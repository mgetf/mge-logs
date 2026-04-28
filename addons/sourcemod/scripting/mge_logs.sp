#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>
#include <mge>
#include <ripext>

#define PLUGIN_VERSION "0.1.0"

#define MAX_ARENAS 64
#define MAX_SESSION_PLAYERS 4
#define MAX_STEAMID_LEN 32
#define MAX_LOG_LINE_LEN 768
#define MATCH_ID_LEN 17
#define MAX_UPLOAD_LOG_SIZE (512 * 1024)
#define MAX_LAST_LOG_URL_LEN 256
#define MAX_HOSTNAME_LEN 128
#define MAX_AUTH_HEADER_LEN 160

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
ConVar g_cvUpload;
ConVar g_cvApiKey;
ConVar g_cvUploadUrl;
ConVar g_cvHostname;

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

char g_sLastLogUrl[MAXPLAYERS + 1][MAX_LAST_LOG_URL_LEN];

static char s_UploadLogBuf[MAX_UPLOAD_LOG_SIZE];

public void OnPluginStart()
{
	g_cvEnabled   = CreateConVar("mge_logs_enabled",    "1",  "Master switch for match logging.", _, true, 0.0, true, 1.0);
	g_cvMaxFiles  = CreateConVar("mge_logs_max_files",  "1000", "Max log files to keep in logs/mge/.", _, true, 0.0);
	g_cvUpload    = CreateConVar("mge_logs_upload",     "0",  "Upload completed logs to the mge.tf backend.", _, true, 0.0, true, 1.0);
	g_cvApiKey    = CreateConVar("mge_logs_apikey",     "",   "API key for log upload.", FCVAR_PROTECTED);
	g_cvUploadUrl = CreateConVar("mge_logs_upload_url", "",   "Full endpoint URL for log upload (e.g. https://mge.tf/api/logs/upload).");

	g_cvHostname = FindConVar("hostname");

	RegConsoleCmd("sm_lastlog", Cmd_LastLog);
	AddCommandListener(Listener_Say, "say");
	AddCommandListener(Listener_Say, "say_team");

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

public void OnClientDisconnected(int client)
{
	g_sLastLogUrl[client][0] = '\0';
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

	if (!g_bSessionActive[arena_index] || g_bSessionPendingFlush[arena_index]) {
		return;
	}

	char steamId[MAX_STEAMID_LEN];
	if (!GetClientAuthId(client, AuthId_Steam3, steamId, sizeof(steamId))) {
		return;
	}

	bool isInSession = false;
	for (int i = 0; i < g_iSessionPlayerCount[arena_index]; i++) {
		if (StrEqual(steamId, g_sSessionPlayers[arena_index][i])) {
			isInSession = true;
			break;
		}
	}

	if (isInSession) {
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
			bool team1Won = g_iSession2v2WinningTeam[arena_index] == 2;
			strcopy(winTeam, sizeof(winTeam), team1Won ? "Red" : "Blue");

			// team1 = players[0..1] (Red), team2 = players[2..3] (Blue)
			int w1 = team1Won ? 0 : 2;
			int w2 = team1Won ? 1 : 3;
			int l1 = team1Won ? 2 : 0;
			int l2 = team1Won ? 3 : 1;

			AppendMetaLine(arena_index,
				"World triggered \"mge_match_end\" (winning_team \"%s\") (winning_score \"%d\") (losing_score \"%d\") (winner_p1 \"%s\") (winner_p2 \"%s\") (loser_p1 \"%s\") (loser_p2 \"%s\")",
				winTeam,
				g_iSessionWinnerScore[arena_index],
				g_iSessionLoserScore[arena_index],
				g_sSessionPlayers[arena_index][w1],
				g_sSessionPlayers[arena_index][w2],
				g_sSessionPlayers[arena_index][l1],
				g_sSessionPlayers[arena_index][l2]);
		}
		else {
			AppendMetaLine(arena_index,
				"World triggered \"mge_match_end\" (winner \"%s\") (loser \"%s\") (winner_score \"%d\") (loser_score \"%d\")",
				g_sSessionWinnerSteamId[arena_index],
				g_sSessionLoserSteamId[arena_index],
				g_iSessionWinnerScore[arena_index],
				g_iSessionLoserScore[arena_index]);
		}

		char filePath[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, filePath, sizeof(filePath),
			"logs/mge/mge_%s.log", g_sSessionMatchId[arena_index]);

		if (FlushSession(arena_index)) {
			UploadSession(arena_index, filePath);
		}
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

bool ReadLogFile(const char[] path, char[] buffer, int maxlen)
{
	File f = OpenFile(path, "r");
	if (f == null) {
		return false;
	}

	int pos = 0;
	char line[MAX_LOG_LINE_LEN];

	while (!f.EndOfFile() && f.ReadLine(line, sizeof(line))) {
		int lineLen = strlen(line);
		if (pos + lineLen >= maxlen) {
			f.Close();
			LogError("[mge_logs] Log file too large to upload (>%d bytes): %s", maxlen, path);
			return false;
		}
		strcopy(buffer[pos], maxlen - pos, line);
		pos += lineLen;
	}

	buffer[pos] = '\0';
	f.Close();
	return true;
}

void NotifyArenaPlayers(int arena, const char[] message)
{
	for (int i = 0; i < g_iSessionPlayerCount[arena]; i++) {
		if (g_sSessionPlayers[arena][i][0] == '\0') {
			continue;
		}

		for (int client = 1; client <= MaxClients; client++) {
			if (!IsClientInGame(client)) {
				continue;
			}

			char clientSteamId[MAX_STEAMID_LEN];
			if (GetClientAuthId(client, AuthId_Steam3, clientSteamId, sizeof(clientSteamId))
				&& StrEqual(clientSteamId, g_sSessionPlayers[arena][i]))
			{
				PrintToChat(client, "%s", message);
			}
		}
	}
}

void UploadSession(int arena, const char[] filePath)
{
	if (!g_cvUpload.BoolValue || !LibraryExists("ripext")) {
		return;
	}

	char apiKey[128], url[256];
	g_cvApiKey.GetString(apiKey, sizeof(apiKey));
	g_cvUploadUrl.GetString(url, sizeof(url));

	if (apiKey[0] == '\0' || url[0] == '\0') {
		return;
	}

	if (!ReadLogFile(filePath, s_UploadLogBuf, sizeof(s_UploadLogBuf))) {
		return;
	}

	NotifyArenaPlayers(arena, "[MGE] Uploading match log...");

	char hostname[MAX_HOSTNAME_LEN];
	if (g_cvHostname != null) {
		g_cvHostname.GetString(hostname, sizeof(hostname));
	}

	DataPack pack = new DataPack();
	pack.WriteString(filePath);
	pack.WriteString(apiKey);
	pack.WriteString(url);
	pack.WriteString(g_sSessionMatchId[arena]);
	pack.WriteString(hostname);
	pack.WriteCell(g_iSessionPlayerCount[arena]);
	for (int i = 0; i < g_iSessionPlayerCount[arena]; i++) {
		pack.WriteString(g_sSessionPlayers[arena][i]);
	}

	char authHeader[MAX_AUTH_HEADER_LEN];
	FormatEx(authHeader, sizeof(authHeader), "Bearer %s", apiKey);

	JSONObject payload = new JSONObject();
	payload.SetString("matchid", g_sSessionMatchId[arena]);
	payload.SetString("log", s_UploadLogBuf);
	if (hostname[0] != '\0') {
		payload.SetString("hostname", hostname);
	}

	HTTPRequest request = new HTTPRequest(url);
	request.SetHeader("Authorization", authHeader);
	request.Post(payload, Upload_Complete, pack);
	delete payload;
}

void StoreUrlForSteamId(const char[] steamId, const char[] logUrl)
{
	for (int client = 1; client <= MaxClients; client++) {
		if (!IsClientInGame(client)) {
			continue;
		}

		char clientSteamId[MAX_STEAMID_LEN];
		if (GetClientAuthId(client, AuthId_Steam3, clientSteamId, sizeof(clientSteamId))
			&& StrEqual(clientSteamId, steamId))
		{
			strcopy(g_sLastLogUrl[client], MAX_LAST_LOG_URL_LEN, logUrl);
		}
	}
}

void DoStoreUrlFromPack(DataPack pack, const char[] logUrl)
{
	char skipBuf[PLATFORM_MAX_PATH];
	char skipSmall[MATCH_ID_LEN];
	char skipHostname[MAX_HOSTNAME_LEN];
	pack.Reset();
	pack.ReadString(skipBuf, sizeof(skipBuf));         // filePath
	pack.ReadString(skipBuf, sizeof(skipBuf));         // apiKey
	pack.ReadString(skipBuf, sizeof(skipBuf));         // uploadUrl
	pack.ReadString(skipSmall, sizeof(skipSmall));     // matchId
	pack.ReadString(skipHostname, sizeof(skipHostname)); // hostname

	int count = pack.ReadCell();
	for (int i = 0; i < count; i++) {
		char steamId[MAX_STEAMID_LEN];
		pack.ReadString(steamId, sizeof(steamId));
		StoreUrlForSteamId(steamId, logUrl);

		for (int client = 1; client <= MaxClients; client++) {
			if (!IsClientInGame(client)) {
				continue;
			}

			char clientSteamId[MAX_STEAMID_LEN];
			if (GetClientAuthId(client, AuthId_Steam3, clientSteamId, sizeof(clientSteamId))
				&& StrEqual(clientSteamId, steamId))
			{
				PrintToChat(client, "[MGE] Log uploaded! %s", logUrl);
			}
		}
	}
}

void NotifyPlayersOfError(DataPack pack, const char[] errorMsg)
{
	char skipBuf[PLATFORM_MAX_PATH];
	char skipSmall[MATCH_ID_LEN];
	char skipHostname[MAX_HOSTNAME_LEN];
	pack.Reset();
	pack.ReadString(skipBuf, sizeof(skipBuf));         // filePath
	pack.ReadString(skipBuf, sizeof(skipBuf));         // apiKey
	pack.ReadString(skipBuf, sizeof(skipBuf));         // uploadUrl
	pack.ReadString(skipSmall, sizeof(skipSmall));     // matchId
	pack.ReadString(skipHostname, sizeof(skipHostname)); // hostname

	int count = pack.ReadCell();
	for (int i = 0; i < count; i++) {
		char steamId[MAX_STEAMID_LEN];
		pack.ReadString(steamId, sizeof(steamId));

		for (int client = 1; client <= MaxClients; client++) {
			if (!IsClientInGame(client)) {
				continue;
			}

			char clientSteamId[MAX_STEAMID_LEN];
			if (GetClientAuthId(client, AuthId_Steam3, clientSteamId, sizeof(clientSteamId))
				&& StrEqual(clientSteamId, steamId))
			{
				PrintToChat(client, "[MGE] Log upload failed: %s", errorMsg);
			}
		}
	}
}

public void Upload_Complete(HTTPResponse response, DataPack pack, const char[] error)
{
	if (response.Status != HTTPStatus_OK) {
		int statusCode = view_as<int>(response.Status);

		if (statusCode >= 400 && statusCode < 500) {
			char errorMsg[256];
			errorMsg = "parse error";

			JSONObject errJson = view_as<JSONObject>(response.Data);
			if (errJson != null) {
				errJson.GetString("error", errorMsg, sizeof(errorMsg));
			}

			LogError("[mge_logs] Upload rejected (HTTP %d): %s", statusCode, errorMsg);
			NotifyPlayersOfError(pack, errorMsg);
			delete pack;
			return;
		}

		LogError("[mge_logs] Upload failed (HTTP %d): %s", statusCode, error);
		NotifyPlayersOfError(pack, "server error, retrying in 5s...");
		CreateTimer(5.0, Timer_RetryUpload, pack);
		return;
	}

	JSONObject json = view_as<JSONObject>(response.Data);
	char logUrl[MAX_LAST_LOG_URL_LEN];

	if (!json.GetString("url", logUrl, sizeof(logUrl))) {
		LogError("[mge_logs] Upload response missing 'url' field");
		delete pack;
		return;
	}

	DoStoreUrlFromPack(pack, logUrl);
	delete pack;
}

public Action Timer_RetryUpload(Handle timer, DataPack pack)
{
	pack.Reset();
	char filePath[PLATFORM_MAX_PATH], apiKey[128], url[256], matchId[MATCH_ID_LEN];
	char hostname[MAX_HOSTNAME_LEN];
	pack.ReadString(filePath, sizeof(filePath));
	pack.ReadString(apiKey, sizeof(apiKey));
	pack.ReadString(url, sizeof(url));
	pack.ReadString(matchId, sizeof(matchId));
	pack.ReadString(hostname, sizeof(hostname));

	if (!ReadLogFile(filePath, s_UploadLogBuf, sizeof(s_UploadLogBuf))) {
		LogError("[mge_logs] Retry upload: could not re-read log file %s", filePath);
		delete pack;
		return Plugin_Stop;
	}

	char authHeader[MAX_AUTH_HEADER_LEN];
	FormatEx(authHeader, sizeof(authHeader), "Bearer %s", apiKey);

	JSONObject payload = new JSONObject();
	payload.SetString("matchid", matchId);
	payload.SetString("log", s_UploadLogBuf);
	if (hostname[0] != '\0') {
		payload.SetString("hostname", hostname);
	}

	HTTPRequest request = new HTTPRequest(url);
	request.SetHeader("Authorization", authHeader);
	request.Post(payload, Upload_RetryComplete, pack);
	delete payload;

	return Plugin_Stop;
}

public void Upload_RetryComplete(HTTPResponse response, DataPack pack, const char[] error)
{
	if (response.Status != HTTPStatus_OK) {
		int statusCode = view_as<int>(response.Status);

		if (statusCode >= 400 && statusCode < 500) {
			char errorMsg[256];
			errorMsg = "parse error";

			JSONObject errJson = view_as<JSONObject>(response.Data);
			if (errJson != null) {
				errJson.GetString("error", errorMsg, sizeof(errorMsg));
			}

			LogError("[mge_logs] Upload retry rejected (HTTP %d): %s", statusCode, errorMsg);
			NotifyPlayersOfError(pack, errorMsg);
		} else {
			LogError("[mge_logs] Upload retry failed (HTTP %d): %s", statusCode, error);
		}

		delete pack;
		return;
	}

	JSONObject json = view_as<JSONObject>(response.Data);
	char logUrl[MAX_LAST_LOG_URL_LEN];

	if (!json.GetString("url", logUrl, sizeof(logUrl))) {
		LogError("[mge_logs] Upload retry response missing 'url' field");
		delete pack;
		return;
	}

	DoStoreUrlFromPack(pack, logUrl);
	delete pack;
}

public Action Cmd_LastLog(int client, int args)
{
	if (client == 0) {
		return Plugin_Handled;
	}

	ShowLastLog(client);
	return Plugin_Handled;
}

public Action Listener_Say(int client, const char[] command, int argc)
{
	if (client == 0) {
		return Plugin_Continue;
	}

	char text[32];
	GetCmdArg(1, text, sizeof(text));

	if (!StrEqual(text, "!lastlog") && !StrEqual(text, ".lastlog")) {
		return Plugin_Continue;
	}

	ShowLastLog(client);

	if (g_sLastLogUrl[client][0] != '\0') {
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

void ShowLastLog(int client)
{
	if (g_sLastLogUrl[client][0] == '\0') {
		PrintToChat(client, "[MGE] No recent log found.");
		return;
	}

	QueryClientConVar(client, "cl_disablehtmlmotd", QueryConVar_HtmlMotd, client);
}

public void QueryConVar_HtmlMotd(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	if (!IsClientInGame(client)) {
		return;
	}

	if (result == ConVarQuery_Okay && StringToInt(cvarValue) != 0) {
		PrintToChat(client, "[MGE] Last log: %s", g_sLastLogUrl[client]);
		return;
	}

	KeyValues kv = new KeyValues("data");
	char typeStr[4];
	IntToString(MOTDPANEL_TYPE_URL, typeStr, sizeof(typeStr));
	kv.SetString("title", "MGE Logs");
	kv.SetString("type", typeStr);
	kv.SetString("msg", g_sLastLogUrl[client]);
	kv.SetNum("customsvr", 1);
	ShowVGUIPanel(client, "info", kv);
	delete kv;
}
