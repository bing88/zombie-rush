--[[
	WeaponController.lua (ModuleScript)

	Client responsibilities only (per plan section 5): input, camera-based
	aim direction, and local prediction for a responsive-feeling UI. The
	server re-validates everything and is the actual source of truth —
	SyncFromServer() below overwrites local prediction with the server's
	authoritative ammo/reload state whenever AmmoUpdated arrives, so any
	drift (e.g. a fire request the server silently rejected) self-corrects.

	Exposes Init(), RequestReload(), OnAmmoChanged(), and SyncFromServer()
	so ClientMain can wire this into UI and the AmmoUpdated remote.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local DEFAULT_WEAPON = "AssaultRifle"
local stats = WeaponConfig[DEFAULT_WEAPON]

local WeaponController = {}

local camera = workspace.CurrentCamera
local predictedAmmo = stats.MagazineSize
local lastFireTime = 0
local reloading = false
local mouseHeld = false
local initialized = false

local ammoChangedCallback: ((number, number, boolean) -> ())? = nil

local function updateAmmoUI()
	if ammoChangedCallback then
		ammoChangedCallback(predictedAmmo, stats.MagazineSize, reloading)
	end
end

local function tryFire()
	if reloading then
		return
	end

	local now = os.clock()
	if now - lastFireTime < stats.FireRate then
		return
	end

	if predictedAmmo <= 0 then
		return
	end

	lastFireTime = now
	predictedAmmo -= 1
	updateAmmoUI()

	local aimDirection = camera.CFrame.LookVector
	FireWeapon:FireServer(aimDirection)

	-- Local prediction only — the server independently decides when to
	-- actually start a reload and will correct this via SyncFromServer.
	if predictedAmmo <= 0 then
		reloading = true
		updateAmmoUI()
	end
end

function WeaponController.Init()
	if initialized then
		return
	end
	initialized = true

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			mouseHeld = true
			tryFire()
		elseif input.KeyCode == Enum.KeyCode.R then
			WeaponController.RequestReload()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			mouseHeld = false
		end
	end)

	-- Full-auto: holding the button keeps firing, gated by FireRate above.
	RunService.Heartbeat:Connect(function()
		if mouseHeld then
			tryFire()
		end
	end)
end

function WeaponController.RequestReload()
	if reloading or predictedAmmo >= stats.MagazineSize then
		return
	end
	-- Optimistic local flag so the player gets instant feedback; the
	-- server's AmmoUpdated reply is still what actually confirms this.
	reloading = true
	updateAmmoUI()
	ReloadWeapon:FireServer()
end

function WeaponController.SyncFromServer(current: number, max: number, isReloading: boolean)
	predictedAmmo = current
	reloading = isReloading
	updateAmmoUI()
end

function WeaponController.OnAmmoChanged(callback: (number, number, boolean) -> ())
	ammoChangedCallback = callback
	callback(predictedAmmo, stats.MagazineSize, reloading)
end

return WeaponController
