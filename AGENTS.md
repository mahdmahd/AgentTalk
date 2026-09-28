# AGENTS.md

Working rules for this repository. Read this before changing anything: most of
it is not a matter of taste, it is what keeps the plugin installable, reviewable
and publishable.

## What this project is

An Omarchy shell plugin: a bar widget (`BarWidget.qml`, `Panel.qml`,
`Session.qml`, `Model.js`) and one shell script (`bin/agenttalk`) that owns every
process and every file. `tools/` holds development helpers, not runtime code.

The contract with the shell is the Omarchy plugin contract, documented at
<https://plugins.omarchy.org/develop.html>. Publishing requirements are at
<https://plugins.omarchy.org/publish.html>, and the marketplace has its own
rules at <https://github.com/omacom/omarchy-plugin-marketplace>.

## Versioning

- The **only** version is `version` in `manifest.json`. Do not keep a version
  anywhere else — no tags in code, no second file, no README badge that has to
  be updated by hand.
- Versions follow [SemVer](https://semver.org):
  - **patch** — bug fixes, no new user-visible behaviour (a QML fix, a shell
    script fix, a wording fix in a notice).
  - **minor** — new user-visible behaviour (a new setting, a new panel action, a
    new `bin/agenttalk` subcommand, a new event shape).
  - **major** — a change that breaks an existing user's setup: a setting that is
    removed or renamed, a state-file format change, a required opencode version.
- Bump the version in the same change that needs it, never in a separate
  "bump version" commit.
- Every user-visible change gets a `CHANGELOG.md` entry under `## [Unreleased]`,
  in the Keep a Changelog style, with the version decided by the rules above.
  Unreleased entries say `TBD` until the bump lands.
- A release is: the version bump, the changelog heading, and a tag. The tag is
  `v<version>` and matches `manifest.json` exactly.

## Git workflow

- **`main` is the trunk.** It is never edited directly, and nothing is ever
  pushed to it except through a pull request.
- Every change starts from an up-to-date `main` on its own branch:
  ```bash
  git fetch origin
  git switch main && git pull --ff-only
  git switch -c <type>/<what-it-does>      # feat/, fix/, docs/, chore/, refactor/
  ```
- Work goes up as a **pull request to `main`**. That is mandatory for every
  change, including one-line fixes: no direct commits on `main`, no force
  pushes, no rewriting trunk history.
- Branch names say what the change does, not who did it. One concern per branch;
  unrelated changes split into separate branches and separate pull requests.
- Commits are written for someone reviewing the diff: what changed, and why it
  had to. Keep the subject short and imperative; put the reasoning in the body
  when it is not obvious from the diff.
- **Never push, publish, tag or open a pull request without the repository owner
  asking for it in that conversation.** Work stays local until then. That
  includes the marketplace: submission happens through the marketplace's own
  issue-driven flow, and only when the owner says so.
- Before proposing a pull request: `omarchy plugin validate .`, `qmllint`,
  `bash -n bin/agenttalk`, `bash tools/test.sh`, and a live check on a real
  Omarchy session if the change touches the panel or the bar widget.

## Conventions that are not negotiable

- **QML never touches a process or a file it did not create.** It calls
  `bin/agenttalk`; the script does the work. If a change needs a new capability,
  add a subcommand to the script first.
- **Quickshell 0.3 specifics.** `StdioCollector.streamFinished` does not fire
  reliably: read a collector's `text` from the process's `onExited` signal
  instead, one `Qt.callLater` tick later. `Process` has no `exitStatus`; the exit
  code arrives as the `onExited` argument. `createObject` does not exist: use
  `Qt.createComponent(Qt.resolvedUrl(...))`.
- **A plugin's own directory is not an import path.** Sibling QML files cannot be
  imported as types; load them with `Loader { source: ... }` or
  `Qt.createComponent(Qt.resolvedUrl(...))`. JS files in the plugin directory
  (`Model.js`, `assets/icon.js`) do import normally.
- **Nothing may be written to the user's home outside the state directory.**
  State lives in `$XDG_STATE_HOME/agenttalk` (`~/.local/state/agenttalk`).
  Hyprland config is only touched by `agenttalk bind` / `agenttalk unbind`, and
  only there.
- **Comments explain why, not what.** The bar is full of small decisions that
  look wrong until you know why; a comment that saves the next reader a
  debugging session earns its place, a comment restating the next line does not.
- **No new runtime dependencies.** The plugin is QML, one POSIX-ish bash script,
  `jq`, and opencode. Anything else has to earn its place.
- Bash: `set -euo pipefail`, quoted expansions, `jq -nc` for JSON, no `eval`.

## Event log

`bin/agenttalk` reduces opencode's stream to a fixed set of event shapes before
the panel ever sees it: `user`, `text`, `tool`, `error`, `session`, `done`.
Add new information as new fields on those events, or as a new event type that
`Model.js` explicitly ignores. Renaming an existing `t` value is a breaking
change and needs a major version.

## The bar icon

The icon is vector path data in `assets/icon.js`, generated from the artwork by
`tools/svg2qml.py` and filled with the bar's own icon colour, so it follows the
theme. Never replace it with a raster image or a coloured asset: a bar icon that
does not match the theme is the bug that started all of this. If the artwork
changes, regenerate the data and keep the file's header comment.

## Layout of a change

- Behaviour change: tests in `tools/test.sh` where the script is involved, and a
  changelog entry.
- QML change: `qmllint`, plus a live check if it is visible.
- Manifest change: `omarchy plugin validate .`, and check the description still
  matches what the plugin does.
- Documentation change: keep the commands copy-pasteable and true. A command in
  the README that does not work is worse than no command.
