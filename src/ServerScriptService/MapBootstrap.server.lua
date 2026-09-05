--[[
	MapBootstrap.server.lua

	Tier 1 map: Lobby (portals + landmark, safe — no zombies) and Arena,
	per the Tier 1 checklist. The two are sealed off from each other —
	no walkable path between them — since the portals (see WaveService)
	are the only way a match actually starts. Weapon buy/upgrade used to
	be physical lobby stalls; those are gone because purchases are now
	per-run and happen from the in-match U panel (see ShopService).

	Both the lobby and the arena now load real provided assets instead
	of placeholder blocky geometry, each via the same pattern: a synced-
	in local .rbxm (see below) as the primary source, falling back to a
	hand-built procedural version if that's ever missing or turns out to
	contain no usable geometry — so the bootstrap never leaves the map
	half-built. The **lobby** uses the "Lobby" sub-model out of the
	"Game Lobby" kit (see loadGameLobbyArena), synced in from
	src/ServerStorage/MapAssets/Game_Lobby.rbxm; every functional lobby
	fixture (spawn, monument, match portals) is
	positioned relative to — and scaled to fit — whichever lobby
	actually got built, rather than assuming a fixed size. The **arena**
	uses the "L4D Subway Map" community asset (see loadSubwayMapArena),
	synced in from src/ServerStorage/MapAssets/L4D_Subway_Map.rbxm — no
	live AssetService:LoadAssetAsync call needed for either asset in the
	common case (that's kept only as a secondary fallback if a local
	file is ever missing). Plus basic Lighting-service atmosphere (dusk,
	fog, ambient tint).

	Idempotent: skips building if the "Map" folder already exists (e.g. a
	server soft-restart without a full place reload).

	Everything here is just static geometry + labels/ProximityPrompts.
	Match-start logic (the portals) lives in WaveService.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local PathfindingService = game:GetService("PathfindingService")

if Workspace:FindFirstChild("Map") then
	return
end

-- Atmosphere: a bit moodier than default Roblox daylight, matching a
-- "zombie outbreak at dusk" tone, but bright enough that the arena is
-- actually readable — gameplay visibility wins over mood here. Combined
-- with real light fixtures scattered through the lobby/corridor/arena
-- below rather than relying on ambient light alone.
Lighting.Brightness = 3
Lighting.OutdoorAmbient = Color3.fromRGB(90, 95, 115)
Lighting.Ambient = Color3.fromRGB(70, 72, 90)
Lighting.ClockTime = 18.3 -- early dusk, noticeably brighter than full night
Lighting.FogEnd = 550
Lighting.FogColor = Color3.fromRGB(60, 63, 80)

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
	-- AlwaysOnTop=false (respects wall occlusion) + a distance cap: these
	-- were previously rendering through walls and from clear across the
	-- map (every stall/monument label visible simultaneously, all
	-- crammed into the same screen space at long range) — this ties
	-- every label to actually being near, and able to see, its own part.
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 45
	billboard.Parent = part

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, subText and 0.6 or 1)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.4
	title.Name = "Title"
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
		sub.Name = "SubText"
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

--[[
	Original hand-built lobby (flat floor slab + 4 solid perimeter
	walls) — kept as the fallback for loadGameLobbyArena() below, the
	same role buildProceduralArenaFallback plays for the arena. Returns
	the lobby's world-space horizontal center at floor height (Y = 1)
	and its (X, Y, Z) extents, matching that same convention, so every
	functional lobby fixture below (spawn, stalls, monument, teleport
	pad) can be positioned relative to it regardless of which lobby
	actually got built.
]]
local function buildProceduralLobbyFallback(): (Vector3, Vector3)
	makePart("LobbyFloor", Vector3.new(50, 2, 50), Vector3.new(0, 0, 0), Color3.fromRGB(65, 65, 72))

	local LOBBY_WALL_HEIGHT = 12
	local lobbyWallColor = Color3.fromRGB(50, 50, 58)
	makePart("LobbyWallSouth", Vector3.new(50, LOBBY_WALL_HEIGHT, 1), Vector3.new(0, LOBBY_WALL_HEIGHT / 2, -25), lobbyWallColor)
	makePart("LobbyWallWest", Vector3.new(1, LOBBY_WALL_HEIGHT, 50), Vector3.new(-25, LOBBY_WALL_HEIGHT / 2, 0), lobbyWallColor)
	makePart("LobbyWallEast", Vector3.new(1, LOBBY_WALL_HEIGHT, 50), Vector3.new(25, LOBBY_WALL_HEIGHT / 2, 0), lobbyWallColor)
	makePart("LobbyWallNorth", Vector3.new(50, LOBBY_WALL_HEIGHT, 1), Vector3.new(0, LOBBY_WALL_HEIGHT / 2, 25), lobbyWallColor)

	return Vector3.new(0, 1, 0), Vector3.new(50, LOBBY_WALL_HEIGHT, 50)
end

-- "Game Lobby" asset, provided directly as
-- src/ServerStorage/MapAssets/Game_Lobby.rbxm, synced in by Rojo at
-- ServerStorage.MapAssets.Game_Lobby. Verified by reading the file
-- directly: it's a big multi-purpose kit — 2 police cars w/ lightbars +
-- sirens, a gate, a road/tunnel test track, ~30 repeated barrier "Wall"
-- pieces, its own scripted systems (steering, gate triggers, siren/
-- light toggles) — bundled alongside the actual lobby building, which
-- is its own child Model specifically named "Lobby". Only that one
-- child is used below; everything else in the kit (vehicles, gate,
-- road, tunnel, and all of its scripts) is ignored entirely.
--
-- Currently off: the kit is heavy and Rojo-deserializes noisily; use
-- the procedural lobby until we're ready to bring the real building back.
local USE_GAME_LOBBY_ASSET = false
local GAME_LOBBY_CHILD_NAME = "Lobby"

local function getLocalGameLobbyTemplate(): Model?
	local mapAssets = ServerStorage:FindFirstChild("MapAssets")
	local kit = mapAssets and mapAssets:FindFirstChild("Game_Lobby")
	local lobbyPiece = kit and kit:FindFirstChild(GAME_LOBBY_CHILD_NAME, true)
	if not lobbyPiece or not lobbyPiece:IsA("Model") then
		return nil
	end
	return lobbyPiece:Clone()
end

--[[
	Loads the Game_Lobby asset's "Lobby" sub-model to use instead of
	buildProceduralLobbyFallback() above. Same defensive pattern as
	loadSubwayMapArena: strips any Script/LocalScript, force-Anchors
	every part, and — since there's no reliable signal for which way it
	"faces" or how big it really is — does a translate-only move so its
	bounding box's bottom-center sits at the world origin (floor Y = 1),
	then reports its real size back so every fixture below (spawn,
	stalls, monument, teleport pad) can scale its position to actually
	land inside it instead of assuming the old fixed 50x50 footprint.
	Falls back to the procedural lobby if the local asset is missing,
	the "Lobby" child isn't found inside it, or it turns out to contain
	no usable geometry.
]]
local function loadGameLobbyArena(): (Model?, Vector3?, Vector3?)
	local template = getLocalGameLobbyTemplate()
	if not template then
		warn("MapBootstrap: no usable 'Lobby' model found in ServerStorage.MapAssets.Game_Lobby — falling back to the built-in procedural lobby.")
		return nil, nil, nil
	end

	local partCount = 0
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Archivable = true
			partCount += 1
		end
	end

	if partCount == 0 then
		warn("MapBootstrap: Game_Lobby's 'Lobby' model contained no usable parts — falling back to the built-in procedural lobby.")
		template:Destroy()
		return nil, nil, nil
	end

	template.Name = "GameLobbyBuilding"
	template.Archivable = true

	local boundingOk, boundingCFrame, boundingSize = pcall(function()
		return template:GetBoundingBox()
	end)
	if not boundingOk then
		warn(("MapBootstrap: Game_Lobby's 'Lobby' model GetBoundingBox() failed (%s) — falling back to the built-in procedural lobby."):format(tostring(boundingCFrame)))
		template:Destroy()
		return nil, nil, nil
	end

	local currentBottomCenter = boundingCFrame.Position - Vector3.new(0, boundingSize.Y / 2, 0)
	local targetFloorCenter = Vector3.new(0, 1, 0)
	local delta = targetFloorCenter - currentBottomCenter
	template:PivotTo(template:GetPivot() + delta)
	template.Parent = map

	return template, targetFloorCenter, boundingSize
end

local lobbyModel, lobbyWorldCenter, lobbyWorldSize
if USE_GAME_LOBBY_ASSET then
	lobbyModel, lobbyWorldCenter, lobbyWorldSize = loadGameLobbyArena()
end
if not lobbyModel then
	lobbyWorldCenter, lobbyWorldSize = buildProceduralLobbyFallback()
end
assert(lobbyWorldCenter and lobbyWorldSize)

-- Every fixture below was originally designed for the procedural
-- lobby's fixed 50x50 footprint (half-extent 25 on both axes) — scaled
-- here so they still land inside whichever lobby actually got built
-- above instead of assuming that exact size. Clamped so a wildly
-- small/large real asset doesn't push fixtures absurdly close together
-- or out past its walls. Still just a best-effort fit — verify in
-- Studio that nothing lands inside a wall/pillar of the real building.
local LOBBY_REFERENCE_HALF_EXTENT = 25
local lobbyScaleX = math.clamp((lobbyWorldSize.X / 2) / LOBBY_REFERENCE_HALF_EXTENT, 0.4, 3)
local lobbyScaleZ = math.clamp((lobbyWorldSize.Z / 2) / LOBBY_REFERENCE_HALF_EXTENT, 0.4, 3)

local function lobbyPoint(offsetX: number, height: number, offsetZ: number): Vector3
	return lobbyWorldCenter + Vector3.new(offsetX * lobbyScaleX, height, offsetZ * lobbyScaleZ)
end

local playerSpawnPosition = lobbyPoint(0, 0.5, -18)
local playerSpawn = Instance.new("SpawnLocation")
playerSpawn.Name = "PlayerSpawn"
playerSpawn.Anchored = true
playerSpawn.Size = Vector3.new(8, 1, 8)
playerSpawn.Position = playerSpawnPosition
playerSpawn.Transparency = 1
playerSpawn.CanCollide = true
playerSpawn.Duration = 0 -- no forcefield after spawning
playerSpawn.Parent = map

makeMarker("LobbySpawnPoint", playerSpawnPosition + Vector3.new(0, 1.5, 0))

-- Lobby landmark: a simple abstract monument between spawn and the
-- teleport pad, purely decorative — gives the lobby a focal point
-- instead of just being a flat room with stalls around the edges.
local monumentBase = makePart("MonumentBase", Vector3.new(4, 1, 4), lobbyPoint(0, 0.5, -6), Color3.fromRGB(50, 50, 55))
local monumentPillar = makePart("MonumentPillar", Vector3.new(1.5, 6, 1.5), lobbyPoint(0, 4, -6), Color3.fromRGB(80, 80, 88))
local monumentTop = Instance.new("Part")
monumentTop.Name = "MonumentTop"
monumentTop.Shape = Enum.PartType.Ball
monumentTop.Anchored = true
monumentTop.Size = Vector3.new(2.5, 2.5, 2.5)
monumentTop.Position = lobbyPoint(0, 8.5, -6)
monumentTop.Material = Enum.Material.Neon
monumentTop.Color = Color3.fromRGB(90, 220, 130)
monumentTop.Parent = map
addPointLight(monumentTop, Color3.fromRGB(90, 220, 130), 3, 24)
addLabel(monumentPillar, "ZOMBIE RUSH")

-- One reminder instead of the old five buy/upgrade stalls. Purchases
-- reset every run and happen from the U panel mid-match, so a lobby
-- shop would be selling things that vanish the moment the portal
-- countdown finishes. The sign just tells people where the shop went.
local armorySign = makePart("ArmorySign", Vector3.new(5, 3, 1.2), lobbyPoint(0, 2.5, -20), Color3.fromRGB(50, 70, 90))
addLabel(armorySign, "ARMORY", "Press U during a match")
addPointLight(armorySign, Color3.fromRGB(100, 160, 220), 2, 14)

-- Four match portals. Interacting with one opens a party-size picker
-- (1-4 players); the host's choice decides whether the match starts on a
-- short solo countdown or waits for others to join by stepping onto the
-- SAME portal. See WaveService for the lobby/party state machine.
--
-- Four separate portals rather than one shared pad so concurrent groups
-- have somewhere distinct to gather, and so a portal's own label can
-- show that portal's live "joined / needed" count.
local PORTAL_COUNT = 4
local PORTAL_COLORS = {
	Color3.fromRGB(60, 200, 220),
	Color3.fromRGB(120, 220, 120),
	Color3.fromRGB(230, 180, 90),
	Color3.fromRGB(210, 120, 230),
}
local portalsFolder = Instance.new("Folder")
portalsFolder.Name = "MatchPortals"
portalsFolder.Parent = map

for i = 1, PORTAL_COUNT do
	-- Spread along the lobby's x axis, a short walk in front of the stalls.
	local offsetX = (i - (PORTAL_COUNT + 1) / 2) * 9
	local color = PORTAL_COLORS[i]
	local portal = makePart(
		"MatchPortal" .. i,
		Vector3.new(7, 1, 7),
		lobbyPoint(offsetX, 0.5, 5),
		color,
		{ Material = Enum.Material.Neon }
	)
	portal.Parent = portalsFolder
	-- Label starts blank and is only filled in by WaveService while a
	-- party is forming here ("2 / 4 joined") — a permanent "PORTAL 1 /
	-- Step here" caption was just visual noise once the portals are
	-- self-evidently interactable.
	addLabel(portal, "", "")
	addPrompt(portal, "StartMatch", "Open Portal", ("Portal %d"):format(i))
	addPointLight(portal, color, 4, 18)

	-- Invisible barrier ringing the pad: players can't simply walk in,
	-- they're teleported inside on joining the party (see WaveService)
	-- and teleported back out if they leave. Without this, someone could
	-- wander into the staging area without ever being added to a party,
	-- which reads as "I'm standing in the portal but the match ignores
	-- me". Teleports aren't affected by collision, so this only blocks
	-- walking.
	local barrierHeight = 10
	local halfSpan = 4 -- pad is 7 wide; barrier sits just outside it
	local barrierSpecs = {
		{ size = Vector3.new(8, barrierHeight, 1), offset = Vector3.new(0, barrierHeight / 2, halfSpan) },
		{ size = Vector3.new(8, barrierHeight, 1), offset = Vector3.new(0, barrierHeight / 2, -halfSpan) },
		{ size = Vector3.new(1, barrierHeight, 8), offset = Vector3.new(halfSpan, barrierHeight / 2, 0) },
		{ size = Vector3.new(1, barrierHeight, 8), offset = Vector3.new(-halfSpan, barrierHeight / 2, 0) },
	}
	for wallIndex, spec in barrierSpecs do
		local wall = makePart(
			("MatchPortal%dBarrier%d"):format(i, wallIndex),
			spec.size,
			lobbyPoint(offsetX, 0.5, 5) + spec.offset,
			color,
			{ Transparency = 1, CanCollide = true }
		)
		wall.Parent = portalsFolder
	end
end

-- Match starts via the teleport pad now (see WaveService), not by
-- walking from the lobby into the arena — the corridor that used to
-- physically connect them served no purpose once that changed and was
-- removed. LOBBY_ARENA_BOUNDARY_Z is kept as a plain reference value
-- (not real geometry) purely because the fall-safety-net recovery logic
-- further down still needs a Z threshold to guess "were they in the
-- lobby or the arena" when someone falls through the map — now derived
-- from the lobby's real far edge (whichever lobby actually got built)
-- plus a fixed gap, instead of a fixed 95, and loadSubwayMapArena below
-- uses it the same way to place the arena just past that edge.
local LOBBY_ARENA_GAP = 20
local LOBBY_ARENA_BOUNDARY_Z = lobbyWorldCenter.Z + lobbyWorldSize.Z / 2 + LOBBY_ARENA_GAP

-- ============================== ARENA ==============================
-- Target footprint used as the placement target below regardless of
-- which arena actually ends up getting built — X widened east (vs. a
-- symmetric range) purely so the procedural fallback's CoverBarrel
-- cluster (placed as far out as X = 75) has floor underneath it. Z
-- starts right at LOBBY_ARENA_BOUNDARY_Z (just past whichever lobby
-- actually got built above) instead of a fixed 95, so it can't end up
-- overlapping a much bigger real lobby asset.
local ARENA_X_MIN, ARENA_X_MAX = -55, 80
local ARENA_Z_MIN, ARENA_Z_MAX = LOBBY_ARENA_BOUNDARY_Z, LOBBY_ARENA_BOUNDARY_Z + 110
local arenaWidth = ARENA_X_MAX - ARENA_X_MIN
local arenaDepth = ARENA_Z_MAX - ARENA_Z_MIN
local arenaCenterX = (ARENA_X_MIN + ARENA_X_MAX) / 2
local arenaCenterZ = (ARENA_Z_MIN + ARENA_Z_MAX) / 2

--[[
	The original hand-built arena (cover crates/barrels, dividing walls,
	a raised catwalk with ramps + railings, its own perimeter walls) —
	kept intact as the fallback for loadSubwayMapArena() below, since
	that loads an unknown community asset that might fail to load or
	turn out not to actually contain usable geometry.

	Returns the arena's world-space horizontal center at floor height
	(Y = 1, matching every other floor's top surface) and its (X, Y, Z)
	extents, so the caller can place ArenaSpawnPoint/ZombieSpawns and
	size the outer boundary the same way regardless of which arena
	actually got built.
]]
local function buildProceduralArenaFallback(): (Vector3, Vector3)
	makePart("ArenaFloor", Vector3.new(arenaWidth, 2, arenaDepth), Vector3.new(arenaCenterX, 0, arenaCenterZ), Color3.fromRGB(70, 60, 55))

	-- Overhead lamp posts spread across the arena floor — a 3x3 grid
	-- rather than one central light so there's no single dark corner,
	-- including out toward the widened east edge where the CoverBarrel
	-- cluster sits.
	local arenaLampPositions = {
		Vector3.new(-40, 0, 115), Vector3.new(10, 0, 115), Vector3.new(60, 0, 115),
		Vector3.new(-40, 0, 150), Vector3.new(10, 0, 150), Vector3.new(60, 0, 150),
		Vector3.new(-40, 0, 190), Vector3.new(10, 0, 190), Vector3.new(60, 0, 190),
	}
	for i, basePosition in arenaLampPositions do
		makePart(
			"ArenaLampPost" .. i,
			Vector3.new(0.6, 10, 0.6),
			basePosition + Vector3.new(0, 5, 0),
			Color3.fromRGB(40, 40, 45)
		)
		local fixture = Instance.new("Part")
		fixture.Name = "ArenaLampHead" .. i
		fixture.Shape = Enum.PartType.Ball
		fixture.Anchored = true
		fixture.CanCollide = false
		fixture.Size = Vector3.new(1.4, 1.4, 1.4)
		fixture.Position = basePosition + Vector3.new(0, 10, 0)
		fixture.Material = Enum.Material.Neon
		fixture.Color = Color3.fromRGB(255, 238, 200)
		fixture.Parent = map
		addPointLight(fixture, Color3.fromRGB(255, 232, 190), 3, 32)
	end

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

	-- Extra cover reclaiming the space east of the arena — barrels
	-- instead of crates for visual variety, plus a couple of stacked
	-- pairs for partial cover you can peek over.
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

	-- Catwalk: a raised platform reachable by ramps on both ends, giving
	-- the arena a vertical option instead of everything happening at
	-- ground level.
	local CATWALK_HEIGHT = 10
	local catwalkPlatform = makePart("CatwalkPlatform", Vector3.new(16, 1, 10), Vector3.new(0, CATWALK_HEIGHT, 175), Color3.fromRGB(70, 70, 78))
	addPointLight(catwalkPlatform, Color3.fromRGB(150, 200, 255), 2, 22)
	makePart("CatwalkRailingLeft", Vector3.new(16, 3, 0.5), Vector3.new(0, CATWALK_HEIGHT + 2, 170.25), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })
	makePart("CatwalkRailingRight", Vector3.new(16, 3, 0.5), Vector3.new(0, CATWALK_HEIGHT + 2, 179.75), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })
	makePart("CatwalkRailingWest", Vector3.new(0.5, 3, 10), Vector3.new(-8.25, CATWALK_HEIGHT + 2, 175), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })
	makePart("CatwalkRailingEast", Vector3.new(0.5, 3, 10), Vector3.new(8.25, CATWALK_HEIGHT + 2, 175), Color3.fromRGB(50, 50, 56), { Transparency = 0.4 })

	local function makeRamp(name: string, position: Vector3, rotationY: number)
		local ramp = Instance.new("WedgePart")
		ramp.Name = name
		ramp.Anchored = true
		ramp.Size = Vector3.new(6, CATWALK_HEIGHT, 12)
		ramp.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(rotationY), 0)
		ramp.Color = Color3.fromRGB(70, 70, 78)
		ramp.Material = Enum.Material.Concrete
		ramp.Parent = map
	end

	makeRamp("CatwalkRampSouth", Vector3.new(0, CATWALK_HEIGHT / 2, 187), 180)
	makeRamp("CatwalkRampNorth", Vector3.new(0, CATWALK_HEIGHT / 2, 163), 0)

	-- Perimeter walls flush with the arena floor's actual edges, solid on all 4 sides.
	local ARENA_WALL_HEIGHT = 16
	local arenaWallColor = Color3.fromRGB(55, 50, 55)
	makePart("ArenaWallSouth", Vector3.new(arenaWidth, ARENA_WALL_HEIGHT, 1), Vector3.new(arenaCenterX, ARENA_WALL_HEIGHT / 2, LOBBY_ARENA_BOUNDARY_Z), arenaWallColor)
	makePart("ArenaWallNorth", Vector3.new(arenaWidth, ARENA_WALL_HEIGHT, 1), Vector3.new(arenaCenterX, ARENA_WALL_HEIGHT / 2, ARENA_Z_MAX), arenaWallColor)
	makePart("ArenaWallWest", Vector3.new(1, ARENA_WALL_HEIGHT, arenaDepth), Vector3.new(ARENA_X_MIN, ARENA_WALL_HEIGHT / 2, arenaCenterZ), arenaWallColor)
	makePart("ArenaWallEast", Vector3.new(1, ARENA_WALL_HEIGHT, arenaDepth), Vector3.new(ARENA_X_MAX, ARENA_WALL_HEIGHT / 2, arenaCenterZ), arenaWallColor)

	return Vector3.new(arenaCenterX, 1, arenaCenterZ), Vector3.new(arenaWidth, ARENA_WALL_HEIGHT, arenaDepth)
end

-- "L4D Subway Map" community asset — https://create.roblox.com/store/asset/32852869/L4D-Subway-Map
-- The actual .rbxm was provided directly and is synced in by Rojo at
-- src/ServerStorage/MapAssets/L4D_Subway_Map.rbxm, landing in-game at
-- ServerStorage.MapAssets.L4D_Subway_Map (a Model). Verified by
-- inspecting the file's contents directly: 720 Parts / 38 sub-models
-- forming a subway station — "Subway station", "TurnTile", "Track",
-- "Subway Train", "Subway Stairs" — built the old-fashioned way (Glue/
-- Snap/Weld/RotateP legacy joints instead of a single union/MeshPart,
-- harmless here since everything below gets Anchored regardless), plus
-- ~147 bundled Sound instances (ambience) and a decorative corpse/
-- blood-stain prop set ("Corpse", "Blood", "Bloodstain 1/2") that fits
-- the zombie theme well but is worth a look in Studio in case it's not
-- wanted. The asset ID is kept only as a secondary fallback in case the
-- local file is ever missing from a checkout.
local SUBWAY_MAP_ASSET_ID = 32852869

--[[
	Loads the subway map to use as the arena instead of
	buildProceduralArenaFallback() above — preferring the local copy
	synced in via Rojo (see above) and only falling back to a live
	AssetService:LoadAssetAsync call (same permissions caveat as
	ZombieService/WeaponModelFactory: needs "Allow Loading Third Party
	Assets" on, see README Setup) if that local copy isn't present.
	Any failure at any step below falls back further to the procedural
	arena instead of leaving the map half-built or erroring out the
	whole bootstrap script.

	Positioning is a best-effort, translate-only move (deliberately never
	rotates it — there's no reliable signal for which way the asset
	"faces" from here): computes its world bounding box and shifts it so
	that box's bottom-center sits at the arena's target floor position,
	roughly where the procedural arena would otherwise be. Whether that
	puts its actual entrance toward the lobby, whether its multiple
	floors/stairs are cleanly navigable by our direct-chase and
	PathfindingService AI, whether its scale matches our other geometry
	well — all worth checking (and likely manually adjusting, e.g. the
	ArenaSpawnPoint/ZombieSpawns placement below) in Studio now that it's
	actually visible.
]]
local function getLocalSubwayMapTemplate(): Model?
	local mapAssets = ServerStorage:FindFirstChild("MapAssets")
	local template = mapAssets and mapAssets:FindFirstChild("L4D_Subway_Map")
	if not template or not template:IsA("Model") then
		return nil
	end
	return template:Clone()
end

local function loadSubwayMapArena(): (Model?, Vector3?, Vector3?)
	local template = getLocalSubwayMapTemplate()

	if not template then
		local ok, templateOrError = pcall(function()
			return AssetService:LoadAssetAsync(SUBWAY_MAP_ASSET_ID)
		end)
		if not ok then
			warn(("MapBootstrap: no local subway map found in ServerStorage.MapAssets, and failed to load subway map asset %d live (%s) — falling back to the built-in procedural arena. If this isn't a permissions error, check that 'Allow Loading Third Party Assets' is on in Game Settings > Security."):format(SUBWAY_MAP_ASSET_ID, tostring(templateOrError)))
			return nil, nil, nil
		end
		template = templateOrError :: Model
	end

	template.Sandboxed = false

	local partCount = 0
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			-- Strip unconditionally (unlike the Normal zombie's kept
			-- Animate/RbxNpcSounds) — a map has no business running any
			-- of its own logic; we only want its static geometry.
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Archivable = true
			partCount += 1
		end
	end

	if partCount == 0 then
		warn(("MapBootstrap: subway map asset %d loaded but contained no usable parts — falling back to the built-in procedural arena."):format(SUBWAY_MAP_ASSET_ID))
		template:Destroy()
		return nil, nil, nil
	end

	template.Name = "SubwayMapArena"
	template.Archivable = true

	local boundingOk, boundingCFrame, boundingSize = pcall(function()
		return template:GetBoundingBox()
	end)
	if not boundingOk then
		warn(("MapBootstrap: subway map asset %d loaded but GetBoundingBox() failed (%s) — falling back to the built-in procedural arena."):format(SUBWAY_MAP_ASSET_ID, tostring(boundingCFrame)))
		template:Destroy()
		return nil, nil, nil
	end

	local currentBottomCenter = boundingCFrame.Position - Vector3.new(0, boundingSize.Y / 2, 0)
	-- Bottom-center's X/Z is already the box's horizontal center, so this
	-- doubles as the "floor height, horizontal center" point the caller
	-- needs for spawn placement — same convention as
	-- buildProceduralArenaFallback's return value above.
	local targetFloorCenter = Vector3.new(arenaCenterX, 1, LOBBY_ARENA_BOUNDARY_Z + boundingSize.Z / 2)
	local delta = targetFloorCenter - currentBottomCenter

	template:PivotTo(template:GetPivot() + delta)
	template.Parent = map

	return template, targetFloorCenter, boundingSize
end

local subwayModel, arenaWorldCenter, arenaWorldSize = loadSubwayMapArena()
if not subwayModel then
	arenaWorldCenter, arenaWorldSize = buildProceduralArenaFallback()
end
assert(arenaWorldCenter and arenaWorldSize)

local PROBE_HEIGHT_ABOVE_FLOOR = 12 -- high enough to clear low steps/platforms, low enough to stay under any ceiling
local REQUIRED_HEADROOM = 6 -- a standable spot needs at least this much clear space above it

--[[
	Raycasts down at one X/Z column and returns a standable position, or
	nil. Rays start only PROBE_HEIGHT_ABOVE_FLOOR above the known
	play-level floor, NOT above the whole model — on an enclosed map like
	the subway station, starting above the model means the first downward
	hit is its ROOF. Also rejects spots without headroom (under a train,
	stairs, a pipe), which are standable in the raycast sense but
	instantly trap whatever spawns there.
]]
local function probeFloorAt(geometryModel: Model, x: number, z: number, floorY: number): Vector3?
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { geometryModel }

	local origin = Vector3.new(x, floorY + PROBE_HEIGHT_ABOVE_FLOOR, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -(PROBE_HEIGHT_ABOVE_FLOOR + 8), 0), raycastParams)
	if not result then
		return nil
	end

	local standPosition = result.Position + Vector3.new(0, 3, 0)
	local headroomHit = Workspace:Raycast(standPosition, Vector3.new(0, REQUIRED_HEADROOM, 0), raycastParams)
	if headroomHit then
		return nil
	end
	return standPosition
end

--[[
	Finds somewhere players can actually stand, starting at the arena's
	center and spiralling outward until real floor turns up.

	FIXED BUG: ArenaSpawnPoint used to be the bounding box's center,
	unvalidated. On the subway map that lands in open space (the track
	pit / the gap between platforms), so starting a match teleported
	everyone into the void and killed them instantly. The bounding box
	center of a real building is not reliably inside the building.

	This is also the reference point zombie spawn reachability is tested
	against below, so a bad value here silently degraded that too —
	pathfinding to a point in the void fails for every candidate, which
	made the reachability filter give up and fall back to unfiltered.
]]
local function findStandablePosition(geometryModel: Model?, center: Vector3, size: Vector3): Vector3
	local fallback = center + Vector3.new(0, 2, 0)
	if not geometryModel then
		return fallback -- procedural arena: flat and open, center is fine
	end

	local direct = probeFloorAt(geometryModel, center.X, center.Z, center.Y)
	if direct then
		return direct
	end

	-- Expanding square-ring search outward from the center.
	local step = 8
	local maxRings = math.ceil(math.max(size.X, size.Z) / 2 / step)
	for ring = 1, maxRings do
		local offset = ring * step
		for _, candidate in {
			Vector3.new(center.X + offset, 0, center.Z),
			Vector3.new(center.X - offset, 0, center.Z),
			Vector3.new(center.X, 0, center.Z + offset),
			Vector3.new(center.X, 0, center.Z - offset),
			Vector3.new(center.X + offset, 0, center.Z + offset),
			Vector3.new(center.X - offset, 0, center.Z - offset),
			Vector3.new(center.X + offset, 0, center.Z - offset),
			Vector3.new(center.X - offset, 0, center.Z + offset),
		} do
			local found = probeFloorAt(geometryModel, candidate.X, candidate.Z, center.Y)
			if found then
				return found
			end
		end
	end

	warn("MapBootstrap: no standable floor found anywhere in the arena — falling back to the bounding box center, which may be mid-air.")
	return fallback
end

local arenaPlayerSpawn = findStandablePosition(subwayModel, arenaWorldCenter, arenaWorldSize)
makeMarker("ArenaSpawnPoint", arenaPlayerSpawn)
print(("MapBootstrap: ArenaSpawnPoint at %.1f, %.1f, %.1f (arena floor Y=%.1f)"):format(
	arenaPlayerSpawn.X,
	arenaPlayerSpawn.Y,
	arenaPlayerSpawn.Z,
	arenaWorldCenter.Y
))

--[[
	Builds zombie spawn points by sampling a grid across the arena's
	actual X/Z footprint and raycasting down to find real floor
	surfaces, instead of a purely geometric ring around the bounding-box
	center. The ring approach (still used as a fallback below) works
	fine for the simple, flat, open-box procedural arena it was
	originally built for, but for the loaded subway map — multiple
	floors, platforms, a train, stairs — a ring computed purely from the
	overall bounding box's center/radius could easily land inside walls,
	in the void between separate structures, or on the wrong level
	entirely.

	CRITICAL — probe height: rays start only PROBE_HEIGHT_ABOVE_FLOOR
	studs above the known play-level floor (bottomCenter.Y, which is
	where ArenaSpawnPoint puts players), NOT above the whole model's
	bounding box. A first version of this started above the entire
	model and took the first downward hit, which on an enclosed map like
	the subway station is its ROOF — so every spawn point landed on the
	roof, out of sight and unreachable. Zombies did spawn, but nowhere
	the player could see them, and once MaxConcurrentZombies filled up
	with roof-stuck zombies WaveService blocked all further spawning:
	indistinguishable from "zombies never spawn" in-game.

	geometryModel is whatever real Model to raycast against (the loaded
	subway map); bottomCenter/size describe its bounding box using the
	SAME convention as this file's other arena-building functions —
	bottomCenter's Y is the floor level (not the box's vertical center),
	X/Z are the horizontal center.
]]
local function buildGeometryAwareSpawnPositions(geometryModel: Model, bottomCenter: Vector3, size: Vector3, desiredCount: number, playerReferencePosition: Vector3): { Vector3 }
	-- Grid across the real footprint, inset from the outer edges so a
	-- hit isn't immediately against a boundary wall.
	local GRID_STEP = 12
	local EDGE_MARGIN = 6
	local minX, maxX = bottomCenter.X - size.X / 2 + EDGE_MARGIN, bottomCenter.X + size.X / 2 - EDGE_MARGIN
	local minZ, maxZ = bottomCenter.Z - size.Z / 2 + EDGE_MARGIN, bottomCenter.Z + size.Z / 2 - EDGE_MARGIN

	local candidates: { Vector3 } = {}
	local x = minX
	while x <= maxX do
		local z = minZ
		while z <= maxZ do
			-- Shared with the player-spawn search above: same roof
			-- avoidance, same headroom rejection.
			local standPosition = probeFloorAt(geometryModel, x, z, bottomCenter.Y)
			if standPosition then
				table.insert(candidates, standPosition)
			end
			z += GRID_STEP
		end
		x += GRID_STEP
	end

	if #candidates == 0 then
		return {}
	end

	-- Reachability filter: keep only candidates PathfindingService can
	-- actually route from to where players stand. This is the gap that
	-- let 2 of wave 1's 5 zombies go missing after the roof fix — those
	-- points WERE real floor with real headroom (so they passed every
	-- earlier check), but sat in parts of the subway map genuinely
	-- disconnected from the play area: the track bed below platform
	-- level, inside the train, behind a barrier. A zombie spawned there
	-- can't path to anyone, never dies, and — because a wave only
	-- advances once the arena is clear (see WaveService's
	-- waitUntilArenaClear) — silently stalls the whole wave too.
	--
	-- Uses the same agent dimensions ZombieService's own pathfinding
	-- does, so "reachable" here means the same thing it will at runtime.
	local reachable: { Vector3 } = {}
	for _, candidate in candidates do
		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = false,
		})
		local computeOk = pcall(function()
			path:ComputeAsync(candidate, playerReferencePosition)
		end)
		if computeOk and path.Status == Enum.PathStatus.Success then
			table.insert(reachable, candidate)
		end
	end

	if #reachable == 0 then
		warn("MapBootstrap: found real floor positions, but PathfindingService couldn't route from ANY of them to the player spawn — falling back to unfiltered floor positions. Zombies may spawn somewhere they can't reach players from.")
		reachable = candidates
	end
	candidates = reachable

	-- Shuffle so picking desiredCount below doesn't systematically favor
	-- whichever corner of the grid happened to be scanned first.
	for i = #candidates, 2, -1 do
		local j = math.random(1, i)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	end

	-- Greedily pick points that are reasonably spread out from each
	-- other, so spawns don't cluster even if the grid found a lot of
	-- valid floor concentrated in one area (e.g. one big open platform).
	local MIN_SEPARATION = 10
	local selected: { Vector3 } = {}
	for _, candidate in candidates do
		if #selected >= desiredCount then
			break
		end
		local tooClose = false
		for _, existing in selected do
			if (candidate - existing).Magnitude < MIN_SEPARATION then
				tooClose = true
				break
			end
		end
		if not tooClose then
			table.insert(selected, candidate)
		end
	end

	-- If the spread-out pass alone didn't reach the desired count (e.g.
	-- a small map with limited open floor), backfill with whatever
	-- candidates are left, ignoring separation, rather than shipping
	-- fewer spawn points than requested.
	if #selected < desiredCount then
		for _, candidate in candidates do
			if #selected >= desiredCount then
				break
			end
			local alreadyPicked = false
			for _, existing in selected do
				if (candidate - existing).Magnitude < 0.1 then
					alreadyPicked = true
					break
				end
			end
			if not alreadyPicked then
				table.insert(selected, candidate)
			end
		end
	end

	return selected
end

local zombieSpawns = Instance.new("Folder")
zombieSpawns.Name = "ZombieSpawns"
zombieSpawns.Parent = Workspace

local SPAWN_COUNT = 10
local spawnPositions: { Vector3 } = {}

if subwayModel then
	spawnPositions = buildGeometryAwareSpawnPositions(
		subwayModel,
		arenaWorldCenter,
		arenaWorldSize,
		SPAWN_COUNT,
		arenaPlayerSpawn -- the validated ArenaSpawnPoint, not the raw bounding-box center
	)
	if #spawnPositions == 0 then
		warn("MapBootstrap: geometry-aware spawn point search found zero valid floor points on the subway map — falling back to the simple ring formula, which may land inside walls on this specific map layout.")
	end
end

if #spawnPositions == 0 then
	-- Simple ring: fine for the flat, open procedural fallback arena
	-- this was originally built for, and a last-resort fallback for the
	-- subway map too if raycasting somehow found nothing above.
	local SPAWN_RING_RADIUS = math.min(arenaWorldSize.X, arenaWorldSize.Z) / 2 * 0.6
	for i = 1, SPAWN_COUNT do
		local angle = (i / SPAWN_COUNT) * math.pi * 2
		table.insert(
			spawnPositions,
			arenaWorldCenter + Vector3.new(math.cos(angle) * SPAWN_RING_RADIUS, 2, math.sin(angle) * SPAWN_RING_RADIUS)
		)
	end
end

for i, position in spawnPositions do
	local point = Instance.new("Part")
	point.Name = "SpawnPoint" .. i
	point.Anchored = true
	point.CanCollide = false
	point.Transparency = 1
	point.Size = Vector3.new(2, 1, 2)
	point.Position = position
	point.Parent = zombieSpawns
end

-- Diagnostic: confirms spawn points landed at a sane height relative to
-- the arena floor. A previous bug put every one of them on the subway
-- station's ROOF (raycasting from above the whole model, so the first
-- downward hit was the roof rather than the interior floor) — zombies
-- spawned fine but were unreachable and invisible, which in-game was
-- indistinguishable from "zombies never spawn." If minY/maxY below are
-- far above arena floor Y, that regression is back.
do
	local minY, maxY = math.huge, -math.huge
	for _, position in spawnPositions do
		minY = math.min(minY, position.Y)
		maxY = math.max(maxY, position.Y)
	end
	print(("MapBootstrap: created %d zombie spawn point(s) (reachability-validated against the player spawn); arena floor Y=%.1f, spawn Y range %.1f..%.1f"):format(
		#spawnPositions,
		arenaWorldCenter.Y,
		minY,
		maxY
	))
end

-- ============================== BOUNDARY ==============================
-- Invisible walls around the whole level so players/zombies can't wander off the edge into the void.
-- The lobby's own walls already fully seal it off, so this exists
-- mainly to wrap whichever arena actually got built (procedural, with
-- its own perimeter walls, or the loaded subway map, whose real extent/
-- wall-completeness we can't know ahead of time) — sized dynamically
-- around both lobbyWorldCenter/lobbyWorldSize AND
-- arenaWorldCenter/arenaWorldSize (plus a margin) instead of a fixed
-- rectangle, so it safely contains either real asset regardless of how
-- big or small either one actually turns out to be.

local BOUNDARY_MARGIN = 20
local BOUNDARY_MIN_X = math.min(lobbyWorldCenter.X - lobbyWorldSize.X / 2, arenaWorldCenter.X - arenaWorldSize.X / 2) - BOUNDARY_MARGIN
local BOUNDARY_MAX_X = math.max(lobbyWorldCenter.X + lobbyWorldSize.X / 2, arenaWorldCenter.X + arenaWorldSize.X / 2) + BOUNDARY_MARGIN
local BOUNDARY_MIN_Z = math.min(lobbyWorldCenter.Z - lobbyWorldSize.Z / 2, arenaWorldCenter.Z - arenaWorldSize.Z / 2) - BOUNDARY_MARGIN
local BOUNDARY_MAX_Z = math.max(lobbyWorldCenter.Z + lobbyWorldSize.Z / 2, arenaWorldCenter.Z + arenaWorldSize.Z / 2) + BOUNDARY_MARGIN
local boundaryWidth = BOUNDARY_MAX_X - BOUNDARY_MIN_X
local boundaryDepth = BOUNDARY_MAX_Z - BOUNDARY_MIN_Z
local boundaryCenterX = (BOUNDARY_MIN_X + BOUNDARY_MAX_X) / 2
local boundaryCenterZ = (BOUNDARY_MIN_Z + BOUNDARY_MAX_Z) / 2

makePart("BoundaryNorth", Vector3.new(boundaryWidth, 40, 2), Vector3.new(boundaryCenterX, 15, BOUNDARY_MAX_Z), Color3.new(), { Transparency = 1 })
makePart("BoundarySouth", Vector3.new(boundaryWidth, 40, 2), Vector3.new(boundaryCenterX, 15, BOUNDARY_MIN_Z), Color3.new(), { Transparency = 1 })
makePart("BoundaryEast", Vector3.new(2, 40, boundaryDepth), Vector3.new(BOUNDARY_MAX_X, 15, boundaryCenterZ), Color3.new(), { Transparency = 1 })
makePart("BoundaryWest", Vector3.new(2, 40, boundaryDepth), Vector3.new(BOUNDARY_MIN_X, 15, boundaryCenterZ), Color3.new(), { Transparency = 1 })

-- ============================== FALL SAFETY NET ==============================
-- Last-resort catch-all, well below every floor (Y = -50) and spanning
-- past even the outer boundary above in every direction: if a player
-- ever still ends up falling — a knockback shoved through a gap we
-- didn't account for, a future geometry change, etc. — this catches
-- them and teleports them back to a safe spot instead of leaving them
-- to fall forever. Not a substitute for the real floors/walls above,
-- just insurance underneath them.
local fallSafetyNet = Instance.new("Part")
fallSafetyNet.Name = "FallSafetyNet"
fallSafetyNet.Anchored = true
fallSafetyNet.CanCollide = false
fallSafetyNet.CanQuery = false
fallSafetyNet.Transparency = 1
fallSafetyNet.Size = Vector3.new(boundaryWidth + 200, 4, boundaryDepth + 200)
fallSafetyNet.Position = Vector3.new(boundaryCenterX, -50, boundaryCenterZ)
fallSafetyNet.Parent = map

local LOBBY_RECOVERY_POSITION = playerSpawnPosition + Vector3.new(0, 3.5, 0)
local ARENA_RECOVERY_POSITION = arenaWorldCenter + Vector3.new(0, 7, 0)
local recoveringCharacters: { [Model]: boolean } = {}

fallSafetyNet.Touched:Connect(function(hit: BasePart)
	local character = hit.Parent
	if not character or not character:IsA("Model") or recoveringCharacters[character] then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not rootPart or humanoid.Health <= 0 then
		return
	end

	recoveringCharacters[character] = true

	-- Rough "which area were they in" guess from their Z position right
	-- before hitting the net (X/Z barely drift during a straight fall) —
	-- good enough since this is only ever expected to fire as a last
	-- resort, not something normal play should ever actually trigger.
	local recoveryPosition = if rootPart.Position.Z < LOBBY_ARENA_BOUNDARY_Z then LOBBY_RECOVERY_POSITION else ARENA_RECOVERY_POSITION

	rootPart.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(CFrame.new(recoveryPosition))

	task.delay(1, function()
		recoveringCharacters[character] = nil
	end)
end)
