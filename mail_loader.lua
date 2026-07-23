local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")

local KEY_API = "https://key-api.tallestguild.workers.dev/validate"
local MAIL_SCRIPT = "https://raw.githubusercontent.com/JuicyAsian/TallestGuild/refs/heads/main/mail.lua"

local environment = getgenv and getgenv() or _G
local key = environment.script_key or script_key

if type(key) ~= "string" or key == "" then
    error("Missing script_key. Get your protected loader from /getscript.")
end

local player = Players.LocalPlayer
if not player then
    error("Could not find LocalPlayer")
end

local requestFunction = environment.request
    or environment.http_request
    or (environment.syn and environment.syn.request)
    or (environment.http and environment.http.request)
    or (environment.fluxus and environment.fluxus.request)

if not requestFunction then
    error("Your executor does not support HTTP requests")
end

local response = requestFunction({
    Url = KEY_API,
    URL = KEY_API,
    Method = "POST",
    Headers = {["Content-Type"] = "application/json"},
    Body = HttpService:JSONEncode({
        key = key,
        device_id = RbxAnalyticsService:GetClientId(),
        roblox_user_id = tostring(player.UserId),
        roblox_username = player.Name,
        roblox_display_name = player.DisplayName,
        product = "mail"
    })
})

if not response then
    error("The license server did not respond")
end

local responseBody = response.Body or response.body
if type(responseBody) ~= "string" or responseBody == "" then
    error("The license server returned an empty response")
end

local decoded,data = pcall(HttpService.JSONDecode,HttpService,responseBody)
if not decoded or type(data) ~= "table" then
    error("The license server returned invalid data")
end

if not data.success then
    error(data.message or "License validation failed")
end

local source = game:HttpGet(MAIL_SCRIPT)
local compiled,compileError = loadstring(source)
if not compiled then
    error("Mail Bypass failed to compile: "..tostring(compileError))
end

compiled()
