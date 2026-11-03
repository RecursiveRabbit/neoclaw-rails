#!/usr/bin/env python3
"""
NeoClaw vertical-slice test agent.

Stock components only:
- matrix-nio (stock Matrix client library): /sync long-poll is the
  notification path; sends are plain room_send calls. (matrix-commander,
  the stock CLI candidate, cannot parse Synapse's current server-less
  room IDs -- KeyError 'room_id' on join; recorded in slice evidence.)
- kimi web (stock Kimi Code local server): POST /api/v1/sessions/{id}/prompts
  is the wake; POST /api/v1/sessions/{id}/prompts/{prompt_id}:steer injects a
  queued prompt into the active turn = guidance.

Wake rules (spec 5.2):
- DM -> wake
- shared room -> wake only on mention of the resident
- unrelated traffic -> no wake
- own messages -> never wake (self-echo suppression)
"""
import asyncio, json, os, re, threading, time, urllib.request, urllib.error

import nio

H = os.environ.get("MATRIX_HOMESERVER", "http://10.89.2.4:8008")
USER = os.environ["RESIDENT_USER"]
MODEL = os.environ.get("SLICE_MODEL", "house/kimi-for-coding")
DISPLAY = os.environ.get("RESIDENT_DISPLAY", "slice-resident")
KIMI = "http://127.0.0.1:58999/api/v1"
BASE = "/pod"
LOGF = open(f"{BASE}/logs/listener.log", "a", buffering=1)
def LOG(*a):
    print(time.strftime("[%H:%M:%S]"), *a, file=LOGF, flush=True)

TOK = open(f"{BASE}/logs/kimi-web.token").read().strip()

def kimi_api(method, path, body=None):
    req = urllib.request.Request(KIMI + path, method=method)
    req.add_header("Authorization", "Bearer " + TOK)
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try: return {"code": e.code, "err": json.loads(e.read())}
        except Exception: return {"code": e.code}

def ensure_session():
    sid_file = "/pod/workspace/slice-session.id"
    if os.path.exists(sid_file):
        sid = open(sid_file).read().strip()
        d = kimi_api("GET", "/sessions/" + sid)
        if d.get("code") == 0:
            LOG("resumed session", sid)
            return sid
    d = kimi_api("POST", "/sessions", {"metadata": {"cwd": "/pod/workspace", "resident": USER}})
    sid = d["data"]["id"]
    open(sid_file, "w").write(sid)
    LOG("created session", sid)
    return sid

SID = ensure_session()
state = {"busy": False, "pending": [], "lock": threading.Lock()}

def responder():
    last_beat = 0
    while True:
        time.sleep(2)
        try:
            d = kimi_api("GET", "/sessions/" + SID)
            if d.get("code") != 0: continue
            busy = d["data"]["busy"]
            with state["lock"]:
                pend = list(state["pending"])
            if time.time() - last_beat > 60:
                last_beat = time.time()
                LOG("responder heartbeat: busy=%s pending=%d" % (busy, len(pend)))
            if state["busy"] and not busy and pend:
                wake_iso = state.get("wake_iso", "")
                text = ""
                for attempt in range(4):
                    msgs = kimi_api("GET", "/sessions/%s/messages?limit=30" % SID).get("data", {}).get("items", [])
                    newer = [m for m in msgs if m["role"] == "assistant"
                             and (not wake_iso or m.get("created_at", "") >= wake_iso)]
                    if newer:
                        text = "\n".join(c.get("text", "") for c in newer[-1].get("content", [])
                                         if isinstance(c, dict) and c.get("type") == "text").strip()
                        if text:
                            break
                    time.sleep(2)
                if text:
                    async def send_all():
                        cl = nio.AsyncClient(H, USER, device_id="slice-agent", store_path="/pod/creds/nio-store")
                        cl.access_token = creds_token
                        for room in pend:
                            r = await cl.room_send(room, "m.room.message",
                                                   {"msgtype": "m.text", "body": text})
                            LOG("replied to", room, "len", len(text), "resp:", type(r).__name__)
                        await cl.close()
                    try:
                        asyncio.run(send_all())
                    except Exception as e:
                        LOG("SEND FAILED:", repr(e))
                else:
                    LOG("assistant text empty; nothing to send")
                with state["lock"]:
                    state["pending"] = []
            state["busy"] = busy
        except Exception as e:
            LOG("responder error:", repr(e))

threading.Thread(target=responder, daemon=True).start()

DM_ROOMS = {os.environ.get("SLICE_DM", "")}
SHARED_ROOMS = {os.environ.get("SLICE_SHARED", "")}
mention_re = re.compile(r"@" + re.escape(DISPLAY) + r"\b|" + re.escape(USER), re.I)
creds = json.load(open(f"{BASE}/creds/credentials.json"))
creds_token = creds["access_token"]

def wake(room, sender, eid, body, why):
    LOG("WAKE [%s] %s %s %s" % (why, room, sender, eid))
    text = ("[Matrix message] room=%s from=%s event=%s\n%s\n"
            "(Your final assistant message in this turn will be posted back to room %s. "
            "Reply to %s directly; keep it short.)" % (room, sender, eid, body, room, sender))
    rb = kimi_api("POST", "/sessions/%s/prompts" % SID,
                  {"content": [{"type": "text", "text": text}],
                   "model": MODEL, "permission_mode": "auto"})
    st = (rb.get("data") or {}).get("status")
    pid = (rb.get("data") or {}).get("prompt_id")
    if st == "queued" and pid:
        rs = kimi_api("POST", "/sessions/%s/prompts/%s:steer" % (SID, pid))
        LOG("busy -> steered guidance:", json.dumps(rs)[:140])
    else:
        LOG("prompt status=", st)
    import datetime as _dt
    with state["lock"]:
        state["pending"].append(room)
        state["wake_iso"] = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.")

async def main():
    cl = nio.AsyncClient(H, USER, device_id=creds["device_id"], store_path="/pod/creds/nio-store")
    cl.access_token = creds_token
    # initial sync to establish since token
    resp = await cl.sync(timeout=30000, full_state=False)
    LOG("initial sync:", getattr(resp, "device_id", type(resp).__name__))
    for rid in [r for r in list(DM_ROOMS | SHARED_ROOMS) if r]:
        jr = await cl.join(rid)
        LOG("join", rid, type(jr).__name__)
    while True:
        resp = await cl.sync(timeout=30000, full_state=False)
        if getattr(resp, "rooms", None) is None: continue
        for rid, space in resp.rooms.join.items():
            for ev in space.timeline.events:
                if not isinstance(ev, nio.RoomMessageText): continue
                if ev.sender == USER:
                    LOG("self-echo suppressed:", ev.event_id)
                    continue
                body = ev.body
                if rid in DM_ROOMS:
                    why = "dm"
                elif rid in SHARED_ROOMS and mention_re.search(body):
                    why = "mention"
                else:
                    LOG("no wake (%s): unrelated" % rid)
                    continue
                wake(rid, ev.sender, ev.event_id, body, why)

asyncio.run(main())
