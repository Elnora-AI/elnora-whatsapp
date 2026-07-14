#!/usr/bin/env node
// wa — WhatsApp CLI for agents and scripts.
//
// Reads go straight to the local SQLite store (fast, work with the bridge
// down); sends go through the bridge's localhost REST API. JSON on stdout,
// JSON errors on stderr, exit 0/1. No dependencies (node:sqlite).
"use strict";

// node:sqlite prints an ExperimentalWarning on stderr through the 24.x line.
// Re-exec once with --no-warnings so stderr stays parseable JSON.
const MAJOR = Number(process.versions.node.split(".")[0]);
if (MAJOR < 25 && !process.env.WA_RESPAWNED) {
  const { spawnSync } = require("node:child_process");
  const r = spawnSync(
    process.execPath,
    ["--no-warnings", ...process.execArgv, __filename, ...process.argv.slice(2)],
    { stdio: "inherit", env: { ...process.env, WA_RESPAWNED: "1" } }
  );
  if (r.error) {
    console.error(JSON.stringify({ error: `respawn failed: ${r.error.message}` }));
    process.exit(1);
  }
  process.exit(r.status === null ? 1 : r.status);
}

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const VERSION = require("../package.json").version;

const HELP = `wa — WhatsApp from the command line (local store + bridge REST)

Usage:
  wa contacts <query>                 Search contacts and group chats by name
  wa chats [--limit N]                Recent chats, newest first
  wa messages <who> [options]         Messages in a chat (JID, phone, or name)
      --limit N        max messages (default 20)
      --from-them      only messages from the other side
      --since <time>   at/after this time (ISO 8601 or "YYYY-MM-DD HH:MM:SS")
  wa send <who> <text...>             Send a text message (single recipient)
  wa doctor                           Install/bridge/pairing health as JSON

Options:
  --compact            minified JSON output
  --version            print CLI version
  -h, --help           this help

Environment:
  WHATSAPP_MCP_DIR     install dir (default ~/.whatsapp-mcp)
  WHATSAPP_BRIDGE_PORT bridge REST port (default 8080)

<who> resolution: exact JID > known international phone number (country code,
no leading 0/00) > unique contact-name match > unique group-chat-name match.
Ambiguous names fail with the candidate list. To send to a number you have
never chatted with, pass the full JID: <digits>@s.whatsapp.net.
For send, everything after <who> is the literal message — flag-looking words
are sent verbatim; put wa options (e.g. --compact) BEFORE the send command.
Output is JSON on stdout; errors are JSON on stderr with exit code 1.`;

// --- argument parsing ----------------------------------------------------------
// Global flags may appear before the command. Read commands also accept their
// flags after positionals. For `send`, everything after <who> is literal text.

const argv = process.argv.slice(2);
const flags = { compact: false, limit: null, fromThem: false, since: null };
let cmd = null;
let positional = [];

function takeGlobal(a, next) {
  if (a === "--compact") return (flags.compact = true), 0;
  return -1;
}

let i = 0;
for (; i < argv.length; i++) {
  const a = argv[i];
  if (a === "-h" || a === "--help") {
    console.log(HELP);
    process.exit(0);
  }
  if (a === "--version" || a === "-v") {
    console.log(JSON.stringify({ version: VERSION }));
    process.exit(0);
  }
  if (takeGlobal(a) === 0) continue;
  cmd = a;
  i++;
  break;
}

if (cmd === "send") {
  // <who> then verbatim text — no flag parsing past this point.
  positional = argv.slice(i);
} else {
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--compact") flags.compact = true;
    else if (a === "--from-them") flags.fromThem = true;
    else if (a === "--limit") flags.limit = Number(argv[++i]);
    else if (a === "--since") flags.since = argv[++i];
    else if (a === "--") {
      positional.push(...argv.slice(i + 1));
      break;
    } else positional.push(a);
  }
}

function out(obj) {
  console.log(JSON.stringify(obj, null, flags.compact ? 0 : 2));
}
function die(error, hint) {
  console.error(JSON.stringify(hint ? { error, hint } : { error }));
  process.exit(1);
}

const INSTALL_DIR = process.env.WHATSAPP_MCP_DIR
  ? path.resolve(process.env.WHATSAPP_MCP_DIR)
  : path.join(os.homedir(), ".whatsapp-mcp");
const STORE = path.join(INSTALL_DIR, "whatsapp-bridge", "store");
const MESSAGES_DB = path.join(STORE, "messages.db");
const CONTACTS_DB = path.join(STORE, "whatsapp.db");
const TOKEN_FILE = path.join(STORE, ".bridge-token");
const PORT = process.env.WHATSAPP_BRIDGE_PORT || "8080";
const API = `http://127.0.0.1:${PORT}/api`;
const SETUP_HINT =
  "Install/repair: /whatsapp-setup in Claude Code, or scripts/setup.sh from https://github.com/Elnora-AI/elnora-whatsapp. Custom location? Set WHATSAPP_MCP_DIR.";

const dbCache = new Map();
function openDb(file) {
  if (dbCache.has(file)) return dbCache.get(file);
  if (!fs.existsSync(file)) die(`database not found: ${file}`, SETUP_HINT);
  let db;
  try {
    db = new DatabaseSync(file, { readOnly: true });
  } catch (e) {
    // Never fall back to a writable open on the message store.
    die(`cannot open ${file} read-only: ${e.message}`, SETUP_HINT);
  }
  dbCache.set(file, db);
  return db;
}

function bridgeToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, "utf8").trim() || null;
  } catch {
    return null;
  }
}

async function bridge(pathname, body, timeoutMs = 8000) {
  const token = bridgeToken();
  if (!token) {
    die(`no bridge token at ${TOKEN_FILE}`, `The bridge has never started. ${SETUP_HINT}`);
  }
  let res;
  try {
    res = await fetch(`${API}${pathname}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    die(
      `bridge not reachable on 127.0.0.1:${PORT} (${e.cause?.code || e.name})`,
      "Reads still work; for sends start the bridge keep-alive service (run `wa doctor`, or the repo's scripts/doctor.sh)."
    );
  }
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  if (!res.ok) die(`bridge returned HTTP ${res.status}`, JSON.stringify(json));
  return json;
}

// --- resolution ----------------------------------------------------------------

function contactRows(db, query) {
  const q = `%${query}%`;
  return db
    .prepare(
      `SELECT their_jid AS jid, full_name, push_name, first_name
       FROM whatsmeow_contacts
       WHERE full_name LIKE ? OR push_name LIKE ? OR first_name LIKE ?
       ORDER BY full_name, push_name LIMIT 50`
    )
    .all(q, q, q)
    .map((r) => ({
      jid: r.jid,
      name: r.full_name || r.push_name || r.first_name || null,
      phone: r.jid.endsWith("@s.whatsapp.net") ? r.jid.split("@")[0] : null,
      kind: "contact",
    }));
}

function groupRows(db, query) {
  return db
    .prepare(
      `SELECT jid, name FROM chats
       WHERE jid LIKE '%@g.us' AND name LIKE ?
       ORDER BY last_message_time DESC LIMIT 50`
    )
    .all(`%${query}%`)
    .map((r) => ({ jid: r.jid, name: r.name, phone: null, kind: "group" }));
}

function jidKnown(jid) {
  const inChats = openDb(MESSAGES_DB)
    .prepare(`SELECT 1 FROM chats WHERE jid = ?`)
    .get(jid);
  if (inChats) return true;
  return !!openDb(CONTACTS_DB)
    .prepare(`SELECT 1 FROM whatsmeow_contacts WHERE their_jid = ?`)
    .get(jid);
}

function resolveByName(who) {
  const contacts = contactRows(openDb(CONTACTS_DB), who);
  const groups = groupRows(openDb(MESSAGES_DB), who);
  const all = [...contacts, ...groups];
  if (all.length === 0) return null;
  const exact = all.filter(
    (c) => (c.name || "").toLowerCase() === who.toLowerCase()
  );
  const pick = exact.length === 1 ? exact : all;
  if (pick.length > 1) {
    console.error(
      JSON.stringify({
        error: `"${who}" is ambiguous (${pick.length} matches) — use the JID`,
        candidates: pick.slice(0, 10),
      })
    );
    process.exit(1);
  }
  return { jid: pick[0].jid, name: pick[0].name };
}

// who = exact JID | known international phone | unique contact/group name
function resolveWho(who) {
  if (/@(s\.whatsapp\.net|g\.us|lid)$/.test(who)) {
    return { jid: who, name: null };
  }
  if (/^\+?[0-9][0-9 ()-]{4,}$/.test(who)) {
    const digits = who.replace(/[^0-9]/g, "");
    if (digits.startsWith("0")) {
      die(
        `"${who}" looks like a local-format number`,
        "WhatsApp needs international format: country code first, no leading 0 or 00."
      );
    }
    const jid = `${digits}@s.whatsapp.net`;
    if (digits.length >= 7 && digits.length <= 15 && jidKnown(jid)) {
      return { jid, name: null };
    }
    // Unknown number: maybe it's actually a numeric NAME (group "2024 2025").
    const byName = resolveByName(who);
    if (byName) return byName;
    die(
      `no existing chat or contact for number "${who}"`,
      `To message a number you have never chatted with, pass the full JID: ${digits}@s.whatsapp.net`
    );
  }
  const byName = resolveByName(who);
  if (!byName) {
    die(`no contact or group matches "${who}"`, "Try `wa contacts <query>` to search.");
  }
  return byName;
}

// sender values arrive as bare phones, bare LIDs, or full JIDs; LIDs map to
// phone numbers via whatsmeow_lid_map (mirrors upstream's sender aliasing).
function senderNames(rawSenders) {
  const bare = [...new Set(rawSenders.map((s) => s.split("@")[0]))];
  if (bare.length === 0) return {};
  const cdb = openDb(CONTACTS_DB);
  const ph = (n) => Array(n).fill("?").join(",");
  const lidToPn = {};
  try {
    for (const r of cdb
      .prepare(`SELECT lid, pn FROM whatsmeow_lid_map WHERE lid IN (${ph(bare.length)})`)
      .all(...bare)) {
      lidToPn[r.lid] = r.pn;
    }
  } catch {
    /* older store without lid map */
  }
  const jids = [...new Set(bare.map((b) => `${lidToPn[b] || b}@s.whatsapp.net`))];
  const names = {};
  for (const r of cdb
    .prepare(
      `SELECT their_jid, full_name, push_name, first_name
       FROM whatsmeow_contacts WHERE their_jid IN (${ph(jids.length)})`
    )
    .all(...jids)) {
    names[r.their_jid] = r.full_name || r.push_name || r.first_name || null;
  }
  const map = {};
  for (const raw of rawSenders) {
    const b = raw.split("@")[0];
    const pn = lidToPn[b] || b;
    map[raw] = names[`${pn}@s.whatsapp.net`] || (lidToPn[b] ? pn : b);
  }
  return map;
}

// --- commands ----------------------------------------------------------------

function cmdContacts(query) {
  if (!query) die("usage: wa contacts <query>");
  const contacts = contactRows(openDb(CONTACTS_DB), query);
  const groups = groupRows(openDb(MESSAGES_DB), query);
  out([...contacts, ...groups]);
}

function cmdChats() {
  const limit = flags.limit || 20;
  const db = openDb(MESSAGES_DB);
  // rowid-correlated join: exactly one message row per chat even when
  // several messages share the last-message timestamp (second precision).
  const rows = db
    .prepare(
      `SELECT c.jid, c.name, c.last_message_time,
              m.content AS last_message, m.is_from_me AS last_is_from_me
       FROM chats c
       LEFT JOIN messages m ON m.rowid = (
         SELECT MAX(rowid) FROM messages
         WHERE chat_jid = c.jid AND timestamp = c.last_message_time
       )
       ORDER BY c.last_message_time DESC LIMIT ?`
    )
    .all(limit);
  out(
    rows.map((r) => ({
      jid: r.jid,
      name: r.name,
      is_group: r.jid.endsWith("@g.us"),
      last_message_time: r.last_message_time,
      last_message: r.last_message,
      last_is_from_me: !!r.last_is_from_me,
    }))
  );
}

function cmdMessages(who) {
  if (!who) die("usage: wa messages <who>");
  const target = resolveWho(who);
  const limit = flags.limit || 20;
  const db = openDb(MESSAGES_DB);
  let sql = `SELECT id, timestamp, sender, content, is_from_me, media_type, filename
             FROM messages WHERE chat_jid = ?`;
  const params = [target.jid];
  if (flags.fromThem) sql += ` AND is_from_me = 0`;
  if (flags.since) {
    // datetime() normalizes both sides (T or space separator, Z or ±HH:MM
    // offsets) to UTC, so ISO 8601 input compares correctly against the
    // store's "YYYY-MM-DD HH:MM:SS±HH:MM" format.
    if (db.prepare(`SELECT datetime(?) AS d`).get(flags.since).d === null) {
      die(
        `--since "${flags.since}" is not a recognized timestamp`,
        'Use ISO 8601 ("2026-07-01T09:00:00Z") or "YYYY-MM-DD HH:MM:SS".'
      );
    }
    sql += ` AND datetime(timestamp) >= datetime(?)`;
    params.push(flags.since);
  }
  sql += ` ORDER BY timestamp DESC LIMIT ?`;
  params.push(limit);
  const rows = db.prepare(sql).all(...params);
  const names = senderNames(
    rows.filter((r) => !r.is_from_me && r.sender).map((r) => r.sender)
  );
  out({
    chat: { jid: target.jid, name: target.name },
    messages: rows.map((r) => ({
      id: r.id,
      timestamp: r.timestamp,
      from_me: !!r.is_from_me,
      sender: r.is_from_me ? "me" : names[r.sender] || r.sender,
      content: r.content,
      media_type: r.media_type || null,
      filename: r.filename || null,
    })),
  });
}

async function cmdSend(who, textParts) {
  const text = textParts.join(" ").trim();
  if (!who || !text) die("usage: wa send <who> <text...>");
  if (who.includes(",")) {
    die("one recipient per send", "Bulk sending is not supported (account-ban risk).");
  }
  const target = resolveWho(who);
  const resp = await bridge("/send", { recipient: target.jid, message: text });
  out({
    sent: resp.success !== false,
    recipient: { jid: target.jid, name: target.name },
    bridge: resp,
  });
}

async function cmdDoctor() {
  const report = {
    version: VERSION,
    install_dir: INSTALL_DIR,
    install_dir_exists: fs.existsSync(INSTALL_DIR),
    messages_db: fs.existsSync(MESSAGES_DB),
    contacts_db: fs.existsSync(CONTACTS_DB),
    bridge_token: fs.existsSync(TOKEN_FILE),
    bridge: "unreachable",
    paired: null,
    chats: null,
    newest_message: null,
  };
  if (report.messages_db) {
    try {
      const db = openDb(MESSAGES_DB);
      report.chats = db.prepare(`SELECT COUNT(*) AS n FROM chats`).get().n;
      report.newest_message =
        db.prepare(`SELECT MAX(timestamp) AS t FROM messages`).get().t || null;
    } catch (e) {
      report.store_error = e.message;
    }
  }
  const token = bridgeToken();
  if (token) {
    try {
      const res = await fetch(`${API}/health`, {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(2000),
      });
      const health = await res.json().catch(() => ({}));
      report.bridge = res.ok || res.status === 503 ? "up" : `http ${res.status}`;
      report.paired = health.connected === true;
    } catch {
      /* stays unreachable */
    }
  }
  const healthy =
    report.messages_db && report.bridge === "up" && report.paired === true;
  out({ healthy, ...report });
  if (!healthy) process.exitCode = 1;
}

// --- dispatch ----------------------------------------------------------------

(async () => {
  switch (cmd) {
    case "contacts":
      return cmdContacts(positional.join(" "));
    case "chats":
      return cmdChats();
    case "messages":
      return cmdMessages(positional.join(" "));
    case "send":
      return cmdSend(positional[0], positional.slice(1));
    case "doctor":
      return cmdDoctor();
    case null:
    case undefined:
      console.log(HELP);
      process.exit(0);
    default:
      die(`unknown command "${cmd}"`, "Run `wa --help` for usage.");
  }
})().catch((e) => die(e.message));
