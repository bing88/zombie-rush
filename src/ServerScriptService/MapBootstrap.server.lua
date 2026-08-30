--[[
	MapBootstrap.server.lua

	Tier 1 map: Lobby (shop + upgrade stalls, safe — no zombies) ->
	Corridor -> Arena (cover crates + dividing walls carving sub-corridors
	+ a hidden secret room), per the Tier 1 checklist ("1 map... cover,
	corridors, shop area, 1 secret"). Still placeholder blocky geometry —
	no art pipeline exists yet, same rationale as Tier 0's baseplate — but
	now laid out with actual level-design intent instead of one flat slab.

	Idempotent: skips building if the "Map" folder already exists (e.g. a
	server soft-restart without a full place reload).

	Everything here is just static geometry + labels/ProximityPrompts.
	Purchase/secret *logic* lives in ShopService, which finds these parts
	by name (Stall_*, SecretDoor) and wires up Triggered handlers.
]]

local Workspace = game:GetService("Workspace")

if Workspace:FindFirstChild("Map") then
	return
end

local map = Instance.new("Folder")
map.Name = "Map"
map.Parent = Workspace

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, options: { [string]: any }?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = Enum.Material.Concrete
	part.Parent = map

	if options then
		if options.Transparency then
			part.Transparency = options.Transparency
		end
		if options.CanCollide ~= nil then
			part.CanCollide = options.CanCollide
		end
		if options.Material then
			part.Material = options.Material
		end
	end

	return part
end

local function makeMarker(name: string, position: Vector3): Part
	local marker = Instance.new("Part")
	marker.Name = name
	marker.Anchored = true
	marker.CanCollide = false
	marker.Transparency = 1
	marker.Size = Vector3.new(4, 1, 4)
	marker.Position = position
	marker.Parent = map
	return marker
end

local function addLabel(part: BasePart, text: string, subText: string?)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(200, 60)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, subText and 0.6 or 1)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.4
	title.Text = text
	title.Parent = billboard

	if subText then
		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.new(1, 0, 0.4, 0)
		sub.Position = UDim2.fromScale(0, 0.6)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.Gotham
		sub.TextScaled = true
		sub.TextColor3 = Color3.fromRGB(255, 220, 100)
		sub.TextStrokeTransparency = 0.4
		sub.Text = subText
		sub.Parent = billboard
	end
end

local function addPrompt(part: BasePart, name: string, actionText: string, objectText: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
end

-- ============================== LOBBY ==============================
-- Safe zone: no zombies ever spawn here (WaveService only spawns in Wave/Boss states, always in the arena).

makePart("LobbyFloor", Vector3.new(50, 2, 50), Vector3.new(0, 0, 0), Color3.fromRGB(65, 65, 72))

local playerSpawn = Instance.new("SpawnLocation")
playerSpawn.Name = "PlayerSpawn"
playerSpawn.Anchored = true
playerSpawn.Size = Vector3.new(8, 1, 8)
playerSpawn.Position = Vector3.new(0, 1.5, -18)
playerSpawn.Transparency = 1
playerSpawn.CanCollide = true
playerSpawn.Duration = 0 -- no forcefield after spawning
playerSpawn.Parent = map

makeMarker("LobbySpawnPoint", Vector3.new(0, 3, -18))

local weaponStalls = {
	{ Name = "Stall_BuyAssaultRifle", Position = Vector3.new(-18, 2.5, -20), Title = "Assault Rifle", Price = 150 },
	{ Name = "Stall_BuyShotgun", Position = Vector3.new(-18, 2.5, -8), Title = "Shotgun", Price = 300 },
}
for _, data in weaponStalls do
	local podium = makePart(data.Name, Vector3.new(4, 3, 4), data.Position, Color3.fromRGB(60, 90, 140))
	addLabel(podium, data.Title, data.Price .. " coins")
	addPrompt(podium, "Buy", "Buy", data.Title .. " — " .. data.Price .. " coins")
end

local upgradeStalls = {
	{ Name = "Stall_UpgradePistol", Position = Vector3.new(18, 2.5, -20), Title = "Pistol Upgrade" },
	{ Name = "Stall_UpgradeAssaultRifle", Position = Vector3.new(18, 2.5, -8), Title = "AR Upgrade" },
	{ Name = "Stall_UpgradeShotgun", Position = Vector3.new(18, 2.5, 4), Title = "Shotgun Upgrade" },
}
for _, data in upgradeStalls do
	local podium = makePart(data.Name, Vector3.new(4, 3, 4), data.Position, Color3.fromRGB(140, 110, 40))
	addLabel(podium, data.Title, "Upgrade")
	addPrompt(podium, "Upgrade", "Upgrade", data.Title)
end

-- ============================== CORRIDOR ==============================

makePart("CorridorFloor", Vector3.new(10, 2, 50), Vector3.new(0, 0, 50), Color3.fromRGB(55, 55, 60))
makePart("CorridorWallLeft", Vector3.new(1, 8, 50), Vector3.new(-5, 4, 50), Color3.fromRGB(45, 45, 50))
makePart("CorridorWallRight", Vector3.new(1, 8, 50), Vector3.new(5, 4, 50), Color3.fromRGB(45, 45, 50))

-- ============================== ARENA ==============================

makePart("ArenaFloor", Vector3.new(110, 2, 110), Vector3.new(0, 0, 150), Color3.fromRGB(70, 60, 55))

makeMarker("ArenaSpawnPoint", Vector3.new(0, 3, 105))

-- Cover crates scattered through the arena so gunfights aren't just kiting across open ground.
local coverPositions = {
	Vector3.new(-25, 3, 120), Vector3.new(20, 3, 115), Vector3.new(0, 3, 138),
	Vector3.new(-15, 3, 158), Vector3.new(35, 3, 165), Vector3.new(-38, 3, 178),
	Vector3.new(15, 3, 188), Vector3.new(-5, 3, 200), Vector3.new(42, 3, 130),
	Vector3.new(-45, 3, 145),
}
for i, position in coverPositions do
	makePart("CoverCrate" .. i, Vector3.new(4, 4, 4), position, Color3.fromRGB(110, 85, 55), { Material = Enum.Material.WoodPlanks })
end

-- Low dividing walls carve the open arena into flankable sub-corridors.
makePart("ArenaWall1", Vector3.new(2, 6, 30), Vector3.new(-30, 3, 150), Color3.fromRGB(60, 55, 60))
makePart("ArenaWall2", Vector3.new(2, 6, 30), Vector3.new(30, 3, 170), Color3.fromRGB(60, 55, 60))
makePart("ArenaWall3", Vector3.new(30, 6, 2), Vector3.new(0, 3, 195), Color3.fromRGB(60, 55, 60))

-- Zombie spawn ring around the arena perimeter.
local zombieSpawns = Instance.new("Folder")
zombieSpawns.Name = "ZombieSpawns"
zombieSpawns.Parent = Workspace
local SPAWN_RING_RADIUS = 50
local SPAWN_COUNT = 10
for i = 1, SPAWN_COUNT do
	local angle = (i / SPAWN_COUNT) * math.pi * 2
	local position = Vector3.new(math.cos(angle) * SPAWN_RING_RADIUS, 3, 150 + math.sin(angle) * SPAWN_RING_RADIUS)
	local point = Instance.new("Part")
	point.Name = "SpawnPoint" .. i
	point.Anchored = true
	point.CanCollide = false
	point.Transparency = 1
	point.Size = Vector3.new(2, 1, 2)
	point.Position = position
	point.Parent = zombieSpawns
end

-- ============================== SECRET ==============================
-- A hidden button (behind a crate, easy to miss) opens SecretDoor, revealing a one-time coin stash.

makePart("SecretRoomFloor", Vector3.new(20, 2, 20), Vector3.new(65, 0, 150), Color3.fromRGB(40, 35, 60))
makePart("SecretRoomWallBack", Vector3.new(2, 8, 20), Vector3.new(75, 4, 150), Color3.fromRGB(35, 30, 50))
makePart("SecretRoomWallLeft", Vector3.new(20, 8, 2), Vector3.new(65, 4, 140), Color3.fromRGB(35, 30, 50))
makePart("SecretRoomWallRight", Vector3.new(20, 8, 2), Vector3.new(65, 4, 160), Color3.fromRGB(35, 30, 50))

makePart("SecretDoor", Vector3.new(2, 8, 16), Vector3.new(55, 4, 150), Color3.fromRGB(90, 40, 40))

local secretButton = makePart("Stall_SecretButton", Vector3.new(1.5, 1.5, 1.5), Vector3.new(-40, 3, 128), Color3.fromRGB(30, 30, 35))
addLabel(secretButton, "???")
addPrompt(secretButton, "Investigate", "Investigate", "A strange button, half-buried behind the crate.")

local secretCache = makePart("Stall_SecretCache", Vector3.new(3, 3, 3), Vector3.new(70, 2.5, 150), Color3.fromRGB(220, 180, 40), { Material = Enum.Material.Neon })
addLabel(secretCache, "Secret Stash")
addPrompt(secretCache, "Claim", "Claim", "Secret Stash")

-- ============================== BOUNDARY ==============================
-- Invisible walls around the whole level so players/zombies can't wander off the edge into the void.

local BOUNDARY_MIN_X, BOUNDARY_MAX_X = -65, 85
local BOUNDARY_MIN_Z, BOUNDARY_MAX_Z = -30, 210
local boundaryWidth = BOUNDARY_MAX_X - BOUNDARY_MIN_X
local boundaryDepth = BOUNDARY_MAX_Z - BOUNDARY_MIN_Z
local boundaryCenterX = (BOUNDARY_MIN_X + BOUNDARY_MAX_X) / 2
local boundaryCenterZ = (BOUNDARY_MIN_Z + BOUNDARY_MAX_Z) / 2

makePart("BoundaryNorth", Vector3.new(boundaryWidth, 40, 2), Vector3.new(boundaryCenterX, 15, BOUNDARY_MAX_Z), Color3.new(), { Transparency = 1 })
makePart("BoundarySouth", Vector3.new(boundaryWidth, 40, 2), Vector3.new(boundaryCenterX, 15, BOUNDARY_MIN_Z), Color3.new(), { Transparency = 1 })
makePart("BoundaryEast", Vector3.new(2, 40, boundaryDepth), Vector3.new(BOUNDARY_MAX_X, 15, boundaryCenterZ), Color3.new(), { Transparency = 1 })
makePart("BoundaryWest", Vector3.new(2, 40, boundaryDepth), Vector3.new(BOUNDARY_MIN_X, 15, boundaryCenterZ), Color3.new(), { Transparency = 1 })
