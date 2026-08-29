--[[
	WeaponService.server.lua

	Server-authoritative shooting. Per the plan (section 5), the client is
	NEVER trusted for damage, ammo, or fire rate. The client only sends
	"I want to fire" with aim data; everything else happens here.

	Tier 0 scope: one weapon (AssaultRifle), single-target hitscan raycast,
	no reload UI polish, ammo tracked server-side per player.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local FireWeapon = Remotes.FireWeapon
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

Players.PlayerAdded:Connect(function(player)
	getOrCreateState(player)
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)

--[[
	Validates and resolves a raycast hit into damage applied to a zombie.
	Returns true if a zombie was hit, false otherwise.
]]
local function resolveHit(player: Player, stats, origin: Vector3, direction: Vector3): boolean
	local character = player.Character
	if not character then
		return false
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(origin, direction * stats.Range, raycastParams)
	if not result then
		return false
	end

	local hitInstance = result.Instance
	local zombieModel = hitInstance:FindFirstAncestorOfClass("Model")
	if not zombieModel or not zombieModel:HasTag("Zombie") then
		return false
	end

	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local damage = stats.Damage
	if hitInstance.Name == "Head" then
		damage *= stats.HeadshotMultiplier
	end

	humanoid:TakeDamage(damage)

	ZombieHPChanged:FireAllClients(zombieModel.Name, humanoid.Health, humanoid.MaxHealth)

	return true
end

FireWeapon.OnServerEvent:Connect(function(player: Player, aimDirection: Vector3)
	-- Validate input shape before trusting anything about it.
	if typeof(aimDirection) ~= "Vector3" then
		return
	end

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

	-- Validate ammo.
	if state.Reloading or state.AmmoInMagazine <= 0 then
		return
	end

	state.LastFireTime = now
	state.AmmoInMagazine -= 1

	-- Apply weapon spread server-side so clients can't send a laser-perfect
	-- direction and bypass spread.
	local spreadRadians = math.rad(stats.Spread)
	local randomAngleX = (math.random() - 0.5) * 2 * spreadRadians
	local randomAngleY = (math.random() - 0.5) * 2 * spreadRadians
	local spreadCFrame = CFrame.new(rootPart.Position, rootPart.Position + aimDirection)
		* CFrame.Angles(randomAngleY, randomAngleX, 0)
	local finalDirection = spreadCFrame.LookVector

	resolveHit(player, stats, rootPart.Position, finalDirection)

	-- Auto-reload when empty. Tier 0 keeps this simple; Tier 1 can add a
	-- manual reload input + animation.
	if state.AmmoInMagazine <= 0 then
		state.Reloading = true
		task.delay(stats.ReloadTime, function()
			if playerStates[player] == state then
				state.AmmoInMagazine = stats.MagazineSize
				state.Reloading = false
			end
		end)
	end
end)
