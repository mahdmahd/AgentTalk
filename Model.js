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
        pushBlock(blocks, {kind: "user", text: String(event.text === undefined ? "" : event.text)})
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
