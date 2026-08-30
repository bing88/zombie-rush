--[[
	ClientMain.client.lua

	Entry point for all client controllers. Keeps individual controllers as
	plain ModuleScripts (testable, requireable) and does the wiring here,
	rather than each controller reaching into globals.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local Controllers = script.Parent:WaitForChild("Controllers")
local WeaponController = require(Controllers.WeaponController)
local UIController = require(Controllers.UIController)
local EffectsController = require(Controllers.EffectsController)
local CameraController = require(Controllers.CameraController)
local ShopController = require(Controllers.ShopController)

UIController.Init()
CameraController.Init() -- must init before WeaponController: its RenderStepped
                         -- connection needs to register first so camera-bending
                         -- (auto-aim lock) happens before WeaponController reads
                         -- camera.CFrame.LookVector to decide fire direction.
WeaponController.Init()
EffectsController.Init()
ShopController.Init()

WeaponController.OnAmmoChanged(function(weaponName, current, max, isReloading)
	UIController.SetAmmo(weaponName, current, max, isReloading)
end)

WeaponController.OnLocalFire(function()
	UIController.ShakeAmmoUI()
end)

EffectsController.OnLocalHitmarker(function(killed: boolean)
	UIController.ShowHitmarker(killed)
end)

UIController.OnReloadPressed(function()
	WeaponController.RequestReload()
end)

UIController.OnFireButtonStateChanged(function(held: boolean)
	WeaponController.SetFireButtonHeld(held)
end)

-- Leaderboard: toggle via on-screen tab or the L key; request fresh data
-- each time it's opened (not kept live-updating while open — a match
-- result only changes the underlying data at most once every few
-- minutes, so there's no need for anything more than "ask on open").
local leaderboardOpen = false
local function toggleLeaderboard()
	leaderboardOpen = not leaderboardOpen
	UIController.ToggleLeaderboard()
	if leaderboardOpen then
		Remotes.RequestLeaderboard:FireServer()
	end
end
UIController.OnLeaderboardTabPressed(toggleLeaderboard)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.L then
		toggleLeaderboard()
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
end)

Remotes.WaveStateChanged.OnClientEvent:Connect(function(waveNumber: number, totalWaves: number, state: string)
	UIController.SetWave(waveNumber, totalWaves, state)
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

Remotes.WeaponsOwned.OnClientEvent:Connect(function(owned: { [string]: boolean }, levels: { [string]: number })
	ShopController.SetOwnedWeapons(owned, levels)
end)

Remotes.ShowStartConfirmation.OnClientEvent:Connect(function()
	UIController.ShowStartConfirmation(function(confirmed: boolean)
		Remotes.ConfirmStartGame:FireServer(confirmed)
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
	elseif state == "Starting" then
		UIController.SetGameStateBanner(("Match starts in %ds"):format(secondsLeft))
	elseif state == "WaveIncoming" then
		UIController.SetGameStateBanner(("Wave %d incoming in %ds"):format(nextWaveNumber or 0, secondsLeft))
	elseif state == "WaveStart" then
		-- secondsLeft doubles as the wave number for this event.
		UIController.FlashBanner(("WAVE %d"):format(secondsLeft), 2.5)
	elseif state == "BossIncoming" then
		UIController.SetGameStateBanner(("BOSS INCOMING — %ds"):format(secondsLeft))
	elseif state == "BossStart" then
		UIController.FlashBanner("BOSS FIGHT!", 2.5)
	elseif state == "Victory" then
		UIController.SetGameStateBanner(("Round complete! Returning to lobby in %ds"):format(secondsLeft))
	elseif state == "Defeat" then
		UIController.SetGameStateBanner(("Wiped out... returning to lobby in %ds"):format(secondsLeft))
	else
		UIController.SetGameStateBanner("")
	end
end)
