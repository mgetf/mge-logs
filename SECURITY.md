# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it privately using [GitHub Security Advisories](../../security/advisories/new) rather than opening a public issue.

Please include:

- A description of the vulnerability and its potential impact
- Steps to reproduce (server config, ConVar values, etc. if relevant)
- Any relevant logs

We aim to acknowledge reports within a few days.

## Scope Notes

- `mge_logs_apikey` is a `FCVAR_PROTECTED` ConVar — it is never printed to players or unprotected logs, and is only sent as a `Bearer` token to the configured `mge_logs_upload_url`. If you find a code path that leaks it, that's a valid report.
- This plugin writes per-match `.log` files to `logs/mge/` on the server. These files contain player Steam3 IDs, in-game names, and (if supstats2 is installed) detailed combat stats. They are not intended to be served directly to the public — access control is the server operator's responsibility.
