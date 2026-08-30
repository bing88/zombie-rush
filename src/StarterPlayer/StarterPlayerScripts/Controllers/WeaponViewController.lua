--[[
	WeaponViewController.lua (ModuleScript)

	Purely cosmetic, local-only tool animation.

	FIRST FIX, found via evidence not guessing: Tool.Grip does NOT
	control what's rendered the way it's commonly assumed to. Roblox
	reads Grip ONCE, at equip time, to build an internal Weld (named
	"RightGrip"/"LeftGrip" by convention, found as a child of the
	character's RightHand/LeftHand, with Part0=hand and Part1=Handle).
	That Weld's own C0 is what actually determines the visible pose —
	and it does NOT get re-derived from Tool.Grip afterward. Confirmed
	directly: dumping that Weld's C0 alongside a continuously-updated
	Tool.Grip showed the Weld's C0 sitting completely frozen at its
	equip-time value regardless of what Tool.Grip was doing, across
	three different techniques (direct assignment, TweenService,
	IKControl) that all "correctly" computed and set Grip with zero
	visible effect. This module targets that Weld directly instead.

	SECOND FIX: applying a fixed offset relative to the hand's rest pose
	still rode along with the hand's own run-animation swing every
	frame. Fixed by actively CANCELING OUT whatever the hand is
	currently doing and locking the weapon to a stable pose defined
	independently of the hand — see updateStabilizedFollow's own
	comment for the exact math.

	THIRD FIX: that stable pose was originally computed as "a small
	offset in front of the camera" — correct for first-person (camera
	≈ eye position), but in third-person the camera sits far BEHIND the
	character. That placed the gun right at the camera lens, reading as
	gigantic due to ordinary perspective distortion on an object that
	close, completely disconnected from the character's actual body.
	getGunBasePosition below picks a different base position depending
	on camera mode — the camera itself in first-person, the character's
	UpperTorso in third-person — while rotation (camera pitch, clamped)
	is shared between both.

	LOCAL ONLY regardless: changes made client-side aren't visible to
	other players watching you — same limitation as everything else
	client-side in this codebase; a shared version needs either a real
	authored Animation asset or a server-synced system.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local WeaponViewController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local RELOAD_DIP_OFFSET = CFrame.new(0, -0.6, 0.3) * CFrame.Angles(math.rad(35), 0, 0)

-- Kept modest so the barrel tilt reads as "following your aim" rather
-- than an exaggerated/cartoonish swing.
local MAX_PITCH_DEGREES = 35

-- Pitch-follow backs off until this os.clock() timestamp passes, so it
-- doesn't fight the reload dip/return tween below for control of the weld.
local reloadingUntilClock = 0

local hasLoggedNoGrips = false
local lastDiagnosticPrintTime = 0

--[[
	Finds the equip-time Weld(s) Roblox actually renders from — RightGrip
	under RightHand always for a held weapon; LeftGrip under LeftHand too,
	for two-handed weapons that have one (this specific Pistol only has
	RightGrip, per the diagnostic dump — other weapons in this game may
	have both). Returns whatever's actually present, which may be just one.
]]
local function findGripWelds(): { Weld }
	local character = player.Character
	if not character then
		return {}
	end

	local welds = {}
	for _, handName in { "RightHand", "LeftHand" } do
		local hand = character:FindFirstChild(handName)
		if hand then
			local weld = hand:FindFirstChild((handName == "RightHand") and "RightGrip" or "LeftGrip")
			if weld and weld:IsA("Weld") then
				table.insert(welds, weld)
			end
		end
	end
	return welds
end

--[[
	Plays the real weapon's own "Reload" Sound if it has one (silently
	does nothing otherwise — not every asset ships one). Resets
	TimePosition first so re-reloading the same weapon in quick
	succession (e.g. after the reload watchdog force-clears a stuck
	one) always restarts the clip instead of Play() no-oping.
]]
local function playReloadSound()
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	local sound = tool and tool:FindFirstChild("Reload", true)
	if sound and sound:IsA("Sound") then
		sound.TimePosition = 0
		sound:Play()
	end
end

--[[
	Local offsets (right, down, forward) applied on top of whichever
	base position getGunBasePosition picks for the current camera mode.
	Still aesthetic placement guesses, not verified in Studio — retune
	these two constants if the gun sits at an awkward distance/angle.
]]
local GUN_OFFSET_FIRST_PERSON = CFrame.new(0.5, -0.5, -0.8)
local GUN_OFFSET_THIRD_PERSON = CFrame.new(0.3, -0.3, -0.5)

local function getGunOffset(): CFrame
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return GUN_OFFSET_FIRST_PERSON
	end
	return GUN_OFFSET_THIRD_PERSON
end

--[[
	Where the gun should be positioned FROM, before the local offset
	above is applied. First-person: the camera itself (camera ≈ eye
	position, behaves like a standard viewmodel). Third-person: the
	character's own UpperTorso — NOT the camera, which sits far behind
	the character in this mode; using the camera's position there was
	the actual bug behind the weapon appearing gigantic and floating at
	the lens (see the file's header comment).
]]
local function getGunBasePosition(character: Model): Vector3
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return camera.CFrame.Position
	end
	local upperTorso = character:FindFirstChild("UpperTorso") :: BasePart?
	return upperTorso and upperTorso.Position or camera.CFrame.Position
end

--[[
	Camera ROTATION ONLY (pitch clamped, yaw preserved, roll dropped) —
	same decomposition approach used elsewhere in this project for
	camera-relative aiming math. Position is handled separately by
	getGunBasePosition above, since the appropriate position source
	differs by camera mode while the desired orientation doesn't.
]]
local function getStabilizedCameraRotation(): CFrame
	local lookVector = camera.CFrame.LookVector

	local horizontal = Vector3.new(lookVector.X, 0, lookVector.Z)
	local horizontalLength = horizontal.Magnitude
	if horizontalLength < 0.0001 then
		horizontal = Vector3.new(0, 0, -1)
		horizontalLength = 1
	end
	horizontal = horizontal / horizontalLength

	local rawPitch = math.atan2(lookVector.Y, horizontalLength)
	local clampedPitch = math.clamp(rawPitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	local yaw = math.atan2(-horizontal.X, -horizontal.Z)

	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(clampedPitch, 0, 0)
end

--[[ Combines base position + rotation + local offset for the given character. ]]
local function getDesiredWorldCFrame(character: Model): CFrame
	local basePosition = getGunBasePosition(character)
	local rotation = getStabilizedCameraRotation()
	return CFrame.new(basePosition) * rotation * getGunOffset()
end

--[[
	Reload dip/return, redone to work with the continuous stabilized-
	follow below instead of a static "rest pose" (which no longer really
	exists — the weapon is driven to a fresh desired pose every frame
	now, not toward a fixed rest position). Dips to the current desired
	pose with RELOAD_DIP_OFFSET applied on top; the "return" tween aims
	at whatever the desired pose happens to be at that moment, then
	hands off cleanly to updateStabilizedFollow once reloadingUntilClock
	passes — no separate "snap back to rest" step needed.
]]
function WeaponViewController.PlayReloadAnimation(durationSeconds: number)
	local character = player.Character
	local welds = findGripWelds()
	if not character or #welds == 0 then
		return
	end

	playReloadSound()

	local dipTime = math.clamp(durationSeconds * 0.35, 0.1, 0.6)
	local returnTime = math.max(durationSeconds - dipTime, 0.15)

	-- Stabilized-follow yields weld control for the whole reload sequence
	-- (plus a small buffer) so it doesn't immediately overwrite whichever
	-- tween is currently running.
	reloadingUntilClock = os.clock() + dipTime + returnTime + 0.1

	local dipWorldTarget = getDesiredWorldCFrame(character) * RELOAD_DIP_OFFSET
	for _, weld in welds do
		local hand = weld.Part0
		if hand then
			TweenService:Create(
				weld,
				TweenInfo.new(dipTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ C0 = hand.CFrame:Inverse() * dipWorldTarget }
			):Play()
		end
	end

	task.delay(dipTime, function()
		-- Re-fetch rather than trusting the earlier references — the
		-- weapon may have changed (unequipped, died, respawned) by now,
		-- which would mean these exact Weld instances no longer exist.
		local currentCharacter = player.Character
		local currentWelds = findGripWelds()
		if not currentCharacter then
			return
		end
		local returnWorldTarget = getDesiredWorldCFrame(currentCharacter)
		for _, weld in currentWelds do
			local hand = weld.Part0
			if hand then
				TweenService:Create(
					weld,
					TweenInfo.new(returnTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ C0 = hand.CFrame:Inverse() * returnWorldTarget }
				):Play()
			end
		end
	end)
end

--[[
	Actively cancels out whatever the hand is currently doing (including
	the run/walk animation's swing) and locks the weapon to a stable pose
	instead — the fix for "the gun shakes with the hand while running":
	a fixed offset relative to the hand's rest pose still rides along
	with every frame of the hand's own animated motion. This computes,
	every frame, exactly the weld.C0 needed to make Handle's WORLD pose
	equal the desired target regardless of where the hand itself
	currently is: given Handle.CFrame = Hand.CFrame * weld.C0, solving
	for weld.C0 with a known desired Handle.CFrame gives
	weld.C0 = Hand.CFrame:Inverse() * desiredWorldCFrame.

	Direct assignment (not a tween) — this needs to track the hand's
	current-frame position exactly to properly cancel it; a tween toward
	a constantly-moving target would only partially cancel with a lag,
	which would look like a *smaller* shake rather than none.
]]
local function updateStabilizedFollow()
	if os.clock() < reloadingUntilClock then
		return -- the reload tween currently owns the weld(s)
	end

	local character = player.Character
	if not character then
		return
	end

	local welds = findGripWelds()
	if #welds == 0 then
		if not hasLoggedNoGrips then
			hasLoggedNoGrips = true
			print("[WeaponView] updateStabilizedFollow: no RightGrip/LeftGrip weld found — skipping every frame.")
		end
		return
	end

	local desiredWorldCFrame = getDesiredWorldCFrame(character)

	local ok, err = pcall(function()
		for _, weld in welds do
			local hand = weld.Part0
			if hand then
				weld.C0 = hand.CFrame:Inverse() * desiredWorldCFrame
			end
		end
	end)

	if not ok then
		warn("[WeaponView] weld stabilized-follow errored: " .. tostring(err))
		return
	end

	-- DIAGNOSTIC (throttled to once every 3s): light-touch confirmation
	-- this is actually running and targeting real welds, kept in for
	-- now given how many rounds it took to find the right target.
	local now = os.clock()
	if now - lastDiagnosticPrintTime > 3 then
		lastDiagnosticPrintTime = now
		local pitchDegrees = math.deg(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)))
		local mode = (player.CameraMode == Enum.CameraMode.LockFirstPerson) and "1P" or "3P"
		print(("[WeaponView] pitch=%.1f deg | mode=%s | tracking %d grip weld(s)"):format(pitchDegrees, mode, #welds))
	end
end

function WeaponViewController.Init()
	RunService.RenderStepped:Connect(updateStabilizedFollow)
end

return WeaponViewController
