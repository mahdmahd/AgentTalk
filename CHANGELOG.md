# Changelog

All notable changes to AgentTalk are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/). The version in `manifest.json` is
the only place a version number lives.

## [Unreleased]

## [2.0.3]

### Fixed

- A single event had no limit of its own, and two things followed from that. The
  worker read each line of opencode's stream whole before measuring anything, so
  one oversized line — a file pasted into a tool result, a repetition that never
  stops — was held in the process that outlives the run. The line is now read in
  pieces with `read -n`, dropped when it reaches the limit, and the transcript
  says an event was too large; the reader is one function used by both loops, so
  the two cannot drift apart again.
- `events.jsonl` grew for as long as the conversation did. It is the whole
  transcript rather than the panel's window, so the cap is generous (8 MiB,
  keeping 4), but it is a cap, and it is enforced before the write like the
  panel's.
- An event's length is now measured in bytes with `wc -c` before anything is
  written, rather than counted in characters with `${#}` or inferred from how much
  the file grew afterwards. `${#}` counts characters, so on a UTF-8 event the
  measured size could be a quarter of the real one.

## [2.0.2]

### Fixed

- The panel's log could exceed its cap for as long as the trim took. The event
  was appended first and the size checked afterwards, so a single event larger
  than the whole cap made the file the panel watches briefly unbounded, and the
  panel reads that file on every change. Room is now made before the write, and
  an event that is larger than the entire cap is not written to the panel's log
  at all: the panel says how large it was and the complete log keeps the event in
  full. A test now measures the largest size the file ever *reached* while a run
  streams an event a hundred times the cap, which is the claim that actually
  matters.
- The worker and the `append` subcommand had two copies of the panel-log
  arithmetic, and they had drifted apart. There is one implementation now, and
  the cap is settled from the event's real size in bytes rather than from
  `${#event}`, which counts characters — so the cap no longer undercounts a
  conversation that is not pure ASCII.

## [2.0.1]

### Fixed

- The panel could read a half-written `meta.json`. `meta.json` was rewritten by
  truncating it and then writing the new content, and the panel watches that file
  the same way it watches the event log, so a read landing in between saw an
  empty file and treated the agent as having no workspace, no session and no
  running state. Every write of the file now goes through a temporary file and a
  rename, which is atomic, so a reader gets the old content or the new one.
- The pinned workspace going missing was not only a panel problem. Three tests
  covering it failed on a loaded CI runner and passed everywhere else, which is
  the signature of a race rather than of a slow machine. The runner now has a
  test that fails if a rewrite is ever readable half-written.

## [2.0.0]

### Changed

- **Breaking:** `agenttalk run` takes the prompt on stdin, not as an argument:
  `agenttalk run build "add a test"` is now `agenttalk run build < "add a test"`.
  A prompt in the argument list is readable by any user on the machine for as
  long as the process lives, so a pasted stack trace, a customer name or a token
  sat in every `ps` until the run ended. Nothing else about `run` changed, and
  the panel was switched over in the same release.
- The prompt also reaches opencode over stdin instead of as its positional
  message, and the transcript line the worker writes for it no longer passes the
  text through `jq`'s argument list either. It travels in a pipe and in one
  owner-only temporary file, which the worker deletes when the run ends.
- The panel now reads `panel.jsonl`, a tail of the event log capped at 256 KiB,
  instead of reading `events.jsonl` whole. `FileView` reads the entire file it
  is given, so a long conversation was read in full on every change to render a
  window that was never that big. `events.jsonl` is unchanged and still holds
  every event. `AGENTTALK_PANEL_LOG_MAX` and `AGENTTALK_PANEL_LOG_KEEP` move the
  cap.
- `AGENTS.md`, the rules this repository is worked under, moved to
  `.github/AGENTS.md`. The plugin is installed by cloning this repository, so
  everything in the root ships to every user, and a root `AGENTS.md` is a file
  that coding agents read and obey without being asked to.

## [1.3.0]

### Added

- The workspace field lists the directories its text matches while you type,
  with the arrows and Enter to pick one. Completion was Tab-only and invisible:
  a no-match and a broken completion looked the same, and the way to tell them
  apart was to press Enter and be told the directory did not exist.
- Dot directories are offered once you type a leading dot, the way a shell
  treats them. They used to turn up in every list, where one of them shifts the
  common prefix of everything behind it.
- The path in the field follows the row you walk to, and a row can be clicked.
  The text and the lit row are one choice shown twice, so scrolling the list and
  watching the field change is what makes them the same control instead of two
  that have to be kept in agreement.
- A path the script refuses comes back into the field that asked for it: the
  text you typed stays, and the reason sits under it. It used to arrive as a
  banner, five seconds after the field had closed — about a path you could no
  longer see, and which you then had to type again to find out why.

### Changed

- Completion matches the stem regardless of case. The panel is not a shell, so
  there is no case-sensitivity muscle memory to lean on, and `agent` used to
  find nothing where `AgentTalk` was sitting right there — in silence, which is
  the most expensive kind of wrong answer in a field.
- Enter asks the script instead of deciding. The list says what exists that
  starts with what you typed, which is a different question from "is this a
  directory", and a field that answers the second one itself is wrong the moment
  the two disagree. Enter takes the lit row where the list names the text, and
  sends the path as typed where it does not; `agenttalk cd` has the last word.
- Completion reads a slash in the stem as a path rather than as part of a name.
  Tab puts a trailing slash on after a unique match, and a stem that cannot match
  anything is silence where the directory is sitting right there.
- `agenttalk cd` says `not a directory` when the path is a file, rather than
  claiming a directory does not exist when it is visibly right there.

### Fixed

- The workspace field no longer loses a keystroke or overwrites itself with a
  stale answer. Tab pressed while a completion was running was dropped, and an
  answer that came back after more was typed replaced the text with a path built
  from the text as it was when the question was asked — both ending in a path
  that does not exist.
- Typing a directory's own name and pressing Tab no longer claims that directory
  does not exist. The trailing slash emptied the list, the empty list read as
  `no directory here matches`, and Enter then refused to send the path it had
  just finished recognising. The empty list now says `nothing here starts with
  that`, which is a statement about the list rather than a verdict on the path,
  and a trailing slash asks what is inside the directory instead of matching
  nothing.

**1.2.0**

### Changed

- The rail is grouped by workspace and ordered by what wants your attention,
  which is what a list of agents could never say on its own. It was opencode's
  agent list in the order opencode returned it, with a type attribute where the
  state should have been: eight agents and two of them mid-run gave you no way
  to tell which two. Rows are now grouped under the directory their next run
  happens in, and ordered unread first, then working, then idle — so the row
  that needs you is the one at the top, and a group leads with its most urgent
  row. An agent that follows the focused window gets a `following the window`
  group of its own rather than borrowing the directory of its last run, which is
  not where it works any more and would move as the pointer crossed windows.
- A row's second line says what the run is doing instead of the agent's `mode`.
  `mode` is a property of the agent type, so it printed the same word on every
  idle row: a line of text that never changed. It is now `working`, `idle`,
  `not started`, `stopped`, `timed out` or `failed` — the last three taken from
  the exit codes the script already records, so a stop and a timeout are not
  reported as failures.
- Setting a working directory in the plugin settings puts the whole rail in one
  group, because it overrides every agent's workspace. Following the focused
  window keeps the agents in one group of their own.

## [1.1.0]

### Added

- Tab completes directories in the workspace field: one match fills it, several
  extend it to what they share, and no match leaves it alone. The listing comes
  from the new `agenttalk complete [dir-prefix] [stem]`, because the panel does
  not read directories itself.
- The prompt takes the keyboard focus the panel is handed on open, because that
  is what the panel is for. Until now the focus sat on the panel's key handler
  instead: nothing you typed appeared and Enter sent an empty prompt, which made
  a working panel look dead.
- A `WORKSPACE` row between the header and the transcript: the path the next
  run happens in, editable in place, plus `window` to follow the focused
  window and `reset` to forget the pin. `agenttalk cd <agent> <path>`,
  `--window` and `--reset` do the same from the shell.
- `user` events in the event log carry the workdir the prompt ran in, so the
  transcript can show it per message.
- The agent's answer gets its own bubble, under the prompt it answers, with the
  workdir stamped above it.
- `agenttalk doctor`, which reports the opencode binary it found, the agents it
  lists and whether the state directory is writable.
- `agenttalk` now looks for opencode where mise, `~/.local/bin` and the usual
  install prefixes put it, instead of trusting `PATH` alone, so the panel finds
  the agents the user actually runs.

### Fixed

- The panel now follows what it is supposed to follow. `meta.json` and
  `events.jsonl` were read once, when the panel opened, and never again: a
  `FileView` emits `loaded` when it reads a file and `fileChanged` when the
  file changes afterwards, and only the first one was handled. So a run that
  started, a path that was pinned and every new event in the transcript
  arrived after the panel was already open and stayed invisible until it was
  reopened, and `New` and `reset` looked broken because they could not change a
  transcript the panel had stopped reading. Both views reload on `fileChanged`.
- A button that cannot do anything says so. `reset` needs a pinned workspace
  and `change…`/`window` need a selected agent, but the shell's `Button` draws
  no disabled state at all, so those actions looked exactly as live as `New`
  and pressing them did nothing at all. They are dimmed while disabled, and the
  path in the `WORKSPACE` row now says that clicking it is what pins a path,
  which is what gives `reset` something to do.
- `agenttalk clear` no longer drops the pinned workspace. It wrote an older
  `meta.json` that had no `workdir` or `workdirPinned`, so forgetting a
  conversation silently forgot where you were working too, and the panel went
  back to following whatever window was focused. The shape of that file is now
  written in one place instead of twice.
- Editing the workspace field starts from the path the next run would use, and
  the first keystroke replaces it. The selection was asked for in the same tick
  as the focus, which left the caret in front of the prefill, so typing spliced
  the new path in front of the old one.
- Stop, New and the workspace actions are the shell's own `Button`. They were a
  `Text` with a `MouseArea`, which has no pressed state and cannot be reached
  from the keyboard, so they read as labels and a click that did work looked
  exactly like a click that did not.
- A run that ends because it was stopped says so. A non-zero `done` event is
  shown in the transcript as `· stopped` for the signals a stop sends, and as
  the exit code for anything else.
- A failing action says what went wrong. Stop and New report success or
  failure in the panel instead of failing silently.
- The bar widget is now a real `BarWidget` entry point, as the plugin contract
  asks. Before this the slot was zero pixels wide and the icon was invisible.
- Agents are detected again. `StdioCollector.streamFinished` does not fire
  reliably on Quickshell 0.3, so the panel read its collectors on the process's
  `onExited` signal instead; the empty agent list was the result of waiting for
  a signal that never came.
- A run no longer reports itself as a failure, and its own output no longer
  covers the transcript.
- Session transcripts are created through `Qt.createComponent`, because
  `createObject` does not exist in Quickshell, and `Session.qml` imports
  `Quickshell` before asking it for the environment.
- The "no agents found" notice disappears once opencode answers.
- `agenttalk bind` writes a combo the shell understands. It normalised the words
  into a single Hyprland-style string, so `agenttalk bind SUPER CTRL A` and a
  bare `agenttalk bind` produce one `o.bind` line in `~/.config/hypr/bindings.lua`
  instead of an argument list Hyprland never sees. The block is replaced, not
  stacked, and `unbind` reports which combo went free.
- `agenttalk doctor` reports `onPath` as a boolean instead of the string
  `"true"`, so `jq` tests on its output do the obvious thing.

### Changed

- The bar icon is the Flaticon "artificial intelligence" artwork as vector path
  data, filled with the bar's own icon colour, so it follows the theme instead of
  being a coloured image pasted into a monochrome bar. Flaticon blocks automated
  downloads, so `assets/icon.svg` is traced from the PNG it serves by the new
  `tools/png2svg.py`, and `tools/svg2qml.py` turns that into the path data.
- The panel hangs off the bar icon (the `KeyboardPanel` arrangement Omarchy uses
  for keyboard-driven popups), and the shell routes summon, toggle and hide to
  the widget.
- `tools/test.sh` covers the script's behaviour against a stubbed opencode, and
  GitHub Actions checks the manifest, the shell scripts and that suite.

## [1.0.0]

Initial release.

### Added

- A bar widget that lists opencode's agents, keeps one conversation per agent
  and lets you send a prompt with Enter.
- `bin/agenttalk` with `agents`, `run`, `stop`, `clear`, `cwd`, `init`, `append`,
  `bind` and `unbind`, and an event log that survives closing the panel,
  reloading the plugin or restarting the shell.
- Settings for auto-approving tool permissions, the default agent and the
  working directory, which defaults to the directory of the focused window.
