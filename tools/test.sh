#!/usr/bin/env bash
# Behaviour tests for bin/agenttalk.
#
# The script is the part of this plugin that owns processes and files, so it is
# the part that gets tested from a terminal. Every test runs against a temporary
# state directory, and the ones that would start a run stub the opencode binary,
# so the suite needs nothing but bash, jq and mktemp.
#
# Usage: bash tools/test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENTTALK="$ROOT/bin/agenttalk"
export AGENTTALK_STATE_DIR
export AGENTTALK_OPENCODE_BIN

passed=0
failed=0

fail() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  shift
  for line in "$@"; do printf '      %s\n' "$line"; done
}

pass() {
  passed=$((passed + 1))
  printf 'ok    %s\n' "$1"
}

check() {
  # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected: $3" "actual:   $2"
  fi
}

# Count the events of one type in a log. jq prints a whole object when the
# filter has no output expression, and an object spans several lines, so
# counting with `jq ... | wc -l` counts lines of *text* rather than events.
#
# A log that is being appended to has a half-written line, and jq reports that
# and still prints its answer, so the number is taken from the first line and
# checked: a second line here would be the `|| 0` fallback after a successful
# print, and the caller's arithmetic would choke on the pair.
event_count() {
  local n
  n=$(jq -s --arg type "${2:-}" 'map(select(.t == $type)) | length' "$1" 2>/dev/null | head -1)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# A run is a detached worker writing a file, so every test that waits for one
# has to wait on the file rather than on the command that started it.
wait_for_event() {
  # wait_for_event <log> <type> <count> [tries]
  local log="$1" type="$2" want="$3" tries="${4:-120}" seen=0
  for ((i = 0; i < tries; i++)); do
    seen=$(event_count "$log" "$type")
    [[ "$seen" -ge "$want" ]] && return 0
    sleep 0.25
  done
  printf '      (waited for %s %s events, saw %s)\n' "$want" "$type" "$seen" >&2
  return 1
}

# A stub that speaks opencode's --format json just well enough to drive the
# normaliser: a session line, two text parts, a tool call, an error, a done line.
# The shapes are the ones `normalize_stream` knows, so a change to that filter
# that the panel could not cope with fails here first.
make_opencode_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "0.0.0-stub"; exit 0; }
printf '%s\n' '{"type":"session","sessionID":"ses_stub"}'
printf '%s\n' '{"type":"text","part":{"text":"first"}}'
printf '%s\n' '{"type":"text","part":{"text":"second"}}'
printf '%s\n' '{"type":"tool_use","part":{"tool":"read","state":{"status":"completed","title":"README.md"}}}'
# One event far larger than any panel budget, for the test that the file the
# panel watches never gets that big. Off unless a test asks for it by size.
if [[ -n "${STUB_HUGE:-}" ]]; then
  printf '{"type":"text","part":{"text":"'
  head -c "$STUB_HUGE" /dev/zero | tr '\0' 'x'
  printf '"}}\n'
fi
printf '%s\n' '{"type":"error","part":{"error":"it went wrong"}}'
printf '%s\n' '{"type":"done"}'
EOF
  chmod +x "$stub"
}

# The largest size the panel's log ever reached while it was being written, and
# the number of samples that saw it. `$(<file)` and ${#} are builtins, so this
# samples fast enough to catch a window a few milliseconds wide, which a `stat`
# per sample could miss. A sample that appears to be over the cap is measured
# again with `stat`, so a violation is confirmed exactly rather than inferred
# from a builtin that drops the trailing newline and is a byte short.
watch_peak() {
  local panel="$1" cap="$2" stop="$3" out="$4" peak=0 samples=0 content size
  while [[ ! -f "$stop" ]]; do
    if [[ -f "$panel" ]]; then
      content=$(<"$panel")
      size=${#content}
      ((size > cap)) && size=$(stat -c%s "$panel" 2>/dev/null || printf 0)
      samples=$((samples + 1))
      ((size > peak)) && peak=$size
    fi
  done
  printf '%s %s' "$peak" "$samples" >"$out"
}

TMP=$(mktemp -d)
# A second root for the tests that need state directories of their own: `complete`
# is compared against an exact listing of $TMP, so nothing else may land in it.
ALT=$(mktemp -d)
trap 'rm -rf "$TMP" "$ALT"' EXIT

AGENTTALK_STATE_DIR="$TMP/state"
STUB="$TMP/opencode"
make_opencode_stub "$STUB"

# --- doctor -----------------------------------------------------------------

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" doctor 2>/dev/null)
check "doctor reports the state directory" \
  "$(jq -r '.stateDir' <<<"$out")" "$AGENTTALK_STATE_DIR"
check "doctor finds the stubbed opencode" \
  "$(jq -r '.opencode.found' <<<"$out")" "true"
check "doctor reports opencode on PATH as a boolean" \
  "$(jq -r '.opencode.onPath | type' <<<"$out")" "boolean"
check "doctor has a version" \
  "$(jq -r '.opencode.version' <<<"$out")" "0.0.0-stub"

# --- init -------------------------------------------------------------------

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" init build 2>/dev/null)
check "init creates the agent directory" \
  "$([[ -d "$AGENTTALK_STATE_DIR/agents/build" ]] && echo yes)" "yes"
check "init creates an empty event log" \
  "$([[ -f "$AGENTTALK_STATE_DIR/agents/build/events.jsonl" ]] && echo yes)" "yes"
check "init creates the panel log the panel watches" \
  "$([[ -f "$AGENTTALK_STATE_DIR/agents/build/panel.jsonl" ]] && echo yes)" "yes"
check "init creates meta.json" \
  "$(jq -r '.agent' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "build"
check "init is idempotent" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" init build 2>/dev/null; echo $?)" "0"

# --- append -----------------------------------------------------------------

AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" append build \
  '{"t":"text","text":"hello"}' >/dev/null 2>&1
check "append writes the event verbatim" \
  "$(tail -1 "$AGENTTALK_STATE_DIR/agents/build/events.jsonl")" \
  '{"t":"text","text":"hello"}'
check "append reaches the panel log too" \
  "$(tail -1 "$AGENTTALK_STATE_DIR/agents/build/panel.jsonl")" \
  '{"t":"text","text":"hello"}'

# --- the panel log is bounded ------------------------------------------------
#
# The panel watches panel.jsonl with a FileView, which reads the whole file it
# is given. events.jsonl grows forever, so watching it means reading a whole
# conversation to render a window that is never that big. These tests pin the
# bound: small caps, many events, and the complete log still complete.

BOUND_STATE="$ALT/state3"
AGENTTALK_OPENCODE_BIN="$STUB" AGENTTALK_STATE_DIR="$BOUND_STATE" \
  AGENTTALK_PANEL_LOG_MAX=2000 AGENTTALK_PANEL_LOG_KEEP=1000 \
  "$AGENTTALK" init bound >/dev/null 2>&1
for i in $(seq 1 60); do
  AGENTTALK_OPENCODE_BIN="$STUB" AGENTTALK_STATE_DIR="$BOUND_STATE" \
    AGENTTALK_PANEL_LOG_MAX=2000 AGENTTALK_PANEL_LOG_KEEP=1000 \
    "$AGENTTALK" append bound \
    "{\"t\":\"text\",\"text\":\"event number $i padded out with some words to make it long enough to matter\"}" \
    >/dev/null 2>&1
done
check "the panel log stays under its cap" \
  "$([[ "$(stat -c%s "$BOUND_STATE/agents/bound/panel.jsonl")" -le 2000 ]] && echo yes)" "yes"
check "the panel log has dropped the oldest events" \
  "$(jq -r '.text' "$BOUND_STATE/agents/bound/panel.jsonl" | grep -c '^event number 1 padded')" "0"
check "the panel log kept a whole number of events" \
  "$([[ "$(jq -s 'length' "$BOUND_STATE/agents/bound/panel.jsonl")" -gt 5 ]] && echo yes)" "yes"
check "the complete log kept every event" \
  "$(wc -l <"$BOUND_STATE/agents/bound/events.jsonl" | tr -d ' ')" "60"
check "the panel log is shorter than the complete log" \
  "$([[ "$(stat -c%s "$BOUND_STATE/agents/bound/panel.jsonl")" -lt \
      "$(stat -c%s "$BOUND_STATE/agents/bound/events.jsonl")" ]] && echo yes)" "yes"
check "the panel log keeps the newest event" \
  "$(tail -1 "$BOUND_STATE/agents/bound/panel.jsonl" | jq -r '.text')" \
  "event number 60 padded out with some words to make it long enough to matter"
check "the panel log has no half-written line" \
  "$(jq -s 'length' "$BOUND_STATE/agents/bound/panel.jsonl")" \
  "$(wc -l <"$BOUND_STATE/agents/bound/panel.jsonl" | tr -d ' ')"

# One event too big for the cap on its own, which is what a run that reads a
# large file produces. Wherever the log was, this crosses the cap and trims, so
# the size afterwards is the keep size and not a function of luck.
BIG=$(printf 'x%.0s' $(seq 1 1500))
AGENTTALK_OPENCODE_BIN="$STUB" AGENTTALK_STATE_DIR="$BOUND_STATE" \
  AGENTTALK_PANEL_LOG_MAX=2000 AGENTTALK_PANEL_LOG_KEEP=1000 \
  "$AGENTTALK" append bound "$(jq -nc --arg t "$BIG" '{t: "text", text: $t}')" \
  >/dev/null 2>&1
check "an event bigger than the keep size does not blank the panel" \
  "$(jq -r 'select(.text|startswith("xxx")) | .text | length' \
      "$BOUND_STATE/agents/bound/panel.jsonl")" "1500"
check "the panel log is still under the cap after one big event" \
  "$([[ "$(stat -c%s "$BOUND_STATE/agents/bound/panel.jsonl")" -le 2000 ]] && echo yes)" "yes"
check "the big event is in the complete log too" \
  "$(jq -r 'select(.text|startswith("xxx")) | .text | length' \
      "$BOUND_STATE/agents/bound/events.jsonl")" "1500"

# --- a watched file is never readable half-written ---------------------------

# The panel watches meta.json through the same FileView as the log, and `> file`
# truncates before the first byte of the new content lands. A reader in between
# gets an empty file, and jq on an empty file answers nothing at all — which is
# how a pinned workspace disappears for no reason. It is not a theory: it made
# three tests fail on a loaded CI runner and nowhere else, and the panel is the
# reader that actually matters.
#
# The helper is driven directly, in its own bash, because what it promises is
# what a reader sees at the instant of the write. Run through the CLI the write
# is finished before a caller could look, which is precisely why this went
# unnoticed for so long. A truncate-then-write fails this within a few hundred
# reads.
#
# The reader is builtins only, on purpose: `$(<file)` and a glob test cannot
# fork, so a read that fails is a torn file and never a process that would not
# start. A jq here would fail the whole run on a busy machine for no reason.
atomic_reads=$(bash -c '
  set -uo pipefail
  source "$1"
  target="$2"
  mkdir -p "$(dirname "$target")"
  # Seed it, so a read that finds no file at all is not counted as a tear: the
  # claim under test is that a rewrite is never half-written, not that the file
  # exists before the first write.
  printf "{\"n\":0}\n" | write_atomic "$target"
  torn=0
  reads=0
  (
    for ((i = 0; i < 1000; i++)); do
      printf "{\"n\":%s}\n" "$i" | write_atomic "$target"
    done
  ) &
  writer=$!
  while kill -0 "$writer" 2>/dev/null; do
    if [[ -f "$target" ]]; then
      reads=$((reads + 1))
      [[ "$(<"$target")" == *\"n\":* ]] || torn=$((torn + 1))
    fi
  done
  wait "$writer"
  printf "%s %s" "$torn" "$reads"
' _ "$AGENTTALK" "$ALT/atomic/meta.json")
check "a meta.json rewrite is never readable half-written" \
  "${atomic_reads%% *}" "0"
# A test that stops reading early passes without having proved anything, so the
# reader is required to have caught the file in flight a good number of times.
check "the reader really did catch the file mid-flight" \
  "$([[ "${atomic_reads##* }" -ge 500 ]] && echo yes)" "yes"
check "the write that landed last is the one that is left" \
  "$(jq -r '.n' "$ALT/atomic/meta.json")" "999"
check "a write leaves no temporary file behind" \
  "$(find "$ALT/atomic" -name 'meta.json.??????' | wc -l | tr -d ' ')" "0"

# The cap is not a promise about the size at the end; it is a promise about the
# size at every instant, because the panel reads this file on every change into
# the shell process that outlives everything else. Settling the size after the
# write bounds the log only in the state nobody is looking at, and one event
# larger than the whole budget made that state last for as long as the trim took.
#
# So the assertion here is the largest size ever *observed*, sampled while a run
# streams an event that is a hundred times the cap.
HUGE_STATE="$ALT/huge"
HUGE_LOG="$HUGE_STATE/agents/huge/panel.jsonl"
HUGE_EVENTS="$HUGE_STATE/agents/huge/events.jsonl"
PEAK_OUT="$ALT/peak"
STOP_FLAG="$ALT/stop-watching"
rm -f "$STOP_FLAG" "$PEAK_OUT"
watch_peak "$HUGE_LOG" 2000 "$STOP_FLAG" "$PEAK_OUT" &
watcher=$!
printf 'go' | AGENTTALK_OPENCODE_BIN="$STUB" AGENTTALK_STATE_DIR="$HUGE_STATE" \
  AGENTTALK_PANEL_LOG_MAX=2000 AGENTTALK_PANEL_LOG_KEEP=1000 STUB_HUGE=200000 \
  AGENTTALK_EVENT_MAX=400000 \
  "$AGENTTALK" run huge >/dev/null 2>&1
wait_for_event "$HUGE_EVENTS" done 1
: >"$STOP_FLAG"
wait "$watcher"
peak_read=$(<"$PEAK_OUT")
peak=${peak_read% *}
samples=${peak_read#* }
# `wait_for_event` is not checked by the harness, so state the thing it was
# waiting for: a run that stopped halfway would leave every assertion below true
# for the wrong reason.
check "the run finished, so the assertions below are not on a half-written log" \
  "$(event_count "$HUGE_EVENTS" done)" "1"
check "the panel's log never exceeded the cap while it was written" \
  "$([[ "$peak" -le 2000 ]] && echo yes)" "yes"
# Without this the assertion above is satisfied by a sampler that never ran.
check "the sampler really did watch the file while it grew" \
  "$([[ "$samples" -ge 50 ]] && echo yes)" "yes"
check "an event bigger than the whole budget is not shown whole" \
  "$(jq -r 'select((.text // "") | test("too large to show")) | .text' "$HUGE_LOG" | wc -l | tr -d ' ')" "1"
check "the panel says how big it was instead of showing nothing" \
  "$(jq -r 'select((.text // "") | test("too large to show")) | .text' "$HUGE_LOG" | grep -c '200')" "1"
# Legal as one event, too big for the panel: the complete log keeps all of it.
check "the big event is in the complete log in full" \
  "$(jq -r 'select((.text // "") | length > 100000) | .text | length' "$HUGE_EVENTS")" "200000"
check "the panel's log is small again once the run is over" \
  "$([[ "$(stat -c%s "$HUGE_LOG")" -lt 2000 ]] && echo yes)" "yes"

# A line over the event limit is a line the worker cannot hold whole, so it is
# read in pieces, dropped, and reported. The two lines after it in the stream
# still have to arrive: a reader that takes a line apart and then loses track of
# where the line ended would swallow them, and `wait_for_event` below would hang
# rather than fail, which is why the run is bounded here.
BIG_STATE="$ALT/big"
BIG_LOG="$BIG_STATE/agents/big/events.jsonl"
BIG_PANEL="$BIG_STATE/agents/big/panel.jsonl"
printf 'go' | AGENTTALK_OPENCODE_BIN="$STUB" AGENTTALK_STATE_DIR="$BIG_STATE" \
  STUB_HUGE=200000 \
  "$AGENTTALK" run big >/dev/null 2>&1
wait_for_event "$BIG_LOG" done 1
check "a run with an over-long line still finished" \
  "$(event_count "$BIG_LOG" done)" "1"
check "the line after the over-long one arrived" \
  "$(event_count "$BIG_LOG" error)" "1"
check "an over-long event is not in the transcript in full" \
  "$(jq -r 'select((.text // "") | length > 100000) | .text | length' "$BIG_LOG")" ""
check "the transcript says an event was too large" \
  "$(jq -r 'select((.text // "") | test("limit for one event")) | .text' "$BIG_LOG" | wc -l | tr -d ' ')" "1"
check "the panel says the same" \
  "$(jq -r 'select((.text // "") | test("limit for one event")) | .text' "$BIG_PANEL" | wc -l | tr -d ' ')" "1"
check "the complete log is nowhere near the size of the line it dropped" \
  "$([[ "$(stat -c%s "$BIG_LOG")" -lt 10000 ]] && echo yes)" "yes"

# The complete log is bounded, and the bound is settled before the write rather
# than after it, on the same terms as the panel's copy of it.
GROW_STATE="$ALT/grow"
GROW_LOG="$GROW_STATE/agents/grow/events.jsonl"
GROW_PEAK="$ALT/grow-peak"
rm -f "$GROW_PEAK" "$STOP_FLAG"
watch_peak "$GROW_LOG" 2000 "$STOP_FLAG" "$GROW_PEAK" &
grow_watcher=$!
for i in $(seq 1 400); do
  AGENTTALK_STATE_DIR="$GROW_STATE" AGENTTALK_EVENT_MAX=600 \
    AGENTTALK_EVENTS_LOG_MAX=2000 AGENTTALK_EVENTS_LOG_KEEP=1000 \
    "$AGENTTALK" append grow "{\"t\":\"text\",\"text\":\"event number $i in this conversation\"}" >/dev/null 2>&1
done
: >"$STOP_FLAG"
wait "$grow_watcher"
grow_read=$(<"$GROW_PEAK")
grow_peak=${grow_read% *}
grow_samples=${grow_read#* }
check "the complete log never went over its own cap" \
  "$([[ "$grow_peak" -le 2000 ]] && echo yes)" "yes"
check "the sampler really did watch the complete log while it grew" \
  "$([[ "$grow_samples" -ge 50 ]] && echo yes)" "yes"
check "the newest event is still in the complete log" \
  "$(jq -r 'select((.text // "") | test("event number 400")) | .text' "$GROW_LOG")" \
  "event number 400 in this conversation"
check "the oldest events are the ones that went" \
  "$(jq -r 'select((.text // "") | test("event number 1 in")) | .text' "$GROW_LOG")" ""
check "the trim left every line whole" \
  "$(jq -c . "$GROW_LOG" >/dev/null 2>&1 && echo yes)" "yes"

# `append` is the way in that does not go through the worker, so it is the only
# way an event that is too big for one event reaches append_event, and it has to
# be refused there as well.
BIG_APPEND="$ALT/big-append"
big_payload=$(printf 'y%.0s' $(seq 1 5000))
AGENTTALK_STATE_DIR="$BIG_APPEND" AGENTTALK_EVENT_MAX=600 \
  "$AGENTTALK" append loud "{\"t\":\"text\",\"text\":\"$big_payload\"}" >/dev/null 2>&1
check "an event appended over the event limit is not stored whole" \
  "$(jq -r 'select((.text // "") | length > 1000) | .text | length' \
      "$BIG_APPEND/agents/loud/events.jsonl")" ""
check "an event appended over the event limit says so instead" \
  "$(jq -r 'select((.text // "") | test("limit for one event")) | .text' \
      "$BIG_APPEND/agents/loud/events.jsonl" | wc -l | tr -d ' ')" "1"
check "the panel is told the same thing" \
  "$(jq -r 'select((.text // "") | test("limit for one event")) | .text' \
      "$BIG_APPEND/agents/loud/panel.jsonl" | wc -l | tr -d ' ')" "1"

# --- run --------------------------------------------------------------------

printf 'do the thing' | AGENTTALK_OPENCODE_BIN="$STUB" \
  "$AGENTTALK" run build --dir "$TMP" >/dev/null 2>&1
events="$AGENTTALK_STATE_DIR/agents/build/events.jsonl"
wait_for_event "$events" done 1

check "run records the prompt" \
  "$(jq -r 'select(.t=="user") | .text' "$events" | head -1)" "do the thing"
check "run records the workdir the prompt was sent to" \
  "$(jq -r 'select(.t=="user") | .workdir' "$events" | head -1)" "$TMP"
check "run records the session id" \
  "$(jq -r 'select(.t=="session") | .id' "$events" | head -1)" "ses_stub"
check "run normalises the answer" \
  "$(jq -r 'select(.t=="text") | .text' "$events" | tail -2 | paste -sd' ' -)" "first second"
check "run normalises a tool call" \
  "$(jq -r 'select(.t=="tool") | .tool + " " + .title' "$events" | head -1)" "read README.md"
check "run normalises an error" \
  "$(jq -r 'select(.t=="error") | .text' "$events" | head -1)" "it went wrong"
check "run finishes with a done event" \
  "$(jq -r 'select(.t=="done") | .code' "$events" | head -1)" "0"
check "run records a clean exit" \
  "$(jq -r '.running' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "false"
check "run stores the session for the next turn" \
  "$(jq -r '.sessionID' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "ses_stub"
# worker.log is where a worker that dies before opencode starts would say why,
# so a run that worked has to leave it empty.
check "a run that worked leaves the worker log empty" \
  "$([[ ! -s "$AGENTTALK_STATE_DIR/agents/build/worker.log" ]] && echo empty)" "empty"

# --- the prompt travels on stdin ---------------------------------------------
#
# A task, or a stack trace somebody could not show anyone, is the most private
# thing this plugin ever handles. argv is world readable, so a prompt in it
# would sit in any user's `ps` for the length of the run. These tests watch what
# opencode actually receives: a stub that records its own argv and its stdin.

make_recording_stub() {
  local stub="$1" record="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "0.0.0-stub"; exit 0; }
{
  printf 'argv=%s\n' "\$*"
  printf 'stdin='
  cat
} >"$record"
printf '%s\n' '{"type":"session","sessionID":"ses_stub"}'
printf '%s\n' '{"type":"done"}'
EOF
  chmod +x "$stub"
}

SECRET="the vault code is hunter2 and the token is sk-not-a-real-one"
REC_STUB="$ALT/opencode-record"
RECORD="$ALT/record.txt"
REC_STATE="$ALT/state4"
make_recording_stub "$REC_STUB" "$RECORD"
printf '%s' "$SECRET" | AGENTTALK_OPENCODE_BIN="$REC_STUB" AGENTTALK_STATE_DIR="$REC_STATE" \
  "$AGENTTALK" run build --dir "$TMP" >/dev/null 2>&1
wait_for_event "$REC_STATE/agents/build/events.jsonl" done 1
# The prompt is everything from the `stdin=` marker on, and a prompt can be more
# than one line, so the marker goes and everything after it stays.
recorded_stdin() { sed -n '/^stdin=/,$p' "$1" | sed '1s/^stdin=//'; }
check "opencode is given the prompt on stdin" \
  "$(recorded_stdin "$RECORD")" "$SECRET"
check "opencode's argv holds none of the prompt" \
  "$(grep '^argv=' "$RECORD" | grep -cF "$SECRET")" "0"
check "opencode's argv is only flags" \
  "$(grep '^argv=' "$RECORD" | grep -c 'hunter2')" "0"
check "the transcript still records the prompt" \
  "$(jq -r 'select(.t=="user") | .text' "$REC_STATE/agents/build/events.jsonl")" "$SECRET"
printf 'line one\nline two\n' | AGENTTALK_OPENCODE_BIN="$REC_STUB" \
  AGENTTALK_STATE_DIR="$ALT/state5" "$AGENTTALK" run build --dir "$TMP" >/dev/null 2>&1
wait_for_event "$ALT/state5/agents/build/events.jsonl" done 1
check "a multiline prompt survives the trip" \
  "$(recorded_stdin "$RECORD")" "line one
line two"

# --- cd ---------------------------------------------------------------------

meta="$AGENTTALK_STATE_DIR/agents/build/meta.json"

check "a fresh agent has no pinned workdir" \
  "$(jq -r '.workdirPinned' "$meta")" "false"

mkdir -p "$TMP/project"
out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build "$TMP/project" 2>/dev/null)
check "cd prints the directory it pinned" "$out" "$TMP/project"
check "cd records the pinned flag" "$(jq -r '.workdirPinned' "$meta")" "true"
check "cd records the directory" "$(jq -r '.workdir' "$meta")" "$TMP/project"
check "cd leaves the conversation alone" \
  "$(jq -r 'select(.t=="user") | .text' "$events" | head -1)" "do the thing"

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build "~" 2>/dev/null)
check "cd expands ~" "$out" "$HOME"

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build "$TMP/nope" 2>&1)
check "cd refuses a directory that does not exist" \
  "$(grep -c 'no such directory' <<<"$out")" "1"
check "cd failing leaves the pin alone" "$(jq -r '.workdir' "$meta")" "$HOME"

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build 2>&1)
check "cd without a target is refused" "$(grep -c 'needs a directory' <<<"$out")" "1"

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build --window 2>/dev/null)
check "cd --window prints the directory it followed" \
  "$([[ -d "$out" ]] && echo yes)" "yes"
check "cd --window pins that directory" "$(jq -r '.workdir' "$meta")" "$out"

out=$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build --reset 2>/dev/null)
check "cd --reset is quiet" "$out" ""
check "cd --reset unpins" "$(jq -r '.workdirPinned' "$meta")" "false"
check "cd --reset forgets the directory" "$(jq -r '.workdir' "$meta")" ""

check "cd fails for an agent that does not exist" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd "no/such/agent" "$TMP" >/dev/null 2>&1; echo $?)" "1"

# --- complete ----------------------------------------------------------------
#
# `complete` is what the panel's Tab key asks. It lists directories only, and it
# says nothing at all when there is no match, because a field that is being
# typed into must not sprout an error the moment the stem stops matching.
mkdir -p "$TMP/project" "$TMP/project-two" "$TMP/other" "$TMP/AgentTalk" "$TMP/.hidden" \
  "$TMP/other/deep" "$TMP/elsewhere"
touch "$TMP/a file"
# $TMP also holds the state directory, so the listing is compared by what it
# does and does not contain rather than by an exact copy of the whole list.
check "complete with no stem lists the directories under a prefix" \
  "$("$AGENTTALK" complete "$TMP/" | tr '\n' ' ')" "AgentTalk elsewhere other project project-two state "
check "complete narrows to the stem" \
  "$("$AGENTTALK" complete "$TMP/" project | tr '\n' ' ')" "project project-two "
check "complete returns the whole match for a unique stem" \
  "$("$AGENTTALK" complete "$TMP/" other)" "other"
check "complete lists no files" \
  "$("$AGENTTALK" complete "$TMP/" "a file" | tr -d '\n')" ""
check "complete is quiet when nothing matches" \
  "$("$AGENTTALK" complete "$TMP/" zzzznope 2>/dev/null | tr -d '\n')" ""
check "complete succeeds when nothing matches" \
  "$("$AGENTTALK" complete "$TMP/" zzzznope >/dev/null 2>&1; echo $?)" "0"
check "complete is quiet for a prefix that is not a directory" \
  "$("$AGENTTALK" complete "$TMP/project/" 2>/dev/null | tr -d '\n')" ""
check "complete expands a ~ prefix" \
  "$("$AGENTTALK" complete "~" | head -1 | grep -c .)" "1"
check "complete with no prefix lists the home directory" \
  "$([[ -d "$HOME/$("$AGENTTALK" complete "" | head -1)" ]] && echo yes)" "yes"

# The panel is not a shell. It has no case-sensitivity muscle memory, and a
# case-sensitive match answers `agent` with silence where `AgentTalk` is right
# there -- and silence in a field that is being typed into reads as a broken
# completion, so the user presses Enter and gets told the directory is missing.
check "complete matches the stem regardless of case" \
  "$("$AGENTTALK" complete "$TMP/" agenttalk)" "AgentTalk"
check "complete matches a lowercase stem against a capitalised directory" \
  "$("$AGENTTALK" complete "$TMP/" AGENTTALK)" "AgentTalk"
check "complete still prefers the exact case over a case-insensitive match" \
  "$("$AGENTTALK" complete "$TMP/" project | tr '\n' ' ')" "project project-two "

# A slash inside the stem is part of the path, not part of the name. The panel
# splits the field at its last slash, so it never sends one, but Tab puts a
# trailing slash there after a unique match and a person at a terminal types
# `other/dee` as a single string. Both are answered the same way, because a stem
# that cannot match anything is silence where a directory is sitting right
# there, and silence in this field reads as "no such directory".
check "complete still returns the whole match for a plain unique stem" \
  "$("$AGENTTALK" complete "$TMP/" other)" "other"
check "complete with a trailing slash lists what is inside" \
  "$("$AGENTTALK" complete "$TMP/other/" | tr '\n' ' ')" "deep "
check "complete reads a trailing slash in the stem as inside" \
  "$("$AGENTTALK" complete "$TMP/" "other/" | tr '\n' ' ')" "deep "
check "complete reads a slash in the middle of the stem as a path" \
  "$("$AGENTTALK" complete "$TMP/" "other/dee")" "deep"
check "complete is quiet for a trailing slash that names no directory" \
  "$("$AGENTTALK" complete "$TMP/" "nope/" 2>/dev/null | tr -d '\n')" ""

# A path that does not start at the root means the user's home directory, which
# is what the panel sends and where a bare name in the field belongs. Resolving
# it against the working directory instead would make the answer depend on
# wherever the shell happened to start, so this checks a directory that exists
# only under the cwd and asks for it by that name: it must not be found.
mkdir -p "$TMP/elsewhere/decoy"
check "complete does not resolve a relative path against the working directory" \
  "$(cd "$TMP/elsewhere" && "$AGENTTALK" complete "decoy/" | tr -d '\n')" ""

# A dot directory at the front of a list moves the common prefix of everything
# behind it, so they are hidden unless asked for by name.
check "complete hides a dot directory by default" \
  "$("$AGENTTALK" complete "$TMP/" | grep -c '^\.')" "0"
check "complete offers a dot directory when the stem asks for one" \
  "$("$AGENTTALK" complete "$TMP/" .hidden)" ".hidden"
check "complete does not offer a dot directory to a plain stem" \
  "$("$AGENTTALK" complete "$TMP/" hid | tr -d '\n')" ""

# `cd` names the two ways a path can be wrong differently, because a file that
# is visibly right there is not a typo.
check "cd says a file is not a directory" \
  "$("$AGENTTALK" cd build "$TMP/a file" 2>&1 >/dev/null)" "agenttalk: not a directory: $TMP/a file"
check "cd still says no such directory for a path that is not there" \
  "$("$AGENTTALK" cd build "$TMP/nope" 2>&1 >/dev/null)" "agenttalk: no such directory: $TMP/nope"

# A pinned workdir is what a run uses when the panel does not name one, which
# is the whole point of pinning it: the run happens where the user said, not
# where a window happened to be.
AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build "$TMP/project" >/dev/null 2>&1
printf 'again' | AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build >/dev/null 2>&1
wait_for_event "$events" user 2
wait_for_event "$events" done 2
check "a run without --dir uses the pinned workdir" \
  "$(jq -r 'select(.t=="user") | .workdir' "$events" | tail -1)" "$TMP/project"
check "a run keeps the pin for the next one" \
  "$(jq -r '.workdirPinned' "$meta")" "true"

# --- clear ------------------------------------------------------------------

AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" clear build >/dev/null 2>&1
check "clear forgets the conversation" \
  "$([[ ! -s "$AGENTTALK_STATE_DIR/agents/build/events.jsonl" ]] && echo empty)" "empty"
check "clear resets the session" \
  "$(jq -r '.sessionID' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" ""
# The workspace was chosen on purpose and is not part of the conversation.
# It used to vanish here, because clear wrote an older meta.json that had no
# room for it and the panel fell back to following the window.
check "clear keeps the pinned workspace" \
  "$(jq -r '.workdir' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "$TMP/project"
check "clear keeps the pin marked" \
  "$(jq -r '.workdirPinned' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "true"
check "clear writes every key the panel reads" \
  "$(jq -r 'keys | join(",")' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" \
  "agent,exitCode,pid,running,sessionID,workdir,workdirPinned"
AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" cd build --reset >/dev/null 2>&1
check "the pin can still be reset after a clear" \
  "$(jq -r '.workdirPinned' "$AGENTTALK_STATE_DIR/agents/build/meta.json")" "false"

# --- failures ---------------------------------------------------------------

check "run without an agent fails" \
  "$(printf 'hi' | AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run "" >/dev/null 2>&1; echo $?)" "1"
check "run without a prompt fails" \
  "$(printf '' | AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build >/dev/null 2>&1; echo $?)" "1"
check "run with only whitespace as a prompt fails" \
  "$(printf '   \n  ' | AGENTTALK_OPENCODE_BIN="$STUB" \
      "$AGENTTALK" run build >/dev/null 2>&1; echo $?)" "1"
check "run with nothing on stdin at all fails" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build </dev/null >/dev/null 2>&1; echo $?)" "1"
check "a prompt given as an argument is not read as one" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build "hi" </dev/null 2>&1 \
      | grep -c "needs a prompt on stdin")" "1"
check "a plain run complains about nothing" \
  "$(printf 'hi' | AGENTTALK_OPENCODE_BIN="$TMP/nope" AGENTTALK_STATE_DIR="$ALT/state6" \
      "$AGENTTALK" run build 2>&1 | grep -c "unknown option")" "0"
check "a missing opencode is reported" \
  "$(printf 'hi' | AGENTTALK_OPENCODE_BIN="$TMP/nope" AGENTTALK_STATE_DIR="$TMP/state2" \
      "$AGENTTALK" run build 2>&1 | grep -c "not found")" "1"
check "doctor survives a missing opencode" \
  "$(AGENTTALK_OPENCODE_BIN="$TMP/nope" AGENTTALK_STATE_DIR="$TMP/state2" \
      "$AGENTTALK" doctor >/dev/null 2>&1; echo $?)" "0"

# --- bind / unbind ----------------------------------------------------------

HYPR_DIR="$TMP/hypr"
mkdir -p "$HYPR_DIR"
# Omarchy ships bindings.lua; `bind` refuses to invent one, so a test that wants
# to check the binding has to look like a real Hyprland config.
printf '%s\n' 'o.bind("ALT + SPACE", "Omarchy menu", "omarchy-menu toggle")' >"$HYPR_DIR/bindings.lua"
AGENTTALK_OPENCODE_BIN="$STUB" HYPRLAND_CONFIG_DIR="$HYPR_DIR" \
  "$AGENTTALK" bind SUPER CTRL A >/dev/null 2>&1
# Omarchy's o.bind takes the whole combo as one string, so the point of these
# two checks is the exact line that ends up in bindings.lua.
check "bind writes the requested combo as one string" \
  "$(grep -c 'o.bind("SUPER + CTRL + A", "AgentTalk"' "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "1"
check "bind unbinds the same combo first" \
  "$(grep -c 'hl.unbind("SUPER + CTRL + A")' "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "1"
check "bind marks the block as its own" \
  "$(grep -c 'managed by bin/agenttalk' "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "1"
# Binding twice must replace our block, not stack a second copy of it.
AGENTTALK_OPENCODE_BIN="$STUB" HYPRLAND_CONFIG_DIR="$HYPR_DIR" \
  "$AGENTTALK" bind SUPER CTRL A >/dev/null 2>&1
check "bind is idempotent" \
  "$(grep -c -- ">>> agenttalk" "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "1"
check "unbind reports the combo it removed" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" HYPRLAND_CONFIG_DIR="$HYPR_DIR" \
      "$AGENTTALK" unbind 2>/dev/null)" "removed the agenttalk binding on SUPER + CTRL + A"
check "unbind is quiet when there is nothing to remove" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" HYPRLAND_CONFIG_DIR="$HYPR_DIR" \
      "$AGENTTALK" unbind 2>/dev/null)" "no agenttalk keybinding found"
AGENTTALK_OPENCODE_BIN="$STUB" HYPRLAND_CONFIG_DIR="$HYPR_DIR" \
  "$AGENTTALK" unbind >/dev/null 2>&1
check "unbind leaves no agenttalk line behind" \
  "$(grep -c 'agenttalk' "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "0"
check "unbind leaves a binding it does not own alone" \
  "$(grep -c 'ALT + SPACE' "$HYPR_DIR/bindings.lua" 2>/dev/null || true)" "1"

# --- panel model -----------------------------------------------------------
#
# Model.js holds the only logic the panel runs that is not a QML binding, and
# none of it can be checked by opening a panel. It runs under node, which is a
# test-time need and not a runtime one: the plugin is still QML, bash, jq and
# opencode. Skipped rather than failed where node is absent, so the suite stays
# runnable on a machine that only has the plugin's own dependencies.

if command -v node >/dev/null 2>&1; then
  model_out=$(node "$ROOT/tools/test_model.js" 2>&1)
  model_status=$?
  printf '%s\n' "$model_out"
  # Its own summary line, so the counts are the ones test_model.js actually
  # printed rather than a number that has to be kept in step by hand.
  model_line=$(printf '%s\n' "$model_out" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)
  if [[ -n "$model_line" ]]; then
    # Its own summary line, so the counts are the ones test_model.js actually
    # printed rather than numbers that have to be kept in step by hand. Both
    # halves are carried over: collapsing four broken assertions into one
    # failure would make a green suite one edit away from a lie.
    passed=$((passed + $(printf '%s' "$model_line" | cut -d' ' -f1)))
    failed=$((failed + $(printf '%s' "$model_line" | cut -d' ' -f3)))
  else
    failed=$((failed + 1))
    printf 'FAIL  Model.js (node failed without a summary)\n'
  fi
else
  printf 'skip  Model.js (no node)\n'
fi

# --- summary ----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
