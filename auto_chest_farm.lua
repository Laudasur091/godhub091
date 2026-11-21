--================================================================--
--  Blox Fruits Auto Chest Farm v5  (Delta Executor compatible)
--  - Chest discovery: records chest positions island-wide, farms all
--  - Anti-drown: returns to last safe ground when in water
--  - Auto-stop + safe zone teleport on Fist of Darkness / God's Chalice
--  - Draggable mod menu GUI
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
local SCAN_RANGE      = 400
local OPEN_RANGE      = 18
local IDLE_HOP_DELAY  = 2.5
local POINT_COOLDOWN  = 25
local MAX_IDLE        = 10
local TweenSpeed      = 260
local HOP_HEIGHT      = 150
local STREAM_WAIT     = 1.2          -- wait after arriving for chests to stream in

local RARE_ITEMS = {
    "fist of darkness", "fistofdarkness",
    "god's chalice", "gods chalice", "chalice",
    "dark fragment", "darkfragment",
}

local SAFE_ZONES = {
    First  = {"middletown", "marinefortress", "piratevillage", "marinebase"},
    Second = {"kingdomofrose", "kingdom", "greenzone", "hydraisland"},
    Third  = {"castleonthesea", "castlesea", "porttown", "hydraisland", "kingdomofrose"},
    Unknown= {"castleonthesea", "porttown", "kingdomofrose", "middletown"},
}

local TP_DESTINATIONS = {
    {name = "Dark Arena",        keywords = {"dark", "arena"}},
    {name = "Castle on the Sea", keywords = {"castle", "sea"}},
}

--==================== STATE ====================--
local openedChests   = {}    -- [model] = os.clock()
local knownChests    = {}    -- [posKey] = Vector3  (discovered chest positions)
local chestByPos     = {}    -- [posKey] = model (streamed chest nearest that pos)
local pointCooldowns = {}
local islandIdx      = 1
local idleCount      = 0
local discoveryDone  = false -- all island points visited at least once
local _G.ChestFarmEnabled = true
local farmRunning    = true
local escaped        = false

local lastSafePos    = nil   -- last grounded position (anti-drown)
local statusLabel    = nil   -- GUI status label reference
local stuckPosKey    = nil   -- position key we're stuck on
local stuckSince     = nil   -- when we started waiting there
local STUCK_TIMEOUT  = 90    -- seconds before server hop when stuck

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

local function posKey(pos)
    return math.floor(pos.X/10)..","..math.floor(pos.Y/10)..","..math.floor(pos.Z/10)
end

--====== Anti-drown ======--
local function inWater()
    if not humanoid or not hrp then return false end
    local state = humanoid:GetState()
    if state == Enum.HumanoidStateType.Swimming
       or state == Enum.HumanoidStateType.Dead then return true end
    local mat = humanoid.FloorMaterial
    return mat == Enum.Material.Water or mat == Enum.Material.Ice
end

local function updateSafePos()
    if humanoid and hrp and humanoid.FloorMaterial ~= Enum.Material.Air
       and not inWater() then
        lastSafePos = hrp.Position
    end
end

local function antiDrown()
    if inWater() and lastSafePos then
        local h = getChar()
        if h then
            h.CFrame = CFrame.new(lastSafePos + Vector3.new(0, 6, 0))
            print("[ChestFarm] Anti-drown: returned to safe ground")
        end
        return true
    end
    return false
end

--====== Island finding ======--
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
                local pos = islandPosition(isl)
                if pos then
                    local d = (pos - myPos).Magnitude
                    if d < bestD then best, bestD = isl, d end
                end
            end
        end
    end
    return best
end

function islandPosition(isl)
    if isl:IsA("BasePart") then return isl.Position end
    if isl.GetPivot then
        local ok, p = pcall(function() return isl:GetPivot().Position end)
        if ok then return p end
    end
    local p = isl:FindFirstChildWhichIsA("BasePart", true)
    return p and p.Position
end

--====== Teleport / FLIGHT (HOHO-style air movement) ======--
local flying = false
local FLIGHT_SPEED = 380
local FLIGHT_TIMEOUT = 90

local function setFlightCollision(on)
    if not character then return end
    for _, p in ipairs(character:GetDescendants()) do
        if p:IsA("BasePart") then
            if on then p.CanCollide = false
            else p.CanCollide = true end
        end
    end
end

-- Smooth flight through the air to target position (noclip + physics state)
local function hopTo(pos)
    local h = getChar()
    if not h or not humanoid then return end
    if flying then return end
    flying = true

    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
    humanoid.AutoRotate = false
    setFlightCollision(true)

    local target = pos + Vector3.new(0, 12, 0)
    local t0 = os.clock()

    while flying do
        h = getChar()
        if not h or not humanoid or humanoid.Health <= 0 then break end

        local cur = h.Position
        local d = target - cur
        local dist = d.Magnitude
        if dist <= 6 then break end

        local dt = RunService.Heartbeat:Wait()
        local step = math.min(FLIGHT_SPEED * dt, dist)
        h.CFrame = CFrame.new(cur + d.Unit * step)

        if antiDrown() then break end
        if os.clock() - t0 > FLIGHT_TIMEOUT then break end
    end

    -- landing: restore
    flying = false
    if character and character.Parent then
        setFlightCollision(false)
        local h2 = getChar()
        if h2 and humanoid and humanoid.Health > 0 then
            humanoid.AutoRotate = true
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            -- settle slightly above ground
            h2.CFrame = CFrame.new(h2.Position + Vector3.new(0, -4, 0))
        end
    end
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
    return teleportToKeywords(kws, "SafeZone")
end

--====== Chest scan + discovery ======--
local function scanChests()
    """Returns list of {model, part} for currently streamed chests."""
    local seen, out = {}, {}

    -- record positions into knownChests as we discover them
    local function record(pos)
        if pos then knownChests[posKey(pos)] = pos end
    end

    pcall(function()
        for _, part in ipairs(CollectionService:GetTagged(CHEST_TAG)) do
            local model = part:FindFirstAncestorOfClass("Model") or part.Parent
            if model and not seen[model] then
                seen[model] = true
                record(part.Position)
                table.insert(out, {model = model, part = part})
            end
        end
    end)

    local folder = Workspace:FindFirstChild("ChestModels")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") and not seen[m] then
                local part = m:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    seen[m] = true
                    record(part.Position)
                    table.insert(out, {model = m, part = part})
                end
            end
        end
    end

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and obj.Name:match("^Chest") and not seen[obj] then
            local part = obj:FindFirstChildWhichIsA("BasePart", true)
            if part then
                seen[obj] = true
                record(part.Position)
                table.insert(out, {model = obj, part = part})
            end
        end
    end
    return out
end

local function chestModelOpened(model)
    local t = openedChests[model]
    return t and (os.clock() - t) < 240
end

-- Find best target: prefer streamed chest near a known position,
-- else return known position to travel to (chest will stream in on arrival)
local function bestChestTarget()
    local h = getChar()
    if not h then return nil end
    local myPos = h.Position

    -- Pass 1: streamed chests
    local streamed = scanChests()
    local best, bestD = nil, math.huge
    for _, c in ipairs(streamed) do
        if not chestModelOpened(c.model)
           and not (c.part.CanTouch == false) then
            local d = (c.part.Position - myPos).Magnitude
            if d < bestD then best, bestD = c, d end
        end
    end
    if best then return {kind = "model", data = best} end

    -- Pass 2: known positions (unstreamed) - pick nearest not recently opened
    best, bestD = nil, math.huge
    for k, pos in pairs(knownChests) do
        -- skip if we opened a chest at this spot recently
        local recent = false
        for m, t in pairs(openedChests) do
            if (os.clock() - t) < 240 and m.Parent then
                local mp = m:FindFirstChildWhichIsA("BasePart", true)
                if mp and posKey(mp.Position) == k then recent = true break end
            end
        end
        if not recent then
            local d = (pos - myPos).Magnitude
            if d < bestD then best, bestD = pos, d end
        end
    end
    if best then return {kind = "position", data = best} end

    return nil
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

--====== Island patrol ======--
local function getIslandPoints()
    local pts = {}
    local wo = Workspace:FindFirstChild("_WorldOrigin")
    local locs = wo and wo:FindFirstChild("Locations")
    if not locs then return pts end
    for _, loc in ipairs(locs:GetChildren()) do
        local part = loc:IsA("BasePart") and loc or loc:FindFirstChildWhichIsA("BasePart", true)
        if part then table.insert(pts, {name = loc.Name, pos = part.Position, scanned = false}) end
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
    local bp = char:WaitForChild("Backpack", 5)
    if bp then watchContainer(bp) end
end)
if character then
    local bp = character:FindFirstChild("Backpack")
    if bp then watchContainer(bp) end
end

--====== MOD MENU GUI (fully draggable) ======--
local function buildMenu()
    local old = playerGui:FindFirstChild("ChestFarmMenu")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ChestFarmMenu"
    gui.ResetOnSpawn = false
    gui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 230, 0, 260)
    frame.Position = UDim2.new(0, 20, 0.5, -130)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, 0, 0, 32)
    title.BackgroundColor3 = Color3.fromRGB(45, 45, 60)
    title.Text = "Chest Farm  |  Sea: " .. SEA
    title.TextColor3 = Color3.new(1,1,1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Active = true
    title.Parent = frame
    Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

    -- drag: attach to frame + title + every button (so dragging works everywhere)
    local dragging, dragStart, startPos = false, nil, nil
    local suppressClick = false
    local function startDrag(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end
    local function onDrag(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                       startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end
    local function endDrag(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            -- moved more than ~8px => it was a drag, suppress the click
            if dragStart then
                suppressClick = (input.Position - dragStart).Magnitude > 8
            end
            dragStart = nil
        end
    end

    frame.InputBegan:Connect(startDrag)
    title.InputBegan:Connect(startDrag)
    UserInputService.InputChanged:Connect(onDrag)
    UserInputService.InputEnded:Connect(endDrag)

    local function makeButton(text, y, color, callback)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.9, 0, 0, 36)
        b.Position = UDim2.new(0.05, 0, 0, y)
        b.BackgroundColor3 = color
        b.Text = text
        b.TextColor3 = Color3.new(1,1,1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 13
        b.Active = true
        b.Parent = frame
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        b.InputBegan:Connect(startDrag)   -- allow drag from buttons too
        b.MouseButton1Click:Connect(function()
            if suppressClick then suppressClick = false return end
            callback()
        end)
        return b
    end

    local y = 42
    for _, dest in ipairs(TP_DESTINATIONS) do
        makeButton("TP: " .. dest.name, y, Color3.fromRGB(60, 90, 160), function()
            _G.ChestFarmEnabled = false
            teleportToKeywords(dest.keywords, dest.name)
            task.delay(2, function() _G.ChestFarmEnabled = true end)
        end)
        y += 42
    end

    makeButton("TP: Safe Zone", y, Color3.fromRGB(60, 140, 90), function()
        _G.ChestFarmEnabled = false
        goToSafeZone()
        task.delay(2, function() _G.ChestFarmEnabled = true end)
    end)
    y += 42

    local farmBtn = makeButton("Farm: ON", y, Color3.fromRGB(160, 60, 60), function()
        _G.ChestFarmEnabled = not _G.ChestFarmEnabled
        farmBtn.Text = _G.ChestFarmEnabled and "Farm: ON" or "Farm: OFF"
        farmBtn.BackgroundColor3 = _G.ChestFarmEnabled
            and Color3.fromRGB(160, 60, 60) or Color3.fromRGB(60, 140, 90)
    end)
    y += 42

    makeButton("Rescan Islands", y, Color3.fromRGB(90, 90, 110), function()
        for _, pt in ipairs(ISLAND_POINTS) do pt.scanned = false end
        pointCooldowns = {}
        discoveryDone = false
        idleCount = 0
    end)
    y += 42

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(0.9, 0, 0, 40)
    status.Position = UDim2.new(0.05, 0, 0, y)
    status.BackgroundTransparency = 1
    status.TextColor3 = Color3.fromRGB(180, 180, 180)
    status.Font = Enum.Font.Gotham
    status.TextSize = 11
    status.TextWrapped = true
    status.Text = "Sea: " .. SEA .. " | Known chests: 0\nDrag anywhere to move"
    status.Parent = frame
    statusLabel = status
end

task.spawn(buildMenu)

--====== MAIN FARM LOOP ======--
print("[ChestFarm] v5 started | Sea: " .. SEA .. " | islands: " .. #ISLAND_POINTS)

while farmRunning do
    -- anti-drown check every loop iteration
    if antiDrown() then
        task.wait(0.3); continue
    end
    updateSafePos()

    if _G.ChestFarmEnabled and not escaped then
        local target = bestChestTarget()
        local h = getChar()
        if h and target then
            idleCount = 0
            if target.kind == "model" then
                stuckPosKey, stuckSince = nil, nil
                local chest = target.data
                local dist = (chest.part.Position - h.Position).Magnitude
                if dist <= OPEN_RANGE then
                    openChest(chest); task.wait(1.5)
                else
                    hopTo(chest.part.Position + Vector3.new(0, 3, 0))
                    task.wait(STREAM_WAIT)
                    -- rescan happens next loop; open if now streamed & close
                    local h2 = getChar()
                    if h2 then
                        local d2 = (chest.part.Position - h2.Position).Magnitude
                        if d2 <= OPEN_RANGE + 5 then
                            openChest(chest); task.wait(1.5)
                        end
                    end
                end
            else
                -- known position, chest may not be streamed yet
                local pos = target.data
                local dist = (pos - h.Position).Magnitude
                local k = posKey(pos)
                if k ~= stuckPosKey then
                    stuckPosKey = k
                    stuckSince = os.clock()
                elseif os.clock() - stuckSince > STUCK_TIMEOUT then
                    -- stuck on a dead/unrespawned chest too long -> server hop
                    stuckPosKey, stuckSince = nil, nil
                    idleCount = 0
                    serverHop()
                end
                if dist <= OPEN_RANGE + 10 then
                    task.wait(STREAM_WAIT)
                else
                    hopTo(pos + Vector3.new(0, 3, 0))
                    task.wait(STREAM_WAIT)
                end
            end
        elseif h then
            -- nothing found: patrol island points to discover chests
            idleCount += 1
            if idleCount >= MAX_IDLE and discoveryDone then
                idleCount = 0
                serverHop()
            elseif #ISLAND_POINTS > 0 then
                -- pick next unscanned point first, else round-robin
                local pt = nil
                for _, p in ipairs(ISLAND_POINTS) do
                    if not p.scanned then pt = p break end
                end
                if not pt then
                    islandIdx = (islandIdx % #ISLAND_POINTS) + 1
                    pt = ISLAND_POINTS[islandIdx]
                end

                local now = os.clock()
                if not pointCooldowns[pt.name] or (now - pointCooldowns[pt.name]) > POINT_COOLDOWN then
                    hopTo(pt.pos)
                    task.wait(STREAM_WAIT)
                    -- mark scanned after a full discovery pass + rescan
                    scanChests()
                    pt.scanned = true
                    pointCooldowns[pt.name] = now
                    task.wait(IDLE_HOP_DELAY)
                    -- check if all points scanned
                    local allDone = true
                    for _, p in ipairs(ISLAND_POINTS) do
                        if not p.scanned then allDone = false break end
                    end
                    if allDone then discoveryDone = true end
                else
                    task.wait(0.5)
                end
            else
                task.wait(1)
            end
        end
    else
        task.wait(0.5)
    end

    -- refresh GUI status label
    if statusLabel then
        local kc = 0
        for _ in pairs(knownChests) do kc += 1 end
        statusLabel.Text = string.format(
            "Sea: %s | Known chests: %d\nIslands scanned: %d/%d%s\nDrag anywhere to move",
            SEA, kc, (function()
                local d = 0
                for _, p in ipairs(ISLAND_POINTS) do if p.scanned then d += 1 end end
                return d
            end)(), #ISLAND_POINTS,
            discoveryDone and " | Discovery done" or "")
    end

    task.wait(0.2)
end
