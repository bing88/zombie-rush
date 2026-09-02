--[[
	PlayerService.server.lua

	Tier 1: HP tracking, death, respawn, DataService profile load/release,
	giving each player Tools for every weapon they own (see
	WeaponConfig.Order), and the downed/revive system.

	Downed/revive design: rather than letting a mid-match death actually
	go through Humanoid.Died (broken joints, respawn timer, etc.) and
	then trying to "undo" that, HealthChanged is intercepted BEFORE
	health reaches 0 — it's clamped to 1, the character is visually
	tipped onto its back (see FALLEN_TIP_ANGLES below — an approximate,
	non-physics "lying on the floor" pose, not a real ragdoll), and the
	player enters a "Downed" state (immobile, can't fire — see
	WeaponService's DownedState check) with a ProximityPrompt a teammate
	can hold to revive them, and a bleed-out timer. If nobody revives
	them in time, *then* Health is actually set to 0, triggering a real
	death (see the Died handler below) — WaveService's defeat check
	reads Humanoid.Health directly, so a truly-dead (Health == 0) player
	counts toward "has everyone been wiped out", while a downed-but-
	pinned-at-1 player doesn't. A truly-dead player does NOT auto-
	respawn immediately — they sit out the rest of the current wave and
	come back with a fresh character at the start of the next one (see
	WaveService's respawnDeadParticipants, called at the start of every
	Break phase), unless the whole party is wiped first, which ends the
	match instead (see WaveService's runDefeat).

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
local PerkService = require(script.Parent.PerkService)
local RunUpgradeService = require(script.Parent.RunUpgradeService)
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

--[[
	Applies the player's run-drafted Survivor (+max HP) and Adrenaline
	(+move speed) stacks to a live humanoid.

	This module owns these two writes because it already applies the
	equivalent Robux perks on spawn — RunUpgradeService calls it through
	the handler registered at the bottom of this file rather than
	touching humanoids itself, so MaxHealth/WalkSpeed only ever have one
	writer.

	IDEMPOTENT BY CONSTRUCTION, which it has to be: it runs on every
	spawn AND again on every draft pick, so "add the bonus to the current
	value" would compound without limit over a long run. Instead the
	pre-bonus values are captured once per humanoid as attributes, and
	the bonus is always recomputed from those rather than from whatever
	the property currently holds.

	Health tracks a MaxHealth increase by the same delta, so drafting
	Survivor mid-run reads as an immediate heal rather than just a wider
	empty bar — the pick is a reward for surviving a wave and should feel
	like one at the moment it's taken.

	While DOWNED, movement and current health are left alone: Health is
	deliberately pinned at 1 by the bleed-out system and WalkSpeed at 0,
	and writing either here would un-freeze a bleeding-out player or
	cancel their death. MaxHealth still updates (harmless at Health 1),
	and the revive path re-invokes this function once the player is back
	up, so a pick taken while downed isn't lost.
]]
local function applyRunUpgradeStats(player: Player, humanoid: Humanoid)
	local baselineMaxHealth = humanoid:GetAttribute("BaselineMaxHealth")
	if typeof(baselineMaxHealth) ~= "number" then
		baselineMaxHealth = humanoid.MaxHealth
		humanoid:SetAttribute("BaselineMaxHealth", baselineMaxHealth)
	end

	local baselineWalkSpeed = humanoid:GetAttribute("BaselineWalkSpeed")
	if typeof(baselineWalkSpeed) ~= "number" then
		baselineWalkSpeed = humanoid.WalkSpeed
		humanoid:SetAttribute("BaselineWalkSpeed", baselineWalkSpeed)
	end

	local isDowned = DownedState.IsDowned(player)

	local targetMaxHealth = baselineMaxHealth + RunUpgradeService.GetTotal(player, "MaxHealth")
	local healthDelta = targetMaxHealth - humanoid.MaxHealth
	if healthDelta ~= 0 then
		humanoid.MaxHealth = targetMaxHealth
		if healthDelta > 0 and not isDowned then
			humanoid.Health = math.min(humanoid.Health + healthDelta, targetMaxHealth)
		end
	end

	if not isDowned then
		humanoid.WalkSpeed = baselineWalkSpeed * RunUpgradeService.GetScale(player, "MoveSpeed")
	end
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

-- Approximate "lying on the floor" pose for a downed character: tips the
-- whole (still rigidly-jointed — this is NOT a real physics ragdoll,
-- just the standing rig rotated as one piece) body onto its back and
-- drops it roughly to floor height. Not physically simulated/raycast
-- against the actual ground, so it can clip slightly into slopes/stairs
-- — good enough for this game's scope; a real ragdoll would need each
-- Motor6D swapped for breakable constraints, which is a much bigger
-- Studio-side undertaking.
local FALLEN_TIP_ANGLES = CFrame.Angles(math.rad(-90), 0, 0)
local FALLEN_HEIGHT_DROP = 2.2

--[[
	Puts a player into the downed state: pins HP at 1, freezes movement,
	visually tips the character onto its back (see FALLEN_TIP_ANGLES),
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
	if not rootPart then
		warn(("PlayerService: %s went down with no HumanoidRootPart — skipping the fallen pose/revive prompt"):format(player.Name))
	end

	-- PlatformStand hands full control of the rig to physics/gravity
	-- (Roblox's own walk/run controller stops fighting it), which is
	-- what makes the tipped-over CFrame below actually stick instead of
	-- being stood back upright the next frame.
	humanoid.PlatformStand = true
	local standingCFrame: CFrame? = nil
	if rootPart then
		standingCFrame = rootPart.CFrame
		rootPart.CFrame = (rootPart.CFrame * FALLEN_TIP_ANGLES) - Vector3.new(0, FALLEN_HEIGHT_DROP, 0)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Revive"
	prompt.ActionText = "Revive"
	prompt.ObjectText = player.Name
	-- QuickRevive belongs to the RESCUER (they're the one holding the
	-- prompt), so the multiplier is looked up per-rescuer at trigger
	-- time rather than baked into the prompt here — the prompt is
	-- shared by everyone who can see it.
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

	-- Undoes the fallen pose and hands control back to the Humanoid's own
	-- controller. Restores the exact pre-down CFrame rather than trying
	-- to invert FALLEN_TIP_ANGLES/FALLEN_HEIGHT_DROP — simpler and immune
	-- to any drift from physics nudging the fallen body while downed.
	local function standBackUp()
		humanoid.PlatformStand = false
		if rootPart and standingCFrame then
			rootPart.CFrame = standingCFrame
		end
	end

	local promptConnection = prompt.Triggered:Connect(function(reviver: Player)
		if resolved or reviver == player then
			return
		end
		-- A reviver must actually be able to help: alive, and not
		-- themselves downed (an incapacitated player has no business
		-- reviving anyone — this ProximityPrompt lives on a BasePart
		-- Roblox will still let any nearby player Trigger regardless of
		-- their own state, so this has to be checked explicitly).
		local reviverCharacter = reviver.Character
		local reviverHumanoid = reviverCharacter and reviverCharacter:FindFirstChildOfClass("Humanoid")
		if not reviverHumanoid or reviverHumanoid.Health <= 0 or DownedState.IsDowned(reviver) then
			return
		end

		resolved = true
		cleanup()
		standBackUp()
		DownedState.SetDowned(player, false)
		humanoid.WalkSpeed = cachedWalkSpeed
		-- Re-apply run upgrades now that they're back up: cachedWalkSpeed
		-- was captured at the moment they went down, so any Adrenaline
		-- drafted while they were bleeding out (drafts open during the
		-- break, when a teammate may still be reviving them) would
		-- otherwise be restored away and silently lost. This recomputes
		-- from the humanoid's own baseline attributes, so it's correct
		-- whether or not anything was drafted in between.
		applyRunUpgradeStats(player, humanoid)
		humanoid.Health = humanoid.MaxHealth * REVIVE_HEALTH_FRACTION
		PlayerDownedChanged:FireClient(player, false, 0)
	end)

	-- The downed player's own QuickRevive extends how long they can hold
	-- on (its multiplier is < 1, so divide).
	local bleedOutSeconds = BLEED_OUT_SECONDS / PerkService.GetMultiplier(player, "QuickRevive")
	PlayerDownedChanged:FireClient(player, true, bleedOutSeconds)

	bleedOutThread = task.delay(bleedOutSeconds, function()
		if resolved then
			return
		end
		resolved = true
		promptConnection:Disconnect()
		cleanup()
		humanoid.WalkSpeed = cachedWalkSpeed
		-- Previously missing entirely: without this, the client never
		-- learned bleed-out had expired (only the revive path fired
		-- this event), leaving the downed banner's countdown stuck
		-- forever on the client with no signal to clear it.
		PlayerDownedChanged:FireClient(player, false, 0)

		-- IMPORTANT: DownedState must stay TRUE until Health actually
		-- hits 0 here — HealthChanged's own intercept below only skips
		-- re-entering downed (and therefore lets a real death happen)
		-- while DownedState.IsDowned(player) is still true. Clearing it
		-- first (the previous, buggy order) made HealthChanged treat
		-- this exactly like a fresh hit and immediately call
		-- enterDownedState again — bleeding out could never actually
		-- kill anyone, it just silently reset the 30s timer forever.
		-- The Died handler below is what finally clears DownedState for
		-- real, once Health reaching 0 actually sticks.
		humanoid.Health = 0
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
		-- Else: stay dead for the rest of THIS wave. A truly-dead
		-- (Health == 0, not just downed) player mid-match contributes to
		-- WaveService's defeat check every second (allPlayersDefeated) —
		-- if every participant is dead/downed at the same moment, that's
		-- an immediate match-ending Defeat regardless of wave timing.
		-- Otherwise, WaveService's respawnDeadParticipants gives this
		-- player a fresh character (LoadCharacter, which re-fires this
		-- whole CharacterAdded chain) the moment the current wave ends
		-- and the next Break phase begins.
	end)

	-- Robux perks, applied per spawn so a purchase mid-session takes
	-- effect on the next respawn without needing a rejoin. Both are a
	-- neutral 1 when unowned, so this is unconditional.
	local healthPerk = PerkService.GetMultiplier(player, "ExtraHealth")
	if healthPerk ~= 1 then
		-- Order matters: raise MaxHealth first, then top Health up to it,
		-- or the new max would sit above a stale current-health value and
		-- the player would spawn visibly damaged.
		humanoid.MaxHealth = humanoid.MaxHealth * healthPerk
		humanoid.Health = humanoid.MaxHealth
	end
	local speedPerk = PerkService.GetMultiplier(player, "SpeedBoost")
	if speedPerk ~= 1 then
		humanoid.WalkSpeed = humanoid.WalkSpeed * speedPerk
	end

	-- Run-drafted Survivor/Adrenaline stacks, re-applied on top of the
	-- perks above. Needed here as well as in the live handler below
	-- because a mid-run respawn (see WaveService's
	-- respawnDeadParticipants) hands out a brand new humanoid at stock
	-- 100 HP / 16 speed, which would quietly erase everything the player
	-- drafted so far.
	applyRunUpgradeStats(player, humanoid)

	-- Fire once immediately so the UI has correct values on spawn.
	PlayerHPChanged:FireClient(player, humanoid.Health, humanoid.MaxHealth)
end

--[[
	Makes a drafted Survivor/Adrenaline pick take effect on the character
	the player is standing in right now, instead of waiting for a
	respawn that may never come. See applyRunUpgradeStats.
]]
RunUpgradeService.OnUpgradeApplied(function(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		applyRunUpgradeStats(player, humanoid)
	end
end)

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
