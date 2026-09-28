// Pure helpers for turning the event log into what the panel draws.
//
// `bin/agenttalk` already reduced opencode's event stream to a handful of
// shapes (user / text / tool / error / done / session), so this file never has
// to know anything about opencode internals. Its only jobs are joining the
// pieces of a reply into blocks and keeping the transcript to a size a chat
// view can hold.

var MAX_BLOCKS = 400

function joinText(previous, next) {
  // opencode emits one text part per step, so a single answer arrives in
  // pieces. Steps break on paragraph boundaries, but a step can also end
  // mid-thought; only insert a break when the two halves clearly want one.
  if (previous === "") return next
  if (/\s$/.test(previous)) return previous + next
  if (/^\s/.test(next)) return previous + next
  return previous + "\n\n" + next
}

function pushBlock(blocks, block) {
  var last = blocks.length > 0 ? blocks[blocks.length - 1] : null

  // An answer is one bubble, however many steps it took to write it.
  if (block.kind === "text" && last && last.kind === "text") {
    last.text = joinText(last.text, block.text)
    return
  }

  // Tools read better as one compact group than as a wall of separate lines.
  if (block.kind === "tool") {
    if (last && last.kind === "tools") {
      last.items.push(block)
      return
    }
    blocks.push({kind: "tools", items: [block]})
    return
  }

  blocks.push(block)
}

function parseEvents(content) {
  var blocks = []
  var lines = String(content === undefined || content === null ? "" : content).split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue

    var event
    try {
      event = JSON.parse(line)
    } catch (e) {
      // A half-written line while the worker appends: the next read has it.
      continue
    }
    if (!event || typeof event !== "object") continue

    switch (String(event.t)) {
      case "user":
        pushBlock(blocks, {
          kind: "user",
          text: String(event.text === undefined ? "" : event.text),
          // The directory this question was asked in, as the worker resolved
          // it. Empty for a run that predates the field.
          workdir: String(event.workdir === undefined ? "" : event.workdir)
        })
        break
      case "text":
        pushBlock(blocks, {kind: "text", text: String(event.text === undefined ? "" : event.text)})
        break
      case "tool":
        pushBlock(blocks, {
          kind: "tool",
          tool: String(event.tool || "tool"),
          status: String(event.status || "running"),
          title: String(event.title === undefined ? "" : event.title)
        })
        break
      case "error":
        pushBlock(blocks, {kind: "error", text: String(event.text === undefined ? "run failed" : event.text)})
        break
      case "done":
        blocks.push({kind: "done", code: Number(event.code || 0)})
        break
      default:
        // `session` and anything a future opencode adds: not our business.
        break
    }
  }

  var dropped = 0
  if (blocks.length > MAX_BLOCKS) {
    // Keep the tail, and never start on a half-finished bubble.
    dropped = blocks.length - MAX_BLOCKS
    blocks = blocks.slice(dropped)
    while (blocks.length > 0 && blocks[0].kind === "tools") blocks.shift()
  }

  return {blocks: blocks, dropped: dropped}
}

function blockKey(block, index) {
  var kind = block && block.kind ? block.kind : "?"
  var body = ""
  if (block && block.kind === "user") body = block.text
  else if (block && block.kind === "text") body = block.text
  else if (block && block.kind === "error") body = block.text
  else if (block && block.kind === "tools") body = block.items.length + ":" + block.items[0].title
  return kind + "|" + body.length + "|" + body.substring(0, 24) + "|" + index
}

// ---------------------------------------------------------------- agent rail
//
// The rail down the left of the panel. A plain list of agents cannot say the
// one thing that matters when there are more than a couple: which of them want
// you right now. So the rail is grouped by the directory a run would happen in,
// and ordered by how much each row is worth a glance.

var ATTENTION_UNSEEN = 0
var ATTENTION_WORKING = 1
var ATTENTION_IDLE = 2

// Unread outranks working: an agent that produced something while you were
// reading another one is the row that is about to be lost, and a running agent
// is not going anywhere.
function attentionRank(running, unseen) {
  if (unseen > 0) return ATTENTION_UNSEEN
  if (running) return ATTENTION_WORKING
  return ATTENTION_IDLE
}

// What the last run left behind. 143 and 124 are the script's own endings
// rather than opencode's: 143 is the SIGTERM the worker records for a stop, and
// 124 is coreutils' timeout. Both are named, because calling either one a
// failure blames the agent for something the user or the clock did.
function runState(running, exitCode) {
  if (running) return {label: "working", tone: "working"}
  if (exitCode === null) return {label: "not started", tone: "idle"}
  if (exitCode === 0) return {label: "idle", tone: "idle"}
  if (exitCode === 143) return {label: "stopped", tone: "stopped"}
  if (exitCode === 124) return {label: "timed out", tone: "stopped"}
  return {label: "failed", tone: "failed"}
}

function railGroupLabel(workdir) {
  // An agent that follows the focused window has no directory of its own, and
  // saying so is more useful than an empty heading over a list of agents.
  return workdir === "" ? "following the window" : workdir
}

function railEntry(agent, sessions, unread, forcedWorkdir, position) {
  var id = String(agent.id || "")
  var session = sessions && sessions[id] ? sessions[id] : null
  var meta = session && session.meta ? session.meta : null
  var pinned = !!(session && session.workdirPinned === true)
  var running = !!(session && session.running === true)
  // The script leaves exitCode null until a run has finished once, which is the
  // only difference between "idle" and "never started".
  var exitCode = meta && meta.exitCode !== undefined && meta.exitCode !== null
    ? Number(meta.exitCode)
    : null

  // The directory the next run would use, in the precedence the script resolves
  // it with: the panel setting wins, then the pin, then the focused window.
  // An unpinned agent is deliberately not grouped under its last run's
  // directory - it does not work there any more, and a row that moves between
  // groups as the pointer crosses windows is a row nobody can aim at.
  var workdir = forcedWorkdir !== "" ? forcedWorkdir : (pinned ? String(session.workdir || "") : "")

  return {
    id: id,
    mode: String(agent.mode || "all"),
    workdir: workdir,
    pinned: pinned,
    running: running,
    exitCode: exitCode,
    unseen: (unread && Number(unread[id])) || 0,
    position: position,
    rank: attentionRank(running, (unread && Number(unread[id])) || 0)
  }
}

function agentRail(agents, sessions, unread, forcedWorkdir) {
  var list = agents || []
  var forced = String(forcedWorkdir === undefined || forcedWorkdir === null ? "" : forcedWorkdir)

  var groups = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var entry = railEntry(list[i] || {}, sessions, unread, forced, i)
    if (entry.id === "") continue
    // Keyed with a prefix so a directory that happens to be called
    // "constructor" cannot reach Object.prototype.
    var key = "g:" + entry.workdir
    var group = seen[key]
    if (group === undefined) {
      group = {workdir: entry.workdir, entries: [], rank: ATTENTION_IDLE}
      seen[key] = group
      groups.push(group)
    }
    group.entries.push(entry)
    if (entry.rank < group.rank) group.rank = entry.rank
  }

  // A group leads with its most urgent row, then sorts by path, so the order
  // only moves when something actually changed state.
  groups.sort(function(a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    return a.workdir < b.workdir ? -1 : (a.workdir > b.workdir ? 1 : 0)
  })

  var rows = []
  var order = []
  for (var g = 0; g < groups.length; g++) {
    var entries = groups[g].entries
    // Within a group: by attention, then by opencode's own order, so an idle
    // list does not reshuffle itself every time one agent starts working.
    entries.sort(function(a, b) {
      if (a.rank !== b.rank) return a.rank - b.rank
      return a.position - b.position
    })
    rows.push({
      kind: "group",
      workdir: groups[g].workdir,
      label: railGroupLabel(groups[g].workdir),
      count: entries.length
    })
    for (var e = 0; e < entries.length; e++) {
      var item = entries[e]
      // The rail's own index, which is what the arrow keys walk. It is not the
      // row's index in the flat list, which also counts the group headings.
      item.slot = order.length
      order.push(item.id)
      rows.push({
        kind: "agent",
        id: item.id,
        slot: item.slot,
        mode: item.mode,
        workdir: item.workdir,
        running: item.running,
        unseen: item.unseen,
        state: runState(item.running, item.exitCode)
      })
    }
  }

  return {rows: rows, order: order}
}
