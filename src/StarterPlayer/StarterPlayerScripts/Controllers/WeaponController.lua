--[[
	WeaponController.lua (ModuleScript)

	Client responsibilities only (per plan section 5): input and local
	prediction for a responsive-feeling UI. The server re-validates
	everything and is the actual source of truth — SyncFromServer() below
	overwrites local prediction with the server's authoritative ammo/
	reload state per weapon whenever AmmoUpdated arrives.

	Tier 1: tracks the currently equipped weapon by listening to
	Tool.Equipped on every Tool in the Backpack + character (weapon
	*switching* itself is just Roblox's default Backpack hotbar — number
	keys / clicking a slot — no custom input handling needed here).
	Ammo/reload state is now tracked per weapon so switching weapons mid-
	reload doesn't lose or corrupt another weapon's state.

	Aim direction is always just camera.CFrame.LookVector at the moment of
	firing — no separate override logic here. CameraController is what
	decides whether the camera itself is currently bent toward a nearby
	target (auto-aim lock-on); this controller doesn't need to know why
	the camera is pointing where it's pointing, only that it should fire
	there when told to.

	Firing triggers on:
	  - The dedicated on-screen fire button being held (SetFireButtonHeld)
	  - CameraController reporting a target is currently locked (auto-fire)

	IMPORTANT: this must be Init()'d AFTER CameraController in ClientMain,
	so CameraController's RenderStepped connection (which may bend the
	camera this frame) registers and therefore runs first.

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
local CameraController = require(Controllers.CameraController)
local WeaponViewController = require(Controllers.WeaponViewController)

local FireWeapon = Remotes.FireWeapon
local ReloadWeapon = Remotes.ReloadWeapon

local WeaponController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local currentWeapon = WeaponConfig.StartingWeapon
local predictedAmmo: { [string]: number } = {} -- [weaponName] = ammo in magazine
local maxAmmo: { [string]: number } = {} -- [weaponName] = current capacity, server-authoritative once synced
local reloading: { [string]: boolean } = {} -- [weaponName] = true while reloading
local reloadDeadline: { [string]: number } = {} -- [weaponName] = os.clock() by which a real reload must have finished
local lastFireTime = 0
local fireButtonHeld = false
local initialized = false

local ammoChangedCallback: ((string, number, number, boolean) -> ())? = nil
local localFireCallback: (() -> ())? = nil

local function statsFor(weaponName: string)
	return WeaponConfig[weaponName]
end

--[[
	Local (client-authoritative-for-visuals-only) muzzle world position.
	Sent alongside the fire request so the server can use a fresh
	position for the FX broadcast instead of its own replicated copy of
	the character, which lags behind a moving player by roughly their
	ping — see WeaponService's origin-tolerance check, which validates
	this rather than trusting it outright. Mirrors the exact lookup
	WeaponService itself does server-side (Tool -> Handle -> Muzzle),
	just run locally where it's zero-latency for the shooter.
]]
local function getLocalMuzzlePosition(): Vector3?
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
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return rootPart and rootPart.Position
end

--[[
	Seeds both ammo and capacity with the weapon's BASE config values as a
	reasonable guess before the server's first AmmoUpdated arrives for
	this weapon. This is only ever a starting guess — maxAmmo gets
	overwritten with the real (possibly upgrade-scaled) capacity by
	SyncFromServer, which is the actual source of truth. Without tracking
	maxAmmo separately, the UI would permanently show the un-upgraded
	base capacity forever, since there'd be nothing else to read it from.
]]
local function ensureAmmo(weaponName: string)
	local stats = statsFor(weaponName)
	if not stats then
		return
	end
	if predictedAmmo[weaponName] == nil then
		predictedAmmo[weaponName] = stats.MagazineSize
	end
	if maxAmmo[weaponName] == nil then
		maxAmmo[weaponName] = stats.MagazineSize
	end
end

local function updateAmmoUI()
	if not ammoChangedCallback then
		return
	end
	ensureAmmo(currentWeapon)
	local stats = statsFor(currentWeapon)
	if not stats then
		return
	end
	ammoChangedCallback(
		currentWeapon,
		predictedAmmo[currentWeapon] or 0,
		maxAmmo[currentWeapon] or stats.MagazineSize,
		reloading[currentWeapon] == true
	)
end

--[[
	Central place to change the reloading flag so the reload animation
	only ever triggers once per reload (on the false -> true transition),
	regardless of whether that transition came from local prediction
	(RequestReload / auto-empty) or a server sync overwriting it.

	Also arms/disarms a watchdog deadline: if a dropped/rejected FireServer
	call or missed remote ever left this flag stuck true with no server
	sync to clear it, checkReloadWatchdog() below force-clears it instead
	of leaving the player stuck for the rest of the match.
]]
local function setReloading(weaponName: string, value: boolean)
	if value then
		local stats = statsFor(weaponName)
		if stats then
			-- Generous buffer over the server's own reload timer so a
			-- normal reload never gets pre-empted by the watchdog.
			reloadDeadline[weaponName] = os.clock() + stats.ReloadTime + 1.5
		end
	else
		reloadDeadline[weaponName] = nil
	end

	if reloading[weaponName] == value then
		return
	end
	reloading[weaponName] = value
	if value and weaponName == currentWeapon then
		local stats = statsFor(weaponName)
		if stats then
			WeaponViewController.PlayReloadAnimation(stats.ReloadTime)
		end
	end
	if weaponName == currentWeapon then
		updateAmmoUI()
	end
end

--[[
	Self-heals a reload that's been "in progress" longer than the weapon's
	ReloadTime plus a generous buffer — this should never happen if every
	FireServer/ReloadWeapon round-trip completes normally, but a dropped
	client->server request (e.g. rejected by the fire-rate check right at
	the edge of a magazine, or any other missed sync) previously left the
	player stuck with a weapon that visually never finishes reloading and
	no way to escape it (R was gated behind the very flag that was stuck).
]]
local function checkReloadWatchdog()
	for weaponName, deadline in reloadDeadline do
		if reloading[weaponName] and os.clock() > deadline then
			reloadDeadline[weaponName] = nil
			reloading[weaponName] = false
			local stats = statsFor(weaponName)
			if stats then
				predictedAmmo[weaponName] = maxAmmo[weaponName] or stats.MagazineSize
			end
			if weaponName == currentWeapon then
				updateAmmoUI()
			end
		end
	end
end

local function tryFire()
	if reloading[currentWeapon] then
		return
	end

	local stats = statsFor(currentWeapon)
	if not stats then
		return
	end

	local now = os.clock()
	if now - lastFireTime < stats.FireRate then
		return
	end

	ensureAmmo(currentWeapon)
	if (predictedAmmo[currentWeapon] or 0) <= 0 then
		return
	end

	lastFireTime = now
	predictedAmmo[currentWeapon] -= 1
	updateAmmoUI()

	FireWeapon:FireServer(camera.CFrame.LookVector, getLocalMuzzlePosition())

	if localFireCallback then
		localFireCallback()
	end

	if predictedAmmo[currentWeapon] <= 0 then
		setReloading(currentWeapon, true)
	end
end

--[[
	Connects Tool.Equipped so switching weapons via the default Backpack
	hotbar (number keys / clicking a slot) updates local prediction state
	without any custom input handling.
]]
local function trackTool(tool: Instance)
	if not tool:IsA("Tool") or not statsFor(tool.Name) then
		return
	end
	tool.Equipped:Connect(function()
		currentWeapon = tool.Name
		ensureAmmo(currentWeapon)
		updateAmmoUI()
	end)
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		trackTool(child)
	end
	container.ChildAdded:Connect(trackTool)
end

function WeaponController.Init()
	if initialized then
		return
	end
	initialized = true

	watchContainer(player:WaitForChild("Backpack"))
	if player.Character then
		watchContainer(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		predictedAmmo = {}
		maxAmmo = {}
		reloading = {}
		reloadDeadline = {}
		watchContainer(character)
	end)

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
		checkReloadWatchdog()
		if CameraController.IsLocked() or fireButtonHeld then
			tryFire()
		end
	end)
end

function WeaponController.SetFireButtonHeld(held: boolean)
	fireButtonHeld = held
end

function WeaponController.RequestReload()
	local stats = statsFor(currentWeapon)
	if not stats then
		return
	end
	ensureAmmo(currentWeapon)
	if (predictedAmmo[currentWeapon] or 0) >= (maxAmmo[currentWeapon] or stats.MagazineSize) then
		return
	end
	-- Deliberately NOT gated on the local `reloading` flag: the server is
	-- authoritative and safely no-ops a redundant request, so pressing R
	-- always gives the player a way to nudge/re-sync a weapon that looks
	-- stuck, instead of that same flag blocking its own recovery.
	setReloading(currentWeapon, true) -- optimistic local flag; server's AmmoUpdated reply confirms it
	ReloadWeapon:FireServer()
end

function WeaponController.SyncFromServer(weaponName: string, current: number, max: number, isReloading: boolean)
	predictedAmmo[weaponName] = current
	maxAmmo[weaponName] = max
	reloading[weaponName] = isReloading
	if isReloading then
		local stats = statsFor(weaponName)
		if stats then
			reloadDeadline[weaponName] = os.clock() + stats.ReloadTime + 1.5
		end
	else
		reloadDeadline[weaponName] = nil
	end
	if weaponName == currentWeapon then
		updateAmmoUI()
	end
end

function WeaponController.OnAmmoChanged(callback: (string, number, number, boolean) -> ())
	ammoChangedCallback = callback
	updateAmmoUI()
end

--[[
	Fires once per successful local shot (not per server confirmation —
	this is immediate, for snappy UI feedback like the ammo-counter
	shake). Doesn't indicate whether the shot hit anything.
]]
function WeaponController.OnLocalFire(callback: () -> ())
	localFireCallback = callback
end

return WeaponController
