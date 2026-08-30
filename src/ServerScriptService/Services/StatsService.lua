--[[
	StatsService.lua (ModuleScript)

	Tracks per-player MATCH stats — kills, damage dealt, coins earned,
	headshot kills — for the end-of-match scoreboard, plus a simple
	session objective ("N headshot kills this match") for a one-time
	bonus. Reset by WaveService at the start of every match.

	This is genuinely a SESSION objective, not a true daily — a real
	daily would need date-based reset logic (tracking a last-reset
	timestamp per player in DataService, handling timezone/UTC
	questions, etc.), which is a bigger persistent-data feature than
	this pass covers. Worth building properly later if daily engagement
	hooks matter; this is deliberately the simpler version.

	Not persisted — purely in-memory, unlike DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local DataService = require(script.Parent.DataService)

local StatsService = {}

export type PlayerStats = {
	Kills: number,
	DamageDealt: number,
	CoinsEarned: number,
	HeadshotKills: number,
	ObjectiveCompleted: boolean,
}

local OBJECTIVE_TARGET = 10 -- headshot kills
local OBJECTIVE_REWARD_COINS = 100

local stats: { [Player]: PlayerStats } = {}

local function freshStats(): PlayerStats
	return { Kills = 0, DamageDealt = 0, CoinsEarned = 0, HeadshotKills = 0, ObjectiveCompleted = false }
end

local function ensure(player: Player): PlayerStats
	local playerStats = stats[player]
	if not playerStats then
		playerStats = freshStats()
		stats[player] = playerStats
	end
	return playerStats
end

Players.PlayerAdded:Connect(function(player)
	ensure(player)
end)
Players.PlayerRemoving:Connect(function(player)
	stats[player] = nil
end)
for _, player in Players:GetPlayers() do
	ensure(player)
end

--[[ Called by WaveService at the start of every match. ]]
function StatsService.ResetAll()
	for _, player in Players:GetPlayers() do
		local fresh = freshStats()
		stats[player] = fresh
		Remotes.ObjectiveUpdated:FireClient(player, fresh.HeadshotKills, OBJECTIVE_TARGET, false)
	end
end

function StatsService.RecordDamage(player: Player, amount: number)
	ensure(player).DamageDealt += amount
end

function StatsService.RecordKill(player: Player)
	ensure(player).Kills += 1
end

function StatsService.RecordCoinsEarned(player: Player, amount: number)
	ensure(player).CoinsEarned += amount
end

--[[
	Called by WeaponService when a shot that killed a zombie was ALSO a
	headshot. Tracks progress toward the session objective and awards
	the one-time bonus the moment the target is hit.
]]
function StatsService.RecordHeadshotKill(player: Player)
	local playerStats = ensure(player)
	playerStats.HeadshotKills += 1

	if playerStats.ObjectiveCompleted then
		return
	end

	if playerStats.HeadshotKills >= OBJECTIVE_TARGET then
		playerStats.ObjectiveCompleted = true
		local newBalance = DataService.AddCoins(player, OBJECTIVE_REWARD_COINS)
		if newBalance then
			Remotes.CoinsUpdated:FireClient(player, newBalance)
		end
		StatsService.RecordCoinsEarned(player, OBJECTIVE_REWARD_COINS)
		Remotes.ObjectiveUpdated:FireClient(player, playerStats.HeadshotKills, OBJECTIVE_TARGET, true)
	else
		Remotes.ObjectiveUpdated:FireClient(player, playerStats.HeadshotKills, OBJECTIVE_TARGET, false)
	end
end

--[[
	Snapshot for the end-of-match scoreboard, sorted by kills descending.
	Returns plain data (not the live tables) since this crosses into a
	RemoteEvent payload.
]]
function StatsService.GetScoreboardSnapshot(): { { Name: string, Kills: number, DamageDealt: number, CoinsEarned: number } }
	local snapshot = {}
	for player, playerStats in stats do
		if player.Parent then -- still connected
			table.insert(snapshot, {
				Name = player.Name,
				Kills = playerStats.Kills,
				DamageDealt = math.floor(playerStats.DamageDealt + 0.5),
				CoinsEarned = playerStats.CoinsEarned,
			})
		end
	end
	table.sort(snapshot, function(a, b)
		return a.Kills > b.Kills
	end)
	return snapshot
end

return StatsService
