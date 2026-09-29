import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One agent's conversation, read straight off the files `bin/agenttalk` keeps
// for it. The session never sees a prompt or a process: it watches two files
// and reports what they say. That is what lets a run keep going after the
// panel is closed, the bar is reloaded, or the shell restarts.
Item {
  id: root

  property string agentId: ""
  readonly property bool valid: agentId !== ""

  readonly property string stateDir: {
    var override = Quickshell.env("AGENTTALK_STATE_DIR")
    if (override) return override
    var xdg = Quickshell.env("XDG_STATE_HOME")
    if (xdg) return xdg + "/agenttalk"
    return Quickshell.env("HOME") + "/.local/state/agenttalk"
  }
  readonly property string dir: stateDir + "/agents/" + agentId

  property var meta: ({})
  property var blocks: []
  property int dropped: 0
  // The raw text behind `blocks`. A block count is not enough to tell two reads
  // apart: clearing a conversation and never having had one both leave zero
  // blocks, and a rewritten block keeps the count too.
  property string eventsRaw: ""
  property string metaRaw: ""
  // The rail's inputs, folded into one string so a change can be compared
  // without watching four bindings.
  property string statusKey: ""

  readonly property bool running: !!(meta && meta.running === true)
  readonly property string workdir: (meta && meta.workdir) ? String(meta.workdir) : ""
  // Whether `workdir` is the one the user picked, as opposed to the directory
  // of the window they happened to be looking at. The panel shows a different
  // label for each, because only a pinned one survives moving to another window.
  readonly property bool workdirPinned: !!(meta && meta.workdirPinned === true)
  // Null until a run has finished once, which is the only difference between
  // "idle" and "never started" in the rail.
  readonly property int exitCode: (meta && meta.exitCode !== undefined && meta.exitCode !== null)
    ? Number(meta.exitCode)
    : -1

  // Fires whenever the transcript grew, so the panel can badge an agent the
  // user is not currently looking at.
  signal transcriptGrew()
  // Fires when the fields the rail groups and orders by change. A binding on
  // `running` would not do: the session object is the same object before and
  // after a run starts, so a map rebuilt only when sessions are added would go
  // on drawing the state the panel opened with.
  signal statusChanged()

  function loadMeta(content) {
    var text = String(content === undefined || content === null ? "" : content)
    if (text === metaRaw) return
    metaRaw = text
    try {
      meta = JSON.parse(text) || {}
    } catch (e) {
      meta = {}
    }
    // Only the rail's inputs are compared, so a session id changing does not
    // rebuild a list the user is looking at for no visible reason.
    var key = [running, workdir, workdirPinned, exitCode].join("|")
    if (key === statusKey) return
    statusKey = key
    statusChanged()
  }

  function loadEvents(content) {
    var text = String(content === undefined || content === null ? "" : content)
    if (text === eventsRaw) return
    var parsed = Model.parseEvents(text)
    eventsRaw = text
    blocks = parsed.blocks
    dropped = parsed.dropped
    transcriptGrew()
  }

  // `loaded` is emitted once, when the file is read for the first time. On its
  // own that makes the panel read these two files exactly once, when it opens:
  // a run that starts, a path that gets pinned and every new event would
  // arrive after that and never be seen until the panel was reopened.
  // `fileChanged` is the only signal that fires afterwards, and `text()` hands
  // back the copy it already has until `reload()` goes and reads the new one.
  FileView {
    path: root.valid ? root.dir + "/meta.json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMeta(text())
    onLoadFailed: root.loadMeta("{}")
    onFileChanged: reload()
  }

  // `panel.jsonl`, not `events.jsonl`. A FileView reads the whole file it is
  // given, and events.jsonl is the complete conversation, which grows with
  // every run and never shrinks. The script keeps panel.jsonl to its last
  // 256 KiB, so this read is bounded by construction no matter how long the
  // conversation gets. events.jsonl still has everything.
  FileView {
    path: root.valid ? root.dir + "/panel.jsonl" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.loadEvents(text())
    onLoadFailed: root.loadEvents("")
    onFileChanged: reload()
  }
}
