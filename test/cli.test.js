"use strict";
// End-to-end tests for cli/wa.js against a synthetic store + mock bridge.
// All data below is fictional.
const { test, before, after } = require("node:test");
const assert = require("node:assert");
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { DatabaseSync } = require("node:sqlite");

const execFileP = promisify(execFile);
const WA = path.join(__dirname, "..", "cli", "wa.js");
let dir, store, server, port, lastBody, lastAuth;

// Async spawn is load-bearing: the mock bridge server lives in THIS process,
// so a sync spawn would block the event loop and deadlock the CLI's requests.
async function run(args, env = {}, expectFail = false) {
  try {
    const { stdout } = await execFileP(process.execPath, [WA, ...args], {
      encoding: "utf8",
      env: { ...process.env, WHATSAPP_MCP_DIR: dir, WHATSAPP_BRIDGE_PORT: String(port), ...env },
    });
    assert.ok(!expectFail, `expected failure, got: ${stdout}`);
    return JSON.parse(stdout);
  } catch (e) {
    if (!expectFail) throw e;
    return JSON.parse(e.stderr.trim().split("\n").pop());
  }
}

before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "wa-test-"));
  store = path.join(dir, "whatsapp-bridge", "store");
  fs.mkdirSync(store, { recursive: true });

  const mdb = new DatabaseSync(path.join(store, "messages.db"));
  mdb.exec(`
    CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT, last_message_time TEXT);
    CREATE TABLE messages (id TEXT, chat_jid TEXT, sender TEXT, content TEXT,
      timestamp TEXT, is_from_me INTEGER, media_type TEXT, filename TEXT, url TEXT);
    INSERT INTO chats VALUES
      ('555001@s.whatsapp.net', NULL, '2026-01-02 10:00:00+00:00'),
      ('999888777@g.us', 'Team PRs', '2026-01-03 09:00:00+00:00');
    INSERT INTO messages VALUES
      ('m1','555001@s.whatsapp.net','555001','hello there','2026-01-02 09:00:00+00:00',0,NULL,NULL,NULL),
      ('m2','555001@s.whatsapp.net','me','hi back','2026-01-02 10:00:00+00:00',1,NULL,NULL,NULL),
      ('m3','999888777@g.us','555001','https://example.com/pr/1','2026-01-03 09:00:00+00:00',0,NULL,NULL,NULL);
  `);
  mdb.close();

  const cdb = new DatabaseSync(path.join(store, "whatsapp.db"));
  cdb.exec(`
    CREATE TABLE whatsmeow_contacts (their_jid TEXT, full_name TEXT, push_name TEXT, first_name TEXT);
    INSERT INTO whatsmeow_contacts VALUES
      ('555001@s.whatsapp.net','Alex Example','Alex',''),
      ('555002@s.whatsapp.net','Alexandra Sample','Sasha','');
  `);
  cdb.close();

  fs.writeFileSync(path.join(store, ".bridge-token"), "test-token-123\n");

  server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      lastBody = body ? JSON.parse(body) : null;
      lastAuth = req.headers.authorization;
      res.setHeader("content-type", "application/json");
      if (req.url === "/api/health") return res.end(JSON.stringify({ status: "ok", connected: true }));
      if (req.url === "/api/send") return res.end(JSON.stringify({ success: true, message: "sent" }));
      res.statusCode = 404;
      res.end("{}");
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  port = server.address().port;
});

after(() => {
  server?.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test("contacts finds people and groups", async () => {
  const alex = await run(["contacts", "Alex Example"]);
  assert.equal(alex.length, 1);
  assert.equal(alex[0].phone, "555001");
  const grp = await run(["contacts", "Team PRs"]);
  assert.equal(grp[0].kind, "group");
  assert.equal(grp[0].jid, "999888777@g.us");
});

test("chats lists newest first with last message", async () => {
  const chats = await run(["chats", "--limit", "5"]);
  assert.equal(chats[0].jid, "999888777@g.us");
  assert.equal(chats[0].is_group, true);
  assert.equal(chats[1].last_message, "hi back");
});

test("messages resolves by unique name and labels senders", async () => {
  const r = await run(["messages", "Alex Example"]);
  assert.equal(r.chat.jid, "555001@s.whatsapp.net");
  assert.equal(r.messages.length, 2);
  assert.equal(r.messages[0].sender, "me");
  assert.equal(r.messages[1].sender, "Alex Example");
});

test("messages --from-them filters own messages", async () => {
  const r = await run(["messages", "555001@s.whatsapp.net", "--from-them"]);
  assert.ok(r.messages.every((m) => m.from_me === false));
  assert.equal(r.messages[0].content, "hello there");
});

test("ambiguous name fails with candidates", async () => {
  const err = await run(["messages", "Alex"], {}, true);
  assert.match(err.error, /ambiguous/);
  assert.ok(err.candidates.length >= 2);
});

test("phone digits resolve without db lookup", async () => {
  const r = await run(["messages", "+55 50-01"]);
  assert.equal(r.chat.jid, "555001@s.whatsapp.net");
});

test("send resolves group name and posts to the bridge with auth", async () => {
  const r = await run(["send", "Team PRs", "hello", "world"]);
  assert.equal(r.sent, true);
  assert.equal(r.recipient.jid, "999888777@g.us");
  assert.deepEqual(lastBody, { recipient: "999888777@g.us", message: "hello world" });
  assert.equal(lastAuth, "Bearer test-token-123");
});

test("send refuses multiple recipients", async () => {
  const err = await run(["send", "a@s.whatsapp.net,b@s.whatsapp.net", "hi"], {}, true);
  assert.match(err.error, /one recipient/);
});

test("doctor reports healthy against mock bridge", async () => {
  const r = await run(["doctor"]);
  assert.equal(r.healthy, true);
  assert.equal(r.paired, true);
  assert.equal(r.chats, 2);
});

test("missing store dies with hint", async () => {
  const err = await run(["chats"], { WHATSAPP_MCP_DIR: path.join(os.tmpdir(), "wa-nonexistent") }, true);
  assert.match(err.error, /database not found/);
  assert.ok(err.hint);
});
