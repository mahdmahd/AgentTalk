# AgentTalk

Talk to your [opencode](https://opencode.ai) agents from a panel in the Omarchy
bar. One click on the bar icon opens your agents: type a task or paste the error
you just hit, pick the agent, press Enter, and watch it work. The conversation
keeps going while you close the panel, change your theme, or restart your shell.

![The AgentTalk panel](preview.png)

## Requirements

- [Omarchy](https://omarchy.org) with a running `omarchy-shell`
- [opencode](https://opencode.ai). The `PATH` answers first; failing that the
  script looks where opencode installs itself — `~/.local/bin`, `~/.opencode/bin`,
  a mise shim, `/usr/local/bin`, `/usr/bin`, and any version mise has installed.
  `AGENTTALK_OPENCODE_BIN` replaces that search, and a value containing a `/` is
  taken as it stands, so a path that is wrong is an error rather than a silent
  fall back to something else.
- `jq`, which the script uses for every piece of JSON it reads or writes. It is a
  dependency of Omarchy itself, so it is already installed; it is named here
  because a plugin that quietly needs a tool is worse than one that says so.
- bash and the usual POSIX tools: `find`, `mktemp`, `awk`, `sed`, `readlink`,
  `timeout`. `hyprctl` is asked where the focused window is working, and without
  it every agent falls back to your home directory.

AgentTalk needs no build step, no service, and no second Quickshell process: it
is a bar widget and one shell script, both of which ship inside the plugin and
run in the shell process you already have. It writes to your home in one place,
`~/.local/state/agenttalk`, and touches your Hyprland config only if you run
`agenttalk bind` yourself.

## Install

```bash
omarchy plugin add https://github.com/ramackersjp/AgentTalk.git --enable
```

`--enable` asks which section the widget goes in and offers `right`, which is
what the manifest asks for. Move it wherever you like afterwards, or change what
it shows:

```bash
omarchy bar move io.github.ramackersjp.agenttalk --section center
```

`bin/agenttalk` is what the panel itself calls, and it is not on your `PATH`.
Put it there once if you want the command line; the panel does not need this.

```bash
ln -s ~/.config/omarchy/plugins/io.github.ramackersjp.agenttalk/bin/agenttalk \
  ~/.local/bin/agenttalk
```

Verify it found opencode:

```bash
agenttalk doctor
```

## Remove

```bash
omarchy plugin remove io.github.ramackersjp.agenttalk
```

It asks before it removes anything; `--yes` answers for you.

Your conversations live in `~/.local/state/agenttalk` and are not touched by
removing the plugin. Delete that directory to forget them.

## Using it

| You want to | Do this |
| --- | --- |
| Open the panel | Click the bar icon, or run `omarchy-shell shell summon io.github.ramackersjp.agenttalk` |
| Talk to an agent | Type. The prompt is focused when the panel opens; Enter sends, Shift+Enter adds a line |
| Pick another agent | Click it on the left. The prompt keeps the keyboard, so the arrows move the caret, not the agent list |
| Start a fresh conversation | `New`, in the header. The workspace stays where you put it |
| Stop a running agent | `Stop`, in the header, while the agent is working |
| Change where the next run happens | The `WORKSPACE` row: click the path, or `change…`, to type one; `window` to follow the focused window; `reset` to forget the pin |
| Close the panel | Escape, or click outside it |

One conversation per agent, and they are independent: a `build` run keeps going
while you talk to `plan`. The default agent is picked for you — your configured
default, then opencode's `build`, then the first agent opencode marks as
primary, and only then the first one it lists.

The rail on the left is grouped by the directory each agent will work in, and
ordered by what wants your attention: something you have not read yet, then
something working, then the rest. An agent that follows the focused window
sits in a `following the window` group until you pin a path to it.

### Choosing a workspace

The `WORKSPACE` row is where the next run of the selected agent happens.
Clicking the path — or `change…` — turns the row into a field, and the button
reads `set` while you type. The field then lists the **directories** its text
matches, as you type, so a path you only half remember is on screen before you
commit to it:

- `Up` and `Down` walk the list, and the field text follows the row you land on
- `Enter` takes what the field says: the lit row, the only match, or the text
  itself when it already names a directory
- `Tab` extends to the common prefix, which is what Tab does everywhere else; on
  a single match it fills the name and puts a `/` on the end, because that is
  then the next thing to type
- matching ignores case, so `agent` finds `AgentTalk`
- the mouse wheel walks the list, and a row can be clicked
- a trailing `/` asks what is inside a directory
- a path that does not start at `/` is read from your home directory, because
  the panel has no directory of its own to read it from
- a list that finds nothing says `nothing here starts with that`, which is a
  statement about the list and not a verdict on the path

`Escape` closes the list first, and leaves the field only on a second press. A
path the script refuses stays in the field with the reason under it — `not a
directory` for a file, `no such directory` for a name that is not there — so a
typo is something you read and correct rather than something you type a second
time to find out what was wrong with it.

### Settings

The shell renders no settings form for a bar widget, so there is nothing to
right-click into. Set a value from the terminal:

```bash
omarchy bar set io.github.ramackersjp.agenttalk defaultAgent plan
```

| Setting | Default | What it does |
| --- | --- | --- |
| `autoApprove` | `true` | Auto-approves the permissions you have not explicitly denied. Turn it off and a run halts at the first one instead, until you answer it in a terminal. |
| `defaultAgent` | *(empty)* | Agent selected when the panel opens. Empty picks `build`, then the first primary agent opencode reports, then the first one it lists. |
| `workDir` | *(empty)* | Where agents run. Empty means "the directory of the window you are focused on". |

A boolean needs `--json`, or it is stored as the text `false` and the panel goes
on reading it as true:

```bash
omarchy bar set io.github.ramackersjp.agenttalk autoApprove false --json
```

`workDir` wins over the `WORKSPACE` row: the panel passes it to every run, so an
agent you pinned a path for still runs there, and the whole rail moves into one
group. Empty it to get the per-agent workspace back.

### Keybinding

```bash
agenttalk bind SUPER CTRL A     # SUPER + CTRL + A opens the panel
agenttalk bind                  # the default, SUPER + A
agenttalk bind --print          # print the block instead of writing it
agenttalk unbind                # remove it
```

The binding is written into `~/.config/hypr/bindings.lua` as one marked block,
so `agenttalk unbind` can take it away again and your own lines are left alone.
Hyprland is reloaded for you, so the key works straight away.

## The icon

The bar icon is [Flaticon's "artificial intelligence" symbol][flaticon], kept as
vector path data in `assets/icon.js` and filled with the colour your bar is
using for icons at that moment. That is why it does not look pasted on: it
follows light and dark themes, accent colours and bar sizes, exactly like the
Nerd Font icons around it.

`assets/icon.svg` is the vector source, and it was traced from the PNG that
Flaticon serves, because that site blocks automated downloads. `tools/png2svg.py`
does the tracing and `tools/svg2qml.py` turns the result into `assets/icon.js`; a
raster image is never what the bar draws, so a bar icon that does not match the
theme is the bug this whole arrangement exists to prevent. A Nerd Font agent
glyph is still in the widget as a fallback, so the slot is never empty if the
artwork is ever missing.

[flaticon]: https://www.flaticon.com/free-icon/artificial-intelligence_7007219?term=ai+symbol&page=1&position=32&origin=tag&related_id=7007219

## How it works

```
BarWidget.qml    the bar icon; loads the panel and keeps it alive
Panel.qml        agents, transcript, input; a view, nothing more
Session.qml      one agent's conversation, read from two files
Model.js         turns the event log into transcript blocks
bin/agenttalk    agents, runs, process groups, JSON normalisation, keybinding
```

`bin/agenttalk` owns everything that touches a process or the disk, so the panel
has no privileged logic and the awkward parts (process groups, JSON
normalisation, working-directory resolution) can be tested from a terminal. A
run is detached and appends to an event log, which is why it survives closing
the panel, reloading the plugin or restarting the shell. `$STATE` below is the
state directory, `agenttalk state-dir` prints it:

```
$STATE/agents/<agent>/meta.json     session id, workdir, pid, exit code
$STATE/agents/<agent>/events.jsonl  one normalised event per line, the whole
                                    conversation, up to 8 MiB
$STATE/agents/<agent>/panel.jsonl   the tail of that log, capped in bytes, and
                                    the only one the panel ever reads
$STATE/agents/<agent>/stderr.log    raw stderr of the last run
```

Two logs, on purpose. The panel reads its state with `FileView`, which reads
the whole file it is pointed at, and a conversation that has run all afternoon
is bigger than any transcript window. `panel.jsonl` is that log's last 256 KiB,
which bounds what the panel loads however long the conversation gets;
`events.jsonl` still holds every event, if you want to read one with `jq`.

Every cap holds at every moment, not just once the next event arrives: room is
made in the file *before* the new event is written, because the panel reads that
file the instant it changes. `events.jsonl` is bounded the same way, at 8 MiB,
because a log nobody reads growing for as long as the conversation does is not
the whole conversation, it is a leak.

A single event is bounded too, at 64 KiB, and that one is enforced on the *read*:
opencode's stream is taken a line at a time, and a model that answers with one
enormous line — a file pasted into a tool result, a repetition that never stops —
would otherwise have that line held in the worker, which outlives the run. So the
line is read in pieces, dropped when it reaches the limit, and the transcript
says an event was too large instead. Two things follow from that. A single event
larger than the whole 256 KiB cannot be shown either: the panel says how large it
was, and the event is in `events.jsonl` like everything else. And nothing is
really lost by any of this — opencode keeps the full conversation in its own
session, and these are the logs AgentTalk makes for reading, not a record of
what happened.

Events are normalised to a handful of shapes — `user`, `text`, `tool`, `error`,
`session`, `done` — so the panel never has to know opencode's internals. It
also means a future opencode release cannot break the transcript by renaming a
field.

## Command line

The same script the panel uses works in a terminal, which is handy when
something looks wrong:

```bash
agenttalk agents                        # agents as JSON
agenttalk run build < "add a test"      # start a turn, prompt on stdin
agenttalk run build --dir ~/Code/project < "add a test"
agenttalk run build --new < "add a test"  # new session instead of this one
agenttalk stop build                    # stop it
agenttalk clear build                   # forget the conversation, keep the workspace
agenttalk cwd                           # working directory of the focused window
agenttalk cd build ~/Code/project       # where that agent works from now on
agenttalk cd build --window             # follow the focused window again
agenttalk cd build --reset              # forget the pinned path
agenttalk complete Code/ Age            # directories, for the workspace field
agenttalk doctor                        # what the plugin can find
agenttalk state-dir                     # where the conversations live
```

`run` also takes `--auto`, which is what the `autoApprove` setting passes: it
auto-approves the permissions you have not explicitly denied, and a run without
it stops at the first one it has not been told about. A turn continues the
agent's session unless `--new` says otherwise, and one agent runs at a time: a
second `run` for an agent that is already working is refused rather than fought
over.

The prompt goes in on stdin, never as an argument, and that is the only way
`run` takes it. Process arguments are readable by any user on the machine while
the process lives, so a prompt there would put whatever you typed — a bug
report, a token, the name of a customer — into every `ps` for the length of the
run. A pipe is nobody else's business. The script hands the same prompt to
opencode the same way, and while a run is in flight it is also in one private
temporary file under the agent's own directory, which the worker deletes when
the run ends.

`complete` and `init` are what the panel calls underneath: the listing under the
workspace field, and the check that an agent's session directory and its files
exist before anything tries to read them. Neither is something you need to
run by hand.

`cd` is what the `WORKSPACE` row calls, and it is the one to reach for when the
panel and the terminal disagree about where an agent works.

Without the symlink, call it by path:
`~/.config/omarchy/plugins/io.github.ramackersjp.agenttalk/bin/agenttalk doctor`.

What the script reads from the environment:

| Variable | Meaning |
| --- | --- |
| `AGENTTALK_OPENCODE_BIN` | opencode binary to use, in place of the search above |
| `AGENTTALK_STATE_DIR` | state directory override |
| `AGENTTALK_TIMEOUT` | seconds before a run is killed (default `3600`) |
| `AGENTTALK_PANEL_LOG_MAX` | bytes `panel.jsonl` may reach (default `262144`) |
| `AGENTTALK_PANEL_LOG_KEEP` | bytes kept when the file has to make room (default `131072`) |
| `AGENTTALK_EVENT_MAX` | bytes one event may reach, read and kept (default `65536`) |
| `AGENTTALK_EVENTS_LOG_MAX` | bytes `events.jsonl` may reach (default `8388608`) |
| `AGENTTALK_EVENTS_LOG_KEEP` | bytes kept when that file has to make room (default `4194304`) |
| `HYPRLAND_CONFIG_DIR` | Hyprland config directory (default `~/.config/hypr`) |
| `XDG_STATE_HOME` | parent of the state directory when `AGENTTALK_STATE_DIR` is unset |

## Troubleshooting

**The panel says `No opencode agents found`.** opencode is not installed, or it
is somewhere the script does not look. `agenttalk doctor` prints the path it
found, the version it reports, whether that path came from the `PATH` and
whether the state directory is writable. The usual places are already searched,
so if opencode lives somewhere else entirely, point the script at it:

```bash
AGENTTALK_OPENCODE_BIN=/path/to/opencode agenttalk doctor
```

A value with a `/` in it is used as it stands and nothing else is tried, so a
wrong one is an error rather than a quiet fall back.

**A setting you changed did not take.** `omarchy bar set` stores whatever you
type as text unless you pass `--json`, so `autoApprove false` lands in
`shell.json` as `"false"` — a string, which the panel reads as true. The fix is
in [Settings](#settings); the symptom is a setting that looks set and is not.

**The workspace list stays empty although the directory is there.** It lists
directories, never files. A bare name is read from your home directory, so `Code`
means `~/Code` and not wherever the panel happens to sit; `~` starts at your home
directory too. A trailing `/` asks what is inside a directory, a leading dot
brings the hidden ones into the list, and matching ignores case — `agent` finds
`AgentTalk`, but neither finds a file.

**A long transcript starts halfway through.** The panel draws the last 400
blocks of a conversation and says how many messages it left out, so an old
conversation does not have to be read to be useless. `agenttalk clear` starts a
new one.

**A run takes a long time to say anything.** opencode snapshots the working
directory before its first turn, and that is slow in a large directory. If the
focused window is your home directory, set `workDir` to the project you are
actually working on.

**The panel is empty after editing the plugin.** `omarchy-restart-shell`. The
shell rescans `~/.config/omarchy/plugins/` when something in it changes, but a
bar widget that is already mounted is not always reinstantiated, so the restart
is what you can rely on.

## Development

```bash
omarchy plugin validate .              # manifest against the shell's schema
qmllint -I "$OMARCHY_PATH/shell" *.qml # QML, with Omarchy's imports resolved
bash -n bin/agenttalk                  # the bridge script
bash tools/test.sh                     # behaviour tests for the script and Model.js
```

`qmllint` needs the `qs.*` imports that only exist in an Omarchy install, so it
runs on your machine rather than in CI. The workflow checks the manifest, that
both shell scripts parse, `tools/svg2qml.py`, `tools/test.sh` and that the
changelog has an `## [Unreleased]` section. See
[.github/AGENTS.md](.github/AGENTS.md) for the rules this repository is worked
under. It lives in `.github/` on purpose: the plugin is installed by cloning
this repository, so anything in the root ships to every user, and a root
`AGENTS.md` is a file that coding agents read on their own.

## License

MIT — see [LICENSE](LICENSE). The bar icon artwork is from
[Flaticon](https://www.flaticon.com/free-icon/artificial-intelligence_7007219?term=ai+symbol&page=1&position=32&origin=tag&related_id=7007219)
and is credited there; the code that draws it is part of this repository.
