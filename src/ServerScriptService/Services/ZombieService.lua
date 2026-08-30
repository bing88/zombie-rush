--[[
	ZombieService.lua (ModuleScript)

	Tier 1: spawns Normal/Fast/Tank/Boss zombies on demand (WaveService
	decides *when* and *how many* — this module only knows how to spawn
	one and run its AI). Converted from Tier 0's self-running .server.lua
	into a ModuleScript so WaveService can drive spawning explicitly
	instead of an endless trickle loop.

	AI: Normal/Fast stay on cheap direct-chase (no PathfindingService).
	Tank/Boss use PathfindingService per the reconciled plan's open
	decision #2, since there are far fewer of them concurrently and they
	benefit more from routing around cover. Boss additionally has a
	simple 2-phase "enrage" at low HP (faster, harder-hitting, visibly
	redder) — see ZombieConfig's Enrage* fields.

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
local ZOMBIE_ASSET_IDS: { [string]: number } = {
	Normal = 3924238625,
	Fast = 82664805038905,
	Tank = 14000778389,
	Boss = 158642843,
}

-- Whichever of these scripts exist are purely cosmetic (walk/idle
-- animation playback, footstep/groan/death audio) and layer on top of
-- our own AI without conflict, so they're the only ones kept. Everything
-- else — most importantly any built-in health-regen or roam/attack AI
-- script the asset ships with — is stripped, since our server-authoritative
-- HP + Heartbeat/PathfindingService AI below must be the sole authority.
local KEPT_ZOMBIE_SCRIPT_NAMES = { Animate = true, RbxNpcSounds = true }

local activeZombieCount = 0

local zombieDiedBindable = Instance.new("BindableEvent")
ZombieService.ZombieDied = zombieDiedBindable.Event -- (statsName: string, killerPlayer: Player?, coinReward: number)

function ZombieService.GetActiveCount(): number
	return activeZombieCount
end

--[[
	Builds a minimal procedural zombie rig, scaled/colored per
	ZombieConfig. Still used for Fast/Tank/Boss (and as a Normal fallback
	if the real asset fails to load) — no art pipeline exists for those
	yet, same rationale as Tier 0.
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

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = stats.MaxHP
	humanoid.Health = stats.MaxHP
	humanoid.WalkSpeed = stats.WalkSpeed
	humanoid.Parent = model

	model.PrimaryPart = rootPart

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

	for _, descendant in template:GetDescendants() do
		if (descendant:IsA("Script") or descendant:IsA("LocalScript")) and not KEPT_ZOMBIE_SCRIPT_NAMES[descendant.Name] then
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

--[[ Cheap direct-chase AI for Normal/Fast/Ranged — no PathfindingService. ]]
local function runDirectChaseAI(model: Model, stats, humanoid: Humanoid, rootPart: BasePart, damageMultiplier: number, onDeath: () -> ())
	local lastAttackTime = 0
	local aiConnection: RBXScriptConnection

	humanoid.Died:Connect(function()
		if aiConnection then
			aiConnection:Disconnect()
		end
		activeZombieCount -= 1
		onDeath()
	end)

	aiConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or humanoid.Health <= 0 then
			return
		end

		local targetRoot = findNearestPlayerRoot(rootPart.Position)
		if not targetRoot then
			humanoid:MoveTo(rootPart.Position) -- idle in place
			return
		end

		local distance = (targetRoot.Position - rootPart.Position).Magnitude
		local canAttack = distance <= stats.AttackRange
			and hasLineOfSight(rootPart.Position, targetRoot.Position, model)

		if not canAttack then
			-- Still moving toward the target even when "in range" but
			-- blocked by cover, instead of stopping dead at the obstacle.
			humanoid:MoveTo(targetRoot.Position)
		else
			humanoid:MoveTo(rootPart.Position) -- stop to attack

			local now = os.clock()
			if now - lastAttackTime >= stats.AttackCooldown then
				lastAttackTime = now
				local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")

				if stats.AttackType == "Ranged" then
					-- Broadcast first so the visual and the damage land
					-- in the same frame — this is a hitscan attack
					-- (instant damage), the travel-time look is purely
					-- cosmetic on the client.
					ZombieRangedAttack:FireAllClients(model.Name, rootPart.Position, targetRoot.Position)
				end

				if targetHumanoid and targetHumanoid.Health > 0 then
					targetHumanoid:TakeDamage(stats.AttackDamage * damageMultiplier)
				end
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
]]
local function runExploderAI(model: Model, stats, humanoid: Humanoid, rootPart: BasePart, onDeath: () -> ())
	local aiConnection: RBXScriptConnection
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
		if aiConnection then
			aiConnection:Disconnect()
		end
		detonate() -- still pops even if it died from being shot rather than reaching a player
		activeZombieCount -= 1
		onDeath()
	end)

	aiConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or humanoid.Health <= 0 or detonated then
			return
		end

		local targetRoot = findNearestPlayerRoot(rootPart.Position)
		if not targetRoot then
			humanoid:MoveTo(rootPart.Position)
			return
		end

		local distance = (targetRoot.Position - rootPart.Position).Magnitude
		if distance <= stats.AttackRange and hasLineOfSight(rootPart.Position, targetRoot.Position, model) then
			detonate()
		else
			humanoid:MoveTo(targetRoot.Position)
		end
	end)
end

--[[
	PathfindingService-driven AI for Tank/Boss. Recomputes a path
	periodically (not every frame — pathfinding is comparatively
	expensive) and falls back to direct MoveTo if computing a path fails,
	so a zombie never just stalls forever on a bad path.

	Boss additionally tracks an "enraged" flag: once HP drops to
	EnrageHPFraction, WalkSpeed/AttackDamage/AttackCooldown swap to the
	Enrage* stats and every part tints red as a readable phase-2 tell.
]]
local function runPathfindingAI(model: Model, statsName: string, stats, humanoid: Humanoid, rootPart: BasePart, damageMultiplier: number, onDeath: () -> ())
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

	task.spawn(function()
		local lastPathComputeTime = 0
		local waypoints: { PathWaypoint } = {}
		local waypointIndex = 1
		local lastAttackTime = 0
		local lastStuckCheckTime = os.clock()
		local lastStuckCheckPosition = rootPart.Position

		while alive and model.Parent do
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
				humanoid:MoveTo(rootPart.Position)
				local cooldown = enraged and stats.EnrageAttackCooldown or stats.AttackCooldown
				if now - lastAttackTime >= cooldown then
					lastAttackTime = now
					local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
					if targetHumanoid and targetHumanoid.Health > 0 then
						local damage = enraged and stats.EnrageAttackDamage or stats.AttackDamage
						targetHumanoid:TakeDamage(damage * damageMultiplier)
					end
				end
				-- Don't let time spent attacking count against the stuck
				-- watchdog below once it resumes chasing.
				lastStuckCheckTime = now
				lastStuckCheckPosition = rootPart.Position
				task.wait(0.2)
				continue
			end

			-- Stuck watchdog: if it's supposed to be travelling but has
			-- barely moved in the last second (wedged against a crate/
			-- wall corner PathfindingService routed it too close to),
			-- force a fresh path computation instead of grinding in place
			-- for the rest of the wave.
			if now - lastStuckCheckTime > 1 then
				local moved = (rootPart.Position - lastStuckCheckPosition).Magnitude
				if moved < 1.5 then
					lastPathComputeTime = 0
				end
				lastStuckCheckTime = now
				lastStuckCheckPosition = rootPart.Position
			end

			if now - lastPathComputeTime > 1.5 or waypointIndex > #waypoints then
				lastPathComputeTime = now
				local path = PathfindingService:CreatePath({
					AgentRadius = 2,
					AgentHeight = 5,
					AgentCanJump = false,
				})
				local computeOk = pcall(function()
					path:ComputeAsync(rootPart.Position, targetRoot.Position)
				end)
				if computeOk and path.Status == Enum.PathStatus.Success then
					waypoints = path:GetWaypoints()
					waypointIndex = 2 -- waypoint 1 is just the zombie's current position
				else
					waypoints = {}
					waypointIndex = 1
				end
			end

			local waypoint = waypoints[waypointIndex]
			if waypoint then
				humanoid:MoveTo(waypoint.Position)
				-- Scale the wait by how far this waypoint actually is
				-- (a flat 2s cap could abandon a long leg early, or make
				-- a slow Tank cut a corner into the very obstacle the
				-- path was routing around); a "close enough" break lets
				-- it move on immediately without waiting out the full
				-- timeout if MoveToFinished doesn't fire cleanly.
				local waypointDistance = (waypoint.Position - rootPart.Position).Magnitude
				local timeout = math.clamp(waypointDistance / math.max(stats.WalkSpeed, 1) + 1, 1, 4)
				local reached = false
				local moveToFinishedConnection = humanoid.MoveToFinished:Connect(function()
					reached = true
				end)
				local waited = 0
				while not reached and waited < timeout and alive and model.Parent do
					task.wait(0.1)
					waited += 0.1
					if (waypoint.Position - rootPart.Position).Magnitude < 3 then
						break
					end
				end
				moveToFinishedConnection:Disconnect()
				waypointIndex += 1
			else
				-- No usable path this cycle; fall back to direct movement
				-- so the zombie doesn't stand still forever.
				humanoid:MoveTo(targetRoot.Position)
				task.wait(0.3)
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
		local killerPlayer: Player? = nil
		local killerUserId = model:GetAttribute("LastHitPlayerId")
		if killerUserId then
			killerPlayer = Players:GetPlayerByUserId(killerUserId)
		end
		zombieDiedBindable:Fire(statsName, killerPlayer, stats.CoinReward)
		task.delay(2, function()
			model:Destroy()
		end)
	end

	local effectiveDamageMultiplier = damageMultiplier or 1
	if stats.AttackType == "Explode" then
		runExploderAI(model, stats, humanoid, rootPart, onDeath)
	elseif stats.UsesPathfinding then
		runPathfindingAI(model, statsName, stats, humanoid, rootPart, effectiveDamageMultiplier, onDeath)
	else
		runDirectChaseAI(model, stats, humanoid, rootPart, effectiveDamageMultiplier, onDeath)
	end

	return model
end

return ZombieService
