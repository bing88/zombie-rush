--[[
	WaveService.server.lua

	Tier 1's match state machine (per the reconciled MVP doc: "1-4
	players, 10 waves with difficulty scaling, 1 boss, return-to-lobby
	loop"). Runs forever as a single coroutine cycling through:

		Lobby -> Starting (countdown) -> Wave 1..10 (with Break between
		each) -> BossIncoming -> Boss -> Victory -> back to Lobby

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
local ZombieService = require(script.Parent.ZombieService)
local DataService = require(script.Parent.DataService)
local MatchState = require(script.Parent.MatchState)

local WaveStateChanged = Remotes.WaveStateChanged
local GameStateChanged = Remotes.GameStateChanged
local BossHPChanged = Remotes.BossHPChanged
local CoinsUpdated = Remotes.CoinsUpdated

local DEFAULT_ARENA_SPAWN = Vector3.new(0, 5, 105)
local DEFAULT_LOBBY_SPAWN = Vector3.new(0, 3, -18)

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

local function teleportAllPlayersTo(position: Vector3)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local jitter = Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
			character:PivotTo(CFrame.new(position + jitter))
		end
	end
end

local function waitUntilArenaClear()
	while ZombieService.GetActiveCount() > 0 do
		task.wait(0.5)
	end
end

--[[ Award coins for every zombie kill while a match is running. ]]
ZombieService.ZombieDied:Connect(function(_statsName: string, killerPlayer: Player?, coinReward: number)
	if not killerPlayer or not killerPlayer.Parent then
		return
	end
	local newBalance = DataService.AddCoins(killerPlayer, coinReward)
	if newBalance then
		CoinsUpdated:FireClient(killerPlayer, newBalance)
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
		if not anyPlayersPresent() then
			return
		end
		while ZombieService.GetActiveCount() >= WaveConfig.MaxConcurrentZombies do
			task.wait(0.5)
		end
		local position = positions[math.random(1, #positions)]
		ZombieService.SpawnZombie(zombieType, position)
		task.wait(spawnInterval)
	end
end

local function runLobbyPhase()
	MatchState.Set("Lobby")
	GameStateChanged:FireAllClients("Lobby", 0)
	while not anyPlayersPresent() do
		task.wait(1)
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
		MatchState.Set("Wave")
		-- "WaveStart" both announces the wave AND overwrites whatever the
		-- lobby countdown banner last said ("Match starts in 1s") — the
		-- client has no other event telling it the countdown finished.
		GameStateChanged:FireAllClients("WaveStart", waveNumber)
		WaveStateChanged:FireAllClients(waveNumber, totalWaves, "InProgress")
		spawnWaveTrickle(waveData.Composition, waveData.SpawnInterval)
		waitUntilArenaClear()

		if waveNumber < totalWaves then
			MatchState.Set("Break")
			WaveStateChanged:FireAllClients(waveNumber, totalWaves, "Break")
			for secondsLeft = WaveConfig.BetweenWaveBreakSeconds, 1, -1 do
				GameStateChanged:FireAllClients("WaveIncoming", secondsLeft, waveNumber + 1)
				task.wait(1)
			end
		end
	end
end

local function runBoss()
	MatchState.Set("BossIncoming")
	for secondsLeft = WaveConfig.BossIntroSeconds, 1, -1 do
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
end

local function runVictory()
	MatchState.Set("Victory")
	for _, player in Players:GetPlayers() do
		local newBalance = DataService.AddCoins(player, WaveConfig.VictoryBonusCoins)
		if newBalance then
			CoinsUpdated:FireClient(player, newBalance)
		end
	end

	for secondsLeft = WaveConfig.VictorySeconds, 1, -1 do
		GameStateChanged:FireAllClients("Victory", secondsLeft)
		task.wait(1)
	end

	teleportAllPlayersTo(getLobbySpawnPosition())
end

task.spawn(function()
	while true do
		runLobbyPhase()
		local started = runCountdownPhase()
		if started then
			runWaves()
			runBoss()
			runVictory()
		end
	end
end)
