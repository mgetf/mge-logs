# mge-logs

`mge_logs` is a SourceMod plugin for Team Fortress 2 that collects per-match combat logs on [MGEMod](https://github.com/mgetf/MGEMod) duel servers, one log file per completed match. It's the collection layer that feeds match history and stats on [mge.tf](https://mge.tf).

MGE runs many concurrent 1v1/2v2 duels per server, which breaks the assumptions of existing TF2 logging tools (like [logs.tf](https://logs.tf)) that expect a single tournament-mode match at a time. `mge_logs` solves this by routing engine log lines to the correct arena session using each player's Steam3 ID, buffering them in memory, and flushing a complete log file when MGEMod reports the match has ended.

See [`docs/rfc-001-mge-match-logging.md`](docs/rfc-001-mge-match-logging.md) for the full design rationale and [`docs/development-plan.md`](docs/development-plan.md) for the phased build plan.

## How it works

- **Lifecycle** — Hooks MGEMod's public forwards (`MGE_On1v1MatchStart`, `MGE_On2v2MatchStart`, `MGE_On1v1MatchEnd`, `MGE_On2v2MatchEnd`, `MGE_OnPlayerELOChange`, `MGE_OnPlayerArenaRemoved`) via [`mge.inc`](addons/sourcemod/scripting/include/mge.inc) to know when a match starts, ends, or is aborted, and for which players.
- **Enrichment** — Relies on existing community plugins (`supstats2`, `medicstats`) that already emit rich per-event log lines (damage, accuracy, airshots, uber tracking) unconditionally via `AddGameLogHook()`. `mge_logs` does not duplicate this logic — it only captures and routes the lines.
- **Collection** — Buffers lines per active arena session and writes one `.log` file per match to `logs/mge/mge_<matchid>.log` (or `..._incomplete.log` if the match was aborted by disconnect, map change, or plugin unload).
- **Upload (optional)** — If `mge_logs_upload` is enabled and an API key/URL are configured, the completed log is POSTed to the mge.tf backend via [sm-ripext](https://github.com/ErasedDeath/sm-ripext), and the returned URL is available in-game via `!lastlog`.

## Dependencies

- [MGEMod](https://github.com/mgetf/MGEMod) — required; this plugin degrades gracefully (no-ops) if MGE isn't loaded.
- [sm-ripext](https://github.com/ErasedDeath/sm-ripext) — required only if log upload is enabled.
- Recommended for richer logs: [supstats2 and medicstats](https://github.com/F2/F2s-sourcemod-plugins) — not required, but without them the log files only contain vanilla kill lines (no damage/accuracy/airshot data).

## Installation

1. Copy `addons/sourcemod/plugins/mge_logs.smx` to your server's `addons/sourcemod/plugins/` directory.
2. Ensure MGEMod is installed and loaded.
3. (Optional) Install `sm-ripext` if you want log upload enabled.
4. Configure ConVars (see below) in your server config or `sourcemod/configs/`.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `mge_logs_enabled` | `1` | Master switch for match logging |
| `mge_logs_max_files` | `1000` | Max log files to retain in `logs/mge/` (oldest deleted first) |
| `mge_logs_upload` | `0` | Upload completed logs to the mge.tf backend |
| `mge_logs_apikey` | *(empty)* | API key for log upload (protected ConVar, never printed) |
| `mge_logs_upload_url` | *(empty)* | Full endpoint URL for log upload (e.g. `https://mge.tf/api/logs/upload`) |

## In-game commands

- `!lastlog` / `.lastlog` — Shows the player's most recent uploaded match log URL (via MOTD panel, falls back to chat if HTML MOTD is disabled).

## Log format

Each match produces a standard TF2-style log file with MGE-specific extensions (`meta_data`, `mge_match_end`, `mge_elo_delta`, `mge_match_aborted`). See the RFC's [§5.3–5.4](docs/rfc-001-mge-match-logging.md#53-session-metadata) for the exact line formats. [`mge-logs-parser`](https://github.com/mgetf/mge-logs-parser) is the companion service that turns these files into structured JSON.

## Building

Requires the [SourcePawn compiler](https://github.com/alliedmodders/sourcemod) (`spcomp`) and the includes vendored in `addons/sourcemod/scripting/include/`:

```bash
spcomp \
  -i"./addons/sourcemod/scripting/include/" \
  addons/sourcemod/scripting/mge_logs.sp \
  -o addons/sourcemod/plugins/mge_logs.smx
```

CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)) compiles and attaches the `.smx` to GitHub releases on every `v*` tag. The compiled plugin is also committed at [`addons/sourcemod/plugins/mge_logs.smx`](addons/sourcemod/plugins/mge_logs.smx) for convenience — pull a tagged release if you want a build that matches CI exactly.

## Third-party code

This repository vendors third-party SourcePawn includes for standalone compilation. See [NOTICE.md](NOTICE.md) for attribution.
