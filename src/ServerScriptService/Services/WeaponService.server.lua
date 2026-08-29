--[[
	WeaponService.server.lua

	Server-authoritative shooting. Per the plan (section 5), the client is
	NEVER trusted for damage, ammo, or fire rate. The client only sends
	"I want to fire" with aim data (and "I want to reload"); everything
	else — including what actually gets drawn as a tracer/flash on every
	client — is decided here and broadcast out.

	Tier 0 scope: one weapon (AssaultRifle), single-target hitscan raycast
	from the equipped Tool's muzzle, manual + auto reload, ammo tracked
	server-side per player and synced back to the owner as the source of
	truth (the client's own copy is prediction only, for responsiveness).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local AmmoUpdated = Remotes.AmmoUpdated
local WeaponFired = Remotes.WeaponFired
local ZombieHPChanged = Remotes.ZombieHPChanged

-- Per-player runtime state. Never trust the client's copy of this.
type PlayerWeaponState = {
	WeaponName: string,
	AmmoInMagazine: number,
	LastFireTime: number,
	Reloading: boolean,
}

local playerStates: { [Player]: PlayerWeaponState } = {}

local DEFAULT_WEAPON = "AssaultRifle"

local function getOrCreateState(player: Player): PlayerWeaponState
	local state = playerStates[player]
	if not state then
		local stats = WeaponConfig[DEFAULT_WEAPON]
		state = {
			WeaponName = DEFAULT_WEAPON,
			AmmoInMagazine = stats.MagazineSize,
			LastFireTime = 0,
			Reloading = false,
		}
		playerStates[player] = state
	end
	return state
end

local function syncAmmo(player: Player, state: PlayerWeaponState, stats)
	AmmoUpdated:FireClient(player, state.AmmoInMagazine, stats.MagazineSize, state.Reloading)
end

Players.PlayerAdded:Connect(function(player)
	local state = getOrCreateState(player)
	syncAmmo(player, state, WeaponConfig[state.WeaponName])
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)

--[[
	Finds the equipped Tool's muzzle world position, so shots visually
	originate from the barrel instead of the torso center. Falls back to a
	position near the player's chest if no tool/muzzle is found (shouldn't
	normally happen since PlayerService auto-equips the weapon on spawn).
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

--[[
	Raycasts and applies damage if a zombie was hit.
	Returns (hitZombie, endPosition, damageDealt) — endPosition is used by
	every client to draw the tracer regardless of whether anything was
	actually hit; damageDealt drives the floating damage number.
]]
local function resolveHit(character: Model, stats, origin: Vector3, direction: Vector3): (boolean, Vector3, number)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(origin, direction * stats.Range, raycastParams)
	if not result then
		return false, origin + direction * stats.Range, 0
	end

	local hitInstance = result.Instance
	local zombieModel = hitInstance:FindFirstAncestorOfClass("Model")
	if not zombieModel or not zombieModel:HasTag("Zombie") then
		return false, result.Position, 0
	end

	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, result.Position, 0
	end

	local damage = stats.Damage
	if hitInstance.Name == "Head" then
		damage *= stats.HeadshotMultiplier
	end

	humanoid:TakeDamage(damage)
	ZombieHPChanged:FireAllClients(zombieModel.Name, humanoid.Health, humanoid.MaxHealth)

	return true, result.Position, damage
end

local function startReload(player: Player, state: PlayerWeaponState, stats)
	if state.Reloading or state.AmmoInMagazine >= stats.MagazineSize then
		return
	end

	state.Reloading = true
	syncAmmo(player, state, stats)

	task.delay(stats.ReloadTime, function()
		-- Guard against the player leaving or their state being replaced
		-- mid-reload (e.g. respawn) before firing the completion sync.
		if playerStates[player] ~= state then
			return
		end
		state.AmmoInMagazine = stats.MagazineSize
		state.Reloading = false
		syncAmmo(player, state, stats)
	end)
end

FireWeapon.OnServerEvent:Connect(function(player: Player, aimDirection: Vector3)
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

	local state = getOrCreateState(player)
	local stats = WeaponConfig[state.WeaponName]
	if not stats then
		return
	end

	-- Validate fire rate: reject requests faster than the weapon allows.
	local now = os.clock()
	if now - state.LastFireTime < stats.FireRate then
		return
	end

	-- Validate ammo/reload state.
	if state.Reloading or state.AmmoInMagazine <= 0 then
		return
	end

	state.LastFireTime = now
	state.AmmoInMagazine -= 1
	syncAmmo(player, state, stats)

	-- Apply weapon spread server-side so clients can't send a laser-perfect
	-- direction and bypass spread.
	local spreadRadians = math.rad(stats.Spread)
	local randomAngleX = (math.random() - 0.5) * 2 * spreadRadians
	local randomAngleY = (math.random() - 0.5) * 2 * spreadRadians
	local spreadCFrame = CFrame.new(rootPart.Position, rootPart.Position + aimDirection)
		* CFrame.Angles(randomAngleY, randomAngleX, 0)
	local finalDirection = spreadCFrame.LookVector

	local origin = getMuzzlePosition(character, rootPart)
	local hitZombie, endPosition, damageDealt = resolveHit(character, stats, origin, finalDirection)

	-- Broadcast to ALL clients (not just the shooter) so every player in
	-- the match sees the tracer/muzzle flash/hit spark/damage number,
	-- not just their own.
	WeaponFired:FireAllClients(player, origin, endPosition, hitZombie, damageDealt)

	if state.AmmoInMagazine <= 0 then
		startReload(player, state, stats)
	end
end)

ReloadWeapon.OnServerEvent:Connect(function(player: Player)
	local state = getOrCreateState(player)
	local stats = WeaponConfig[state.WeaponName]
	if not stats then
		return
	end
	startReload(player, state, stats)
end)
