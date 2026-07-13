#!/usr/bin/env node
// Guard: no personal, customer, or company-internal data may be committed.
// Scans every git-tracked file for forbidden patterns. Exit 1 on any hit.
//
// This repo must stay 100% generic — usable by anyone, tied to no one.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

// Built via string concat so this file never literal-matches its own rules.
const FORBIDDEN = [
  // Real phone-number JIDs (docs must use <phone>@s.whatsapp.net placeholders)
  { re: new RegExp(String.raw`\b\d{7,15}@s\.whatsapp` + String.raw`\.net`), why: "real phone-number JID" },
  // Absolute home paths tie docs/scripts to one machine
  { re: new RegExp("/Users/" + "[a-z]"), why: "absolute macOS home path" },
  { re: new RegExp("C:\\\\Users\\\\" + "[A-Za-z]"), why: "absolute Windows home path" },
  // Company-internal addresses; opensource@/security@ are the public contacts
  { re: new RegExp("[a-z0-9._%+-]+@elnora" + String.raw`\.ai`, "i"), why: "internal email", allow: ["opensource@elnora.ai", "security@elnora.ai"] },
  // Slack user IDs
  { re: new RegExp("\\bU0" + "[A-Z0-9]{8,}\\b"), why: "Slack user ID" },
  // Internal marketplace / infra names
  { re: new RegExp("elnora-internal" + "-ops"), why: "internal marketplace name" },
];

const SELF = "scripts/check-no-private.mjs";

const files = execSync("git ls-files", { encoding: "utf8" })
  .split("\n")
  .filter((f) => f && f !== SELF);

let bad = 0;
for (const file of files) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    continue; // binary or unreadable
  }
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    for (const rule of FORBIDDEN) {
      const m = line.match(rule.re);
      if (!m) continue;
      if (rule.allow && rule.allow.some((a) => line.includes(a) && m[0] === a)) continue;
      console.error(`${file}:${i + 1}: ${rule.why}: ${m[0]}`);
      bad++;
    }
  });
}

if (bad > 0) {
  console.error(`\n${bad} forbidden pattern hit(s). This repo must stay generic.`);
  process.exit(1);
}
console.log(`OK — ${files.length} tracked files clean.`);
