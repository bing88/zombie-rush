--[[
	DataService.lua (ModuleScript)

	The DataStore persistence layer. Everything that survives a run lives
	here; everything that doesn't lives in RunLoadoutService.

	THIS USED TO STORE COINS, UNLOCKED WEAPONS AND UPGRADE LEVELS, and
	no longer does. Persisting those meant power came from a savings
	account rather than from the run — a player with a few runs banked
	bought every weapon and maxed its upgrades in wave 1 and never met
	the difficulty curve again. They're now run-scoped (RunLoadoutService)
	and the only thing persisted in their place is MetaXP, which unlocks
	which weapons may APPEAR in the run shop and never grants power
	itself. See MetaConfig for why that distinction is the whole design.

	Old saves still contain the retired Coins/UnlockedWeapons/
	WeaponUpgrades keys. They're deliberately left alone rather than
	migrated away: nothing reads them, they cost a few bytes, and
	stripping them would mean a destructive write over every existing
	profile to buy nothing. A returning player's banked coins simply stop
	being meaningful, which is the intent.

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
		-- Total lifetime meta XP. The level is DERIVED from this
		-- (MetaConfig.GetLevel) rather than stored alongside it, so the
		-- two can never disagree and retuning the level curve
		-- automatically re-grades every existing player instead of
		-- needing a migration.
		MetaXP = 0,
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

function DataService.GetMetaXP(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	-- Coerced rather than trusted: a profile written before MetaXP
	-- existed backfills it (see Load), but a corrupted save could still
	-- hand back a non-number, and every caller treats this as arithmetic.
	local xp = profile.MetaXP
	return typeof(xp) == "number" and xp or 0
end

--[[
	Adds run-end XP and returns the new total, or nil if the player's
	profile isn't loaded (they left mid-run). Never subtracts: there is
	no mechanic that takes meta progress away, and a negative amount here
	would be a bug rather than a feature.
]]
function DataService.AddMetaXP(player: Player, amount: number): number?
	local profile = profiles[player]
	if not profile or amount <= 0 then
		return nil
	end
	profile.MetaXP = DataService.GetMetaXP(player) + amount
	return profile.MetaXP
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
