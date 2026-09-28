// Tests for the pure half of the panel: Model.js holds the only logic the panel
// runs outside QML bindings, and none of it can be checked by opening a panel.
//
// Run with `node tools/test_model.js`; `tools/test.sh` calls it.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// Model.js is a QML import, not a module, so it has no exports. Evaluating it
// in a context and handing the context back is the only way to reach it.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");
const context = vm.createContext({});
vm.runInContext(source, context, {filename: "Model.js"});

let passed = 0;
let failed = 0;

function check(name, condition) {
  if (condition) {
    passed++;
    console.log("ok " + name);
    return;
  }
  failed++;
  console.log("FAIL " + name);
}

function equal(name, actual, expected) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  check(name, a === b);
}

// A session as Panel.qml sees one: the three rail fields, plus meta.exitCode.
function session(fields) {
  return Object.assign(
    {running: false, workdir: "", workdirPinned: false, meta: {}},
    fields
  );
}

function agents(list) {
  return list.map(function(id) {
    return {id: id, mode: "all"};
  });
}

function build(agentList, sessions, unread, forced) {
  return context.agentRail(agents(agentList), sessions, unread || {}, forced || "");
}

// ---------------------------------------------------------------- grouping

const grouped = build(
  ["build", "plan"],
  {
    build: session({workdir: "/home/jp/Code/AgentTalk", workdirPinned: true}),
    plan: session({workdir: "/home/jp/Code/AgentTalk", workdirPinned: true})
  }
);
equal("two agents in one directory share a heading", grouped.rows.length, 3);
equal("the heading names the directory", grouped.rows[0].label, "/home/jp/Code/AgentTalk");
equal("both agents follow the heading", grouped.rows[1].id, "build");
check("an agent row is not a heading", grouped.rows[1].kind === "agent");

const split = build(
  ["build", "plan"],
  {
    build: session({workdir: "/home/jp/Code/AgentTalk", workdirPinned: true}),
    plan: session({workdir: "/home/jp/Code/Taxi-itax-v2", workdirPinned: true})
  }
);
equal("two directories get two headings", split.rows.filter(function(r) {
  return r.kind === "group";
}).length, 2);

// An unpinned agent follows the focused window, so it has no directory of its
// own yet. It must not borrow the one its last run happened in.
const following = build(
  ["build"],
  {build: session({workdir: "/home/jp/Code/AgentTalk", workdirPinned: false})}
);
equal("an unpinned agent gets its own heading", following.rows[0].label, "following the window");
equal("an unpinned agent is not in its last directory", following.rows[0].workdir, "");

// The panel setting outranks every pin, which puts the whole rail in one group.
const forced = build(
  ["build", "plan"],
  {
    build: session({workdir: "/home/jp/Code/AgentTalk", workdirPinned: true}),
    plan: session({workdir: "/home/jp/Code/Taxi-itax-v2", workdirPinned: true})
  },
  {},
  "/srv/work"
);
equal("a forced directory makes one heading", forced.rows.filter(function(r) {
  return r.kind === "group";
}).length, 1);
equal("the forced directory is the heading", forced.rows[0].label, "/srv/work");

// --------------------------------------------------------------- ordering

const attention = build(
  ["build", "plan", "review"],
  {
    build: session({workdirPinned: true, workdir: "/a"}),
    plan: session({workdirPinned: true, workdir: "/a"}),
    review: session({workdirPinned: true, workdir: "/a"})
  },
  {plan: 2}
);
equal("unread leads, then working, then idle", attention.order, ["plan", "build", "review"]);

const workingBeatsIdle = build(
  ["build", "plan"],
  {
    build: session({workdirPinned: true, workdir: "/a"}),
    plan: session({running: true, workdirPinned: true, workdir: "/a"})
  }
);
equal("a running agent outranks an idle one", workingBeatsIdle.order, ["plan", "build"]);

const workingAndUnread = build(
  ["build", "plan"],
  {
    build: session({workdirPinned: true, workdir: "/a"}),
    plan: session({running: true, workdirPinned: true, workdir: "/a"})
  },
  {plan: 1}
);
equal("unread outranks working", workingAndUnread.order, ["plan", "build"]);
equal(
  "an agent that is both still says so",
  workingAndUnread.rows[1].state.label,
  "working"
);

// A group leads with its most urgent row, so a directory with something running
// in it sorts above a quiet one.
const groupsByUrgency = build(
  ["build", "plan"],
  {
    build: session({workdirPinned: true, workdir: "/zzz-quiet"}),
    plan: session({running: true, workdirPinned: true, workdir: "/aaa-busy"})
  }
);
equal("the busy directory is drawn first", groupsByUrgency.rows[0].label, "/aaa-busy");
equal("and its agent with it", groupsByUrgency.rows[1].id, "plan");

// Nothing changed, so nothing moved: an idle list must not reshuffle itself.
const stable = build(["build", "plan", "review"], {
  build: session({workdirPinned: true, workdir: "/a", meta: {exitCode: 0}}),
  plan: session({workdirPinned: true, workdir: "/a", meta: {exitCode: 0}}),
  review: session({workdirPinned: true, workdir: "/a", meta: {exitCode: 0}})
});
equal("idle agents keep opencode's order", stable.order, ["build", "plan", "review"]);

// ------------------------------------------------------------------ states

function stateOf(exitCode, running) {
  const built = build(["build"], {
    build: session({
      running: running === true,
      workdirPinned: true,
      workdir: "/a",
      meta: exitCode === null ? {} : {exitCode: exitCode}
    })
  });
  return built.rows[1].state;
}

equal("a run that never finished is not started", stateOf(null).label, "not started");
equal("a clean run is idle", stateOf(0).label, "idle");
equal("143 is a stop, not a failure", stateOf(143).label, "stopped");
equal("124 is the timeout, not a failure", stateOf(124).label, "timed out");
equal("anything else did fail", stateOf(1).label, "failed");
check("a failure is toned apart from a stop", stateOf(1).tone === "failed");
check("a stop is not toned as a failure", stateOf(143).tone !== "failed");
equal("a running agent is working", stateOf(0, true).label, "working");

// ------------------------------------------------------------------- slots

// The arrow keys walk agents. `order` is what they walk, and it has to hold
// every agent exactly once, headings and all.
const slots = build(
  ["build", "plan", "review"],
  {
    build: session({workdirPinned: true, workdir: "/a"}),
    plan: session({workdirPinned: true, workdir: "/a"}),
    review: session({workdirPinned: true, workdir: "/b"})
  }
);
equal("the order holds every agent once", slots.order.length, 3);
equal("and holds nothing else", new Set(slots.order).size, 3);
var slotOk = true;
for (var i = 0; i < slots.rows.length; i++) {
  const row = slots.rows[i];
  if (row.kind !== "agent") continue;
  if (slots.order[row.slot] !== row.id) slotOk = false;
}
check("a row's slot points back at itself", slotOk);
check(
  "every agent row carries a state",
  slots.rows.filter(function(r) {
    return r.kind === "agent" && r.state && typeof r.state.label === "string";
  }).length === 3
);

// --------------------------------------------------------------- a scenario
//
// The layout the rail is meant to produce, with the agent list opencode
// actually returns on this machine and a state directory that has something
// going on in it. This is the case the visual check is compared against, so a
// change that reshuffles the rail has to change what is written here too.

const scenarioAgents = [
  "build", "compaction", "explore", "general", "plan", "summary", "title"
];
const scenarioSessions = {
  build: session({
    workdir: "/home/jp/Code/AgentTalk", workdirPinned: true, meta: {exitCode: 0}
  }),
  explore: session({
    workdir: "/home/jp/Code/AgentTalk", workdirPinned: true, meta: {exitCode: 1}
  }),
  plan: session({
    workdir: "/home/jp/Code/omarchy", workdirPinned: true, running: true
  }),
  summary: session({
    workdir: "/home/jp/Code/herdr", workdirPinned: true, meta: {exitCode: 143}
  })
  // compaction, general and title have no session at all: never pinned, never
  // run, so they follow the window.
};
const scenario = context.agentRail(agents(scenarioAgents), scenarioSessions, {}, "");

function shape(built) {
  const out = [];
  for (const row of built.rows) {
    out.push(row.kind === "group" ? ["#", row.label] : [row.id, row.state.label]);
  }
  return out;
}

equal(
  "the busy directory leads, then the window, then the rest by path",
  shape(scenario),
  [
    ["#", "/home/jp/Code/omarchy"],
    ["plan", "working"],
    ["#", "following the window"],
    ["compaction", "not started"],
    ["general", "not started"],
    ["title", "not started"],
    ["#", "/home/jp/Code/AgentTalk"],
    ["build", "idle"],
    ["explore", "failed"],
    ["#", "/home/jp/Code/herdr"],
    ["summary", "stopped"]
  ]
);
check(
  "nothing was lost on the way",
  scenarioAgents.every(function(id) {
    return scenario.order.indexOf(id) >= 0;
  })
);
check(
  "and nothing was invented",
  scenario.order.every(function(id) {
    return scenarioAgents.indexOf(id) >= 0;
  })
);
equal("the rail walks all seven, once each", new Set(scenario.order).size, 7);

// ------------------------------------------------------------------- edges
equal("no agents means no rows", build([], {}).rows.length, 0);
equal("no agents means nothing to walk", build([], {}).order.length, 0);
check(
  "a missing session does not throw",
  build(["ghost"], {}).order.length === 1
);
equal(
  "a directory called constructor is a directory",
  build(["build"], {
    build: session({workdir: "constructor", workdirPinned: true})
  }).rows[0].label,
  "constructor"
);
equal(
  "a directory called __proto__ is a directory",
  build(["build"], {
    build: session({workdir: "__proto__", workdirPinned: true})
  }).rows[0].label,
  "__proto__"
);

console.log("");
console.log(passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
