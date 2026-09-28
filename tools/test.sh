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
event_count() {
  jq -s --arg type "${2:-}" 'map(select(.t == $type)) | length' "$1" 2>/dev/null || echo 0
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
printf '%s\n' '{"type":"error","part":{"error":"it went wrong"}}'
printf '%s\n' '{"type":"done"}'
EOF
  chmod +x "$stub"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# --- run --------------------------------------------------------------------

AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build "do the thing" --dir "$TMP" >/dev/null 2>&1
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
AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build "again" >/dev/null 2>&1
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
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run "" "hi" >/dev/null 2>&1; echo $?)" "1"
check "run without a prompt fails" \
  "$(AGENTTALK_OPENCODE_BIN="$STUB" "$AGENTTALK" run build "" >/dev/null 2>&1; echo $?)" "1"
check "a missing opencode is reported" \
  "$(AGENTTALK_OPENCODE_BIN="$TMP/nope" AGENTTALK_STATE_DIR="$TMP/state2" \
      "$AGENTTALK" run build "hi" 2>&1 | grep -c "not found")" "1"
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
