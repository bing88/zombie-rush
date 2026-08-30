--[[
	WaveService.server.lua

	Tier 1's match state machine (per the reconciled MVP doc: "1-4
	players, 10 waves with difficulty scaling, 1 boss, return-to-lobby
	loop"). Runs forever as a single coroutine cycling through:

		Lobby -> Starting (countdown) -> Wave 1..9 (each with a random
		modifier + a Break) -> Boss -> Victory -> back to Lobby

		...or, if every player is wiped out along the way:
		(Wave/Boss) -> Defeat -> back to Lobby

	Zombies only ever spawn during Wave/Boss states. Coin rewards for
	kills are awarded here (not in ZombieService or WeaponService) by
	listening to ZombieService.ZombieDied, since "who gets paid for a
	kill" is match/economy logic, not zombie-behavior or gun logic.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WaveConfig = require(ReplicatedStorage.Shared.WaveConfig)
local WaveModifiers = require(ReplicatedStorage.Shared.WaveModifiers)
local ZombieService = require(script.Parent.ZombieService)
local DataService = require(script.Parent.DataService)
local MatchState = require(script.Parent.MatchState)
local StatsService = require(script.Parent.StatsService)
local LeaderboardService = require(script.Parent.LeaderboardService)

local WaveStateChanged = Remotes.WaveStateChanged
local GameStateChanged = Remotes.GameStateChanged
local BossHPChanged = Remotes.BossHPChanged
local CoinsUpdated = Remotes.CoinsUpdated
local ShowStartConfirmation = Remotes.ShowStartConfirmation
local ConfirmStartGame = Remotes.ConfirmStartGame
local WaveModifierAnnounced = Remotes.WaveModifierAnnounced
local MatchScoreboard = Remotes.MatchScoreboard

local DEFAULT_ARENA_SPAWN = Vector3.new(0, 5, 105)
local DEFAULT_LOBBY_SPAWN = Vector3.new(0, 3, -18)

-- Set true by a confirmed "yes" on the lobby teleport pad; consumed (and
-- reset) by runLobbyPhase once it moves the match into the countdown.
-- The lobby no longer auto-starts just because a player is present —
-- someone has to explicitly opt in via the pad.
local startRequested = false

-- This wave's randomly picked modifier (see WaveModifiers.lua). Reset to
-- "no modifier" outside of a wave so anything reading it between waves
-- gets a safe default instead of stale state from the previous wave.
local currentModifier = WaveModifiers[1]

-- Set by the defeat watchdog once every connected player's Humanoid.Health
-- is 0 (truly dead, not just downed — see PlayerService/DownedState) while
-- a match is active. Checked at every wait point in the wave/boss loops so
-- the match can bail out to Defeat promptly instead of grinding on with no
-- one left standing.
local matchDefeated = false

local function getMarkerPosition(name: string, fallback: Vector3): Vector3
	local marker = Workspace:FindFirstChild(name, true)
	if marker and marker:IsA("BasePart") then
		return marker.Position
	end
	return fallback
end

local function getArenaSpawnPosition(): Vector3
	return getMarkerPosition("ArenaSpawnPoint", DEFAULT_ARENA_SPAWN)
end

local function getLobbySpawnPosition(): Vector3
	return getMarkerPosition("LobbySpawnPoint", DEFAULT_LOBBY_SPAWN)
end

local function getZombieSpawnPositions(): { Vector3 }
	local folder = Workspace:FindFirstChild("ZombieSpawns")
	local positions = {}
	if folder then
		for _, point in folder:GetChildren() do
			if point:IsA("BasePart") then
				table.insert(positions, point.Position)
			end
		end
	end
	if #positions == 0 then
		table.insert(positions, DEFAULT_ARENA_SPAWN)
	end
	return positions
end

local function anyPlayersPresent(): boolean
	return #Players:GetPlayers() > 0
end

--[[
	True once every currently-connected player is truly dead (Humanoid
	missing or Health <= 0). A downed-but-not-bled-out player is pinned
	at Health == 1 by PlayerService, so they don't count as defeated —
	only a real death does. An empty server never counts as "defeated"
	(that's just nobody home, not a loss).
]]
local function allPlayersDefeated(): boolean
	local players = Players:GetPlayers()
	if #players == 0 then
		return false
	end
	for _, player in players do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			return false
		end
	end
	return true
end

local function teleportAllPlayersTo(position: Vector3)
	for _, player in Players:GetPlayers() do
		-- A player who's truly dead at this point (see PlayerService's
		-- Died handler, which doesn't auto-respawn mid-match) needs a
		-- fresh character before there's anything to teleport.
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			player:LoadCharacter()
			task.wait(0.3)
			character = player.Character
		end
		if character then
			local jitter = Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
			character:PivotTo(CFrame.new(position + jitter))
		end
	end
end

local function waitUntilArenaClear()
	while ZombieService.GetActiveCount() > 0 do
		if matchDefeated then
			return
		end
		task.wait(0.5)
	end
end

--[[ Award coins for every zombie kill while a match is running. ]]
ZombieService.ZombieDied:Connect(function(_statsName: string, killerPlayer: Player?, coinReward: number)
	if not killerPlayer or not killerPlayer.Parent then
		return
	end
	local finalReward = math.floor(coinReward * currentModifier.CoinMultiplier + 0.5)
	local newBalance = DataService.AddCoins(killerPlayer, finalReward)
	if newBalance then
		CoinsUpdated:FireClient(killerPlayer, newBalance)
	end
	StatsService.RecordKill(killerPlayer)
	StatsService.RecordCoinsEarned(killerPlayer, finalReward)
end)

--[[
	Defeat watchdog: runs continuously, independent of whatever phase the
	main sequencer is in, and flips matchDefeated the moment everyone's
	down. The wait loops throughout this module poll that flag to bail
	out promptly instead of only checking at fixed phase boundaries.
]]
task.spawn(function()
	while true do
		if MatchState.IsMatchActive() and allPlayersDefeated() then
			matchDefeated = true
		end
		task.wait(1)
	end
end)

--[[
	Join-in-progress: a player who joins (or respawns) mid-match spawns at
	the lobby's default SpawnLocation like normal, then gets nudged into
	the arena so they're not stuck waiting out the rest of a run alone.
]]
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		if MatchState.IsMatchActive() then
			task.wait(0.2) -- let the character finish loading before moving it
			if character.Parent then
				character:PivotTo(CFrame.new(getArenaSpawnPosition()))
			end
		end
	end)
end)

local function spawnWaveTrickle(composition, spawnInterval: number)
	local positions = getZombieSpawnPositions()
	local spawnOrder = {}
	for zombieType, count in composition do
		for _ = 1, count do
			table.insert(spawnOrder, zombieType)
		end
	end

	-- Shuffle so e.g. Tanks aren't all clumped at the end of the wave.
	for i = #spawnOrder, 2, -1 do
		local j = math.random(1, i)
		spawnOrder[i], spawnOrder[j] = spawnOrder[j], spawnOrder[i]
	end

	for _, zombieType in spawnOrder do
		if not anyPlayersPresent() or matchDefeated then
			return
		end
		while ZombieService.GetActiveCount() >= WaveConfig.MaxConcurrentZombies do
			if matchDefeated then
				return
			end
			task.wait(0.5)
		end
		local position = positions[math.random(1, #positions)]
		ZombieService.SpawnZombie(
			zombieType,
			position,
			currentModifier.HPMultiplier,
			currentModifier.SpeedMultiplier,
			currentModifier.DamageMultiplier
		)
		task.wait(spawnInterval)
	end
end

local function runLobbyPhase()
	MatchState.Set("Lobby")
	startRequested = false
	currentModifier = WaveModifiers[1]
	GameStateChanged:FireAllClients("Lobby", 0)
	while not anyPlayersPresent() or not startRequested do
		if not anyPlayersPresent() then
			startRequested = false
		end
		task.wait(0.5)
	end
end

--[[ Returns false if every player left before the countdown finished. ]]
local function runCountdownPhase(): boolean
	MatchState.Set("Starting")
	for secondsLeft = WaveConfig.LobbyCountdownSeconds, 1, -1 do
		if not anyPlayersPresent() then
			return false
		end
		GameStateChanged:FireAllClients("Starting", secondsLeft)
		task.wait(1)
	end
	return anyPlayersPresent()
end

local function runWaves()
	teleportAllPlayersTo(getArenaSpawnPosition())
	local totalWaves = #WaveConfig.Waves

	for waveNumber, waveData in WaveConfig.Waves do
		if matchDefeated then
			return
		end

		MatchState.Set("Wave")
		currentModifier = WaveModifiers[math.random(1, #WaveModifiers)]
		WaveModifierAnnounced:FireAllClients(currentModifier.Name, currentModifier.Description)

		-- "WaveStart" both announces the wave AND overwrites whatever the
		-- lobby countdown banner last said ("Match starts in 1s") — the
		-- client has no other event telling it the countdown finished.
		GameStateChanged:FireAllClients("WaveStart", waveNumber)
		WaveStateChanged:FireAllClients(waveNumber, totalWaves, "InProgress")
		for _, player in Players:GetPlayers() do
			LeaderboardService.ReportWaveReached(player, waveNumber)
		end

		spawnWaveTrickle(waveData.Composition, waveData.SpawnInterval)
		waitUntilArenaClear()
		if matchDefeated then
			return
		end

		if waveNumber < totalWaves then
			MatchState.Set("Break")
			WaveStateChanged:FireAllClients(waveNumber, totalWaves, "Break")
			for secondsLeft = WaveConfig.BetweenWaveBreakSeconds, 1, -1 do
				if matchDefeated then
					return
				end
				GameStateChanged:FireAllClients("WaveIncoming", secondsLeft, waveNumber + 1)
				task.wait(1)
			end
		end
	end
end

local function runBoss()
	if matchDefeated then
		return
	end

	MatchState.Set("BossIncoming")
	currentModifier = WaveModifiers[1] -- no random modifier on the boss wave; it has enough going on
	for secondsLeft = WaveConfig.BossIntroSeconds, 1, -1 do
		if matchDefeated then
			return
		end
		GameStateChanged:FireAllClients("BossIncoming", secondsLeft)
		task.wait(1)
	end

	MatchState.Set("Boss")
	local totalWaves = #WaveConfig.Waves
	GameStateChanged:FireAllClients("BossStart", 0) -- flashes then self-clears; overwrites the "BossIncoming" countdown banner
	WaveStateChanged:FireAllClients(totalWaves, totalWaves, "Boss")

	local bossPosition = getZombieSpawnPositions()[1]
	local bossModel = ZombieService.SpawnZombie("Boss", bossPosition)
	local bossHumanoid = bossModel and bossModel:FindFirstChildOfClass("Humanoid")
	if bossHumanoid then
		BossHPChanged:FireAllClients(bossHumanoid.Health, bossHumanoid.MaxHealth)
	end

	waitUntilArenaClear()

	if not matchDefeated then
		for _, player in Players:GetPlayers() do
			LeaderboardService.ReportWaveReached(player, totalWaves + 1) -- beat the boss: credit one better than "reached wave 10"
		end
	end
end

local function broadcastScoreboard()
	MatchScoreboard:FireAllClients(StatsService.GetScoreboardSnapshot())
end

local function runVictory()
	MatchState.Set("Victory")
	for _, player in Players:GetPlayers() do
		local newBalance = DataService.AddCoins(player, WaveConfig.VictoryBonusCoins)
		if newBalance then
			CoinsUpdated:FireClient(player, newBalance)
		end
		StatsService.RecordCoinsEarned(player, WaveConfig.VictoryBonusCoins)
	end

	broadcastScoreboard()

	for secondsLeft = WaveConfig.VictorySeconds, 1, -1 do
		GameStateChanged:FireAllClients("Victory", secondsLeft)
		task.wait(1)
	end

	teleportAllPlayersTo(getLobbySpawnPosition())
end

--[[
	Mirror of runVictory for the "everyone got wiped out" outcome — no
	victory bonus, but still shows the scoreboard and returns everyone
	(with fresh characters) to the lobby the same way.
]]
local function runDefeat()
	MatchState.Set("Defeat")
	GameStateChanged:FireAllClients("Defeat", WaveConfig.VictorySeconds)
	broadcastScoreboard()

	for secondsLeft = WaveConfig.VictorySeconds, 1, -1 do
		GameStateChanged:FireAllClients("Defeat", secondsLeft)
		task.wait(1)
	end

	teleportAllPlayersTo(getLobbySpawnPosition())
end

--[[
	Teleport pad wiring: stepping on Stall_TeleportPad and holding the
	interact key asks THAT player (not everyone) whether to start the
	match. A single "yes" is all it takes — this isn't a multiplayer vote/
	quorum system, just an explicit opt-in gate instead of auto-starting
	the moment any player is present. Only meaningful while still in the
	Lobby state; triggering it mid-match (or during the countdown) is a
	no-op since MatchState won't be "Lobby" then.
]]
local function connectTeleportPad()
	local mapFolder = Workspace:WaitForChild("Map", 10)
	local pad = mapFolder and mapFolder:WaitForChild("Stall_TeleportPad", 10)
	local prompt = pad and pad:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn("WaveService: teleport pad or its ProximityPrompt not found")
		return
	end
	prompt.Triggered:Connect(function(player: Player)
		if MatchState.Get() ~= "Lobby" then
			return
		end
		ShowStartConfirmation:FireClient(player)
	end)
end
connectTeleportPad()

ConfirmStartGame.OnServerEvent:Connect(function(player: Player, confirmed: boolean)
	if confirmed and MatchState.Get() == "Lobby" then
		startRequested = true
	end
end)

task.spawn(function()
	while true do
		runLobbyPhase()
		local started = runCountdownPhase()
		if started then
			matchDefeated = false
			StatsService.ResetAll()
			runWaves()
			if matchDefeated then
				runDefeat()
			else
				runBoss()
				if matchDefeated then
					runDefeat()
				else
					runVictory()
				end
			end
			matchDefeated = false
		end
	end
end)
