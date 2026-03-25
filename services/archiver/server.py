#!/usr/bin/env python3
"""NeoClaw Archiver Service (lightweight)

- ChromaDB persistent store
- Chroma default embedding function (ONNX, CPU-friendly)
- No torch/sentence-transformers dependency
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
from pathlib import Path
from typing import List

import chromadb
from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel

HOST = os.environ.get("ARCHIVER_HOST", "10.0.0.2")
PORT = int(os.environ.get("ARCHIVER_PORT", "4010"))
API_KEY = os.environ.get("ARCHIVER_API_KEY", "")
DATA_DIR = os.environ.get("ARCHIVER_DATA_DIR", "/var/lib/neoclaw/archiver")
ARCHIVER_SOURCES = os.environ.get(
    "ARCHIVER_SOURCES",
    "/var/lib/neoclaw/workspaces/*,/var/lib/neoclaw/sessions/*,/var/lib/neoclaw/manager-db/streams/*.json",
)
MAX_K = int(os.environ.get("ARCHIVER_MAX_K", "25"))

Path(DATA_DIR).mkdir(parents=True, exist_ok=True)
client = chromadb.PersistentClient(path=DATA_DIR)
collection = client.get_or_create_collection("neoclaw_sessions")

app = FastAPI(title="neoclaw-archiver", version="0.2.0")


def _auth(x_api_key: str | None):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid api key")


def _chunk(text: str, size: int = 900, overlap: int = 120) -> List[str]:
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    out = []
    i = 0
    n = len(text)
    step = max(1, size - overlap)
    while i < n:
        out.append(text[i:i+size])
        i += step
    return out


def _extract_text(path: str) -> str:
    p = Path(path)
    try:
        if p.suffix == ".jsonl":
            lines = []
            for ln in p.read_text(errors="ignore").splitlines():
                try:
                    obj = json.loads(ln)
                except Exception:
                    continue
                msg = obj.get("message", {})
                content = msg.get("content", [])
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            lines.append(c.get("text", ""))
                elif isinstance(content, str):
                    lines.append(content)
            return "\n".join(lines)
        if p.suffix == ".json":
            obj = json.loads(p.read_text(errors="ignore"))
            return json.dumps(obj, ensure_ascii=False)
        return p.read_text(errors="ignore")
    except Exception:
        return ""


def _doc_id(path: str, chunk_i: int, chunk: str) -> str:
    h = hashlib.sha256((path + "|" + str(chunk_i) + "|" + chunk[:120]).encode()).hexdigest()
    return h


class ReindexRequest(BaseModel):
    glob: str | None = None
    limit_files: int = 0


@app.get("/health")
def health():
    return {"status": "ok", "host": HOST, "port": PORT}


@app.post("/reindex")
def reindex(req: ReindexRequest, x_api_key: str | None = Header(default=None)):
    _auth(x_api_key)
    patterns = [p.strip() for p in (req.glob or ARCHIVER_SOURCES).split(',') if p.strip()]
    files = []
    for pat in patterns:
        for m in glob.glob(pat):
            if os.path.isdir(m):
                files.extend(glob.glob(f"{m}/**/*.jsonl", recursive=True))
                files.extend(glob.glob(f"{m}/**/*.json", recursive=True))
                files.extend(glob.glob(f"{m}/**/*.md", recursive=True))
                files.extend(glob.glob(f"{m}/**/*.txt", recursive=True))
            elif os.path.isfile(m):
                files.append(m)

    files = [f for f in files if ('/sessions/' in f) or ('/streams/' in f) or f.endswith((".md", ".txt", ".json", ".jsonl"))]
    files = sorted(set(files))
    if req.limit_files and req.limit_files > 0:
        files = files[: req.limit_files]

    ids, docs, metas = [], [], []
    for f in files:
        txt = _extract_text(f)
        for i, ch in enumerate(_chunk(txt)):
            ids.append(_doc_id(f, i, ch))
            docs.append(ch)
            metas.append({"path": f, "chunk": i})

    if ids:
        bs = 250
        for i in range(0, len(ids), bs):
            collection.upsert(ids=ids[i:i+bs], documents=docs[i:i+bs], metadatas=metas[i:i+bs])

    return {"indexed_files": len(files), "indexed_chunks": len(ids)}


@app.get("/search")
def search(
    q: str = Query(..., min_length=2),
    k: int = Query(5, ge=1, le=MAX_K),
    path_prefix: str | None = None,
    x_api_key: str | None = Header(default=None),
):
    _auth(x_api_key)
    where = {"path": {"$contains": path_prefix}} if path_prefix else None
    res = collection.query(query_texts=[q], n_results=k, where=where)

    out = []
    ids = res.get("ids", [[]])[0]
    docs = res.get("documents", [[]])[0]
    metas = res.get("metadatas", [[]])[0]
    dists = res.get("distances", [[]])[0]
    for i in range(len(ids)):
        out.append({
            "id": ids[i],
            "score": float(1.0 - (dists[i] if i < len(dists) else 0.0)),
            "path": metas[i].get("path") if i < len(metas) else None,
            "chunk": metas[i].get("chunk") if i < len(metas) else None,
            "text": docs[i],
        })
    return {"results": out}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT)
