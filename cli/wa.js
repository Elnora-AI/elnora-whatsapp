#!/usr/bin/env node
// wa — WhatsApp CLI for agents and scripts.
//
// Reads go straight to the local SQLite store (fast, work with the bridge
// down); sends go through the bridge's localhost REST API. JSON on stdout,
// JSON errors on stderr, exit 0/1. No dependencies (node:sqlite, Node >=22.5).
"use strict";

// Node 22/23 print an ExperimentalWarning when node:sqlite loads, polluting
// stderr for agents. Re-exec once with --no-warnings on those versions.
const MAJOR = Number(process.versions.node.split(".")[0]);
if (MAJOR < 24 && !process.env.WA_RESPAWNED) {
  const { spawnSync } = require("node:child_process");
  const r = spawnSync(
    process.execPath,
    ["--no-warnings", __filename, ...process.argv.slice(2)],
    { stdio: "inherit", env: { ...process.env, WA_RESPAWNED: "1" } }
  );
  process.exit(r.status === null ? 1 : r.status);
}

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const HELP = `wa — WhatsApp from the command line (local store + bridge REST)

Usage:
  wa contacts <query>                 Search contacts and group chats by name
  wa chats [--limit N]                Recent chats, newest first
  wa messages <who> [options]         Messages in a chat (JID, phone, or name)
      --limit N        max messages (default 20)
      --from-them      only messages from the other side
      --since <ISO>    only messages at/after this timestamp
  wa send <who> <text...>             Send a text message (single recipient)
  wa doctor                           Install/bridge/pairing health as JSON

Options:
  --compact            minified JSON output
  -h, --help           this help

Environment:
  WHATSAPP_MCP_DIR     install dir (default ~/.whatsapp-mcp)
  WHATSAPP_BRIDGE_PORT bridge REST port (default 8080)

<who> resolution: exact JID > bare phone digits > unique contact-name match
> unique group-chat-name match. Ambiguous names fail with the candidate list.
Output is JSON on stdout; errors are JSON on stderr with exit code 1.`;

// --- plumbing ----------------------------------------------------------------

const args = process.argv.slice(2);
const flags = { compact: false, limit: null, fromThem: false, since: null };
const positional = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "-h" || a === "--help") {
    console.log(HELP);
    process.exit(0);
  } else if (a === "--compact") flags.compact = true;
  else if (a === "--from-them") flags.fromThem = true;
  else if (a === "--limit") flags.limit = Number(args[++i]);
  else if (a === "--since") flags.since = args[++i];
  else positional.push(a);
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

function openDb(file) {
  if (!fs.existsSync(file)) {
    die(
      `database not found: ${file}`,
      "Run the setup (scripts/setup.sh or /whatsapp-setup), pair your phone, and check WHATSAPP_MCP_DIR."
    );
  }
  try {
    return new DatabaseSync(file, { readOnly: true });
  } catch {
    return new DatabaseSync(file); // older node:sqlite without readOnly
  }
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
    die(
      `no bridge token at ${TOKEN_FILE}`,
      "The bridge has never started. Run scripts/doctor.sh."
    );
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
      "Reads still work; for sends start the bridge service (scripts/doctor.sh shows how)."
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

// who = exact JID | bare phone | unique contact name | unique group name
function resolveWho(who) {
  if (/@(s\.whatsapp\.net|g\.us|lid)$/.test(who)) {
    return { jid: who, name: null };
  }
  if (/^\+?[0-9][0-9 ()-]{4,}$/.test(who)) {
    const digits = who.replace(/[^0-9]/g, "");
    return { jid: `${digits}@s.whatsapp.net`, name: null };
  }
  const cdb = openDb(CONTACTS_DB);
  const contacts = contactRows(cdb, who);
  const mdb = openDb(MESSAGES_DB);
  const groups = groupRows(mdb, who);
  const all = [...contacts, ...groups];
  if (all.length === 0) {
    die(`no contact or group matches "${who}"`, "Try `wa contacts <query>` to search.");
  }
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

function senderNames(jids) {
  if (jids.length === 0) return {};
  const cdb = openDb(CONTACTS_DB);
  const map = {};
  const ph = jids.map(() => "?").join(",");
  for (const r of cdb
    .prepare(
      `SELECT their_jid, full_name, push_name, first_name
       FROM whatsmeow_contacts WHERE their_jid IN (${ph})`
    )
    .all(...jids)) {
    map[r.their_jid] = r.full_name || r.push_name || r.first_name || null;
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
  const rows = db
    .prepare(
      `SELECT c.jid, c.name, c.last_message_time,
              m.content AS last_message, m.sender AS last_sender, m.is_from_me AS last_is_from_me
       FROM chats c
       LEFT JOIN messages m
         ON m.chat_jid = c.jid AND m.timestamp = c.last_message_time
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
    sql += ` AND timestamp >= ?`;
    params.push(flags.since);
  }
  sql += ` ORDER BY timestamp DESC LIMIT ?`;
  params.push(limit);
  const rows = db.prepare(sql).all(...params);
  const names = senderNames([
    ...new Set(
      rows.filter((r) => !r.is_from_me && r.sender).map((r) =>
        r.sender.includes("@") ? r.sender : `${r.sender}@s.whatsapp.net`
      )
    ),
  ]);
  out({
    chat: { jid: target.jid, name: target.name },
    messages: rows.map((r) => {
      const senderJid =
        r.sender && !r.sender.includes("@")
          ? `${r.sender}@s.whatsapp.net`
          : r.sender;
      return {
        id: r.id,
        timestamp: r.timestamp,
        from_me: !!r.is_from_me,
        sender: r.is_from_me ? "me" : names[senderJid] || r.sender,
        content: r.content,
        media_type: r.media_type || null,
        filename: r.filename || null,
      };
    }),
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
  const [cmd, ...rest] = positional;
  switch (cmd) {
    case "contacts":
      return cmdContacts(rest.join(" "));
    case "chats":
      return cmdChats();
    case "messages":
      return cmdMessages(rest.join(" "));
    case "send":
      return cmdSend(rest[0], rest.slice(1));
    case "doctor":
      return cmdDoctor();
    default:
      console.log(HELP);
      process.exit(cmd ? 1 : 0);
  }
})().catch((e) => die(e.message));
