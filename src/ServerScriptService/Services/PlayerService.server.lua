--[[
	PlayerService.server.lua

	Tier 1: HP tracking, death, respawn, DataService profile load/release,
	giving each player Tools for every weapon they own (see
	WeaponConfig.Order), and the downed/revive system.

	Downed/revive design: rather than letting a mid-match death actually
	go through Humanoid.Died (broken joints, respawn timer, etc.) and
	then trying to "undo" that, HealthChanged is intercepted BEFORE
	health reaches 0 — it's clamped to 1 and the player enters a
	"Downed" state (immobile, can't fire — see WeaponService's
	DownedState check) with a ProximityPrompt a teammate can hold to
	revive them, and a bleed-out timer. If nobody revives them in time,
	*then* Health is actually set to 0, triggering a real death that
	waits for the match to end (see the Died handler below) rather than
	auto-respawning — WaveService's defeat check reads Humanoid.Health
	directly, so a truly-dead (Health == 0) player counts toward "has
	everyone been wiped out", while a downed-but-pinned-at-1 player
	doesn't.

	WaveService handles moving a freshly-spawned character into the
	arena if a match is already underway (see MatchState); this script
	only ever spawns players at the map's default SpawnLocation (the
	lobby), and also handles respawning everyone at Victory/Defeat.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local DataService = require(script.Parent.DataService)
local DownedState = require(script.Parent.DownedState)
local MatchState = require(script.Parent.MatchState)

local PlayerHPChanged = Remotes.PlayerHPChanged
local PlayerDied = Remotes.PlayerDied
local CoinsUpdated = Remotes.CoinsUpdated
local WeaponsOwned = Remotes.WeaponsOwned
local PlayerDownedChanged = Remotes.PlayerDownedChanged

local RESPAWN_DELAY_SECONDS = 3
local BLEED_OUT_SECONDS = 30
local REVIVE_HOLD_SECONDS = 2
local REVIVE_HEALTH_FRACTION = 0.5

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
	silently duplicate on every death. Weapons at max upgrade level get
	the cosmetic prestige effect applied.
]]
local function giveOwnedWeapons(player: Player, character: Model)
	local backpack = player:WaitForChild("Backpack")
	for _, child in backpack:GetChildren() do
		child:Destroy()
	end

	for _, weaponName in WeaponConfig.Order do
		if DataService.IsWeaponUnlocked(player, weaponName) then
			local tool = WeaponModelFactory.CreateTool(weaponName)
			if DataService.GetWeaponLevel(player, weaponName) >= UpgradeConfig.MaxLevel then
				WeaponModelFactory.ApplyPrestigeEffect(tool)
			end
			tool.Parent = backpack
		end
	end

	local starter = backpack:FindFirstChild(WeaponConfig.StartingWeapon)
	if starter then
		starter.Parent = character
	end
end

--[[
	Puts a player into the downed state: pins HP at 1, freezes movement,
	adds a "hold to revive" ProximityPrompt, and starts a bleed-out
	timer. Returns nothing — state changes are read back via
	DownedState.IsDowned / the PlayerDownedChanged remote.
]]
local function enterDownedState(player: Player, character: Model, humanoid: Humanoid)
	if DownedState.IsDowned(player) then
		return
	end
	DownedState.SetDowned(player, true)

	local cachedWalkSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	humanoid.Health = 1

	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Revive"
	prompt.ActionText = "Revive"
	prompt.ObjectText = player.Name
	prompt.HoldDuration = REVIVE_HOLD_SECONDS
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	if rootPart then
		prompt.Parent = rootPart
	end

	local label = Instance.new("BillboardGui")
	label.Name = "DownedLabel"
	label.Size = UDim2.fromOffset(160, 40)
	label.StudsOffset = Vector3.new(0, 3, 0)
	label.AlwaysOnTop = true
	if rootPart then
		label.Parent = rootPart
	end
	local labelText = Instance.new("TextLabel")
	labelText.Size = UDim2.fromScale(1, 1)
	labelText.BackgroundTransparency = 1
	labelText.Font = Enum.Font.GothamBold
	labelText.TextScaled = true
	labelText.TextColor3 = Color3.fromRGB(255, 80, 80)
	labelText.TextStrokeTransparency = 0.3
	labelText.Text = "DOWNED"
	labelText.Parent = label

	local resolved = false
	local bleedOutThread: thread? = nil

	local function cleanup()
		if prompt then
			prompt:Destroy()
		end
		if label then
			label:Destroy()
		end
		if bleedOutThread then
			task.cancel(bleedOutThread)
		end
	end

	local promptConnection = prompt.Triggered:Connect(function(reviver: Player)
		if resolved or reviver == player then
			return
		end
		resolved = true
		cleanup()
		DownedState.SetDowned(player, false)
		humanoid.WalkSpeed = cachedWalkSpeed
		humanoid.Health = humanoid.MaxHealth * REVIVE_HEALTH_FRACTION
		PlayerDownedChanged:FireClient(player, false, 0)
	end)

	PlayerDownedChanged:FireClient(player, true, BLEED_OUT_SECONDS)

	bleedOutThread = task.delay(BLEED_OUT_SECONDS, function()
		if resolved then
			return
		end
		resolved = true
		promptConnection:Disconnect()
		cleanup()
		DownedState.SetDowned(player, false)
		humanoid.WalkSpeed = cachedWalkSpeed
		-- Previously missing entirely: without this, the client never
		-- learned bleed-out had expired (only the revive path fired
		-- this event), leaving the downed banner's countdown stuck
		-- forever on the client with no signal to clear it.
		PlayerDownedChanged:FireClient(player, false, 0)
		humanoid.Health = 0 -- now actually dies; see the Died handler below
	end)
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	ensureProfileLoaded(player)
	giveOwnedWeapons(player, character)
	syncOwnedWeapons(player)
	DownedState.SetDowned(player, false) -- fresh life always starts "up"

	humanoid.HealthChanged:Connect(function(newHealth)
		PlayerHPChanged:FireClient(player, newHealth, humanoid.MaxHealth)

		if newHealth <= 0 and MatchState.IsMatchActive() and not DownedState.IsDowned(player) then
			-- Cancel the death in progress and go down instead of dying
			-- outright. enterDownedState re-sets Health to 1, which
			-- re-fires this same HealthChanged handler harmlessly (1 > 0,
			-- no branch taken).
			enterDownedState(player, character, humanoid)
		end
	end)

	humanoid.Died:Connect(function()
		PlayerDied:FireClient(player)
		DownedState.SetDowned(player, false)
		if not MatchState.IsMatchActive() then
			-- Normal Tier-0-style respawn: happens in the lobby, during
			-- countdown, or after victory/defeat -- never mid-fight.
			task.delay(RESPAWN_DELAY_SECONDS, function()
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end
		-- Else: stay dead. A truly-dead (Health == 0, not just downed)
		-- player mid-match contributes to WaveService's defeat check;
		-- everyone gets respawned together when the match ends either
		-- way (see WaveService's runDefeat).
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
	DownedState.SetDowned(player, false)
	DataService.Release(player)
end)
