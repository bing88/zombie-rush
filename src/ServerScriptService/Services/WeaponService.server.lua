--[[
	WeaponService.server.lua

	Server-authoritative shooting. Per the plan (section 5), the client is
	NEVER trusted for damage, ammo, fire rate, or even *which weapon* it's
	firing — that's derived here from whichever Tool is actually equipped
	on the character, not anything the client claims.

	Tier 1: generalized from Tier 0's single hardcoded AssaultRifle into
	N weapons with independent per-weapon ammo/reload state, weapon
	switching via Roblox's default Backpack hotbar (Tool.Equipped is what
	we listen to — no custom "switch weapon" remote needed), shotgun-style
	multi-pellet spread, and damage upgrades read from DataService.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local PerkService = require(script.Parent.PerkService)
local DataService = require(script.Parent.DataService)
local InternalSignals = require(script.Parent.InternalSignals)
local DownedState = require(script.Parent.DownedState)
local StatsService = require(script.Parent.StatsService)
local ZombieService = require(script.Parent.ZombieService)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local AmmoUpdated = Remotes.AmmoUpdated
local WeaponFired = Remotes.WeaponFired
local ZombieHPChanged = Remotes.ZombieHPChanged
local BossHPChanged = Remotes.BossHPChanged
local WeaponExploded = Remotes.WeaponExploded

-- Per-player runtime state. Never trust the client's copy of any of this.
type PlayerWeaponState = {
	EquippedWeapon: string,
	Ammo: { [string]: number },
	Reloading: { [string]: boolean },
	LastFireTime: number,
}

local playerStates: { [Player]: PlayerWeaponState } = {}

local function getOrCreateState(player: Player): PlayerWeaponState
	local state = playerStates[player]
	if not state then
		state = {
			EquippedWeapon = WeaponConfig.StartingWeapon,
			Ammo = {},
			Reloading = {},
			LastFireTime = 0,
		}
		playerStates[player] = state
	end
	return state
end

local function getDamageMultiplier(player: Player, weaponName: string): number
	local level = DataService.GetWeaponLevel(player, weaponName)
	if level <= 0 then
		return 1
	end
	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	local levelData = weaponUpgrades and weaponUpgrades.Levels[level]
	local upgradeMultiplier = (levelData and levelData.DamageMultiplier) or 1
	-- Robux DamageBoost stacks multiplicatively on top of coin upgrades
	-- (returns a neutral 1 when unowned, so this is unconditional).
	return upgradeMultiplier * PerkService.GetMultiplier(player, "DamageBoost")
end

--[[
	Upgrade levels scale magazine capacity too, not just damage — see
	UpgradeConfig's MagazineBonus. This is the ONLY place "current max
	magazine size" should be computed from; every other function below
	calls this rather than reading stats.MagazineSize directly, so a
	level-up is reflected everywhere consistently.
]]
local function getMagazineCapacity(player: Player, weaponName: string): number
	local stats = WeaponConfig[weaponName]
	if not stats then
		return 0
	end
	local magPerk = PerkService.GetMultiplier(player, "BigMag")
	local level = DataService.GetWeaponLevel(player, weaponName)
	if level <= 0 then
		return math.floor(stats.MagazineSize * magPerk)
	end
	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	local levelData = weaponUpgrades and weaponUpgrades.Levels[level]
	local bonus = (levelData and levelData.MagazineBonus) or 0
	-- BigMag scales the FINAL capacity (base + upgrade bonus) rather
	-- than only the base, so it keeps its value as upgrades come in.
	-- Floored so capacity stays a whole number of rounds.
	return math.floor((stats.MagazineSize + bonus) * magPerk)
end

local function syncAmmo(player: Player, state: PlayerWeaponState)
	local weaponName = state.EquippedWeapon
	local stats = WeaponConfig[weaponName]
	if not stats then
		return
	end
	local capacity = getMagazineCapacity(player, weaponName)
	local ammo = state.Ammo[weaponName] or capacity
	AmmoUpdated:FireClient(player, weaponName, ammo, capacity, state.Reloading[weaponName] == true)
end

InternalSignals.SetAmmoRefreshHandler(function(player: Player)
	local state = playerStates[player]
	if state then
		syncAmmo(player, state)
	end
end)

--[[
	Connects Tool.Equipped so we always know the *actual* equipped weapon
	server-side, regardless of whether the client switched via number key
	or clicking the Backpack hotbar (both just equip a Tool — no remote
	involved). Called once per container per life; ChildAdded catches
	tools added later (shop purchases, or the starter weapon PlayerService
	parents in after this connects).
]]
local function trackTool(player: Player, state: PlayerWeaponState, tool: Instance)
	if not tool:IsA("Tool") or not WeaponConfig[tool.Name] then
		return
	end
	tool.Equipped:Connect(function()
		local weaponName = tool.Name
		state.EquippedWeapon = weaponName
		if state.Ammo[weaponName] == nil then
			state.Ammo[weaponName] = getMagazineCapacity(player, weaponName)
		end
		syncAmmo(player, state)
	end)
end

local function watchContainer(player: Player, state: PlayerWeaponState, container: Instance)
	for _, child in container:GetChildren() do
		trackTool(player, state, child)
	end
	container.ChildAdded:Connect(function(child)
		trackTool(player, state, child)
	end)
end

Players.PlayerAdded:Connect(function(player)
	local state = getOrCreateState(player)
	local backpack = player:WaitForChild("Backpack")
	watchContainer(player, state, backpack)

	player.CharacterAdded:Connect(function(character)
		state.Ammo = {}
		state.Reloading = {}
		watchContainer(player, state, character)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)

--[[
	Finds the equipped Tool's muzzle world position, so shots visually
	originate from the barrel instead of the torso center. Falls back to
	a position near the player's chest if no tool/muzzle is found.
]]
local function getMuzzlePosition(character: Model, rootPart: BasePart): Vector3
	local tool = character:FindFirstChildOfClass("Tool")
	local handle = tool and tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	return rootPart.Position + Vector3.new(0, 1, 0)
end

-- How far the client's self-reported muzzle position is allowed to
-- diverge from the server's own (replication-lagged) copy of the
-- character before it's rejected as implausible. Generous enough to
-- cover legitimate movement during normal ping, nowhere near enough to
-- let someone claim a shot originated somewhere they actually aren't.
local MAX_CLAIMED_ORIGIN_DEVIATION_STUDS = 12

--[[
	Prefers the client's self-reported muzzle position over the server's
	own replicated copy of the character, when it's present and passes a
	plausibility check — this fixes visible effect lag while moving: the
	server's own copy of a moving player's position is behind their
	actual (client-predicted) position by roughly their ping, so effects
	built from it visibly trail a moving shooter. This never affects
	actual hit detection (the raycast below still runs server-side from
	whatever origin is returned here, and damage is always the server's
	own determination) — it only changes where the tracer/muzzle-flash
	visually starts from. Falls back to the server-computed position if
	the claim is missing, malformed, or too far from where the server
	independently believes the character is.
]]
local function resolveFireOrigin(character: Model, rootPart: BasePart, claimedOrigin: unknown): Vector3
	local serverOrigin = getMuzzlePosition(character, rootPart)
	if typeof(claimedOrigin) ~= "Vector3" then
		return serverOrigin
	end
	if (claimedOrigin - serverOrigin).Magnitude > MAX_CLAIMED_ORIGIN_DEVIATION_STUDS then
		return serverOrigin
	end
	return claimedOrigin
end

--[[
	Applies AOE "splash" damage around an explosion center to every live
	zombie within BlastRadius — see WeaponConfig's optional
	ExplodeOnImpact/BlastRadius/BlastDamage fields (mirrors the official
	Weapons Kit's "Exploding projectiles" option:
	https://create.roblox.com/docs/resources/weapons-kit#exploding-
	projectiles). Called once per pellet, at wherever that pellet's
	raycast ended up (zombie or plain geometry) — a splash weapon still
	damages nearby zombies even on a direct miss, same as a real
	grenade/rocket. Also fires WeaponExploded so every client plays the
	same blast VFX/sound already used for an Exploder zombie's own
	detonation (see EffectsController.Init's WeaponExploded handler).

	excludeModel skips one zombie (the one that was just directly hit
	and already took its own finalDamage/headshot-multiplied hit,
	including StatsService/HP-broadcast bookkeeping) so a dead-center
	explosion doesn't double-dip that same zombie a second time via the
	splash pass too.
]]
local function applyExplosionSplash(player: Player, stats, center: Vector3, excludeModel: Model?)
	local radius = stats.BlastRadius or 8
	local blastDamage = stats.BlastDamage or 100

	for _, zombieModel in CollectionService:GetTagged("Zombie") do
		if zombieModel == excludeModel then
			continue
		end

		local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
		local rootPart = humanoid and humanoid.RootPart
		if not humanoid or not rootPart or humanoid.Health <= 0 then
			continue
		end

		local distance = (rootPart.Position - center).Magnitude
		if distance > radius then
			continue
		end

		-- Linear falloff: full damage at the blast center, ~15% at the
		-- radius edge — same shape as the Exploder zombie's own
		-- detonation damage against players (see ZombieService).
		local falloff = 1 - (distance / radius)
		local splashDamage = blastDamage * math.max(falloff, 0.15)

		zombieModel:SetAttribute("LastHitPlayerId", player.UserId)
		humanoid:TakeDamage(splashDamage)
		StatsService.RecordDamage(player, splashDamage)

		ZombieHPChanged:FireAllClients(zombieModel.Name, humanoid.Health, humanoid.MaxHealth)
		if zombieModel:HasTag("Boss") then
			BossHPChanged:FireAllClients(humanoid.Health, humanoid.MaxHealth)
		end
	end

	WeaponExploded:FireAllClients(center, radius)
end

--[[
	Raycasts a single pellet and applies damage if a live zombie was hit.
	Tags the zombie with LastHitPlayerId so ZombieService can credit the
	right player for the kill (and coin reward) on death. Also records
	damage/headshot-kill stats via StatsService for the scoreboard and
	session objective.
	Returns a hit-result table for the WeaponFired broadcast — Killed
	drives the client's hitmarker/kill-sound distinction. SurfaceNormal/
	SurfaceMaterial are only ever set for a MISS that still hit plain
	environment geometry (never a zombie, never anything with a
	Humanoid) — that's the "hit marks" specialized option
	(https://create.roblox.com/docs/resources/weapons-kit#hit-marks):
	EffectsController uses them to stick a fading bullet-hole/scorch
	mark on the wall/floor a shot actually hit, which would look wrong
	glued to a moving/dying character instead.
]]
local function resolvePellet(player: Player, character: Model, stats, damage: number, origin: Vector3, direction: Vector3)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(origin, direction * stats.Range, raycastParams)
	if not result then
		local endPosition = origin + direction * stats.Range
		if stats.ExplodeOnImpact then
			applyExplosionSplash(player, stats, endPosition)
		end
		return { EndPosition = endPosition, Hit = false, Damage = 0, Killed = false }
	end

	local hitInstance = result.Instance
	local zombieModel = hitInstance:FindFirstAncestorOfClass("Model")
	local isZombie = zombieModel ~= nil and zombieModel:HasTag("Zombie")

	if not isZombie then
		if stats.ExplodeOnImpact then
			applyExplosionSplash(player, stats, result.Position)
		end

		-- Skip hit-mark data for anything with a Humanoid ancestor
		-- (another player's character, or a zombie that's momentarily
		-- untagged) — only plain static geometry gets a decal. Reuses
		-- zombieModel from above (the nearest ancestor Model, zombie-
		-- tagged or not) rather than searching again.
		local hasHumanoidAncestor = zombieModel ~= nil and zombieModel:FindFirstChildOfClass("Humanoid") ~= nil
		if hasHumanoidAncestor then
			return { EndPosition = result.Position, Hit = false, Damage = 0, Killed = false }
		end

		return {
			EndPosition = result.Position,
			Hit = false,
			Damage = 0,
			Killed = false,
			SurfaceNormal = result.Normal,
			SurfaceMaterial = result.Material,
		}
	end

	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return { EndPosition = result.Position, Hit = false, Damage = 0, Killed = false }
	end

	local finalDamage = damage
	local isHeadshot = hitInstance.Name == "Head"
	if isHeadshot then
		finalDamage *= stats.HeadshotMultiplier
	end

	zombieModel:SetAttribute("LastHitPlayerId", player.UserId)
	humanoid:TakeDamage(finalDamage)
	StatsService.RecordDamage(player, finalDamage)

	local killed = humanoid.Health <= 0
	if killed and isHeadshot then
		StatsService.RecordHeadshotKill(player)
	end

	if not killed then
		-- Killing blows get their own separate, more theatrical knockback
		-- (see ZombieService's applyDeathKnockback via onDeath) — this is
		-- just for hits the zombie survives, so getting shot always reads
		-- as an impact rather than only mattering on the kill.
		ZombieService.ApplyHitKnockback(zombieModel, direction)
	end

	ZombieHPChanged:FireAllClients(zombieModel.Name, humanoid.Health, humanoid.MaxHealth)
	if zombieModel:HasTag("Boss") then
		BossHPChanged:FireAllClients(humanoid.Health, humanoid.MaxHealth)
	end

	if stats.ExplodeOnImpact then
		applyExplosionSplash(player, stats, result.Position, zombieModel)
	end

	return { EndPosition = result.Position, Hit = true, Damage = finalDamage, Killed = killed }
end

local function startReload(player: Player, state: PlayerWeaponState, weaponName: string, stats)
	local capacity = getMagazineCapacity(player, weaponName)
	if state.Reloading[weaponName] or (state.Ammo[weaponName] or capacity) >= capacity then
		return
	end

	state.Reloading[weaponName] = true
	syncAmmo(player, state)

	-- FastReload multiplies reload TIME (its multiplier is < 1), and is
	-- a neutral 1 when unowned.
	local reloadSeconds = stats.ReloadTime * PerkService.GetMultiplier(player, "FastReload")
	task.delay(reloadSeconds, function()
		-- Guard against the player leaving or their state resetting
		-- (e.g. respawn) mid-reload before firing the completion sync.
		if playerStates[player] ~= state or not state.Reloading[weaponName] then
			return
		end
		-- Recompute capacity at completion time rather than reusing the
		-- value captured at reload-start, in case the player upgraded
		-- this weapon mid-reload (rare, but cheap to get right).
		state.Ammo[weaponName] = getMagazineCapacity(player, weaponName)
		state.Reloading[weaponName] = false
		if state.EquippedWeapon == weaponName then
			syncAmmo(player, state)
		end
	end)
end

FireWeapon.OnServerEvent:Connect(function(player: Player, aimDirection: Vector3, claimedOrigin: unknown)
	if typeof(aimDirection) ~= "Vector3" or aimDirection.Magnitude < 0.5 then
		return
	end
	aimDirection = aimDirection.Unit

	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return
	end

	if DownedState.IsDowned(player) then
		return -- can't fight back while bleeding out, waiting on a teammate revive
	end

	local state = getOrCreateState(player)
	local weaponName = state.EquippedWeapon
	local stats = WeaponConfig[weaponName]
	if not stats then
		return
	end

	-- The client can only ever fire whatever Tool is actually equipped —
	-- this also implicitly enforces weapon ownership, since a Tool only
	-- exists in the character if PlayerService/ShopService gave it out
	-- for an unlocked weapon.
	local equippedTool = character:FindFirstChildOfClass("Tool")
	if not equippedTool or equippedTool.Name ~= weaponName then
		return
	end

	-- Validate fire rate: reject requests faster than the weapon allows.
	local now = os.clock()
	if now - state.LastFireTime < stats.FireRate then
		return
	end

	local ammo = state.Ammo[weaponName] or getMagazineCapacity(player, weaponName)
	if state.Reloading[weaponName] or ammo <= 0 then
		return
	end

	state.LastFireTime = now
	state.Ammo[weaponName] = ammo - 1
	syncAmmo(player, state)

	local baseDamage = stats.Damage * getDamageMultiplier(player, weaponName)
	local origin = resolveFireOrigin(character, rootPart, claimedOrigin)
	local spreadRadians = math.rad(stats.Spread)

	local hits = {}
	for _ = 1, stats.Pellets do
		-- Apply weapon spread server-side per pellet so clients can't
		-- send a laser-perfect direction and bypass spread.
		local randomAngleX = (math.random() - 0.5) * 2 * spreadRadians
		local randomAngleY = (math.random() - 0.5) * 2 * spreadRadians
		local spreadCFrame = CFrame.new(rootPart.Position, rootPart.Position + aimDirection)
			* CFrame.Angles(randomAngleY, randomAngleX, 0)
		local finalDirection = spreadCFrame.LookVector

		table.insert(hits, resolvePellet(player, character, stats, baseDamage, origin, finalDirection))
	end

	-- Broadcast to ALL clients (not just the shooter) so every player in
	-- the match sees the tracer/muzzle flash/hit spark/damage numbers.
	WeaponFired:FireAllClients(player, weaponName, origin, hits)

	if state.Ammo[weaponName] <= 0 then
		startReload(player, state, weaponName, stats)
	end
end)

ReloadWeapon.OnServerEvent:Connect(function(player: Player)
	local state = getOrCreateState(player)
	local weaponName = state.EquippedWeapon
	local stats = WeaponConfig[weaponName]
	if not stats then
		return
	end
	startReload(player, state, weaponName, stats)
end)
