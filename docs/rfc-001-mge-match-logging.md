# RFC-001: MGE Match Logging

**Status:** Draft  
**Author:** —  
**Created:** 2026-04-07  

## 1. Summary

A system for capturing per-match combat logs on MGE servers, producing one log file per completed duel (1v1 or 2v2). The system reuses existing community plugins for rich stat emission and introduces a single new SourceMod plugin (`mge_logs`) that acts as an arena-aware log collector, leveraging the MGE public API (`mge.inc`).

## 2. Motivation

MGE (My Gaming Edge) is a 1v1 and 2v2 duel practice format for Team Fortress 2. Players care deeply about per-match statistics — damage output, accuracy, airshots — but today, no logging infrastructure exists for MGE. The competitive 6v6 ecosystem has [logs.tf](https://logs.tf), powered by F2's open-source SourceMod plugins (`logstf`, `supstats2`, `medicstats`), but that stack assumes a single match per server with tournament mode lifecycle. MGE breaks every one of those assumptions.

The goal is to bring logs.tf-quality match data to MGE, ultimately powering a match history and stats view on **mge.tf**.

## 3. Problem Statement

The 6v6 logging stack cannot run on MGE servers for three reasons:

| Assumption | 6v6 Reality | MGE Reality |
|---|---|---|
| Match lifecycle | Tournament mode (`mp_tournament`) drives start/end via `match.inc` | No tournament mode; MGE plugin owns lifecycle via forwards |
| Concurrency | One match per server at a time | Multiple arenas running concurrently on the same server |
| Log output | Single log file per match (`logstf.log`) | Need one log file per arena match, separated in parallel |

However, the **stat emission** layer (supstats2, medicstats) is decoupled from match lifecycle — those plugins hook game events and call `LogToGame()` unconditionally. This means we can reuse them as-is and only replace the **collection** layer (logstf) with an MGE-aware equivalent.

## 4. Architecture

The system has three distinct layers, each solving a different problem. No single layer is sufficient on its own.

### 4.1 Separation of Concerns

**Enrichment layer — "What happened?"**

supstats2 and medicstats hook TF2 game events (damage, kills, heals, accuracy, uber) and emit detailed log lines via `LogToGame()`. They operate at the per-event level. They have no concept of "matches," "arenas," or "MGE" — they just see TF2 game events and produce enriched log lines for every player on the server, all the time.

Without this layer, we would only have the data already available in MGE's forwards (player A killed player B in arena 3) — no damage breakdown, no weapons, no accuracy, no airshots. To get those, we'd have to reimplement supstats2's hooks inside our own plugin.

**Lifecycle layer — "When, where, between whom, and with what result?"**

The MGE plugin (via `mge.inc`) tells us: a match started right now, in this arena, between these specific players, in this game mode, with this frag limit. And later: the match ended, this player won 20-17, and their ELO changed by +18. It has zero information about what happened *during* the match.

Without this layer, we have a continuous firehose of enriched log lines with no way to slice them into match-scoped files. We'd have no way to know when matches start or end, which players are dueling each other, or what the match outcome was.

**Collection layer — "Combine both into per-match log files."**

This is `mge_logs`, the plugin we build. It uses `mge.inc` forwards to know *when to open and close a recording session and for whom*, and it uses `AddGameLogHook()` to know *what to record into that session*. It's the glue between the two orthogonal layers above.

```
┌─────────────────────────────────────────────────────────────┐
│              ENRICHMENT LAYER ("what happened")             │
│                                                             │
│    TF2 Engine              supstats2           medicstats   │
│  (vanilla kill/          (damage, acc,        (uber, drops, │
│   suicide lines)          airshot, spawn)      charge)      │
│        │                      │                    │        │
│        └──── all emit via ────┴── LogToGame() ─────┘        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼  AddGameLogHook()
┌──────────────────────────┴──────────────────────────────────┐
│               COLLECTION LAYER (mge_logs — NEW)             │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Arena 1       │  │ Arena 2       │  │ Arena 3       │     │
│  │ Session       │  │ Session       │  │ Session       │     │
│  │ [SteamA,      │  │ [SteamC,      │  │ [SteamE-H]   │     │
│  │  SteamB]      │  │  SteamD]      │  │              │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                 │               │
│  Log lines routed by SteamID extracted from player tokens   │
└─────────┬─────────────────┬─────────────────┬───────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
    match_abc.log     match_def.log     match_ghi.log

          ▲                 ▲                 ▲
          │                 │                 │
┌─────────┴─────────────────┴─────────────────┴───────────────┐
│             LIFECYCLE LAYER ("when/where/who/result")        │
│                                                             │
│  MGE plugin (mge.inc) provides:                             │
│    MGE_On1v1MatchStart → open session                       │
│    MGE_On1v1MatchEnd   → close session, write file          │
│    MGE_On2v2MatchStart → open session                       │
│    MGE_On2v2MatchEnd   → close session, write file          │
│    MGE_OnPlayerELOChange → append ELO metadata              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Components

**Existing (run as-is, no modifications):**

- **supstats2** — Hooks `SDKHook_OnTakeDamage`, `TF2_CalcIsAttackCritical`, `player_hurt`, `player_healed`, `player_spawn`, `item_pickup`, `player_chargedeployed`, entity creation/destruction. Emits rich log lines via `LogToGame()` for every player on the server, unconditionally (no match-state gating). Provides: per-hit damage with weapon name resolution from `items_game.txt`, realdamage, crit/minicrit, airshot + height, headshot, accuracy (shot_fired/shot_hit with rocket-jump filtering), spawns, item pickups with healing, heals with crossbow airshot detection, chargedeployed with medigun name.

- **medicstats** — Hooks medic-specific events and runs a repeating timer for uber tracking. Emits via `LogToGame()`: `chargeready`, `medic_death_ex` (uber % on death), `first_heal_after_spawn`, `empty_uber`, `chargeended` (duration), `lost_uber_advantage`. Relevant primarily for Ultiduo (2v2 with medics).

**New (to be built):**

- **mge_logs** — The arena-aware collector. Depends on `mge.inc` for lifecycle. Replaces logstf's role. Described in detail below.

### 4.3 Why supstats2 and medicstats work as-is

Both plugins depend on `match.inc` at compile time, which hooks tournament mode events (`teamplay_round_restart_seconds`, `tf_game_over`, etc.). On an MGE server without tournament mode:

- `match.inc`'s hooks fire but conditions are never met, so `g_bInMatch` stays false permanently.
- supstats2's `StartMatch()` callback is an empty function body. Its stat-emitting hooks (`OnTakeDamage`, `Event_PlayerHurt`, etc.) have no match-state guards.
- medicstats runs its timer and event hooks independently of match state.
- The only lost functionality is supstats2's `meta_data` emission (match ID, map, title), which we handle ourselves in mge_logs.

**Dependencies introduced:** smlib, kvizzle, f2stocks (lightweight SM libraries already standard in competitive TF2 server deployments).

## 5. mge_logs Plugin Design

### 5.1 Lifecycle — MGE Forwards

| MGE Forward | mge_logs Response |
|---|---|
| `MGE_On1v1MatchStart(arena, p1, p2)` | Create a LogSession for the arena with p1 and p2's SteamIDs |
| `MGE_On2v2MatchStart(arena, t1p1, t1p2, t2p1, t2p2)` | Create a LogSession with all four SteamIDs |
| `MGE_On1v1MatchEnd(arena, winner, loser, w_score, l_score)` | Finalize and flush the session to disk |
| `MGE_On2v2MatchEnd(arena, w_team, w_score, l_score, ...)` | Finalize and flush the session to disk |
| `MGE_OnArenaPlayerDeath(victim, attacker, arena)` | (Optional) Increment internal kill counter for validation |
| `MGE_OnPlayerELOChange(client, old, new, arena)` | Append ELO delta to session metadata |

### 5.2 Log Line Routing

On every `AddGameLogHook()` callback:

1. Extract SteamID(s) from the log line by scanning for the `<[U:1:` pattern within player tokens (`"Name<uid><SteamID><Team>"`).
2. Look up each SteamID in a hash map (`StringMap`) that maps SteamID → arena session.
3. If a match is found, append the raw line to that session's buffer.
4. Lines with no recognized SteamID (e.g., `World triggered "Round_Start"`) are discarded — they are server-global events irrelevant to individual arena matches.

Lines may contain two player tokens (attacker + victim). Both players will always be in the same arena session — MGE arenas are isolated; cross-arena combat is impossible. We match on the first SteamID found.

### 5.3 Session Metadata

At session creation, mge_logs emits its own log lines into the session buffer (not via `LogToGame()`, since that would broadcast to all sessions):

```
World triggered "meta_data" (matchid "<generated>") (map "<current_map>") (arena "<arena_name>") (gamemode "<mode>") (fraglimit "<limit>")
"Player1<uid><SteamID><Team>" changed role to "<class>"
"Player2<uid><SteamID><Team>" changed role to "<class>"
```

At session finalization (match end), mge_logs appends:

```
World triggered "mge_match_end" (winner "<SteamID>") (winner_score "<n>") (loser_score "<n>")
World triggered "mge_elo_delta" (player "<SteamID>") (old_elo "<n>") (new_elo "<n>")
```

These are MGE-specific extensions to the log format. The `meta_data` line follows the convention established in [TF2 Logs Spec 3.0](https://github.com/F2/F2s-sourcemod-plugins/blob/master/logs-spec.md), extended with `arena` and `gamemode` properties.

### 5.4 Output Format

Each match produces a single `.log` file in standard TF2 log format:

```
L mm/dd/yyyy - HH:MM:SS: <log line>
```

Files are written to `logs/mge/` under the SourceMod directory, named `mge_<matchid>.log`. The match ID is generated from a timestamp + random suffix (same approach as supstats2's `meta_data` matchid).

The output is a valid subset of the TF2 log format. Any parser that understands standard TF2 logs + the Spec 3.0 extensions can parse these files. MGE-specific lines (`mge_match_end`, `mge_elo_delta`) use the `World triggered` convention and can be ignored by parsers that don't understand them.

### 5.5 Session Buffer Management

Each active arena session maintains:

- A `StringMap` of participant SteamIDs (for routing lookup)
- An `ArrayList` of buffered log lines (strings)
- Metadata: arena index, arena name, game mode, frag limit, start timestamp, match ID
- ELO change records (populated via `MGE_OnPlayerELOChange`)

On match end, the buffer is flushed to disk and all session state is freed. Sessions are keyed by arena index; since an arena can only have one active match at a time, there's no collision.

Maximum concurrent sessions equals the number of arenas on the map (typically 10-20). Memory overhead is minimal — an MGE match generates far fewer log lines than a 30-minute 6v6 match.

## 6. Game Mode Considerations

The collector captures the same raw events regardless of game mode. Interpretation is the parser's responsibility — the log file always includes the game mode in its `meta_data` line.

| Game Mode | What the engine + supstats2 already logs | Parser interpretation |
|---|---|---|
| **MGE** (standard 1v1) | kills, damage, weapons, accuracy | Primary metric: kills. DPM, accuracy as supporting stats |
| **BBall** | kills, damage + `triggered "flagintel"` (intel pickup/capture) | Primary metric: goals (intel captures). Kills are supporting |
| **KOTH** | kills, damage + `triggered "pointcaptured"` | Primary metric: point time. Kills as supporting |
| **Ammomod** | kills, damage, accuracy | Same as MGE; ammo mechanics are invisible to logs |
| **Ultiduo** (2v2) | kills, damage, heals, uber, accuracy | Full stat suite including heal stats and uber tracking |
| **Endif** | kills, damage | Same as MGE |
| **Midair** | kills, damage | Airshot data (from supstats2) is the key differentiator |

**BBall and KOTH:** The TF2 engine natively logs intel and point capture events using player tokens (`"Player<uid><SteamID><Team>"`). These lines will be routed to the correct arena session via SteamID, just like kill/damage lines.

**Ultiduo:** medicstats provides uber/heal/drop data. These are emitted via `LogToGame()` with player tokens and will be captured automatically.

**Score semantics:** The `winner_score` and `loser_score` in `MGE_On1v1MatchEnd` / `MGE_On2v2MatchEnd` reflect the arena's actual scoring — goals for BBall, kills for MGE, etc. The collector passes them through without interpretation.

## 7. What mge_logs Does NOT Do

- **No stat computation.** The plugin is a collector. It does not calculate DPM, accuracy percentages, or any derived metrics. That is the parser/backend's job.
- **No in-game display.** No computed stats are shown to players. Basic info (score, ELO change) is already displayed by MGE itself.
- **No uploads.** The initial version writes to local disk only. Upload to mge.tf is a future phase.
- **No modification to supstats2 or medicstats.** They run as stock releases from F2's repository.
- **No modification to MGE.** It consumes the existing `mge.inc` API only.

## 8. Server Requirements

**Plugins to install:**

| Plugin | Source | Purpose |
|---|---|---|
| mge.smx | MGEMod repo | Core MGE plugin (already installed) |
| mge_logs.smx | This project | The new collector |
| supstats2.smx | F2's repo | Rich stat emission |
| medicstats.smx | F2's repo | Medic stat emission (for Ultiduo) |

**Extensions / libraries:**

| Dependency | Required by |
|---|---|
| smlib | supstats2 |
| kvizzle | supstats2 (weapon name resolution from items_game.txt) |
| f2stocks | supstats2, medicstats |
| SDKHooks | supstats2 (included with SourceMod) |

**Server ConVars:**

- `log on` — enables engine logging so that `AddGameLogHook()` receives lines.

**No additional ConVars are required for the initial version.** Future phases will add ConVars for upload API key, log retention policy, etc.

## 9. Future Phases (Out of Scope for This RFC)

These are noted for architectural awareness but are not part of the initial implementation:

1. **Upload pipeline** — HTTP POST to `mge.tf/api/logs/upload` with API key auth, triggered at match end. Returns a log URL.
2. **In-game log URL** — `!lastlog` command that prints the mge.tf URL for the most recent match.
3. **mge.tf log viewer** — Web UI for browsing match logs, player stats, match history. Requires a log parser on the backend.
4. **Log retention / cleanup** — ConVar-controlled max age or max file count for local log files.
5. **Spectator log access** — Allow spectators to see log URLs for matches they're watching.

## 10. Open Questions

1. **match.inc side effects** — supstats2 and medicstats include `match.inc`, which hooks tournament mode events. On a server where `mp_tournament` is 0 (as in MGE), these hooks should be inert. This needs verification on a live MGE server to confirm there are no edge cases (e.g., map change triggers, stale timer state).

2. **Log line volume** — An MGE server with 20+ players across 10+ arenas will generate more `LogToGame()` calls per second than a typical 6v6 match (more concurrent fights, higher kill rate). supstats2's `OnTakeDamage` hook fires on every hit for every player on the server. Performance impact should be benchmarked. F2's code is performance-conscious (documented in code comments with benchmark data), but the MGE workload pattern differs.

3. **Player disconnect mid-match** — If a player disconnects during a match, MGE fires `MGE_OnPlayerArenaRemoved`. The match may end or be aborted. mge_logs should handle this gracefully — either discard the partial session or flush what it has with a marker indicating the match was incomplete.

4. **Team assignment semantics** — In MGE, both players in a 1v1 are on Red and Blue respectively, but the team assignment is managed by MGE, not by player choice. The `<Team>` field in log lines will reflect the actual TF2 team at the time of the event. This should be consistent within a match but may differ from the `SLOT_ONE`/`SLOT_TWO` semantics in `mge.inc`.

5. **Duplicate log lines** — supstats2 blocks the vanilla `chargedeployed` line and emits its own (with medigun name). This uses `AddGameLogHook` + `BlockLogLine` forward. Our collector also uses `AddGameLogHook`. We need to verify that the blocked line is never seen by our hook, and that supstats2's replacement line is. Hook execution order may matter.

6. **BBall/KOTH event coverage** — We assume the TF2 engine logs intel capture and point capture events on MGE arena maps. This needs verification — MGE maps use custom entity setups, and some objective events may not fire through the standard engine log path.
