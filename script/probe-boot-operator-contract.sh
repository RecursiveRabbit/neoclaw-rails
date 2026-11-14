#!/bin/bash
# §7.4 — the boot wiring, measured by booting.
#
# The claim in docs/HUB-ENVIRONMENT.md is that a bad operator list is named *at boot*.
# That is two claims in one sentence: the contract can produce the words (covered by
# test/services/hub/operator_contract_test.rb, ten rows) and the initializer calls it
# at boot (covered here, and by one row that reads this process's log).
#
# Why this is a process and not a test row: `Rails.application.config.after_initialize`
# is not a readable list. Called without a block it RUNS the hooks, and inside a booted
# suite it raises from ActiveSupport's own runner ("undefined method 'call' for nil",
# run 43597828749 / job 132456010050). Loading the initializer again only appends a hook
# that will never fire, and calling run_load_hooks mid-suite would re-execute every other
# initializer's after_initialize work. The only honest place to observe boot is a boot.
#
# Three cases, and the third keeps the first two honest: a probe that can only say
# "found it" cannot tell a working warning from a grep that matches anything.
#
#   unset              -> warns "is unset or empty"
#   bare localpart     -> warns "cannot match any sender"
#   full Matrix ID     -> logs NEITHER: a usable list is silent
#
# Every boot is bounded. It has to be: the same script passed on run 43598262313 and then
# sat in progress for eight minutes on run 43598275411 with identical content, so at least
# one boot sometimes does not return. The cause is not established and is not guessed at
# here. A kill is reported in the output and the assertion is still evaluated, because the
# warning is written during boot, before whatever it was that did not return.
#
# Exit: 0 all three as expected, 1 otherwise. A boot that fails to start is a FAIL, not an
# UNMET: this script runs where a boot is supposed to work.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 64

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL   $*"; }

OUT="${TMPDIR:-/tmp}/probe-boot-$$.out"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-75}"
UNCONFIGURED="is unset or empty"
UNMATCHABLE="cannot match any sender"

# boot [value] — boots the app in its own process with NEOCLAW_OPERATORS set to value,
# or absent when value is "-". Prints everything that boot logged (its file log, then its
# stdout), and appends a note to $NOTE when the process had to be killed.
boot() {
  rm -f log/*.log "$OUT"
  if [ "${1:-}" = "-" ]; then
    timeout -k 5 "$BOOT_TIMEOUT" env -u NEOCLAW_OPERATORS RAILS_ENV=test bin/rails runner 'nil' >"$OUT" 2>&1
  else
    timeout -k 5 "$BOOT_TIMEOUT" env NEOCLAW_OPERATORS="$1" RAILS_ENV=test bin/rails runner 'nil' >"$OUT" 2>&1
  fi
  local rc=$?
  NOTE=""
  if [ "$rc" -eq 124 ]; then
    echo "NOTE   the boot did not return within ${BOOT_TIMEOUT}s and was killed; reading what it wrote before the kill" >&2
    NOTE=" (boot killed after ${BOOT_TIMEOUT}s)"
  fi
  { cat log/*.log 2>/dev/null; echo; cat "$OUT"; } 2>/dev/null
}

boot_started() { # fails loudly when the process never got as far as booting
  if grep -qiE 'Application failed to boot|uninitialized constant|LoadError|cannot load such file' "$OUT"; then
    bad "$1: the boot did not start, so nothing was measured: $(tail -3 "$OUT" | tr '\n' ' ')"
    return 1
  fi
  return 0
}

expect_warning() { # label, value, substring
  local label="$1" value="$2" want="$3" hay
  hay=$(boot "$value")
  boot_started "$label" || return
  case "$hay" in
    *"$want"*) ok "$label: the boot logged it without being asked — ${want}${NOTE}" ;;
    *) bad "$label: no line containing \"${want}\". Looked in log/*.log (present: $(ls log 2>/dev/null | tr '\n' ' ')) and stdout. Last output: $(tail -2 "$OUT" | tr '\n' ' ')${NOTE}" ;;
  esac
}

expect_silence() { # label, value
  local label="$1" value="$2" hay
  hay=$(boot "$value")
  boot_started "$label" || return
  case "$hay" in
    *"$UNCONFIGURED"*|*"$UNMATCHABLE"*)
      bad "$label: a usable list produced a boot warning — the false positive this case exists to catch${NOTE}" ;;
    *) ok "$label: a usable list boots silent, so the probe can tell the difference${NOTE}" ;;
  esac
}

echo "== §7.4 boot probe — three bounded boots, reading what each process logged =="
expect_warning  "unset list"      "-"                  "$UNCONFIGURED"
expect_warning  "bare localpart"  "evans"              "$UNMATCHABLE"
expect_silence  "full Matrix ID"  "@evans:matrix.home"

rm -f "$OUT"
echo
echo "-- $PASS pass, $FAIL fail --"
[ "$FAIL" -eq 0 ]
