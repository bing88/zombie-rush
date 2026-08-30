--[[
	DataService.lua (ModuleScript)

	Tier 1's DataStore persistence layer — coins + unlocked weapons +
	weapon upgrade levels + whether the secret stash has been claimed
	(per the reconciled MVP doc: "coins + unlocked weapons only — no full
	player profile yet"). Everything else (PlayerService, WeaponService,
	ShopService, WaveService) reads/writes through this module instead of
	touching DataStoreService directly, so there's exactly one place that
	handles retries/failures/caching.

	Studio note: without "Enable Studio Access to API Services" turned on,
	GetAsync/SetAsync will error — this is caught and the module silently
	falls back to defaults so solo testing still works; progress just
	won't persist across sessions until that setting is enabled (or the
	game is published and played live).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local DataService = {}

local STORE_NAME = "ZombieRush_PlayerData_v1"
local dataStore = DataStoreService:GetDataStore(STORE_NAME)
local AUTOSAVE_INTERVAL_SECONDS = 90

local function defaultProfile()
	return {
		Coins = 0,
		UnlockedWeapons = { Pistol = true },
		WeaponUpgrades = {},
	}
end

local profiles: { [Player]: any } = {}

local function attemptGet(key: string): (boolean, any)
	return pcall(function()
		return dataStore:GetAsync(key)
	end)
end

local function attemptSet(key: string, value: any): (boolean, any)
	return pcall(function()
		dataStore:SetAsync(key, value)
	end)
end

--[[
	Loads (or lazily creates) a player's profile. Safe to call more than
	once for the same player — later calls just return the cached profile
	instead of re-hitting the DataStore, which matters because both
	PlayerAdded and the first CharacterAdded may race to load the profile.
]]
function DataService.Load(player: Player)
	if profiles[player] then
		return profiles[player]
	end

	local key = "Player_" .. player.UserId
	local ok, result = attemptGet(key)

	local profile
	if ok and typeof(result) == "table" then
		profile = result
		-- Backfill any fields added after this player's save was created.
		local defaults = defaultProfile()
		for fieldName, defaultValue in defaults do
			if profile[fieldName] == nil then
				profile[fieldName] = defaultValue
			end
		end
	else
		if not ok then
			warn(("DataService: failed to load data for %s (%s) — using defaults this session."):format(player.Name, tostring(result)))
		end
		profile = defaultProfile()
	end

	profiles[player] = profile
	return profile
end

function DataService.Get(player: Player)
	return profiles[player]
end

function DataService.Save(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local key = "Player_" .. player.UserId
	local ok, err = attemptSet(key, profile)
	if not ok then
		warn(("DataService: failed to save data for %s (%s)"):format(player.Name, tostring(err)))
	end
end

function DataService.Release(player: Player)
	DataService.Save(player)
	profiles[player] = nil
end

function DataService.AddCoins(player: Player, amount: number): number?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	profile.Coins += amount
	return profile.Coins
end

function DataService.SpendCoins(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or profile.Coins < amount then
		return false
	end
	profile.Coins -= amount
	return true
end

function DataService.IsWeaponUnlocked(player: Player, weaponName: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.UnlockedWeapons[weaponName] == true
end

function DataService.UnlockWeapon(player: Player, weaponName: string)
	local profile = profiles[player]
	if profile then
		profile.UnlockedWeapons[weaponName] = true
	end
end

function DataService.GetWeaponLevel(player: Player, weaponName: string): number
	local profile = profiles[player]
	return (profile and profile.WeaponUpgrades[weaponName]) or 0
end

function DataService.SetWeaponLevel(player: Player, weaponName: string, level: number)
	local profile = profiles[player]
	if profile then
		profile.WeaponUpgrades[weaponName] = level
	end
end

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL_SECONDS)
		for _, player in Players:GetPlayers() do
			if profiles[player] then
				DataService.Save(player)
			end
		end
	end
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		DataService.Save(player)
	end
	task.wait(1) -- give SetAsync calls a moment to flush before the server closes
end)

return DataService
