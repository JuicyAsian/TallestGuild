local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")

print("LOADER STARTED")

local key = script_key

if type(key) ~= "string" or key == "" then
    error("Missing script_key")
end

print("KEY FOUND")

local player = Players.LocalPlayer

if not player then
    error("Could not find LocalPlayer")
end

local device_id = RbxAnalyticsService:GetClientId()

local requestFunction =
    request
    or http_request
    or syn and syn.request
    or fluxus and fluxus.request

if not requestFunction then
    error("Your executor does not support HTTP requests")
end

local response = requestFunction({
    Url = "https://key-api.tallestguild.workers.dev/validate",
    Method = "POST",
    Headers = {
        ["Content-Type"] = "application/json"
    },
    Body = HttpService:JSONEncode({
        key = key,
        device_id = device_id,

        roblox_user_id = tostring(player.UserId),
        roblox_username = player.Name,
        roblox_display_name = player.DisplayName
    })
})

if not response then
    error("The license server did not respond")
end

local responseBody = response.Body or response.body

if type(responseBody) ~= "string" or responseBody == "" then
    error("The license server returned an empty response")
end

local decodeSuccess, data = pcall(function()
    return HttpService:JSONDecode(responseBody)
end)

if not decodeSuccess or type(data) ~= "table" then
    error("The license server returned an invalid response")
end

print(data.message or "No response message")

if not data.success then
    error(data.message or "License validation failed")
end

print("KEY ACCEPTED")

loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JuicyAsian/TallestGuild/refs/heads/main/main.lua"
))()
