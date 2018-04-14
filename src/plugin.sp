#include <sourcemod>
#include <SteamWorks>

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
ConVar g_hCvarWebhookURL;
ConVar g_hCvarRateLimit;
ConVar g_hCvarReportDelay;
ConVar g_hCvarPlayerReportDelay;

char g_sRoleId[64];
char g_sHostname[128];
char g_sWebhook[512];
char g_sPublicIp[24];
char g_sPort[6];
bool g_bHelloNotified[MAXPLAYERS] = false;

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
    g_hCvarWebhookURL = CreateConVar("discord_report_webhook_url", "", "Webhook to call to send a report", FCVAR_PROTECTED);
    g_hCvarRateLimit = CreateConVar("discord_report_rate_limiting", "1", "Should we rate limit reports", FCVAR_NONE);
    g_hCvarReportDelay = CreateConVar("discord_report_delay", "30", "Number of seconds this server must wait to send another report", FCVAR_NONE);
    g_hCvarPlayerReportDelay = CreateConVar("discord_report_player_delay", "600", "Number of seconds a player must wait to send another report about the same player", FCVAR_NONE);

    g_hCvarRoleId.AddChangeHook(On_RoleIdUpdate);
    g_hCvarWebhookURL.AddChangeHook(On_WebhookUpdate);
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
    g_hCvarWebhookURL.GetString(g_sWebhook, sizeof(g_sWebhook));
    g_hCvarPort.GetString(g_sPort, sizeof(g_sPort));
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
            PrintToChat(client, "\x01[\x03Reports\x01] \x04%t", "HelloMsg");
            g_bHelloNotified[client] = true;
        }
    }

    return Plugin_Stop;
}

public void On_RoleIdUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    strcopy(g_sRoleId, sizeof(g_sRoleId), newValue);
}

public void On_WebhookUpdate(ConVar cvar, const char[] oldValue, const char[] newValue) {
    strcopy(g_sWebhook, sizeof(g_sWebhook), newValue);
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

    char reporter_name[32], reporter_steamid[32];
    GetClientName(client, reporter_name, sizeof(reporter_name));
    GetClientAuthId(client, AuthId_SteamID64, reporter_steamid, sizeof(reporter_steamid), true);


    char report_msg[1024];
    Format(report_msg, sizeof(report_msg), "%T", "Report", LANG_SERVER, g_sRoleId, g_sHostname, reporter_name, reporter_steamid, target_name, target_steamid, reason);
    ReplaceString(report_msg, strlen(report_msg), "\"", "\\\"", false);
    if (strlen(g_sWebhook) != 0) {
        char json_body[1248];
        Format(json_body, sizeof(json_body), "{\"content\": \"%s\", \"embeds\": [{\"title\": \"%T\", \"description\": \"steam://connect/%s\"}]}", report_msg, "JoinServer", LANG_SERVER, g_sPublicIp);

        Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, g_sWebhook);

        SteamWorks_SetHTTPRequestContextValue(req, client, target[0]);
        SteamWorks_SetHTTPRequestRawPostBody(req, "Application/json", json_body, strlen(json_body));
        SteamWorks_SetHTTPCallbacks(req, Callback_ReqComplete);

        SteamWorks_SendHTTPRequest(req);
    }

    return Plugin_Handled;
}

public Callback_ReqComplete(Handle req, bool failure, bool successful, EHTTPStatusCode statusCode, any data, any data1) {
    int client = view_as<int>(data);
    int target = view_as<int>(data1);
    if (failure || !successful || (statusCode < k_EHTTPStatusCode200OK || statusCode >= k_EHTTPStatusCode400BadRequest)) {
        PrintToChat(client, "\x01[\x03Reports\x01] \x04%t", "ReportFailed");
    } else {
        g_iLastServerReport = GetTime();
        g_iLastPlayerReport[client][target] = GetTime();
        PrintToChat(client, "\x01[\x03Reports\x01] \x04%t", "ReportSent");
    }

    req.Close();
}

void PrintUsage(int client) {
    ReplyToCommand(client, "sm_report <user> <reason>");
}
