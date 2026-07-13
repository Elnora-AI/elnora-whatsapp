# Security Policy

## Reporting a vulnerability

Email **security@elnora.ai** or use GitHub's private vulnerability reporting
on this repository. We aim to acknowledge within 2 business days.

## Scope notes

- This repo contains setup/health scripts, service templates, and Claude Code
  plugin glue. Vulnerabilities in the bridge or MCP server themselves belong
  upstream at
  [verygoodplugins/whatsapp-mcp](https://github.com/verygoodplugins/whatsapp-mcp) —
  please report there too (and to us, so we can move the pinned revision).
- The threat model assumes a single-user machine. The bridge's REST API is
  localhost-only behind a bearer token; the message store is permission-locked
  to the owning user. Reports that require an attacker who already runs code
  as the same user are out of scope.

## Hardening defaults shipped here

- Webhook forwarding disabled (discard-port `WEBHOOK_URL`).
- `store/` chmod 700, databases and token 600 (user-only ACL on Windows).
- Upstream pinned to a reviewed revision, not a moving branch.
