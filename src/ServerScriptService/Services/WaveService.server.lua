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
local PerkService = require(script.Parent.PerkService)
local LeaderboardService = require(script.Parent.LeaderboardService)

local WaveStateChanged = Remotes.WaveStateChanged
local GameStateChanged = Remotes.GameStateChanged
local BossHPChanged = Remotes.BossHPChanged
local CoinsUpdated = Remotes.CoinsUpdated
local ShowStartConfirmation = Remotes.ShowStartConfirmation
local ConfirmStartGame = Remotes.ConfirmStartGame
local WaveModifierAnnounced = Remotes.WaveModifierAnnounced
local MatchScoreboard = Remotes.MatchScoreboard
local LeaveParty = Remotes.LeaveParty
local PartyStatusChanged = Remotes.PartyStatusChanged

local DEFAULT_ARENA_SPAWN = Vector3.new(0, 5, 105)
local DEFAULT_LOBBY_SPAWN = Vector3.new(0, 3, -18)

-- Set true once a portal's party countdown finishes (see the portal
-- section near the bottom); consumed and reset by runLobbyPhase.
local startRequested = false

--[[
	Who is actually IN the current match. Populated from the party that
	formed at a portal, frozen at the moment the match starts, so players
	who join the server mid-run aren't teleported into it and don't count
	toward the "everyone's dead" defeat check. Empty while in the lobby.
]]
local matchParticipants: { Player } = {}

--[[
	Participants still connected. Everything match-scoped filters through
	this rather than Players:GetPlayers(), so someone leaving mid-run
	shrinks the party instead of hanging the match waiting on a player
	who's gone.
]]
local function getActiveParticipants(): { Player }
	local active = {}
	for _, player in matchParticipants do
		if player.Parent then
			table.insert(active, player)
		end
	end
	return active
end

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

--[[
	During a match this means "any participant left standing in the run";
	in the lobby it just means "anyone on the server at all". Keeping both
	behind one name lets the wave loops stay unchanged while matches are
	now party-scoped rather than whole-server.
]]
local function anyPlayersPresent(): boolean
	if #matchParticipants > 0 then
		return #getActiveParticipants() > 0
	end
	return #Players:GetPlayers() > 0
end

--[[
	True once every MATCH PARTICIPANT is truly dead (Humanoid missing or
	Health <= 0). A downed-but-not-bled-out player is pinned at Health == 1
	by PlayerService, so they don't count as defeated — only a real death
	does. Nobody left (empty party) never counts as "defeated" — that's
	just nobody home, not a loss.

	Scoped to participants, not everyone on the server, so a player idling
	in the lobby can neither prevent nor trigger a defeat for the group
	actually playing.
]]
local function allPlayersDefeated(): boolean
	local players = getActiveParticipants()
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

--[[ Teleports match participants only — lobby players stay put. ]]
local function teleportAllPlayersTo(position: Vector3)
	for _, player in getActiveParticipants() do
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
	-- CoinDoubler stacks on top of the wave's own coin modifier (e.g.
	-- Payday), and is a neutral 1 when unowned.
	local finalReward = math.floor(
		coinReward * currentModifier.CoinMultiplier * PerkService.GetMultiplier(killerPlayer, "CoinDoubler") + 0.5
	)
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
	Respawn-in-progress: a MATCH PARTICIPANT whose character reloads
	mid-run gets nudged back into the arena rather than left stranded in
	the lobby.

	Deliberately scoped to participants now that matches are party-based:
	a player who joins the server mid-run is NOT part of that party, so
	pulling them into the arena would drop them among zombies in a run
	they never opted into — and since allPlayersDefeated only counts
	participants, their death wouldn't even register. They stay in the
	lobby and can start their own run at a portal instead.
]]
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		if not MatchState.IsMatchActive() then
			return
		end
		local isParticipant = false
		for _, participant in matchParticipants do
			if participant == player then
				isParticipant = true
				break
			end
		end
		if not isParticipant then
			return
		end
		task.wait(0.2) -- let the character finish loading before moving it
		if character.Parent then
			character:PivotTo(CFrame.new(getArenaSpawnPosition()))
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

--[[
	Waits in the lobby until a portal party's countdown finishes and sets
	startRequested (see the portal section below). matchParticipants is
	cleared on entry so the previous run's roster can't leak into the
	presence/defeat checks while we're back in the lobby.
]]
local function runLobbyPhase()
	MatchState.Set("Lobby")
	startRequested = false
	matchParticipants = {}
	currentModifier = WaveModifiers[1]
	GameStateChanged:FireAllClients("Lobby", 0)
	while not startRequested do
		task.wait(0.25)
	end
	MatchState.Set("Starting")
end

--[[
	Runs the boss portion of a boss wave (every WaveConfig.BossEveryNWaves
	waves). Returns once the boss is dead or the match was lost.

	HP scales with which boss this is (see WaveConfig.GetBossHPMultiplier)
	so the wave-20/30/... bosses stay threatening against upgraded
	weapons instead of melting instantly.
]]
local function runBossWave(waveNumber: number)
	if matchDefeated then
		return
	end

	MatchState.Set("BossIncoming")
	currentModifier = WaveModifiers[1] -- no random modifier on a boss wave; it has enough going on
	for secondsLeft = WaveConfig.BossIntroSeconds, 1, -1 do
		if matchDefeated then
			return
		end
		GameStateChanged:FireAllClients("BossIncoming", secondsLeft)
		task.wait(1)
	end

	MatchState.Set("Boss")
	GameStateChanged:FireAllClients("BossStart", 0) -- flashes then self-clears; overwrites the "BossIncoming" countdown banner
	WaveStateChanged:FireAllClients(waveNumber, waveNumber, "Boss")

	local bossPosition = getZombieSpawnPositions()[1]
	local bossModel = ZombieService.SpawnZombie("Boss", bossPosition, WaveConfig.GetBossHPMultiplier(waveNumber))
	local bossHumanoid = bossModel and bossModel:FindFirstChildOfClass("Humanoid")
	if bossHumanoid then
		BossHPChanged:FireAllClients(bossHumanoid.Health, bossHumanoid.MaxHealth)
	end

	waitUntilArenaClear()

	if not matchDefeated then
		-- Milestone payout, replacing the old one-off victory bonus now
		-- that runs are endless and there's no final "you won" moment.
		for _, player in getActiveParticipants() do
			local bonus = math.floor(
				WaveConfig.BossClearBonusCoins * PerkService.GetMultiplier(player, "CoinDoubler") + 0.5
			)
			local newBalance = DataService.AddCoins(player, bonus)
			if newBalance then
				CoinsUpdated:FireClient(player, newBalance)
			end
			StatsService.RecordCoinsEarned(player, bonus)
		end
	end
end

--[[
	Endless wave loop: runs until the team is wiped, rather than stopping
	at a fixed final wave. Every WaveConfig.BossEveryNWaves-th wave is a
	boss wave. WaveConfig.GetWave supplies composition/pacing for any wave
	number — handcrafted for the early ones, generated beyond that.

	The "total waves" argument in WaveStateChanged is now just the current
	wave number, since there's no fixed total to count toward; the client
	renders "Wave N" from it (see UIController.SetWave).
]]
local function runWaves()
	teleportAllPlayersTo(getArenaSpawnPosition())

	local waveNumber = 0
	while not matchDefeated do
		waveNumber += 1

		for _, player in getActiveParticipants() do
			LeaderboardService.ReportWaveReached(player, waveNumber)
		end

		if waveNumber % WaveConfig.BossEveryNWaves == 0 then
			runBossWave(waveNumber)
		else
			MatchState.Set("Wave")
			currentModifier = WaveModifiers[math.random(1, #WaveModifiers)]
			WaveModifierAnnounced:FireAllClients(currentModifier.Name, currentModifier.Description)

			-- "WaveStart" both announces the wave AND overwrites whatever
			-- the lobby countdown banner last said ("Match starts in 1s")
			-- — the client has no other event telling it the countdown
			-- finished.
			GameStateChanged:FireAllClients("WaveStart", waveNumber)
			WaveStateChanged:FireAllClients(waveNumber, waveNumber, "InProgress")

			local waveData = WaveConfig.GetWave(waveNumber)
			spawnWaveTrickle(waveData.Composition, waveData.SpawnInterval)
			waitUntilArenaClear()
		end

		if matchDefeated then
			return
		end

		MatchState.Set("Break")
		WaveStateChanged:FireAllClients(waveNumber, waveNumber, "Break")
		for secondsLeft = WaveConfig.BetweenWaveBreakSeconds, 1, -1 do
			if matchDefeated then
				return
			end
			GameStateChanged:FireAllClients("WaveIncoming", secondsLeft, waveNumber + 1)
			task.wait(1)
		end
	end
end


local function broadcastScoreboard()
	MatchScoreboard:FireAllClients(StatsService.GetScoreboardSnapshot())
end

--[[
	End of a run. In endless mode this is the ONLY way a match ends —
	there is no victory state anymore, since waves never run out. Shows
	the scoreboard (where "you reached wave N" actually lands for the
	player) and returns everyone, with fresh characters, to the lobby.
local function runDefeat()
	MatchState.Set("Defeat")
	GameStateChanged:FireAllClients("Defeat", WaveConfig.EndOfRunSeconds)
	broadcastScoreboard()

	for secondsLeft = WaveConfig.EndOfRunSeconds, 1, -1 do
		GameStateChanged:FireAllClients("Defeat", secondsLeft)
		task.wait(1)
	end

	teleportAllPlayersTo(getLobbySpawnPosition())
end

--[[
	PORTAL / PARTY SYSTEM

	Four portals sit in the lobby (built in MapBootstrap as
	Map.MatchPortals.MatchPortal1..4). Interacting with one opens a party
	size picker (1-4) on that player's client. Their choice makes them the
	HOST of a forming party on that portal:

	  - Size 1 (solo): short countdown (WaveConfig.SoloCountdownSeconds),
	    since there's nobody to wait for.
	  - Size 2-4: longer countdown (WaveConfig.LobbyCountdownSeconds) to
	    give others time to join, and the match starts EARLY the moment
	    the party fills up rather than burning the rest of the timer.

	Others join by simply stepping onto that same portal — no prompt, no
	confirmation. The portal's own label shows live "joined / needed" so
	the state is readable in-world without any extra UI.

	Only one party forms at a time. A second player interacting with a
	different portal while one is already filling just joins the existing
	party instead of starting a competing one — with a small player count
	per server, two half-full parties that can never start is a worse
	outcome than everyone landing in one match.
]]
local PORTAL_COUNT = 4

local partyPortalId: number? = nil
local partyTargetSize = 0
local partyMembers: { Player } = {}
local partyDeadline = 0
local portalParts: { [number]: BasePart } = {}

local function isPartyForming(): boolean
	return partyPortalId ~= nil
end

local function isInParty(player: Player): boolean
	for _, member in partyMembers do
		if member == player then
			return true
		end
	end
	return false
end

--[[
	Portal labels double as the party UI: the sub-label shows the live
	join count while a party is forming there, and resets to the default
	prompt otherwise.
]]
local function updatePortalLabels()
	for portalId, part in portalParts do
		local label = part:FindFirstChild("Label")
		local title = label and label:FindFirstChild("Title")
		if title and title:IsA("TextLabel") then
			-- Blank unless a party is actually forming here — the portals
			-- carry no permanent caption (see MapBootstrap).
			title.Text = (partyPortalId == portalId)
					and ("%d / %d joined"):format(#partyMembers, partyTargetSize)
				or ""
		end
	end
end

--[[ Where inside a portal to place a waiting party member. ]]
local function getPortalStandPosition(portalId: number, memberIndex: number): Vector3
	local part = portalParts[portalId]
	if not part then
		return getLobbySpawnPosition()
	end
	-- Fan members around the pad's center so they don't all stack in
	-- exactly the same spot.
	local angle = (memberIndex - 1) * (math.pi * 2 / 4)
	return part.Position + Vector3.new(math.cos(angle) * 1.8, 3, math.sin(angle) * 1.8)
end

local function teleportPlayerTo(player: Player, position: Vector3)
	local character = player.Character
	if character and character.PrimaryPart then
		character:PivotTo(CFrame.new(position))
	end
end

--[[
	Pushes each member their own party status, which drives the in-portal
	waiting UI (join count + the exit button). Sent per-member rather than
	broadcast since only members should see the exit affordance.
]]
local function broadcastPartyStatus()
	for _, member in partyMembers do
		PartyStatusChanged:FireClient(member, true, #partyMembers, partyTargetSize)
	end
end

--[[
	Ends the forming party. notifyMembers=false is used when the party is
	being consumed to actually start a match — those players are about to
	be teleported into the arena, so telling their clients "you left the
	party" first would flash the wrong UI state.
]]
local function clearParty(notifyMembers: boolean?)
	if notifyMembers then
		for _, member in partyMembers do
			PartyStatusChanged:FireClient(member, false, 0, 0)
		end
	end
	partyPortalId = nil
	partyTargetSize = 0
	partyMembers = {}
	partyDeadline = 0
	updatePortalLabels()
end

--[[
	Adds a player to the forming party and teleports them INSIDE the
	portal to wait. The portal is ringed by an invisible barrier (see
	MapBootstrap) so being inside it is only reachable this way — which
	keeps "standing in the portal" and "actually in the party" the same
	thing, rather than something a player could get wrong by walking in.
]]
local function addToParty(player: Player)
	if not isPartyForming() or isInParty(player) then
		return
	end
	if #partyMembers >= partyTargetSize then
		return -- already full; they'll have to wait for the next run
	end
	table.insert(partyMembers, player)
	teleportPlayerTo(player, getPortalStandPosition(partyPortalId :: number, #partyMembers))
	updatePortalLabels()
	broadcastPartyStatus()
end

--[[
	Voluntary exit: leaves the party AND teleports back out of the portal
	(the barrier means they can't walk out themselves). If the host
	leaves and nobody else is left, the party dissolves entirely.
]]
local function removeFromParty(player: Player)
	if not isPartyForming() or not isInParty(player) then
		return
	end
	local remaining = {}
	for _, member in partyMembers do
		if member ~= player then
			table.insert(remaining, member)
		end
	end
	partyMembers = remaining

	teleportPlayerTo(player, getLobbySpawnPosition())
	PartyStatusChanged:FireClient(player, false, 0, 0)

	if #partyMembers == 0 then
		clearParty(false) -- nobody left to notify; the leaver already was
		return
	end
	updatePortalLabels()
	broadcastPartyStatus()
end

--[[
	Runs a forming party's countdown to its deadline, then hands off to
	the main sequencer by freezing matchParticipants and setting
	startRequested. Bails out (clearing the party) if everyone leaves.

	Broadcasts the same "Starting" state the old lobby countdown used, so
	the existing client banner keeps working unchanged.
]]
local function runPartyCountdown()
	while isPartyForming() do
		-- Drop members who disconnected while waiting.
		local stillHere = {}
		for _, member in partyMembers do
			if member.Parent then
				table.insert(stillHere, member)
			end
		end
		if #stillHere ~= #partyMembers then
			partyMembers = stillHere
			updatePortalLabels()
		end

		if #partyMembers == 0 then
			clearParty(false)
			return
		end

		local secondsLeft = math.max(0, math.ceil(partyDeadline - os.clock()))
		-- Early start only applies to multiplayer parties. A solo party is
		-- "full" the instant it's created (1 >= 1), so treating that as
		-- full here would skip SoloCountdownSeconds entirely and drop the
		-- host straight into the arena with no warning — the short solo
		-- countdown is deliberate prep time, not a wait for other players.
		local isFull = partyTargetSize > 1 and #partyMembers >= partyTargetSize

		if secondsLeft <= 0 or isFull then
			matchParticipants = partyMembers
			-- No "you left the party" notify — these players are being
			-- moved into the match, not ejected. Their waiting UI is
			-- cleared client-side when the match state changes.
			clearParty(false)
			startRequested = true
			return
		end

		for _, member in partyMembers do
			GameStateChanged:FireClient(member, "Starting", secondsLeft)
		end
		task.wait(0.5)
	end
end

--[[
	Wires each portal's ProximityPrompt. That prompt is the only way into
	a party: it opens the size picker for the first player, and joins
	(plus teleports in) for anyone after. Only meaningful in the Lobby
	state — a no-op mid-match.
]]
local function connectPortals()
	local mapFolder = Workspace:WaitForChild("Map", 10)
	local portalsFolder = mapFolder and mapFolder:WaitForChild("MatchPortals", 10)
	if not portalsFolder then
		warn("WaveService: MatchPortals folder not found — the lobby has no way to start a match")
		return
	end

	for portalId = 1, PORTAL_COUNT do
		local portal = portalsFolder:FindFirstChild("MatchPortal" .. portalId)
		if portal and portal:IsA("BasePart") then
			portalParts[portalId] = portal

			local prompt = portal:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Triggered:Connect(function(player: Player)
					if MatchState.Get() ~= "Lobby" then
						return
					end
					if isPartyForming() then
						-- A party is already filling — interacting just
						-- joins it rather than opening a competing picker.
						addToParty(player)
						return
					end
					ShowStartConfirmation:FireClient(player, portalId)
				end)
			end

			-- No Touched-to-join handler: the portal is walled off (see
			-- MapBootstrap), so the ONLY way in is the prompt above,
			-- which both joins the party and teleports the player
			-- inside. That keeps "inside the portal" and "in the party"
			-- exactly equivalent.
		end
	end
	updatePortalLabels()
end
connectPortals()

--[[
	Host's answer to the party size picker. partySize nil/0 means they
	cancelled. Validated server-side (1..PORTAL_COUNT) rather than
	trusting the client's number.
]]
LeaveParty.OnServerEvent:Connect(function(player: Player)
	removeFromParty(player)
end)

ConfirmStartGame.OnServerEvent:Connect(function(player: Player, portalId: number?, partySize: number?)
	if MatchState.Get() ~= "Lobby" then
		return
	end
	if isPartyForming() then
		addToParty(player) -- someone beat them to it; just join that one
		return
	end
	if typeof(portalId) ~= "number" or not portalParts[portalId] then
		return
	end
	if typeof(partySize) ~= "number" then
		return
	end
	partySize = math.clamp(math.floor(partySize), 1, PORTAL_COUNT)

	partyPortalId = portalId
	partyTargetSize = partySize
	partyMembers = { player }
	partyDeadline = os.clock()
		+ (partySize == 1 and WaveConfig.SoloCountdownSeconds or WaveConfig.LobbyCountdownSeconds)
	-- Host waits inside the portal like everyone else.
	teleportPlayerTo(player, getPortalStandPosition(portalId, 1))
	updatePortalLabels()
	broadcastPartyStatus()

	task.spawn(runPartyCountdown)
end)


task.spawn(function()
	while true do
		-- Blocks until a portal party's countdown completes; that
		-- countdown IS the pre-match countdown now (the old fixed
		-- lobby countdown was removed, since the party's own timer
		-- already serves that role and its length depends on the
		-- chosen party size).
		runLobbyPhase()
		if #getActiveParticipants() > 0 then
			matchDefeated = false
			StatsService.ResetAll()
			-- Endless: runWaves only returns once the team is wiped (or
			-- everyone left), so defeat is the single exit path — there's
			-- no victory branch anymore.
			runWaves()
			runDefeat()
			matchDefeated = false
		end
	end
end)
