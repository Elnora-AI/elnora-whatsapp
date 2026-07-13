#!/usr/bin/env node
// Cross-platform launcher for the whatsapp-mcp MCP server.
//
// Resolves the whatsapp-mcp install directory (WHATSAPP_MCP_DIR env var,
// falling back to ~/.whatsapp-mcp) and execs the Python MCP server via uv.
// Claude Code invokes this through the plugin's mcpServers entry, so the
// same plugin works no matter where the user installed whatsapp-mcp.
"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

function installDir() {
  const env = process.env.WHATSAPP_MCP_DIR;
  if (env && env.trim()) return path.resolve(env.trim());
  return path.join(os.homedir(), ".whatsapp-mcp");
}

const dir = installDir();
const serverDir = path.join(dir, "whatsapp-mcp-server");

if (!fs.existsSync(path.join(serverDir, "main.py"))) {
  console.error(`[whatsapp] MCP server not found at ${serverDir}`);
  console.error("[whatsapp] Run /whatsapp-setup (or scripts/setup.sh) to install it,");
  console.error("[whatsapp] or set WHATSAPP_MCP_DIR to an existing whatsapp-mcp checkout.");
  process.exit(1);
}

const child = spawn("uv", ["--directory", serverDir, "run", "main.py"], {
  stdio: "inherit",
  env: process.env,
});

child.on("error", (err) => {
  console.error(`[whatsapp] failed to start uv: ${err.message}`);
  console.error("[whatsapp] Install uv: https://docs.astral.sh/uv/");
  process.exit(1);
});

child.on("exit", (code, signal) => {
  process.exit(signal ? 1 : code === null ? 1 : code);
});
