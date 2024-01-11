/*
*	Melee Weapon Fatigue
*	Copyright (C) 2024 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION		"1.0"

/*=======================================================================================
	Plugin Info:

*	Name	:	[L4D2] Melee Weapon Fatigue
*	Author	:	SilverShot
*	Descrp	:	Introduces the shove penalty fatigue system to melee weapon, combining the two together.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=345411
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.0 (11-Jan-2024)
	- Initial release.

======================================================================================*/

#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <left4dhooks>

#define CVAR_FLAGS			FCVAR_NOTIFY
#define GAMEDATA			"l4d2_melee_fatigue"
#define CONFIG_DATA			"data/l4d2_melee_fatigue.cfg"


ConVar g_hCvarAllow, g_hCvarMPGameMode, g_hCvarModes, g_hCvarModesOff, g_hCvarModesTog, g_hCvarGunInt, g_hCvarGunDur, g_hCvarGunRan;
float g_fCvarGunInt, g_fCvarGunDur, g_fCvarGunRan;
bool g_bCvarAllow, g_bIgnored;
Handle g_hSDK_TrySwing;
StringMap g_hTimes;
StringMap g_hMelee;

char g_sMeleeScripts[][] =
{
	// "generic",
	"baseball_bat",
	"cricket_bat",
	"crowbar",
	"electric_guitar",
	"fireaxe",
	"frying_pan",
	"golfclub",
	"katana",
	"knife",
	"machete",
	"tonfa",
	"pitchfork",
	"shovel"
};



// ====================================================================================================
//					PLUGIN INFO / START
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D2] Melee Weapon Fatigue",
	author = "SilverShot",
	description = "Introduces the shove penalty fatigue system to melee weapons.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=345411"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	// =========================
	// CVARS
	// =========================
	g_hCvarAllow =		CreateConVar(	"l4d2_melee_fatigue_allow",			"1",			"0=Plugin off, 1=Plugin on.", CVAR_FLAGS);
	g_hCvarModes =		CreateConVar(	"l4d2_melee_fatigue_modes",			"",				"Turn on the plugin in these game modes, separate by commas (no spaces). (Empty = all).", CVAR_FLAGS);
	g_hCvarModesOff =	CreateConVar(	"l4d2_melee_fatigue_modes_off",		"",				"Turn off the plugin in these game modes, separate by commas (no spaces). (Empty = none).", CVAR_FLAGS);
	g_hCvarModesTog =	CreateConVar(	"l4d2_melee_fatigue_modes_tog",		"0",			"Turn on the plugin in these game modes. 0=All, 1=Coop, 2=Survival, 4=Versus, 8=Scavenge. Add numbers together.", CVAR_FLAGS);
	CreateConVar(						"l4d2_melee_fatigue_version",		PLUGIN_VERSION,	"Melee Weapon Fatigue plugin version",	FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true, "l4d2_melee_fatigue");

	g_hCvarMPGameMode = FindConVar("mp_gamemode");
	g_hCvarMPGameMode.AddChangeHook(ConVarChanged_Allow);
	g_hCvarAllow.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModes.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesOff.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesTog.AddChangeHook(ConVarChanged_Allow);

	g_hCvarGunDur = FindConVar("z_gun_swing_interval");
	g_hCvarGunInt = FindConVar("z_gun_swing_duration");
	g_hCvarGunRan = FindConVar("z_gun_range");
	g_hCvarGunDur.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarGunInt.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarGunRan.AddChangeHook(ConVarChanged_Cvars);



	// =========================
	// SDKCall
	// =========================
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	Handle hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	StartPrepSDKCall(SDKCall_Entity);
	if( PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CTerrorWeapon::TrySwing") == false )
		SetFailState("Could not load the \"CTerrorWeapon::TrySwing\" gamedata signature.");

	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	g_hSDK_TrySwing = EndPrepSDKCall();

	delete hGameData;



	// =========================
	// DATA
	// =========================
	RegAdminCmd("sm_melee_fatigue_reload", CmdReload, ADMFLAG_ROOT);

	g_hTimes = new StringMap();
	for( int i = 0; i < sizeof(g_sMeleeScripts); i++ )
	{
		g_hTimes.SetValue(g_sMeleeScripts[i], 0.0);
	}

	g_hMelee = new StringMap();
	for( int i = 0; i < sizeof(g_sMeleeScripts); i++ )
	{
		g_hMelee.SetValue(g_sMeleeScripts[i], i);
	}
}



// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	IsAllowed();
}

void ConVarChanged_Allow(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsAllowed();
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_fCvarGunInt = g_hCvarGunInt.FloatValue;
	g_fCvarGunDur = g_hCvarGunDur.FloatValue;
	g_fCvarGunRan = g_hCvarGunRan.FloatValue;
}

void IsAllowed()
{
	bool bAllow = GetConVarBool(g_hCvarAllow);
	bool bAllowMode = IsAllowedGameMode();
	GetCvars();

	if( g_bCvarAllow == false && bAllow == true && bAllowMode == true )
	{
		g_bCvarAllow = true;
	}
	else if( g_bCvarAllow == true && (bAllow == false || bAllowMode == false) )
	{
		g_bCvarAllow = false;
	}
}

int g_iCurrentMode;
public void L4D_OnGameModeChange(int gamemode)
{
	g_iCurrentMode = gamemode;
}

bool IsAllowedGameMode()
{
	if( g_hCvarMPGameMode == null )
		return false;

	int iCvarModesTog = g_hCvarModesTog.IntValue;
	if( iCvarModesTog != 0 )
	{
		g_iCurrentMode = L4D_GetGameModeType();

		if( g_iCurrentMode == 0 )
			return false;

		switch( g_iCurrentMode ) // Left4DHooks values are flipped for these modes, sadly
		{
			case 2:		g_iCurrentMode = 4;
			case 4:		g_iCurrentMode = 2;
		}

		if( !(iCvarModesTog & g_iCurrentMode) )
			return false;
	}

	char sGameModes[64], sGameMode[64];
	g_hCvarMPGameMode.GetString(sGameMode, sizeof(sGameMode));
	Format(sGameMode, sizeof(sGameMode), ",%s,", sGameMode);

	g_hCvarModes.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) == -1 )
			return false;
	}

	g_hCvarModesOff.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) != -1 )
			return false;
	}

	return true;
}



// ====================================================================================================
//					CONFIG
// ====================================================================================================
public void OnMapStart()
{
	RequestFrame(OnFrameStart); // Melee weapon IDs are not valid from "Left4DHooks" until 1 frame after OnMapStart()
}

void OnFrameStart()
{
	LoadData();
}

Action CmdReload(int client, int args)
{
	LoadData();
	return Plugin_Handled;
}

void LoadData()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_DATA);
	if( FileExists(sPath) == false )
	{
		return;
	}

	// Load config
	KeyValues hFile = new KeyValues("melee_fatigue");
	if( !hFile.ImportFromFile(sPath) )
	{
		LogError("Failed to load data config: \"%s\"", CONFIG_DATA);
		delete hFile;
		return;
	}

	int meleeID;

	for( int i = 0; i < sizeof(g_sMeleeScripts); i++ )
	{
		ReadData(hFile, g_sMeleeScripts[i]);
		
		meleeID = L4D2_GetMeleeWeaponIndex(g_sMeleeScripts[i]);
		g_hMelee.SetValue(g_sMeleeScripts[i], meleeID);
	}

	delete hFile;
}

void ReadData(KeyValues hFile, const char [] script)
{
	if( hFile.JumpToKey(script) )
	{
		g_hTimes.SetValue(script, hFile.GetFloat("time", 0.0));
		hFile.Rewind();
	}
}



// ====================================================================================================
//					FORWARDS
// ====================================================================================================
// When shoving, set melee weapon attack time to prevent primary attack before shove penalty finishes
public void L4D_OnSwingStart(int client, int weapon)
{
	if( g_bCvarAllow && !g_bIgnored && weapon != -1 )
	{
		// Block melee weapon swing when shoving
		static char class[16];
		GetEdictClassname(weapon, class, sizeof(class));

		if( strncmp(class[7], "melee", 5) == 0 )
		{
			float time = GetEntPropFloat(client, Prop_Send, "m_flNextShoveTime");
			SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", time + 0.1);
		}
	}
}

// If shoving is blocked, prevent melee weapon attack
public Action L4D_OnStartMeleeSwing(int client, bool boolean)
{
	if( g_bCvarAllow )
	{
		// Shove is blocked
		float time = GetEntPropFloat(client, Prop_Send, "m_flNextShoveTime");

		if( time > GetGameTime() )
		{
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

// On melee weapon attack
public void L4D_OnStartMeleeSwing_Post(int client, bool boolean)
{
	if( g_bCvarAllow )
	{
		int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
		if( weapon != -1 )
		{
			// Calls to calculate shove penalty cooldown
			g_bIgnored = true;
			SDKCall(g_hSDK_TrySwing, weapon, g_fCvarGunInt, g_fCvarGunDur, g_fCvarGunRan);
			g_bIgnored = false;

			// Get custom melee cooldown time, if available
			float cool;
			static char script[32];

			GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", script, sizeof(script));
			g_hTimes.GetValue(script, cool);

			// Block next melee attack according to cooldpwn time
			int meleeID;
			float delay = 0.8;

			// Get melee swing refire delay
			if( g_hMelee.GetValue(script, meleeID) && meleeID != -1 )
			{
				delay = L4D2_GetFloatMeleeAttribute(meleeID, L4D2FMWA_RefireDelay);
			}

			// If next shove time is sooner than the melee refire delay, use the melee refire delay
			float time = GetEntPropFloat(client, Prop_Send, "m_flNextShoveTime") + 0.4 + cool;
			if( time - GetGameTime() < delay )
			{
				time = GetGameTime() + delay + cool;
			}
	
			SetEntPropFloat(client, Prop_Send, "m_flNextShoveTime", time);
			SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", time + 0.1);
		}
	}
}