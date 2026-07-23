local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(
    ReplicatedStorage
    :WaitForChild("SharedModules")
    :WaitForChild("Networking")
)

local player = Players.LocalPlayer

local runtimeEnvironment = getgenv and getgenv() or _G
if runtimeEnvironment.LightsMailAutoThread then
    pcall(task.cancel,runtimeEnvironment.LightsMailAutoThread)
    runtimeEnvironment.LightsMailAutoThread = nil
end

local counterFile = "LightsMail_SendCounter_"..tostring(player.UserId)..".json"

local SendCounter = {
    Today = 0,
    Total = 0,
    Date = os.date("%Y-%m-%d"),
    UserId = player.UserId
}

local function loadSendCounter()

    if readfile and isfile and isfile(counterFile) then

        local success, data = pcall(function()
            return game:GetService("HttpService"):JSONDecode(
                readfile(counterFile)
            )
        end)

        if success and type(data) == "table" then
            SendCounter = data
        end

    end

end


local function saveSendCounter()

    if writefile then

        pcall(function()

            writefile(
                counterFile,
                game:GetService("HttpService"):JSONEncode(SendCounter)
            )

        end)

    end

end


local function resetDailyCounter()

    local today = os.date("%Y-%m-%d")

    if SendCounter.Date ~= today then

        SendCounter.Today = 0
        SendCounter.Date = today
        saveSendCounter()

    end

end


local function addSendCount()

    resetDailyCounter()

    SendCounter.Today += 1
    SendCounter.Total += 1

    saveSendCounter()

end

loadSendCounter()
resetDailyCounter()

local historyFile = "LightsMail_History_"..tostring(player.UserId)..".json"
local MailHistory = {}
local refreshHistoryPage = function() end

local function loadMailHistory()
    if readfile and isfile and isfile(historyFile) then
        local ok,data = pcall(function()
            return game:GetService("HttpService"):JSONDecode(readfile(historyFile))
        end)

        if ok and type(data) == "table" then
            MailHistory = data
        end
    end
end

local function saveMailHistory()
    if writefile then
        pcall(function()
            writefile(
                historyFile,
                game:GetService("HttpService"):JSONEncode(MailHistory)
            )
        end)
    end
end

local function addMailHistoryEntry(recipientUsername,recipientId,waves,completedWaveCount)
    local itemsByKey = {}
    local total = 0

    for waveIndex = 1,completedWaveCount do
        for _,item in ipairs(waves[waveIndex]) do
            local key = item.Category.."|"..tostring(item.ItemKey)
            local displayName = item.Category == "Pets" and tostring(item.ItemKey) or tostring(item.ItemKey)

            if not itemsByKey[key] then
                itemsByKey[key] = {
                    Name = displayName,
                    Category = item.Category,
                    Count = 0
                }
            end

            itemsByKey[key].Count += item.Count
            total += item.Count
        end
    end

    if total <= 0 then
        return
    end

    local items = {}
    for _,item in pairs(itemsByKey) do
        table.insert(items,item)
    end
    table.sort(items,function(a,b)
        return a.Name < b.Name
    end)

    table.insert(MailHistory,1,{
        Timestamp = os.time(),
        Sender = player.Name,
        Recipient = recipientUsername or tostring(recipientId),
        RecipientId = recipientId,
        Total = total,
        Items = items
    })

    while #MailHistory > 100 do
        table.remove(MailHistory)
    end

    saveMailHistory()
    refreshHistoryPage()
end

loadMailHistory()


local old = player.PlayerGui:FindFirstChild("LightsMailUI_v102")
if old then
    old:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "LightsMailUI_v102"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- ============================================================
-- SHECKLE ESP + TRADE WEBHOOK SETTINGS
-- ============================================================

local SheckleSettings = {
    SheckleESP = false,
    TradeWebhookEnabled = false,
    TradeWebhookURL = ""
}

local webhookConfigFile = "LightsMail_Webhook_"..tostring(player.UserId)..".json"

if readfile and isfile and isfile(webhookConfigFile) then
    pcall(function()
        local saved = game:GetService("HttpService"):JSONDecode(readfile(webhookConfigFile))
        if type(saved) == "table" and type(saved.URL) == "string" and saved.URL ~= "" then
            SheckleSettings.TradeWebhookURL = saved.URL
            SheckleSettings.TradeWebhookEnabled = true
        end
    end)
end

local function saveWebhookSettings()
    if writefile then
        pcall(function()
            writefile(
                webhookConfigFile,
                game:GetService("HttpService"):JSONEncode({
                    URL = SheckleSettings.TradeWebhookURL
                })
            )
        end)
    end
end

local LastWebhookStatus = "No webhook request sent yet."

local function getWebhookRequestFunction()
    local environment = getgenv and getgenv() or _G
    return environment.request
        or environment.http_request
        or (environment.syn and environment.syn.request)
        or (environment.http and environment.http.request)
        or (environment.fluxus and environment.fluxus.request)
        or (environment.krnl and environment.krnl.request)
end

local function postWebhook(url,payload)
    local requestFunction = getWebhookRequestFunction()
    if not requestFunction then
        LastWebhookStatus = "Failed: executor HTTP requests are unavailable."
        return false,LastWebhookStatus
    end

    local ok,response = pcall(requestFunction,{
        Url = url,
        URL = url,
        Method = "POST",
        Headers = {['Content-Type'] = "application/json"},
        Body = game:GetService("HttpService"):JSONEncode(payload)
    })

    if not ok then
        LastWebhookStatus = "Failed: "..tostring(response)
        return false,LastWebhookStatus
    end

    local statusCode = type(response) == "table"
        and (response.StatusCode or response.Status or response.status_code)

    if statusCode and (statusCode < 200 or statusCode >= 300) then
        local body = type(response) == "table" and (response.Body or response.body) or ""
        LastWebhookStatus = "Discord HTTP "..tostring(statusCode)..": "..tostring(body)
        return false,LastWebhookStatus
    end

    LastWebhookStatus = "Delivered to Discord"
    return true,LastWebhookStatus
end

local thumbnailCache = {}
local CAT_WEBHOOK_AVATAR = "https://cdn.discordapp.com/attachments/1310819145826304092/1528210396291403917/image.png?ex=6a62be57&is=6a616cd7&hm=752dc88eaabebbd5331d2cc25987acc706fd35d1b88be5ac30b26ed8a116e15e&"

local function getRobloxHeadshotUrl(userId)
    userId = tonumber(userId)
    if not userId then
        return nil
    end

    if thumbnailCache[userId] then
        return thumbnailCache[userId]
    end

    local endpoint = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds="
        ..tostring(userId).."&size=150x150&format=Png&isCircular=false"
    local requestFunction = getWebhookRequestFunction()
    local body = nil

    if requestFunction then
        local ok,response = pcall(requestFunction,{
            Url = endpoint,
            URL = endpoint,
            Method = "GET"
        })
        if ok and type(response) == "table" then
            body = response.Body or response.body
        end
    end

    if not body and game.HttpGet then
        pcall(function()
            body = game:HttpGet(endpoint)
        end)
    end

    if body then
        local ok,decoded = pcall(function()
            return game:GetService("HttpService"):JSONDecode(body)
        end)
        local imageUrl = ok
            and decoded
            and decoded.data
            and decoded.data[1]
            and decoded.data[1].imageUrl

        if imageUrl then
            thumbnailCache[userId] = imageUrl
            return imageUrl
        end
    end

    return nil
end

local function sendMailWebhook(recipientUsername,recipientId,waves,completedWaveCount,noteText)
    if not SheckleSettings.TradeWebhookEnabled
    or SheckleSettings.TradeWebhookURL == "" then
        return
    end

    local grouped = {}
    local totalItems = 0

    for waveIndex = 1,completedWaveCount do
        for _,item in ipairs(waves[waveIndex]) do
            local key = item.Category.."|"..tostring(item.ItemKey)
            if not grouped[key] then
                grouped[key] = {
                    Category = tostring(item.Category),
                    Name = tostring(item.ItemKey),
                    Count = 0
                }
            end
            grouped[key].Count += item.Count
            totalItems += item.Count
        end
    end

    if totalItems <= 0 then
        return
    end

    local groupedList = {}
    for _,item in pairs(grouped) do
        table.insert(groupedList,item)
    end
    table.sort(groupedList,function(a,b)
        if a.Category == b.Category then
            return a.Name < b.Name
        end
        return a.Category < b.Category
    end)

    local itemLines = {}
    local lastCategory = nil
    for _,item in ipairs(groupedList) do
        if item.Category ~= lastCategory then
            table.insert(itemLines,"**"..item.Category.."**")
            lastCategory = item.Category
        end
        table.insert(itemLines,"`"..tostring(item.Count).."x`  –  "..item.Name)
    end

    local itemsText = table.concat(itemLines,"\n")
    if #itemsText > 1000 then
        itemsText = string.sub(itemsText,1,997).."..."
    end

    local recipient = recipientUsername or tostring(recipientId)
    local recipientThumbnail = getRobloxHeadshotUrl(recipientId)

    local payload = {
        username = "Mail Bypass: by Pubert",
        avatar_url = CAT_WEBHOOK_AVATAR,
        embeds = {{
            color = 2845183,
            author = {
                name = "To "..recipient,
                icon_url = recipientThumbnail,
                url = "https://www.roblox.com/users/"..tostring(recipientId).."/profile"
            },
            title = "📨 Delivery Complete",
            description = "**"..player.Name.."** sent **"..tostring(totalItems)
                .." item(s)** to **"..recipient.."**\n"
                .."[View recipient profile](https://www.roblox.com/users/"
                ..tostring(recipientId).."/profile)",
            thumbnail = recipientThumbnail and {url = recipientThumbnail} or nil,
            fields = {
                {name = "👤 Sender", value = "`"..player.Name.."`", inline = true},
                {name = "✉️ Recipient", value = "`"..recipient.."`", inline = true},
                {name = "🆔 Recipient ID", value = "`"..tostring(recipientId).."`", inline = true},
                {
                    name = "📦 Items ("..#groupedList.." entries · "..tostring(totalItems).." total)",
                    value = itemsText ~= "" and itemsText or "No item details",
                    inline = false
                },
                {
                    name = "📝 Note",
                    value = "```"..string.sub(tostring(noteText or "No note"),1,950).."```",
                    inline = false
                }
            },
            footer = {
                text = "Light's Mail • Logged by JuicyAsian • v1.03",
                icon_url = recipientThumbnail
            },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }}
    }

    local delivered,message = postWebhook(SheckleSettings.TradeWebhookURL,payload)
    if not delivered then
        warn("Webhook failed:",message)
    end
end

local Theme = {
    BG = Color3.fromRGB(13,10,24),
    Panel = Color3.fromRGB(22,17,38),
    Input = Color3.fromRGB(31,24,52),
    Hover = Color3.fromRGB(73,50,116),
    Blue = Color3.fromRGB(43,105,255),
    Cyan = Color3.fromRGB(111,214,255),
    Purple = Color3.fromRGB(73,42,188),
    Accent = Color3.fromRGB(176,132,255),
    Yellow = Color3.fromRGB(255,210,104),
    Text = Color3.fromRGB(250,248,255),
    Muted = Color3.fromRGB(205,195,222),
    Red = Color3.fromRGB(220,45,78)
}

local function corner(o,r)
    local c=Instance.new("UICorner")
    c.CornerRadius=UDim.new(0,r)
    c.Parent=o
end

local function outline(o)
    local s=Instance.new("UIStroke")
    s.Color=Color3.fromRGB(73,55,112)
    s.Transparency=.18
    s.Thickness=1
    s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    s.Parent=o
end

local function surfaceGradient(o,topColor,bottomColor)
    local g=Instance.new("UIGradient")
    g.Color=ColorSequence.new({
        ColorSequenceKeypoint.new(0,topColor or Color3.fromRGB(38,28,62)),
        ColorSequenceKeypoint.new(1,bottomColor or Color3.fromRGB(18,14,31))
    })
    g.Rotation=90
    g.Parent=o
    return g
end

local function makeLine(parent,pos,size,color)
    local f=Instance.new("Frame")
    f.BackgroundColor3=color
    f.BorderSizePixel=0
    f.Position=pos
    f.Size=size
    f.Parent=parent
end

local function label(p,t,s,font)
    local x=Instance.new("TextLabel")
    x.BackgroundTransparency=1
    x.Text=t
    x.TextColor3=Theme.Text
    x.Font=font or Enum.Font.Cartoon
    x.TextSize=s
    x.TextXAlignment=Enum.TextXAlignment.Left
    x.TextYAlignment=Enum.TextYAlignment.Center
    x.Parent=p
    return x
end

local function button(p,t,s,c)
    local b=Instance.new("TextButton")
    b.Text=t
    b.TextColor3=Theme.Text
    b.Font=Enum.Font.Cartoon
    b.TextSize=s
    b.BackgroundColor3=c
    b.Parent=p
    corner(b,10)

    if c == Theme.Blue then
        local accentStroke=Instance.new("UIStroke")
        accentStroke.Color=Theme.Cyan
        accentStroke.Transparency=.42
        accentStroke.Thickness=1.25
        accentStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
        accentStroke.Parent=b
    elseif c == Theme.Red then
        local dangerStroke=Instance.new("UIStroke")
        dangerStroke.Color=Color3.fromRGB(255,128,148)
        dangerStroke.Transparency=.25
        dangerStroke.Thickness=1.25
        dangerStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
        dangerStroke.Parent=b
    end

    -- Subtle hover feedback keeps the interface lively without changing behavior.
    local hoverBase = c
    b.MouseEnter:Connect(function()
        hoverBase = b.BackgroundColor3
        TweenService:Create(b,TweenInfo.new(.12),{
            BackgroundColor3 = hoverBase:Lerp(Color3.new(1,1,1),.10)
        }):Play()
    end)
    b.MouseLeave:Connect(function()
        local targetColor = b:GetAttribute("ActiveTab") and Theme.Purple or hoverBase
        TweenService:Create(b,TweenInfo.new(.12),{
            BackgroundColor3 = targetColor
        }):Play()
    end)
    return b
end

local scale=Instance.new("UIScale")
scale.Scale=.75
scale.Parent=gui

local main=Instance.new("Frame")
main.Size=UDim2.fromOffset(1180,760)
-- Top anchoring keeps the header stationary while collapse pulls upward.
main.AnchorPoint=Vector2.new(.5,0)
main.Position=UDim2.new(.5,0,.5,-380)
main.BackgroundColor3=Theme.BG
main.Parent=gui
corner(main,18)
outline(main)

local windowGlow=Instance.new("UIStroke")
windowGlow.Name="WindowGlow"
windowGlow.Color=Theme.Purple
windowGlow.Transparency=.76
windowGlow.Thickness=4
windowGlow.Parent=main

local mainGradient=Instance.new("UIGradient")
mainGradient.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(22,17,38)),
    ColorSequenceKeypoint.new(.55,Color3.fromRGB(13,10,24)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(22,17,38))
})
mainGradient.Rotation=115
mainGradient.Parent=main

local headerWash=Instance.new("Frame")
headerWash.Name="HeaderWash"
headerWash.Size=UDim2.new(1,0,0,90)
headerWash.BackgroundColor3=Theme.Blue
headerWash.BorderSizePixel=0
headerWash.Parent=main
corner(headerWash,18)

local headerWashGradient=Instance.new("UIGradient")
headerWashGradient.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(43,105,255)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(73,42,188))
})
headerWashGradient.Rotation=8
headerWashGradient.Parent=headerWash

-- Fit the desktop-sized design onto smaller screens while retaining its layout.
local camera=workspace.CurrentCamera
local function updateScale()
    local viewport=camera and camera.ViewportSize or Vector2.new(1280,720)
    local fittedScale=math.min((viewport.X-32)/1180,(viewport.Y-32)/760)
    scale.Scale=math.clamp(fittedScale*.74,.40,.74)
end
updateScale()
if camera then
    camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

-- DRAG SYSTEM
local dragging = false
local dragStart
local startPos

local function updateDrag(input)
    local delta = input.Position - dragStart

    TweenService:Create(
        main,
        TweenInfo.new(.08),
        {
            Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        }
    ):Play()
end


main.InputBegan:Connect(function(input)

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        
        -- only drag from top area
        if input.Position.Y <= main.AbsolutePosition.Y + 90 then
            
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            
        end
    end

end)


main.InputEnded:Connect(function(input)

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end

end)


UIS.InputChanged:Connect(function(input)

    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        updateDrag(input)
    end

end)

local mailBadge=Instance.new("Frame")
mailBadge.Position=UDim2.fromOffset(54,24)
mailBadge.Size=UDim2.fromOffset(32,32)
mailBadge.BackgroundTransparency=1
mailBadge.Parent=main

local mailIcon=label(mailBadge,"✉",23,Enum.Font.Cartoon)
mailIcon.Position=UDim2.fromOffset(0,0)
mailIcon.Size=UDim2.fromScale(1,1)
mailIcon.BackgroundTransparency=1
mailIcon.TextXAlignment=Enum.TextXAlignment.Center

local title=label(main,"LIGHT'S MAIL",30,Enum.Font.Cartoon)
title.Position=UDim2.fromOffset(96,19)
title.Size=UDim2.fromOffset(300,34)

local titleGradient=Instance.new("UIGradient")
titleGradient.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Theme.Text),
    ColorSequenceKeypoint.new(1,Theme.Text)
})
titleGradient.Parent=title

task.spawn(function()
    while mailIcon.Parent do
        local spin=TweenService:Create(
            mailIcon,
            TweenInfo.new(.65,Enum.EasingStyle.Quart,Enum.EasingDirection.Out),
            {Rotation=360}
        )
        spin:Play()
        spin.Completed:Wait()
        mailIcon.Rotation=0
        task.wait(1.35)
    end
end)

local sub=label(main,"RUNNING  •  Mailbox  •  by JuicyAsian",13,Enum.Font.Cartoon)
sub.Position=UDim2.fromOffset(96,50)
sub.Size=UDim2.fromOffset(340,20)

local live=label(main,"● ONLINE",12,Enum.Font.Cartoon)
live.Position=UDim2.fromOffset(340,50)
live.Size=UDim2.fromOffset(100,20)
live.TextColor3=Color3.fromRGB(82,235,156)


local sendCounterBox = Instance.new("Frame")
sendCounterBox.Name = "SendCounterBox"
sendCounterBox.Size = UDim2.fromOffset(230,32)
sendCounterBox.Position = UDim2.new(1,-390,0,32)
sendCounterBox.BackgroundColor3 = Theme.Panel
sendCounterBox.Parent = main
corner(sendCounterBox,10)
outline(sendCounterBox)

local sendCounter = label(
    sendCounterBox,
    "📬 0/50 today  •  0 total",
    16,
    Enum.Font.FredokaOne
)

sendCounter.TextXAlignment = Enum.TextXAlignment.Center
sendCounter.Size = UDim2.fromScale(1,1)

local function updateSendCounter()
    resetDailyCounter()

    sendCounter.Text =
        "📬 "..SendCounter.Today.."/50 today  •  "..SendCounter.Total.." total"
end

updateSendCounter()


task.spawn(function()
    while live.Parent do
        live.TextTransparency=.4
        task.wait(.6)
        live.TextTransparency=0
        task.wait(.6)
    end
end)

-- COLLAPSE BUTTON
local collapse=button(main,"−",22,Theme.Panel)
collapse.Size=UDim2.fromOffset(45,45)
collapse.Position=UDim2.new(1,-120,0,25)
collapse.ZIndex=10

local close=button(main,"X",22,Theme.Red)
close.Size=UDim2.fromOffset(45,45)
close.Position=UDim2.new(1,-65,0,25)

close.MouseButton1Click:Connect(function()
    gui:Destroy()
end)

-- NEW HEADER PURPLE DIVIDER
local headerDivider = Instance.new("Frame")
headerDivider.Name = "HeaderDivider"
headerDivider.BackgroundColor3 = Theme.Purple
headerDivider.BorderSizePixel = 0
headerDivider.Size = UDim2.new(1,-50,0,2)
headerDivider.Position = UDim2.fromOffset(25,88)
headerDivider.Parent = main

local dividerGradient=Instance.new("UIGradient")
dividerGradient.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Theme.Cyan),
    ColorSequenceKeypoint.new(.5,Theme.Blue),
    ColorSequenceKeypoint.new(1,Theme.Purple)
})
dividerGradient.Parent=headerDivider


-- Forward declarations used by the global keyboard handler.
local inventoryOpen = false
local inventoryDropdown
local clickAway

-- SIDEBAR NAVIGATION ONLY
UIS.InputBegan:Connect(function(input,gp)
    if not gp and input.KeyCode==Enum.KeyCode.RightShift then
        gui.Enabled=not gui.Enabled
    end

    if not gp and input.KeyCode == Enum.KeyCode.Escape and inventoryDropdown and clickAway then
        inventoryOpen = false
        inventoryDropdown.Visible = false
        clickAway.Visible = false
    end
end)



-- NEW SIDEBAR
local side = Instance.new("Frame")
side.Size = UDim2.fromOffset(180,625)
side.Position = UDim2.fromOffset(25,105)
side.BackgroundColor3 = Theme.Panel
side.Parent = main
corner(side,16)
outline(side)
surfaceGradient(side,Color3.fromRGB(31,23,50),Color3.fromRGB(18,14,31))

local sideTitle = label(side,"MAIL",20,Enum.Font.GothamBold)
sideTitle.Position = UDim2.fromOffset(25,25)

local sideDesc = label(side,"Mailbox workspace",13,Enum.Font.GothamMedium)
sideDesc.Position = UDim2.fromOffset(25,65)
sideDesc.TextColor3 = Theme.Muted

local sideLine = Instance.new("Frame")
sideLine.BackgroundColor3 = Theme.Blue
sideLine.BorderSizePixel = 0
sideLine.Size = UDim2.fromOffset(130,2)
sideLine.Position = UDim2.fromOffset(25,95)
sideLine.Parent = side

local activeSideButton
local showPage
local pageButtons = {}

local MailPageVisible = true

local SheckleSettingsPanel

local function createSettingsPanel()

    local panel = Instance.new("Frame")
    panel.Name = "SheckleSettingsPanel"
    panel.Size = UDim2.fromOffset(890,560)
    panel.Position = UDim2.fromOffset(230,105)
    panel.BackgroundColor3 = Theme.BG
    panel.Visible = false
    panel.Parent = main

    corner(panel,16)
    outline(panel)

    local title = label(panel,"⚙ SETTINGS",26,Enum.Font.FredokaOne)
    title.Position = UDim2.fromOffset(25,20)

    local function card(y,height)
        local f = Instance.new("Frame")
        f.Size = UDim2.fromOffset(840,height)
        f.Position = UDim2.fromOffset(25,y)
        f.BackgroundColor3 = Theme.Panel
        f.Parent = panel
        corner(f,14)
        outline(f)
        return f
    end

    -- Sheckle ESP card
    local espCard = card(70,120)

    local espTitle = label(espCard,"🌱 SHECKLE ESP",18,Enum.Font.FredokaOne)
    espTitle.Position = UDim2.fromOffset(20,15)

    local espDesc = label(
        espCard,
        "Display fruit information, value and profit data above items.",
        14
    )
    espDesc.Position = UDim2.fromOffset(20,45)
    espDesc.TextColor3 = Theme.Muted
    espDesc.Size = UDim2.fromOffset(650,25)

    local esp = button(espCard,"☐ Disabled",16,Theme.Input)
    esp.Size = UDim2.fromOffset(150,38)
    esp.Position = UDim2.fromOffset(420,70)

    esp.MouseButton1Click:Connect(function()
        SheckleSettings.SheckleESP = not SheckleSettings.SheckleESP

        if SheckleSettings.SheckleESP then
            esp.Text = "☑ Enabled"
            esp.BackgroundColor3 = Theme.Blue
        else
            esp.Text = "☐ Disabled"
            esp.BackgroundColor3 = Theme.Input
        end
    end)


    -- Webhook card
    local hookCard = card(210,170)

    local hookTitle = label(
        hookCard,
        "YOUR DISCORD WEBHOOK (optional)",
        16,
        Enum.Font.FredokaOne
    )
    hookTitle.Position = UDim2.fromOffset(20,15)

    local hookDesc = label(
        hookCard,
        "Receive webhook messages for trades. Paste your Discord webhook below.",
        14
    )
    hookDesc.Position = UDim2.fromOffset(20,45)
    hookDesc.TextColor3 = Theme.Muted
    hookDesc.Size = UDim2.fromOffset(540,30)

    local webhook = Instance.new("TextBox")
    webhook.Size = UDim2.fromOffset(650,42)
    webhook.Position = UDim2.fromOffset(20,95)
    webhook.BackgroundColor3 = Theme.Input
    webhook.TextColor3 = Theme.Text
    webhook.PlaceholderText = "https://discord.com/api/webhooks/..."
    webhook.Text = SheckleSettings.TradeWebhookURL or ""
    webhook.ClearTextOnFocus = false
    webhook.Parent = hookCard
    corner(webhook,8)

    local save = button(hookCard,"Save",16,Theme.Blue)
    save.Size = UDim2.fromOffset(110,42)
    save.Position = UDim2.fromOffset(700,95)

    local status = label(hookCard,"No webhook set.",14)
    status.Position = UDim2.fromOffset(20,140)
    status.TextColor3 = Theme.Muted

    save.MouseButton1Click:Connect(function()
        local url = string.gsub(webhook.Text,"^%s*(.-)%s*$","%1")
        local valid = url == ""
            or string.match(url,"^https://discord%.com/api/webhooks/")
            or string.match(url,"^https://discordapp%.com/api/webhooks/")

        if not valid then
            status.Text = "Enter a valid Discord webhook URL."
            status.TextColor3 = Theme.Red
            return
        end

        SheckleSettings.TradeWebhookURL = url
        SheckleSettings.TradeWebhookEnabled = url ~= ""
        saveWebhookSettings()

        status.Text = SheckleSettings.TradeWebhookEnabled
            and "✓ Webhook active — trade logs enabled."
            or "No webhook set."

        status.TextColor3 = SheckleSettings.TradeWebhookEnabled
            and Color3.fromRGB(80,255,120)
            or Theme.Muted
    end)


    -- Future toggles area
    local future = card(400,90)

    local futureTitle = label(
        future,
        "MORE SETTINGS",
        16,
        Enum.Font.FredokaOne
    )
    futureTitle.Position = UDim2.fromOffset(20,15)

    local futureText = label(
        future,
        "More toggles can be added here later.",
        14
    )
    futureText.Position = UDim2.fromOffset(20,45)
    futureText.TextColor3 = Theme.Muted


    return panel
end


local function sideButton(txt,y,pageName)
    local b = button(side,txt,16,Theme.Input)
    b.Size = UDim2.fromOffset(150,42)
    b.Position = UDim2.fromOffset(15,y)

    local normal = Theme.Input
    local active = Theme.Purple

    local tabGlow = Instance.new("UIStroke")
    tabGlow.Name = "TabGlow"
    tabGlow.Color = Theme.Cyan
    tabGlow.Thickness = 1
    tabGlow.Transparency = 1
    tabGlow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    tabGlow.Parent = b

    b.MouseEnter:Connect(function()
        TweenService:Create(tabGlow,TweenInfo.new(.12),{
            Transparency = .48,
            Thickness = 1.25
        }):Play()
    end)

    b.MouseLeave:Connect(function()
        TweenService:Create(tabGlow,TweenInfo.new(.12),{
            Transparency = b:GetAttribute("ActiveTab") and .38 or 1,
            Thickness = b:GetAttribute("ActiveTab") and 1.25 or 1
        }):Play()
    end)

    b.MouseButton1Click:Connect(function()
        if activeSideButton then
            activeSideButton.BackgroundColor3 = normal
            activeSideButton:SetAttribute("ActiveTab",false)
            local oldGlow = activeSideButton:FindFirstChild("TabGlow")
            if oldGlow then
                oldGlow.Transparency = 1
                oldGlow.Thickness = 1
            end
        end

        activeSideButton = b
        b:SetAttribute("ActiveTab",true)
        b.BackgroundColor3 = active
        tabGlow.Transparency = .38
        tabGlow.Thickness = 1.25

        if showPage and pageName then
            showPage(pageName)
        end
    end)

    pageButtons[pageName or txt] = b

    return b
end

sideButton("Mail",112,"Mail")
sideButton("Fruit values",175,"Fruits")
sideButton("Incoming",238,"Incoming")
sideButton("History",303,"History")
SheckleSettingsPanel = createSettingsPanel()

local settingsButton = sideButton("Settings",370,"Settings")


sideButton("Guide",440,"Tutorial")

local discordBox = Instance.new("TextButton")
discordBox.Name = "DiscordPromo"
discordBox.Size = UDim2.fromOffset(150,85)
discordBox.Position = UDim2.fromOffset(15,515)
discordBox.BackgroundColor3 = Color3.fromRGB(80,45,180)
discordBox.TextColor3 = Theme.Text
discordBox.Text = ""
discordBox.AutoButtonColor = false
discordBox.Parent = side
corner(discordBox,14)
outline(discordBox)

local discordGradient = Instance.new("UIGradient")
discordGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(91,100,246)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(111,72,220))
})
discordGradient.Rotation = 25
discordGradient.Parent = discordBox

local discordIcon = label(discordBox,"◉",18,Enum.Font.GothamBold)
discordIcon.Position = UDim2.fromOffset(12,9)
discordIcon.Size = UDim2.fromOffset(22,24)
discordIcon.TextColor3 = Color3.fromRGB(190,202,255)

local discordTitle = label(discordBox,"Join our Server!",14,Enum.Font.GothamBold)
discordTitle.Position = UDim2.fromOffset(36,9)
discordTitle.Size = UDim2.fromOffset(105,24)

local discordLinkBox = Instance.new("Frame")
discordLinkBox.Size = UDim2.new(1,-18,0,32)
discordLinkBox.Position = UDim2.fromOffset(9,43)
discordLinkBox.BackgroundColor3 = Color3.fromRGB(39,47,102)
discordLinkBox.Parent = discordBox
corner(discordLinkBox,9)

local discordLinkStroke = Instance.new("UIStroke")
discordLinkStroke.Color = Color3.fromRGB(154,171,255)
discordLinkStroke.Transparency = .45
discordLinkStroke.Parent = discordLinkBox

local discordLink = label(discordLinkBox,"Discord.gg/pubert",12,Enum.Font.GothamBold)
discordLink.Size = UDim2.fromScale(1,1)
discordLink.TextXAlignment = Enum.TextXAlignment.Center

discordBox.MouseEnter:Connect(function()
    TweenService:Create(discordBox,TweenInfo.new(.12),{
        BackgroundColor3 = Color3.fromRGB(103,76,225)
    }):Play()
end)

discordBox.MouseLeave:Connect(function()
    TweenService:Create(discordBox,TweenInfo.new(.12),{
        BackgroundColor3 = Color3.fromRGB(80,45,180)
    }):Play()
end)

discordBox.MouseButton1Click:Connect(function()
    if setclipboard then
        setclipboard("https://discord.gg/pubert")
    end

    discordTitle.Text = "Copied to clipboard!"

    task.wait(1.5)

    discordTitle.Text = "Join our Server!"
end)

local body=Instance.new("Frame")
body.BackgroundTransparency=1
body.Position=UDim2.fromOffset(230,105)
body.Size=UDim2.new(1,-255,1,-135)
body.Parent=main

local function panel(pos,size,titleText)
    local f=Instance.new("Frame")
    f.Position=pos
    f.Size=size
    f.BackgroundColor3=Theme.Panel
    f.Parent=body
    corner(f,14)
    outline(f)
    surfaceGradient(f,Color3.fromRGB(38,28,62),Color3.fromRGB(20,15,34))

    local t=label(f,titleText,24,Enum.Font.FredokaOne)
    t.Position=UDim2.fromOffset(22,15)
    t.Size=UDim2.new(1,-45,0,35)

    makeLine(f,UDim2.fromOffset(20,55),UDim2.new(1,-40,0,2),Theme.Blue)
    return f
end

local recipient=panel(
    UDim2.fromOffset(0,0),
    UDim2.fromOffset(320,235),
    "RECIPIENT"
)

local user=Instance.new("TextBox")
user.Text=""
user.PlaceholderText="Username or UserID"
user.PlaceholderColor3=Theme.Muted
user.ClearTextOnFocus=false
user.Size=UDim2.fromOffset(270,45)
user.Position=UDim2.fromOffset(25,75)
user.BackgroundColor3=Theme.Input
user.TextColor3=Theme.Text
user.Font=Enum.Font.Gotham
user.TextSize=18
user.Parent=recipient
corner(user,8)


-- RECIPIENT CARD

local recipientCard = Instance.new("Frame")
recipientCard.Size = UDim2.fromOffset(270,75)
recipientCard.Position = UDim2.fromOffset(25,135)
recipientCard.BackgroundColor3 = Theme.BG
recipientCard.Parent = recipient

corner(recipientCard,12)
outline(recipientCard)
surfaceGradient(recipientCard,Color3.fromRGB(24,20,42),Color3.fromRGB(12,11,23))


local avatar = Instance.new("ImageLabel")
avatar.Size = UDim2.fromOffset(55,55)
avatar.Position = UDim2.fromOffset(10,10)
avatar.ScaleType = Enum.ScaleType.Crop
avatar.BackgroundColor3 = Theme.Input
avatar.Image = "rbxthumb://type=Asset&id=72772988377290&w=150&h=150"
avatar.ImageTransparency = 0
avatar.Parent = recipientCard

local avatarCorner = Instance.new("UICorner")
avatarCorner.CornerRadius = UDim.new(1,0)
avatarCorner.Parent = avatar


local SelectedRecipientId = nil
local SelectedRecipientUsername = nil
local MailQueue = {}

local recipientName = label(
    recipientCard,
    "👤 No recipient",
    24,
    Enum.Font.FredokaOne
)

recipientName.Position = UDim2.fromOffset(80,12)
recipientName.Size = UDim2.fromOffset(155,22)
recipientName.TextScaled = true
recipientName.TextWrapped = false


local recipientInfo = label(
    recipientCard,
    "Enter a username or UserID above",
    13
)

recipientInfo.Position = UDim2.fromOffset(80,38)
recipientInfo.Size = UDim2.fromOffset(155,30)
recipientInfo.TextScaled = true
recipientInfo.TextWrapped = true
recipientInfo.TextColor3 = Theme.Muted
recipientInfo.TextColor3 = Theme.Muted


local function updateRecipientCard(username,displayName,userId)

    SelectedRecipientId = userId
    SelectedRecipientUsername = username

    local displayNameText = username.."  ✓"

    recipientName.Text = displayNameText

    if #displayNameText > 16 then
        recipientName.TextSize = 16
    elseif #displayNameText > 12 then
        recipientName.TextSize = 18
    else
        recipientName.TextSize = 22
    end

    recipientName.TextColor3 =
        Color3.fromRGB(80,255,120)

    recipientInfo.Text =
        displayName..
        "\nUserID: "..tostring(userId)

    avatar.Image =
        "rbxthumb://type=Avatar&id="..tostring(userId).."&w=150&h=150"

    avatar.ImageTransparency = 0

end


user.FocusLost:Connect(function(enterPressed)

    if not enterPressed then
        return
    end

    local input = user.Text

    if input == "" then

    recipientName.Text = "👤 No recipient"

    recipientName.TextColor3 =
        Theme.Text

    recipientInfo.Text =
        "Enter a username or UserID above"


    -- force image refresh
    avatar.Image = ""

    task.wait()

    avatar.Image =
        "rbxthumb://type=Asset&id=72772988377290&w=150&h=150"

    avatar.ImageTransparency = 0

    return
end

    local success,userId = pcall(function()
        return tonumber(input) or game.Players:GetUserIdFromNameAsync(input)
    end)

    if success and userId then

    local nameSuccess, username = pcall(function()
        return game.Players:GetNameFromUserIdAsync(userId)
    end)

    if nameSuccess then

        updateRecipientCard(
            username,
            username,
            userId
        )

    else

        recipientName.Text = "⚠ Rate limited"

        recipientName.TextColor3 =
            Theme.Text

        recipientInfo.Text =
            "Try again in a few seconds"

        avatar.Image =
            "rbxthumb://type=Asset&id=72772988377290&w=150&h=150"

        avatar.ImageTransparency = 0

    end

else
        recipientName.Text = "❌ Invalid user"

recipientName.TextColor3 =
    Theme.Text

recipientInfo.Text =
    "Could not find player"
        avatar.Image = "rbxthumb://type=Asset&id=72772988377290&w=150&h=150"
        avatar.ImageTransparency = 0
    end

end)


local items=panel(
    UDim2.fromOffset(340,0),
    UDim2.fromOffset(550,235),
    "ADD ITEMS TO QUEUE"
)

local selectedItem = nil
local inventoryItems = {}

local searchBtn=Instance.new("TextBox")
searchBtn.Text=""
searchBtn.PlaceholderText="🔎 Search inventory..."
searchBtn.PlaceholderColor3=Theme.Text
searchBtn.ClearTextOnFocus=false
searchBtn.Size=UDim2.fromOffset(320,45)
searchBtn.Position=UDim2.fromOffset(35,75)
searchBtn.BackgroundColor3=Theme.Blue
searchBtn.TextColor3=Theme.Text
searchBtn.Font=Enum.Font.FredokaOne
searchBtn.TextSize=18
searchBtn.Parent=items
corner(searchBtn,10)

inventoryDropdown = Instance.new("Frame")
inventoryDropdown.Name = "InventoryDropdown"
inventoryDropdown.Size = UDim2.fromOffset(320,240)
inventoryDropdown.BackgroundColor3 = Theme.BG
inventoryDropdown.Visible = false
inventoryDropdown.ZIndex = 50

-- allow dropdown outside panel
items.ClipsDescendants = false

inventoryDropdown.Parent = items

corner(inventoryDropdown,10)
outline(inventoryDropdown)
inventoryDropdown.ClipsDescendants = true

-- CLICK OUTSIDE TO CLOSE INVENTORY DROPDOWN
clickAway = Instance.new("TextButton")
clickAway.BackgroundTransparency = 1
clickAway.Text = ""
clickAway.Size = UDim2.fromScale(1,1)
clickAway.Position = UDim2.fromScale(0,0)
clickAway.Visible = false
clickAway.ZIndex = 40
clickAway.Parent = gui

clickAway.MouseButton1Click:Connect(function()
    inventoryOpen = false
    inventoryDropdown.Visible = false
    clickAway.Visible = false
end)


local inventoryScroll = Instance.new("ScrollingFrame")

inventoryScroll.Name = "InventoryScroll"
inventoryScroll.Size = UDim2.new(1,-10,1,-10)
inventoryScroll.Position = UDim2.fromOffset(5,5)

inventoryScroll.BackgroundTransparency = 1
inventoryScroll.BorderSizePixel = 0

inventoryScroll.ScrollBarThickness = 6
inventoryScroll.ScrollBarImageColor3 = Theme.Cyan

inventoryScroll.CanvasSize = UDim2.new(0,0,0,0)

inventoryScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

inventoryScroll.ScrollingDirection = Enum.ScrollingDirection.Y

inventoryScroll.Parent = inventoryDropdown
inventoryScroll.ZIndex = 51

local inventoryLayout = Instance.new("UIListLayout")
inventoryLayout.Padding = UDim.new(0,3)
inventoryLayout.Parent = inventoryScroll

local function clearInventoryList()

    for _,v in pairs(inventoryScroll:GetChildren()) do

        if v:IsA("TextButton") then
            v:Destroy()
        end

    end

end


local function loadInventory()

    clearInventoryList()

    inventoryItems = {}

    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local ok, replica = pcall(function()

        local PS = require(
            ReplicatedStorage
            :WaitForChild("ClientModules")
            :WaitForChild("PlayerStateClient")
        )

        return PS:WaitForLocalReplica(10)

    end)


    if not ok or not replica or not replica.Data then
        warn("Failed loading replica")
        return
    end


    local inv = nil

    -- try common inventory locations
    if type(replica.Data.Inventory) == "table" then
        inv = replica.Data.Inventory
    elseif type(replica.Data.Inventories) == "table" then
        inv = replica.Data.Inventories
    elseif type(replica.Data.Items) == "table" then
        inv = replica.Data.Items
    end

    if type(inv) ~= "table" then
        warn("Inventory missing")
        warn("Replica keys:")
        for k,v in pairs(replica.Data) do
            warn(k, typeof(v))
        end
        return
    end



    local TRADEABLE = {

        Sprinklers = true,
        WateringCans = true,
        Mushrooms = true,
        Gnomes = true,
        Raccoons = true,
        Crates = true,
        SeedPacks = true,
        Trowels = true,
        Props = true,
        Seeds = true,
        Flashbangs = true,
        EmptyPots = true,
        Pets = true

    }



    -- normal items

    for category,_ in pairs(TRADEABLE) do

        local folder = inv[category]

        if type(folder) == "table" then

            for name,count in pairs(folder) do

                if type(count) == "number" and count > 0 then

                    table.insert(
                        inventoryItems,
                        {
                            Name = tostring(name),
                            Category = category,
                            Count = count
                        }
                    )

                end

            end

        end

    end



    -- pets stacked

    if type(inv.Pets) == "table" then


        local pets = {}


        for id,pet in pairs(inv.Pets) do


            if type(pet) == "table"
            and pet.Name
            and not pet.Equipped then


                local name = tostring(pet.Name)


                if not pets[name] then

                    pets[name] = {

                        Name=name,
                        Category="Pets",
                        Count=0,
                        ItemKey={}

                    }

                end


                pets[name].Count += 1


                table.insert(
                    pets[name].ItemKey,
                    id
                )


            end


        end



        for _,pet in pairs(pets) do

            table.insert(
                inventoryItems,
                pet
            )

        end


    end

    -- A manual refresh reloads server totals; keep queued amounts reserved locally.
    for _,queued in ipairs(MailQueue) do
        for _,inventoryItem in ipairs(inventoryItems) do
            if inventoryItem.Name == queued.Name
            and inventoryItem.Category == queued.Category then
                inventoryItem.Count = math.max(0,inventoryItem.Count - queued.Amount)
                break
            end
        end
    end


    if #inventoryItems == 0 then
        warn("Loaded inventory but no tradeable items found")
        for k,v in pairs(inv) do
            warn("Inventory category:", k, typeof(v))
        end
    end

end


local function changeInventoryCount(itemName, category, amount)

    for _,item in ipairs(inventoryItems) do

        if item.Name == itemName
        and item.Category == category then

            item.Count = item.Count + amount

            if item.Count < 0 then
                item.Count = 0
            end

            return
        end

    end

end

local function refreshInventory()
    clearInventoryList()

    local query = string.lower(searchBtn.Text)

    for _,itemData in pairs(inventoryItems) do
        if query == "" or string.find(string.lower(itemData.Name), query, 1, true) then

            local itemButton = button(
                inventoryScroll,
                itemData.Name.." x"..tostring(itemData.Count),
                15,
                Theme.Input
            )

            itemButton.ZIndex = 52
            itemButton.Size = UDim2.new(1,-5,0,35)

            itemButton.MouseButton1Click:Connect(function()
                selectedItem = itemData

searchBtn.Text = itemData.Name

inventoryDropdown.Visible = false
inventoryOpen = false
clickAway.Visible = false
            end)
        end
    end

    inventoryScroll.CanvasSize = UDim2.fromOffset(
        0,
        inventoryLayout.AbsoluteContentSize.Y
    )
end

searchBtn.Focused:Connect(function()

    if inventoryOpen then
        return
    end

    clearInventoryList()

    inventoryOpen = true
    inventoryDropdown.Visible = true
    inventoryDropdown.Position = UDim2.fromOffset(35,125)
    clickAway.Visible = true
    inventoryScroll.CanvasPosition = Vector2.new(0,0)

    -- only load once
    if #inventoryItems == 0 then
        loadInventory()
    end

    refreshInventory()

end)

searchBtn:GetPropertyChangedSignal("Text"):Connect(function()
    if inventoryOpen then
        refreshInventory()
    end
end)

local refresh=button(items,"♻",22,Theme.Blue)
refresh.AutoButtonColor = true
refresh.Size=UDim2.fromOffset(55,45)
refresh.Position=UDim2.fromOffset(365,75)

refresh.MouseButton1Click:Connect(function()

    loadInventory()

    refreshInventory()

    refresh.Text="✓"

    task.wait(.5)

    refresh.Text="♻"

end)

local amount=Instance.new("TextBox")
amount.Text=""
amount.PlaceholderText="Amount of items"
amount.PlaceholderColor3=Theme.Muted
amount.ClearTextOnFocus=false
amount.Size=UDim2.fromOffset(240,42)
amount.Position=UDim2.fromOffset(35,140)
amount.BackgroundColor3=Theme.Input
amount.TextColor3=Theme.Text
amount.Font=Enum.Font.Gotham
amount.TextSize=16
amount.Parent=items
corner(amount,8)

local add=button(items,"+ Add",18,Theme.Blue)
add.Size=UDim2.fromOffset(130,42)
add.Position=UDim2.fromOffset(295,140)

local MAX_QUEUE_SLOTS = 20
local MAX_STACK_AMOUNT = 9990
local MAX_QUEUE_AMOUNT = MAX_QUEUE_SLOTS * MAX_STACK_AMOUNT

local function getItemSlotCount(item)
    if item.Category == "Pets" then
        return item.Amount
    end

    return math.ceil(item.Amount / MAX_STACK_AMOUNT)
end

local function getQueueSlotCount()
    local slots = 0

    for _,item in ipairs(MailQueue) do
        slots += getItemSlotCount(item)
    end

    return slots
end


local function buildMailboxWaves()

    local waves = {}
    local usedKeysByWave = {}

    local function placeEntry(entry)
        local uniqueKey = entry.Category.."\0"..tostring(entry.ItemKey)

        for waveIndex,wave in ipairs(waves) do
            if #wave < MAX_QUEUE_SLOTS
            and not usedKeysByWave[waveIndex][uniqueKey] then
                table.insert(wave,entry)
                usedKeysByWave[waveIndex][uniqueKey] = true
                return
            end
        end

        table.insert(waves,{entry})
        table.insert(usedKeysByWave,{[uniqueKey] = true})
    end

    for _,item in ipairs(MailQueue) do


        -- PET HANDLING
        if item.Category == "Pets" then

            if type(item.ItemKey) == "table" then

                local amountLeft = item.Amount

                for _,petID in ipairs(item.ItemKey) do

                    if amountLeft <= 0 then
                        break
                    end


                    placeEntry({
                        Category = "Pets",
                        ItemKey = petID,
                        Count = 1
                    })

                    amountLeft -= 1

                end

            end



        -- NORMAL ITEMS
        else

            -- Different item keys share a trade. Repeated stacks of the same
            -- key are placed into later waves because duplicate keys are ignored.
            local amountLeft = item.Amount

            while amountLeft > 0 do
                local stackAmount = math.min(amountLeft,MAX_STACK_AMOUNT)

                placeEntry({
                    Category = item.Category,
                    ItemKey = item.Name,
                    Count = stackAmount
                })

                amountLeft -= stackAmount
            end

        end

    end

    return waves

end

local function consumeSentWave(wave)
    for _,sent in ipairs(wave) do
        if sent.Category == "Pets" then
            for _,queued in ipairs(MailQueue) do
                if queued.Category == "Pets" and type(queued.ItemKey) == "table" then
                    local petIndex = table.find(queued.ItemKey,sent.ItemKey)

                    if petIndex then
                        table.remove(queued.ItemKey,petIndex)
                        queued.Amount -= 1
                        break
                    end
                end
            end
        else
            for _,queued in ipairs(MailQueue) do
                if queued.Category == sent.Category and queued.Name == sent.ItemKey then
                    queued.Amount -= sent.Count
                    break
                end
            end
        end
    end

    for index = #MailQueue,1,-1 do
        if MailQueue[index].Amount <= 0 then
            table.remove(MailQueue,index)
        end
    end
end

local autoEnabled = false

local auto=button(items,"☐ Auto Accept incoming mail",15,Theme.Panel)
auto.Size=UDim2.fromOffset(350,32)
auto.Position=UDim2.fromOffset(35,185)

local autoThread = nil
local incomingAutoButton = nil
local refreshIncomingPage = function() end

local function claimMail()

    local success, result = pcall(function()

        return Net.Mailbox.ClaimAll:Fire()

    end)

    if not success then
        warn("Auto accept failed:", result)
    end

end

local function updateAutoAcceptButtons()
    auto.Text = autoEnabled
        and "☑ Auto Accept incoming mail"
        or "☐ Auto Accept incoming mail"
    auto.BackgroundColor3 = autoEnabled and Theme.Blue or Theme.Panel

    if incomingAutoButton then
        incomingAutoButton.Text = autoEnabled
            and "☑ AUTO ACCEPT  /  EVERY 1s"
            or "☐ AUTO ACCEPT  /  EVERY 1s"
        incomingAutoButton.BackgroundColor3 = autoEnabled and Theme.Blue or Theme.Input
    end
end

local function setAutoAccept(state)
    autoEnabled = state
    updateAutoAcceptButtons()

    if autoEnabled and not autoThread then
        autoThread = task.spawn(function()
            while autoEnabled and gui.Parent do
                claimMail()
                task.wait(1)
                refreshIncomingPage()
            end
            autoThread = nil
            runtimeEnvironment.LightsMailAutoThread = nil
        end)
        runtimeEnvironment.LightsMailAutoThread = autoThread
    elseif not autoEnabled and autoThread then
        pcall(task.cancel,autoThread)
        autoThread = nil
        runtimeEnvironment.LightsMailAutoThread = nil
    end
end

gui.Destroying:Connect(function()
    autoEnabled = false
    if autoThread then
        pcall(task.cancel,autoThread)
        autoThread = nil
    end
    runtimeEnvironment.LightsMailAutoThread = nil
end)

auto.MouseButton1Click:Connect(function()
    setAutoAccept(not autoEnabled)
end)
-- QUEUE REDESIGN
local queue=Instance.new("Frame")
queue.Position=UDim2.fromOffset(0,250)
queue.Size=UDim2.fromOffset(890,195)
queue.BackgroundColor3=Theme.Panel
queue.Parent=body
corner(queue,14)
outline(queue)
surfaceGradient(queue,Color3.fromRGB(36,26,58),Color3.fromRGB(19,14,32))

-- Queue title
local queueTitle=label(queue,"QUEUE  /  EMPTY",18,Enum.Font.GothamBold)
queueTitle.Position=UDim2.fromOffset(18,10)
queueTitle.Size=UDim2.fromOffset(600,25)


-- Note badge
local CurrentMailNote = "📝 Note: sent by JuicyAsian"

local note=button(
    queue,
    CurrentMailNote,
    14,
    Theme.Input
)

note.Size=UDim2.fromOffset(225,28)
note.Position=UDim2.new(1,-243,0,5)


-- MAIL NOTE PANEL
local notePanel = Instance.new("Frame")
notePanel.Size = UDim2.fromOffset(620,300)
notePanel.Position = UDim2.new(.5,-310,.5,-150)
notePanel.BackgroundColor3 = Theme.BG
notePanel.Visible = false
notePanel.ZIndex = 100
notePanel.Parent = gui

corner(notePanel,14)
outline(notePanel)

local noteTitle = label(
    notePanel,
    "📝 MAIL NOTE",
    24,
    Enum.Font.FredokaOne
)
noteTitle.Position = UDim2.fromOffset(20,20)
noteTitle.ZIndex = 101

local noteDesc = label(
    notePanel,
    "This note is attached to every mail sent. Set it once and it is reused every send.",
    14
)
noteDesc.Position = UDim2.fromOffset(20,55)
noteDesc.Size = UDim2.fromOffset(560,40)
noteDesc.TextColor3 = Theme.Muted
noteDesc.ZIndex = 101

local noteInput = Instance.new("TextBox")
noteInput.Text = CurrentMailNote
noteInput.PlaceholderText = "Mail note..."
noteInput.ClearTextOnFocus = false
noteInput.Size = UDim2.fromOffset(570,40)
noteInput.Position = UDim2.fromOffset(20,110)
noteInput.BackgroundColor3 = Theme.Input
noteInput.TextColor3 = Theme.Text
noteInput.Font = Enum.Font.Gotham
noteInput.TextSize = 16
noteInput.Parent = notePanel
noteInput.ZIndex = 101
corner(noteInput,8)

local saveNote = button(notePanel,"Save Note",16,Color3.fromRGB(40,180,90))
saveNote.Size = UDim2.fromOffset(185,40)
saveNote.Position = UDim2.fromOffset(20,170)
saveNote.ZIndex = 101

local resetNote = button(notePanel,"Reset to default",16,Theme.Yellow)
resetNote.Size = UDim2.fromOffset(185,40)
resetNote.Position = UDim2.fromOffset(215,170)
resetNote.ZIndex = 101

local closeNote = button(notePanel,"Close",16,Theme.Panel)
closeNote.Size = UDim2.fromOffset(185,40)
closeNote.Position = UDim2.fromOffset(410,170)
closeNote.ZIndex = 101

note.MouseButton1Click:Connect(function()
    noteInput.Text = CurrentMailNote
    notePanel.Visible = true

    for _,obj in pairs(notePanel:GetDescendants()) do
        if obj:IsA("GuiObject") then
            obj.ZIndex = 101
        end
    end
end)

saveNote.MouseButton1Click:Connect(function()
    CurrentMailNote = noteInput.Text

    if CurrentMailNote == "" then
        CurrentMailNote = "📝 Note: sent by JuicyAsian"
    end

    note.Text = CurrentMailNote
    notePanel.Visible = false
end)

resetNote.MouseButton1Click:Connect(function()
    noteInput.Text = "📝 Note: sent by JuicyAsian"
end)

closeNote.MouseButton1Click:Connect(function()
    notePanel.Visible = false
end)


-- Left queue display box
local queueBox=Instance.new("ScrollingFrame")
queueBox.Size=UDim2.fromOffset(470,140)
queueBox.Position=UDim2.fromOffset(18,40)
queueBox.BackgroundColor3=Theme.BG
queueBox.Parent=queue

queueBox.ScrollBarThickness = 6
queueBox.ScrollBarImageColor3 = Theme.Cyan
queueBox.CanvasSize = UDim2.new(0,0,0,0)
queueBox.AutomaticCanvasSize = Enum.AutomaticSize.Y
queueBox.ScrollingDirection = Enum.ScrollingDirection.Y

corner(queueBox,10)
outline(queueBox)


local queueLayout = Instance.new("UIListLayout")
queueLayout.Padding = UDim.new(0,3)
queueLayout.SortOrder = Enum.SortOrder.LayoutOrder
queueLayout.Parent = queueBox


local queuePadding = Instance.new("UIPadding")
queuePadding.PaddingTop = UDim.new(0,8)
queuePadding.PaddingLeft = UDim.new(0,10)
queuePadding.PaddingRight = UDim.new(0,10)
queuePadding.Parent = queueBox


local empty=label(queueBox,"Queue is empty\n\nAdd an item from the right.",18)
empty.Size=UDim2.new(1,-20,1,-20)
empty.Position=UDim2.fromOffset(10,0)
empty.TextXAlignment=Enum.TextXAlignment.Center
empty.TextYAlignment=Enum.TextYAlignment.Center
empty.ZIndex = 5



local function getQueueTotal()

    local total = 0

    for _,item in ipairs(MailQueue) do
        total += item.Amount
    end

    return total

end

local queueWarning = label(
    queue,
    "",
    14
)

queueWarning.Position = UDim2.fromOffset(540,100)
queueWarning.Size = UDim2.fromOffset(300,25)
queueWarning.TextColor3 = Theme.Red

-- Right info section
local queueInfo=label(
    queue,
    "Queue is empty.\nAdd items, pick a recipient, then\nSend.",
   20
)

queueInfo.Position=UDim2.fromOffset(510,65)
queueInfo.Size=UDim2.fromOffset(300,80)
queueInfo.TextColor3=Theme.Muted


-- forward declarations (must exist before refreshQueue uses them)
local function getQueueTotal()

    local total = 0

    for _,item in ipairs(MailQueue) do
        total += tonumber(item.Amount) or 0
    end

    return total

end


local function updateQueueInfo()

    if #MailQueue == 0 then

        queueInfo.Text =
            "Queue is empty.\nAdd items, pick a recipient, then\nSend."

        return

    end


    local total = getQueueTotal()

    queueInfo.Text =
        #MailQueue.." items ("..total.." total)\n"..
        "sending to one recipient."

end


local function refreshQueue()

    local total = 0

for _,item in ipairs(MailQueue) do
    total += item.Amount
end

local usedSlots = getQueueSlotCount()

queueTitle.Text = "QUEUE  /  "..usedSlots.." OF "..MAX_QUEUE_SLOTS.." SLOTS  /  "..total.." ITEMS"

if usedSlots >= MAX_QUEUE_SLOTS then

    queueWarning.Text = "⚠ Queue limit reached (20/20)"

elseif total >= MAX_QUEUE_AMOUNT then

    queueWarning.Text = "⚠ Item limit reached"

else

    queueWarning.Text = ""

end

-- update sending status safely after queue UI exists
updateQueueInfo()

    for _,v in pairs(queueBox:GetChildren()) do
        if v:IsA("GuiObject") and v ~= empty then
            v:Destroy()
        end
    end

    if #MailQueue == 0 then
        empty.Visible = true
        empty.Text = "Queue is empty\n\nAdd an item from the right."
        return
    end

    empty.Visible = false

    for index,item in ipairs(MailQueue) do

        local rowFrame = Instance.new("Frame")
rowFrame.Size = UDim2.fromOffset(470,28)
rowFrame.LayoutOrder = index
rowFrame.BackgroundTransparency = 1
rowFrame.Parent = queueBox


local row = label(
    rowFrame,
    item.Name.." x"..item.Amount,
    16
)

row.BackgroundTransparency = 1
row.TextColor3 = Theme.Text

row.Size = UDim2.fromOffset(390,28)
row.Position = UDim2.fromOffset(5,0)


local remove = Instance.new("TextButton")

remove.Text = "X"
remove.Font = Enum.Font.GothamBold
remove.TextSize = 14
remove.TextColor3 = Color3.fromRGB(255,255,255)

remove.BackgroundColor3 = Theme.Red
remove.Size = UDim2.fromOffset(24,24)
remove.Position = UDim2.fromOffset(420,2)

remove.Parent = rowFrame

corner(remove,8)


        remove.MouseButton1Click:Connect(function()

    local removed = MailQueue[index]

    if removed then

        changeInventoryCount(
    removed.Name,
    removed.Category,
    removed.Amount
)

    end

    table.remove(MailQueue,index)

    refreshInventory()

    refreshQueue()

end)

    end
end



-- Send batch button


local clear=button(main,"CLEAR QUEUE",18,Theme.Red)
clear.Size=UDim2.fromOffset(280,50)
clear.Position=UDim2.fromOffset(280,620)

clear.MouseButton1Click:Connect(function()

    -- return all queued items back to dropdown
    for _,item in ipairs(MailQueue) do

        changeInventoryCount(
            item.Name,
            item.Category,
            item.Amount
        )

    end


    MailQueue = {}


    refreshInventory()
    refreshQueue()

end)

local send=button(main,"SEND MAIL",18,Theme.Blue)
send.Size=UDim2.fromOffset(300,50)
send.Position=UDim2.fromOffset(680,620)

local sendingWaves = false
local cancelSending = false

local function formatItemCount(value)
    local formatted = tostring(math.floor(value))

    while true do
        local replaced,count = formatted:gsub("^(%-?%d+)(%d%d%d)","%1,%2")
        formatted = replaced

        if count == 0 then
            break
        end
    end

    return formatted
end

send.MouseButton1Click:Connect(function()

    if sendingWaves then
        cancelSending = true
        send.Text = "STOPPING..."
        return
    end


    local recipientName = SelectedRecipientId


    if not recipientName then
        recipientInfo.Text = "Select a verified recipient first"
        return
    end


    local waves = buildMailboxWaves()


    if #waves == 0 then
        return
    end

    sendingWaves = true
    cancelSending = false
    send.AutoButtonColor = false

    local completedWaves = 0
    local completedItems = 0
    local totalItems = 0
    local failedMessage = nil

    for _,wave in ipairs(waves) do
        for _,entry in ipairs(wave) do
            totalItems += entry.Count
        end
    end

    send.Text = "SENT 0/"..formatItemCount(totalItems)

    for waveIndex,wave in ipairs(waves) do
        -- The mailbox needs time to finish one transaction before accepting another.
        if waveIndex > 1 then
            send.Text = "SENT "..formatItemCount(completedItems).."/"..formatItemCount(totalItems)
            task.wait(5)
        end

        local ok = false
        local result
        local attempt = 0

        while not ok and not cancelSending do
            attempt += 1

            local callOk,callResult = pcall(function()
                return Net.Mailbox.SendBatch:Fire(
                    SelectedRecipientId,
                    wave,
                    CurrentMailNote
                )
            end)

            ok = callOk and callResult ~= false
            result = callResult

            if ok then
                break
            end

            local retryDelay = 5

            for secondsLeft = retryDelay,1,-1 do
                if cancelSending then
                    break
                end

                send.Text = "WAIT "..secondsLeft.."s • "
                    ..formatItemCount(completedItems).."/"..formatItemCount(totalItems)
                task.wait(1)
            end
        end

        if cancelSending or not ok then
            failedMessage = result or "Mailbox rejected wave "..waveIndex
            break
        end

        completedWaves += 1

        for _,entry in ipairs(wave) do
            completedItems += entry.Count
        end

        consumeSentWave(wave)
        addSendCount()
        updateSendCounter()
        refreshQueue()
        send.Text = "SENT "..formatItemCount(completedItems).."/"..formatItemCount(totalItems)
    end

    addMailHistoryEntry(
        SelectedRecipientUsername,
        SelectedRecipientId,
        waves,
        completedWaves
    )

    if completedWaves > 0 then
        task.spawn(
            sendMailWebhook,
            SelectedRecipientUsername,
            SelectedRecipientId,
            waves,
            completedWaves,
            CurrentMailNote
        )
    end

    if completedWaves == #waves then
        
        send.Text = "✓ SENT "..formatItemCount(completedItems).."/"..formatItemCount(totalItems)
        refreshInventory()

    elseif cancelSending then

        send.Text = "STOPPED • "..formatItemCount(completedItems).."/"..formatItemCount(totalItems)

    else

        send.Text = "FAILED • "..formatItemCount(completedItems).."/"..formatItemCount(totalItems)
        warn(failedMessage)

    end

    task.wait(2)

    sendingWaves = false
    cancelSending = false
    send.AutoButtonColor = true
    send.Text="SEND MAIL"


end)

add.MouseButton1Click:Connect(function()

    if not selectedItem then
        searchBtn.Text = "⚠ Select item first"
        return
    end


    local amountNumber = tonumber(amount.Text)


    if not amountNumber or amountNumber <= 0 then
        amount.PlaceholderText = "Enter amount"
        amount.Text = ""
        return
    end

    amountNumber = math.floor(amountNumber)


    -- CHECK INVENTORY LIMIT

    -- selectedItem.Count already excludes anything reserved in the queue.
    local available = selectedItem.Count


    if amountNumber > available then

        amount.Text = ""

        amount.PlaceholderText =
            "Only "..available.." available"

        return

    end



    -- ADD TO QUEUE

    local requestedSlots

    if selectedItem.Category == "Pets" then
        requestedSlots = amountNumber
    else
        local queuedAmount = 0

        for _,queued in ipairs(MailQueue) do
            if queued.Name == selectedItem.Name
            and queued.Category == selectedItem.Category then
                queuedAmount = queued.Amount
                break
            end
        end

        requestedSlots = math.ceil((queuedAmount + amountNumber) / MAX_STACK_AMOUNT)
            - math.ceil(queuedAmount / MAX_STACK_AMOUNT)
    end

    if getQueueSlotCount() + requestedSlots > MAX_QUEUE_SLOTS then

    searchBtn.Text = "⚠ Queue full (20 max)"

    return

end


local currentTotal = getQueueTotal()

if currentTotal + amountNumber > MAX_QUEUE_AMOUNT then

    amount.Text = ""

    amount.PlaceholderText =
        "Max queue is 199,800 items"

    return

end


    local found = false


    for _,queued in ipairs(MailQueue) do


        if queued.Name == selectedItem.Name
        and queued.Category == selectedItem.Category then


            queued.Amount += amountNumber

            found = true

            break

        end

    end



    if not found then


        table.insert(
            MailQueue,
            {
                Name = selectedItem.Name,
                Category = selectedItem.Category,
                Amount = amountNumber,
                Count = selectedItem.Count,
                ItemKey = selectedItem.ItemKey
            }
        )

    end

    changeInventoryCount(
    selectedItem.Name,
    selectedItem.Category,
    -amountNumber
)

refreshInventory()



refreshQueue()

-- reset item selector for next item
amount.Text = ""
searchBtn.Text = ""
selectedItem = nil

inventoryOpen = false
inventoryDropdown.Visible = false
clickAway.Visible = false

end)



-- ============================================================
-- SHECKLE ESP DISPLAY SYSTEM
-- ============================================================

local SheckleESPObjects = {}

local function clearSheckleESP()
    for _,v in pairs(SheckleESPObjects) do
        if v then
            v:Destroy()
        end
    end
    SheckleESPObjects = {}
end

local function createSheckleBillboard(part, text)
    local gui = Instance.new("BillboardGui")
    gui.Name = "SheckleESP"
    gui.Size = UDim2.fromOffset(220, 70)
    gui.StudsOffset = Vector3.new(0, 3, 0)
    gui.AlwaysOnTop = true
    gui.Parent = part

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Text = text
    label.TextColor3 = Color3.fromRGB(255, 220, 50)
    label.TextStrokeTransparency = 0
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 16
    label.TextWrapped = true
    label.Parent = gui

    table.insert(SheckleESPObjects, gui)
end

local function updateSheckleESP()
    clearSheckleESP()

    if not SheckleSettings.SheckleESP then
        return
    end

    local gardens = workspace:FindFirstChild("Gardens")
    if not gardens then
        return
    end

    for _,obj in ipairs(gardens:GetDescendants()) do
        if obj:IsA("Model") then

            local fruitName = obj:GetAttribute("CorePartName")
            local mutation = obj:GetAttribute("Mutation")
            local size = obj:GetAttribute("SizeMulti")

            if fruitName then
                local part = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")

                if part then
                    local info = fruitName

                    if mutation then
                        info ..= "\n" .. tostring(mutation)
                    end

                    if size then
                        info ..= "\nSize: "..string.format("%.2f", size)
                    end

                    createSheckleBillboard(part, info)
                end
            end
        end
    end
end

task.spawn(function()
    while gui.Parent do
        updateSheckleESP()
        task.wait(2)
    end
end)

-- ============================================================
-- PAGE SYSTEM
-- ============================================================

local mailObjects = {
    recipient,
    items,
    queue,
    clear,
    send,
}

-- force every mail-only object to hide when leaving the Mail page
local function setMailPageVisible(state)
    for _,obj in ipairs(mailObjects) do
        if obj and obj:IsA("GuiObject") then
            obj.Visible = state
        end
    end
end

local function createPlaceholderPage(name, icon, heading, description)
    local page = Instance.new("Frame")
    page.Name = name.."Page"
    page.Size = UDim2.fromOffset(890,560)
    page.Position = UDim2.fromOffset(230,105)
    page.BackgroundColor3 = Theme.BG
    page.Visible = false
    page.Parent = main
    corner(page,16)
    outline(page)

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(.5,.5)
    card.Position = UDim2.fromScale(.5,.5)
    card.Size = UDim2.fromOffset(620,250)
    card.BackgroundColor3 = Theme.Panel
    card.Parent = page
    corner(card,16)
    outline(card)

    local pageIcon = label(card,icon,54,Enum.Font.FredokaOne)
    pageIcon.Size = UDim2.new(1,0,0,65)
    pageIcon.Position = UDim2.fromOffset(0,28)
    pageIcon.TextXAlignment = Enum.TextXAlignment.Center

    local pageTitle = label(card,heading,27,Enum.Font.FredokaOne)
    pageTitle.Size = UDim2.new(1,-50,0,40)
    pageTitle.Position = UDim2.fromOffset(25,98)
    pageTitle.TextXAlignment = Enum.TextXAlignment.Center

    local pageDescription = label(card,description,16)
    pageDescription.Size = UDim2.new(1,-80,0,65)
    pageDescription.Position = UDim2.fromOffset(40,145)
    pageDescription.TextColor3 = Theme.Muted
    pageDescription.TextWrapped = true
    pageDescription.TextXAlignment = Enum.TextXAlignment.Center

    return page
end

local function readIncomingMail()
    local ok,replica = pcall(function()
        local stateClient = require(
            ReplicatedStorage
            :WaitForChild("ClientModules")
            :WaitForChild("PlayerStateClient")
        )
        return stateClient:WaitForLocalReplica(5)
    end)

    if not ok or not replica or type(replica.Data) ~= "table" then
        return {}
    end

    local data = replica.Data
    local source = data.IncomingMail
        or data.Inbox
        or data.ReceivedMail
        or data.PendingMail
        or data.Mailbox
        or data.Mail

    if type(source) ~= "table" then
        local bestTable = nil
        local bestScore = 0
        local visited = {}

        local function discover(value,depth,keyName)
            if type(value) ~= "table" or visited[value] or depth > 5 then
                return
            end
            visited[value] = true

            local keyLower = string.lower(tostring(keyName or ""))
            local score = 0

            if string.find(keyLower,"incoming",1,true) then score += 80 end
            if string.find(keyLower,"inbox",1,true) then score += 80 end
            if string.find(keyLower,"received",1,true) then score += 60 end
            if string.find(keyLower,"pending",1,true) then score += 40 end
            if string.find(keyLower,"mailbox",1,true) then score += 25 end

            for _,entry in pairs(value) do
                if type(entry) == "table" then
                    if entry.Sender or entry.From or entry.SenderName or entry.FromName then
                        score += 30
                    end
                    if entry.Items or entry.Attachments or entry.Contents then
                        score += 30
                    end
                    if entry.Note or entry.Message then
                        score += 10
                    end
                end
            end

            if score > bestScore then
                bestScore = score
                bestTable = value
            end

            for childKey,childValue in pairs(value) do
                discover(childValue,depth + 1,childKey)
            end
        end

        discover(data,0,"PlayerData")
        source = bestTable
    end

    if type(source) ~= "table" then
        return {}
    end

    source = source.Incoming
        or source.Inbox
        or source.Received
        or source.Pending
        or source.Messages
        or source.Mail
        or source
    if type(source) ~= "table" then
        return {}
    end

    local results = {}

    for id,raw in pairs(source) do
        if type(raw) == "table" then
            local sender = raw.SenderName
                or raw.FromName
                or raw.SenderUsername
                or raw.FromUsername
                or raw.Sender
                or raw.From
                or raw.SenderId
                or raw.FromUserId
            local rawItems = raw.Items
                or raw.Attachments
                or raw.Inventory
                or raw.Contents
                or raw.ItemData
                or raw.Gifts

            if sender or rawItems then
                local entry = {
                    Id = id,
                    Sender = tostring(sender or "Unknown sender"),
                    Note = tostring(raw.Note or raw.Message or "No note attached"),
                    Timestamp = tonumber(raw.Timestamp or raw.Time or raw.SentAt) or os.time(),
                    Items = {},
                    Total = 0
                }

                local function addItem(category,name,count)
                    count = tonumber(count) or 1
                    table.insert(entry.Items,{
                        Category = tostring(category or "ITEM"),
                        Name = tostring(name or "Unknown item"),
                        Count = count
                    })
                    entry.Total += count
                end

                if type(rawItems) == "table" then
                    for itemKey,itemValue in pairs(rawItems) do
                        if type(itemValue) == "number" then
                            addItem("ITEM",itemKey,itemValue)
                        elseif type(itemValue) == "table" then
                            local directName = itemValue.Name
                                or itemValue.ItemName
                                or itemValue.ItemKey
                                or itemValue.Key
                                or itemValue.Id
                            if directName then
                                addItem(
                                    itemValue.Category or "ITEM",
                                    directName,
                                    itemValue.Count or itemValue.Amount or itemValue.Quantity
                                )
                            else
                                for nestedName,nestedValue in pairs(itemValue) do
                                    if type(nestedValue) == "number" then
                                        addItem(itemKey,nestedName,nestedValue)
                                    end
                                end
                            end
                        end
                    end
                end

                table.insert(results,entry)
            end
        end
    end

    -- Some versions keep inbox data only in the native MailboxUI. Read its
    -- visible cards when no compatible replica table was found.
    if #results == 0 then
        local nativeMailbox = player.PlayerGui:FindFirstChild("MailboxUI")

        if nativeMailbox then
            local bestList = nil
            local bestScore = -1

            for _,object in ipairs(nativeMailbox:GetDescendants()) do
                local objectName = string.lower(object.Name)
                local isMailContainer = object:IsA("ScrollingFrame")
                    or (object:IsA("Frame") and (
                        string.find(objectName,"incoming",1,true)
                        or string.find(objectName,"inbox",1,true)
                        or string.find(objectName,"received",1,true)
                    ))

                if isMailContainer then
                    local path = string.lower(object:GetFullName())
                    local score = 0

                    if string.find(path,"incoming",1,true)
                    or string.find(path,"inbox",1,true)
                    or string.find(path,"received",1,true) then
                        score += 200
                    end

                    if object:IsA("ScrollingFrame") then
                        score += 100
                    end

                    if not string.find(path,"inventory",1,true) then
                        for _,child in ipairs(object:GetChildren()) do
                            if child:IsA("GuiObject") then
                                score += 1
                            end
                        end
                    else
                        score = -1
                    end

                    if score > bestScore then
                        bestScore = score
                        bestList = object
                    end
                end
            end

            if bestList and bestScore > 0 then
                for cardIndex,card in ipairs(bestList:GetChildren()) do
                    if card:IsA("GuiObject") and card.Visible then
                        local texts = {}
                        local seenText = {}

                        local function captureText(object)
                            if (object:IsA("TextLabel") or object:IsA("TextButton"))
                            and object.Visible then
                                local value = string.gsub(object.Text or "","^%s*(.-)%s*$","%1")
                                if value ~= "" and not seenText[value] then
                                    seenText[value] = true
                                    table.insert(texts,value)
                                end
                            end
                        end

                        captureText(card)
                        for _,object in ipairs(card:GetDescendants()) do
                            captureText(object)
                        end

                        if #texts >= 2 then
                            local entry = {
                                Id = card.Name..":"..cardIndex,
                                Sender = texts[1],
                                Note = "No note attached",
                                Timestamp = os.time(),
                                Items = {},
                                Total = 0
                            }

                            for _,value in ipairs(texts) do
                                local lower = string.lower(value)

                                if string.find(lower,"note",1,true) then
                                    entry.Note = value
                                else
                                    local countText = value:match("[x×]%s*([%d,]+)")
                                        or value:match("([%d,]+)%s*[x×]")

                                    if countText then
                                        local count = tonumber((countText:gsub(",",""))) or 1
                                        local itemName = value
                                            :gsub("[x×]%s*[%d,]+","")
                                            :gsub("[%d,]+%s*[x×]","")
                                            :gsub("^%s*(.-)%s*$","%1")

                                        table.insert(entry.Items,{
                                            Category = "ITEM",
                                            Name = itemName ~= "" and itemName or "Mailbox item",
                                            Count = count
                                        })
                                        entry.Total += count
                                    end
                                end
                            end

                            if #entry.Items == 0 then
                                table.insert(entry.Items,{
                                    Category = "MAIL",
                                    Name = texts[2],
                                    Count = 1
                                })
                                entry.Total = 1
                            end

                            table.insert(results,entry)
                        end
                    end
                end
            end

            -- Keep the native window from covering the custom mailbox after
            -- it has served as the data source.
            if nativeMailbox:IsA("ScreenGui") then
                nativeMailbox.Enabled = false
            end
        end
    end

    table.sort(results,function(a,b)
        return a.Timestamp > b.Timestamp
    end)
    return results
end

local function createIncomingPage()
    local page = Instance.new("Frame")
    page.Name = "IncomingPage"
    page.Size = UDim2.fromOffset(890,560)
    page.Position = UDim2.fromOffset(230,105)
    page.BackgroundColor3 = Theme.BG
    page.Visible = false
    page.Parent = main
    corner(page,16)
    outline(page)

    local pageTitle = label(page,"INCOMING MAIL",24,Enum.Font.GothamBold)
    pageTitle.Position = UDim2.fromOffset(24,18)
    pageTitle.Size = UDim2.fromOffset(400,30)

    local status = label(page,"Checking mailbox...",13,Enum.Font.GothamMedium)
    status.Position = UDim2.fromOffset(24,48)
    status.Size = UDim2.fromOffset(450,22)
    status.TextColor3 = Theme.Muted

    local refreshButton = button(page,"REFRESH",13,Theme.Input)
    refreshButton.Size = UDim2.fromOffset(100,34)
    refreshButton.Position = UDim2.new(1,-124,0,18)

    local acceptAll = button(page,"ACCEPT ALL",13,Theme.Blue)
    acceptAll.Size = UDim2.fromOffset(120,36)
    acceptAll.Position = UDim2.new(1,-144,0,68)

    incomingAutoButton = button(page,"☐ AUTO ACCEPT  /  EVERY 1s",13,Theme.Input)
    incomingAutoButton.Size = UDim2.fromOffset(260,36)
    incomingAutoButton.Position = UDim2.fromOffset(24,68)
    updateAutoAcceptButtons()

    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1,-48,1,-130)
    list.Position = UDim2.fromOffset(24,118)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 5
    list.ScrollBarImageColor3 = Theme.Cyan
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.CanvasSize = UDim2.new()
    list.Parent = page

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0,9)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list

    local expanded = {}

    refreshIncomingPage = function()
        if not page.Visible then
            return
        end

        for _,child in ipairs(list:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end

        local incoming = readIncomingMail()
        local totalItems = 0
        for _,entry in ipairs(incoming) do
            totalItems += entry.Total
        end

        status.Text = #incoming.." waiting  /  "..formatItemCount(totalItems).." total items"
        acceptAll.Visible = #incoming > 0

        if #incoming == 0 then
            local emptyCard = Instance.new("Frame")
            emptyCard.Size = UDim2.new(1,-6,0,180)
            emptyCard.BackgroundColor3 = Theme.Panel
            emptyCard.Parent = list
            corner(emptyCard,12)
            outline(emptyCard)

            local emptyTitle = label(emptyCard,"MAILBOX IS EMPTY",18,Enum.Font.GothamBold)
            emptyTitle.Size = UDim2.new(1,0,0,30)
            emptyTitle.Position = UDim2.fromOffset(0,52)
            emptyTitle.TextXAlignment = Enum.TextXAlignment.Center

            local emptyText = label(emptyCard,"Fresh mail will appear here when it arrives.",13)
            emptyText.Size = UDim2.new(1,0,0,24)
            emptyText.Position = UDim2.fromOffset(0,88)
            emptyText.TextColor3 = Theme.Muted
            emptyText.TextXAlignment = Enum.TextXAlignment.Center
            return
        end

        for index,entry in ipairs(incoming) do
            local isExpanded = expanded[tostring(entry.Id)] == true
            local rowHeight = isExpanded and (104 + #entry.Items * 28) or 78
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1,-6,0,rowHeight)
            row.BackgroundColor3 = Color3.fromRGB(25,36,63)
            row.Text = ""
            row.AutoButtonColor = false
            row.LayoutOrder = index
            row.Parent = list
            corner(row,10)
            outline(row)

            local accent = Instance.new("Frame")
            accent.Size = UDim2.new(0,3,1,-12)
            accent.Position = UDim2.fromOffset(0,6)
            accent.BackgroundColor3 = Theme.Cyan
            accent.BorderSizePixel = 0
            accent.Parent = row

            local sender = label(row,entry.Sender,15,Enum.Font.GothamBold)
            sender.Position = UDim2.fromOffset(18,10)
            sender.Size = UDim2.new(1,-190,0,24)

            local meta = label(
                row,
                #entry.Items.." item types  /  "..os.date("%Y-%m-%d  %H:%M",entry.Timestamp),
                11
            )
            meta.Position = UDim2.fromOffset(18,34)
            meta.Size = UDim2.new(1,-190,0,18)
            meta.TextColor3 = Theme.Muted

            local noteText = label(row,"Note: "..entry.Note,11)
            noteText.Position = UDim2.fromOffset(18,53)
            noteText.Size = UDim2.new(1,-200,0,18)
            noteText.TextColor3 = Theme.Muted

            local worth = label(
                row,
                formatItemCount(entry.Total).."  "..(isExpanded and "▲" or "▼"),
                14,
                Enum.Font.GothamBold
            )
            worth.Position = UDim2.new(1,-160,0,22)
            worth.Size = UDim2.fromOffset(140,26)
            worth.TextXAlignment = Enum.TextXAlignment.Right
            worth.TextColor3 = Theme.Cyan

            if isExpanded then
                for itemIndex,item in ipairs(entry.Items) do
                    local itemLine = label(
                        row,
                        string.upper(item.Category).."   "..item.Name.."   ×"..formatItemCount(item.Count),
                        12,
                        Enum.Font.GothamMedium
                    )
                    itemLine.Position = UDim2.fromOffset(24,75 + itemIndex * 27)
                    itemLine.Size = UDim2.new(1,-48,0,24)
                end
            end

            row.MouseButton1Click:Connect(function()
                expanded[tostring(entry.Id)] = not expanded[tostring(entry.Id)]
                refreshIncomingPage()
            end)
        end
    end

    incomingAutoButton.MouseButton1Click:Connect(function()
        setAutoAccept(not autoEnabled)
    end)

    refreshButton.MouseButton1Click:Connect(function()
        refreshButton.Text = "CHECKING..."
        refreshIncomingPage()
        refreshButton.Text = "REFRESH"
    end)

    acceptAll.MouseButton1Click:Connect(function()
        acceptAll.Text = "ACCEPTING..."
        claimMail()
        task.wait(1)
        refreshIncomingPage()
        acceptAll.Text = "ACCEPT ALL"
    end)

    refreshIncomingPage()
    return page
end

local function createHistoryPage()
    local page = Instance.new("Frame")
    page.Name = "HistoryPage"
    page.Size = UDim2.fromOffset(890,560)
    page.Position = UDim2.fromOffset(230,105)
    page.BackgroundColor3 = Theme.BG
    page.Visible = false
    page.Parent = main
    corner(page,16)
    outline(page)

    local pageTitle = label(page,"MAIL HISTORY",24,Enum.Font.GothamBold)
    pageTitle.Position = UDim2.fromOffset(24,18)
    pageTitle.Size = UDim2.fromOffset(420,30)

    local pageCount = label(page,"0 deliveries logged",15,Enum.Font.Cartoon)
    pageCount.Position = UDim2.fromOffset(24,48)
    pageCount.Size = UDim2.fromOffset(420,22)
    pageCount.TextColor3 = Theme.Muted

    local clearHistory = button(page,"CLEAR",15,Theme.Red)
    clearHistory.Size = UDim2.fromOffset(90,34)
    clearHistory.Position = UDim2.new(1,-114,0,20)

    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1,-150,0,38)
    search.Position = UDim2.fromOffset(24,80)
    search.BackgroundColor3 = Theme.Input
    search.TextColor3 = Theme.Text
    search.Text = ""
    search.PlaceholderColor3 = Theme.Muted
    search.PlaceholderText = "Search sender, recipient, or item..."
    search.ClearTextOnFocus = false
    search.Font = Enum.Font.Gotham
    search.TextSize = 16
    search.Parent = page
    corner(search,9)

    local resetSearch = button(page,"RESET",15,Theme.Input)
    resetSearch.Size = UDim2.fromOffset(105,38)
    resetSearch.Position = UDim2.new(1,-129,0,80)

    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1,-48,1,-150)
    list.Position = UDim2.fromOffset(24,132)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 5
    list.ScrollBarImageColor3 = Theme.Purple
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.CanvasSize = UDim2.new()
    list.Parent = page

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0,8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list

    local expanded = {}

    refreshHistoryPage = function()
        for _,child in ipairs(list:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end

        pageCount.Text = #MailHistory.." deliveries logged"
        local query = string.lower(search.Text)
        local shown = 0

        for index,entry in ipairs(MailHistory) do
            local searchable = string.lower(
                tostring(entry.Sender).." "..tostring(entry.Recipient)
            )

            for _,item in ipairs(entry.Items or {}) do
                searchable ..= " "..string.lower(tostring(item.Name))
            end

            if query == "" or string.find(searchable,query,1,true) then
                shown += 1
                local isExpanded = expanded[index] == true
                local itemCount = #(entry.Items or {})
                local rowHeight = isExpanded and (102 + itemCount * 28) or 82

                local row = Instance.new("TextButton")
                row.Name = "HistoryRow"
                row.LayoutOrder = index
                row.Size = UDim2.new(1,-6,0,rowHeight)
                row.BackgroundColor3 = Color3.fromRGB(20,29,50)
                row.Text = ""
                row.AutoButtonColor = false
                row.Parent = list
                corner(row,10)
                outline(row)

                local accent = Instance.new("Frame")
                accent.Size = UDim2.new(0,3,1,-12)
                accent.Position = UDim2.fromOffset(0,6)
                accent.BackgroundColor3 = Theme.Cyan
                accent.BorderSizePixel = 0
                accent.Parent = row
                corner(accent,2)

                local route = label(
                    row,
                    tostring(entry.Sender).."   →   "..tostring(entry.Recipient),
                    17,
                    Enum.Font.Cartoon
                )
                route.Position = UDim2.fromOffset(18,10)
                route.Size = UDim2.new(1,-210,0,28)
                route.TextColor3 = Theme.Text

                local timestamp = label(
                    row,
                    os.date("%Y-%m-%d  %H:%M",entry.Timestamp or os.time()),
                    14,
                    Enum.Font.Cartoon
                )
                timestamp.Position = UDim2.fromOffset(18,42)
                timestamp.Size = UDim2.fromOffset(240,22)
                timestamp.TextColor3 = Theme.Muted

                local total = label(
                    row,
                    formatItemCount(entry.Total or 0).." items  "..(isExpanded and "▲" or "▼"),
                    16,
                    Enum.Font.Cartoon
                )
                total.Position = UDim2.new(1,-190,0,25)
                total.Size = UDim2.fromOffset(170,28)
                total.TextXAlignment = Enum.TextXAlignment.Right
                total.TextColor3 = Color3.fromRGB(80,235,160)

                if isExpanded then
                    local divider = Instance.new("Frame")
                    divider.Size = UDim2.new(1,-36,0,1)
                    divider.Position = UDim2.fromOffset(18,77)
                    divider.BackgroundColor3 = Color3.fromRGB(49,64,94)
                    divider.BorderSizePixel = 0
                    divider.Parent = row

                    for itemIndex,item in ipairs(entry.Items or {}) do
                        local itemLine = label(
                            row,
                            tostring(item.Name).."  ×"..formatItemCount(item.Count or 0),
                            15,
                            Enum.Font.Cartoon
                        )
                        itemLine.Position = UDim2.fromOffset(26,80 + itemIndex * 28)
                        itemLine.Size = UDim2.new(1,-52,0,26)
                        itemLine.TextColor3 = Theme.Text
                    end
                end

                row.MouseButton1Click:Connect(function()
                    expanded[index] = not expanded[index]
                    refreshHistoryPage()
                end)
            end
        end

        if shown == 0 then
            local emptyState = label(
                list,
                query == "" and "No mail deliveries logged yet." or "No matching history found.",
                17,
                Enum.Font.Cartoon
            )
            emptyState.Size = UDim2.new(1,-6,0,80)
            emptyState.TextColor3 = Theme.Muted
            emptyState.TextXAlignment = Enum.TextXAlignment.Center
        end
    end

    search:GetPropertyChangedSignal("Text"):Connect(refreshHistoryPage)
    resetSearch.MouseButton1Click:Connect(function()
        search.Text = ""
        expanded = {}
        refreshHistoryPage()
    end)
    clearHistory.MouseButton1Click:Connect(function()
        MailHistory = {}
        expanded = {}
        saveMailHistory()
        refreshHistoryPage()
    end)

    refreshHistoryPage()
    return page
end

local extraPages = {
    Fruits = createPlaceholderPage(
        "Fruits","🌱","FRUIT VALUE TOOLS",
        "Inventory value overlays and fruit calculations will appear here."
    ),
    Incoming = createIncomingPage(),
    History = createHistoryPage(),
    Tutorial = createPlaceholderPage(
        "Tutorial","📖","HOW TO USE LIGHT'S MAIL",
        "Choose a verified recipient, add inventory items to the queue, then send the batch."
    )
}

local currentPage = "Mail"

showPage = function(name)

    currentPage = name

    setMailPageVisible(name == "Mail")

    if SheckleSettingsPanel then
        SheckleSettingsPanel.Visible = (name == "Settings")
    end

    for pageName,page in pairs(extraPages) do
        page.Visible = (name == pageName)
    end

    if name == "Incoming" then
        refreshIncomingPage()
    end

end

showPage("Mail")
if pageButtons.Mail then
    activeSideButton = pageButtons.Mail
    activeSideButton:SetAttribute("ActiveTab",true)
    activeSideButton.BackgroundColor3 = Theme.Purple
    local initialGlow = activeSideButton:FindFirstChild("TabGlow")
    if initialGlow then
        initialGlow.Transparency = .38
        initialGlow.Thickness = 1.25
    end
end

-- COLLAPSE SYSTEM
local collapsed = false

local hiddenObjects = {}

collapse.MouseButton1Click:Connect(function()

    collapsed = not collapsed

    collapse.Text = collapsed and "+" or "−"

    if collapsed then

        hiddenObjects = {}

        for _,obj in pairs(main:GetChildren()) do

            if obj:IsA("GuiObject")
            and obj ~= collapse
            and obj ~= close
            and obj ~= title
            and obj ~= mailBadge
            and obj ~= sub
            and obj ~= live
            and obj ~= headerDivider then

                hiddenObjects[obj] = obj.Visible
                obj.Visible = false
            end
        end


    else

        for obj,wasVisible in pairs(hiddenObjects) do

            if obj then
                obj.Visible = wasVisible
            end

        end

    end


    TweenService:Create(
        main,
        TweenInfo.new(
            .35,
            Enum.EasingStyle.Quint,
            Enum.EasingDirection.Out
        ),
        {
            Size =
            collapsed
            and UDim2.fromOffset(1180,105)
            or UDim2.fromOffset(1180,760)
        }
    ):Play()

end)
