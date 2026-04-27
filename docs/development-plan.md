# MGE Match Logging — Phased Development Plan

**Based on:** [RFC-001: MGE Match Logging](rfc-001-mge-match-logging.md)  
**Created:** 2026-04-07  

## Overview

This document breaks the RFC into incremental phases. Each phase is a self-contained milestone that produces a testable deliverable. Phases are ordered by dependency — each builds on the previous. No phase requires future phases to be useful.

The plan separates **validation work** (resolving unknowns from the RFC's open questions) from **implementation work** (writing the mge_logs plugin). Validation comes first because it could change the architecture.

---

## Phase 0: Validation

**Goal:** Confirm that the foundational assumptions from the RFC hold on a live MGE server before writing any plugin code.

**Resolves:** RFC Open Questions #1, #2, #5, #6.

### 0.1 — supstats2 + match.inc on MGE servers

Install supstats2 (with smlib, kvizzle, f2stocks, match.inc) on a running MGE server. Verify:

- The plugin loads without errors.
- `match.inc` hooks are inert — no unexpected match state transitions, no tournament restart commands, no error log spam. Check SM error logs after running for 30+ minutes with active players.
- supstats2's `LogToGame()` calls are visible in the server console / engine log. Run `log on` and inspect the console output during active duels to confirm damage, accuracy, spawn, and pickup lines are being emitted.

### 0.2 — medicstats on MGE servers

Install medicstats alongside supstats2. Verify:

- The plugin loads without errors.
- On an Ultiduo arena with medics, uber-related log lines (`chargeready`, `chargedeployed`, `medic_death_ex`) appear in the engine log.
- The repeating timer (0.15s interval) doesn't cause performance issues with many players.

### 0.3 — Log line volume

With supstats2 and medicstats running on a populated MGE server (15+ players):

- Count log lines per minute during peak activity.
- Compare to a typical 6v6 match (~200 lines/min for 12 players). MGE may produce more due to higher kill rate and more players, but each arena is isolated so per-session volume is low.
- Check for any noticeable server performance impact (tick rate, player latency).

### 0.4 — Hook ordering (duplicate log lines)

With supstats2 running, add a minimal test plugin that registers `AddGameLogHook()` and logs every line it receives to a file. Verify:

- The vanilla `chargedeployed` line (blocked by supstats2) does NOT appear in the hooked output.
- supstats2's replacement `chargedeployed` line (with medigun name) DOES appear.
- This confirms that our collector will see the correct, non-duplicated lines regardless of plugin load order.

### 0.5 — BBall / KOTH event coverage

On an MGE server with BBall and KOTH arenas:

- Play BBall and check if `triggered "flagintel"` (intel pickup/capture/drop) lines appear in the engine log.
- Play KOTH and check if `triggered "pointcaptured"` lines appear.
- If these events don't fire (due to MGE's custom entity setup), document what does/doesn't work. This affects the game mode coverage table in the RFC but doesn't block the core implementation.

### Deliverable

A validation report documenting results for each item. If any assumption fails, update the RFC before proceeding.

### Risk

If supstats2 causes issues on MGE servers (errors, performance, conflicts), the fallback is to extract only the hooks we need into mge_logs directly. This would increase the scope of Phase 1 significantly but doesn't block the project.

---

## Phase 1: Minimal Collector (1v1)

**Goal:** Produce `.log` files on disk for completed 1v1 matches, containing all enriched log lines from the match.

**Depends on:** Phase 0 (validation passed).

### 1.1 — Plugin skeleton

- Create `mge_logs.sp` with plugin info, `OnPluginStart`, `OnPluginEnd`.
- `#include <mge>` with `REQUIRE_PLUGIN` undefined (optional dependency — graceful degradation if MGE isn't loaded).
- Register `AddGameLogHook()` in `OnPluginStart`, remove in `OnPluginEnd`.
- Create `logs/mge/` directory on plugin start if it doesn't exist.

### 1.2 — Session data structure

- Define a session struct or set of parallel arrays (SourcePawn's enum struct limitations may require the latter) holding: arena index, participant SteamIDs, log line buffer (`ArrayList` of strings), start timestamp, match ID.
- Implement `CreateSession(arena_index, steamids[])` and `DestroySession(arena_index)`.
- Maintain a global `StringMap` mapping SteamID → arena index for fast routing lookups.

### 1.3 — Lifecycle hooks (1v1)

- Hook `MGE_On1v1MatchStart`: extract SteamIDs for both players using `GetClientAuthId()`, call `CreateSession`.
- Hook `MGE_On1v1MatchEnd`: call flush-to-disk logic, then `DestroySession`.

### 1.4 — Log line routing

- In the `AddGameLogHook` callback: scan the log line for `<[U:1:` to extract SteamID(s). Look up in the global `StringMap`. If found, append the raw line (with timestamp prefix) to the corresponding session's buffer.
- Lines with no matching SteamID are silently dropped.

### 1.5 — File output

- On match end, write the session's buffered lines to `logs/mge/mge_<matchid>.log`, one line per entry, in `L mm/dd/yyyy - HH:MM:SS: <message>` format.
- Generate match ID from timestamp + random suffix (same approach as supstats2).

### Deliverable

After a completed 1v1 match on Spire, a file like `logs/mge/mge_260407143022_a8f3.log` appears containing all kill, damage, accuracy, spawn, and pickup lines for the two participants. No metadata lines yet — just the raw filtered engine output.

### Testing

- Play a 1v1 to completion. Verify the log file exists and contains only lines involving the two participants.
- Play two 1v1s simultaneously in different arenas. Verify two separate log files are produced with no cross-contamination.
- Play a 1v1 and have a third player idle on the server. Verify the idler's spawn/damage lines (if any) don't appear in the log.

---

## Phase 2: Session Metadata

**Goal:** Add MGE-specific context to each log file so a parser knows what the match was about.

**Depends on:** Phase 1.

### 2.1 — Match start metadata

At session creation, write directly into the session buffer (not via `LogToGame()`):

- `meta_data` line with match ID, map name, arena name (from `MGE_GetArenaInfo`), game mode, and frag limit.
- `changed role to` lines for each participant (read their current class via `TF2_GetPlayerClass`).

These lines appear at the top of the log file, before any gameplay lines.

### 2.2 — Match end metadata

At session finalization, append to the buffer before flushing:

- `mge_match_end` line with winner SteamID, winner score, loser score (from the `MGE_On1v1MatchEnd` forward parameters).

### 2.3 — ELO tracking

- Hook `MGE_OnPlayerELOChange`. Store the ELO delta in the session (keyed by arena index).
- At session finalization, append `mge_elo_delta` lines for each player whose ELO changed.

### Deliverable

Log files now open with metadata (arena, mode, players, classes) and close with match result and ELO changes. A parser can extract match context without inferring it from gameplay lines.

### Testing

- Play a 1v1 to completion. Verify the log file starts with `meta_data` and `changed role to` lines and ends with `mge_match_end` and `mge_elo_delta` lines.
- Verify the arena name, game mode, and frag limit in `meta_data` match the actual arena.
- Verify ELO values match what MGE displays in chat.

---

## Phase 3: 2v2 Support

**Goal:** Extend session management to handle 4-player 2v2 matches (including Ultiduo).

**Depends on:** Phase 2.

### 3.1 — 2v2 lifecycle hooks

- Hook `MGE_On2v2MatchStart`: create a session with four SteamIDs.
- Hook `MGE_On2v2MatchEnd`: finalize with winning team, team scores, all four player references.

### 3.2 — 2v2 match end metadata

- Extend `mge_match_end` format to include `winning_team` ("Red" or "Blue") and all four player SteamIDs, so the parser can reconstruct team composition.

### 3.3 — Ultiduo verification

- On a 2v2 Ultiduo arena, verify that medicstats' heal/uber lines are captured in the session log alongside damage/kill lines.
- Verify that heals between teammates (same arena) are correctly routed.

### Deliverable

Full parity between 1v1 and 2v2 log capture. Ultiduo matches produce logs with heal, uber, and medic stat lines.

### Testing

- Play a 2v2 to completion. Verify the log file contains lines from all four participants and no one else.
- Play Ultiduo specifically. Verify `healed`, `chargedeployed`, `chargeready`, `medic_death_ex` lines from medicstats appear.
- Run a 1v1 and 2v2 simultaneously. Verify separate, correct log files.

---

## Phase 4: Edge Cases and Robustness

**Goal:** Handle non-happy-path scenarios gracefully.

**Depends on:** Phase 3.

### 4.1 — Player disconnect

- Hook `MGE_OnPlayerArenaRemoved`. If a session is active for that arena and the match hasn't ended via the normal MatchEnd forward:
  - Append a marker line: `World triggered "mge_match_aborted" (reason "player_disconnect")`.
  - Flush the partial log to disk with a distinct filename pattern (e.g., `mge_<matchid>_incomplete.log`).
  - Destroy the session.
- If the match does end normally after a disconnect (MGE may handle replacement or forfeit), the normal MatchEnd path handles it.

### 4.2 — Map change mid-match

- In `OnMapEnd`, iterate all active sessions. Flush any that are still open as incomplete (same approach as 4.1, reason `"map_change"`).

### 4.3 — Plugin reload

- In `OnPluginEnd`, flush all active sessions as incomplete (reason `"plugin_unload"`).
- In `OnPluginStart` / `OnMapStart`, ensure clean state — no stale sessions from a previous plugin load.

### 4.4 — Log file retention

- Add ConVar `mge_logs_max_files` (default: 1000). On each new file write, count existing files in `logs/mge/`. If over the limit, delete the oldest.
- Add ConVar `mge_logs_enabled` (default: 1). Master switch to disable logging without unloading the plugin.

### Deliverable

The plugin handles all lifecycle edge cases without leaking sessions or losing data unexpectedly. Server operators have basic configuration control.

### Testing

- Disconnect mid-match. Verify an incomplete log file is produced with the abort marker.
- Change map with active matches. Verify incomplete logs are flushed.
- Reload the plugin (`sm plugins reload mge_logs`). Verify no errors and clean restart.
- Set `mge_logs_max_files 5`, play 10 matches, verify only 5 files remain (the newest).

---

## Phase 5: Upload Pipeline

**Goal:** Automatically upload log files to the mge.tf backend after each match.

**Depends on:** Phase 4 + an mge.tf API endpoint for receiving logs (backend work, out of scope for this plugin plan).

### 5.1 — HTTP upload

- Add dependency on `AnyHttp` or `SteamWorks` extension (same options logstf uses).
- Add ConVar `mge_logs_apikey` (protected) for server authentication.
- Add ConVar `mge_logs_upload` (default: 0, set to 1 to enable).
- On match end (after file write), if upload is enabled and API key is set, POST the log file to `mge.tf/api/logs/upload` with the API key.

### 5.2 — Response handling

- Parse the response for a log ID / URL.
- Store the last log URL per arena (or per player) for the `!lastlog` command.
- Print upload success/failure to server console. Do NOT print to player chat by default (MGE matches are short and frequent — chat spam would be disruptive).

### 5.3 — In-game log access

- Register `!lastlog` / `.lastlog` chat command.
- When a player types it, show their most recent match log URL via MOTD panel (same approach as logstf's `!log` command).
- Optional: print the URL in chat as a fallback for players with `cl_disablehtmlmotd 1`.

### 5.4 — Upload failure handling

- On failure, retry once after 5 seconds.
- On second failure, log the error and move on. Do not block or queue — MGE matches happen frequently enough that losing one log upload is acceptable.
- The local file always exists regardless of upload success.

### Deliverable

Log files are uploaded to mge.tf automatically. Players can type `!lastlog` to view their most recent match stats on the website.

### Testing

- With upload enabled, play a match. Verify the log appears on mge.tf.
- Disable the API key. Verify upload fails gracefully with no player-visible errors.
- Simulate network failure. Verify retry behavior and that the local file is unaffected.

---

## Phase 6: Future Enhancements

**Goal:** Items identified during RFC discussion that extend beyond the core plugin. Included here for completeness and planning visibility.

These are not scoped in detail — each would get its own plan document when prioritized.

### 6.1 — mge.tf log viewer

Backend work: build a TF2 log parser that understands MGE-specific extensions (`mge_match_end`, `mge_elo_delta`, `arena`, `gamemode`). Web UI for browsing match history, per-player stats, head-to-head records. Game-mode-aware stat presentation (BBall shows goals, Ultiduo shows heals, Midair highlights airshots).

### 6.2 — Aggregate player statistics

Use uploaded logs to compute lifetime stats: overall accuracy, DPM averages, win rates per arena/class/game mode, airshot rates. Power leaderboards and player profile pages on mge.tf.

### 6.3 — Spectator log access

When a spectator watches a match, allow them to see the log URL for that match (either the current in-progress match or the most recently completed one in that arena). May require an additional MGE API native to query spectator arena context.

### 6.4 — Live match stats (stretch)

Instead of waiting for match end, upload partial logs mid-match (like logstf's `logstf_midgameupload`). This would allow spectators or the website to show live stats during a match. Complexity is higher due to the short duration of MGE matches — a partial upload mid-match may not be useful for a 2-minute duel, but could matter for long first-to-20 grinds.

---

## Phase Dependency Graph

```
Phase 0: Validation
    │
    ▼
Phase 1: Minimal Collector (1v1)
    │
    ▼
Phase 2: Session Metadata
    │
    ▼
Phase 3: 2v2 Support
    │
    ▼
Phase 4: Edge Cases & Robustness
    │
    ├──────────────────────┐
    ▼                      ▼
Phase 5: Upload       Phase 6: Future
(requires mge.tf       (independent items,
 API endpoint)          each gets own plan)
```

## Summary Table

| Phase | Scope | Deliverable | Depends on |
|---|---|---|---|
| 0 | Validation | Report confirming assumptions | — |
| 1 | Minimal Collector | .log files on disk for 1v1 matches | Phase 0 |
| 2 | Session Metadata | Metadata + ELO in log files | Phase 1 |
| 3 | 2v2 Support | 2v2 + Ultiduo log capture | Phase 2 |
| 4 | Edge Cases | Disconnect, map change, retention | Phase 3 |
| 5 | Upload Pipeline | Auto-upload to mge.tf + !lastlog | Phase 4 + backend |
| 6 | Future | Viewer, aggregate stats, spectators | Phase 5 |
