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

--[[
	Run-drafted Gunslinger/Speed Loader scales, mirrored from the server
	(see RunUpgradeService's buildClientState and the RunUpgradesChanged
	handler in Init below). Both default to a neutral 1.

	These HAVE to be mirrored rather than left server-only: every
	prediction in this module — the local fire-rate gate, the reload
	animation length, the reload watchdog deadline — is computed
	client-side so shooting responds instantly instead of waiting a
	round trip. A server that accepts faster shots while this module
	keeps throttling at the base rate would make a drafted fire-rate
	upgrade completely invisible to the player who chose it.

	They're received as finished scales, not raw stack counts, so the
	client never re-derives the combination and can't disagree with the
	server about it. The server still independently enforces its own
	copy, so a tampered client can only ever throttle ITSELF.
]]
local runFireRateScale = 1
local runReloadScale = 1

--[[
	The same mirroring, for the two systems that also shorten the gap
	between shots: the current kill-streak tier (ComboService) and
	Berserk while it's running (UltimateService). Everything in the
	comment above applies identically — a streak that made the server
	accept faster shots while this module kept throttling would be a
	reward the player earned and never felt.

	Kept as separate variables rather than one combined scale so each
	arrives from, and is overwritten by, exactly the remote that owns it.
	A single shared number would need both handlers to know the other's
	current value to avoid clobbering it.
]]
local comboFireRateScale = 1
local ultimateFireRateScale = 1

--[[
	The weapon's effective shot delay and reload duration for this
	player, right now. Every read of FireRate/ReloadTime goes through
	these two rather than touching WeaponConfig directly, so a drafted
	upgrade can't be applied in one place and forgotten in another.

	The three fire-rate scales multiply, mirroring exactly how the server
	composes them in WeaponService's fire-gap check. If a fourth source
	is ever added there, it has to be added here too.
]]
local function effectiveFireRate(stats): number
	return stats.FireRate * runFireRateScale * comboFireRateScale * ultimateFireRateScale
end

local function effectiveReloadTime(stats): number
	return stats.ReloadTime * runReloadScale
end

local ammoChangedCallback: ((string, number, number, boolean) -> ())? = nil
local localFireCallback: (() -> ())? = nil
local localMuzzleFlashCallback: ((Vector3) -> ())? = nil
local localTracerCallback: ((Vector3, Vector3, number) -> ())? = nil
local weaponEquippedCallback: ((string) -> ())? = nil

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
	just run locally where it's zero-latency for the shooter — EXCEPT in
	first person while WeaponViewController's camera-glued viewmodel is
	showing, where the real (character-attached) Tool's Muzzle has no
	visual relationship to the on-screen gun at all (see
	WeaponViewController.GetActiveMuzzleWorldPosition's header) — that
	takes priority whenever it's available.
]]
local function getLocalMuzzlePosition(): Vector3?
	local viewmodelMuzzle = WeaponViewController.GetActiveMuzzleWorldPosition()
	if viewmodelMuzzle then
		return viewmodelMuzzle
	end

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
			reloadDeadline[weaponName] = os.clock() + effectiveReloadTime(stats) + 1.5
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
			-- Passing the EFFECTIVE time keeps the authored reload
			-- animation stretched to match the real reload: the view
			-- controller scales playback to whatever duration it's
			-- given, so a Speed Loader run would otherwise finish
			-- reloading well before the animation did.
			WeaponViewController.PlayReloadAnimation(effectiveReloadTime(stats))
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
	if now - lastFireTime < effectiveFireRate(stats) then
		return
	end

	ensureAmmo(currentWeapon)
	if (predictedAmmo[currentWeapon] or 0) <= 0 then
		return
	end

	lastFireTime = now
	predictedAmmo[currentWeapon] -= 1
	updateAmmoUI()

	local muzzlePosition = getLocalMuzzlePosition()
	local aimDirection = camera.CFrame.LookVector
	FireWeapon:FireServer(aimDirection, muzzlePosition)

	if muzzlePosition then
		if localMuzzleFlashCallback then
			localMuzzleFlashCallback(muzzlePosition)
		end
		if localTracerCallback then
			localTracerCallback(muzzlePosition, aimDirection, stats.Range)
		end
	end

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
		if weaponEquippedCallback then
			weaponEquippedCallback(currentWeapon)
		end
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

	-- Run-drafted fire-rate/reload scales — see runFireRateScale above
	-- for why the client needs its own copy of these.
	Remotes.RunUpgradesChanged.OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		runFireRateScale = tonumber(state.FireRateScale) or 1
		runReloadScale = tonumber(state.ReloadScale) or 1
	end)

	-- Kill-streak and ultimate fire-rate scales, from the same two
	-- remotes that drive their HUD readouts. Both fall back to a neutral
	-- 1 on a malformed payload, so a bad message can only ever cost the
	-- bonus for a moment rather than leaving the weapon stuck at a stale
	-- faster-than-allowed rate the server would then reject.
	Remotes.ComboChanged.OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		comboFireRateScale = tonumber(state.FireRateScale) or 1
	end)

	Remotes.UltimateStateChanged.OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		-- The server sends the bonus and whether it's live, not a scale,
		-- because the HUD needs the bonus for its label either way.
		-- Same 1/(1+bonus) form the server uses.
		if state.Active then
			ultimateFireRateScale = 1 / (1 + (tonumber(state.FireRateBonus) or 0))
		else
			ultimateFireRateScale = 1
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
			-- Effective, not raw: a Speed Loader run reloads faster than
			-- WeaponConfig says, and a watchdog deadline computed from
			-- the base time would just be needlessly generous.
			reloadDeadline[weaponName] = os.clock() + effectiveReloadTime(stats) + 1.5
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

--[[
	Fires with the shooter's own current muzzle position, immediately on
	every local shot — zero network wait. This is what actually fixes
	the muzzle flash trailing behind a moving player: the flash it drives
	(see EffectsController.SpawnLocalMuzzleFlash) never waits on a
	server round-trip at all for the local player.
]]
function WeaponController.OnLocalMuzzleFlash(callback: (Vector3) -> ())
	localMuzzleFlashCallback = callback
end

--[[
	Fires with (origin, direction, range) immediately on every local
	shot, alongside OnLocalMuzzleFlash — this is what actually fixes the
	tracer beam trailing behind a moving player, which the muzzle-flash
	fix alone didn't touch.
]]
function WeaponController.OnLocalTracer(callback: (Vector3, Vector3, number) -> ())
	localTracerCallback = callback
end

-- Fires with the weapon's name every time ANY Tool.Equipped happens
-- (hotbar click, number key, or Roblox's own equip handling) — lets
-- UIController keep its custom hotbar's highlight ring in sync without
-- duplicating this controller's Backpack/Character tracking.
function WeaponController.OnWeaponEquipped(callback: (string) -> ())
	weaponEquippedCallback = callback
end

return WeaponController
