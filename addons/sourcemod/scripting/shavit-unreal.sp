#pragma semicolon 1

#define UNREALPHYS_VERSION "1.2"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <clientprefs>
#include <shavit.inc>

enum struct GunJumpConfig
{
	char Weapon[64];
	float Range;
	float Boost_Horizontal;
	float Boost_Vertical;
	float Boost_Horizontal_Mod;
	float Boost_Vertical_Mod;
	int Primary_Clip_Max_Size;
}

// Gun jumping
GunJumpConfig	g_GunJumpConfig[32];
int	g_TotalGuns;

// Dodging
float g_LastSideMove[MAXPLAYERS + 1][2];
int g_LastDodgeTick[MAXPLAYERS + 1];
int g_LandingTick[MAXPLAYERS + 1];
int g_LastTapTick[MAXPLAYERS + 1];
int g_LastTapKey[MAXPLAYERS + 1];
bool g_bCanDodge[MAXPLAYERS + 1];
bool g_bWaitingForGround[MAXPLAYERS + 1];

// Double jumping
bool g_Jumped[MAXPLAYERS + 1];
int g_LastButtons[MAXPLAYERS + 1];
int g_UnaffectedButtons[MAXPLAYERS + 1];

ConVar g_hModifiedUnreal;
bool   g_bModifiedUnreal;

bool g_bUnrealClients[MAXPLAYERS + 1];

bool gB_Late = false;

Handle gH_USPCookie = null;
bool g_USPUsers[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "[Shavit] Unreal Physics",
	author = "blacky",
	description = "Simulates physics from the Unreal Tournament games",
	version = UNREALPHYS_VERSION,
	url = "http://steamcommunity.com/id/blaackyy/"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gB_Late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{	
	// Command that reloads the gun boosting config
	RegAdminCmd("sm_reloadunreal", SM_ReloadGJ, ADMFLAG_RCON, "Reloads the gun jumping config.");

	RegConsoleCmd("sm_unrealglock", Command_Glock, "Sets default unreal gun to Glock.");
	RegConsoleCmd("sm_unrealusp", Command_USP, "Sets default unreal gun to USP.");
	gH_USPCookie = RegClientCookie("unreal_usp", "Glock is 0. USP is 1.", CookieAccess_Protected);
	
	// Initialize gun boosting config
	LoadGunJumpConfig();
	
	g_hModifiedUnreal = CreateConVar("shavit_unreal_modified", "1", "Uses modified boosting which affects boost values. boost_hor and boost_vert should be around 2000 for this version", 0, true, 0.0, true, 1.0);
	HookConVarChange(g_hModifiedUnreal, OnModifiedUnrealChanged);

	AutoExecConfig(true, "shavit-unreal");

	HookEvent("weapon_fire", Event_WeaponFire);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

	if(gB_Late)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			g_bUnrealClients[i] = IsStyleUnreal(Shavit_GetBhopStyle(i));
		}
	}
}

public Action Command_Glock(int client, int args)
{
	if(!IsValidClient(client))
		return Plugin_Handled;

	g_USPUsers[client] = false;
	char sCookie[4];
	IntToString(view_as<int>(g_USPUsers[client]), sCookie, 4);
	SetClientCookie(client, gH_USPCookie, sCookie);

	Shavit_PrintToChat(client, "Using Glock for Unreal.");
	return Plugin_Handled;
}

public Action Command_USP(int client, int args)
{
	if(!IsValidClient(client))
		return Plugin_Handled;

	g_USPUsers[client] = true;
	char sCookie[4];
	IntToString(view_as<int>(g_USPUsers[client]), sCookie, 4);
	SetClientCookie(client, gH_USPCookie, sCookie);

	Shavit_PrintToChat(client, "Using USP for Unreal.");
	return Plugin_Handled;
}

public void OnClientCookiesCached(int client)
{
	if(IsFakeClient(client))
	{
		return;
	}

	char sSetting[8];
	GetClientCookie(client, gH_USPCookie, sSetting, 8);

	if(strlen(sSetting) == 0)
	{
		SetClientCookie(client, gH_USPCookie, "0");
		g_USPUsers[client] = false;
	}
	else
	{
		g_USPUsers[client] = view_as<bool>(StringToInt(sSetting));
	}
}

bool IsStyleUnreal(int style)
{
	// Blacky's timer
	//return Style(style).HasSpecialKey("gunboost");
	
	// Shavit's timer
	char name[128];
	int status = Shavit_GetStyleStrings(style, sSpecialString, name, sizeof(name));
	return status == SP_ERROR_NONE && (StrContains(name, "unreal") != -1);
}

bool IsPlayerUsingUnreal(int client)
{
	// Blacky's timer
	//return Style(TimerInfo(client).ActiveStyle).HasSpecialKey("gunboost");
	
	// Shavit's timer
	return g_bUnrealClients[client];
}

public void OnModifiedUnrealChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bModifiedUnreal = GetConVarBool(g_hModifiedUnreal);
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	// Reset player settings
	g_LastSideMove[client][0]   = 0.0;
	g_LastSideMove[client][0]   = 0.0;
	g_LastDodgeTick[client]     = 0;
	g_LandingTick[client]       = 0;
	g_LastTapTick[client]       = 0;
	g_LastTapKey[client]        = 0;
	g_bCanDodge[client]         = false;
	g_bWaitingForGround[client] = false;
	g_Jumped[client]            = false;
	g_LastButtons[client]       = 0;
	g_UnaffectedButtons[client] = 0;
	g_bUnrealClients[client]    = false;
	
	return true;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("user.id"));
	if (g_bUnrealClients[client])
		givegunstuff(client);
}

void givegunstuff(int client)
{
	if (IsPlayerAlive(client))
	{
		//Client_RemoveAllWeapons(client);
		int weaponIndex = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
		if(weaponIndex != -1)
		{
			CS_DropWeapon(client, weaponIndex, false, false);
		}
		/*weaponIndex = */
		if (g_USPUsers[client])
			GivePlayerItem(client, (GetEngineVersion() == Engine_CSGO) ? "weapon_usp_silencer" : "weapon_usp");
		else
			GivePlayerItem(client, "weapon_glock");
		
		/*
		if(weaponIndex != -1)
		{
			Handle hPack = CreateDataPack();
			WritePackCell(hPack, GetClientUserId(client));
			WritePackCell(hPack, EntIndexToEntRef(weaponIndex));
			RequestFrame(NextFrame_EquipWeapon, hPack);
		}
		*/
	}
}

public void Shavit_OnStyleChanged(int client, int oldStyle, int newStyle)
{
	if(IsStyleUnreal(newStyle))
	{
		Shavit_PrintToChat(client, "Use !unrealglock or !unrealusp to set your default pistol.");
		g_bUnrealClients[client] = true;
		givegunstuff(client);
	}
	else
	{
		g_bUnrealClients[client] = false;
	}
}

public void NextFrame_EquipWeapon(Handle pack)
{
	ResetPack(pack);
	int client = GetClientOfUserId(ReadPackCell(pack));
	if(client != 0)
	{
		int weaponIndex = EntRefToEntIndex(ReadPackCell(pack));
		if(weaponIndex != INVALID_ENT_REFERENCE)
		{
			EquipPlayerWeapon(client, weaponIndex);
		}
	}
	delete pack;
}

public Action SM_ReloadGJ(int client, int args)
{	
	LoadGunJumpConfig();
	
	ReplyToCommand(client, "[Unreal Physics] - Gunjump config reloaded.");
	
	return Plugin_Handled;
}

FindWeaponConfigByWeaponName(const char[] sWeapon)
{
	for(new i; i < g_TotalGuns; i++)
	{
		if(StrEqual(sWeapon, g_GunJumpConfig[i].Weapon))
		{
			return i;
		}
	}
	
	return -1;
}

void LoadGunJumpConfig()
{
	decl String:sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/gunjump.cfg");
	
	new Handle:kv = CreateKeyValues("Gun Jump Settings");
	FileToKeyValues(kv, sPath);
	
	if(kv != INVALID_HANDLE)
	{
		new Key, bool:KeyExists = true, String:sKey[32];
		
		do
		{
			IntToString(Key, sKey, sizeof(sKey));
			KeyExists = KvJumpToKey(kv, sKey);
			
			if(KeyExists == true)
			{
				KvGetString(kv, "weapon", g_GunJumpConfig[Key].Weapon, 32);
				g_GunJumpConfig[Key].Range                     = KvGetFloat(kv, "range", 100.0);
				//g_GunJumpConfig[Key].Damage                    = KvGetFloat(kv, "damage", 5.0);
				//g_GunJumpConfig[Key].Auto_Health_Regen         = bool:KvGetNum(kv, "auto_health_regen", 1);
				//g_GunJumpConfig[Key].Health_Regen_Rate         = KvGetNum(kv, "health_regen_rate", 5);
				//g_GunJumpConfig[Key].Max_Health                = KvGetNum(kv, "max_health", 100);
				g_GunJumpConfig[Key].Boost_Horizontal          = KvGetFloat(kv, "boost_hor", 1.0);
				g_GunJumpConfig[Key].Boost_Vertical            = KvGetFloat(kv, "boost_vert", 1.0);
				g_GunJumpConfig[Key].Boost_Horizontal_Mod      = KvGetFloat(kv, "boost_hor_mod", 1.0);
				g_GunJumpConfig[Key].Boost_Vertical_Mod        = KvGetFloat(kv, "boost_vert_mod", 1.0);
				//g_GunJumpConfig[Key].Primary_Clip_Size         = KvGetNum(kv, "clip_size", 100);
				g_GunJumpConfig[Key].Primary_Clip_Max_Size     = KvGetNum(kv, "clip_max", 100);
				//g_GunJumpConfig[Key].Primary_Clip_Regen_Rate   = KvGetNum(kv, "clip_regen", 5);
				//g_GunJumpConfig[Key].Primary_Clip_Auto_Regen   = bool:KvGetNum(kv, "clip_auto_regen", 0);
				
				KvGoBack(kv);
				Key++;
			}
		}
		while(KeyExists == true && Key < 32);
			
		CloseHandle(kv);
		
		g_TotalGuns = Key;
	}
	else
	{
		LogError("Something went wrong reading from the gunjump.cfg file.");
	}
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if(!(0 < client <= MaxClients))
	{
		return;
	}
	
	if(IsFakeClient(client))
	{
		return;
	}
	
	if(!IsPlayerUsingUnreal(client))
	{
		return;
	}
	
	// Stop boost if invalid weapon
	char sWeapon[64];
	GetEventString(event, "weapon", sWeapon, sizeof(sWeapon));
	if (StrContains(sWeapon, "weapon_") == -1)
		Format(sWeapon, sizeof(sWeapon), "weapon_%s", sWeapon);
	int GunConfig = FindWeaponConfigByWeaponName(sWeapon);
	if(GunConfig == -1)
		return;
		
	int slot2 = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	if (IsValidEntity(slot2))
	{
		if(GetEntProp(slot2, Prop_Data, "m_iState") == 2)
		{
			SetEntProp(slot2, Prop_Data, "m_iClip1", g_GunJumpConfig[GunConfig].Primary_Clip_Max_Size + 1);
		}
	}
	
	float vPos[3];
	GetClientEyePosition(client, vPos);
	
	float vAng[3];
	GetClientEyeAngles(client, vAng);
	
	TR_TraceRayFilter(vPos, vAng, MASK_PLAYERSOLID_BRUSHONLY, RayType_Infinite, TraceRayDontHitSelf, client);
	
	if(TR_DidHit())
	{
		float vHitPos[3];
		TR_GetEndPosition(vHitPos);

		if(GetVectorDistance(vPos, vHitPos) <= g_GunJumpConfig[GunConfig].Range)
		{
			float vPush[3];
			MakeVectorFromPoints(vHitPos, vPos, vPush);

			if (g_bModifiedUnreal) {
				NormalizeVector(vPush, vPush);
				vPush[0] *= g_GunJumpConfig[GunConfig].Boost_Horizontal_Mod;
				vPush[1] *= g_GunJumpConfig[GunConfig].Boost_Horizontal_Mod;
				vPush[2] *= g_GunJumpConfig[GunConfig].Boost_Vertical_Mod;
			} else {
				vPush[0] *= g_GunJumpConfig[GunConfig].Boost_Horizontal;
				vPush[1] *= g_GunJumpConfig[GunConfig].Boost_Horizontal;
				vPush[2] *= g_GunJumpConfig[GunConfig].Boost_Vertical;
			}

			float vVel[3];
			float vResult[3];
			GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
			AddVectors(vPush, vVel, vResult);
			TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vResult);
		}
	}
	
	return;
}

public bool TraceRayDontHitSelf(entity, mask, any:data)
{
	if(entity == data)
	{
		return false;
	}
	
	if(0 < entity <= MaxClients)
	{
		return false;
	}
	
	char sClass[64];
	GetEntityClassname(entity, sClass, 64);
	if(StrContains(sClass, "weapon_") != -1)
	{
		return false;
	}
	
	return true;
}

int Unreal_GetButtons(int client)
{
	// Blacky's timer
	//return Timer_GetButtons(client);
	
	// Shavit's timer
	return g_UnaffectedButtons[client];
}

public Action Shavit_OnUserCmdPre(int client, int &buttons, int &impulse, float vel[3], float angles[3], TimerStatus status, int track, int style, stylesettings_t stylesettings, int mouse[2])
{
	g_UnaffectedButtons[client] = buttons;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if(IsPlayerAlive(client) && !IsFakeClient(client) && IsPlayerUsingUnreal(client))
	{
		// Dodge detection
		CheckForKeyTap(client, vel);
				
		// Double jump detection
		CheckForJumpTap(client, Unreal_GetButtons(client));
	}
	
	g_LastSideMove[client][0] = vel[0];
	g_LastSideMove[client][1] = vel[1];
	g_LastButtons[client]     = Unreal_GetButtons(client);
}

CheckForKeyTap(int client, float vel[3])
{
	if(GetEntityFlags(client) & FL_ONGROUND)
	{
		g_bCanDodge[client] = true;
		
		if(g_bWaitingForGround[client] == true)
		{
			g_bWaitingForGround[client] = false;
			g_LandingTick[client]       = GetGameTickCount();
		}
	}
	
	if(g_bCanDodge[client] == false)
		return;
	
	if((float(GetGameTickCount())*GetTickInterval() - float(g_LandingTick[client])*GetTickInterval()) < 0.3)
		return;
	
	if(g_LastSideMove[client][1] <= 0 && vel[1] > 0)
		OnClientTappedKey(client, IN_MOVERIGHT);
	else if(g_LastSideMove[client][1] >= 0 && vel[1] < 0)
		OnClientTappedKey(client, IN_MOVELEFT);
	else if(g_LastSideMove[client][0] <= 0 && vel[0] > 0)
		OnClientTappedKey(client, IN_FORWARD);
	else if(g_LastSideMove[client][0] >= 0 && vel[0] < 0)
		OnClientTappedKey(client, IN_BACK);
}

OnClientTappedKey(int client, int Key)
{
	if(g_LastTapKey[client] == Key && (float(GetGameTickCount())*GetTickInterval() - float(g_LastTapTick[client])*GetTickInterval() < 0.2))
	{
		OnClientDoubleTappedKey(client, Key);
	}
	
	g_LastTapKey[client]  = Key;
	g_LastTapTick[client] = GetGameTickCount();
}

OnClientDoubleTappedKey(int client, int Key)
{
	float vAng[3];
	GetClientEyeAngles(client, vAng);
	vAng[0] = 0.0; // Ensures consistent dodges if player is considered to be facing straight outwards
	
	// Get direction player wants to dodge to
	float vDodgeDir[3];
	if(Key == IN_MOVERIGHT)
	{
		GetAngleVectors(vAng, NULL_VECTOR, vDodgeDir, NULL_VECTOR);
	}
	else if(Key == IN_MOVELEFT)
	{
		GetAngleVectors(vAng, NULL_VECTOR, vDodgeDir, NULL_VECTOR);
		NegateVector(vDodgeDir);
	}
	else if(Key == IN_FORWARD)
	{
		GetAngleVectors(vAng, vDodgeDir, NULL_VECTOR, NULL_VECTOR);
	}
	else if(Key == IN_BACK)
	{
		GetAngleVectors(vAng, vDodgeDir, NULL_VECTOR, NULL_VECTOR);
		NegateVector(vDodgeDir);
	}
	
	// Checks if a client is allowed to dodge (from ground or from wall)
	bool bCanDodge;
	if(GetEntityFlags(client) & FL_ONGROUND)
	{
		bCanDodge = true;
	}
	else
	{
		float vPos[3];
		GetEntPropVector(client, Prop_Data, "m_vecOrigin", vPos);
		
		float vTraceAngle[3];
		vTraceAngle[0] = vDodgeDir[0];
		vTraceAngle[1] = vDodgeDir[1];
		vTraceAngle[2] = vDodgeDir[2];
		NegateVector(vTraceAngle);
		GetVectorAngles(vTraceAngle, vTraceAngle);
		
		TR_TraceRayFilter(vPos, vTraceAngle, MASK_PLAYERSOLID_BRUSHONLY, RayType_Infinite, TraceRayDontHitSelf, client);
		
		if(TR_DidHit())
		{
			float vHitPos[3];
			TR_GetEndPosition(vHitPos);
			
			if(GetVectorDistance(vPos, vHitPos) < 30)
			{
				bCanDodge = true;
			}
		}
	}
	
	// Dodges client if they are allowed to dodge
	if(bCanDodge == true)
	{
		vDodgeDir[0] *= 400.0;
		vDodgeDir[1] *= 400.0;
		
		float vVel[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
		
		float vResult[3];
		AddVectors(vVel, vDodgeDir, vResult);
		vResult[2] = 251.0;
		
		// This line and following timer allows setting a player's vertical velocity when they are on the ground to something lower than 250.0
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vResult);
		
		DataPack hData;
		CreateDataTimer(0.0, Timer_Dodge, hData, TIMER_DATA_HNDL_CLOSE);
		WritePackCell(hData, client);
		WritePackFloat(hData, vResult[0]);
		WritePackFloat(hData, vResult[1]);
		WritePackFloat(hData, vResult[2]);
		
		g_LastDodgeTick[client] = GetGameTickCount();
		
		float vPos[3];
		GetClientEyePosition(client, vPos);
	}
}

public Action Timer_Dodge(Handle timer, DataPack data)
{
	ResetPack(data);
	int client = ReadPackCell(data);
	
	float vVel[3];
	vVel[0] = ReadPackFloat(data);
	vVel[1] = ReadPackFloat(data);
	vVel[2] = 150.0;
	
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vVel);
	
	g_bWaitingForGround[client] = true;
	g_bCanDodge[client]         = false;
}

CheckForJumpTap(int client, int buttons)
{
	if(!(GetEntityFlags(client) & FL_ONGROUND))
	{
		float vVel[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
		
		if(!(g_LastButtons[client] & IN_JUMP) && (buttons & IN_JUMP) && g_Jumped[client] == false && (-60.0 <= vVel[2] <= 90.0))
		{
			vVel[2] = 290.0;
			TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vVel);
			
			g_Jumped[client] = true;
			
			Event hEventJump = CreateEvent("player_jump", true);
			
			if(hEventJump != INVALID_HANDLE)
			{
				SetEventInt(hEventJump, "userid", GetClientUserId(client));
				FireEvent(hEventJump);
			}
		}
	}
	else
	{
		g_Jumped[client] = false;
	}
}
