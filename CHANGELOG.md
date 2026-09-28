# Changelog

All notable changes to AgentTalk are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/). The version in `manifest.json` is
the only place a version number lives.

## [Unreleased]

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
