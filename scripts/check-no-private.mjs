#!/usr/bin/env node
// Guard: no personal, customer, or company-internal data may be committed.
// Scans every git-tracked file AND commit metadata (author/committer/message)
// for forbidden patterns. Exit 1 on any hit.
//
// This repo must stay 100% generic — usable by anyone, tied to no one.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

// Built via string concat so this file never literal-matches its own rules.
// Every regex is global: ALL matches on a line are checked individually, so
// an allowlisted token cannot mask a forbidden one on the same line.
const FORBIDDEN = [
  // Real phone-number JIDs (docs must use <phone>@s.whatsapp.net placeholders)
  { re: new RegExp(String.raw`\b\d{7,15}@s\.whatsapp` + String.raw`\.net`, "g"), why: "real phone-number JID" },
  // Absolute home paths tie docs/scripts to one machine
  { re: new RegExp("/Users/" + "[a-z]", "g"), why: "absolute macOS home path" },
  { re: new RegExp("C:\\\\Users\\\\" + "[A-Za-z]", "g"), why: "absolute Windows home path" },
  // Company-internal addresses; opensource@/security@ are the public contacts
  { re: new RegExp("[a-z0-9._%+-]+@elnora" + String.raw`\.ai`, "gi"), why: "internal email", allow: ["opensource@elnora.ai", "security@elnora.ai"] },
  // Slack user IDs
  { re: new RegExp("\\bU0" + "[A-Z0-9]{8,}\\b", "g"), why: "Slack user ID" },
  // Internal marketplace / infra names
  { re: new RegExp("elnora-internal" + "-ops", "g"), why: "internal marketplace name" },
];

const SELF = "scripts/check-no-private.mjs";
let bad = 0;

function scanText(text, label) {
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    for (const rule of FORBIDDEN) {
      rule.re.lastIndex = 0;
      for (const m of line.matchAll(rule.re)) {
        if (rule.allow && rule.allow.includes(m[0])) continue;
        console.error(`${label}:${i + 1}: ${rule.why}: ${m[0]}`);
        bad++;
      }
    }
  });
}

const files = execFileSync("git", ["ls-files"], { encoding: "utf8" })
  .split("\n")
  .filter((f) => f && f !== SELF);

for (const file of files) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    continue; // binary or unreadable
  }
  scanText(text, file);
}

// Commit metadata: identities and messages must be as generic as the tree.
// Scans HEAD's history (not --all) so each ref is judged on its own commits:
// main CI validates main, a PR's CI validates the PR branch.
// On pull_request events HEAD is GitHub's SYNTHETIC test-merge commit, which
// GitHub authors as the PR creator — nobody can control that identity, so
// skip to the real PR head (second parent) in that one case.
let scanRef = "HEAD";
const headMeta = execFileSync("git", ["log", "-1", "--format=%ce%n%s", "HEAD"], {
  encoding: "utf8",
}).split("\n");
if (
  headMeta[0] === "noreply@github.com" &&
  /^Merge [0-9a-f]{40} into [0-9a-f]{40}$/.test(headMeta[1] ?? "")
) {
  scanRef = "HEAD^2";
}
const gitLog = execFileSync(
  "git",
  ["log", scanRef, "--format=%h %an <%ae> %cn <%ce>%n%B"],
  { encoding: "utf8" }
);
scanText(gitLog, `git-log(${scanRef})`);

if (bad > 0) {
  console.error(`\n${bad} forbidden pattern hit(s). This repo must stay generic.`);
  process.exit(1);
}
console.log(`OK — ${files.length} tracked files + commit metadata clean.`);
