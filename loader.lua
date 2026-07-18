local HttpService = game:GetService("HttpService")

local key = script_key

if not key then
    error("Missing script_key")
end

local device_id = game:GetService("RbxAnalyticsService"):GetClientId()

local response = request({
    Url = "https://key-api.tallestguild.workers.dev/validate",
    Method = "POST",
    Headers = {
        ["Content-Type"] = "application/json"
    },
    Body = HttpService:JSONEncode({
        key = key,
        device_id = device_id
    })
})

local data = HttpService:JSONDecode(response.Body)

if not data.success then
    error(data.message)
end

print("Key accepted!")

loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JuicyAsian/TallestGuild/refs/heads/main/main.lua"
))()