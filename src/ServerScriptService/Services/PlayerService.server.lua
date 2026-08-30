--[[
	PlayerService.server.lua

	Tier 1: HP tracking, death, respawn, DataService profile load/release,
	and giving each player Tools for every weapon they own (not just one
	auto-equipped weapon like Tier 0 — see WeaponConfig.Order). WaveService
	handles moving a freshly-spawned character into the arena if a match
	is already underway (see MatchState); this script only ever spawns
	players at the map's default SpawnLocation (the lobby).
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)
local DataService = require(script.Parent.DataService)

local PlayerHPChanged = Remotes.PlayerHPChanged
local PlayerDied = Remotes.PlayerDied
local CoinsUpdated = Remotes.CoinsUpdated
local WeaponsOwned = Remotes.WeaponsOwned

local RESPAWN_DELAY_SECONDS = 3

--[[
	Load is idempotent (see DataService), so calling this from both
	PlayerAdded and CharacterAdded is safe and protects against
	CharacterAdded firing before the PlayerAdded handler's own Load call
	(which can yield on a real DataStore network round-trip) finishes.
]]
local function ensureProfileLoaded(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		profile = DataService.Load(player)
		CoinsUpdated:FireClient(player, profile.Coins)
	end
	return profile
end

local function syncOwnedWeapons(player: Player)
	local owned = {}
	local levels = {}
	for _, weaponName in WeaponConfig.Order do
		owned[weaponName] = DataService.IsWeaponUnlocked(player, weaponName)
		levels[weaponName] = DataService.GetWeaponLevel(player, weaponName)
	end
	WeaponsOwned:FireClient(player, owned, levels)
end

--[[
	Rebuilds the Backpack's weapon Tools from scratch every spawn. Old
	Tool instances died with the previous character (if equipped) — but
	the Backpack itself persists across respawns, so anything still
	sitting in it from the previous life must be cleared first or it'll
	silently duplicate on every death.
]]
local function giveOwnedWeapons(player: Player, character: Model)
	local backpack = player:WaitForChild("Backpack")
	for _, child in backpack:GetChildren() do
		child:Destroy()
	end

	for _, weaponName in WeaponConfig.Order do
		if DataService.IsWeaponUnlocked(player, weaponName) then
			local tool = WeaponModelFactory.CreateTool(weaponName)
			tool.Parent = backpack
		end
	end

	local starter = backpack:FindFirstChild(WeaponConfig.StartingWeapon)
	if starter then
		starter.Parent = character
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	ensureProfileLoaded(player)
	giveOwnedWeapons(player, character)
	syncOwnedWeapons(player)

	humanoid.HealthChanged:Connect(function(newHealth)
		PlayerHPChanged:FireClient(player, newHealth, humanoid.MaxHealth)
	end)

	humanoid.Died:Connect(function()
		PlayerDied:FireClient(player)
		task.delay(RESPAWN_DELAY_SECONDS, function()
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end)

	-- Fire once immediately so the UI has correct values on spawn.
	PlayerHPChanged:FireClient(player, humanoid.Health, humanoid.MaxHealth)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	ensureProfileLoaded(player)
end)

Players.PlayerRemoving:Connect(function(player)
	DataService.Release(player)
end)
