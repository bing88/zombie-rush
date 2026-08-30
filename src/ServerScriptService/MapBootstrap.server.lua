--[[
	MapBootstrap.server.lua

	Tier 1 map: Lobby (shop + upgrade stalls, teleport pad, safe — no
	zombies) -> Corridor -> Arena (cover crates/barrels + dividing walls
	carving sub-corridors + a raised catwalk for verticality), per the
	Tier 1 checklist ("1 map... cover, corridors, shop area"). Still
	placeholder blocky geometry — no art pipeline exists yet, same
	rationale as Tier 0's baseplate — but laid out with actual
	level-design intent instead of one flat slab, plus basic
	Lighting-service atmosphere (dusk, fog, ambient tint).

	Idempotent: skips building if the "Map" folder already exists (e.g. a
	server soft-restart without a full place reload).

	Everything here is just static geometry + labels/ProximityPrompts.
	Purchase logic lives in ShopService; match-start logic (the teleport
	pad) lives in WaveService — both find these parts by name (Stall_*)
	and wire up Triggered handlers.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

if Workspace:FindFirstChild("Map") then
	return
end

-- Atmosphere: a bit darker/moodier than default Roblox daylight, matching
-- a "zombie outbreak at dusk" tone without needing any custom skybox
-- assets. Cheap and safe — purely Lighting-service property tweaks.
Lighting.Brightness = 1.4
Lighting.OutdoorAmbient = Color3.fromRGB(45, 48, 60)
Lighting.Ambient = Color3.fromRGB(35, 35, 42)
Lighting.ClockTime = 19.5 -- dusk
Lighting.FogEnd = 400
Lighting.FogColor = Color3.fromRGB(40, 42, 55)

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

local function addPointLight(part: BasePart, color: Color3, brightness: number?, range: number?)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness or 2
	light.Range = range or 16
	light.Parent = part
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

-- Lobby landmark: a simple abstract monument between spawn and the
-- teleport pad, purely decorative — gives the lobby a focal point
-- instead of just being a flat room with stalls around the edges.
-- Small footprint so it doesn't block the walk path in a 50x50 room.
local monumentBase = makePart("MonumentBase", Vector3.new(4, 1, 4), Vector3.new(0, 0.5, -6), Color3.fromRGB(50, 50, 55))
local monumentPillar = makePart("MonumentPillar", Vector3.new(1.5, 6, 1.5), Vector3.new(0, 4, -6), Color3.fromRGB(80, 80, 88))
local monumentTop = Instance.new("Part")
monumentTop.Name = "MonumentTop"
monumentTop.Shape = Enum.PartType.Ball
monumentTop.Anchored = true
monumentTop.Size = Vector3.new(2.5, 2.5, 2.5)
monumentTop.Position = Vector3.new(0, 8.5, -6)
monumentTop.Material = Enum.Material.Neon
monumentTop.Color = Color3.fromRGB(90, 220, 130)
monumentTop.Parent = map
addPointLight(monumentTop, Color3.fromRGB(90, 220, 130), 3, 24)
addLabel(monumentPillar, "ZOMBIE RUSH")

local weaponStalls = {
	{ Name = "Stall_BuyAssaultRifle", Position = Vector3.new(-18, 2.5, -20), Title = "Assault Rifle", Price = 150 },
	{ Name = "Stall_BuyShotgun", Position = Vector3.new(-18, 2.5, -8), Title = "Shotgun", Price = 300 },
}
for _, data in weaponStalls do
	local podium = makePart(data.Name, Vector3.new(4, 3, 4), data.Position, Color3.fromRGB(60, 90, 140))
	addLabel(podium, data.Title, data.Price .. " coins")
	addPrompt(podium, "Buy", "Buy", data.Title .. " — " .. data.Price .. " coins")
	addPointLight(podium, Color3.fromRGB(100, 150, 255), 2, 14)
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
	addPointLight(podium, Color3.fromRGB(255, 200, 100), 2, 14)
end

-- Teleport pad: stepping up and confirming is what actually starts a
-- match (see WaveService) — the lobby no longer auto-starts just because
-- a player is present. Glowing neon disc, hard to miss, center of the
-- lobby a short walk from the stalls.
local teleportPad = makePart(
	"Stall_TeleportPad",
	Vector3.new(10, 1, 10),
	Vector3.new(0, 0.5, 5),
	Color3.fromRGB(60, 200, 220),
	{ Material = Enum.Material.Neon }
)
addLabel(teleportPad, "START MATCH", "Step here")
addPrompt(teleportPad, "StartMatch", "Start Match", "Teleporter")
addPointLight(teleportPad, Color3.fromRGB(60, 200, 220), 4, 20)

-- ============================== CORRIDOR ==============================

makePart("CorridorFloor", Vector3.new(10, 2, 50), Vector3.new(0, 0, 50), Color3.fromRGB(55, 55, 60))
makePart("CorridorWallLeft", Vector3.new(1, 8, 50), Vector3.new(-5, 4, 50), Color3.fromRGB(45, 45, 50))
makePart("CorridorWallRight", Vector3.new(1, 8, 50), Vector3.new(5, 4, 50), Color3.fromRGB(45, 45, 50))

-- A few overhead light fixtures so the corridor isn't a dark tunnel
-- between the lit lobby and arena.
local corridorLightPositions = { Vector3.new(0, 7.5, 25), Vector3.new(0, 7.5, 50), Vector3.new(0, 7.5, 75) }
for i, position in corridorLightPositions do
	local fixture = makePart("CorridorLight" .. i, Vector3.new(2, 0.5, 2), position, Color3.fromRGB(255, 240, 200), { Material = Enum.Material.Neon })
	addPointLight(fixture, Color3.fromRGB(255, 235, 190), 2, 18)
end

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

-- Extra cover reclaiming the space east of the arena (previously a
-- secret room) — barrels instead of crates for visual variety, plus a
-- couple of stacked pairs for partial cover you can peek over.
local barrelPositions = {
	Vector3.new(60, 3, 130), Vector3.new(70, 3, 145), Vector3.new(55, 3, 160),
	Vector3.new(68, 3, 175), Vector3.new(48, 3, 185), Vector3.new(75, 3, 120),
}
for i, position in barrelPositions do
	local barrel = Instance.new("Part")
	barrel.Name = "CoverBarrel" .. i
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Anchored = true
	barrel.Size = Vector3.new(4, 3, 3)
	barrel.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	barrel.Color = Color3.fromRGB(120, 90, 40)
	barrel.Material = Enum.Material.Metal
	barrel.Parent = map
end

-- Catwalk: a raised platform reachable by ramps on both ends, giving the
-- arena a vertical option (per the original plan's "vertical areas"
-- design goal) instead of everything happening at ground level. High
-- ground for players, and a longer sightline for picking off zombies
-- approaching from the north spawn ring.
local CATWALK_HEIGHT = 10
makePart("CatwalkPlatform", Vector3.new(16, 1, 10), Vector3.new(0, CATWALK_HEIGHT, 175), Color3.fromRGB(70, 70, 78))
makePart("CatwalkRailingLeft", Vector3.new(16, 3, 0.5), Vector3.new(0, CATWALK_HEIGHT + 2, 170.25), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })
makePart("CatwalkRailingRight", Vector3.new(16, 3, 0.5), Vector3.new(0, CATWALK_HEIGHT + 2, 179.75), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })

local function makeRamp(name: string, position: Vector3, rotationY: number)
	-- NOTE: WedgePart's slope direction depends on Roblox's default local
	-- axis convention, which isn't something I can visually verify from
	-- here. This is a best-effort placement — if the ramp looks inverted
	-- or players can't actually walk up it in Studio, try rotationY + 180
	-- for that ramp, or swap which face Size.Z faces.
	local ramp = Instance.new("WedgePart")
	ramp.Name = name
	ramp.Anchored = true
	ramp.Size = Vector3.new(6, CATWALK_HEIGHT, 12)
	ramp.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(rotationY), 0)
	ramp.Color = Color3.fromRGB(70, 70, 78)
	ramp.Material = Enum.Material.Concrete
	ramp.Parent = map
end

-- One ramp up from the south (near ArenaWall3) so it's reachable while
-- fighting through that sub-corridor, one from the north for a second
-- approach so it's not a single-file chokepoint.
makeRamp("CatwalkRampSouth", Vector3.new(0, CATWALK_HEIGHT / 2, 187), 180)
makeRamp("CatwalkRampNorth", Vector3.new(0, CATWALK_HEIGHT / 2, 163), 0)

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
