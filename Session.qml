import QtQuick
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

  readonly property bool running: !!(meta && meta.running === true)
  readonly property string workdir: (meta && meta.workdir) ? String(meta.workdir) : ""

  // Fires whenever the transcript grew, so the panel can badge an agent the
  // user is not currently looking at.
  signal transcriptGrew()

  function loadMeta(content) {
    var parsed = {}
    try {
      parsed = JSON.parse(String(content === undefined || content === null ? "" : content)) || {}
    } catch (e) {
      parsed = {}
    }
    meta = parsed
  }

  function loadEvents(content) {
    var parsed = Model.parseEvents(content)
    if (parsed.blocks.length === blocks.length && parsed.dropped === dropped) return
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
