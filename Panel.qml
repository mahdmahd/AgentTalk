import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The whole product lives in one file: a bar button, and the panel it opens.
// Agents down the left, the conversation on the right, the input at the bottom.
//
// The panel owns no agent logic. It renders the event log `bin/agenttalk`
// writes and asks that script to start, stop or clear a conversation, which
// means a run is detached from the shell on purpose: close the panel, reload
// the bar, restart omarchy-shell, and the agent keeps working. Reopening picks
// up where it left off.
Panel {
  id: root
  moduleName: "io.github.ramackersjp.agenttalk"
  ipcTarget: "io.github.ramackersjp.agenttalk"

  // ------------------------------------------------------------------ paths

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    while (url.length > 0 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }
  readonly property string cli: pluginDir + "/bin/agenttalk"

  // ----------------------------------------------------------------- colors

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: bar ? bar.urgent : Color.accent
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color urgentColor: Color.urgent
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ state

  property var agents: []
  property string selectedId: ""
  property int cursorIndex: -1
  property bool cursorActive: false
  property string notice: ""

  // One Session per agent, all of them alive from the start: the bar icon has to
  // know whether anything is working even when this panel was never opened.
  property var sessions: ({})
  property var unread: ({})

  readonly property var selected: sessions[selectedId] !== undefined ? sessions[selectedId] : null
  readonly property var blocks: selected && selected.blocks ? selected.blocks : []
  readonly property bool running: !!(selected && selected.running)
  readonly property bool anyRunning: {
    for (var id in sessions) if (sessions[id].running) return true
    return false
  }
  readonly property string workdir: selected ? selected.workdir : ""

  readonly property bool autoApprove: setting("autoApprove", true) !== false
  readonly property string defaultAgent: String(setting("defaultAgent", ""))
  readonly property string configuredWorkDir: String(setting("workDir", ""))

  onOpenedChanged: {
    if (opened) {
      refreshAgents()
      editor.forceActiveFocus()
    }
  }

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
      notice = "No opencode agents found. Is opencode installed and on PATH?"
      return
    }

    agents = next

    var map = {}
    var wanted = []
    for (var j = 0; j < next.length; j++) {
      var id = next[j].id
      map[id] = sessions[id] !== undefined ? sessions[id] : createSession(id)
      wanted.push(id)
    }
    sessions = map
    fire(["init"].concat(wanted))

    if (selectedId === "" || map[selectedId] === undefined) selectedId = pickDefault()
    cursorIndex = Math.max(0, indexOfAgent(selectedId))
  }

  function pickDefault() {
    if (defaultAgent !== "" && indexOfAgent(defaultAgent) >= 0) return defaultAgent
    for (var i = 0; i < agents.length; i++) if (agents[i].id === "build") return "build"
    return agents.length > 0 ? agents[0].id : ""
  }

  function indexOfAgent(id) {
    for (var i = 0; i < agents.length; i++) if (agents[i].id === id) return i
    return -1
  }

  function selectAgent(id) {
    if (!id || id === selectedId) return
    selectedId = id
    markRead(id)
  }

  function createSession(id) {
    var session = createObject("Session.qml", root, {agentId: id})
    session.transcriptGrew.connect(function() { onTranscriptGrew(id) })
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
  }

  function markRead(id) {
    if (!unread[id]) return
    unread[id] = 0
    unread = Object.assign({}, unread)
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
    report(["stop", selectedId])
  }

  function clearConversation() {
    if (selectedId === "") return
    report(["clear", selectedId])
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
  function report(args) {
    if (actionProcess.running) return
    actionProcess.command = [cli].concat(args)
    actionProcess.running = true
  }

  Process {
    id: agentsProcess
    command: [root.cli, "agents"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = []
        try {
          parsed = JSON.parse(text())
        } catch (e) {
          parsed = []
        }
        root.applyAgents(Array.isArray(parsed) ? parsed : [])
      }
    }
  }

  Process {
    id: fireProcess
    command: [root.cli]
    running: false
  }

  Process {
    id: actionProcess
    command: [root.cli]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        if (exitCode === 0) return
        var message = text().trim()
        root.flash(message === "" ? ("agenttalk failed (" + exitCode + ")") : message)
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text().trim() !== "") root.flash(text().trim())
    }
  }

  Timer {
    id: agentsProcessExhausted
    interval: 200
    onTriggered: if (!agentsProcess.running) root.refreshAgents()
  }

  Timer {
    id: noticeTimer
    interval: 5000
    onTriggered: root.notice = ""
  }

  // -------------------------------------------------------------- navigation

  function moveCursor(delta) {
    if (agents.length === 0) return
    var index = cursorIndex < 0 ? 0 : cursorIndex + delta
    cursorIndex = Math.max(0, Math.min(agents.length - 1, index))
    cursorActive = true
  }

  function cycleAgent(direction) {
    if (agents.length === 0) return
    var index = indexOfAgent(selectedId)
    if (index < 0) index = 0
    index = ((index + direction) % agents.length + agents.length) % agents.length
    cursorIndex = index
    selectAgent(agents[index].id)
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= agents.length) return
    selectAgent(agents[cursorIndex].id)
    editor.forceActiveFocus()
  }

  function armCursor() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    editor.forceActiveFocus()
  }

  // ------------------------------------------------------------------ chrome

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-robot: an agent, not a terminal.
    text: "\uf06a9"
    active: root.anyRunning
    tooltipText: root.anyRunning
      ? "AgentTalk — an agent is working"
      : "AgentTalk — talk to your agents"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(680))
    contentHeight: panel.fittedContentHeight(Style.space(440), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing belongs to the editor. The catcher drives the panel until the
      // editor takes focus, then keeps its hands off.
      blocked: editor.activeFocus

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
              model: root.agents
              currentIndex: root.cursorIndex
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: Item {
                id: agentRow
                required property int index
                required property var modelData

                readonly property string agentId: modelData.id
                readonly property var session: root.sessions[agentId] !== undefined ? root.sessions[agentId] : null
                readonly property bool busy: !!(session && session.running)
                readonly property bool isSelected: agentId === root.selectedId
                readonly property bool hot: hoverArea.containsMouse
                  || (root.cursorActive && index === root.cursorIndex)
                readonly property int unseen: root.unread[agentId] || 0

                width: agentList.width
                height: Style.space(40)

                Rectangle {
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

                  Text {
                    width: parent.width
                    text: agentRow.busy ? "working" : agentRow.modelData.mode
                    color: agentRow.busy ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // The only two things worth showing without reading the row:
                // that it is working, and that it finished while you were away.
                Rectangle {
                  id: marker
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
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.cursorIndex = agentRow.index
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

              // Where the agent is about to work is the one thing you need to
              // know before you press send, so it is always on screen.
              Text {
                Layout.fillWidth: true
                text: root.running
                  ? "working in " + (root.workdir === "" ? "…" : root.workdir)
                  : (root.configuredWorkDir !== ""
                      ? root.configuredWorkDir
                      : (root.workdir === ""
                          ? "runs in the directory of the window you are on"
                          : "last run: " + root.workdir))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
              }
            }

            Button {
              visible: root.running
              text: "Stop"
              fontSize: Style.font.caption
              onClicked: root.stopRun()
            }

            Button {
              text: "New"
              tooltipText: "Forget this conversation"
              fontSize: Style.font.caption
              onClicked: root.clearConversation()
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

                  // what you said
                  Rectangle {
                    visible: block.modelData.kind === "user"
                    width: Math.min(parent.width, prompt.implicitWidth + Style.space(28))
                    height: prompt.implicitHeight + Style.spacing.md
                    anchors.right: parent.right
                    color: root.selectedFill
                    radius: Style.cornerRadius

                    Text {
                      id: prompt
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.margins: Style.spacing.sm
                      text: block.modelData.text
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                    }
                  }

                  // what the agent said
                  Text {
                    visible: block.modelData.kind === "text"
                    width: parent.width
                    text: block.modelData.text
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
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

                  // what went wrong
                  Text {
                    visible: block.modelData.kind === "error"
                    width: parent.width
                    text: "⚠  " + block.modelData.text
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
          Rectangle {
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
