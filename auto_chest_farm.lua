--================================================================--
--  Blox Fruits Auto Chest Farm v4  (Delta Executor compatible)
--  - Auto chest farm (all 3 seas, dynamic detection)
--  - Auto-stop + safe zone teleport on Fist of Darkness / God's Chalice
--  - Mod menu GUI: Dark Arena TP, Castle on the Sea TP, farm toggle
--  - Auto server hop when all chests looted
--================================================================--

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local TweenService     = game:GetService("TweenService")
local TeleportService  = game:GetService("TeleportService")
local HttpService      = game:GetService("HttpService")
local CollectionService= game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local character, hrp, humanoid

-- Detect current sea by PlaceId
local SEA = "Unknown"
if game.PlaceId == 2753915549 then SEA = "First"
elseif game.PlaceId == 4442272183 then SEA = "Second"
elseif game.PlaceId == 7449423635 then SEA = "Third" end

--==================== SETTINGS ====================--
local CHEST_TAG       = "_ChestTagged"
local SCAN_RANGE      = 300
local OPEN_RANGE      = 15
local IDLE_HOP_DELAY  = 2
local POINT_COOLDOWN  = 20
local MAX_IDLE        = 12
local TweenSpeed      = 220
local HOP_HEIGHT      = 120

-- Rare drops that trigger safe-zone escape
local RARE_ITEMS = {
    "fist of darkness", "fistofdarkness",
    "god's chalice", "gods chalice", "chalice",
    "dark fragment", "darkfragment",
}

-- Safe-zone island keywords per sea (matched against Map island names)
local SAFE_ZONES = {
    First  = {"middletown", "marinefortress", "piratevillage", "marinebase"},
    Second = {"kingdomofrose", "kingdom", "greenzone", "hydraisland"},
    Third  = {"castleonthesea", "castlesea", "porttown", "hydraisland", "kingdomofrose"},
    Unknown= {"castleonthesea", "porttown", "kingdomofrose", "middletown"},
}

-- Menu teleport destinations: {button text, required keywords (ALL must match)}
local TP_DESTINATIONS = {
    {name = "Dark Arena",        keywords = {"dark", "arena"}},
    {name = "Castle on the Sea", keywords = {"castle", "sea"}},
}

--==================== STATE ====================--
local openedChests   = {}
local pointCooldowns = {}
local islandIdx      = 1
local idleCount      = 0
_G.ChestFarmEnabled  = true
local farmRunning    = true
local escaped        = false   -- set true once rare item handled

--==================== HELPERS ====================--
local function getChar()
    if not character or not character.Parent then
        character = player.Character or player.CharacterAdded:Wait()
    end
    if not hrp or not hrp.Parent then
        hrp      = character:WaitForChild("HumanoidRootPart", 10)
        humanoid = character:WaitForChild("Humanoid", 10)
    end
    return hrp
end

local function norm(s)
    return (s or ""):lower():gsub("[%s_%-]", "")
end

-- Find island model under workspace.Map (fallback: _WorldOrigin.Locations)
local function findIsland(keywords)
    local best, bestD = nil, math.huge
    local h = getChar()
    local myPos = h and h.Position or Vector3.new()

    local containers = {}
    local map = Workspace:FindFirstChild("Map")
    if map then table.insert(containers, map) end
    local wo = Workspace:FindFirstChild("_WorldOrigin")
    local locs = wo and wo:FindFirstChild("Locations")
    if locs then table.insert(containers, locs) end

    for _, container in ipairs(containers) do
        for _, isl in ipairs(container:GetChildren()) do
            local n = norm(isl.Name)
            local allMatch = true
            for _, kw in ipairs(keywords) do
                if not n:find(kw, 1, true) then allMatch = false break end
            end
            if allMatch then
                local part = isl:IsA("BasePart") and isl
                    or isl:FindFirstChildWhichIsA("BasePart", true)
                    or (isl.GetPivot and isl)
                local pos
                if part and part:IsA("BasePart") then pos = part.Position
                elseif isl.GetPivot then pos = isl:GetPivot().Position end
                if pos then
                    local d = (pos - myPos).Magnitude
                    if d < bestD then best, bestD = isl, d end
                end
            end
        end
    end
    return best
end

local function islandPosition(isl)
    if isl:IsA("BasePart") then return isl.Position end
    if isl.GetPivot then return isl:GetPivot().Position end
    local p = isl:FindFirstChildWhichIsA("BasePart", true)
    return p and p.Position
end

--====== Teleport ======--
local function hopTo(pos)
    local h = getChar()
    if not h then return end
    h.CFrame = CFrame.new(pos + Vector3.new(0, HOP_HEIGHT, 0))
    task.delay(0.4, function()
        local h2 = getChar()
        if h2 then h2.CFrame = CFrame.new(pos + Vector3.new(0, 8, 0)) end
    end)
end

local function teleportToKeywords(keywords, label)
    local isl = findIsland(keywords)
    if not isl then
        warn("[ChestFarm] Island not found: " .. (label or table.concat(keywords, "+")))
        return false
    end
    local pos = islandPosition(isl)
    if pos then hopTo(pos) end
    print("[ChestFarm] Teleported to " .. (label or isl.Name))
    return true
end

local function goToSafeZone()
    local kws = SAFE_ZONES[SEA] or SAFE_ZONES.Unknown
    print("[ChestFarm] Rare drop! Escaping to safe zone (Sea: " .. SEA .. ")")
    -- try each safe-zone keyword, nearest match wins
    return teleportToKeywords(kws, "SafeZone")
end

--====== Chest detection ======--
local function getChests()
    local seen, out = {}, {}
    pcall(function()
        for _, part in ipairs(CollectionService:GetTagged(CHEST_TAG)) do
            local model = part:FindFirstAncestorOfClass("Model") or part.Parent
            if model and not seen[model] then
                seen[model] = true
                table.insert(out, {model = model, part = part})
            end
        end
    end)
    local folder = Workspace:FindFirstChild("ChestModels")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") and not seen[m] then
                local part = m:FindFirstChildWhichIsA("BasePart", true)
                if part then seen[m] = true; table.insert(out, {model = m, part = part}) end
            end
        end
    end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and obj.Name:match("^Chest") and not seen[obj] then
            local part = obj:FindFirstChildWhichIsA("BasePart", true)
            if part then seen[obj] = true; table.insert(out, {model = obj, part = part}) end
        end
    end
    return out
end

local function isChestAvailable(entry)
    local part = entry.part
    if part and part:IsA("BasePart") and part.CanTouch == false then return false end
    local t = openedChests[entry.model]
    if t and (os.clock() - t) < 240 then return false end
    return true
end

local function nearestChest()
    local h = getChar()
    if not h then return nil end
    local myPos = h.Position
    local best, bestD = nil, math.huge
    for _, c in ipairs(getChests()) do
        if isChestAvailable(c) then
            local d = (c.part.Position - myPos).Magnitude
            if d < bestD then best, bestD = c, d end
        end
    end
    return best
end

local function openChest(entry)
    local part, model = entry.part, entry.model
    local h = getChar()
    if not h then return false end
    h.CFrame = CFrame.new(part.Position + Vector3.new(0, 2, 0))
    task.wait(0.15)
    if firetouchinterest then
        pcall(function()
            firetouchinterest(h, part, 0)
            task.wait(0.1)
            firetouchinterest(h, part, 1)
        end)
    end
    local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt and prompt.Enabled then pcall(fireproximityprompt, prompt) end
    local cd = model:FindFirstChildWhichIsA("ClickDetector", true)
    if cd and fireclickdetector then pcall(fireclickdetector, cd) end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if remotes then
        for _, n in ipairs({"OpenChest","ChestOpen","Open","Chest","Collector"}) do
            local r = remotes:FindFirstChild(n)
            if r and r:IsA("RemoteEvent") then pcall(function() r:FireServer(model) end) break end
        end
    end
    openedChests[model] = os.clock()
    return true
end

local function tweenTo(targetPos)
    local h = getChar()
    if not h or not humanoid then return end
    local dist = (h.Position - targetPos).Magnitude
    local dur  = math.clamp(dist / TweenSpeed, 0.15, 3)
    local tw = TweenService:Create(h, TweenInfo.new(dur, Enum.EasingStyle.Linear),
        {CFrame = CFrame.new(targetPos)})
    tw:Play(); tw.Completed:Wait()
end

--====== Island patrol points ======--
local function getIslandPoints()
    local pts = {}
    local wo = Workspace:FindFirstChild("_WorldOrigin")
    local locs = wo and wo:FindFirstChild("Locations")
    if not locs then return pts end
    for _, loc in ipairs(locs:GetChildren()) do
        local part = loc:IsA("BasePart") and loc or loc:FindFirstChildWhichIsA("BasePart", true)
        if part then table.insert(pts, {name = loc.Name, pos = part.Position}) end
    end
    table.sort(pts, function(a,b) return a.name < b.name end)
    return pts
end
local ISLAND_POINTS = getIslandPoints()

--====== Server Hop ======--
local function serverHop()
    print("[ChestFarm] All chests looted -> hopping server...")
    task.wait(2)
    local ok, res = pcall(function()
        return game:HttpGet(string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?limit=100&sortOrder=Asc&excludeFullGames=true",
            game.PlaceId))
    end)
    if ok and res then
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, res)
        if ok2 and data and data.data and #data.data > 0 then
            local cands = {}
            for _, s in ipairs(data.data) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    table.insert(cands, s)
                end
            end
            if #cands > 0 then
                TeleportService:TeleportToPlaceInstance(
                    game.PlaceId, cands[math.random(#cands)].id, player)
                return
            end
        end
    end
    TeleportService:Teleport(game.PlaceId, player)
end

--====== RARE ITEM WATCHER ======--
local function isRareItem(name)
    local n = norm(name)
    for _, rare in ipairs(RARE_ITEMS) do
        if n:find(rare, 1, true) then return true end
    end
    return false
end

local function onRareDrop(itemName)
    if escaped then return end
    escaped = true
    _G.ChestFarmEnabled = false
    print("[ChestFarm] !! Rare drop: " .. itemName .. " - stopping farm, going to safe zone")
    task.spawn(function()
        task.wait(0.5)
        goToSafeZone()
        -- resume farming after 30s in safe zone
        task.wait(30)
        escaped = false
        _G.ChestFarmEnabled = true
        print("[ChestFarm] Resuming farm")
    end)
end

local function watchContainer(container)
    for _, item in ipairs(container:GetChildren()) do
        if item:IsA("Tool") and isRareItem(item.Name) then
            onRareDrop(item.Name)
        end
    end
    container.ChildAdded:Connect(function(item)
        if item:IsA("Tool") and isRareItem(item.Name) then
            onRareDrop(item.Name)
        end
    end)
end

watchContainer(player:WaitForChild("Backpack"))
player.CharacterAdded:Connect(function(char)
    watchContainer(char:WaitForChild("Backpack") or char)
end)
-- check existing character backpack too
if character then
    local bp = character:FindFirstChild("Backpack")
    if bp then watchContainer(bp) end
end

--====== MOD MENU GUI ======--
local function buildMenu()
    local old = playerGui:FindFirstChild("ChestFarmMenu")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ChestFarmMenu"
    gui.ResetOnSpawn = false
    gui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 220, 0, 240)
    frame.Position = UDim2.new(0, 20, 0.5, -120)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

    -- drag support
    local dragging, dragStart, startPos = false, nil, nil
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true; dragStart = input.Position; startPos = frame.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                       startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 30)
    title.BackgroundColor3 = Color3.fromRGB(45, 45, 60)
    title.Text = "Chest Farm  |  Sea: " .. SEA
    title.TextColor3 = Color3.new(1,1,1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = frame
    Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

    local function makeButton(text, y, color, callback)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.9, 0, 0, 36)
        b.Position = UDim2.new(0.05, 0, 0, y)
        b.BackgroundColor3 = color
        b.Text = text
        b.TextColor3 = Color3.new(1,1,1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 13
        b.Parent = frame
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        b.MouseButton1Click:Connect(callback)
        return b
    end

    -- teleport buttons for each destination
    local y = 40
    for _, dest in ipairs(TP_DESTINATIONS) do
        makeButton("TP: " .. dest.name, y, Color3.fromRGB(60, 90, 160), function()
            _G.ChestFarmEnabled = false
            teleportToKeywords(dest.keywords, dest.name)
            task.delay(2, function() _G.ChestFarmEnabled = true end)
        end)
        y += 42
    end

    -- safe zone button
    makeButton("TP: Safe Zone", y, Color3.fromRGB(60, 140, 90), function()
        _G.ChestFarmEnabled = false
        goToSafeZone()
        task.delay(2, function() _G.ChestFarmEnabled = true end)
    end)
    y += 42

    -- farm toggle
    local farmBtn = makeButton("Farm: ON", y, Color3.fromRGB(160, 60, 60), function()
        _G.ChestFarmEnabled = not _G.ChestFarmEnabled
        farmBtn.Text = _G.ChestFarmEnabled and "Farm: ON" or "Farm: OFF"
        farmBtn.BackgroundColor3 = _G.ChestFarmEnabled
            and Color3.fromRGB(160, 60, 60) or Color3.fromRGB(60, 140, 90)
    end)
    y += 42

    -- status label
    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(0.9, 0, 0, 30)
    status.Position = UDim2.new(0.05, 0, 0, y)
    status.BackgroundTransparency = 1
    status.TextColor3 = Color3.fromRGB(180, 180, 180)
    status.Font = Enum.Font.Gotham
    status.TextSize = 11
    status.TextWrapped = true
    status.Text = "Sea: " .. SEA .. "\nChests: dynamic scan\nRare drop -> safe zone"
    status.Parent = frame
end

task.spawn(buildMenu)

--====== MAIN FARM LOOP ======--
print("[ChestFarm] v4 started | Sea: " .. SEA .. " | islands: " .. #ISLAND_POINTS)

while farmRunning do
    if _G.ChestFarmEnabled and not escaped then
        local chest = nearestChest()
        local h = getChar()
        if h then
            if chest then
                local dist = (chest.part.Position - h.Position).Magnitude
                idleCount = 0
                if dist <= OPEN_RANGE then
                    openChest(chest); task.wait(1.5)
                elseif dist <= SCAN_RANGE then
                    tweenTo(chest.part.Position + Vector3.new(0, 3, 0))
                    openChest(chest); task.wait(1.5)
                else
                    hopTo(chest.part.Position); task.wait(0.6)
                end
            else
                idleCount += 1
                if idleCount >= MAX_IDLE then
                    idleCount = 0
                    serverHop()
                elseif #ISLAND_POINTS > 0 then
                    islandIdx = (islandIdx % #ISLAND_POINTS) + 1
                    local pt = ISLAND_POINTS[islandIdx]
                    local now = os.clock()
                    if not pointCooldowns[pt.name] or (now - pointCooldowns[pt.name]) > POINT_COOLDOWN then
                        local d = (h.Position - pt.pos).Magnitude
                        if d > SCAN_RANGE then hopTo(pt.pos) else tweenTo(pt.pos) end
                        pointCooldowns[pt.name] = now
                        task.wait(IDLE_HOP_DELAY)
                    else
                        task.wait(0.5)
                    end
                else
                    task.wait(1)
                end
            end
        end
    else
        task.wait(0.5)
    end
    task.wait(0.2)
end
