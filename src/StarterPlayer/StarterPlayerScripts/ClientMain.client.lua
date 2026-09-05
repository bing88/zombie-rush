--[[
	ClientMain.client.lua

	Entry point for all client controllers. Keeps individual controllers as
	plain ModuleScripts (testable, requireable) and does the wiring here,
	rather than each controller reaching into globals.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local Controllers = script.Parent:WaitForChild("Controllers")
local WeaponController = require(Controllers.WeaponController)
local UIController = require(Controllers.UIController)
local EffectsController = require(Controllers.EffectsController)
local CameraController = require(Controllers.CameraController)
local ShopController = require(Controllers.ShopController)
local WeaponViewController = require(Controllers.WeaponViewController)
local PerkShopController = require(Controllers.PerkShopController)
local RunDraftController = require(Controllers.RunDraftController)
local ComboController = require(Controllers.ComboController)

UIController.Init()
CameraController.Init() -- must init before WeaponController: its RenderStepped
                         -- connection needs to register first so camera-bending
                         -- (auto-aim lock) happens before WeaponController reads
                         -- camera.CFrame.LookVector to decide fire direction.
WeaponController.Init()
EffectsController.Init()
ShopController.Init()
PerkShopController.Init()
RunDraftController.Init() -- between-wave 3-choice upgrade draft + the run's owned-upgrade list
ComboController.Init() -- kill-streak readout + ultimate charge meter, and the Q keybind that spends it
WeaponViewController.Init() -- IKControl-based weapon holding: right-hand aim-follow + left-hand support grip — see the file's own doc comment for the full architecture

WeaponController.OnAmmoChanged(function(weaponName, current, max, isReloading)
	UIController.SetAmmo(weaponName, current, max, isReloading)
end)

WeaponController.OnLocalFire(function()
	UIController.ShakeAmmoUI()
	WeaponViewController.PlayFireAnimation()
	EffectsController.SpawnLocalWeaponFireExtras() -- muzzle particles + ejected casing + bolt cycle (see Weapons Kit specialized options)
end)

WeaponController.OnLocalMuzzleFlash(function(position: Vector3)
	EffectsController.SpawnLocalMuzzleFlash(position)
end)

WeaponController.OnLocalTracer(function(origin: Vector3, direction: Vector3, range: number)
	EffectsController.SpawnLocalTracer(origin, direction, range)
end)

WeaponController.OnWeaponEquipped(function(weaponName: string)
	UIController.SetEquippedWeapon(weaponName)
	ShopController.SetEquippedWeapon(weaponName)
end)

EffectsController.OnLocalHitmarker(function(killed: boolean, headshot: boolean)
	UIController.ShowHitmarker(killed, headshot)
end)

UIController.OnReloadPressed(function()
	WeaponController.RequestReload()
end)

UIController.OnViewTogglePressed(function()
	CameraController.ToggleFirstPerson()
end)

-- Ultimate: `Q` is handled inside ComboController, but touch players
-- have no keyboard, so UIController's ULT button routes to the same
-- activation path and mirrors the meter's ready/active colour back onto
-- the button.
UIController.OnUltimatePressed(function()
	ComboController.TryActivate()
end)

ComboController.OnUltimateStateChanged(function(ready: boolean, active: boolean, color: Color3, charge: number)
	UIController.SetUltimateButtonState(ready, active, color, charge)
end)

UIController.OnFireButtonStateChanged(function(held: boolean)
	WeaponController.SetFireButtonHeld(held)
end)

-- Leaderboard: opened via the on-screen tab or the L key (both refresh
-- data on open), closed via the panel's own X button or L again. State
-- is tracked here as the single source of truth so the tab/X/L-key
-- paths can never leave the panel's Visible property out of sync with
-- what the rest of the client thinks is open.
local leaderboardOpen = false
local function openLeaderboard()
	leaderboardOpen = true
	UIController.SetLeaderboardVisible(true)
	Remotes.RequestLeaderboard:FireServer()
end
local function closeLeaderboard()
	leaderboardOpen = false
	UIController.SetLeaderboardVisible(false)
end
local function toggleLeaderboard()
	if leaderboardOpen then
		closeLeaderboard()
	else
		openLeaderboard()
	end
end
UIController.OnLeaderboardTabPressed(openLeaderboard) -- re-tapping the tab while open just refreshes, which is harmless
UIController.OnLeaderboardClosePressed(closeLeaderboard)

-- Number-row -> weapon slot, matching WeaponConfig.Order (same order the
-- custom hotbar lays its slots out in). Needed because hiding Roblox's
-- default Backpack CoreGui (see UIController.Init) also removes its
-- built-in 1/2/3 equip-by-number handling.
local NUMBER_KEYCODES = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.L then
		toggleLeaderboard()
		return
	end
	-- While the between-wave upgrade draft is open it owns 1-3 for card
	-- selection (see RunDraftController.IsDraftOpen) — otherwise a single
	-- keypress would both pick a card and switch weapons.
	if RunDraftController.IsDraftOpen() then
		return
	end

	for index, keyCode in NUMBER_KEYCODES do
		if input.KeyCode == keyCode then
			local weaponName = WeaponConfig.Order[index]
			if weaponName then
				UIController.EquipWeaponByName(weaponName)
			end
			return
		end
	end
end)

-- Server is the source of truth for ammo/reload state; this overwrites
-- whatever WeaponController predicted locally.
Remotes.AmmoUpdated.OnClientEvent:Connect(function(weaponName: string, current: number, max: number, isReloading: boolean)
	WeaponController.SyncFromServer(weaponName, current, max, isReloading)
end)

-- Tracks the previous HP value so a *decrease* (damage taken) can be
-- distinguished from an increase (healing/revive) — only the former
-- should flash the vignette.
local lastKnownHP: number? = nil
Remotes.PlayerHPChanged.OnClientEvent:Connect(function(current: number, max: number)
	UIController.SetHP(current, max)
	if lastKnownHP and current < lastKnownHP then
		UIController.FlashDamageVignette()
		EffectsController.PlayLocalHitSound()
	end
	lastKnownHP = current
end)

Remotes.PlayerDied.OnClientEvent:Connect(function()
	UIController.ShowDeath()
end)

Remotes.PlayerDownedChanged.OnClientEvent:Connect(function(isDowned: boolean, bleedOutSeconds: number)
	UIController.SetDowned(isDowned, bleedOutSeconds)
end)

Remotes.CoinsUpdated.OnClientEvent:Connect(function(amount: number)
	UIController.SetCoins(amount)
	ShopController.SetCash(amount)
end)

Remotes.WaveStateChanged.OnClientEvent:Connect(function(waveNumber: number, totalWaves: number, state: string)
	UIController.SetWave(waveNumber, totalWaves, state)
	-- Break is the shopping window; InProgress/Boss keep the shop open
	-- but stop the tab pulse so it doesn't flash through a fight.
	if state == "Break" then
		ShopController.SetMatchState(true, true)
	elseif state == "InProgress" or state == "Boss" then
		ShopController.SetMatchState(true, false)
	end
end)

Remotes.WaveModifierAnnounced.OnClientEvent:Connect(function(name: string, description: string)
	UIController.SetWaveModifier(name, description)
end)

Remotes.BossHPChanged.OnClientEvent:Connect(function(current: number, max: number)
	UIController.SetBossHP(current, max)
end)

Remotes.ShopResult.OnClientEvent:Connect(function(success: boolean, message: string)
	UIController.ShowToast(message, success)
end)

Remotes.WeaponsOwned.OnClientEvent:Connect(function(
	owned: { [string]: boolean },
	levels: { [string]: number },
	available: { [string]: boolean }?
)
	ShopController.SetOwnedWeapons(owned, levels, available)
	UIController.SetOwnedWeapons(owned)
end)

Remotes.MetaProgressChanged.OnClientEvent:Connect(function(state)
	ShopController.SetMetaProgress(state)
end)

Remotes.PartyStatusChanged.OnClientEvent:Connect(function(inParty: boolean, joined: number, target: number)
	UIController.SetPartyStatus(inParty, joined, target)
end)

UIController.OnPartyExitPressed(function()
	Remotes.LeaveParty:FireServer()
end)

Remotes.ShowStartConfirmation.OnClientEvent:Connect(function(portalId: number)
	UIController.ShowStartConfirmation(function(partySize: number?)
		-- partySize nil means cancelled; the server treats a non-number
		-- as "no party" and ignores it.
		Remotes.ConfirmStartGame:FireServer(portalId, partySize)
	end)
end)

Remotes.ObjectiveUpdated.OnClientEvent:Connect(function(progress: number, target: number, completed: boolean)
	UIController.SetObjective(progress, target, completed)
end)

Remotes.MatchScoreboard.OnClientEvent:Connect(function(entries)
	UIController.ShowScoreboard(entries)
end)

Remotes.LeaderboardData.OnClientEvent:Connect(function(entries)
	UIController.SetLeaderboardEntries(entries)
end)

Remotes.GameStateChanged.OnClientEvent:Connect(function(state: string, secondsLeft: number, nextWaveNumber: number?)
	if state == "Lobby" then
		UIController.SetGameStateBanner("Waiting for players...")
		UIController.SetWaveModifier("Normal", "")
		UIController.HideScoreboard()
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(false, false)
	elseif state == "Starting" then
		UIController.SetGameStateBanner(("Match starts in %ds"):format(secondsLeft))
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(false, false)
	elseif state == "WaveIncoming" then
		UIController.SetGameStateBanner(("Wave %d incoming in %ds"):format(nextWaveNumber or 0, secondsLeft))
		ShopController.SetMatchState(true, true)
	elseif state == "WaveStart" then
		-- secondsLeft doubles as the wave number for this event.
		UIController.FlashBanner(("WAVE %d"):format(secondsLeft), 2.5)
		-- The party was consumed to start this match rather than
		-- disbanded, so the server deliberately doesn't send a
		-- "you left the party" status here — clear the waiting panel off
		-- the match starting instead, or it would linger all run.
		UIController.SetPartyStatus(false, 0, 0)
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(true, false)
	elseif state == "BossIncoming" then
		UIController.SetGameStateBanner(("BOSS INCOMING — %ds"):format(secondsLeft))
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(true, false)
	elseif state == "BossStart" then
		UIController.FlashBanner("BOSS FIGHT!", 2.5)
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(true, false)
	elseif state == "Defeat" then
		-- Endless mode has no victory state — a run only ends by being
		-- wiped out, and the scoreboard reports how far you got.
		UIController.SetGameStateBanner(("Wiped out... returning to lobby in %ds"):format(secondsLeft))
		UIController.SetWaveBreakSkipStatus(0, 0)
		ShopController.SetMatchState(false, false)
	else
		UIController.SetGameStateBanner("")
		UIController.SetWaveBreakSkipStatus(0, 0)
	end
end)

UIController.OnWaveBreakSkipPressed(function()
	Remotes.SkipWaveBreak:FireServer()
end)

Remotes.WaveBreakSkipStatus.OnClientEvent:Connect(function(skippedCount: number, totalNeeded: number)
	UIController.SetWaveBreakSkipStatus(tonumber(skippedCount) or 0, tonumber(totalNeeded) or 0)
end)
