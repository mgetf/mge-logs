#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>
#include <mge>

#define PLUGIN_VERSION "0.1.0"

#define MAX_ARENAS 64
#define MAX_SESSION_PLAYERS 4
#define MAX_STEAMID_LEN 32
#define MAX_LOG_LINE_LEN 768
#define MATCH_ID_LEN 17

static const char g_sClassNames[10][] = {
	"", "scout", "sniper", "soldier", "demoman",
	"medic", "heavyweapons", "pyro", "spy", "engineer"
};

public Plugin myinfo = {
	name = "MGE Logs",
	author = "mge.tf",
	description = "Arena-aware match log collector for MGE.",
	version = PLUGIN_VERSION,
	url = "https://mge.tf"
};

ConVar g_cvEnabled;
ConVar g_cvMaxFiles;

bool g_bGameLogHooked;
bool g_bMGEAvailable;
bool g_bSessionActive[MAX_ARENAS];
bool g_bSessionPendingFlush[MAX_ARENAS];
bool g_bSession2v2[MAX_ARENAS];

ArrayList g_hSessionBuffer[MAX_ARENAS];
StringMap g_hSteamToArena;

char g_sLogDir[PLATFORM_MAX_PATH];
char g_sSessionMatchId[MAX_ARENAS][MATCH_ID_LEN];
char g_sSessionPlayers[MAX_ARENAS][MAX_SESSION_PLAYERS][MAX_STEAMID_LEN];
char g_sSessionWinnerSteamId[MAX_ARENAS][MAX_STEAMID_LEN];
char g_sSessionLoserSteamId[MAX_ARENAS][MAX_STEAMID_LEN];

int g_iSessionPlayerCount[MAX_ARENAS];
int g_iSessionWinnerScore[MAX_ARENAS];
int g_iSessionLoserScore[MAX_ARENAS];
int g_iSession2v2WinningTeam[MAX_ARENAS];

public void OnPluginStart()
{
	g_cvEnabled  = CreateConVar("mge_logs_enabled",   "1",    "Master switch for match logging.", _, true, 0.0, true, 1.0);
	g_cvMaxFiles = CreateConVar("mge_logs_max_files", "1000", "Max log files to keep in logs/mge/.", _, true, 0.0);

	g_bMGEAvailable = LibraryExists("mge");
	g_hSteamToArena = new StringMap();

	BuildPath(Path_SM, g_sLogDir, sizeof(g_sLogDir), "logs/mge");
	EnsureLogDirectory();

	AddGameLogHook(GameLog);
	g_bGameLogHooked = true;
}

public void OnPluginEnd()
{
	if (g_bGameLogHooked) {
		RemoveGameLogHook(GameLog);
		g_bGameLogHooked = false;
	}

	AbortAllSessions("plugin_unload");

	delete g_hSteamToArena;
	g_hSteamToArena = null;
}

public void OnMapEnd()
{
	AbortAllSessions("map_change");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "mge")) {
		g_bMGEAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "mge")) {
		g_bMGEAvailable = false;
		DestroyAllSessions();
	}
}

public void MGE_On1v1MatchStart(int arena_index, int player1, int player2)
{
	if (!g_bMGEAvailable) {
		return;
	}

	CreateSession(arena_index, player1, player2);
}

public void MGE_On1v1MatchEnd(int arena_index, int winner, int loser, int winner_score, int loser_score)
{
	if (!g_bMGEAvailable) {
		return;
	}

	if (!IsValidArenaIndex(arena_index) || !g_bSessionActive[arena_index]) {
		return;
	}

	GetClientAuthId(winner, AuthId_Steam3,
		g_sSessionWinnerSteamId[arena_index], MAX_STEAMID_LEN);
	GetClientAuthId(loser, AuthId_Steam3,
		g_sSessionLoserSteamId[arena_index], MAX_STEAMID_LEN);
	g_iSessionWinnerScore[arena_index] = winner_score;
	g_iSessionLoserScore[arena_index] = loser_score;

	g_bSessionPendingFlush[arena_index] = true;
	RequestFrame(Frame_FlushPendingSessions, arena_index);
}

public void MGE_On2v2MatchStart(int arena_index, int team1_player1, int team1_player2, int team2_player1, int team2_player2)
{
	if (!g_bMGEAvailable) {
		return;
	}

	CreateSession(arena_index, team1_player1, team1_player2, team2_player1, team2_player2);
}

public void MGE_On2v2MatchEnd(int arena_index, int winning_team, int winning_score, int losing_score, int team1_player1, int team1_player2, int team2_player1, int team2_player2)
{
	if (!g_bMGEAvailable) {
		return;
	}

	if (!IsValidArenaIndex(arena_index) || !g_bSessionActive[arena_index]) {
		return;
	}

	g_iSession2v2WinningTeam[arena_index] = winning_team;
	g_iSessionWinnerScore[arena_index] = winning_score;
	g_iSessionLoserScore[arena_index] = losing_score;

	g_bSessionPendingFlush[arena_index] = true;
	RequestFrame(Frame_FlushPendingSessions, arena_index);
}

public void MGE_OnPlayerArenaRemoved(int client, int arena_index)
{
	if (!IsValidArenaIndex(arena_index)) {
		return;
	}

	if (g_bSessionActive[arena_index] && !g_bSessionPendingFlush[arena_index]) {
		AbortSession(arena_index, "player_disconnect");
	}
}

public void MGE_OnPlayerELOChange(int client, int old_elo, int new_elo, int arena_index)
{
	if (!IsValidArenaIndex(arena_index) || !g_bSessionActive[arena_index]) {
		return;
	}

	char steamid[MAX_STEAMID_LEN];
	if (!GetClientAuthId(client, AuthId_Steam3, steamid, sizeof(steamid))) {
		return;
	}

	AppendMetaLine(arena_index,
		"World triggered \"mge_elo_delta\" (player \"%s\") (old_elo \"%d\") (new_elo \"%d\")",
		steamid, old_elo, new_elo);
}

public void Frame_FlushPendingSessions(int arena_index)
{
	if (!IsValidArenaIndex(arena_index) || !g_bSessionPendingFlush[arena_index]) {
		return;
	}

	g_bSessionPendingFlush[arena_index] = false;

	if (g_bSessionActive[arena_index]) {
		if (g_bSession2v2[arena_index]) {
			char winTeam[8];
			strcopy(winTeam, sizeof(winTeam),
				g_iSession2v2WinningTeam[arena_index] == 2 ? "Red" : "Blue");

			AppendMetaLine(arena_index,
				"World triggered \"mge_match_end\" (winning_team \"%s\") (winning_score \"%d\") (losing_score \"%d\") (t1p1 \"%s\") (t1p2 \"%s\") (t2p1 \"%s\") (t2p2 \"%s\")",
				winTeam,
				g_iSessionWinnerScore[arena_index],
				g_iSessionLoserScore[arena_index],
				g_sSessionPlayers[arena_index][0],
				g_sSessionPlayers[arena_index][1],
				g_sSessionPlayers[arena_index][2],
				g_sSessionPlayers[arena_index][3]);
		}
		else {
			AppendMetaLine(arena_index,
				"World triggered \"mge_match_end\" (winner \"%s\") (winner_score \"%d\") (loser_score \"%d\")",
				g_sSessionWinnerSteamId[arena_index],
				g_iSessionWinnerScore[arena_index],
				g_iSessionLoserScore[arena_index]);
		}

		FlushSession(arena_index);
		DestroySession(arena_index);
	}
}

public Action GameLog(const char[] message)
{
	if (g_hSteamToArena == null) {
		return Plugin_Continue;
	}

	char steamid[MAX_STEAMID_LEN];
	if (!ExtractSteamId(message, steamid, sizeof(steamid))) {
		return Plugin_Continue;
	}

	int arena;
	if (!g_hSteamToArena.GetValue(steamid, arena)) {
		return Plugin_Continue;
	}

	if (!IsValidArenaIndex(arena) || !g_bSessionActive[arena]) {
		return Plugin_Continue;
	}

	AppendLogLine(arena, message);
	return Plugin_Continue;
}

void CreateSession(int arena, int player1, int player2, int player3 = -1, int player4 = -1)
{
	if (!g_cvEnabled.BoolValue) {
		return;
	}

	if (!IsValidArenaIndex(arena)) {
		LogError("CreateSession: invalid arena index %d", arena);
		return;
	}

	if (g_bSessionPendingFlush[arena]) {
		g_bSessionPendingFlush[arena] = false;
		FlushSession(arena);
	}

	if (g_bSessionActive[arena]) {
		DestroySession(arena);
	}

	bool is2v2 = (player3 != -1);

	char steamIds[MAX_SESSION_PLAYERS][MAX_STEAMID_LEN];
	int playerHandles[MAX_SESSION_PLAYERS];
	int playerCount = is2v2 ? 4 : 2;

	playerHandles[0] = player1;
	playerHandles[1] = player2;
	if (is2v2) {
		playerHandles[2] = player3;
		playerHandles[3] = player4;
	}

	for (int i = 0; i < playerCount; i++) {
		if (!GetClientAuthId(playerHandles[i], AuthId_Steam3, steamIds[i], MAX_STEAMID_LEN)) {
			LogError("CreateSession: failed to get SteamID for client %d", playerHandles[i]);
			return;
		}
	}

	g_hSessionBuffer[arena] = new ArrayList(ByteCountToCells(MAX_LOG_LINE_LEN));
	g_bSessionActive[arena] = true;
	g_bSession2v2[arena] = is2v2;
	g_iSessionPlayerCount[arena] = playerCount;

	for (int i = 0; i < playerCount; i++) {
		strcopy(g_sSessionPlayers[arena][i], MAX_STEAMID_LEN, steamIds[i]);
		g_hSteamToArena.SetValue(steamIds[i], arena);
	}

	GenerateMatchId(g_sSessionMatchId[arena], MATCH_ID_LEN);

	char map[64], gamemode[16];
	GetCurrentMap(map, sizeof(map));

	MGEArenaInfo info;
	if (MGE_GetArenaInfo(arena, info))
	{
		GamemodeString(info.gameMode, gamemode, sizeof(gamemode));
		AppendMetaLine(arena,
			"World triggered \"meta_data\" (matchid \"%s\") (map \"%s\") (arena \"%s\") (gamemode \"%s\") (fraglimit \"%d\")",
			g_sSessionMatchId[arena], map, info.name, gamemode, info.fragLimit);
	}
	else
	{
		AppendMetaLine(arena,
			"World triggered \"meta_data\" (matchid \"%s\") (map \"%s\")",
			g_sSessionMatchId[arena], map);
	}

	for (int i = 0; i < playerCount; i++) {
		WriteChangedRoleLine(arena, playerHandles[i], steamIds[i]);
	}
}

void DestroySession(int arena)
{
	if (!IsValidArenaIndex(arena)) {
		return;
	}

	if (g_hSteamToArena != null) {
		for (int i = 0; i < g_iSessionPlayerCount[arena]; i++) {
			if (g_sSessionPlayers[arena][i][0] != '\0') {
				g_hSteamToArena.Remove(g_sSessionPlayers[arena][i]);
			}
		}
	}

	delete g_hSessionBuffer[arena];
	g_hSessionBuffer[arena] = null;

	g_bSessionActive[arena] = false;
	g_iSessionPlayerCount[arena] = 0;
	g_sSessionMatchId[arena][0] = '\0';

	for (int i = 0; i < MAX_SESSION_PLAYERS; i++) {
		g_sSessionPlayers[arena][i][0] = '\0';
	}

	g_sSessionWinnerSteamId[arena][0] = '\0';
	g_sSessionLoserSteamId[arena][0] = '\0';
	g_iSessionWinnerScore[arena] = 0;
	g_iSessionLoserScore[arena] = 0;
	g_bSession2v2[arena] = false;
	g_iSession2v2WinningTeam[arena] = 0;
}

void AbortSession(int arena, const char[] reason)
{
	if (!IsValidArenaIndex(arena) || !g_bSessionActive[arena]) {
		return;
	}

	AppendMetaLine(arena,
		"World triggered \"mge_match_aborted\" (reason \"%s\")", reason);

	FlushSession(arena, "_incomplete");
	DestroySession(arena);
}

void AbortAllSessions(const char[] reason)
{
	for (int arena = 1; arena < MAX_ARENAS; arena++) {
		g_bSessionPendingFlush[arena] = false;
		if (g_bSessionActive[arena]) {
			AbortSession(arena, reason);
		}
	}
}

void DestroyAllSessions()
{
	for (int arena = 1; arena < MAX_ARENAS; arena++) {
		g_bSessionPendingFlush[arena] = false;
		if (g_bSessionActive[arena]) {
			DestroySession(arena);
		}
	}
}

bool FlushSession(int arena, const char[] suffix = "")
{
	if (!IsValidArenaIndex(arena) || g_hSessionBuffer[arena] == null) {
		return false;
	}

	EnsureLogDirectory();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "logs/mge/mge_%s%s.log", g_sSessionMatchId[arena], suffix);

	File file = OpenFile(path, "w");
	if (file == null) {
		LogError("FlushSession: could not open %s for writing", path);
		return false;
	}

	char line[MAX_LOG_LINE_LEN];
	int lineCount = g_hSessionBuffer[arena].Length;

	for (int i = 0; i < lineCount; i++) {
		g_hSessionBuffer[arena].GetString(i, line, sizeof(line));
		file.WriteString(line, false);
	}

	file.Close();

	EnforceFileRetention();

	return true;
}

void AppendMetaLine(int arena, const char[] format, any ...)
{
	char message[MAX_LOG_LINE_LEN];
	VFormat(message, sizeof(message), format, 3);
	StrCat(message, sizeof(message), "\n");
	AppendLogLine(arena, message);
}

void GamemodeString(int gameMode, char[] buffer, int maxlen)
{
	if (gameMode & MGE_GAMEMODE_BBALL)   { strcopy(buffer, maxlen, "bball");   return; }
	if (gameMode & MGE_GAMEMODE_KOTH)    { strcopy(buffer, maxlen, "koth");    return; }
	if (gameMode & MGE_GAMEMODE_AMMOMOD) { strcopy(buffer, maxlen, "ammomod"); return; }
	if (gameMode & MGE_GAMEMODE_MIDAIR)  { strcopy(buffer, maxlen, "midair");  return; }
	if (gameMode & MGE_GAMEMODE_ENDIF)   { strcopy(buffer, maxlen, "endif");   return; }
	if (gameMode & MGE_GAMEMODE_ULTIDUO) { strcopy(buffer, maxlen, "ultiduo"); return; }
	if (gameMode & MGE_GAMEMODE_TURRIS)  { strcopy(buffer, maxlen, "turris");  return; }
	strcopy(buffer, maxlen, "mge");
}

void WriteChangedRoleLine(int arena, int client, const char[] steamid)
{
	char name[64], team[8];
	int uid = GetClientUserId(client);
	GetClientName(client, name, sizeof(name));

	int teamNum = GetClientTeam(client);
	strcopy(team, sizeof(team), teamNum == 3 ? "Blue" : "Red");

	int classIdx = view_as<int>(TF2_GetPlayerClass(client));
	if (classIdx < 0 || classIdx >= sizeof(g_sClassNames))
		classIdx = 0;

	AppendMetaLine(arena,
		"\"%s<%d><%s><%s>\" changed role to \"%s\"",
		name, uid, steamid, team, g_sClassNames[classIdx]);
}

void AppendLogLine(int arena, const char[] message)
{
	if (g_hSessionBuffer[arena] == null) {
		return;
	}

	if (strlen(message) >= MAX_LOG_LINE_LEN - 32) {
		LogError("AppendLogLine: log line too long (%d): %s", strlen(message), message);
		return;
	}

	char time[32];
	char line[MAX_LOG_LINE_LEN];

	FormatTime(time, sizeof(time), "%m/%d/%Y - %H:%M:%S");
	FormatEx(line, sizeof(line), "L %s: %s", time, message);
	g_hSessionBuffer[arena].PushString(line);
}

bool ExtractSteamId(const char[] message, char[] steamid, int maxlen)
{
	int start = StrContains(message, "[U:1:");
	if (start == -1) {
		return false;
	}

	int messageLength = strlen(message);
	int end = start;

	while (end < messageLength && message[end] != ']') {
		end++;
	}

	if (end >= messageLength) {
		return false;
	}

	int steamIdLength = end - start + 1;
	if (steamIdLength >= maxlen) {
		return false;
	}

	for (int i = 0; i < steamIdLength; i++) {
		steamid[i] = message[start + i];
	}

	steamid[steamIdLength] = '\0';
	return true;
}

void GenerateMatchId(char[] buffer, int maxlen)
{
	if (maxlen < MATCH_ID_LEN) {
		return;
	}

	FormatTime(buffer, maxlen, "%y%m%d%H%M%S");

	char hexChars[] = "0123456789abcdef";
	int offset = strlen(buffer);

	for (int i = 0; i < 4; i++) {
		buffer[offset + i] = hexChars[GetRandomInt(0, 15)];
	}

	buffer[offset + 4] = '\0';
}

void EnforceFileRetention()
{
	int maxFiles = g_cvMaxFiles.IntValue;
	if (maxFiles <= 0) {
		return;
	}

	DirectoryListing dir = OpenDirectory(g_sLogDir);
	if (dir == null) {
		return;
	}

	ArrayList files = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	char entry[PLATFORM_MAX_PATH];
	FileType type;

	while (dir.GetNext(entry, sizeof(entry), type)) {
		if (type != FileType_File) {
			continue;
		}

		int len = strlen(entry);
		if (len < 4 || !StrEqual(entry[len - 4], ".log")) {
			continue;
		}

		files.PushString(entry);
	}

	delete dir;

	int fileCount = files.Length;

	if (fileCount > maxFiles) {
		SortADTArray(files, Sort_Ascending, Sort_String);

		int toDelete = fileCount - maxFiles;
		char fullPath[PLATFORM_MAX_PATH];

		for (int i = 0; i < toDelete; i++) {
			files.GetString(i, entry, sizeof(entry));
			FormatEx(fullPath, sizeof(fullPath), "%s/%s", g_sLogDir, entry);
			DeleteFile(fullPath);
		}
	}

	delete files;
}

void EnsureLogDirectory()
{
	if (DirExists(g_sLogDir)) {
		return;
	}

	if (!CreateDirectory(g_sLogDir, 511)) {
		LogError("EnsureLogDirectory: could not create %s", g_sLogDir);
	}
}

bool IsValidArenaIndex(int arena)
{
	return arena > 0 && arena < MAX_ARENAS;
}
