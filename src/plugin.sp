#include <sourcemod>
#include <SteamWorks>
#include <discord>

public Plugin myinfo = {
    name = "Discord Reports",
    author = "Dreae",
    description = "Fire a Discord webhook to report players.",
    version = "1.0.1",
    url = "https://dreae.onl"
};

ConVar g_hCvarHostname;
ConVar g_hCvarPort;
ConVar g_hCvarRoleId;
ConVar g_hCvarChannelId;
ConVar g_hCvarStaffRoleId;
ConVar g_hCvarRateLimit;
ConVar g_hCvarReportDelay;
ConVar g_hCvarPlayerReportDelay;

char g_sRoleId[64];
char g_sHostname[128];
char g_sPublicIp[24];
char g_sPort[6];
int g_iChannelId[2];
int g_iRoleId[2];
bool g_bHelloNotified[MAXPLAYERS] = false;
bool g_bConnected = false;

bool g_bRateLimit = false;
int g_iLastServerReport = 0;
int g_iLastPlayerReport[MAXPLAYERS][MAXPLAYERS];
int g_iReportDelay = 0;
int g_iReportPlayerDelay = 0;

public void OnPluginStart() {
    g_hCvarHostname = FindConVar("hostname");
    g_hCvarPort = FindConVar("hostport");

    RegConsoleCmd("sm_report", Cmd_Report, "sm_report <player> <reason>");

    g_hCvarRoleId = CreateConVar("discord_report_role_id", "", "Role to mention in reports", FCVAR_PROTECTED);
    g_hCvarChannelId = CreateConVar("discord_report_channel_id", "", "ChannelId for discord reprots", FCVAR_PROTECTED);
    g_hCvarStaffRoleId = CreateConVar("discord_report_staff_id", "", "The RoleId that should be considered staff", FCVAR_PROTECTED);
    g_hCvarRateLimit = CreateConVar("discord_report_rate_limiting", "1", "Should we rate limit reports", FCVAR_NONE);
    g_hCvarReportDelay = CreateConVar("discord_report_delay", "30", "Number of seconds this server must wait to send another report", FCVAR_NONE);
    g_hCvarPlayerReportDelay = CreateConVar("discord_report_player_delay", "600", "Number of seconds a player must wait to send another report about the same player", FCVAR_NONE);

    g_hCvarRoleId.AddChangeHook(On_RoleIdUpdate);
    g_hCvarChannelId.AddChangeHook(On_ChannelIdUpdate);
    g_hCvarStaffRoleId.AddChangeHook(On_RoleIdUpdate);
    g_hCvarRateLimit.AddChangeHook(On_RateLimitUpdate);
    g_hCvarReportDelay.AddChangeHook(On_ReportDelayUpdate);
    g_hCvarPlayerReportDelay.AddChangeHook(On_PlayerReportDelayUpdate);

    HookEvent("player_spawn", On_PlayerSpawn);

    LoadTranslations("common.phrases");
    LoadTranslations("discord_reports.phrases");
}

public void OnConfigsExecuted() {
    g_hCvarHostname.GetString(g_sHostname, sizeof(g_sHostname));
    g_hCvarRoleId.GetString(g_sRoleId, sizeof(g_sRoleId));
    g_hCvarPort.GetString(g_sPort, sizeof(g_sPort));

    char channelId[24];
    g_hCvarChannelId.GetString(channelId, sizeof(channelId));
    StringToUInt64(channelId, g_iChannelId);

    char roleId[24];
    g_hCvarStaffRoleId.GetString(roleId, sizeof(roleId));
    if (strlen(roleId) != 0) {
        StringToUInt64(roleId, g_iRoleId);
    }

    g_bRateLimit = g_hCvarRateLimit.BoolValue;
    g_iReportDelay = g_hCvarReportDelay.IntValue;
    g_iReportPlayerDelay = g_hCvarPlayerReportDelay.IntValue;

    int pieces[4];
    SteamWorks_GetPublicIP(pieces);
    Format(g_sPublicIp, sizeof(g_sPublicIp), "%d.%d.%d.%d:%s", pieces[0], pieces[1], pieces[2], pieces[3], g_sPort);
}

public void OnClientDisconnect(int client) {
    g_bHelloNotified[client] = false;
    for (int c = 1; c < MAXPLAYERS; c++) {
        g_iLastPlayerReport[client][c] = 0;
        g_iLastPlayerReport[c][client] = 0;
    }
}

public Action On_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int user_id = event.GetInt("userid");
    int client = GetClientOfUserId(user_id);

    CreateTimer(0.1, Timer_Notify, client, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Notify(Handle timer, any data) {
    int client = view_as<int>(data);
    if (IsClientInGame(client) && IsPlayerAlive(client)) {
        if (!g_bHelloNotified[client]) {
            print_to_client(client, "%t", "HelloMsg");
            g_bHelloNotified[client] = true;
        }
    }

    return Plugin_Stop;
}

public void On_RoleIdUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    strcopy(g_sRoleId, sizeof(g_sRoleId), newValue);
}

public void On_ChannelIdUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    if (strlen(newValue) != 0) {
        StringToUInt64(newValue, g_iChannelId);
    }
}

public void On_RateLimitUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    g_bRateLimit = cvar.BoolValue;
}

public void On_ReportDelayUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    g_iReportDelay = cvar.IntValue;
}

public void On_PlayerReportDelayUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    g_iReportPlayerDelay = cvar.IntValue;
}

public Action Cmd_Report(int client, int args) {
    if (args < 2) {
        PrintUsage(client);
        return Plugin_Handled;
    }

    if (!g_bConnected || g_iChannelId[0] == 0 || g_iChannelId[1] == 0) {
        return Plugin_Handled;
    }

    if (g_bRateLimit) {
        if (GetTime() - g_iLastServerReport < g_iReportDelay) {
            ReplyToCommand(client, "%t", "ReportRateLimit");
            return Plugin_Handled;
        }
    }

    char arguments[512];
    GetCmdArgString(arguments, sizeof(arguments));
    char target_string[64];
    int len = BreakString(arguments, target_string, sizeof(target_string));


    int target[1];
    char target_name[64], target_steamid[32];
    bool tn_is_ml;
    int found = ProcessTargetString(target_string, client, target, 1, COMMAND_FILTER_NO_IMMUNITY | COMMAND_FILTER_NO_BOTS | COMMAND_FILTER_NO_MULTI, target_name, 128, tn_is_ml);
    if (found != 1) {
        ReplyToTargetError(client, found);
        return Plugin_Handled;
    } else if (g_bRateLimit) {
        if (GetTime() - g_iLastPlayerReport[client][target[0]] < g_iReportPlayerDelay) {
            ReplyToCommand(client, "%t", "PlayerReportRateLimit");
            return Plugin_Handled;
        }
    }

    GetClientAuthId(target[0], AuthId_SteamID64, target_steamid, sizeof(target_steamid));

    char reason[256];
    Format(reason, sizeof(reason), arguments[len]);
    ReplaceString(reason, strlen(reason), "\"", "\\\"", false);

    char reporter_name[32], reporter_steamid[32];
    GetClientName(client, reporter_name, sizeof(reporter_name));
    GetClientAuthId(client, AuthId_SteamID64, reporter_steamid, sizeof(reporter_steamid), true);

    if (g_bConnected) {
        char titleBuffer[64]
        Format(titleBuffer, sizeof(titleBuffer), "%T", "NewReport", LANG_SERVER);

        char reporter[32];
        Format(reporter, sizeof(reporter), "%T", "Reporter", LANG_SERVER);
        char reporterName[128];
        Format(reporterName, sizeof(reporterName), "%s \\<[%s](https://steamidfinder.com/lookup/%s)\\>", reporter_name, reporter_steamid, reporter_steamid);

        char rulebreaker[32];
        Format(rulebreaker, sizeof(rulebreaker), "%T", "Rulebreaker", LANG_SERVER);
        char rulebreakerName[128];
        Format(rulebreakerName, sizeof(rulebreakerName), "%s \\<[%s](https://steamidfinder.com/lookup/%s)\\>", target_name, target_steamid, target_steamid);

        char description[32];
        Format(description, sizeof(description), "%T", "Description", LANG_SERVER);

        char connect[32];
        Format(connect, sizeof(connect), "%T", "Connect", LANG_SERVER);
        char connectUrl[40];
        Format(connectUrl, sizeof(connectUrl), "steam://connect/%s", g_sPublicIp);

        NewDiscordMessage msg = new NewDiscordMessage();
        msg.SetContent("<@%s>", g_sRoleId);

        NewDiscordEmbed embed = new NewDiscordEmbed();
        embed.SetTitle(titleBuffer);
        embed.SetDescription(g_sHostname);
        embed.AddField(reporter, reporterName, true);
        embed.AddField(rulebreaker, rulebreakerName, true);
        embed.AddField(description, reason);
        embed.AddField(connect, connectUrl);

        msg.SetEmbed(embed);
        Discord_SendToChannel(g_iChannelId, msg);
    }

    return Plugin_Handled;
}

public void OnDiscordReady(DiscordReady ready) {
    g_bConnected = true;
}

void PrintUsage(int client) {
    ReplyToCommand(client, "sm_report <user> <reason>");
}

public void OnDiscordMessage(DiscordUser author, DiscordMessage msg) {
    int channelId[2];
    msg.ChannelId(channelId);

    if (channelId[0] != g_iChannelId[0] || channelId[1] != g_iChannelId[1]) {
        return;
    }

    if (g_iRoleId[0] != 0 && g_iRoleId[1] != 0) {
        int guildId[2];
        msg.GuildId(guildId);

        if (guildId[0] == 0 || guildId[1] == 0 || !author.HasRole(guildId, g_iRoleId)) {
            return;
        }
    }

    char content[512];
    msg.GetContent(content, sizeof(content));

    char cmd[32];
    int len = BreakString(content, cmd, sizeof(cmd));
    if (StrEqual(cmd, "?rwarn", false)) {
        do_warn(content[len], msg);
    }
}

void do_warn(const char[] content, DiscordMessage msg) {
    char steam_id[21];
    int len = BreakString(content, steam_id, sizeof(steam_id));
    int client = find_target(steam_id);

    if (client != 0) {
        PrintHintText(client, "<font size='34' color='#FF4C4C' face=''>Reports</font>\n%t", "BeenWarned");
        print_to_client(client, "%t", "ClientWarned", content[len]);

        char name[256];
        Format(name, sizeof(name), "%L", client);
        msg.ReplyToChannel("%T", "AdminClientWarned", LANG_SERVER, name);
    }
}

int find_target(const char[] steam_id) {
    for (int i = 1; i < MaxClients; i++) {
        if (valid_client(i)) {
            char target_id[21];
            GetClientAuthId(i, AuthId_SteamID64, target_id, sizeof(target_id), true);

            if (StrEqual(steam_id, target_id)) {
                return i;
            }
        }
    }

    return 0;
}

bool valid_client(int client) {
    return IsClientConnected(client) && IsClientAuthorized(client);
}

void print_to_client(int client, const char[] msg, any ...) {
    SetGlobalTransTarget(client);

    char content[1024];
    VFormat(content, sizeof(content), msg, 3);

    PrintToChat(client, "\x01[\x03Reports\x01] \x04%s", content);
}