--[[
	LeaderboardService.lua (ModuleScript)

	Global "best wave reached" leaderboard via OrderedDataStore. Only
	writes when a player's recorded best actually improves — never
	writes on every wave — to stay well under DataStore write-rate
	limits even with several concurrent players progressing at once.

	Studio note: same caveat as DataService — without "Enable Studio
	Access to API Services", these calls fail and are caught; the
	leaderboard just comes back empty rather than erroring.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local LeaderboardService = {}

local orderedStore = DataStoreService:GetOrderedDataStore("ZombieRush_BestWave_v1")

-- Cached per-player best-known value so we don't re-read the DataStore
-- on every single wave a player reaches within one session.
local sessionBest: { [Player]: number } = {}

Remotes.RequestLeaderboard.OnServerEvent:Connect(function(player: Player)
	LeaderboardService.SendTopEntries(player)
end)

Players.PlayerRemoving:Connect(function(player)
	sessionBest[player] = nil
end)

--[[
	Call whenever a player reaches a new wave (or beats the boss).
	Cheap no-op if it doesn't beat their own session-cached best; only
	touches the DataStore when it might actually be a new record.
]]
function LeaderboardService.ReportWaveReached(player: Player, waveNumber: number)
	if (sessionBest[player] or 0) >= waveNumber then
		return
	end

	local key = "Player_" .. player.UserId
	task.spawn(function()
		local ok, existing = pcall(function()
			return orderedStore:GetAsync(key)
		end)
		local currentBest = (ok and typeof(existing) == "number") and existing or 0

		if waveNumber <= currentBest then
			sessionBest[player] = currentBest
			return
		end

		local setOk, err = pcall(function()
			orderedStore:SetAsync(key, waveNumber)
		end)
		if setOk then
			sessionBest[player] = waveNumber
		else
			warn("LeaderboardService: failed to save best wave for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

--[[
	Fetches the top 10 and sends them to the requesting client. Resolves
	UserIds to display names best-effort — a departed/renamed player
	falls back to showing their UserId rather than failing the whole list.
]]
function LeaderboardService.SendTopEntries(player: Player)
	task.spawn(function()
		local ok, pages = pcall(function()
			return orderedStore:GetSortedAsync(false, 10)
		end)
		if not ok then
			warn("LeaderboardService: failed to fetch leaderboard: " .. tostring(pages))
			Remotes.LeaderboardData:FireClient(player, {})
			return
		end

		local topPage = (pages :: any):GetCurrentPage()
		local entries = {}
		for _, entry in topPage do
			local userId = tonumber((entry.key :: string):match("_(%d+)$"))
			local displayName = tostring(userId)
			if userId then
				local nameOk, name = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				if nameOk then
					displayName = name
				end
			end
			table.insert(entries, { Name = displayName, BestWave = entry.value })
		end

		Remotes.LeaderboardData:FireClient(player, entries)
	end)
end

return LeaderboardService
