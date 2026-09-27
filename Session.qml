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

  readonly property bool running: !!(meta && meta.running === true)
  readonly property string workdir: (meta && meta.workdir) ? String(meta.workdir) : ""
  // Whether `workdir` is the one the user picked, as opposed to the directory
  // of the window they happened to be looking at. The panel shows a different
  // label for each, because only a pinned one survives moving to another window.
  readonly property bool workdirPinned: !!(meta && meta.workdirPinned === true)

  // Fires whenever the transcript grew, so the panel can badge an agent the
  // user is not currently looking at.
  signal transcriptGrew()

  function loadMeta(content) {
    var text = String(content === undefined || content === null ? "" : content)
    if (text === metaRaw) return
    metaRaw = text
    try {
      meta = JSON.parse(text) || {}
    } catch (e) {
      meta = {}
    }
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

  FileView {
    path: root.valid ? root.dir + "/meta.json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMeta(text())
    onLoadFailed: root.loadMeta("{}")
  }

  FileView {
    path: root.valid ? root.dir + "/events.jsonl" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.loadEvents(text())
    onLoadFailed: root.loadEvents("")
  }
}
