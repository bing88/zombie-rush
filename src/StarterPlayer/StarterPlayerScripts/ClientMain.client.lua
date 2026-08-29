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

UIController.Init()
WeaponController.Init()
EffectsController.Init()
CameraController.Init()

WeaponController.OnAmmoChanged(function(current, max, isReloading)
	UIController.SetAmmo(current, max, isReloading)
end)

UIController.OnReloadPressed(function()
	WeaponController.RequestReload()
end)

UIController.OnFireButtonStateChanged(function(held: boolean)
	WeaponController.SetFireButtonHeld(held)
end)

-- Server is the source of truth for ammo/reload state; this overwrites
-- whatever WeaponController predicted locally.
Remotes.AmmoUpdated.OnClientEvent:Connect(function(current: number, max: number, isReloading: boolean)
	WeaponController.SyncFromServer(current, max, isReloading)
end)

Remotes.PlayerHPChanged.OnClientEvent:Connect(function(current: number, max: number)
	UIController.SetHP(current, max)
end)

Remotes.PlayerDied.OnClientEvent:Connect(function()
	UIController.ShowDeath()
end)
