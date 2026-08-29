--[[
	WeaponController.lua (ModuleScript)

	Client responsibilities only (per plan section 5): input, camera-based
	aim direction, and local prediction for a responsive-feeling UI. The
	server re-validates everything and is the actual source of truth —
	SyncFromServer() below overwrites local prediction with the server's
	authoritative ammo/reload state whenever AmmoUpdated arrives, so any
	drift (e.g. a fire request the server silently rejected) self-corrects.

	Firing is no longer triggered by tapping/clicking anywhere on screen.
	The only manual trigger is the dedicated on-screen fire button
	(SetFireButtonHeld, wired from UIController) — this also happens to
	work for a desktop mouse click on that button, so there's one trigger
	path instead of two. On top of that, every frame this also checks
	AutoAimController for a nearby target and auto-fires at it regardless
	of whether the fire button is held, as a convenience assist.

	Exposes Init(), RequestReload(), SetFireButtonHeld(), OnAmmoChanged(),
	and SyncFromServer() so ClientMain can wire this into UI and remotes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local Controllers = script.Parent
local AutoAimController = require(Controllers.AutoAimController)
local WeaponViewController = require(Controllers.WeaponViewController)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon
local DEFAULT_WEAPON = "AssaultRifle"
local stats = WeaponConfig[DEFAULT_WEAPON]

local WeaponController = {}

local player = Players.LocalPlayer
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

local function getMuzzlePosition(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	local handle = tool and tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return rootPart and rootPart.Position
end

local function tryFire(overrideDirection: Vector3?)
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

	local aimDirection = overrideDirection or camera.CFrame.LookVector
	FireWeapon:FireServer(aimDirection)

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

	RunService.Heartbeat:Connect(function()
		local muzzlePosition = getMuzzlePosition()
		local autoAimDirection, shouldAutoFire = nil, false
		if muzzlePosition then
			autoAimDirection, shouldAutoFire = AutoAimController.FindTarget(muzzlePosition)
		end

		if shouldAutoFire and autoAimDirection then
			tryFire(autoAimDirection)
		elseif fireButtonHeld then
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
