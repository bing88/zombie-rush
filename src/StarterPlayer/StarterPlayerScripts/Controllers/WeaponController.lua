--[[
	WeaponController.lua (ModuleScript)

	Client responsibilities only (per plan section 5): input, camera-based
	aim direction, and local visual/ammo prediction for UI responsiveness.
	The server re-validates everything — this script cannot grant damage,
	ammo, or fire rate on its own; the server silently drops anything it
	doesn't accept.

	Exposes Init() and OnAmmoChanged() so ClientMain can wire this into UI.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local FireWeapon = Remotes.FireWeapon
local DEFAULT_WEAPON = "AssaultRifle"
local stats = WeaponConfig[DEFAULT_WEAPON]

local WeaponController = {}

local camera = workspace.CurrentCamera
local predictedAmmo = stats.MagazineSize
local lastFireTime = 0
local reloading = false
local mouseHeld = false
local initialized = false

local ammoChangedCallback: ((number, number) -> ())? = nil

local function setAmmo(value: number)
	predictedAmmo = value
	if ammoChangedCallback then
		ammoChangedCallback(predictedAmmo, stats.MagazineSize)
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
	setAmmo(predictedAmmo - 1)

	local aimDirection = camera.CFrame.LookVector
	FireWeapon:FireServer(aimDirection)

	if predictedAmmo <= 0 then
		reloading = true
		task.delay(stats.ReloadTime, function()
			reloading = false
			setAmmo(stats.MagazineSize)
		end)
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
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseHeld = true
			tryFire()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
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

function WeaponController.OnAmmoChanged(callback: (number, number) -> ())
	ammoChangedCallback = callback
	callback(predictedAmmo, stats.MagazineSize)
end

return WeaponController
