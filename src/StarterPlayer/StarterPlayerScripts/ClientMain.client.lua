--[[
	ClientMain.client.lua

	Entry point for all client controllers. Keeps individual controllers as
	plain ModuleScripts (testable, requireable) and does the wiring here,
	rather than each controller reaching into globals.
]]

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

UIController.OnReloadPressed(function()
	WeaponController.RequestReload()
end)

UIController.OnFireButtonStateChanged(function(held: boolean)
	WeaponController.SetFireButtonHeld(held)
end)

-- Server is the source of truth for ammo/reload state; this overwrites
-- whatever WeaponController predicted locally.
Remotes.AmmoUpdated.OnClientEvent:Connect(function(weaponName: string, current: number, max: number, isReloading: boolean)
	WeaponController.SyncFromServer(weaponName, current, max, isReloading)
end)

Remotes.PlayerHPChanged.OnClientEvent:Connect(function(current: number, max: number)
	UIController.SetHP(current, max)
end)

Remotes.PlayerDied.OnClientEvent:Connect(function()
	UIController.ShowDeath()
end)

Remotes.CoinsUpdated.OnClientEvent:Connect(function(amount: number)
	UIController.SetCoins(amount)
end)

Remotes.WaveStateChanged.OnClientEvent:Connect(function(waveNumber: number, totalWaves: number, state: string)
	UIController.SetWave(waveNumber, totalWaves, state)
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

Remotes.GameStateChanged.OnClientEvent:Connect(function(state: string, secondsLeft: number, nextWaveNumber: number?)
	if state == "Lobby" then
		UIController.SetGameStateBanner("Waiting for players...")
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
	else
		UIController.SetGameStateBanner("")
	end
end)
