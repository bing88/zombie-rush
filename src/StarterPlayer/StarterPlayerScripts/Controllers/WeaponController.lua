--[[
	WeaponController.lua (ModuleScript)

	Client responsibilities only (per plan section 5): input and local
	prediction for a responsive-feeling UI. The server re-validates
	everything and is the actual source of truth — SyncFromServer() below
	overwrites local prediction with the server's authoritative ammo/
	reload state whenever AmmoUpdated arrives.

	Aim direction is always just camera.CFrame.LookVector at the moment of
	firing — no separate override logic here. CameraController is what
	decides whether the camera itself is currently bent toward a nearby
	target (auto-aim lock-on); this controller doesn't need to know why
	the camera is pointing where it's pointing, only that it should fire
	there when told to. That's what keeps manual aim and auto-aim
	perfectly consistent: there's only one aim direction, ever.

	Firing triggers on:
	  - The dedicated on-screen fire button being held (SetFireButtonHeld)
	  - CameraController reporting a target is currently locked (auto-fire)

	IMPORTANT: this must be Init()'d AFTER CameraController in ClientMain,
	so CameraController's RenderStepped connection (which may bend the
	camera this frame) registers and therefore runs first. Both use
	RenderStepped so they stay in lockstep frame-to-frame.

	Exposes Init(), RequestReload(), SetFireButtonHeld(), OnAmmoChanged(),
	and SyncFromServer() so ClientMain can wire this into UI and remotes.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local Controllers = script.Parent
local CameraController = require(Controllers.CameraController)
local WeaponViewController = require(Controllers.WeaponViewController)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local DEFAULT_WEAPON = "AssaultRifle"
local stats = WeaponConfig[DEFAULT_WEAPON]

local WeaponController = {}

local camera = workspace.CurrentCamera

local predictedAmmo = stats.MagazineSize
local lastFireTime = 0
local reloading = false
local fireButtonHeld = false
local initialized = false

local ammoChangedCallback: ((number, number, boolean) -> ())? = nil

local function updateAmmoUI()
	if ammoChangedCallback then
		ammoChangedCallback(predictedAmmo, stats.MagazineSize, reloading)
	end
end

--[[
	Central place to change the reloading flag so the reload animation
	only ever triggers once per reload (on the false -> true transition),
	regardless of whether that transition came from local prediction
	(RequestReload / auto-empty) or a server sync overwriting it.
]]
local function setReloading(value: boolean)
	if reloading == value then
		return
	end
	reloading = value
	if value then
		WeaponViewController.PlayReloadAnimation(stats.ReloadTime)
	end
	updateAmmoUI()
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

	FireWeapon:FireServer(camera.CFrame.LookVector)

	if predictedAmmo <= 0 then
		setReloading(true)
	end
end

function WeaponController.Init()
	if initialized then
		return
	end
	initialized = true

	-- Only remaining raw input binding: reload. Firing is button/auto-aim only.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			WeaponController.RequestReload()
		end
	end)

	RunService.RenderStepped:Connect(function()
		if CameraController.IsLocked() or fireButtonHeld then
			tryFire()
		end
	end)
end

function WeaponController.SetFireButtonHeld(held: boolean)
	fireButtonHeld = held
end

function WeaponController.RequestReload()
	if reloading or predictedAmmo >= stats.MagazineSize then
		return
	end
	setReloading(true) -- optimistic local flag; server's AmmoUpdated reply confirms it
	ReloadWeapon:FireServer()
end

function WeaponController.SyncFromServer(current: number, max: number, isReloading: boolean)
	predictedAmmo = current
	setReloading(isReloading)
	updateAmmoUI()
end

function WeaponController.OnAmmoChanged(callback: (number, number, boolean) -> ())
	ammoChangedCallback = callback
	callback(predictedAmmo, stats.MagazineSize, reloading)
end

return WeaponController
