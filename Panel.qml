import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The panel half of AgentTalk: agents down the left, the conversation on the
// right, the input at the bottom. `BarWidget.qml` is the manifest entry point
// and loads this file; the shell never loads it directly.
//
// The panel owns no agent logic. It renders the event log `bin/agenttalk`
// writes and asks that script to start, stop or clear a conversation, which
// means a run is detached from the shell on purpose: close the panel, reload
// the bar, restart omarchy-shell, and the agent keeps working. Reopening picks
// up where it left off.
Panel {
  id: root
  moduleName: "io.github.ramackersjp.agenttalk"
  // The bar widget owns the open/close route: the shell hands `summon`,
  // `toggle` and `hide` to the live bar instance, and a per-target IPC handler
  // here would only ever reach whichever monitor claimed the target.
  manageIpc: false

  // Injected by BarWidget.qml. `bar` and `settings` come from the bar host,
  // `anchorItem` is the button the panel hangs off, `hostWidget` is the widget
  // the shell talks to.
  property var anchorItem: null
  property var hostWidget: null

  // ------------------------------------------------------------------ paths

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    while (url.length > 0 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }
  readonly property string cli: pluginDir + "/bin/agenttalk"
  readonly property string home: Quickshell.env("HOME") || ""

  // ----------------------------------------------------------------- colors

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: bar ? bar.urgent : Color.accent
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color urgentColor: Color.urgent
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The theme's own state colours, resolved once: a hover that is a slightly
  // different grey per widget is a hover that looks broken.
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent, urgentColor)
  readonly property color pressedFill: Style.pressedFillFor(foreground, accent, urgentColor)
  readonly property color normalFill: Style.normalFillFor(foreground, accent, urgentColor)
  readonly property color hoverBorder: Style.hoverBorderFor(foreground, accent, urgentColor)
  // `qs.Ui.Button` draws no disabled state: not a dimmer label, not a muted
  // border, not a different cursor. A button that cannot do anything is
  // painted exactly like one that can, so an action that is merely not
  // applicable yet reads as a broken panel. Dimming is the whole fix.
  readonly property real disabledDim: 0.4
  // What a group heading reads as a state: it has none, but the rows in a
  // delegate share their bindings, and a missing object there is an error on
  // every repaint rather than an empty line.
  readonly property var noState: ({label: "", tone: "idle"})

  // ------------------------------------------------------------------ state

  property var agents: []
  property string selectedId: ""
  property int cursorIndex: -1
  property bool cursorActive: false
  property string notice: ""
  // Set while `opencode agent list` comes back empty. Stops the retry timer.
  property bool agentsMissing: false
  // The workspace path is edited in place, so the field only exists while the
  // user is typing in it.
  property bool workspaceEditing: false
  property string workspaceDraft: ""
  // What the typed stem matches, newest answer last, as the paths the panel
  // would store. Paths, not names, so that nothing has to decide twice whether
  // `~/Code/AgentTalk` and `/home/jp/Code/AgentTalk` are the same place, and so
  // that a row can show a directory name without also having to re-derive the
  // directory it is in.
  property var suggestPaths: []
  // -1 means "nothing chosen", which is not the same as "chosen the first one":
  // Enter has to be able to mean "the path I typed" without a row being lit.
  property int suggestIndex: -1
  // "none" only after a question came back empty, which is the only state in
  // which there is something to say about a path that does not exist. It is not
  // derived from `suggestPaths.length` so that the first keystroke, before any
  // answer has arrived, is not reported as a path that cannot be found.
  property string suggestSaid: ""
  // Counts the questions asked of the script. A completion answer is only shown
  // when no newer question has been asked since, which is the whole of the
  // "you typed while find was running" race.
  property int suggestSeq: 0

  // One Session per agent, all of them alive from the start: the bar icon has to
  // know whether anything is working even when this panel was never opened.
  property var sessions: ({})
  property var unread: ({})
  // The rail: group headings and agent rows in one flat list, so one ListView
  // draws the whole thing and the scrollbar stays honest. `railOrder` is the
  // same rows without the headings, because the arrow keys walk agents and
  // must not stop on a label.
  property var rail: []
  property var railOrder: []

  // The cursor's row in the flat list, which the ListView needs for its own
  // currentIndex. Computed from the rail rather than tracked, because the list
  // is rebuilt as a whole every time anything in it changes.
  readonly property int cursorRow: {
    if (cursorIndex < 0 || cursorIndex >= railOrder.length) return -1
    var id = railOrder[cursorIndex]
    for (var i = 0; i < rail.length; i++) {
      if (rail[i].kind === "agent" && rail[i].id === id) return i
    }
    return -1
  }

  readonly property var selected: sessions[selectedId] !== undefined ? sessions[selectedId] : null
  readonly property var blocks: selected && selected.blocks ? selected.blocks : []
  // Messages the transcript is too long to hold, so the count can be said out
  // loud instead of pretending the conversation started here.
  readonly property int dropped: selected ? selected.dropped : 0
  readonly property bool running: !!(selected && selected.running)
  readonly property bool anyRunning: {
    for (var id in sessions) if (sessions[id].running) return true
    return false
  }
  readonly property string workdir: selected ? selected.workdir : ""
  readonly property bool workdirPinned: !!(selected && selected.workdirPinned)
  // The directory a run would use right now: the one the user pinned, else
  // whatever the panel setting forces, else the window they are on.
  readonly property string effectiveWorkdir: configuredWorkDir !== ""
    ? configuredWorkDir
    : (workdirPinned ? workdir : "")

  readonly property bool autoApprove: setting("autoApprove", true) !== false
  readonly property string defaultAgent: String(setting("defaultAgent", ""))
  readonly property string configuredWorkDir: String(setting("workDir", ""))

  onOpenedChanged: {
    if (opened) {
      refreshAgents()
      editor.forceActiveFocus()
    }
  }

  // A forced working directory overrides every agent's workspace, so it moves
  // the whole rail into one group at once.
  onConfiguredWorkDirChanged: rebuildRail()

  Component.onCompleted: refreshAgents()

  // -------------------------------------------------------------- agent list

  function refreshAgents() {
    // Re-running a Process that is still going would drop the answer, so wait
    // for it; the reads are milliseconds.
    if (agentsProcess.running) agentsProcessExhausted.restart()
    else agentsProcess.running = true
  }

  function applyAgents(list) {
    var next = []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      if (!entry.id) continue
      next.push({id: String(entry.id), mode: String(entry.mode || "all")})
    }
    if (next.length === 0) {
      // opencode is the one dependency this plugin has, so say so plainly
      // instead of showing an empty list. agentRetry keeps looking for it:
      // installing opencode while the panel is open is a thing people do.
      notice = "No opencode agents found. Install opencode, then reopen this panel."
      agentsMissing = true
      return
    }
    agentsMissing = false
    // A stale "no agents" banner outlives the problem it described, so drop it
    // as soon as opencode answers.
    if (notice === "No opencode agents found. Install opencode, then reopen this panel.") notice = ""

    agents = next

    var map = {}
    var wanted = []
    for (var j = 0; j < next.length; j++) {
      var id = next[j].id
      var existing = sessions[id]
      if (existing === undefined || existing === null) existing = createSession(id)
      map[id] = existing
      wanted.push(id)
    }
    sessions = map
    fire(["init"].concat(wanted))

    if (map[selectedId] === undefined || selectedId === "") selectedId = pickDefault()
    rebuildRail()
    cursorIndex = Math.max(0, railIndex(selectedId))
  }

  // The rail is derived, never stored: every source of it is already on this
  // object, and a cached copy is a copy that can disagree with the sessions.
  // Rebuilt when an agent appears, when one changes state, and when a badge
  // comes or goes - those are the only three things that move a row.
  function rebuildRail() {
    var built = Model.agentRail(agents, sessions, unread, configuredWorkDir)
    rail = built.rows
    railOrder = built.order
    if (railOrder.length === 0) {
      cursorIndex = -1
      return
    }
    if (cursorIndex < 0 || cursorIndex >= railOrder.length) {
      cursorIndex = Math.max(0, railIndex(selectedId))
    }
  }

  // Where an agent sits in the rail, which is the order the arrow keys walk -
  // not the order opencode listed the agents in.
  function railIndex(id) {
    for (var i = 0; i < railOrder.length; i++) if (railOrder[i] === id) return i
    return -1
  }

  // opencode ships `build` as its general-purpose agent and marks the agents it
  // can start with as primary. The configured default wins, then `build`, then
  // the first primary, then whatever opencode listed first.
  function pickDefault() {
    if (defaultAgent !== "" && indexOfAgent(defaultAgent) >= 0) return defaultAgent
    for (var i = 0; i < agents.length; i++) if (agents[i].id === "build") return "build"
    for (var j = 0; j < agents.length; j++) if (agents[j].mode === "primary") return agents[j].id
    return agents.length > 0 ? agents[0].id : ""
  }

  function indexOfAgent(id) {
    for (var i = 0; i < agents.length; i++) if (agents[i].id === id) return i
    return -1
  }

  function selectAgent(id) {
    if (!id || id === selectedId) return
    // A half-typed path belongs to the agent it was typed for.
    workspaceEditing = false
    selectedId = id
    markRead(id)
  }

  // `createObject` is a QML-tooling helper that Quickshell does not provide,
  // so the session component is compiled once here and instantiated from it.
  readonly property var sessionComponent: Qt.createComponent(Qt.resolvedUrl("Session.qml"))

  function createSession(id) {
    if (!sessionComponent || sessionComponent.status !== Component.Ready) return null
    var session = sessionComponent.createObject(root, {agentId: id})
    if (!session) return null
    session.transcriptGrew.connect(function() { onTranscriptGrew(id) })
    session.statusChanged.connect(function() { onSessionStatus(id) })
    return session
  }

  function onTranscriptGrew(id) {
    // Work that lands while you are reading another agent gets a badge rather
    // than pulling you away from what you were doing.
    if (id === selectedId) {
      markRead(id)
      return
    }
    if (!sessions[id]) return
    unread[id] = (unread[id] || 0) + 1
    unread = Object.assign({}, unread)
    // A badge outranks a running row, so the rail has to be rebuilt with it.
    rebuildRail()
  }

  // A run starting, ending or being pointed at another directory all move rows
  // between groups, and the rail is grouped and ordered by exactly those.
  function onSessionStatus(id) {
    if (railOrder.length === 0) return
    rebuildRail()
  }

  function markRead(id) {
    if (!unread[id]) return
    unread[id] = 0
    unread = Object.assign({}, unread)
    rebuildRail()
  }

  // ------------------------------------------------------------------ input

  function send() {
    var text = editor.text === undefined ? "" : String(editor.text)
    if (text.trim() === "") return
    if (selectedId === "") return

    // One run at a time per agent: two runs would fight over the same session.
    if (running) {
      flash(root.selectedId + " is still working, stop it first")
      return
    }

    editor.text = ""
    markRead(selectedId)

    var args = ["run", selectedId, text]
    if (autoApprove) args.push("--auto")
    if (configuredWorkDir !== "") args.push("--dir", configuredWorkDir)
    report(args)
  }

  function stopRun() {
    if (selectedId === "") return
    var agent = selectedId
    // Stopping is invisible by nature: the answer simply stops coming. Say so,
    // or a working Stop button looks exactly like a broken one.
    report(["stop", agent], function() { flash("stopped " + agent) })
  }

  function clearConversation() {
    if (selectedId === "") return
    var agent = selectedId
    report(["clear", agent], function() { flash("new conversation with " + agent) })
  }

  // ----------------------------------------------------------------- workspace
  //
  // The three ways to choose where the next run happens, all of them a single
  // `agenttalk cd` away. The pin is the panel's own state, kept per agent in
  // meta.json, so it survives a reload and a shell restart.

  // The one place a workspace is stored. It takes an absolute path and hands it
  // to the script; deciding *which* path is the caller's business, so the field
  // can refuse to send anything it could not resolve.
  function commitWorkspace(absolute) {
    if (selectedId === "") return
    var agent = selectedId
    workspaceEditing = false
    suggestPaths = []
    suggestIndex = -1
    if (absolute === "") return
    // The notice names the directory the script stored, not this guess at it.
    report(["cd", agent, absolute], function(out) {
      flash(agent + " will work in " + (out === "" ? absolute : out))
    })
  }

  function useWindowWorkspace() {
    if (selectedId === "") return
    var agent = selectedId
    report(["cd", agent, "--window"], function(out) {
      flash(agent + " will work in " + (out === "" ? "the window you are on" : out))
    })
  }

  function resetWorkspace() {
    if (selectedId === "") return
    var agent = selectedId
    report(["cd", agent, "--reset"], function() { flash(agent + " uses the window you are on") })
  }

  // Put text in the field and react to it. The prefill and every keystroke go
  // through here, so what the field holds and what the list offers cannot drift
  // apart. Assigning `workspaceField.text` by hand is deliberate: the first
  // keystroke takes the `text: workspaceDraft` binding away for good, so the
  // value has to be written on every visit, not just the first one.
  function setWorkspaceDraft(text) {
    workspaceDraft = text
    workspaceField.text = text
    // The old answer describes the old text. Clearing it is also what keeps the
    // "nothing here matches" row from claiming a path is missing during the
    // moment before the new answer arrives.
    suggestPaths = []
    suggestIndex = -1
    suggestSaid = ""
  }

  function editWorkspace() {
    if (selectedId === "") return
    // Prefill with where the next run would go, so changing one segment of a
    // long path does not mean typing the rest of it.
    setWorkspaceDraft(effectiveWorkdir)
    workspaceEditing = true
    // The field only exists after this state change, so the focus has to wait
    // for the next frame, and the selection a frame after that: selectAll()
    // asked for in the same tick as the focus lands on an empty selection,
    // which left the caret at the start of the path. The prefill is absolute
    // and people type `~/...` into it, so a caret in front of it means every
    // keystroke splices a new path onto the old one instead of replacing it.
    Qt.callLater(function() {
      workspaceField.forceActiveFocus()
      Qt.callLater(function() { workspaceField.selectAll() })
      // The list opens on what is already in the field, so the field never sits
      // there with nothing to say about a path that may not exist.
      root.refreshSuggestions()
    })
  }

  function flash(message) {
    notice = message
    noticeTimer.restart()
  }

  // --------------------------------------------------------------- commands

  // Fire and forget: the effect of these is visible in the transcript anyway.
  function fire(args) {
    if (fireProcess.running) return
    fireProcess.command = [cli].concat(args)
    fireProcess.running = true
  }

  // The same, but a failure has to reach the user. An agent that silently
  // refuses to start is the worst outcome this panel has.
  function report(args, ok) {
    if (actionProcess.running) return
    actionProcess.command = [cli].concat(args)
    actionProcess.onOk = ok
    actionProcess.running = true
  }

  // Quickshell's StdioCollector does not reliably emit streamFinished here, so
  // nothing waits on that signal: every Process reads its collectors in
  // onExited instead, one callLater tick after the process is gone so the
  // collectors have been flushed. The collectors reset per run, so a reused
  // Process never sees the previous run's bytes.
  function collect(process, code, ok) {
    Qt.callLater(function() {
      var out = String(process.stdoutCollector.text || "").trim()
      var err = String(process.stderrCollector.text || "").trim()
      var message = out !== "" ? out : err
      if (code !== 0) {
        root.flash(message === "" ? ("agenttalk failed (" + code + ")") : message)
        return
      }
      if (ok) ok(out)
    })
  }

  // `done` and `tools` blocks carry no `text`, and QML warns when a Text gets
  // undefined even while it is hidden, so every transcript line goes through
  // this.
  function blockText(block) {
    if (!block || block.text === undefined || block.text === null) return ""
    return String(block.text)
  }

  function parseAgentList(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  Process {
    id: agentsProcess
    command: [root.cli, "agents"]
    running: false
    property var stdoutCollector: StdioCollector { waitForEnd: true }
    property var stderrCollector: StdioCollector { waitForEnd: true }
    stdout: stdoutCollector
    stderr: stderrCollector
    onExited: function(code) { root.collect(agentsProcess, code, function(out) { root.applyAgents(root.parseAgentList(out)) }) }
  }

  Process {
    id: fireProcess
    command: [root.cli]
    running: false
    property var stdoutCollector: StdioCollector { waitForEnd: true }
    property var stderrCollector: StdioCollector { waitForEnd: true }
    stdout: stdoutCollector
    stderr: stderrCollector
    onExited: function(code) { root.collect(fireProcess, code, function() {}) }
  }

  Process {
    id: actionProcess
    command: [root.cli]
    running: false
    property var stdoutCollector: StdioCollector { waitForEnd: true }
    property var stderrCollector: StdioCollector { waitForEnd: true }
    // Set per call by `report` and cleared here: a command that is dropped
    // because another one is still going must not run its callback later.
    property var onOk: null
    stdout: stdoutCollector
    stderr: stderrCollector
    onExited: function(code) {
      var ok = actionProcess.onOk
      actionProcess.onOk = null
      root.collect(actionProcess, code, function(out) {
        // `run` detaches and prints its session id; that is progress, not a
        // failure, and the transcript shows it anyway. Every other command is
        // quiet on success, so anything it prints is worth surfacing.
        if (out !== "" && actionProcess.subcommand !== "run") root.flash(out)
        if (ok) ok(out)
      })
    }
    // command[0] is the script itself, so the subcommand sits at index 1.
    property string subcommand: command.length > 1 ? command[1] : ""
  }

  Timer {
    id: agentsProcessExhausted
    interval: 200
    onTriggered: if (!agentsProcess.running) root.refreshAgents()
  }

  // opencode is a separate program from the shell, so the first `agent list`
  // can lose a race with a login, a mise activation or a slow disk. Keep asking
  // for a couple of minutes, then stop: an open panel that polls a missing
  // binary forever is worse than a notice the user can act on.
  Timer {
    id: agentRetry
    interval: 5000
    repeat: true
    running: root.agentsMissing && agentRetry.tries < 24
    property int tries: 0
    onTriggered: {
      tries++
      if (!agentsProcess.running) root.refreshAgents()
    }
  }

  Timer {
    id: noticeTimer
    interval: 5000
    onTriggered: root.notice = ""
  }

  // Directory completion for the workspace field. QML asks the script instead
  // of reading a directory itself: it never touches a file it did not create.
  // The collector is read in onExited, per the house rule, and the field is
  // refocused because the field is the panel's only target while editing.
  Process {
    id: completeProcess
    command: [root.cli, "complete", ""]
    // `running` belongs to the Process and a Process runs one command at a
    // time, so the panel keeps its own two facts: whether this answer is still
    // wanted, and what to ask next. Dropping the keystroke that arrived while a
    // `find` was running loses a letter of what someone is typing, and letting
    // the answer through after they have typed more overwrites their text with a
    // path built from the text as it was when the question was asked. Both end
    // in a path that does not exist.
    property bool inFlight: false
    property var wanted: null
    property int askedSeq: 0
    property string base: ""
    property var stdoutCollector: StdioCollector { waitForEnd: true }
    property var stderrCollector: StdioCollector { waitForEnd: true }
    stdout: stdoutCollector
    stderr: stderrCollector

    // Ask for what the field holds now. If something is already running, the
    // answer to that is thrown away and this waits in `wanted` instead.
    function ask(field) {
      var value = field.text
      var slash = value.lastIndexOf("/")
      wanted = {
        base: slash >= 0 ? value.slice(0, slash + 1) : "",
        stem: slash >= 0 ? value.slice(slash + 1) : value,
        seq: ++root.suggestSeq
      }
      start()
    }

    function start() {
      if (inFlight || wanted === null) return
      var query = wanted
      wanted = null
      base = query.base
      command = [root.cli, "complete", query.base].concat(query.stem === "" ? [] : [query.stem])
      askedSeq = query.seq
      inFlight = true
      running = true
    }

    onExited: function() {
      inFlight = false
      // The collector's text is read a tick later, like every other process
      // here: on exit it can still be one line short of what the run wrote.
      var out = String(completeProcess.stdoutCollector.text || "")
      var base = completeProcess.base
      var seq = completeProcess.askedSeq
      // Anything asked for after this question has a newer answer to wait for,
      // so this one is not shown: it describes a field that no longer exists.
      if (seq === root.suggestSeq) Qt.callLater(function() { applyCompletion(base, out) })
      start()
    }
  }

  // The one statement that means "the list should now say what the field says".
  // The debounce timer, the prefill and Tab all go through here, so there is one
  // place where the field and the list are tied together.
  function refreshSuggestions() {
    completeProcess.ask(workspaceField)
  }

  // As you type, not when Tab is pressed. A field that only answers Tab makes
  // "no match" and "broken" look the same, and the only way to find out which
  // one it is used to be to press Enter and be told the directory is missing.
  Timer {
    id: suggestTimer
    interval: 90
    onTriggered: root.refreshSuggestions()
  }

  // Turn what the script returned into paths, and decide what Enter means.
  function applyCompletion(base, out) {
    var names = String(out).trim().split("\n").filter(function(name) { return name !== "" })
    var stem = String(workspaceField.text).slice(base.length)
    var paths = names.map(function(name) { return resolvePath(base + name) })
    suggestPaths = paths
    suggestSaid = names.length === 0 ? "none" : ""
    // A row is only lit when there is a genuine choice to make. With one match,
    // or with the text already naming a directory, Enter has nothing to ask.
    var exact = names.indexOf(stem)
    suggestIndex = exact >= 0 ? exact : (names.length > 1 ? 0 : -1)
  }

  // The path a name under `base` means, made absolute. `agenttalk cd` resolves a
  // relative path against its own working directory, which for a panel is
  // wherever the shell happened to start, so someone typing a workspace into a
  // panel means it from their home directory. That is also where an empty
  // prefix starts from, which is why a bare name lands in $HOME too.
  function resolvePath(text) {
    var home = root.home
    if (text === "~") return home
    if (text.indexOf("~/") === 0) return home + text.substring(1)
    if (text.indexOf("/") === 0) return text
    return home + "/" + text
  }

  // Tab still completes to the common prefix, because that is what Tab does and
  // changing it would only make the muscle memory wrong. What it no longer does
  // is replace the answer with a guess: the list is already on screen, so Tab
  // extends the text and the list narrows itself.
  function completeCommonPrefix() {
    var names = suggestPaths.map(function(path) { return path.slice(path.lastIndexOf("/") + 1) })
    if (names.length === 0) return
    var typed = String(workspaceField.text)
    var stem = names.length === 1 ? names[0] : commonPrefix(names)
    if (stem === "") return
    var slash = typed.lastIndexOf("/")
    var base = slash >= 0 ? typed.slice(0, slash + 1) : ""
    var grown = base + stem + (names.length === 1 ? "/" : "")
    setWorkspaceDraft(grown)
    workspaceField.cursorPosition = grown.length
    workspaceField.forceActiveFocus()
    root.refreshSuggestions()
  }

  // Enter takes the path that was typed when that path is a directory, a chosen
  // row when one was chosen, and the only match when there is exactly one -- so
  // `agent` finds `AgentTalk` instead of being reported as missing. Anything
  // else leaves the field open, because there is no answer to store yet.
  function acceptWorkspace() {
    if (selectedId === "") return
    var typed = resolvePath(String(workspaceField.text).trim())
    var names = suggestPaths.map(function(path) { return path.slice(path.lastIndexOf("/") + 1) })
    var stem = names.length > 0 ? String(workspaceField.text).slice(String(workspaceField.text).lastIndexOf("/") + 1) : ""
    var target = typed
    if (names.indexOf(stem) < 0) {
      if (suggestIndex >= 0 && suggestIndex < suggestPaths.length) {
        target = suggestPaths[suggestIndex]
      } else if (suggestPaths.length === 1) {
        target = suggestPaths[0]
      } else if (suggestPaths.length === 0) {
        // Nothing to store, so nothing is sent: the script would only say the
        // directory does not exist, in a banner, for a field that is still open.
        return
      }
    }
    commitWorkspace(target)
  }

  function moveSuggestion(delta) {
    if (suggestPaths.length === 0) return
    var next = suggestIndex < 0 ? 0 : suggestIndex + delta
    suggestIndex = Math.max(0, Math.min(suggestPaths.length - 1, next))
  }

  function commonPrefix(names) {
    var prefix = names[0]
    for (var i = 1; i < names.length; i++) {
      var name = names[i]
      var shared = 0
      while (shared < prefix.length && shared < name.length && prefix[shared] === name[shared]) shared++
      prefix = prefix.slice(0, shared)
    }
    return prefix
  }

  // -------------------------------------------------------------- navigation

  // The arrow keys walk the rail as the eye does: a group heading is not a
  // place you can land, so Up from the first agent of a group goes to the last
  // agent of the group above it rather than stopping on the label.
  function moveCursor(delta) {
    if (railOrder.length === 0) return
    var index = cursorIndex < 0 ? 0 : cursorIndex + delta
    cursorIndex = Math.max(0, Math.min(railOrder.length - 1, index))
    cursorActive = true
  }

  function cycleAgent(direction) {
    if (railOrder.length === 0) return
    var index = railIndex(selectedId)
    if (index < 0) index = 0
    index = ((index + direction) % railOrder.length + railOrder.length) % railOrder.length
    cursorIndex = index
    selectAgent(railOrder[index])
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= railOrder.length) return
    selectAgent(railOrder[cursorIndex])
    editor.forceActiveFocus()
  }

  function armCursor() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    editor.forceActiveFocus()
  }

  // Panel-to-panel tabbing has to start from the bar widget, not from this
  // item: the bar knows which slot is on screen, and it holds the other
  // panels' open state.
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ------------------------------------------------------------------ chrome

  // Stop, New and the workspace actions are qs.Ui.Button, not hand-rolled
  // Text + MouseArea pairs. The panel is keyboard-driven first: Button gives
  // them a Tab stop and Enter/Space activation, and the theme's own pressed,
  // hover and focus states, so a button cannot end up looking like a label
  // that only some clicks reach.

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    // The panel exists to be typed into, so the prompt takes the focus the
    // shell hands the panel on open. Focusing the catcher instead left the
    // prompt unfocused: the first characters went nowhere, Enter had nothing
    // to send, and a panel that worked read as a panel that was dead.
    focusTarget: editor
    contentWidth: panel.fittedContentWidth(Style.space(680))
    contentHeight: panel.fittedContentHeight(Style.space(440), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing belongs to the editor. The catcher drives the panel until the
      // editor takes focus, then keeps its hands off — which is where the
      // prompt normally sits. The workspace field is a second place keys are
      // meant to land: Enter there commits a path, and it must not reach
      // send() as well.
      blocked: editor.activeFocus || workspaceField.activeFocus

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx === 0) root.moveCursor(dy)
        else root.cycleAgent(dx)
      }
      onActivateRequested: root.armCursor()
      onReturnRequested: root.send()

      RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------------------------------------------------------- agent rail
        Rectangle {
          Layout.preferredWidth: Style.space(172)
          Layout.fillHeight: true
          color: "transparent"

          ColumnLayout {
            anchors.fill: parent
            anchors.rightMargin: Style.spacing.sm
            spacing: Style.spacing.xxs

            Text {
              text: "AGENTS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.6
              Layout.leftMargin: Style.spacing.md
              Layout.bottomMargin: Style.spacing.xs
            }

            ListView {
              id: agentList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: 1
              model: root.rail
              currentIndex: root.cursorRow
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: Item {
                id: agentRow
                required property int index
                required property var modelData

                readonly property bool isGroup: modelData.kind === "group"
                readonly property string agentId: isGroup ? "" : modelData.id
                readonly property bool busy: !isGroup && modelData.running === true
                readonly property bool isSelected: !isGroup && agentId === root.selectedId
                // The cursor counts agents, this list counts headings too, so the
                // two are matched on the row's own slot in the rail rather than
                // on its index here.
                readonly property bool hot: !isGroup && (hoverArea.containsMouse
                  || (root.cursorActive && modelData.slot === root.cursorIndex))
                readonly property int unseen: isGroup ? 0 : modelData.unseen
                // A heading has no state and a row has no label, and hiding a
                // Text does not stop QML from evaluating its bindings: each kind
                // of row reads both through here, or a hidden binding throws on
                // every repaint.
                readonly property string rowLabel: isGroup ? String(modelData.label) : ""
                readonly property var rowState: isGroup ? root.noState : modelData.state

                width: agentList.width
                height: isGroup ? Style.space(22) : Style.space(40)

                // A group heading is the directory its agents will work in, and
                // the only place in the panel that says so for a list of them.
                // Full path, elided from the left: two projects can share a
                // basename, and a heading that cannot tell them apart groups
                // nothing.
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  visible: agentRow.isGroup
                  text: agentRow.rowLabel
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideLeft
                }

                Rectangle {
                  visible: !agentRow.isGroup
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.xs
                  anchors.rightMargin: Style.spacing.xs
                  radius: Style.cornerRadius
                  color: agentRow.isSelected
                    ? root.selectedFill
                    : (agentRow.hot ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Column {
                  visible: !agentRow.isGroup
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: marker.left
                  anchors.rightMargin: Style.spacing.xs
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 1

                  Text {
                    width: parent.width
                    text: agentRow.agentId
                    color: agentRow.isSelected ? root.foreground : Qt.darker(root.foreground, 1.15)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: agentRow.isSelected
                    elide: Text.ElideRight
                  }

                  // What the run is doing, not what the agent is: `mode` is a
                  // property of the agent type, so it printed the same word on
                  // every idle row - a line of text that never changed.
                  Text {
                    width: parent.width
                    text: agentRow.rowState.label
                    color: agentRow.rowState.tone === "working"
                      ? root.accent
                      : (agentRow.rowState.tone === "failed" ? root.urgentColor : root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // The only two things worth showing without reading the row:
                // that it is working, and that it finished while you were away.
                Rectangle {
                  id: marker
                  visible: !agentRow.isGroup
                  width: Math.max(badge.width, Style.space(8))
                  height: width
                  radius: width / 2
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  color: agentRow.busy
                    ? root.accent
                    : (agentRow.unseen > 0 ? Qt.darker(root.foreground, 1.4) : "transparent")

                  Text {
                    id: badge
                    anchors.centerIn: parent
                    visible: !agentRow.busy && agentRow.unseen > 0
                    text: String(agentRow.unseen)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: hoverArea
                  visible: !agentRow.isGroup
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.cursorIndex = agentRow.modelData.slot
                    root.selectAgent(agentRow.agentId)
                    editor.forceActiveFocus()
                  }
                }
              }
            }
          }
        }

        Rectangle {
          Layout.preferredWidth: Math.max(1, Style.space(1))
          Layout.fillHeight: true
          color: root.selectedFill
          opacity: 0.4
        }

        // ------------------------------------------------------ conversation
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.margins: Style.spacing.md
          spacing: Style.spacing.sm

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.sm

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0

              Text {
                Layout.fillWidth: true
                text: root.selectedId === "" ? "No agent" : root.selectedId
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                text: root.running
                  ? "working" + (root.effectiveWorkdir === "" ? "" : " in " + root.effectiveWorkdir)
                  : (root.dropped > 0
                      ? root.dropped + " earlier message" + (root.dropped === 1 ? "" : "s") + " not shown"
                      : "idle")
                color: root.running ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
              }
            }

            Button {
              text: "Stop"
              focusable: true
              foreground: root.urgentColor
              visible: root.running
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.stopRun()
            }

            Button {
              text: "New"
              focusable: true
              visible: root.selectedId !== ""
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.clearConversation()
            }
          }

          // ------------------------------------------------------------ workspace
          //
          // Where the next run happens, and the only way to change it. It sits
          // between the header and the transcript rather than in the header,
          // because it is a path: a path needs room, and a header has none.
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(36)
            color: root.normalFill
            radius: Style.cornerRadius

            RowLayout {
              id: workspaceRow
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.xs
              spacing: Style.spacing.xs

              Text {
                text: "WORKSPACE"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.6
              }

              // The path, or the reason there is not one. Read-only text that
              // looks like text: clicking it turns it into the field below.
              Text {
                id: workspaceLabel
                Layout.fillWidth: true
                Layout.leftMargin: Style.spacing.xs
                // Pinning a path is also the only thing that gives `reset`
                // anything to do, and a dimmed button on its own says no more
                // than a dead one did. So the row that owns the pin says what a
                // click on it is for, right where the user is already looking.
                text: {
                  var where = root.effectiveWorkdir !== ""
                    ? root.effectiveWorkdir
                    : "the directory of the window you are on"
                  return root.workdirPinned ? where : where + "  ·  click to pin a path"
                }
                color: root.effectiveWorkdir === "" ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
                visible: !root.workspaceEditing

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.IBeamCursor
                  onClicked: root.editWorkspace()
                }
              }

              TextField {
                id: workspaceField
                Layout.fillWidth: true
                Layout.leftMargin: Style.spacing.xs
                visible: root.workspaceEditing
                text: root.workspaceDraft
                selectByMouse: true
                background: null
                color: root.foreground
                selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                selectedTextColor: root.foreground
                placeholderText: "~/Code/AgentTalk"
                placeholderTextColor: Qt.darker(root.foreground, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                onAccepted: root.acceptWorkspace()
                // Every keystroke re-asks. The list, not Tab, is what makes a
                // path recognisable while it is being typed.
                onTextEdited: {
                  root.setWorkspaceDraft(text)
                  suggestTimer.restart()
                }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    // Escape closes the list before it gives up the field, so a
                    // half-typed path can be walked away from one step at a time.
                    if (root.suggestPaths.length > 0) {
                      root.suggestPaths = []
                      root.suggestIndex = -1
                    } else {
                      root.workspaceEditing = false
                    }
                    event.accepted = true
                  } else if (event.key === Qt.Key_Tab) {
                    // Tab completes a directory here. While the field holds
                    // the focus the catcher never sees the key, so it cannot
                    // fall through to switching panels.
                    root.completeCommonPrefix()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    root.moveSuggestion(1)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    root.moveSuggestion(-1)
                    event.accepted = true
                  }
                }
              }

              Button {
                text: root.workspaceEditing ? "set" : "change…"
                focusable: true
                active: root.workspaceEditing
                enabled: root.selectedId !== ""
                opacity: enabled ? 1 : root.disabledDim
                onClicked: root.workspaceEditing ? root.acceptWorkspace() : root.editWorkspace()
              }

              Button {
                text: "window"
                focusable: true
                enabled: root.selectedId !== "" && !root.workspaceEditing
                active: !root.workdirPinned && !root.workspaceEditing
                opacity: enabled ? 1 : root.disabledDim
                onClicked: root.useWindowWorkspace()
              }

              Button {
                text: "reset"
                focusable: true
                enabled: root.workdirPinned && !root.workspaceEditing
                opacity: enabled ? 1 : root.disabledDim
                onClicked: root.resetWorkspace()
              }
            }

            // The directories the typed stem matches, as they are found. An
            // overlay rather than rows in the layout, because the transcript is
            // right underneath and moving it every keystroke is worse than
            // covering it while a field is open.
            Rectangle {
              id: suggestBox
              z: 20
              visible: root.workspaceEditing && (root.suggestPaths.length > 0 || root.suggestSaid === "none")
              anchors.top: workspaceRow.bottom
              anchors.topMargin: Style.spacing.xs
              anchors.left: workspaceField.left
              anchors.right: workspaceField.right
              // Long enough for the choices, short enough that a big directory
              // cannot push the field off the panel. Clamped here rather than
              // on the list, which has no such property: the list fills the box
              // and scrolls once the box stops growing.
              height: Math.min(suggestList.contentHeight, Style.space(160)) + 2
              color: root.normalFill
              radius: Style.cornerRadius
              border.width: 1
              border.color: root.hoverBorder

              ListView {
                id: suggestList
                anchors.fill: parent
                anchors.margins: 1
                clip: true
                spacing: 0
                model: root.suggestPaths
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                  id: suggestRow
                  required property int index
                  required property var modelData
                  width: suggestList.width
                  height: Style.space(26)

                  Rectangle {
                    anchors.fill: parent
                    color: suggestRow.index === root.suggestIndex ? root.accent : "transparent"
                    opacity: suggestRow.index === root.suggestIndex ? 0.18 : 1
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    // The directory on its own. The path it is in is already in
                    // the field, and repeating it in every row is the part of a
                    // file dialog that makes it unreadable.
                    text: suggestRow.modelData.slice(suggestRow.modelData.lastIndexOf("/") + 1)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }
            }

            // The one thing the field has to say when nothing matched. It lives
            // in the list rather than in a banner, because the banner is where
            // "no such directory" used to arrive: five seconds, gone, and for a
            // path that was never sent in the first place.
            Text {
              id: suggestNone
              z: 20
              visible: root.workspaceEditing && root.suggestPaths.length === 0 && root.suggestSaid === "none"
              anchors.top: workspaceRow.bottom
              anchors.topMargin: Style.spacing.xs
              anchors.left: workspaceField.left
              anchors.leftMargin: Style.spacing.sm
              anchors.right: workspaceField.right
              anchors.rightMargin: Style.spacing.sm
              height: Style.space(26)
              verticalAlignment: Text.AlignVCenter
              text: "no directory here matches"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
              id: transcript
              anchors.fill: parent
              clip: true
              spacing: Style.spacing.sm
              model: root.blocks
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              // Stay at the newest message unless the user scrolled up to read
              // something: a running agent would otherwise yank the view away.
              property bool pinned: true
              onCountChanged: if (pinned) Qt.callLater(positionViewAtEnd)
              onAtYEndChanged: pinned = atYEnd

              delegate: Item {
                id: block
                required property int index
                required property var modelData

                width: transcript.width
                height: body.implicitHeight

                Column {
                  id: body
                  width: parent.width
                  spacing: Style.spacing.xs

                  // what you said, in the directory you said it in
                  Rectangle {
                    visible: block.modelData.kind === "user"
                    width: Math.min(parent.width, Math.max(prompt.implicitWidth, stamp.implicitWidth) + Style.space(28))
                    height: prompt.implicitHeight
                      + (stamp.visible ? stamp.implicitHeight + Style.spacing.xs : 0)
                      + Style.spacing.md
                    anchors.right: parent.right
                    color: root.selectedFill
                    radius: Style.cornerRadius

                    // The workdir belongs to this question, not to the panel:
                    // the workspace bar can have changed three times since.
                    Text {
                      id: stamp
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.sm
                      visible: block.modelData.workdir !== undefined && block.modelData.workdir !== ""
                      text: "in " + block.modelData.workdir
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideLeft
                    }

                    Text {
                      id: prompt
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      anchors.margins: Style.spacing.sm
                      text: root.blockText(block.modelData)
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                    }
                  }

                  // what the agent said, on a surface of its own: the quiet
                  // side of the conversation against the user's bright one.
                  Rectangle {
                    visible: block.modelData.kind === "text"
                    width: Math.min(parent.width, answer.implicitWidth + Style.space(28))
                    height: answer.implicitHeight + Style.spacing.md
                    color: root.hoverFill
                    radius: Style.cornerRadius

                    Text {
                      id: answer
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.sm
                      text: root.blockText(block.modelData)
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                    }
                  }

                  // what the agent did
                  Repeater {
                    model: block.modelData.kind === "tools" ? block.modelData.items : []

                    Text {
                      required property var modelData
                      width: parent.width
                      text: (modelData.status === "completed" ? "✓ "
                            : (modelData.status === "error" ? "✗ " : "… "))
                        + modelData.tool
                        + (modelData.title === "" ? "" : "  " + modelData.title)
                      textFormat: Text.PlainText
                      color: modelData.status === "error" ? root.urgentColor : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  // how the run ended, when it did not end the way it should
                  Text {
                    visible: block.modelData.kind === "done" && block.modelData.code !== 0
                    width: parent.width
                    text: (block.modelData.code === 143 || block.modelData.code === 130)
                      ? "· stopped"
                      : "· the run ended with code " + block.modelData.code
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  // what went wrong
                  Text {
                    visible: block.modelData.kind === "error"
                    width: parent.width
                    text: "⚠  " + root.blockText(block.modelData)
                    textFormat: Text.PlainText
                    color: root.urgentColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                  }
                }
              }

              // Nothing on screen yet: one line saying what this panel is for.
              Text {
                anchors.centerIn: parent
                visible: transcript.count === 0
                width: parent.width - Style.space(32)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.selectedId === ""
                  ? "No opencode agents found. Install opencode, then reopen this panel."
                  : "Say what you want, or paste the error you just hit, and "
                    + root.selectedId + " starts on it."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // input
          BorderSurface {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(78)
            color: Style.controlFill(editor.activeFocus, false, root.foreground, root.accent)
            borderSpec: Border.controlSpec(
              editor.activeFocus ? "focus" : "normal", root.foreground, root.accent)
            radius: Style.cornerRadius

            TextArea {
              id: editor
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              wrapMode: TextArea.Wrap
              selectByMouse: true
              background: null
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, root.accent)
              selectedTextColor: root.foreground
              placeholderText: root.running
                ? root.selectedId + " is working…"
                : "Ask for a change, or paste the error you just hit. Enter sends."
              placeholderTextColor: Qt.darker(root.foreground, 1.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (event.modifiers & Qt.ShiftModifier) return
                  root.send()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.switchPanel(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.notice !== ""
            text: root.notice
            color: root.urgentColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
