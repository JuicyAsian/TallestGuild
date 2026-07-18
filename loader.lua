print("Loader started")

local HttpService = game:GetService("HttpService")

local key = script_key

if not key then
    error("Missing script_key")
end

print("Key found:", key)

local device_id = game:GetService("RbxAnalyticsService"):GetClientId()

print("HWID:", device_id)

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

print("API response received")

local data = HttpService:JSONDecode(response.Body)

print(data.message)

if not data.success then
    error(data.message)
end

print("Key accepted!")

loadstring(game:HttpGet(
"https://raw.githubusercontent.com/JuicyAsian/TallestGuild/refs/heads/main/main.lua"
))()
