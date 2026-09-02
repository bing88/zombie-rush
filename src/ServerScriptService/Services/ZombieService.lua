--[[
	ZombieService.lua (ModuleScript)

	Tier 1: spawns Normal/Fast/Tank/Boss zombies on demand (WaveService
	decides *when* and *how many* — this module only knows how to spawn
	one and run its AI). Converted from Tier 0's self-running .server.lua
	into a ModuleScript so WaveService can drive spawning explicitly
	instead of an endless trickle loop.

	AI: every Melee/Ranged type (Normal/Fast/Tank/Boss/Ranged) shares a
	single runChaseAI, using PathfindingService when
	stats.UsesPathfinding is true — now true for every type, since the
	loaded subway map has real multi-level geometry (walls, stairs,
	platforms) a straight-line MoveTo has no way to route around. Kept
	as a per-type toggle rather than deleted outright, in case a future
	very-cheap/very-numerous enemy type wants to opt back out of the
	pathfinding cost. Boss additionally has a simple 2-phase "enrage" at
	low HP (faster, harder-hitting, visibly redder) — see ZombieConfig's
	Enrage* fields. Exploder stays on its own separate runExploderAI
	(detonate-once-on-approach, not a repeating attack) but shares the
	same pathfinding movement helper.

	WeaponService tags a zombie with the attribute "LastHitPlayerId"
	whenever it damages it; this module reads that attribute on death to
	decide who gets credited (and therefore who gets the coin reward via
	the ZombieDied event, consumed by WaveService).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZombieConfig = require(ReplicatedStorage.Shared.ZombieConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local ZombieRangedAttack = Remotes.ZombieRangedAttack
local ZombieExploded = Remotes.ZombieExploded

local ZombieService = {}

local ZOMBIE_TAG = "Zombie"
local BOSS_TAG = "Boss"

-- Toolbox model assets used as the real rig for each zombie type instead
-- of the placeholder blocks. Normal is the official Roblox "Drooling
-- Zombie (Rthro)" NPC kit (see https://create.roblox.com/docs/resources/npc-kit
-- for its documented structure); Fast/Tank/Boss are unofficial community
-- models of unknown internal structure, handled more defensively below.
-- Ranged/Exploder have no asset yet and always use the placeholder rig.
-- Careful with these values: every id here had picked up a stray
-- trailing "1" (e.g. Tank was 3058978681 for what should be 305897868,
-- Boss 3193866641 for 319386664 — all four off by exactly one appended
-- digit versus the ids documented in the README). The result was
-- "Could not find asset" / "didn't contain a Model" warnings at spawn
-- and EVERY type silently falling back to the placeholder blocky rig,
-- which looks like "the models just don't load" rather than a typo.
-- If a type regresses to the placeholder, check the digit count here
-- against the README's list first.
local ZOMBIE_ASSET_IDS: { [string]: number } = {
	Normal = 39242386251,
	Fast = 3065429261, -- "Skeleton Dog"
	Tank = 3058978681, -- "NERF Zombie"
	Boss = 3193866641, -- "Axe Monster"
	-- Reusing existing assets for the newer types rather than sourcing
	-- more: Runner reads as a faster Fast, Brute as a bigger Tank, and
	-- Scale/Color in ZombieConfig already differentiate them visually.
	-- Types with no entry here (Ranged, Exploder, Spitter, Bomber) fall
	-- back to the placeholder rig automatically, which is a supported
	-- path — see getZombieTemplate/createZombieModel.
1	Runner = 3065429261, -- same "Skeleton Dog" rig as Fast
	Brute = 3058978681, -- same "NERF Zombie" rig as Tank
}

-- Whichever of these scripts exist are purely cosmetic (walk/idle
-- animation playback, footstep/groan/death audio) and layer on top of
-- our own AI without conflict — but only trusted for the one verified-
-- compatible asset (Normal; see buildZombieTemplate's trustBuiltInScripts).
-- Everything else — most importantly any built-in health-regen or
-- roam/attack AI script the asset ships with — is unconditionally
-- stripped, since our server-authoritative HP + Heartbeat/
-- PathfindingService AI below must be the sole authority.
local KEPT_ZOMBIE_SCRIPT_NAMES = { Animate = true, RbxNpcSounds = true }

local activeZombieCount = 0

local zombieDiedBindable = Instance.new("BindableEvent")
ZombieService.ZombieDied = zombieDiedBindable.Event -- (statsName: string, killerPlayer: Player?, coinReward: number)

function ZombieService.GetActiveCount(): number
	return activeZombieCount
end

--[[
	Adds one rigidly-welded, non-animated limb part to the model.
	`localCFrame` is the limb's full rest pose (translation *and*
	rotation) relative to rootPart — used for the arms below, which get a
	fixed "reach forward" rotation baked in but never move afterward, so
	a plain WeldConstraint (not a Motor6D) is enough; there's nothing to
	animate.
]]
local function addPlaceholderLimb(model: Model, rootPart: BasePart, name: string, size: Vector3, color: Color3, localCFrame: CFrame)
	local limb = Instance.new("Part")
	limb.Name = name
	limb.Size = size
	limb.Color = color
	limb.Parent = model
	limb.CFrame = rootPart.CFrame * localCFrame

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = rootPart
	weld.Part1 = limb
	weld.Parent = limb

	return limb
end

--[[
	Adds one leg jointed to rootPart via Motor6D (pivoting at the hip,
	where the leg meets the torso) instead of a rigid WeldConstraint, so
	its C0 can be animated frame-by-frame for a walk cycle (see
	animateLegWalk) — a WeldConstraint would otherwise continuously fight
	back to the leg's original rigid offset every time we tried to swing it.

	`hipLocalPosition` is where the hip joint sits, in rootPart's local
	space; the leg part itself hangs straight down from there by default
	(its top face at the hip, matching the C1 offset below).
]]
local function addPlaceholderLeg(model: Model, rootPart: BasePart, name: string, size: Vector3, color: Color3, hipLocalPosition: Vector3): (BasePart, Motor6D)
	local leg = Instance.new("Part")
	leg.Name = name
	leg.Size = size
	leg.Color = color
	leg.Parent = model
	leg.CFrame = rootPart.CFrame * CFrame.new(hipLocalPosition - Vector3.new(0, size.Y / 2, 0))

	local motor = Instance.new("Motor6D")
	motor.Part0 = rootPart
	motor.Part1 = leg
	motor.C0 = CFrame.new(hipLocalPosition)
	motor.C1 = CFrame.new(0, size.Y / 2, 0)
	motor.Parent = leg

	return leg, motor
end

local LEG_SWING_MAX_ANGLE = math.rad(50)
local LEG_SWING_CYCLES_PER_STUD = 0.6 -- stride frequency; tuned so it reads as a walk/run cycle rather than a spin
local LEG_SWING_MIN_SPEED = 0.6 -- studs/sec of actual root velocity below which legs snap back to standing rather than idly twitching

--[[
	Procedural walk cycle for the placeholder rig's legs: swings each
	leg's Motor6D about its hip in opposite phase, driven by how far the
	zombie has actually *travelled* (root part velocity integrated over
	time) rather than just elapsed time — so a slow Tank and a fast
	zombie both get a stride that matches their real movement instead of
	either one looking like it's moonwalking or sprinting in place.
	Snaps straight back to the standing rest pose the moment it stops
	(no ease-out) — simple, and stopping is usually to attack, so a
	lingering mid-stride leg would look worse than a clean snap.
]]
local function animateLegWalk(model: Model, humanoid: Humanoid, rootPart: BasePart, leftLegMotor: Motor6D, rightLegMotor: Motor6D, restC0Left: CFrame, restC0Right: CFrame)
	local strideDistance = 0
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if not model.Parent or humanoid.Health <= 0 then
			connection:Disconnect()
			return
		end

		local horizontalVelocity = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
		local speed = horizontalVelocity.Magnitude

		if speed > LEG_SWING_MIN_SPEED then
			strideDistance += speed * dt
		else
			strideDistance = 0
		end

		local swing = math.sin(strideDistance * LEG_SWING_CYCLES_PER_STUD * (math.pi * 2)) * LEG_SWING_MAX_ANGLE
		leftLegMotor.C0 = restC0Left * CFrame.Angles(swing, 0, 0)
		rightLegMotor.C0 = restC0Right * CFrame.Angles(-swing, 0, 0)
	end)
end

--[[
	Builds a minimal procedural zombie rig, scaled/colored per
	ZombieConfig. Still used for Fast/Tank/Boss (and as a Normal fallback
	if the real asset fails to load) — no art pipeline exists for those
	yet, same rationale as Tier 0. Torso + Head + 2 arms + 2 legs.

	Arms are fixed in a "reach forward" pose (classic zombie silhouette)
	and never move; legs are hip-jointed via Motor6D and swing through a
	procedural walk cycle while the zombie is actually moving (see
	animateLegWalk).
]]
local function createPlaceholderZombieModel(statsName: string): Model
	local stats = ZombieConfig[statsName]
	local scale = stats.Scale

	local model = Instance.new("Model")
	model.Name = statsName .. "Zombie"

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1) * scale
	rootPart.Transparency = 1
	rootPart.CanCollide = false
	rootPart.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1) * scale
	torso.Color = stats.Color
	torso.Parent = model
	local torsoWeld = Instance.new("WeldConstraint")
	torsoWeld.Part0 = rootPart
	torsoWeld.Part1 = torso
	torsoWeld.Parent = torso
	torso.CFrame = rootPart.CFrame

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2) * scale
	head.Color = stats.Color:Lerp(Color3.new(1, 1, 1), 0.2)
	head.Parent = model
	head.CFrame = rootPart.CFrame * CFrame.new(0, 1.6 * scale, 0)
	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = rootPart
	headWeld.Part1 = head
	headWeld.Parent = head

	-- Classic R6 proportions: 1x2x1 limbs.
	local limbColor = stats.Color:Lerp(Color3.new(0, 0, 0), 0.1) -- slightly darker than the torso for a bit of visual definition
	local limbSize = Vector3.new(1, 2, 1) * scale

	-- Arms: shoulder flush against the torso's side (half torso width +
	-- half arm width = 1.5 studs out), rotated -90° about X so the arm's
	-- long axis points forward (local -Z — the model's facing direction,
	-- same convention as CFrame.LookVector) from the shoulder instead of
	-- hanging straight down, and pushed forward by half the arm's length
	-- so it still pivots from the shoulder rather than from its middle.
	local armForwardRotation = CFrame.Angles(math.rad(-90), 0, 0)
	local shoulderHeight = 0.3 * scale
	addPlaceholderLimb(model, rootPart, "Left Arm", limbSize, limbColor,
		CFrame.new(-1.5 * scale, shoulderHeight, -1 * scale) * armForwardRotation)
	addPlaceholderLimb(model, rootPart, "Right Arm", limbSize, limbColor,
		CFrame.new(1.5 * scale, shoulderHeight, -1 * scale) * armForwardRotation)

	-- Legs: hip centered under each half of the torso, hip joint sitting
	-- right at the torso's bottom edge (half torso height up from the
	-- leg's own center).
	local leftHip = Vector3.new(-0.5 * scale, -1 * scale, 0)
	local rightHip = Vector3.new(0.5 * scale, -1 * scale, 0)
	local _leftLeg, leftLegMotor = addPlaceholderLeg(model, rootPart, "Left Leg", limbSize, limbColor, leftHip)
	local _rightLeg, rightLegMotor = addPlaceholderLeg(model, rootPart, "Right Leg", limbSize, limbColor, rightHip)

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = stats.MaxHP
	humanoid.Health = stats.MaxHP
	humanoid.WalkSpeed = stats.WalkSpeed
	humanoid.Parent = model

	model.PrimaryPart = rootPart

	animateLegWalk(model, humanoid, rootPart, leftLegMotor, rightLegMotor, CFrame.new(leftHip), CFrame.new(rightHip))

	return model
end

--[[
	Loads + processes one zombie type's real rig. Everything here
	(including the load itself) runs inside a single pcall in
	getZombieTemplate, so any failure at any step — no usable Model/root
	part, or something more obscure about how a Store asset comes back
	(e.g. Sandboxed/Capability writes being restricted) — falls back to
	the placeholder cleanly instead of throwing an uncaught error that
	would silently break the wave's whole spawn loop.
]]
local function buildZombieTemplate(assetId: number, statsName: string): Model
	local container = AssetService:LoadAssetAsync(assetId)

	-- LoadAssetAsync sandboxes the returned Model by default (no script
	-- Capabilities at all), which would silently prevent even the
	-- "Animate"/"RbxNpcSounds" scripts we deliberately keep below from
	-- ever running. We already strip everything else, so it's safe to
	-- trust what's left.
	container.Sandboxed = false

	local template = container:FindFirstChildOfClass("Model")
	if not template then
		container:Destroy()
		error(("asset %d didn't contain a Model"):format(assetId))
	end
	template.Parent = nil -- detach from the throwaway wrapper before destroying it
	container:Destroy()
	template.Sandboxed = false

	-- A kept "Animate" script almost always assumes a standard R6/R15
	-- humanoid layout ("Torso"/"UpperTorso" + "Head" as *direct* children
	-- of the top-level model) to WaitForChild its limbs — on a
	-- non-humanoid/non-standard community model that WaitForChild never
	-- resolves, hanging that thread forever ("Infinite yield possible..."
	-- spam, one leaked coroutine per zombie spawned; happened for both
	-- the "Skeleton Dog" Fast model and — since a part merely being
	-- *named* "Torso" doesn't guarantee it's a direct child of the exact
	-- Model the script expects — isn't safely detectable by sniffing part
	-- names either). Given that, only the one Normal zombie asset (the
	-- official, verified-compatible Roblox NPC kit) is trusted to keep
	-- its own scripts; every other (community-sourced) zombie type always
	-- strips them, regardless of what part names it happens to contain.
	local trustBuiltInScripts = statsName == "Normal"

	for _, descendant in template:GetDescendants() do
		local isKeptScriptName = KEPT_ZOMBIE_SCRIPT_NAMES[descendant.Name] and trustBuiltInScripts
		if (descendant:IsA("Script") or descendant:IsA("LocalScript")) and not isKeptScriptName then
			descendant:Destroy()
		end
	end

	local humanoid = template:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		-- Some community models (e.g. simple decorative rigs) don't ship
		-- a Humanoid at all; add one so our AI (Humanoid:MoveTo, TakeDamage)
		-- still works. It won't animate/move limbs correctly unless the
		-- model's parts are already rigidly joined to the root, but it'll
		-- at least chase, attack, and die like every other zombie type.
		humanoid = Instance.new("Humanoid")
		humanoid.Parent = template
	end

	-- Root part naming varies wildly across toolbox uploads (modern
	-- "HumanoidRootPart", old R6 "Torso", or nothing set up at all) — walk
	-- down a fallback chain and standardize on "HumanoidRootPart" so the
	-- rest of the codebase (AI below, AutoAimController, WeaponService)
	-- can keep relying on that one name regardless of the source asset.
	local rootPart = template.PrimaryPart
		or template:FindFirstChild("HumanoidRootPart")
		or template:FindFirstChild("Torso")
		or template:FindFirstChild("UpperTorso")
		or template:FindFirstChildWhichIsA("BasePart", true)

	if not rootPart or not rootPart:IsA("BasePart") then
		template:Destroy()
		error(("asset %d has no usable root part"):format(assetId))
	end
	if rootPart.Name ~= "HumanoidRootPart" then
		rootPart.Name = "HumanoidRootPart"
	end
	template.PrimaryPart = rootPart :: BasePart

	-- Store assets sometimes come back with Archivable = false on some
	-- descendants (an anti-duplication default) — if left alone, every
	-- :Clone() of this template (every future spawn of this type) would
	-- silently return nil, which then errors wherever the caller assumes
	-- a real Model (e.g. reading its Humanoid).
	template.Archivable = true
	for _, descendant in template:GetDescendants() do
		descendant.Archivable = true
	end

	template.Name = statsName .. "ZombieTemplate"
	return template
end

local zombieTemplates: { [string]: Model } = {}
local zombieTemplateLoadAttempted: { [string]: boolean } = {}

--[[
	Lazily loads + caches the real rig for a zombie type on first use (not
	at server start — no need to pay the network round-trip for a type
	that never gets spawned). Cached as a hidden ServerStorage template so
	every subsequent zombie of that type is just a cheap :Clone().

	Returns nil (and warns once per type) if anything about loading or
	preparing the asset fails — most commonly because "Allow Loading
	Third Party Assets" is off in Game Settings > Security (required
	since none of these assets are owned by the game's creator — see
	AssetService:LoadAssetAsync's docs) — so callers fall back to the
	placeholder rig instead of erroring.
]]
local function getZombieTemplate(statsName: string): Model?
	if zombieTemplates[statsName] then
		return zombieTemplates[statsName]
	end
	if zombieTemplateLoadAttempted[statsName] then
		return nil
	end
	zombieTemplateLoadAttempted[statsName] = true

	local assetId = ZOMBIE_ASSET_IDS[statsName]
	if not assetId then
		return nil
	end

	local ok, templateOrError = pcall(buildZombieTemplate, assetId, statsName)
	if not ok or not templateOrError then
		warn(("ZombieService: failed to prepare %s zombie asset %d (%s) — falling back to the placeholder rig. If this isn't a permissions error, check that 'Allow Loading Third Party Assets' is on in Game Settings > Security."):format(statsName, assetId, tostring(templateOrError)))
		return nil
	end

	local template = templateOrError :: Model
	template.Parent = ServerStorage
	zombieTemplates[statsName] = template
	return template
end

--[[
	Dispatches to the real asset rig for a type (with the placeholder rig
	as a fallback if it fails to load, lacks a usable structure, or fails
	to Clone()).
]]
local function createZombieModel(statsName: string): Model
	local stats = ZombieConfig[statsName]
	local model: Model

	local template = getZombieTemplate(statsName)
	if template then
		model = template:Clone()
		if model then
			local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
			humanoid.MaxHealth = stats.MaxHP
			humanoid.Health = stats.MaxHP
			humanoid.WalkSpeed = stats.WalkSpeed
		else
			warn(("ZombieService: %s template failed to Clone() — falling back to the placeholder rig for this spawn."):format(statsName))
		end
	end

	if not model then
		model = createPlaceholderZombieModel(statsName)
	end

	CollectionService:AddTag(model, ZOMBIE_TAG)
	if statsName == "Boss" then
		CollectionService:AddTag(model, BOSS_TAG)
	end

	return model
end

--[[
	Raycasts torso-height between two points, ignoring the zombie's own
	model, to decide whether it actually has a clear shot at its target —
	AttackRange alone is just Euclidean distance, so without this a
	zombie standing right next to (but on the other side of) a crate or
	wall would think it's "in range" and stop dead to attack through solid
	geometry, looking permanently stuck against the obstacle.
]]
local function hasLineOfSight(fromPosition: Vector3, toPosition: Vector3, ignoreModel: Model): boolean
	local eyeOffset = Vector3.new(0, 1, 0)
	local origin = fromPosition + eyeOffset
	local direction = (toPosition + eyeOffset) - origin
	local distance = direction.Magnitude
	if distance < 0.1 then
		return true
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { ignoreModel }

	local result = Workspace:Raycast(origin, direction, raycastParams)
	if not result then
		return true
	end
	-- Something solid was hit meaningfully before reaching the target -> blocked.
	return (result.Position - origin).Magnitude >= distance - 1.5
end

local function findNearestPlayerRoot(fromPosition: Vector3): BasePart?
	local nearestRoot: BasePart? = nil
	local nearestDistance = math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if humanoid and humanoid.Health > 0 and root then
				local distance = (root.Position - fromPosition).Magnitude
				if distance < nearestDistance then
					nearestDistance = distance
					nearestRoot = root
				end
			end
		end
	end

	return nearestRoot
end

--[[
	Shared PathfindingService-driven movement, used by every chasing
	zombie type now (previously Tank/Boss only — see runChaseAI's own
	comment for why that changed). Periodically recomputes a path (not
	every tick — pathfinding is comparatively expensive) and includes a
	stuck watchdog that forces a fresh path if barely any progress was
	made recently (e.g. wedged against a wall corner the path routed
	too close to), instead of grinding in place forever. Blocks
	internally via task.wait for roughly one "tick" worth of time —
	callers should call this from within their own loop rather than
	wrapping it in an additional task.wait.

	pathState is a small per-zombie table the caller owns and passes in
	every call (see newPathState()) — keeps this function reentrant
	rather than tying it to one specific zombie via upvalues.
]]
local PATH_RECOMPUTE_INTERVAL = 1.5
local STUCK_CHECK_INTERVAL = 1
local STUCK_DISTANCE_THRESHOLD = 1.5

-- If a zombie makes essentially no progress for this long, treat it as
-- genuinely stranded (not merely bumping a corner) and teleport it to a
-- known-good spawn point. See the rescue block in
-- moveTowardWithPathfinding for why this exists.
local STRANDED_SECONDS = 12

local function newPathState()
	return {
		-- Jittered so many zombies spawned at once (e.g. a whole wave)
		-- don't all recompute paths on the same cadence — now that most
		-- zombie types use real pathfinding (previously just Tank/Boss,
		-- far fewer concurrent instances), synchronized recomputes could
		-- otherwise create periodic CPU spikes.
		lastPathComputeTime = os.clock() - math.random() * PATH_RECOMPUTE_INTERVAL,
		waypoints = {} :: { PathWaypoint },
		waypointIndex = 1,
		lastStuckCheckTime = os.clock(),
		lastStuckCheckPosition = nil :: Vector3?,
		strandedSince = nil :: number?,
	}
end

--[[
	Last-resort rescue for a zombie that's made no meaningful progress
	for STRANDED_SECONDS: teleport it to a random known-good spawn point
	(the same reachability-validated ZombieSpawns list WaveService uses).

	Why this is needed even with validated spawn points: a zombie can
	still end up somewhere unreachable mid-match — knocked off a ledge
	by the hit-knockback impulse, wedged in a gap between props, or
	simply on a bit of geometry PathfindingService can't route out of.
	A permanently stuck zombie doesn't just look wrong, it STALLS THE
	WHOLE WAVE: WaveService's waitUntilArenaClear only advances once
	every zombie is dead, so one stranded zombie hangs the match
	indefinitely. Teleporting is deliberately blunt but self-correcting
	— strictly better than a match that can never progress.
]]
local function rescueStrandedZombie(rootPart: BasePart): boolean
	local folder = Workspace:FindFirstChild("ZombieSpawns")
	if not folder then
		return false
	end
	local points = {}
	for _, point in folder:GetChildren() do
		if point:IsA("BasePart") then
			table.insert(points, point.Position)
		end
	end
	if #points == 0 then
		return false
	end
	local destination = points[math.random(1, #points)]
	local ok = pcall(function()
		rootPart.CFrame = CFrame.new(destination)
		rootPart.AssemblyLinearVelocity = Vector3.zero
	end)
	return ok
end

local function moveTowardWithPathfinding(pathState, humanoid: Humanoid, rootPart: BasePart, targetPosition: Vector3, walkSpeed: number, isAlive: () -> boolean)
	local now = os.clock()

	if not pathState.lastStuckCheckPosition then
		pathState.lastStuckCheckPosition = rootPart.Position
	end

	if now - pathState.lastStuckCheckTime > STUCK_CHECK_INTERVAL then
		local moved = (rootPart.Position - pathState.lastStuckCheckPosition).Magnitude
		if moved < STUCK_DISTANCE_THRESHOLD then
			pathState.lastPathComputeTime = 0 -- force a fresh path below
			-- Track how long this has been going on: a brief snag on a
			-- corner resolves after a fresh path, but continuous
			-- no-progress means genuinely stranded.
			pathState.strandedSince = pathState.strandedSince or now
			if now - pathState.strandedSince > STRANDED_SECONDS then
				if rescueStrandedZombie(rootPart) then
					pathState.strandedSince = nil
					pathState.waypoints = {}
					pathState.waypointIndex = 1
					pathState.lastPathComputeTime = 0
				end
			end
		else
			pathState.strandedSince = nil -- made real progress; not stranded
		end
		pathState.lastStuckCheckTime = now
		pathState.lastStuckCheckPosition = rootPart.Position
	end

	if now - pathState.lastPathComputeTime > PATH_RECOMPUTE_INTERVAL or pathState.waypointIndex > #pathState.waypoints then
		pathState.lastPathComputeTime = now
		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = false,
		})
		local computeOk = pcall(function()
			path:ComputeAsync(rootPart.Position, targetPosition)
		end)
		if computeOk and path.Status == Enum.PathStatus.Success then
			pathState.waypoints = path:GetWaypoints()
			pathState.waypointIndex = 2 -- waypoint 1 is just the zombie's current position
		else
			pathState.waypoints = {}
			pathState.waypointIndex = 1
		end
	end

	local waypoint = pathState.waypoints[pathState.waypointIndex]
	if waypoint then
		humanoid:MoveTo(waypoint.Position)
		-- Scale the wait by how far this waypoint actually is (a flat
		-- cap could abandon a long leg early, or make a slow zombie cut
		-- a corner into the very obstacle the path was routing around);
		-- a "close enough" break lets it move on immediately without
		-- waiting out the full timeout if MoveToFinished doesn't fire
		-- cleanly.
		local waypointDistance = (waypoint.Position - rootPart.Position).Magnitude
		local timeout = math.clamp(waypointDistance / math.max(walkSpeed, 1) + 1, 1, 4)
		local reached = false
		local moveToFinishedConnection = humanoid.MoveToFinished:Connect(function()
			reached = true
		end)
		local waited = 0
		while not reached and waited < timeout and isAlive() do
			task.wait(0.1)
			waited += 0.1
			if (waypoint.Position - rootPart.Position).Magnitude < 3 then
				break
			end
		end
		moveToFinishedConnection:Disconnect()
		pathState.waypointIndex += 1
	else
		-- No usable path this cycle; fall back to direct movement so
		-- the zombie doesn't stand still forever.
		humanoid:MoveTo(targetPosition)
		task.wait(0.3)
	end
end

--[[
	Unified chase AI for every Melee/Ranged zombie type (Normal/Fast/
	Tank/Boss/Ranged) — handles both attack styles, and, for Boss
	specifically, the enrage phase-2 swap.

	Movement uses real PathfindingService routing (via the shared
	moveTowardWithPathfinding helper above) whenever stats.
	UsesPathfinding is true, instead of a raw straight-line
	humanoid:MoveTo with zero obstacle awareness. Previously only Tank/
	Boss opted into this ("keep server cost down with many concurrent
	zombies" — see ZombieConfig's old comment); every other type just
	walked straight at the player's current position. That was fine for
	the old open-box procedural arena, but the loaded subway map has
	real multi-level geometry (walls, stairs, platforms) a straight
	line has no way to route around, which is what was causing zombies
	to visibly get stuck against walls/ladders instead of actually
	pathing to the player. UsesPathfinding is kept as a per-type
	config toggle (now true for every type except Exploder, which has
	its own separate runExploderAI) rather than deleted outright, in
	case a future very-cheap/very-numerous enemy type wants to opt back
	out of the pathfinding cost.
]]
local function runChaseAI(model: Model, statsName: string, stats, humanoid: Humanoid, rootPart: BasePart, damageMultiplier: number, onDeath: () -> ())
	local alive = true
	local enraged = false

	humanoid.Died:Connect(function()
		alive = false
		activeZombieCount -= 1
		onDeath()
	end)

	if statsName == "Boss" and stats.EnrageHPFraction then
		humanoid.HealthChanged:Connect(function(health)
			if enraged or health <= 0 then
				return
			end
			if health <= humanoid.MaxHealth * stats.EnrageHPFraction then
				enraged = true
				humanoid.WalkSpeed = stats.EnrageWalkSpeed
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("BasePart") then
						descendant.Color = Color3.fromRGB(255, 50, 50)
					end
				end
			end
		end)
	end

	local function isAlive()
		return alive and model.Parent ~= nil
	end

	task.spawn(function()
		local pathState = newPathState()
		local lastAttackTime = 0

		while isAlive() do
			local targetRoot = findNearestPlayerRoot(rootPart.Position)
			if not targetRoot then
				task.wait(0.5)
				continue
			end

			local now = os.clock()
			local distance = (targetRoot.Position - rootPart.Position).Magnitude
			local canAttack = distance <= stats.AttackRange
				and hasLineOfSight(rootPart.Position, targetRoot.Position, model)

			if canAttack then
				humanoid:MoveTo(rootPart.Position) -- stop to attack
				local cooldown = enraged and stats.EnrageAttackCooldown or stats.AttackCooldown
				if now - lastAttackTime >= cooldown then
					lastAttackTime = now
					local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")

					if stats.AttackType == "Ranged" then
						-- Broadcast first so the visual and the damage
						-- land in the same frame — this is a hitscan
						-- attack (instant damage), the travel-time look
						-- is purely cosmetic on the client.
						ZombieRangedAttack:FireAllClients(model.Name, rootPart.Position, targetRoot.Position)
					end

					if targetHumanoid and targetHumanoid.Health > 0 then
						local damage = enraged and stats.EnrageAttackDamage or stats.AttackDamage
						targetHumanoid:TakeDamage(damage * damageMultiplier)
					end
				end
				-- Don't let time spent attacking count against the
				-- stuck watchdog once it resumes chasing.
				pathState.lastStuckCheckTime = now
				pathState.lastStuckCheckPosition = rootPart.Position
				task.wait(0.2)
				continue
			end

			if stats.UsesPathfinding then
				moveTowardWithPathfinding(pathState, humanoid, rootPart, targetRoot.Position, stats.WalkSpeed, isAlive)
			else
				-- Still moving toward the target even when "in range"
				-- but blocked by cover, instead of stopping dead at the
				-- obstacle.
				humanoid:MoveTo(targetRoot.Position)
				task.wait(0.15)
			end
		end
	end)
end

--[[
	One-shot AI for Exploder: chases like the others, but instead of a
	repeating attack, detonates exactly once on reaching AttackRange —
	dealing AOE damage to every player in ExplosionRadius, then killing
	itself. Also detonates if it dies from being shot (see onDeath in
	SpawnZombie), so a partial-HP Exploder killed by gunfire still pops,
	which reads more consistently than it just quietly vanishing.

	Movement uses the same shared pathfinding helper as runChaseAI now
	(previously a raw straight-line MoveTo, same "gets stuck on the new
	map's real geometry" problem as every other type had).
]]
local function runExploderAI(model: Model, stats, humanoid: Humanoid, rootPart: BasePart, onDeath: () -> ())
	local alive = true
	local detonated = false

	local function detonate()
		if detonated then
			return
		end
		detonated = true

		ZombieExploded:FireAllClients(rootPart.Position, stats.ExplosionRadius)

		for _, player in Players:GetPlayers() do
			local character = player.Character
			local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local targetHumanoid = character and character:FindFirstChildOfClass("Humanoid")
			if targetRoot and targetHumanoid and targetHumanoid.Health > 0 then
				local distance = (targetRoot.Position - rootPart.Position).Magnitude
				if distance <= stats.ExplosionRadius then
					-- Linear falloff: full damage at point-blank, ~0 at
					-- the edge of the radius, so it's not an insta-kill
					-- flat-damage blast regardless of distance.
					local falloff = 1 - (distance / stats.ExplosionRadius)
					targetHumanoid:TakeDamage(stats.ExplosionDamage * math.max(falloff, 0.15))
				end
			end
		end

		if humanoid.Health > 0 then
			humanoid.Health = 0 -- triggers Died -> onDeath cleanup below; no killer credit for a self-detonation
		end
	end

	humanoid.Died:Connect(function()
		alive = false
		detonate() -- still pops even if it died from being shot rather than reaching a player
		activeZombieCount -= 1
		onDeath()
	end)

	local function isAlive()
		return alive and model.Parent ~= nil and not detonated
	end

	task.spawn(function()
		local pathState = newPathState()

		while isAlive() do
			local targetRoot = findNearestPlayerRoot(rootPart.Position)
			if not targetRoot then
				task.wait(0.5)
				continue
			end

			local distance = (targetRoot.Position - rootPart.Position).Magnitude
			if distance <= stats.AttackRange and hasLineOfSight(rootPart.Position, targetRoot.Position, model) then
				detonate()
				break
			end

			if stats.UsesPathfinding then
				moveTowardWithPathfinding(pathState, humanoid, rootPart, targetRoot.Position, stats.WalkSpeed, isAlive)
			else
				humanoid:MoveTo(targetRoot.Position)
				task.wait(0.15)
			end
		end
	end)
end

--[[
	Applies a quick outward/upward velocity pop to the root part on
	death, so a kill reads as an impact instead of the model just
	freezing in its tracks. Real toolbox rigs with standard Motor6D
	joints will also ragdoll via Roblox's default BreakJointsOnDeath
	behavior on top of this; the placeholder rig (welded, not
	Motor6D-jointed) won't ragdoll, but still gets the same knockback pop
	since that's just a velocity set on the root part regardless of rig type.
]]
local function applyDeathKnockback(rootPart: BasePart)
	local randomAngle = math.random() * math.pi * 2
	local horizontal = Vector3.new(math.cos(randomAngle), 0, math.sin(randomAngle)) * math.random(8, 14)
	local impulseVelocity = horizontal + Vector3.new(0, math.random(6, 10), 0)

	local ok = pcall(function()
		rootPart.AssemblyLinearVelocity = impulseVelocity
	end)
	if not ok then
		-- Root part may be anchored on some fallback paths; harmless no-op then.
	end
end

local HIT_KNOCKBACK_STUN_SECONDS = 0.15
local HIT_KNOCKBACK_SPEED = 16
local HIT_KNOCKBACK_LIFT = 5

-- Shared per-zombie "stun until" clock (os.clock() timestamp), keyed by
-- Model. See ApplyHitKnockback's comment for why this replaced each
-- call independently saving/restoring humanoid.PlatformStand.
local knockbackStunExpiry: { [Model]: number } = {}

--[[
	Punches a *surviving* hit (see WeaponService's resolvePellet — killing
	blows keep the separate, more theatrical applyDeathKnockback instead)
	backward along the shot's direction, so getting shot reads as an
	impact instead of the zombie just soaking damage silently.

	Briefly flips Humanoid.PlatformStand on: a Humanoid actively fighting
	for movement control (MoveTo, every AI loop below calls it constantly)
	would otherwise re-assert its own velocity within the same frame,
	making a plain AssemblyLinearVelocity impulse invisible. PlatformStand
	hands full control to physics for a beat so the impulse is actually
	visible, then hands it back — the AI loops keep calling MoveTo the
	whole time regardless, so movement just resumes normally afterward
	with no extra bookkeeping needed here.

	FIXED BUG: this previously captured/restored PlatformStand per-call
	("wasPlatformStand = humanoid.PlatformStand ... restore to that").
	A multi-pellet hit (the Shotgun fires 8 at once) or several hits
	landing within the same 0.15s window each independently captured
	whatever the PREVIOUS call had already set PlatformStand to (true),
	then scheduled their own delayed restore back to that captured
	(already-true) value. Once all the delayed callbacks fired, the
	LAST one to run would set PlatformStand back to true instead of
	false, leaving the Humanoid permanently stuck with no movement
	authority — exactly the reported "zombie gets stuck after being
	hit" symptom, and worse the more pellets/hits landed together.
	Fixed by tracking one shared "stun expiry" clock per zombie that
	each hit only ever EXTENDS (never independently restores from) —
	only the callback whose delay lands at or after the current latest
	expiry actually clears PlatformStand, so overlapping hits can no
	longer race each other into leaving it stuck on.
]]
function ZombieService.ApplyHitKnockback(zombieModel: Model, shotDirection: Vector3)
	local rootPart = zombieModel.PrimaryPart
	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return
	end

	local horizontal = Vector3.new(shotDirection.X, 0, shotDirection.Z)
	if horizontal.Magnitude < 0.01 then
		return
	end
	local impulseVelocity = horizontal.Unit * HIT_KNOCKBACK_SPEED + Vector3.new(0, HIT_KNOCKBACK_LIFT, 0)

	humanoid.PlatformStand = true

	local ok = pcall(function()
		rootPart.AssemblyLinearVelocity = impulseVelocity
	end)
	if not ok then
		-- Root part may be anchored on some fallback paths; harmless no-op then.
	end

	local expiryClock = os.clock() + HIT_KNOCKBACK_STUN_SECONDS
	knockbackStunExpiry[zombieModel] = math.max(knockbackStunExpiry[zombieModel] or 0, expiryClock)

	task.delay(HIT_KNOCKBACK_STUN_SECONDS, function()
		if not humanoid.Parent or humanoid.Health <= 0 then
			knockbackStunExpiry[zombieModel] = nil
			return
		end
		-- Only actually clear PlatformStand once we're past the LATEST
		-- recorded expiry — if a later hit pushed it further out since
		-- this particular delay was scheduled, some other (later-firing)
		-- delayed call will be the one that actually clears it instead.
		if os.clock() >= (knockbackStunExpiry[zombieModel] or 0) then
			humanoid.PlatformStand = false
			knockbackStunExpiry[zombieModel] = nil
		end
	end)
end

-- Community "zombie die" groan (https://create.roblox.com/store/asset/116391542832455/Fast-Zombie-Die),
-- used as the death sound for every zombie type, not just Fast.
local ZOMBIE_DEATH_SOUND_ID = "rbxassetid://116391542832455"

--[[
	Plays the death groan at the zombie's position via a standalone
	emitter part (rather than a Sound parented directly under the corpse)
	so it isn't cut off early by onDeath's task.delay(2, model:Destroy).
	Playing this from the server (not a LocalScript) means the replicated
	Sound.Playing change is what every client actually hears — no remote
	event needed.
]]
local function playDeathSound(position: Vector3)
	local emitter = Instance.new("Part")
	emitter.Name = "ZombieDeathSoundEmitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.Transparency = 1
	emitter.Size = Vector3.new(0.1, 0.1, 0.1)
	emitter.Position = position
	emitter.Parent = Workspace

	local sound = Instance.new("Sound")
	sound.SoundId = ZOMBIE_DEATH_SOUND_ID
	sound.Volume = 0.6
	sound.RollOffMinDistance = 8
	sound.RollOffMaxDistance = 150
	sound.Parent = emitter
	sound:Play()

	Debris:AddItem(emitter, 5) -- safety buffer well past the clip's length
end

--[[
	Spawns one zombie of the given type at the given position and starts
	its AI. Returns the Model (or nil if statsName is unknown).

	hpMultiplier/speedMultiplier/damageMultiplier (all default 1) let
	WaveService apply a random per-wave modifier (see WaveModifiers.lua)
	without this module needing to know anything about wave balance —
	it just scales whatever base stats it was given.
]]
function ZombieService.SpawnZombie(
	statsName: string,
	position: Vector3,
	hpMultiplier: number?,
	speedMultiplier: number?,
	damageMultiplier: number?
): Model?
	local stats = ZombieConfig[statsName]
	if not stats then
		warn("ZombieService.SpawnZombie: unknown zombie type " .. tostring(statsName))
		return nil
	end

	local model = createZombieModel(statsName)
	model.Parent = Workspace
	model:PivotTo(CFrame.new(position))
	activeZombieCount += 1

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = model.PrimaryPart :: BasePart

	-- Applied here (after createZombieModel, which sets base values)
	-- so multiplier scaling is consistent regardless of which path
	-- created the model (real asset clone vs. placeholder).
	humanoid.MaxHealth = stats.MaxHP * (hpMultiplier or 1)
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = stats.WalkSpeed * (speedMultiplier or 1)

	local function onDeath()
		CollectionService:RemoveTag(model, ZOMBIE_TAG)
		applyDeathKnockback(rootPart)
		playDeathSound(rootPart.Position)
		local killerPlayer: Player? = nil
		local killerUserId = model:GetAttribute("LastHitPlayerId")
		if killerUserId then
			killerPlayer = Players:GetPlayerByUserId(killerUserId)
		end
		zombieDiedBindable:Fire(statsName, killerPlayer, stats.CoinReward)
		knockbackStunExpiry[model] = nil -- drop the reference so the destroyed Model can actually be garbage collected
		task.delay(2, function()
			model:Destroy()
		end)
	end

	local effectiveDamageMultiplier = damageMultiplier or 1
	if stats.AttackType == "Explode" then
		runExploderAI(model, stats, humanoid, rootPart, onDeath)
	else
		runChaseAI(model, statsName, stats, humanoid, rootPart, effectiveDamageMultiplier, onDeath)
	end

	return model
end

return ZombieService
