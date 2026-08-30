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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local DataService = require(script.Parent.DataService)
local InternalSignals = require(script.Parent.InternalSignals)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local AmmoUpdated = Remotes.AmmoUpdated
local WeaponFired = Remotes.WeaponFired
local ZombieHPChanged = Remotes.ZombieHPChanged
local BossHPChanged = Remotes.BossHPChanged

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
	return (levelData and levelData.DamageMultiplier) or 1
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
	local level = DataService.GetWeaponLevel(player, weaponName)
	if level <= 0 then
		return stats.MagazineSize
	end
	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	local levelData = weaponUpgrades and weaponUpgrades.Levels[level]
	local bonus = (levelData and levelData.MagazineBonus) or 0
	return stats.MagazineSize + bonus
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

--[[
	Raycasts a single pellet and applies damage if a live zombie was hit.
	Tags the zombie with LastHitPlayerId so ZombieService can credit the
	right player for the kill (and coin reward) on death.
	Returns a hit-result table for the WeaponFired broadcast.
]]
local function resolvePellet(player: Player, character: Model, stats, damage: number, origin: Vector3, direction: Vector3)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(origin, direction * stats.Range, raycastParams)
	if not result then
		return { EndPosition = origin + direction * stats.Range, Hit = false, Damage = 0 }
	end

	local hitInstance = result.Instance
	local zombieModel = hitInstance:FindFirstAncestorOfClass("Model")
	if not zombieModel or not zombieModel:HasTag("Zombie") then
		return { EndPosition = result.Position, Hit = false, Damage = 0 }
	end

	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return { EndPosition = result.Position, Hit = false, Damage = 0 }
	end

	local finalDamage = damage
	if hitInstance.Name == "Head" then
		finalDamage *= stats.HeadshotMultiplier
	end

	zombieModel:SetAttribute("LastHitPlayerId", player.UserId)
	humanoid:TakeDamage(finalDamage)
	ZombieHPChanged:FireAllClients(zombieModel.Name, humanoid.Health, humanoid.MaxHealth)
	if zombieModel:HasTag("Boss") then
		BossHPChanged:FireAllClients(humanoid.Health, humanoid.MaxHealth)
	end

	return { EndPosition = result.Position, Hit = true, Damage = finalDamage }
end

local function startReload(player: Player, state: PlayerWeaponState, weaponName: string, stats)
	local capacity = getMagazineCapacity(player, weaponName)
	if state.Reloading[weaponName] or (state.Ammo[weaponName] or capacity) >= capacity then
		return
	end

	state.Reloading[weaponName] = true
	syncAmmo(player, state)

	task.delay(stats.ReloadTime, function()
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
	local origin = getMuzzlePosition(character, rootPart)
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
