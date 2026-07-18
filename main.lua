-- ============================================================
--  TALLEST GUILD v1.1  -  Script by JuicyAsian   (Grow a Garden)
--  Height hunter: keeps a sprinkler down on YOUR plot, plants
--  batches of one seed (default Bamboo), and judges every plant
--  by its "Height" model attribute (newer plants), falling back
--  to the CollisionBlock "MaxHeight" attribute. The value is
--  rounded UP like the game displays it (353.2 reads as 354).
--  Rounded height >= target = KEEPER: its harvest prompt is
--  destroyed on sight, it is never removed, a webhook can ping
--  you, and "Stop when found" can end the run.
--  Everything below the target is removed AUTOMATICALLY, routed
--  LIVE per plant by its model attributes (no mode guessing):
--    PlantType present ("Plant") - no working harvest prompt, the
--              shovel is the ONLY remover: Shovel.UseShovel per
--              plant, shovel held, any age
--    crop (no PlantType) with Age == MaxAge - ready NOW: its
--              HarvestPrompt is blasted and you keep the crop
--    crop still growing (Age < MaxAge) - not worth waiting on:
--              shoveled with the rest; if it ripens before the
--              shovel reaches it, its route flips to collect
--  Shovel order inside a pass: PlantType models first (they can
--  never be claimed), then crops by BIGGEST MaxAge-Age gap -
--  nearly-ripe crops sink to the end so they get time to ripen
--  and be CLAIMED by the collect engine instead of shoveled
--  The collect blaster is a PERSISTENT engine: it iterates the
--  planted crop the whole time the hunt runs, so grown plants are
--  claimed WHILE the next seeds are still going down - no waiting
--  for the batch to finish. Auto sell fires NPCS.SellAll on its
--  own timer (toggle + interval in the AUTO SELL card).
--  Cycle: sprinkler -> plant N seed fires -> judge -> remove all
--  non-keepers of OUR seed -> repeat. Other crops are never
--  touched: judging keys on the plant's SeedName attribute.
--  Anti-AFK (both layers) and noclip are always on. RightShift
--  hides/shows the window, X shuts the script down (re-execute
--  to use it again). Settings persist via the Save config toggle.
-- ============================================================

-- ============================================================
--  CONFIG  (defaults; almost everything is UI-editable)
-- ============================================================
local SEED_NAME        = "Bamboo"                   -- the one crop this run hunts
local TARGET_HEIGHT    = 60                         -- keeper when round(MaxHeight) >= this
local SEEDS_PER_BATCH  = 100                        -- seed fires per cycle before removal
local STOP_ON_FOUND    = false                      -- true = the whole run stops at the first keeper
local SPRINKLER_NAME   = "Super Sprinkler"          -- tool name in your backpack
local SPRINKLER_LIFE   = 120                        -- seconds one sprinkler lasts (Super Sprinkler = 120)
local PLACE_SPRINKLER  = true                       -- always have one down before planting
local PLANT_RADIUS     = 20                         -- studs around the plot center
local PLANT_DELAY      = 0.05                       -- seconds between PlantSeed fires
local ONLY_PLANT_AREA  = true                       -- raycast each spot onto a PlantArea tile
local CENTER_ON_SELF   = false                      -- plant around where you stand instead of the plot center
local SHOVEL_DELAY     = 0.25                       -- seconds between UseShovel fires
local COLLECT_BATCH    = 30                         -- prompts fired simultaneously per batch
local COLLECT_DELAY    = 0                          -- wait between prompt batches (0 = every frame)
local SCAN_DELAY       = 0.1                        -- seconds between judge sweeps
local AUTO_SELL        = false                      -- fire NPCS.SellAll on a timer
local SELL_INTERVAL    = 5                          -- seconds between SellAll fires
local PROMPT_RANGE     = 1000000                    -- studs; a fired prompt must be in range
local UI_SCALE         = 0.85                        -- global window scale (1 = full size)
local TOGGLE_KEY       = Enum.KeyCode.RightShift    -- show/hide the window
local STARTUP_KEY      = Enum.KeyCode.G             -- hammered until the game loads
local STARTUP_INTERVAL = 1                          -- seconds between startup key presses
local STARTUP_TIMEOUT  = 120                        -- give up pressing after this many seconds
local SCRIPT_VERSION   = "v1.6"

-- ============================================================
--  DISCORD  (all webhook URLs live here, nowhere else)
-- ============================================================
local WEBHOOK_URL    = ""                           -- pinged once per keeper; UI-editable
local WEBHOOK_NAME   = "Tallest Guild by Pubert"
local WEBHOOK_AVATAR = "https://images-ext-1.discordapp.net/external/GyDHCHVC3oUMvV2EV_-HdkwHnCISKW4e91AZcn3B1oI/%3Fsize%3D4096/https/cdn.discordapp.com/avatars/751854078920753294/97c94ada5ee082d02b1e855eecbd4c95.png?format=webp&quality=lossless&width=282&height=282"

-- ============================================================
--  DEBUG
-- ============================================================
local DEBUG_LOGS = true                             -- print loop activity to the console
local function dlog(tag, msg)
    if DEBUG_LOGS then
        print(("[TallestGuild][%s] %s"):format(tag, msg))
    end
end

-- ============================================================
--  SERVICES
-- ============================================================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")

-- a queued/auto execution can run before the Player object exists
local LocalPlayer = Players.LocalPlayer
while LocalPlayer == nil do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

-- ============================================================
--  RUN GUARD  (one live instance only + a session token)
-- ============================================================
-- The live instance beats a heartbeat into getgenv every second. A second
-- execution that sees a fresh heartbeat aborts itself; a stale one means the
-- old run crashed or was X-closed and the new execution takes over.
do
    local lastBeat = getgenv().TallestGuild_Heartbeat
    if getgenv().TallestGuild_Session ~= nil
        and type(lastBeat) == "number"
        and os.clock() - lastBeat < 5 then
        warn("[TallestGuild] already running - this execution aborted itself. Close the live one with X first.")
        return
    end
end

local SESSION = {}
getgenv().TallestGuild_Session = SESSION
local function alive()
    return getgenv().TallestGuild_Session == SESSION
end

task.spawn(function()
    while alive() do
        getgenv().TallestGuild_Heartbeat = os.clock()
        task.wait(1)
    end
end)

-- connections that would outlive the window are tracked so X can kill them;
-- UI-instance connections die with gui:Destroy() and don't need tracking
local trackedConns = {}
local function trackConn(conn)
    trackedConns[#trackedConns + 1] = conn
    return conn
end

-- ============================================================
--  STATE  (loops mutate this; the UI reads from it)
-- ============================================================
local state = {
    running        = false,             -- the whole hunt loop
    seedName       = SEED_NAME,
    targetHeight   = TARGET_HEIGHT,
    seedsPerBatch  = SEEDS_PER_BATCH,
    stopOnFound    = STOP_ON_FOUND,
    sprinklerName  = SPRINKLER_NAME,
    sprinklerLife  = SPRINKLER_LIFE,
    placeSprinkler = PLACE_SPRINKLER,
    sprinklerAt    = 0,                 -- os.clock() deadline for the next sprinkler
    radius         = PLANT_RADIUS,
    plantDelay     = PLANT_DELAY,
    onlyPlantArea  = ONLY_PLANT_AREA,
    centerOnSelf   = CENTER_ON_SELF,
    shovelDelay    = SHOVEL_DELAY,
    collectBatch   = COLLECT_BATCH,
    collectDelay   = COLLECT_DELAY,
    scanDelay      = SCAN_DELAY,
    autoSell       = AUTO_SELL,
    sellInterval   = SELL_INTERVAL,
    nextSellAt     = 0,                 -- os.clock() deadline for the next SellAll
    sells          = 0,
    anchored       = false,             -- freeze the character in place
    hideOtherPlots = true,              -- destroy other players' plots client-side (de-lag)
    saveConfig     = false,             -- persist settings across re-executions
    webhookUrl     = WEBHOOK_URL,
    pingUserId     = "",                -- Discord user id pinged on keeper ("" = @everyone)
    bestHeight     = 0,                 -- tallest rounded height judged this session
    keepers        = 0,
    removed        = 0,
    cycles         = 0,
    totalPlanted   = 0,                 -- REAL seeds planted (counted from the stack Count dropping)
    batchDone      = 0,
    batchTotal     = 0,
    sprinklersPlaced = 0,
    phase          = "idle",            -- idle | sprinkler | planting | waiting | removing
    runStartedAt   = 0,
    statusMsg      = "idle - press START HUNT (centers on your plot)",
    statusKind     = "idle",            -- idle | run | good | bad
}

local function setStatus(kind, msg)
    state.statusKind = kind
    state.statusMsg  = msg
    dlog("STATUS", msg)
end

-- ============================================================
--  STARTUP KEY RITUAL  (hammer G until the game officially loads)
-- ============================================================
-- Runs SYNCHRONOUSLY before everything else. GAG sits on its intro screen
-- until a key is pressed; the LoadingScreenDone attribute flips true once it
-- is gone. Already-loaded sessions fall straight through.
do
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    local function loadingDone()
        return LocalPlayer:GetAttribute("LoadingScreenDone") == true
    end

    -- VirtualInputManager first; executor keypress/keyrelease as fallback
    local function pressKey(keyCode)
        local okVim = pcall(function()
            local vim = game:GetService("VirtualInputManager")
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.05)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
        if okVim then return true end
        if typeof(keypress) == "function" and typeof(keyrelease) == "function"
            and #keyCode.Name == 1 then
            return (pcall(function()
                local vk = string.byte(keyCode.Name)
                keypress(vk)
                task.wait(0.05)
                keyrelease(vk)
            end))
        end
        return false
    end

    if alive() and not loadingDone() then
        dlog("STARTUP", ("pressing %s every %ss until the game loads (max %ds)"):format(
            STARTUP_KEY.Name, tostring(STARTUP_INTERVAL), STARTUP_TIMEOUT))
        local presses  = 0
        local deadline = os.clock() + STARTUP_TIMEOUT
        while alive() and not loadingDone() and os.clock() < deadline do
            if not pressKey(STARTUP_KEY) then
                dlog("STARTUP", "key press failed - continuing anyway")
                break
            end
            presses += 1
            task.wait(STARTUP_INTERVAL)
        end
        dlog("STARTUP", loadingDone()
            and ("game fully loaded after %d press(es)"):format(presses)
            or  "LoadingScreenDone not seen in time - continuing anyway")
    end
end

-- ============================================================
--  SAVE CONFIG  (settings persisted to JSON, reloaded on execution)
-- ============================================================
-- running is deliberately never saved: the hunt is always OFF on a fresh
-- execution. The webhook URL + ping id always save (people kept "losing"
-- them behind the toggle in CarrotGuild).
local CONFIG_FILE = "TallestGuild_Config.json"
local CONFIG_KEYS = {
    "seedName", "targetHeight", "seedsPerBatch", "stopOnFound",
    "sprinklerName", "sprinklerLife", "placeSprinkler", "radius", "plantDelay",
    "onlyPlantArea", "centerOnSelf", "shovelDelay", "collectBatch",
    "collectDelay", "scanDelay", "autoSell", "sellInterval",
    "anchored", "hideOtherPlots",
}

local function persistConfig()
    if typeof(writefile) ~= "function" then return end
    local data = {
        saveConfig = state.saveConfig,
        webhookUrl = state.webhookUrl,
        pingUserId = state.pingUserId,
    }
    if state.saveConfig then
        for _, key in ipairs(CONFIG_KEYS) do
            data[key] = state[key]
        end
    end
    local ok, err = pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(data))
    end)
    if not ok then dlog("CONFIG", "save failed: " .. tostring(err)) end
end

do
    if typeof(isfile) == "function" and typeof(readfile) == "function" then
        local ok, data = pcall(function()
            if isfile(CONFIG_FILE) then
                return HttpService:JSONDecode(readfile(CONFIG_FILE))
            end
            return nil
        end)
        if ok and type(data) == "table" then
            if type(data.webhookUrl) == "string" and data.webhookUrl:match("%S") then
                state.webhookUrl = data.webhookUrl
            end
            if type(data.pingUserId) == "string" then
                state.pingUserId = data.pingUserId:gsub("%D", "")
            end
            if data.saveConfig == true then
                state.saveConfig = true
                for _, key in ipairs(CONFIG_KEYS) do
                    if data[key] ~= nil and type(data[key]) == type(state[key]) then
                        state[key] = data[key]
                    end
                end
                dlog("CONFIG", "loaded saved settings from " .. CONFIG_FILE)
            end
        end
    end
end

-- ============================================================
--  NETWORKING
-- ============================================================
local Networking
do
    local ok, err = pcall(function()
        Networking = require(ReplicatedStorage
            :WaitForChild("SharedModules"):WaitForChild("Networking"))
    end)
    if not ok then
        dlog("ERROR", "failed to require Networking: " .. tostring(err))
    end
end

-- ============================================================
--  PLOT / PLANTS FOLDER  (lazy + nil-tolerant, never WaitForChild)
-- ============================================================
-- PlotId can be nil right after join/teleport; every reader polls the live
-- attribute. NEVER block on MyPlot:WaitForChild("Plants") - it infinite-yields
-- on data-only builds (the Harvest 2.3 boot stall).
local function getPlotId()
    return LocalPlayer:GetAttribute("PlotId")
end

local cachedPlantsFolder
local function getPlantsFolder()
    if cachedPlantsFolder and cachedPlantsFolder.Parent then return cachedPlantsFolder end
    cachedPlantsFolder = nil
    local plotId  = getPlotId()
    local gardens = workspace:FindFirstChild("Gardens")
    local plot    = gardens and plotId and gardens:FindFirstChild("Plot" .. tostring(plotId))
    local folder  = plot and plot:FindFirstChild("Plants")
    if not folder then
        -- ShovelController fallback; only trusted when the folder is actually
        -- parented (it has returned an orphaned empty "Plants" before)
        pcall(function()
            local ps = LocalPlayer:FindFirstChild("PlayerScripts")
            local controllers = ps and ps:FindFirstChild("Controllers")
            local module = controllers and controllers:FindFirstChild("ShovelController")
            if module then
                local shovel = require(module)
                local got = shovel.GetPlayerPlantsFolder()
                if typeof(got) ~= "Instance" then got = shovel:GetPlayerPlantsFolder() end
                if typeof(got) == "Instance" and got.Parent then folder = got end
            end
        end)
    end
    cachedPlantsFolder = folder
    return folder
end

-- ============================================================
--  DELETE OTHER PLOTS  (client-side de-lag)
-- ============================================================
-- Destroy every Gardens child matching ^Plot%d+$ except our own, spaced one
-- per frame. Re-replicated plots are re-killed the MOMENT they reappear via
-- ChildAdded + task.defer (still nearly empty then, so the destroy is O(1)).
-- NEVER on a timer: streaming re-sends deleted plots and a periodic sweep
-- destroys thousands of instances per frame, over and over (the Harvest 2.1
-- spike-loop bug). Skipped entirely while PlotId is nil so our own plot can
-- never be caught.
local function isForeignPlot(inst)
    local plotId = getPlotId()
    if plotId == nil then return false end
    return inst.Name:match("^Plot%d+$") ~= nil and inst.Name ~= ("Plot" .. tostring(plotId))
end

local function sweepOtherPlots()
    if not state.hideOtherPlots then return end
    local gardens = workspace:FindFirstChild("Gardens")
    if not gardens then return end
    for _, plot in ipairs(gardens:GetChildren()) do
        if not alive() then return end
        if isForeignPlot(plot) then
            pcall(function() plot:Destroy() end)
            task.wait()   -- one destroy per frame
        end
    end
end

task.spawn(function()
    local gardens = workspace:FindFirstChild("Gardens")
    local deadline = os.clock() + 30
    while alive() and not gardens and os.clock() < deadline do
        task.wait(0.5)
        gardens = workspace:FindFirstChild("Gardens")
    end
    if not (alive() and gardens) then return end
    trackConn(gardens.ChildAdded:Connect(function(child)
        task.defer(function()
            if alive() and state.hideOtherPlots and child.Parent and isForeignPlot(child) then
                pcall(function() child:Destroy() end)
            end
        end)
    end))
    -- wait for the plot assignment before the first sweep
    while alive() and getPlotId() == nil do task.wait(0.5) end
    if alive() then sweepOtherPlots() end
end)

-- ============================================================
--  NOCLIP  (always on; a fully grown plot would trap you otherwise)
-- ============================================================
local function isCollisionPart(part)
    return part:IsA("BasePart")
        and part.Name ~= "HumanoidRootPart"
        and not (part.Parent and part.Parent:IsA("Accessory"))
end

local noclipConn
noclipConn = trackConn(RunService.Stepped:Connect(function()
    if not alive() then
        noclipConn:Disconnect()
        return
    end
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if isCollisionPart(part) and part.CanCollide then
            part.CanCollide = false
        end
    end
end))

-- ============================================================
--  ANTI-AFK  (two layers: the engine idle kick + the game's AFK hop)
-- ============================================================
do
    trackConn(LocalPlayer.Idled:Connect(function()
        if not alive() then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        dlog("ANTIAFK", "engine idle kick blocked")
    end))
    -- the game's AntiAfkController server-hops idle players; it reads this
    -- attribute as its idle threshold. Re-applied every 30s in case it clears.
    task.spawn(function()
        while alive() do
            pcall(function()
                LocalPlayer:SetAttribute("AntiAfkIdleOverride", 1e9)
            end)
            task.wait(30)
        end
    end)
end

-- ============================================================
--  FREEZE CHARACTER  (anchors the root in place; toggled from the UI)
-- ============================================================
local function applyAnchor()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then root.Anchored = state.anchored end
end

trackConn(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.3)
    if alive() then applyAnchor() end
end))
if state.anchored then applyAnchor() end

-- ============================================================
--  TOOL HELPERS  (hold the item before firing its remote)
-- ============================================================
-- Seeds/sprinklers carry their real name in attributes (SeedTool /
-- Sprinkler); tool Names can have stack suffixes, so prefix-match those.
local function findToolNamed(container, name)
    if not container then return nil end
    local prefixHit
    for _, tool in ipairs(container:GetChildren()) do
        if tool:IsA("Tool") then
            if tool.Name == name
                or tool:GetAttribute("SeedTool") == name
                or tool:GetAttribute("Sprinkler") == name then
                return tool
            end
            if tool.Name:sub(1, #name) == name then
                prefixHit = prefixHit or tool
            end
        end
    end
    return prefixHit
end

-- return the tool equipped in the character, equipping it from the backpack
-- if needed and WAITING until it actually lands (a fixed wait races the
-- game's own unequip)
local function ensureTool(name)
    local char = LocalPlayer.Character
    if not char then return nil end
    local held = findToolNamed(char, name)
    if held then return held end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not (backpack and humanoid) then return nil end

    local tool = findToolNamed(backpack, name)
    if not tool then return nil end

    humanoid:EquipTool(tool)
    local deadline = os.clock() + 1
    while os.clock() < deadline and tool.Parent ~= char do task.wait(0.05) end
    if tool.Parent == char then return tool end
    return nil
end

-- stack totals from the Count attribute, Character + Backpack
local function countStock(name)
    local total = 0
    local function scan(container)
        if not container then return end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and (tool.Name == name
                or tool:GetAttribute("SeedTool") == name
                or tool:GetAttribute("Sprinkler") == name
                or tool.Name:sub(1, #name) == name) then
                local count = tool:GetAttribute("Count")
                total += (type(count) == "number" and count or 1)
            end
        end
    end
    scan(LocalPlayer.Character)
    scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    return total
end

local function seedsRemaining()      return countStock(state.seedName)      end
local function sprinklerStock()      return countStock(state.sprinklerName) end

-- PLANTED counter: the seed stack's Count attribute is the truth. PlantSeed
-- fires at occupied spots are silently ignored and consume NOTHING, so
-- counting fires overstates - only a stock DROP is a real plant. Restocks
-- (buying seeds) only move the baseline up and never count.
task.spawn(function()
    local baselineSeed, lastCount
    while alive() do
        if state.running then
            if baselineSeed ~= state.seedName then
                -- seed swapped mid-run: a fresh baseline, never a false drop
                baselineSeed = state.seedName
                lastCount = nil
            end
            local now = seedsRemaining()
            if lastCount ~= nil and now < lastCount then
                state.totalPlanted += (lastCount - now)
            end
            lastCount = now
        else
            baselineSeed, lastCount = nil, nil
        end
        task.wait(0.25)
    end
end)

-- AUTO SELL: NPCS.SellAll on its own timer, independent of the hunt - the
-- toggle alone decides. Fired in pcall; a failed fire still reschedules so
-- one bad fire can never kill the loop.
task.spawn(function()
    while alive() do
        if state.autoSell and Networking and os.clock() >= state.nextSellAt then
            local ok = pcall(function()
                Networking.NPCS.SellAll:Fire()
            end)
            if ok then
                state.sells += 1
                dlog("SELL", ("SellAll fired (%d total)"):format(state.sells))
            else
                dlog("SELL", "SellAll fire failed - retrying next interval")
            end
            state.nextSellAt = os.clock() + math.max(state.sellInterval, 1)
        end
        task.wait(0.25)
    end
end)

-- ============================================================
--  POSITION HELPERS
-- ============================================================
local function getRootPosition()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then return root.Position end
    return nil
end

local function instanceCenter(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Model") then return inst:GetPivot().Position end
    return nil
end

-- the farm center comes straight from the plot's own geometry: the middle of
-- Visual.PlantAreaColumn2 (the plantable strip), falling back to Visual.PRIM
-- (the middle of the whole plot), then to where you stand
local function getFarmCenter()
    local plotId  = getPlotId()
    local gardens = workspace:FindFirstChild("Gardens")
    local plot    = gardens and plotId and gardens:FindFirstChild("Plot" .. tostring(plotId))
    local visual  = plot and plot:FindFirstChild("Visual")
    if visual then
        local center = instanceCenter(visual:FindFirstChild("PlantAreaColumn2"))
            or instanceCenter(visual:FindFirstChild("PRIM"))
        if center then return center end
    end
    dlog("FARM", "PlantAreaColumn2/PRIM not found - centering on the character")
    return getRootPosition()
end

-- raycast straight down onto a PlantArea tile; nil = spot is off the plot
local function plantAreaGround(x, z, nearY)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = CollectionService:GetTagged("PlantArea")
    local hit = workspace:Raycast(Vector3.new(x, nearY + 10, z), Vector3.new(0, -50, 0), params)
    if hit then return hit.Position end
    return nil
end

-- ============================================================
--  SPOT GENERATION  (shuffled 1-stud grid inside the radius)
-- ============================================================
local function generateSpotOffsets(radius)
    local offsets = {}
    local limit = math.floor(radius)
    for dx = -limit, limit do
        for dz = -limit, limit do
            -- (0,0) skipped so nothing is planted on top of the sprinkler
            if not (dx == 0 and dz == 0) and (dx * dx + dz * dz) <= radius * radius then
                offsets[#offsets + 1] = { x = dx, z = dz }
            end
        end
    end
    for i = #offsets, 2, -1 do
        local j = math.random(i)
        offsets[i], offsets[j] = offsets[j], offsets[i]
    end
    return offsets
end

-- ============================================================
--  SPRINKLER  (always down before planting; verified by stock drop)
-- ============================================================
-- A placement can be silently rejected, and the tool can stay in your hand
-- after a SUCCESSFUL one - so success is only ever confirmed by the sprinkler
-- STOCK going down against one baseline for the whole call (the CarrotGuild
-- double-place guard: a late-landing confirm must never trigger a second
-- placement).
local function placeSprinklerHere(center)
    if not Networking then return false end
    local plotId = getPlotId()
    if plotId == nil then
        dlog("SPRINKLER", "PlotId still nil - cannot place yet")
        return false
    end

    local baseline
    -- dead center first, then nearby spots in case the exact one is blocked
    local offsets = { {0, 0}, {2, 0}, {-2, 0}, {0, 2}, {0, -2} }
    for attempt, off in ipairs(offsets) do
        if not (alive() and state.running) then return false end
        local tool = ensureTool(state.sprinklerName)
        if not tool then
            dlog("SPRINKLER", "no tool named '" .. state.sprinklerName .. "' found")
            return false
        end
        task.wait(0.5)   -- hold the sprinkler so the server registers it

        if baseline == nil then
            baseline = sprinklerStock()
        elseif sprinklerStock() < baseline then
            state.sprinklersPlaced += 1
            dlog("SPRINKLER", ("attempt %d skipped - the previous fire landed"):format(attempt))
            return true
        end

        local pos = Vector3.new(
            math.round(center.X) + off[1],
            math.round(center.Y),
            math.round(center.Z) + off[2]
        )
        dlog("SPRINKLER", ("attempt %d: PlaceSprinkler(%s, %q, plot %s)"):format(
            attempt, tostring(pos), state.sprinklerName, tostring(plotId)))
        pcall(function()
            Networking.Place.PlaceSprinkler:Fire(pos, state.sprinklerName, tool, plotId)
        end)

        -- keep holding while watching for the stock to drop; swapping tools
        -- early makes the server see an empty hand and reject the placement
        local deadline = os.clock() + 3
        while os.clock() < deadline do
            if sprinklerStock() < baseline then
                state.sprinklersPlaced += 1
                return true
            end
            task.wait(0.1)
        end
        dlog("SPRINKLER", ("attempt %d unconfirmed (stock unchanged), trying next spot"):format(attempt))
    end
    return false
end

-- the user rule: there is ALWAYS a live sprinkler before planting. Checked
-- between every seed too, since a batch easily outlasts one sprinkler life.
local function maintainSprinkler(center)
    if not (state.placeSprinkler and state.running) then return end
    if os.clock() < state.sprinklerAt then return end

    setStatus("run", "placing sprinkler...")
    if placeSprinklerHere(center) then
        state.sprinklerAt = os.clock() + state.sprinklerLife
    else
        -- out of stock or PlotId not ready; keep planting, retry shortly
        state.sprinklerAt = os.clock() + 10
        setStatus("bad", "sprinkler place failed (out of '" .. state.sprinklerName .. "'?) - retrying in 10s")
    end
    ensureTool(state.seedName)   -- swap straight back to the seed
end

-- ============================================================
--  PLANTING
-- ============================================================
local function plantSeedAt(pos, tool)
    if not Networking then return false end
    return (pcall(function()
        Networking.Plant.PlantSeed:Fire(pos, state.seedName, tool)
    end))
end

-- ============================================================
--  DISCORD WEBHOOK  (fired once per keeper)
-- ============================================================
local function resolveRequestFn()
    if typeof(http_request) == "function" then return http_request end
    if typeof(request) == "function" then return request end
    if type(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
    if type(fluxus) == "table" and typeof(fluxus.request) == "function" then return fluxus.request end
    return nil
end

local function sendKeeperWebhook(height)
    local url = state.webhookUrl
    if type(url) ~= "string" or not url:match("^https://") then return end

    local requestFn = resolveRequestFn()
    if not requestFn then
        dlog("WEBHOOK", "no http_request/request function on this executor")
        return
    end

    local content = state.pingUserId ~= ""
        and ("<@%s>"):format(state.pingUserId)
        or "@everyone"

    local payload = {
        username   = WEBHOOK_NAME,
        avatar_url = WEBHOOK_AVATAR,
        content    = content,

        embeds = {{
            title = "🎄 DESIRED HEIGHT REACHED!",

            description = (
                "## 🏆 %d %s\n\n" ..
                "Target %d hit — the plant is **PROTECTED**, " ..
                "it will not be shoveled or collected."
            ):format(
                height,
                state.seedName,
                state.targetHeight
            ),

            color = 0x7CDE8A,

            thumbnail = {
                url = WEBHOOK_AVATAR
            },

            fields = {
                {
                    name = "👤 Player",
                    value = ("`%s`"):format(LocalPlayer.Name),
                    inline = true
                },
                {
                    name = "🌱 Plant",
                    value = ("`%s`"):format(state.seedName),
                    inline = true
                },
                {
                    name = "🎯 Target",
                    value = ("`%d`"):format(state.targetHeight),
                    inline = true
                }
            },

            footer = {
                text = "Tallest Guild " .. SCRIPT_VERSION .. " • discord.gg/pubert"
            },

            timestamp = DateTime.now():ToIsoDate()
        }}
    }

    task.spawn(function()
        local ok, err = pcall(function()
            requestFn({
                Url     = url,
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode(payload),
            })
        end)

        if ok then
            dlog("WEBHOOK", "keeper ping sent")
        else
            dlog("WEBHOOK", "send failed: " .. tostring(err))
        end
    end)
end
-- ============================================================
--  PROMPTS  (stretch + fire, from CarrotGuild)
-- ============================================================
-- AlwaysShow is the important part: prompts compete for the visible slot and
-- an input-simulating fireproximityprompt only lands on a prompt the service
-- considers shown (the "must look at the plant" bug).
local function stretchPrompt(prompt)
    pcall(function()
        prompt.Enabled               = true
        prompt.HoldDuration          = 0
        prompt.MaxActivationDistance = PROMPT_RANGE
        prompt.RequiresLineOfSight   = false
        prompt.Exclusivity           = Enum.ProximityPromptExclusivity.AlwaysShow
    end)
    pcall(function() prompt.MaxIndicatorDistance = PROMPT_RANGE end)
    pcall(function() prompt:SetAttribute("MaxIndicatorDistance", PROMPT_RANGE) end)
end

-- InputHoldBegin/End is the engine's own client hold path: with HoldDuration
-- 0 it triggers instantly, camera and line of sight irrelevant, and it exists
-- on every executor. fireproximityprompt fires too; whichever lands claims.
local function firePrompt(prompt)
    pcall(function()
        prompt.HoldDuration = 0
        prompt:InputHoldBegin()
        prompt:InputHoldEnd()
    end)
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
    end
end

local promptCache = setmetatable({}, { __mode = "k" })
local function getHarvestPrompt(plant)
    local prompt = promptCache[plant]
    if prompt == nil or prompt.Parent == nil then
        local harvestPart = plant:FindFirstChild("HarvestPart")
        prompt = harvestPart and harvestPart:FindFirstChild("HarvestPrompt")
        if not prompt then return nil end
        promptCache[plant] = prompt
    end
    return prompt
end

-- ============================================================
--  JUDGE  (verdict per plant, decided once)
-- ============================================================
-- The height is a number attribute in ONE of two places, varying by plant:
-- "Height" on the plant MODEL itself (newer plants, checked first) or
-- "MaxHeight" on its CollisionBlock child. The game DISPLAYS the value
-- rounded UP (353.2 shows as 354; math.round undershot by 1), so the
-- verdict uses math.ceil to always match what the game says. Verdicts:
--   "keep"    round(MaxHeight) >= target - prompt destroyed, never removed
--   "remove"  under the target - removed by the chosen mode
--   "skip"    a DIFFERENT crop (SeedName mismatch) - never touched at all
-- A plant whose SeedName/CollisionBlock has not replicated yet stays
-- UNJUDGED and is retried next sweep - marking it early risks the wrong
-- verdict on a would-be keeper. Weak keys let claimed plants fall out.
local plantVerdict    = setmetatable({}, { __mode = "k" })
local keeperSeen      = setmetatable({}, { __mode = "k" })   -- one count/ping per plant ever
local heightCache     = setmetatable({}, { __mode = "k" })
local removeList      = {}
local protectedPlants = {}

local function getPlantHeight(plant)
    -- newer plants carry Height right on the model; only fall back to the
    -- CollisionBlock's MaxHeight when it is missing
    local direct = plant:GetAttribute("Height")
    if type(direct) == "number" then return direct end
    local block = heightCache[plant]
    if block == nil or block.Parent == nil then
        block = plant:FindFirstChild("CollisionBlock")
            or plant:FindFirstChild("CollisionBlock", true)
        if not block then return nil end
        heightCache[plant] = block
    end
    local height = block:GetAttribute("MaxHeight")
    if type(height) ~= "number" then return nil end
    return height
end

-- changing the seed or the target makes every verdict stale
local function resetVerdicts()
    plantVerdict    = setmetatable({}, { __mode = "k" })
    heightCache     = setmetatable({}, { __mode = "k" })
    removeList      = {}
    protectedPlants = {}
end

-- keeper: prompt destroyed BEFORE anything can fire it, counted/pinged once
local function protectPlant(plant, rounded)
    plantVerdict[plant] = "keep"
    local prompt = getHarvestPrompt(plant)
    if prompt then pcall(function() prompt:Destroy() end) end
    protectedPlants[#protectedPlants + 1] = plant
    if keeperSeen[plant] then return end
    keeperSeen[plant] = true
    state.keepers += 1
    dlog("KEEPER", ("%s height %d (target %d) - PROTECTED"):format(
        state.seedName, rounded, state.targetHeight))
    setStatus("good", ("KEEPER: %s height %d"):format(state.seedName, rounded))
    sendKeeperWebhook(rounded)
    if state.stopOnFound and state.running then
        state.running = false
        setStatus("good", ("desired height %d found - hunt stopped"):format(rounded))
    end
end

-- does this model belong to OUR crop? SeedName attribute is the truth (like
-- CarrotGuild); if it has not replicated yet, fall back to the model name,
-- else stay undecided (nil) and re-check next sweep
local function matchesOurSeed(plant)
    local seedAttr = plant:GetAttribute("SeedName")
    if seedAttr ~= nil then
        -- case-insensitive: "corn" typed in the box must still match "Corn"
        return string.lower(tostring(seedAttr)) == string.lower(state.seedName)
    end
    local name = string.lower(plant.Name)
    local want = string.lower(state.seedName)
    if name == want or name:sub(1, #want) == want then
        return true
    end
    return nil   -- unknown yet
end

-- the judge sweep: runs whenever the hunt is on, so plants that appear late
-- (or attributes that replicate late) are judged the moment they are ready
task.spawn(function()
    while alive() do
        if state.running then
            local plantsFolder = getPlantsFolder()
            if plantsFolder then
                for _, plant in ipairs(plantsFolder:GetChildren()) do
                    if plantVerdict[plant] == nil then
                        local ours = matchesOurSeed(plant)
                        if ours == false then
                            plantVerdict[plant] = "skip"
                        elseif ours == true then
                            local height = getPlantHeight(plant)
                            if height ~= nil then   -- attribute not up yet = next sweep
                                local rounded = math.ceil(height)
                                if rounded > state.bestHeight then
                                    state.bestHeight = rounded
                                end
                                if rounded >= state.targetHeight then
                                    protectPlant(plant, rounded)
                                else
                                    plantVerdict[plant] = "remove"
                                    removeList[#removeList + 1] = plant
                                    dlog("JUDGE", ("height %d < target %d -> remove"):format(
                                        rounded, state.targetHeight))
                                end
                            end
                        end
                    end
                end

                -- keepers stay prompt-free even if the game re-adds a prompt
                local kept = 0
                for i = 1, #protectedPlants do
                    local plant = protectedPlants[i]
                    if plant.Parent ~= nil then
                        kept += 1
                        protectedPlants[kept] = plant
                        local prompt = getHarvestPrompt(plant)
                        if prompt then pcall(function() prompt:Destroy() end) end
                    end
                end
                for i = #protectedPlants, kept + 1, -1 do protectedPlants[i] = nil end
            end
        end
        task.wait(math.max(state.scanDelay, 0.05))
    end
end)

-- ============================================================
--  REMOVAL  (shovel or collect every "remove" plant, keepers excluded)
-- ============================================================
-- vanished plants leave the list here; each one is a confirmed removal
local function compactRemoveList()
    local live = 0
    for i = 1, #removeList do
        local plant = removeList[i]
        if plant.Parent ~= nil then
            -- verdict re-check: a reset mid-phase must not leave stale targets
            if plantVerdict[plant] == "remove" then
                live += 1
                removeList[live] = plant
            end
        else
            state.removed += 1
        end
    end
    for i = #removeList, live + 1, -1 do removeList[i] = nil end
end

-- how a plant leaves the plot, decided LIVE by the MODEL, not by a setting
-- (user rules 2026-07-18): a present PlantType attribute ("Plant") means no
-- working harvest prompt - the shovel is the ONLY remover (it also removes
-- anything, so unknown future PlantType values route there too). A crop
-- (no PlantType) is only COLLECTED when it is ready RIGHT NOW (Age ==
-- MaxAge); a still-growing crop ignores prompt fires until it ripens, so
-- it is shoveled instead of waited on. The route is recomputed at EVERY
-- fire and count, never cached: Age moves and the judge keeps feeding in
-- new plants, so a growing crop that ripens before the shovel reaches it
-- flips to collect on its own.
local function removalRoute(plant)
    if plant:GetAttribute("PlantType") ~= nil then return "shovel" end
    local age    = plant:GetAttribute("Age")
    local maxAge = plant:GetAttribute("MaxAge")
    if type(age) == "number" and type(maxAge) == "number" and age >= maxAge then
        return "collect"   -- ready to harvest right now
    end
    return "shovel"        -- still growing (or age unknown): shovel it
end

-- shovel PRIORITY (user rule 2026-07-18): spend the shovel's time on plants
-- that will never turn into a claim - PlantType models (never collectable)
-- and the crops FURTHEST from ripe (biggest MaxAge - Age gap) go first.
-- Nearly-ripe crops sink to the end of the pass, so by the time the shovel
-- would reach them many have ripened and been claimed by the collect engine
-- instead - the route re-check at fire time skips those for free. Unknown
-- ages also sort first: no evidence they will ever ripen.
local function shovelPriority(plant)
    if plant:GetAttribute("PlantType") ~= nil then return math.huge end
    local age    = plant:GetAttribute("Age")
    local maxAge = plant:GetAttribute("MaxAge")
    if type(age) == "number" and type(maxAge) == "number" then
        return maxAge - age
    end
    return math.huge
end

-- one UseShovel per target, shovel HELD (the fire does nothing otherwise);
-- false = no shovel tool anywhere, the phase waits and retries
local function shovelPass()
    local tool = ensureTool("Shovel")
    if not tool then
        setStatus("bad", "no Shovel in Character or Backpack - waiting")
        return false
    end
    task.wait(0.2)
    local targets = {}
    for i = 1, #removeList do
        local plant = removeList[i]
        if plant.Parent ~= nil and plantVerdict[plant] == "remove"
            and removalRoute(plant) == "shovel" then
            targets[#targets + 1] = plant
        end
    end
    -- priorities snapshotted once, then biggest gap first
    local priority = {}
    for _, plant in ipairs(targets) do
        priority[plant] = shovelPriority(plant)
    end
    table.sort(targets, function(a, b)
        return priority[a] > priority[b]
    end)
    for _, plant in ipairs(targets) do
        if not (alive() and state.running) then break end
        -- route re-checked at fire time: a crop that ripened while this
        -- pass ran has flipped to collect and must NOT be shoveled now
        if plant.Parent ~= nil and plantVerdict[plant] == "remove"
            and removalRoute(plant) == "shovel" then
            -- Tallest-build models are named "UserId_PlantId" and also carry
            -- a PlantId attribute; which one UseShovel wants is unverified,
            -- so BOTH are fired - an id the server does not accept is
            -- silently ignored, so the extra fire costs nothing
            local ok, err = pcall(function()
                Networking.Shovel.UseShovel:Fire(plant.Name, "", "Shovel", tool)
            end)
            if not ok then
                dlog("ERROR", ("UseShovel failed on %s: %s"):format(plant.Name, tostring(err)))
            end
            local plantId = plant:GetAttribute("PlantId")
            if type(plantId) == "string" and plantId ~= plant.Name then
                pcall(function()
                    Networking.Shovel.UseShovel:Fire(plantId, "", "Shovel", tool)
                end)
            end
            task.wait(state.shovelDelay)
        end
    end
    return true
end

-- prompt blast in parallel batches (some executors yield inside
-- fireproximityprompt, which makes sequential fires crawl). Unready plants
-- are silently ignored by the server and just get re-fired next pass.
local function collectPass()
    local batchSize = math.max(1, math.floor(state.collectBatch))
    local targets = {}
    for i = 1, #removeList do
        local plant = removeList[i]
        if plant.Parent ~= nil and plantVerdict[plant] == "remove"
            and removalRoute(plant) == "collect" then
            targets[#targets + 1] = plant
        end
    end
    for i = 1, #targets, batchSize do
        if not (alive() and state.running) then break end
        for j = i, math.min(i + batchSize - 1, #targets) do
            local plant = targets[j]
            task.spawn(function()
                local prompt = getHarvestPrompt(plant)
                if prompt then
                    stretchPrompt(prompt)
                    firePrompt(prompt)
                end
            end)
        end
        task.wait(state.collectDelay)
    end
end

-- PERSISTENT COLLECT ENGINE: whenever the hunt is on, it iterates the
-- planted crop non-stop and blasts every collect-route target - a plant
-- that finishes growing is claimed WHILE the batch is still being planted,
-- not after it. Shovel-route plants are never fired from here. The shovel
-- cannot join this engine: UseShovel needs the shovel HELD and planting
-- needs the seed held, so they would fight over the hand - shoveling stays
-- in the removal phase after each batch.
task.spawn(function()
    while alive() do
        if state.running then
            compactRemoveList()
            if #removeList > 0 then
                collectPass()
            end
        end
        task.wait(0.05)
    end
end)

-- runs until every "remove" plant of OUR seed is gone. No hard timeout: the
-- plot must be clear before the next batch has room anyway. The collect
-- engine above keeps blasting through this whole phase; in Shovel and
-- Shovel + Collect the shovel clears whatever collecting cannot claim yet.
-- Firing both at one plant is harmless, the server takes whichever lands.
local function removalPhase()
    state.phase = "removing"
    compactRemoveList()
    if #removeList == 0 then
        dlog("REMOVE", "nothing to remove this cycle")
        return
    end
    local stalledLogged = false
    while alive() and state.running do
        compactRemoveList()
        if #removeList == 0 then break end
        local shovelCount = 0
        for i = 1, #removeList do
            if removalRoute(removeList[i]) == "shovel" then
                shovelCount += 1
            end
        end
        setStatus("run", ("removing %d %s plant(s) - %d shovel / %d collect"):format(
            #removeList, state.seedName, shovelCount, #removeList - shovelCount))
        local before = #removeList
        if shovelCount > 0 then
            if not shovelPass() then task.wait(2) end
        end
        task.wait(0.3)   -- let the server catch up before recounting
        compactRemoveList()
        if #removeList >= before and #removeList > 0 then
            if not stalledLogged then
                stalledLogged = true
                dlog("REMOVE", "pass removed nothing - targets may still be growing (Collect) or lagging; retrying")
            end
            task.wait(1)
        else
            stalledLogged = false
        end
    end
    if #removeList == 0 then
        setStatus("run", "plot cleared of non-keepers")
    end
end

-- ============================================================
--  HUNT CYCLE  (sprinkler -> batch -> judge -> remove -> repeat)
-- ============================================================
local function cycleLoop()
    -- wait for the character so the first equip cannot fail silently
    do
        local deadline = os.clock() + 15
        while alive() and state.running and os.clock() < deadline do
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("HumanoidRootPart") then break end
            task.wait(0.5)
        end
    end

    while alive() and state.running do
        local plotCenter = getFarmCenter()
        if not plotCenter then
            setStatus("bad", "no plot geometry and no character - retrying in 3s")
            task.wait(3)
        else
            -- "Plant where I stand" follows the character LIVE, seed by seed;
            -- otherwise the plot center is fixed for the whole cycle
            local function currentCenter()
                if state.centerOnSelf then
                    return getRootPosition() or plotCenter
                end
                return plotCenter
            end
            -- PHASE: plant one batch (the sprinkler check runs between every
            -- seed, so an expiring sprinkler is replaced mid-batch too)
            state.phase      = "planting"
            state.batchTotal = state.seedsPerBatch
            state.batchDone  = 0
            setStatus("run", ("cycle %d: planting %d x %s"):format(
                state.cycles + 1, state.seedsPerBatch, state.seedName))

            local spots = generateSpotOffsets(state.radius)
            local spotIndex = 0
            local validInPass = 0
            while alive() and state.running and state.batchDone < state.seedsPerBatch do
                maintainSprinkler(currentCenter())
                if not (alive() and state.running) then break end

                local tool = ensureTool(state.seedName)
                if not tool then
                    -- out of seeds: if something is already judged for
                    -- removal, END the batch early and go clear it instead
                    -- of stalling here forever with a full plot
                    compactRemoveList()
                    if #removeList > 0 then
                        dlog("PLANT", "out of seeds - ending the batch early to remove what is down")
                        break
                    end
                    setStatus("bad", "no '" .. state.seedName .. "' seeds - waiting")
                    task.wait(2)
                else
                    spotIndex += 1
                    if spotIndex > #spots then
                        if validInPass == 0 then
                            setStatus("bad", "no plantable spot in radius - check radius / Only on PlantArea")
                            task.wait(3)
                        end
                        spots = generateSpotOffsets(state.radius)
                        spotIndex = 1
                        validInPass = 0
                    end
                    local offset = spots[spotIndex]
                    local center = currentCenter()
                    local x, z = center.X + offset.x, center.Z + offset.z
                    local pos
                    if state.onlyPlantArea then
                        pos = plantAreaGround(x, z, center.Y)   -- nil = off the plot
                    else
                        pos = Vector3.new(x, center.Y - 0.4, z)
                    end
                    if pos then
                        validInPass += 1
                        -- the batch counts fire ATTEMPTS (occupied spots
                        -- no-op); the PLANTED tile is fed by the stock
                        -- watcher, which only counts real seed drops
                        plantSeedAt(pos, tool)
                        state.batchDone += 1
                        task.wait(state.plantDelay)
                    end
                end
            end
            if not (alive() and state.running) then break end

            -- PHASE: judge settle - CollisionBlock/attributes replicate a
            -- moment after the models; the judge sweep needs a beat to see them
            state.phase = "waiting"
            setStatus("run", "batch done - judging heights")
            task.wait(1)
            if not (alive() and state.running) then break end

            -- PHASE: remove every under-target plant of OUR seed. Keepers are
            -- excluded by verdict and other crops were never listed.
            removalPhase()
            if not (alive() and state.running) then break end

            state.cycles += 1
            setStatus("run", ("cycle %d done - starting next"):format(state.cycles))
            task.wait(0.25)
        end
    end

    state.phase = "idle"
    if state.statusKind ~= "good" then
        setStatus("idle", "hunt stopped")
    end
end

local function startRun()
    if state.running then return end
    if not Networking then
        setStatus("bad", "Networking not loaded - cannot run")
        return
    end
    state.running     = true
    state.sprinklerAt = 0   -- 0 = place one immediately, before the first seed
    if state.runStartedAt == 0 then state.runStartedAt = os.clock() end
    task.spawn(cycleLoop)
end

local function stopRun()
    state.running = false
end

-- ============================================================
--  UI THEME + HELPERS  (garden greens, bamboo accent)
-- ============================================================
local COL = {
    bg0     = Color3.fromRGB(18, 14, 30),
    bg1     = Color3.fromRGB(27, 20, 45),
    bg2     = Color3.fromRGB(38, 28, 62),
    hover   = Color3.fromRGB(73, 48, 112),
    headerA = Color3.fromRGB(168, 96, 255),
    headerB = Color3.fromRGB(92, 48, 168),
    accent  = Color3.fromRGB(196, 132, 255),
    stroke  = Color3.fromRGB(92, 68, 138),
    text    = Color3.fromRGB(247, 242, 255),
    label   = Color3.fromRGB(222, 208, 240),
    sub     = Color3.fromRGB(178, 156, 204),
    good    = Color3.fromRGB(126, 232, 166),
    bad     = Color3.fromRGB(255, 132, 150),
    runCol  = Color3.fromRGB(255, 214, 112),
}

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = inst
    return c
end

local function stroke(inst, color, thick)
    local s = Instance.new("UIStroke")
    s.Color           = color or COL.stroke
    s.Thickness       = thick or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent          = inst
    return s
end

local function gradient(inst, c0, c1, rot)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, c0),
        ColorSequenceKeypoint.new(1, c1),
    })
    g.Rotation = rot or 90
    g.Parent   = inst
    return g
end

local function padding(inst, l, r, t, b)
    local p = Instance.new("UIPadding")
    p.PaddingLeft   = UDim.new(0, l or 0)
    p.PaddingRight  = UDim.new(0, r or 0)
    p.PaddingTop    = UDim.new(0, t or 0)
    p.PaddingBottom = UDim.new(0, b or 0)
    p.Parent        = inst
    return p
end

local function tween(inst, t, props)
    TweenService:Create(inst, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = target.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
end

local function getGuiParent()
    if typeof(gethui) == "function" then return gethui() end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return LocalPlayer:WaitForChild("PlayerGui")
end

-- ============================================================
--  UI BUILD
-- ============================================================
local guiParent = getGuiParent()

local old = guiParent:FindFirstChild("TallestGuildUI")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name           = "TallestGuildUI"
gui.ResetOnSpawn   = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent         = guiParent

-- phones can't fit the fixed window; shrink just enough for a 16px margin
local function fitToScreen(panel, designWidth, designHeight)
    local scaler = Instance.new("UIScale")
    scaler.Parent = panel
    local function rescale()
        local view = gui.AbsoluteSize
        if view.X < 100 or view.Y < 100 then return end
        -- UI_SCALE caps the size (the 30%-smaller look); small screens
        -- shrink further so the window always fits with a 16px margin
        local fit = math.min(UI_SCALE, (view.X - 16) / designWidth, (view.Y - 16) / designHeight)
        fit = math.max(fit, 0.35)
        if math.abs(scaler.Scale - fit) > 0.01 then
            scaler.Scale = fit
        end
    end
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
    rescale()
    return scaler
end

local WINDOW_W, WINDOW_H, HEADER_ONLY_H = 620, 560, 54

local main = Instance.new("Frame")
main.Name             = "Main"
main.Size             = UDim2.fromOffset(WINDOW_W, WINDOW_H)
main.Position         = UDim2.new(0.5, -WINDOW_W / 2, 0.5, -WINDOW_H / 2)
main.BackgroundColor3 = COL.bg0
main.BorderSizePixel  = 0
main.Parent           = gui
corner(main, 12)
stroke(main, COL.stroke, 1)

do
    local mainScale = fitToScreen(main, WINDOW_W, WINDOW_H)
    main.Position = UDim2.new(
        0.5, -(WINDOW_W * mainScale.Scale) / 2,
        0.5, -(WINDOW_H * mainScale.Scale) / 2
    )
end

do
    local mainList = Instance.new("UIListLayout")
    mainList.SortOrder = Enum.SortOrder.LayoutOrder
    mainList.Padding   = UDim.new(0, 8)
    mainList.Parent    = main
end
padding(main, 10, 10, 0, 10)

-- ---------- header ----------
local header = Instance.new("Frame")
header.LayoutOrder      = 1
header.Size             = UDim2.new(1, 0, 0, 44)
header.BackgroundColor3 = COL.headerA
header.BorderSizePixel  = 0
header.Parent           = main
corner(header, 10)
gradient(header, COL.headerA, COL.headerB, 90)
makeDraggable(header, main)
makeDraggable(main, main)

do
    -- little monogram square gives the header an anchor point
    local mark = Instance.new("TextLabel")
    mark.Size                   = UDim2.fromOffset(28, 28)
    mark.Position               = UDim2.fromOffset(8, 8)
    mark.BackgroundColor3       = Color3.fromRGB(14, 24, 12)
    mark.BackgroundTransparency = 0.25
    mark.Font                   = Enum.Font.GothamBold
    mark.TextSize               = 12
    mark.TextColor3             = COL.accent
    mark.Text                   = "TG"
    mark.Parent                 = header
    corner(mark, 8)

    local title = Instance.new("TextLabel")
    title.Size                   = UDim2.new(1, -160, 0, 18)
    title.Position               = UDim2.fromOffset(44, 5)
    title.BackgroundTransparency = 1
    title.Font                   = Enum.Font.GothamBold
    title.TextSize               = 16
    title.TextColor3             = Color3.fromRGB(18, 30, 16)
    title.TextXAlignment         = Enum.TextXAlignment.Left
    title.Text                   = "TALLEST GUILD"
    title.Parent                 = header

    local byLine = Instance.new("TextLabel")
    byLine.Size                   = UDim2.new(1, -160, 0, 12)
    byLine.Position               = UDim2.fromOffset(44, 24)
    byLine.BackgroundTransparency = 1
    byLine.Font                   = Enum.Font.Gotham
    byLine.TextSize               = 11
    byLine.TextColor3             = Color3.fromRGB(30, 52, 26)
    byLine.TextXAlignment         = Enum.TextXAlignment.Left
    byLine.Text                   = "by JuicyAsian"
    byLine.Parent                 = header

    local versionBadge = Instance.new("TextLabel")
    versionBadge.Size                   = UDim2.fromOffset(42, 20)
    versionBadge.Position               = UDim2.new(1, -112, 0.5, -10)
    versionBadge.BackgroundColor3       = Color3.fromRGB(14, 24, 12)
    versionBadge.BackgroundTransparency = 0.35
    versionBadge.Font                   = Enum.Font.GothamBold
    versionBadge.TextSize               = 11
    versionBadge.TextColor3             = COL.text
    versionBadge.Text                   = SCRIPT_VERSION
    versionBadge.Parent                 = header
    corner(versionBadge, 8)
end

local minBtn = Instance.new("TextButton")
minBtn.Size                   = UDim2.fromOffset(28, 28)
minBtn.Position               = UDim2.new(1, -66, 0.5, -14)
minBtn.BackgroundColor3       = Color3.fromRGB(14, 24, 12)
minBtn.BackgroundTransparency = 0.35
minBtn.Font                   = Enum.Font.GothamBold
minBtn.TextSize               = 14
minBtn.TextColor3             = COL.text
minBtn.Text                   = "–"
minBtn.Parent                 = header
corner(minBtn, 8)
minBtn.MouseEnter:Connect(function() tween(minBtn, 0.12, { BackgroundTransparency = 0.1 }) end)
minBtn.MouseLeave:Connect(function() tween(minBtn, 0.12, { BackgroundTransparency = 0.35 }) end)

do
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size                   = UDim2.fromOffset(28, 28)
    closeBtn.Position               = UDim2.new(1, -34, 0.5, -14)
    closeBtn.BackgroundColor3       = Color3.fromRGB(14, 24, 12)
    closeBtn.BackgroundTransparency = 0.35
    closeBtn.Font                   = Enum.Font.GothamBold
    closeBtn.TextSize               = 14
    closeBtn.TextColor3             = COL.text
    closeBtn.Text                   = "X"
    closeBtn.Parent                 = header
    corner(closeBtn, 8)
    closeBtn.MouseEnter:Connect(function()
        tween(closeBtn, 0.12, { BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(168, 52, 40) })
    end)
    closeBtn.MouseLeave:Connect(function()
        tween(closeBtn, 0.12, { BackgroundTransparency = 0.35, BackgroundColor3 = Color3.fromRGB(14, 24, 12) })
    end)
    -- X = full shutdown: stop the run, disconnect everything. RightShift can
    -- NOT bring the window back after this; re-execute the script.
    closeBtn.MouseButton1Click:Connect(function()
        dlog("SHUTDOWN", "X pressed - stopping the run and disconnecting everything")
        state.running  = false
        state.anchored = false
        pcall(applyAnchor)
        main.Visible = false
        task.spawn(function()
            for _, conn in ipairs(trackedConns) do
                pcall(function() conn:Disconnect() end)
            end
            getgenv().TallestGuild_Session   = nil
            getgenv().TallestGuild_Heartbeat = nil
            pcall(function() gui:Destroy() end)
            print("[TallestGuild] fully stopped - re-execute the script to use it again")
        end)
    end)
end

-- ---------- scrolling body ----------
local body = Instance.new("ScrollingFrame")
body.LayoutOrder            = 2
-- window minus header (44), start button (34), Discord bar (38),
-- footer (24), layout gaps (32), and padding (10)
body.Size                   = UDim2.new(1, 0, 1, -(44 + 34 + 38 + 24 + 32 + 10))
body.BackgroundTransparency = 1
body.BorderSizePixel        = 0
body.ScrollBarThickness     = 4
body.ScrollBarImageColor3   = COL.accent
body.CanvasSize             = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize    = Enum.AutomaticSize.Y
body.Parent                 = main

-- two equal columns inside the scroll (one cramped column reads badly):
-- left = supplies / status / hunt, right = planting / removal / settings
local leftCol, rightCol
do
    local bodyList = Instance.new("UIListLayout")
    bodyList.FillDirection     = Enum.FillDirection.Horizontal
    bodyList.SortOrder         = Enum.SortOrder.LayoutOrder
    bodyList.VerticalAlignment = Enum.VerticalAlignment.Top
    bodyList.Padding           = UDim.new(0, 8)
    bodyList.Parent            = body

    local function makeColumn(order)
        local col = Instance.new("Frame")
        col.LayoutOrder            = order
        col.Size                   = UDim2.new(0.5, -8, 0, 0)
        col.AutomaticSize          = Enum.AutomaticSize.Y
        col.BackgroundTransparency = 1
        col.Parent                 = body
        local list = Instance.new("UIListLayout")
        list.SortOrder = Enum.SortOrder.LayoutOrder
        list.Padding   = UDim.new(0, 8)
        list.Parent    = col
        return col
    end
    leftCol  = makeColumn(1)
    rightCol = makeColumn(2)
end
padding(body, 0, 8, 0, 2)

-- shared stat tile builder (value label on top, caption below)
local function makeStatTile(parent, caption, widthScale, widthOffset)
    local tile = Instance.new("Frame")
    tile.Size             = UDim2.new(widthScale, widthOffset, 1, 0)
    tile.BackgroundColor3 = COL.bg2
    tile.BorderSizePixel  = 0
    tile.Parent           = parent
    corner(tile, 8)
    stroke(tile, COL.stroke, 1)

    local value = Instance.new("TextLabel")
    value.Size                   = UDim2.new(1, 0, 0, 20)
    value.Position               = UDim2.fromOffset(0, 5)
    value.BackgroundTransparency = 1
    value.Font                   = Enum.Font.GothamBold
    value.TextSize               = 15
    value.TextColor3             = COL.text
    value.Text                   = "0"
    value.Parent                 = tile

    local cap = Instance.new("TextLabel")
    cap.Size                   = UDim2.new(1, 0, 0, 11)
    cap.Position               = UDim2.fromOffset(0, 28)
    cap.BackgroundTransparency = 1
    cap.Font                   = Enum.Font.Gotham
    cap.TextSize               = 10
    cap.TextColor3             = COL.sub
    cap.Text                   = caption
    cap.Parent                 = tile
    return value, cap
end

-- ---------- supplies card (live stock, topmost) ----------
local seedsLeftValue, seedsLeftCap, sprinklersLeftValue, sprinklersLeftCap
do
    local suppliesCard = Instance.new("Frame")
    suppliesCard.LayoutOrder      = 0
    suppliesCard.Size             = UDim2.new(1, 0, 0, 62)
    suppliesCard.BackgroundColor3 = COL.bg1
    suppliesCard.BorderSizePixel  = 0
    suppliesCard.Parent           = leftCol
    corner(suppliesCard, 10)
    stroke(suppliesCard, COL.stroke, 1)
    padding(suppliesCard, 10, 10, 8, 8)

    local suppliesRow = Instance.new("Frame")
    suppliesRow.Size                   = UDim2.new(1, 0, 1, 0)
    suppliesRow.BackgroundTransparency = 1
    suppliesRow.Parent                 = suppliesCard

    local suppliesList = Instance.new("UIListLayout")
    suppliesList.FillDirection = Enum.FillDirection.Horizontal
    suppliesList.SortOrder     = Enum.SortOrder.LayoutOrder
    suppliesList.Padding       = UDim.new(0, 6)
    suppliesList.Parent        = suppliesRow

    seedsLeftValue, seedsLeftCap           = makeStatTile(suppliesRow, "SEEDS LEFT", 0.5, -3)
    sprinklersLeftValue, sprinklersLeftCap = makeStatTile(suppliesRow, "SPRINKLERS LEFT", 0.5, -3)
end

-- ---------- status card ----------
local statusCard = Instance.new("Frame")
statusCard.LayoutOrder      = 1
statusCard.Size             = UDim2.new(1, 0, 0, 176)
statusCard.BackgroundColor3 = COL.bg1
statusCard.BorderSizePixel  = 0
statusCard.Parent           = leftCol
corner(statusCard, 10)
stroke(statusCard, COL.stroke, 1)
padding(statusCard, 10, 10, 8, 8)

local statusDot = Instance.new("Frame")
statusDot.Size             = UDim2.fromOffset(8, 8)
statusDot.Position         = UDim2.fromOffset(0, 4)
statusDot.BackgroundColor3 = COL.sub
statusDot.BorderSizePixel  = 0
statusDot.Parent           = statusCard
corner(statusDot, 4)

local statusLabel = Instance.new("TextLabel")
statusLabel.Size                   = UDim2.new(1, -14, 0, 16)
statusLabel.Position               = UDim2.fromOffset(14, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.Font                   = Enum.Font.Gotham
statusLabel.TextSize               = 13
statusLabel.TextColor3             = COL.sub
statusLabel.TextXAlignment         = Enum.TextXAlignment.Left
statusLabel.TextTruncate           = Enum.TextTruncate.AtEnd
statusLabel.Text                   = state.statusMsg
statusLabel.Parent                 = statusCard

local barBack = Instance.new("Frame")
barBack.Size             = UDim2.new(1, 0, 0, 16)
barBack.Position         = UDim2.fromOffset(0, 22)
barBack.BackgroundColor3 = COL.bg2
barBack.BorderSizePixel  = 0
barBack.Parent           = statusCard
corner(barBack, 8)

local barFill = Instance.new("Frame")
barFill.Size             = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = COL.accent
barFill.BorderSizePixel  = 0
barFill.Parent           = barBack
corner(barFill, 8)
gradient(barFill, COL.headerA, COL.headerB, 0)

local barText = Instance.new("TextLabel")
barText.Size                   = UDim2.new(1, 0, 1, 0)
barText.BackgroundTransparency = 1
barText.Font                   = Enum.Font.GothamBold
barText.TextSize               = 11
barText.TextColor3             = COL.text
barText.Text                   = "batch  0 / 0"
barText.ZIndex                 = 2
barText.Parent                 = barBack

local timerLabel = Instance.new("TextLabel")
timerLabel.Size                   = UDim2.new(1, 0, 0, 13)
timerLabel.Position               = UDim2.fromOffset(0, 42)
timerLabel.BackgroundTransparency = 1
timerLabel.Font                   = Enum.Font.Gotham
timerLabel.TextSize               = 11
timerLabel.TextColor3             = COL.sub
timerLabel.TextXAlignment         = Enum.TextXAlignment.Left
timerLabel.Text                   = "sprinkler: idle   |   phase: idle"
timerLabel.Parent                 = statusCard

local bestValue, keepersValue, removedValue, cyclesValue
do
    local tileRow = Instance.new("Frame")
    tileRow.Size                   = UDim2.new(1, 0, 0, 46)
    tileRow.Position               = UDim2.fromOffset(0, 60)
    tileRow.BackgroundTransparency = 1
    tileRow.Parent                 = statusCard

    local tileList = Instance.new("UIListLayout")
    tileList.FillDirection = Enum.FillDirection.Horizontal
    tileList.SortOrder     = Enum.SortOrder.LayoutOrder
    tileList.Padding       = UDim.new(0, 6)
    tileList.Parent        = tileRow

    bestValue    = makeStatTile(tileRow, "BEST HEIGHT", 0.25, -5)
    keepersValue = makeStatTile(tileRow, "KEEPERS", 0.25, -5)
    removedValue = makeStatTile(tileRow, "REMOVED", 0.25, -5)
    cyclesValue  = makeStatTile(tileRow, "CYCLES", 0.25, -5)
    -- the two figures that matter most carry the accent colours
    bestValue.TextColor3    = COL.accent
    keepersValue.TextColor3 = COL.good
end

local elapsedValue, plantedValue, placedValue, sellsValue
do
    local tileRow2 = Instance.new("Frame")
    tileRow2.Size                   = UDim2.new(1, 0, 0, 46)
    tileRow2.Position               = UDim2.fromOffset(0, 112)
    tileRow2.BackgroundTransparency = 1
    tileRow2.Parent                 = statusCard

    local tileList2 = Instance.new("UIListLayout")
    tileList2.FillDirection = Enum.FillDirection.Horizontal
    tileList2.SortOrder     = Enum.SortOrder.LayoutOrder
    tileList2.Padding       = UDim.new(0, 6)
    tileList2.Parent        = tileRow2

    elapsedValue = makeStatTile(tileRow2, "ELAPSED", 0.25, -5)
    plantedValue = makeStatTile(tileRow2, "PLANTED", 0.25, -5)
    placedValue  = makeStatTile(tileRow2, "SPRINKLERS", 0.25, -5)
    sellsValue   = makeStatTile(tileRow2, "SELLS", 0.25, -5)
end

-- ---------- settings cards ----------
local function makeCard(parentColumn, headingText, order)
    local card = Instance.new("Frame")
    card.LayoutOrder      = order
    card.Size             = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize    = Enum.AutomaticSize.Y
    card.BackgroundColor3 = COL.bg1
    card.BorderSizePixel  = 0
    card.Parent           = parentColumn
    corner(card, 10)
    stroke(card, COL.stroke, 1)
    padding(card, 10, 10, 8, 8)

    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding   = UDim.new(0, 6)
    list.Parent    = card

    local heading = Instance.new("TextLabel")
    heading.LayoutOrder            = -2
    heading.Size                   = UDim2.new(1, 0, 0, 16)
    heading.BackgroundTransparency = 1
    heading.Font                   = Enum.Font.GothamBold
    heading.TextSize               = 12
    heading.TextColor3             = COL.text
    heading.TextXAlignment         = Enum.TextXAlignment.Left
    heading.Text                   = headingText
    heading.Parent                 = card
    padding(heading, 9, 0, 0, 0)   -- indents the text clear of the chip

    -- accent chip: UIPadding shifts children too, so -9 lands it at x = 0
    local chip = Instance.new("Frame")
    chip.Size             = UDim2.fromOffset(3, 12)
    chip.Position         = UDim2.fromOffset(-9, 2)
    chip.BackgroundColor3 = COL.accent
    chip.BorderSizePixel  = 0
    chip.Parent           = heading

    local divider = Instance.new("Frame")
    divider.LayoutOrder      = -1
    divider.Size             = UDim2.new(1, 0, 0, 1)
    divider.BackgroundColor3 = COL.stroke
    divider.BorderSizePixel  = 0
    divider.Parent           = card
    return card
end

local huntCard     = makeCard(leftCol, "HUNT", 2)
local plantCard    = makeCard(rightCol, "PLANTING", 1)
local removalCard  = makeCard(rightCol, "REMOVAL", 2)
local sellCard     = makeCard(rightCol, "AUTO SELL", 3)
local settingsCard = makeCard(rightCol, "SETTINGS", 4)

local rowOrder = 0
local function makeRow(parent, labelText)
    rowOrder += 1
    local row = Instance.new("Frame")
    row.LayoutOrder            = rowOrder
    row.Size                   = UDim2.new(1, 0, 0, 24)
    row.BackgroundTransparency = 1
    row.Parent                 = parent

    local label = Instance.new("TextLabel")
    label.Size                   = UDim2.new(1, -100, 1, 0)
    label.BackgroundTransparency = 1
    label.Font                   = Enum.Font.Gotham
    label.TextSize               = 12
    label.TextColor3             = COL.label   -- dimmer than values: hierarchy
    label.TextXAlignment         = Enum.TextXAlignment.Left
    label.Text                   = labelText
    label.Parent                 = row
    return row
end

local function makeTextRow(parent, labelText, initial, onCommit)
    local row = makeRow(parent, labelText)
    local box = Instance.new("TextBox")
    box.Size             = UDim2.fromOffset(94, 22)
    box.Position         = UDim2.new(1, -94, 0.5, -11)
    box.BackgroundColor3 = COL.bg2
    box.Font             = Enum.Font.Gotham
    box.TextSize         = 12
    box.TextColor3       = COL.text
    box.ClearTextOnFocus = false
    box.Text             = tostring(initial)
    box.Parent           = row
    corner(box, 6)
    local boxStroke = stroke(box, COL.stroke, 1)
    box.Focused:Connect(function()
        boxStroke.Color = COL.accent
    end)
    box.FocusLost:Connect(function()
        boxStroke.Color = COL.stroke
        onCommit(box)
        persistConfig()
    end)
    return box
end

-- numeric commit: revert to the current value on junk input, clamp otherwise
local function commitNumber(box, current, min, max, isInt)
    local n = tonumber(box.Text)
    if n == nil then
        box.Text = tostring(current)
        return current
    end
    if isInt then n = math.floor(n + 0.5) end
    n = math.clamp(n, min, max)
    box.Text = tostring(n)
    return n
end

local function makeToggleRow(parent, labelText, initial, onFlip)
    local KNOB_ON  = UDim2.new(1, -19, 0.5, -8)
    local KNOB_OFF = UDim2.new(0, 3, 0.5, -8)

    local row = makeRow(parent, labelText)
    local track = Instance.new("TextButton")
    track.Size             = UDim2.fromOffset(46, 22)
    track.Position         = UDim2.new(1, -46, 0.5, -11)
    track.BackgroundColor3 = initial and COL.headerB or COL.bg2
    track.AutoButtonColor  = false
    track.Text             = ""
    track.Parent           = row
    corner(track, 11)
    stroke(track, COL.stroke, 1)

    local knob = Instance.new("Frame")
    knob.Size             = UDim2.fromOffset(16, 16)
    knob.Position         = initial and KNOB_ON or KNOB_OFF
    knob.BackgroundColor3 = COL.text
    knob.BorderSizePixel  = 0
    knob.Parent           = track
    corner(knob, 8)

    local on = initial
    track.MouseButton1Click:Connect(function()
        on = not on
        tween(track, 0.15, { BackgroundColor3 = on and COL.headerB or COL.bg2 })
        tween(knob, 0.15, { Position = on and KNOB_ON or KNOB_OFF })
        onFlip(on)
        persistConfig()
    end)
end

-- label row + a full-width box below it (URLs / long ids stay readable)
local function makeWideTextRow(parent, labelText, placeholder, initial, onCommit)
    makeRow(parent, labelText)
    rowOrder += 1
    local boxRow = Instance.new("Frame")
    boxRow.LayoutOrder            = rowOrder
    boxRow.Size                   = UDim2.new(1, 0, 0, 24)
    boxRow.BackgroundTransparency = 1
    boxRow.Parent                 = parent

    local box = Instance.new("TextBox")
    box.Size             = UDim2.new(1, 0, 0, 22)
    box.Position         = UDim2.fromOffset(0, 1)
    box.BackgroundColor3 = COL.bg2
    box.Font             = Enum.Font.Gotham
    box.TextSize         = 11
    box.TextColor3       = COL.text
    box.TextXAlignment   = Enum.TextXAlignment.Left
    box.PlaceholderText  = placeholder
    box.ClearTextOnFocus = false
    box.ClipsDescendants = true
    box.Text             = initial
    box.Parent           = boxRow
    corner(box, 6)
    padding(box, 6, 6, 0, 0)
    local boxStroke = stroke(box, COL.stroke, 1)
    box.Focused:Connect(function() boxStroke.Color = COL.accent end)
    box.FocusLost:Connect(function()
        boxStroke.Color = COL.stroke
        onCommit(box)
        persistConfig()
    end)
end

-- HUNT card: removal is AUTOMATIC (routed per plant by its PlantType
-- attribute), so the old mode picker is gone - just an info row
do
    local row = makeRow(huntCard, "Removal")
    local info = Instance.new("TextLabel")
    info.Size                   = UDim2.fromOffset(150, 22)
    info.Position               = UDim2.new(1, -150, 0.5, -11)
    info.BackgroundTransparency = 1
    info.Font                   = Enum.Font.GothamBold
    info.TextSize               = 11
    info.TextColor3             = COL.sub
    info.TextXAlignment         = Enum.TextXAlignment.Right
    info.Text                   = "auto (by PlantType)"
    info.Parent                 = row
end

makeTextRow(huntCard, "Seed", state.seedName, function(box)
    if box.Text == "" then
        box.Text = state.seedName
        return
    end
    if box.Text ~= state.seedName then
        state.seedName = box.Text
        -- skip/remove verdicts were judged against the old seed
        resetVerdicts()
    end
end)
makeTextRow(huntCard, "Target height (59.5 = 60)", state.targetHeight, function(box)
    local before = state.targetHeight
    state.targetHeight = commitNumber(box, state.targetHeight, 1, 100000, true)
    if state.targetHeight ~= before then resetVerdicts() end
end)
makeTextRow(huntCard, "Seeds per batch", state.seedsPerBatch, function(box)
    state.seedsPerBatch = commitNumber(box, state.seedsPerBatch, 1, 1000, true)
end)
makeToggleRow(huntCard, "Stop when found", state.stopOnFound, function(on)
    state.stopOnFound = on
end)

-- PLANTING card
makeTextRow(plantCard, "Sprinkler item", state.sprinklerName, function(box)
    if box.Text ~= "" then state.sprinklerName = box.Text else box.Text = state.sprinklerName end
end)
makeTextRow(plantCard, "Sprinkler life (s)", state.sprinklerLife, function(box)
    state.sprinklerLife = commitNumber(box, state.sprinklerLife, 10, 600, true)
end)
makeToggleRow(plantCard, "Place sprinkler first", state.placeSprinkler, function(on)
    state.placeSprinkler = on
end)
makeTextRow(plantCard, "Radius", state.radius, function(box)
    state.radius = commitNumber(box, state.radius, 1, 200, true)
end)
makeTextRow(plantCard, "Plant delay (s)", state.plantDelay, function(box)
    state.plantDelay = commitNumber(box, state.plantDelay, 0, 5, false)
end)
makeToggleRow(plantCard, "Only on PlantArea", state.onlyPlantArea, function(on)
    state.onlyPlantArea = on
end)
-- ON = the batch centers on YOUR character and follows you live; OFF = the
-- plot's plant-area center. Combine with Only on PlantArea off to plant at
-- exact foot height with no ground raycast.
makeToggleRow(plantCard, "Plant where I stand", state.centerOnSelf, function(on)
    state.centerOnSelf = on
end)

-- REMOVAL card
makeTextRow(removalCard, "Shovel delay (s)", state.shovelDelay, function(box)
    state.shovelDelay = commitNumber(box, state.shovelDelay, 0.05, 5, false)
end)
makeTextRow(removalCard, "Collect batch size", state.collectBatch, function(box)
    state.collectBatch = commitNumber(box, state.collectBatch, 1, 50, true)
end)
makeTextRow(removalCard, "Collect delay (s)", state.collectDelay, function(box)
    state.collectDelay = commitNumber(box, state.collectDelay, 0, 5, false)
end)
makeTextRow(removalCard, "Judge scan delay (s)", state.scanDelay, function(box)
    state.scanDelay = commitNumber(box, state.scanDelay, 0.05, 10, false)
end)

-- AUTO SELL card
makeToggleRow(sellCard, "Auto sell (SellAll)", state.autoSell, function(on)
    state.autoSell = on
    -- ON sells right away, then every interval
    state.nextSellAt = os.clock()
end)
makeTextRow(sellCard, "Sell every (s)", state.sellInterval, function(box)
    state.sellInterval = commitNumber(box, state.sellInterval, 1, 3600, false)
    state.nextSellAt   = os.clock() + state.sellInterval
end)

-- SETTINGS card
makeToggleRow(settingsCard, "Freeze character", state.anchored, function(on)
    state.anchored = on
    applyAnchor()
end)
makeToggleRow(settingsCard, "Delete other plots", state.hideOtherPlots, function(on)
    state.hideOtherPlots = on
    if on then task.spawn(sweepOtherPlots) end
end)
makeToggleRow(settingsCard, "Save config", state.saveConfig, function(on)
    state.saveConfig = on
end)
makeWideTextRow(settingsCard, "Discord webhook (pinged per keeper)",
    "https://discord.com/api/webhooks/...", state.webhookUrl, function(box)
    state.webhookUrl = box.Text:gsub("%s+", "")
    box.Text         = state.webhookUrl
end)
makeWideTextRow(settingsCard, "Ping user ID instead of @everyone (optional)",
    "e.g. 123456789012345678", state.pingUserId, function(box)
    local id = box.Text:gsub("%D", "")
    state.pingUserId = id
    box.Text         = id
end)

-- ---------- start button (always visible, under the scroll) ----------
local startBtn = Instance.new("TextButton")
startBtn.LayoutOrder      = 3
startBtn.Size             = UDim2.new(1, 0, 0, 34)
startBtn.BackgroundColor3 = Color3.fromRGB(46, 128, 74)
startBtn.Font             = Enum.Font.GothamBold
startBtn.TextSize         = 13
startBtn.TextColor3       = COL.text
startBtn.Text             = "START HUNT"
startBtn.Parent           = main
corner(startBtn, 8)
stroke(startBtn, COL.stroke, 1)
gradient(startBtn, Color3.fromRGB(255, 255, 255), Color3.fromRGB(208, 208, 208), 90)
startBtn.MouseButton1Click:Connect(function()
    if state.running then stopRun() else startRun() end
end)

-- ---------- Discord invite bar ----------
local DISCORD_INVITE = "discord.gg/pubert"

local discordBtn = Instance.new("TextButton")
discordBtn.Name             = "DiscordInvite"
discordBtn.LayoutOrder      = 4
discordBtn.Size             = UDim2.new(1, 0, 0, 38)
discordBtn.BackgroundColor3 = Color3.fromRGB(111, 76, 205)
discordBtn.BorderSizePixel  = 0
discordBtn.AutoButtonColor  = false
discordBtn.Text             = ""
discordBtn.Parent           = main
corner(discordBtn, 10)
stroke(discordBtn, Color3.fromRGB(154, 116, 235), 1)
gradient(discordBtn, Color3.fromRGB(146, 91, 235), Color3.fromRGB(91, 61, 179), 0)

local discordIcon = Instance.new("TextLabel")
discordIcon.Size                   = UDim2.fromOffset(30, 30)
discordIcon.Position               = UDim2.fromOffset(5, 4)
discordIcon.BackgroundTransparency = 1
discordIcon.Font                   = Enum.Font.GothamBold
discordIcon.TextSize               = 18
discordIcon.TextColor3             = COL.text
discordIcon.Text                   = "◉"
discordIcon.Parent                 = discordBtn

local discordTitle = Instance.new("TextLabel")
discordTitle.Size                   = UDim2.new(0.5, -36, 1, 0)
discordTitle.Position               = UDim2.fromOffset(36, 0)
discordTitle.BackgroundTransparency = 1
discordTitle.Font                   = Enum.Font.GothamBold
discordTitle.TextSize               = 13
discordTitle.TextColor3             = COL.text
discordTitle.TextXAlignment         = Enum.TextXAlignment.Left
discordTitle.Text                   = "Join our Server!"
discordTitle.Parent                 = discordBtn

local discordLinkBox = Instance.new("Frame")
discordLinkBox.Size                   = UDim2.new(0.43, 0, 0, 26)
discordLinkBox.Position               = UDim2.new(1, -8, 0.5, -13)
discordLinkBox.AnchorPoint            = Vector2.new(1, 0)
discordLinkBox.BackgroundColor3       = Color3.fromRGB(48, 34, 91)
discordLinkBox.BackgroundTransparency = 0.15
discordLinkBox.BorderSizePixel        = 0
discordLinkBox.Parent                 = discordBtn
corner(discordLinkBox, 8)
stroke(discordLinkBox, Color3.fromRGB(176, 145, 240), 1)

local discordLink = Instance.new("TextLabel")
discordLink.Size                   = UDim2.new(1, -10, 1, 0)
discordLink.Position               = UDim2.fromOffset(5, 0)
discordLink.BackgroundTransparency = 1
discordLink.Font                   = Enum.Font.GothamBold
discordLink.TextSize               = 11
discordLink.TextColor3             = COL.text
discordLink.Text                   = DISCORD_INVITE
discordLink.Parent                 = discordLinkBox

local discordOriginalText = "Join our Server!"
local function copyDiscordInvite()
    local copied = false

    if typeof(setclipboard) == "function" then
        copied = pcall(setclipboard, DISCORD_INVITE)
    elseif typeof(toclipboard) == "function" then
        copied = pcall(toclipboard, DISCORD_INVITE)
    end

    if copied then
        discordTitle.Text = "Invite copied!"
        setStatus("good", "Invite copied: " .. DISCORD_INVITE)
    else
        discordTitle.Text = "Copy unavailable"
        setStatus("bad", "Clipboard function unavailable - invite: " .. DISCORD_INVITE)
    end

    task.delay(2, function()
        if alive() and discordTitle.Parent then
            discordTitle.Text = discordOriginalText
        end
    end)
end

discordBtn.MouseButton1Click:Connect(copyDiscordInvite)
discordBtn.MouseEnter:Connect(function()
    tween(discordBtn, 0.12, { BackgroundColor3 = Color3.fromRGB(132, 91, 224) })
end)
discordBtn.MouseLeave:Connect(function()
    tween(discordBtn, 0.12, { BackgroundColor3 = Color3.fromRGB(111, 76, 205) })
end)

-- ---------- footer ----------
local footer = Instance.new("TextLabel")
footer.LayoutOrder            = 5
footer.Size                   = UDim2.new(1, 0, 0, 24)
footer.BackgroundTransparency = 1
footer.Font                   = Enum.Font.Gotham
footer.TextSize               = 11
footer.TextColor3             = COL.sub
footer.Text                   = "RightShift to show/hide   |   X shuts the script down"
footer.Parent                 = main

-- minimize keeps only the header; the fixed window shrinks to match
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    minBtn.Text      = minimized and "+" or "–"
    body.Visible       = not minimized
    startBtn.Visible   = not minimized
    discordBtn.Visible = not minimized
    footer.Visible     = not minimized
    main.Size        = UDim2.fromOffset(WINDOW_W, minimized and HEADER_ONLY_H or WINDOW_H)
end)

-- ============================================================
--  UI REFRESH LOOP
-- ============================================================
local STATUS_COLORS = { idle = COL.sub, run = COL.runCol, good = COL.good, bad = COL.bad }

task.spawn(function()
    while alive() do
        if not gui.Parent then break end
        local statusColor = STATUS_COLORS[state.statusKind] or COL.sub
        statusLabel.Text           = state.statusMsg
        statusLabel.TextColor3     = statusColor
        statusDot.BackgroundColor3 = statusColor

        local frac = state.batchTotal > 0 and (state.batchDone / state.batchTotal) or 0
        barFill.Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)
        barText.Text = ("batch  %d / %d"):format(state.batchDone, state.batchTotal)

        local sprinklerInfo = (state.running and state.placeSprinkler)
            and ("sprinkler: %ds"):format(math.max(0, math.ceil(state.sprinklerAt - os.clock())))
            or "sprinkler: idle"
        local sellInfo = state.autoSell
            and ("sell: %ds"):format(math.max(0, math.ceil(state.nextSellAt - os.clock())))
            or "sell: idle"
        timerLabel.Text = sprinklerInfo .. "   |   " .. sellInfo .. "   |   phase: " .. state.phase

        bestValue.Text    = state.bestHeight > 0 and tostring(state.bestHeight) or "-"
        keepersValue.Text = tostring(state.keepers)
        removedValue.Text = tostring(state.removed)
        cyclesValue.Text  = tostring(state.cycles)
        plantedValue.Text = tostring(state.totalPlanted)
        placedValue.Text  = tostring(state.sprinklersPlaced)
        sellsValue.Text   = tostring(state.sells)

        seedsLeftValue.Text      = tostring(seedsRemaining())
        seedsLeftCap.Text        = (state.seedName .. "s left"):upper()
        sprinklersLeftValue.Text = tostring(sprinklerStock())
        sprinklersLeftCap.Text   = (state.sprinklerName .. "s left"):upper()

        local elapsed = state.runStartedAt > 0 and (os.clock() - state.runStartedAt) or 0
        elapsedValue.Text = ("%d:%02d:%02d"):format(
            math.floor(elapsed / 3600), math.floor(elapsed / 60) % 60, math.floor(elapsed) % 60)

        startBtn.Text = state.running and "STOP HUNT" or "START HUNT"
        startBtn.BackgroundColor3 = state.running
            and Color3.fromRGB(150, 58, 44)
            or  Color3.fromRGB(46, 128, 74)
        task.wait(0.1)
    end
end)

-- ============================================================
--  TOGGLE KEY
-- ============================================================
trackConn(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or not alive() then return end
    if input.KeyCode == TOGGLE_KEY then
        main.Visible = not main.Visible
    end
end))

dlog("INIT", "Tallest Guild " .. SCRIPT_VERSION .. " loaded - RightShift toggles the window")
dlog("INIT", "anti-AFK (idle kick + GAG server-hop override) and the single-instance guard are active")