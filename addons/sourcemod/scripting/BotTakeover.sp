#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define PLUGIN_VERSION "1.0.0"
#define CHAT_PREFIX "\x04[Takeover]\x01 "

// CS:S observer modes that follow one player
#define OBS_MODE_IN_EYE 4
#define OBS_MODE_CHASE 5

// CS:S standing player hull: a player taking the place of a crouching bot must fit there standing
static const float g_vHullMins[3] = { -16.0, -16.0, 0.0 };
static const float g_vHullMaxs[3] = { 16.0, 16.0, 72.0 };

ConVar g_cvEnable;
ConVar g_cvPerRound;
ConVar g_cvDamageDelay;
ConVar g_cvUseKey;
ConVar g_cvHint;
ConVar g_cvAnnounce;

// True while a taken over bot is killed: its death is hidden from events and from the game log
bool g_bSilentDeath;
bool g_bRoundOver;

int g_iTakeovers[MAXPLAYERS + 1];
int g_iLastButtons[MAXPLAYERS + 1];
int g_iLastTarget[MAXPLAYERS + 1];
float g_fLastHurt[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "BotTakeover",
	author = ".Rushaway",
	description = "Lets a dead player take control of a living bot of his team, like in CS:GO",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-BotTakeover"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSS)
	{
		strcopy(error, err_max, "This plugin only works on Counter-Strike: Source");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("BotTakeover.phrases");

	CreateConVar("sm_bottakeover_version", PLUGIN_VERSION, "BotTakeover version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("sm_takeover_enable", "1", "Let dead players take control of a living bot of their team", _, true, 0.0, true, 1.0);
	g_cvPerRound = CreateConVar("sm_takeover_per_round", "1", "Takeovers per player and per round, 0 = no limit", _, true, 0.0);
	g_cvDamageDelay = CreateConVar("sm_takeover_damage_delay", "2.0", "Seconds after a bot was last hurt before it can be taken over", _, true, 0.0);
	g_cvUseKey = CreateConVar("sm_takeover_use_key", "1", "Take over the spectated bot with the use key (E)", _, true, 0.0, true, 1.0);
	g_cvHint = CreateConVar("sm_takeover_hint", "1", "Show a hint when a dead player spectates a bot he can take over", _, true, 0.0, true, 1.0);
	g_cvAnnounce = CreateConVar("sm_takeover_announce", "1", "Tell the player's team who took control of which bot", _, true, 0.0, true, 1.0);
	AutoExecConfig(true);

	RegConsoleCmd("sm_takeover", Command_Takeover, "Take control of the bot you are spectating");

#if defined TAKEOVER_TEST
	RegServerCmd("sm_takeover_test", Command_Test, "Test build only: sm_takeover_test <dead player userid> <bot userid>");
#endif

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);

	AddGameLogHook(OnGameLog);

	for (int client = 1; client <= MaxClients; client++)
	{
		ResetClient(client);
	}
}

public void OnMapStart()
{
	g_bRoundOver = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		ResetClient(client);
	}
}

public void OnClientDisconnect(int client)
{
	ResetClient(client);
}

void ResetClient(int client)
{
	g_iTakeovers[client] = 0;
	g_iLastButtons[client] = 0;
	g_iLastTarget[client] = -1;
	g_fLastHurt[client] = 0.0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundOver = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		g_iTakeovers[client] = 0;
		g_iLastTarget[client] = -1;
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundOver = true;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (g_bSilentDeath)
		return Plugin_Handled;

	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim > 0)
		g_fLastHurt[victim] = GetGameTime();

	return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	// No kill feed line, and no kill or death for the stats plugins
	if (g_bSilentDeath)
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action OnGameLog(const char[] message)
{
	// The engine logs the bot's suicide on its own: keep it out of the log the stats daemon reads
	if (g_bSilentDeath)
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Command_Takeover(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[SM] %t", "Command is in-game only");
		return Plugin_Handled;
	}

	int bot = GetObservedBot(client);
	char sReason[64];
	if (!CanTakeOver(client, bot, sReason, sizeof(sReason)))
	{
		PrintToChat(client, "%s%t", CHAT_PREFIX, sReason);
		return Plugin_Handled;
	}

	TakeOver(client, bot);
	return Plugin_Handled;
}

#if defined TAKEOVER_TEST
// Lets a dead bot stand in for a player, to test the takeover without a human client
public Action Command_Test(int args)
{
	int client = GetClientOfUserId(GetCmdArgInt(1));
	int bot = GetClientOfUserId(GetCmdArgInt(2));
	if (client == 0 || bot == 0)
	{
		PrintToServer("[Takeover test] unknown userid");
		return Plugin_Handled;
	}

	char sReason[64];
	if (!CanTakeOver(client, bot, sReason, sizeof(sReason)))
	{
		PrintToServer("[Takeover test] refused: %s", sReason);
		return Plugin_Handled;
	}

	TakeOver(client, bot);
	PrintToServer("[Takeover test] %N alive %d team %d health %d armor %d, %N alive %d frags %d deaths %d",
		client, IsPlayerAlive(client), GetClientTeam(client), GetClientHealth(client), GetClientArmor(client),
		bot, IsPlayerAlive(bot), GetClientFrags(bot), GetClientDeaths(bot));
	return Plugin_Handled;
}
#endif

public void OnPlayerRunCmdPost(int client, int buttons)
{
	if (IsFakeClient(client) || IsPlayerAlive(client))
	{
		g_iLastButtons[client] = buttons;
		g_iLastTarget[client] = -1;
		return;
	}

	bool bPressed = (buttons & IN_USE) && !(g_iLastButtons[client] & IN_USE);
	g_iLastButtons[client] = buttons;

	if (!g_cvEnable.BoolValue)
		return;

	int bot = GetObservedBot(client);
	char sReason[64];

	if (bot != g_iLastTarget[client])
	{
		g_iLastTarget[client] = bot;
		if (bot > 0 && g_cvHint.BoolValue && g_cvUseKey.BoolValue && CanTakeOver(client, bot, sReason, sizeof(sReason)))
			PrintHintText(client, "%t", "Hint", bot);
	}

	if (!bPressed || !g_cvUseKey.BoolValue || bot <= 0)
		return;

	if (!CanTakeOver(client, bot, sReason, sizeof(sReason)))
	{
		PrintToChat(client, "%s%t", CHAT_PREFIX, sReason);
		return;
	}

	// Not inside the player's own command processing: respawn him on the next frame
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(GetClientUserId(bot));
	RequestFrame(Frame_TakeOver, pack);
}

public void Frame_TakeOver(DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int bot = GetClientOfUserId(pack.ReadCell());
	delete pack;

	char sReason[64];
	if (client == 0 || bot == 0 || !CanTakeOver(client, bot, sReason, sizeof(sReason)))
		return;

	TakeOver(client, bot);
}

// The living bot of his team a dead player is watching, or -1
int GetObservedBot(int client)
{
	int iMode = GetEntProp(client, Prop_Send, "m_iObserverMode");
	if (iMode != OBS_MODE_IN_EYE && iMode != OBS_MODE_CHASE)
		return -1;

	int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
	if (target < 1 || target > MaxClients || !IsClientInGame(target) || !IsFakeClient(target))
		return -1;

	return target;
}

bool CanTakeOver(int client, int bot, char[] reason, int maxlen)
{
	if (!g_cvEnable.BoolValue)
	{
		strcopy(reason, maxlen, "Disabled");
		return false;
	}

	if (IsPlayerAlive(client))
	{
		strcopy(reason, maxlen, "Must Be Dead");
		return false;
	}

	int iTeam = GetClientTeam(client);
	if (iTeam != CS_TEAM_T && iTeam != CS_TEAM_CT || GetEntProp(client, Prop_Send, "m_iClass") < 1)
	{
		strcopy(reason, maxlen, "Must Be In A Team");
		return false;
	}

	if (bot < 1 || bot > MaxClients || !IsClientInGame(bot) || !IsFakeClient(bot) || IsClientSourceTV(bot)
		|| !IsPlayerAlive(bot) || GetClientTeam(bot) != iTeam)
	{
		strcopy(reason, maxlen, "Not Watching A Bot");
		return false;
	}

	if (g_bRoundOver)
	{
		strcopy(reason, maxlen, "Round Over");
		return false;
	}

	if (GameRules_GetProp("m_bFreezePeriod"))
	{
		strcopy(reason, maxlen, "Freeze Time");
		return false;
	}

	if (g_cvPerRound.IntValue > 0 && g_iTakeovers[client] >= g_cvPerRound.IntValue)
	{
		strcopy(reason, maxlen, "Limit Reached");
		return false;
	}

	if (GetGameTime() - g_fLastHurt[bot] < g_cvDamageDelay.FloatValue)
	{
		strcopy(reason, maxlen, "Bot In Combat");
		return false;
	}

	if (IsBotBusy(bot))
	{
		strcopy(reason, maxlen, "Bot Busy");
		return false;
	}

	float vOrigin[3];
	GetClientAbsOrigin(bot, vOrigin);
	TR_TraceHullFilter(vOrigin, vOrigin, g_vHullMins, g_vHullMaxs, MASK_PLAYERSOLID, TraceFilter_NoPlayers);
	if (TR_DidHit())
	{
		strcopy(reason, maxlen, "No Room");
		return false;
	}

	return true;
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return entity > MaxClients;
}

// Planting, defusing or on a ladder: taking his place would cancel the action or drop the player
bool IsBotBusy(int bot)
{
	if (GetEntProp(bot, Prop_Send, "m_bIsDefusing"))
		return true;

	if (GetEntityMoveType(bot) == MOVETYPE_LADDER)
		return true;

	int iActive = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
	if (iActive != -1)
	{
		char sClass[32];
		GetEntityClassname(iActive, sClass, sizeof(sClass));
		if (StrEqual(sClass, "weapon_c4") && GetEntProp(iActive, Prop_Send, "m_bStartedArming"))
			return true;
	}

	return false;
}

void TakeOver(int client, int bot)
{
	float vOrigin[3], vAngles[3], vVelocity[3];
	GetClientAbsOrigin(bot, vOrigin);
	GetClientEyeAngles(bot, vAngles);
	GetEntPropVector(bot, Prop_Data, "m_vecAbsVelocity", vVelocity);

	int iHealth = GetClientHealth(bot);
	int iArmor = GetEntProp(bot, Prop_Send, "m_ArmorValue");
	int iHelmet = GetEntProp(bot, Prop_Send, "m_bHasHelmet");
	int iDefuser = GetEntProp(bot, Prop_Send, "m_bHasDefuser");
	int iNightVision = GetEntProp(bot, Prop_Send, "m_bHasNightVision");

	char sActive[32];
	int iActive = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
	if (iActive != -1)
		GetEntityClassname(iActive, sActive, sizeof(sActive));

	int iAmmoSize = GetEntPropArraySize(bot, Prop_Send, "m_iAmmo");
	int[] iAmmo = new int[iAmmoSize];
	for (int i = 0; i < iAmmoSize; i++)
	{
		iAmmo[i] = GetEntProp(bot, Prop_Send, "m_iAmmo", _, i);
	}

	char sBotName[MAX_NAME_LENGTH];
	GetClientName(bot, sBotName, sizeof(sBotName));

	// 1. The player respawns first, so his team is never seen wiped out
	CS_RespawnPlayer(client);
	if (!IsPlayerAlive(client))
		return;

	RemoveWeapons(client);

	// 2. The bot's own weapon entities move to the player: clip, silencer and burst mode stay as they were
	int iSize = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
	int[] iWeapons = new int[iSize];
	int[] iClips = new int[iSize];
	int iCount = 0;
	for (int i = 0; i < iSize; i++)
	{
		int weapon = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", i);
		if (weapon == -1)
			continue;

		int iClip = GetEntProp(weapon, Prop_Send, "m_iClip1");
		if (RemovePlayerItem(bot, weapon))
		{
			iWeapons[iCount] = weapon;
			iClips[iCount] = iClip;
			iCount++;
		}
	}

	// Nothing left to drop when the bot dies
	SetEntProp(bot, Prop_Send, "m_bHasDefuser", 0);

	// 3. The bot leaves silently: no kill feed, no score change, no body
	KillSilently(bot);

	// 4. The player takes the bot's place
	TeleportEntity(client, vOrigin, vAngles, vVelocity);

	for (int i = 0; i < iCount; i++)
	{
		EquipPlayerWeapon(client, iWeapons[i]);
		if (GetEntPropEnt(iWeapons[i], Prop_Send, "m_hOwnerEntity") != client)
		{
			RemoveEntity(iWeapons[i]);
			continue;
		}
		SetEntProp(iWeapons[i], Prop_Send, "m_iClip1", iClips[i]);
	}

	// Reserve ammo and grenade counts belong to the player, not to the weapons: set them after the weapons
	for (int i = 0; i < iAmmoSize; i++)
	{
		SetEntProp(client, Prop_Send, "m_iAmmo", iAmmo[i], _, i);
	}

	SetEntityHealth(client, iHealth);
	SetEntProp(client, Prop_Send, "m_ArmorValue", iArmor);
	SetEntProp(client, Prop_Send, "m_bHasHelmet", iHelmet);
	SetEntProp(client, Prop_Send, "m_bHasDefuser", iDefuser);
	SetEntProp(client, Prop_Send, "m_bHasNightVision", iNightVision);

	if (sActive[0] != '\0')
		FakeClientCommandEx(client, "use %s", sActive);

	g_iTakeovers[client]++;
	g_iLastTarget[client] = -1;

	LogAction(client, -1, "\"%L\" took control of bot \"%s\"", client, sBotName);
	PrintToChat(client, "%s%t", CHAT_PREFIX, "Took Over", sBotName);

	if (!g_cvAnnounce.BoolValue)
		return;

	int iTeam = GetClientTeam(client);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != client && IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == iTeam)
			PrintToChat(i, "%s%t", CHAT_PREFIX, "Teammate Took Over", client, sBotName);
	}
}

void RemoveWeapons(int client)
{
	int iSize = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < iSize; i++)
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (weapon != -1 && RemovePlayerItem(client, weapon))
			RemoveEntity(weapon);
	}
}

void KillSilently(int bot)
{
	int iFrags = GetClientFrags(bot);
	int iDeaths = GetClientDeaths(bot);

	g_bSilentDeath = true;
	ForcePlayerSuicide(bot);
	g_bSilentDeath = false;

	// A suicide costs a frag and adds a death: give them back
	SetEntProp(bot, Prop_Data, "m_iFrags", iFrags);
	SetEntProp(bot, Prop_Data, "m_iDeaths", iDeaths);

	int iRagdoll = GetEntPropEnt(bot, Prop_Send, "m_hRagdoll");
	if (iRagdoll > MaxClients && IsValidEntity(iRagdoll))
		RemoveEntity(iRagdoll);
}
