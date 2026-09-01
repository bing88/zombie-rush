--[[
	WeaponViewController.lua (ModuleScript)

	Purely cosmetic, local-only weapon-holding pose. Rebuilt around
	IKControl per "Roblox Weapons Kit — Stable Weapon Holding & Shooting
	Implementation Guide.md", replacing the previous approach (directly
	overwriting the equip-time RightGrip/LeftGrip Weld's C0 every frame
	to cancel out the hand's own animated motion), which worked but
	fought Roblox's animation system by design — exactly the guide's
	Rule 1 anti-pattern ("do not manually CFrame the player's hands
	every frame"), just applied to the grip weld instead of the hand
	itself.

	IMPORTANT — this is NOT a repeat of the "IKControl ... zero visible
	effect" attempt this file's git history already tried once. That
	earlier attempt fed a computed pose back into Tool.Grip, which
	Roblox only reads ONCE at equip time to build a frozen Weld — no
	technique writing to Grip afterward can work, IKControl included
	(see WeaponIK.lua's header for the full explanation). This module
	never touches Tool.Grip or that Weld. Instead:

	  - RIGHT hand: an IKControl (Type=Position — see WeaponIK.lua's
	    header for the full back-and-forth on why this file landed
	    here rather than Transform) bends the character's own arm
	    (ChainRoot=RightUpperArm, EndEffector=RightHand) toward a small
	    invisible "WeaponAimTarget" Attachment that THIS script
	    repositions every frame to a point roughly in front of the
	    torso. Since the weapon's equip weld is still rigidly attached
    30|	    to RightHand, the gun follows the now-repositioned hand
	    automatically — no separate weapon positioning needed.

	    This file briefly switched to Type=Transform (full position +
	    rotation control) once WeaponModelFactory's
	    HANDLE_ATTACHMENT_ROTATION_CORRECTION made Tool.Grip's own
	    rotation a verified no-op, on the theory that the earlier
	    Transform attempt's upside-down/shake symptoms were caused by
	    that Grip bug rather than Transform mode itself. Live testing
	    disproved that theory: the commanded rotation and the actual
	    RightHand rotation diverged by tens of degrees every tick, and
	    walking/running shook visibly, same as before. The real cause
	    turned out to be structural, not a Grip math bug at all —
	    Roblox's chain from RightUpperArm to RightHand spans THREE
	    rotational joints (shoulder, elbow, wrist), each a full 3-DoF
	    Motor6D: 9 rotational degrees of freedom trying to satisfy a
	    single 3-DoF position target (Position mode) or a 6-DoF pose
	    target (Transform mode) — wildly underdetermined either way.
	    Roblox's own developers confirm (DevForum "IKControl Pole
	    Property not working properly", "IKControl unexpected behavior
	    issues") that reliably controlling this needs actual physics
	    constraints (HingeConstraint/BallSocketConstraint) added to the
	    rig's joints in Studio — a Pole alone, let alone no Pole at
	    all, is "often insufficient" per their own reports, and Studio
	    constraint placement is a GUI workflow this file can't do from
	    code. So: back to Position mode, which is at least verified
	    stable and reaches the intended chest-height spot with zero
	    shake — the tradeoff is the barrel's exact tilt is left to
	    whatever elbow/wrist solution Roblox's solver happens to pick,
	    which won't always point precisely at the camera's aim
	    direction. Precisely fixing that for real would need Studio-
	    side constraint work or a properly authored aim animation, both
	    outside what this script-only approach can achieve.

	  - LEFT hand (support hand): a second IKControl (also
	    Type=Position, same reasoning) bends the other arm toward the
	    weapon's own "LeftGrip" Attachment's position (see
	    WeaponModelFactory) — no per-frame script work at all, Roblox's
	    IK solver just continuously re-reads that attachment's live
	    position since it's a reference to a moving Instance, not a
	    CFrame snapshot. This is new: no weapon in this game previously
	    had ANY left-hand interaction (Roblox's automatic Tool-equip
	    weld only ever creates a RightGrip Weld; a LeftGrip Weld
	    would've needed the Weapons Kit's own scripts, which are
	    stripped) — the left arm was previously just doing whatever the
	    default idle/walk animation did, disconnected from the gun.

	Supports both R15 (two-segment arms, full elbow bend) and R6
	(single rigid arm, shoulder-only rotation) rigs — see
	resolveArmParts. If neither rig shape is found (or IKControl simply
	isn't supported), this silently no-ops: the Tool still equips fine
	via Roblox's own default weld, just without these enhancements.

	Custom RifleHold/RifleWalk/RifleSprint Animation-Editor-authored
	poses from the guide's sections 8-10 are intentionally NOT built
	here — creating those requires posing a rig in Roblox Studio's
	Animation Editor (a GUI workflow, not something scriptable from
	here). This game also has no player sprint mechanic to distinguish
	anyway. What IS implemented is the guide's actual core mechanism
	(sections 11-14, 20, 29) — stable IK-driven holding — adapted to
	this game's existing "weapon always tracks the camera" design
	instead of the guide's generic walk/sprint pose-swapping, since
	that's what this game actually needs visually.

	LOCAL ONLY regardless: changes made client-side aren't visible to
	other players watching you — same limitation as everything else
	client-side in this codebase; a shared version needs either a real
	authored Animation asset or a server-synced system.

	FIRST-PERSON VIEWMODEL: everything above (IK reach or hold
	Animation) poses the real, character-attached RightHand/Handle —
	fine for third person, but it only tracks camera YAW (see
	getStabilizedCameraRotation's includePitch and faceCamera in
	CameraController), never pitch, and is still ultimately anchored to
	a body bone rather than the camera itself. In first person that
	reads as the gun visibly sliding around on screen as the camera
	pitches, instead of the classic FPS "glued to the camera" viewmodel
	feel. buildFirstPersonViewmodel/updateFirstPersonViewmodel/
	applyFirstPersonViewmodelState solve that with a SEPARATE, purely
	decorative clone of the equipped Tool that's re-planted at a fixed
	camera-relative spot every frame (see FIRST_PERSON_VIEWMODEL_OFFSET)
	while player.CameraMode == LockFirstPerson, with the real Tool
	hidden (LocalTransparencyModifier, so only this client stops seeing
	it) for the duration so the two don't visually double up. No
	physics/IK/Animation involved in that clone at all, so it can't
	jitter or lag behind camera movement the way the real bone-attached
	Tool does.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponIK = require(ReplicatedStorage.Shared.WeaponIK)
local CFrameDebug = require(ReplicatedStorage.Shared.CFrameDebug)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local WeaponViewController = {}

-- Flip to false once the weapon-holding pose is confirmed correct and
-- these prints are no longer needed. Client-side only (each player only
-- sees their own Output for this).
local DEBUG_LOGGING = true
local DEBUG_TICK_INTERVAL = 1.5
local lastDebugTickClock = 0

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local RELOAD_DIP_OFFSET = CFrame.new(0, -0.6, 0.3) * CFrame.Angles(math.rad(35), 0, 0)

-- Clamps how far the hand TARGET's position shifts vertically with
-- camera pitch (Position-type IK never rotates the barrel itself —
-- see WeaponIK.lua's header — so this only nudges where the hand
-- reaches for, not the gun's actual tilt).
local MAX_PITCH_DEGREES = 35

--[[
	Local offsets (right, up, forward) applied on top of whichever base
	position getGunBasePosition picks for the current camera mode.
	Still aesthetic placement guesses, not verified in Studio — retune
	these two constants if the gun sits at an awkward distance/angle.

	THIRD_PERSON was previously (0.3, -0.3, -0.5) — small enough that,
	combined with the third-person target also dipping with camera
	pitch (see getDesiredHandCFrame below), it landed close enough to
	where a naturally-hanging arm already rests that the Position-type
	IK barely had to move the hand at all: screenshots showed the gun
	sitting down by the hip with the arm still looking like a plain
	idle pose, not "held up." Pushed further right/forward and flipped
	to a slight UP offset (torso-center is roughly solar-plexus height
	on the default R15 rig, noticeably above where a hanging hand
	rests) so reaching this target requires a clearly visible raise,
	regardless of the exact camera angle.
]]
local GUN_OFFSET_FIRST_PERSON = CFrame.new(0.5, -0.5, -0.8)
local GUN_OFFSET_THIRD_PERSON = CFrame.new(0.55, 0.15, -1.1)

--[[
	Bottom-right "viewmodel" placement for the camera-glued first-person
	clone (see buildFirstPersonViewmodel below) — deliberately a PURE
	translation, zero extra rotation, so the gun's own -Z ("barrel
	forward", per Tool/Muzzle convention — see WeaponModelFactory) ends
	up pointing exactly parallel to camera.LookVector, i.e. wherever the
	crosshair (screen-center, always == camera.LookVector) is currently
	pointing, no matter how the camera pitches/yaws.

	Y is pushed low enough that the weapon's own top rail/sights sit
	clearly BELOW screen-center — the crosshair must read as floating
	in front of/above the gun (like most reference shooters), never
	overlapping or merging with its silhouette. Only X/Y are read here;
	Z (depth) is recomputed per-weapon in buildFirstPersonViewmodel
	below since it has to scale with each weapon's own length.
]]
local FIRST_PERSON_VIEWMODEL_OFFSET = CFrame.new(0.28, -0.85, -0.4)

-- Pitch-follow backs off until this os.clock() timestamp passes, so it
-- doesn't fight the reload dip/return tween below for control of the
-- aim target attachment.
local reloadingUntilClock = 0

local currentCharacter: Model? = nil
local currentTool: Tool? = nil
local aimTargetAttachment: Attachment? = nil
local rightHandIK: IKControl? = nil
local leftHandIK: IKControl? = nil
local currentArmParts: any = nil -- ArmParts, declared below resolveArmParts; kept for debug tick logging only

-- Set only when the equipped weapon has a WeaponConfig.HoldAnimationId
-- — see createIKForTool and playHoldAnimation. nil means "this weapon
-- is using the live right-hand Position-IK reach instead" (rightHandIK
-- will be set in that case, mutually exclusive with this).
local holdAnimationTrack: AnimationTrack? = nil

-- One-shot flourishes layered on top of whichever hold pose is active
-- (live IK or holdAnimationTrack above) — see loadAuxiliaryAnimations,
-- PlayFireAnimation, PlayReloadAnimation, and createIKForTool's equip
-- trigger. Each is independently nil'able (WeaponConfig fields are
-- optional per weapon) and reloaded fresh on every tool equip.
local fireAnimationTrack: AnimationTrack? = nil
local equipAnimationTrack: AnimationTrack? = nil
local reloadAnimationTrack: AnimationTrack? = nil

local hasWarnedNoIKRig = false

-- First-person "viewmodel" clone state — see buildFirstPersonViewmodel/
-- updateFirstPersonViewmodel/applyFirstPersonViewmodelState below. All
-- nil/empty/false whenever third-person (or no tool) is active.
local firstPersonViewmodelTool: Tool? = nil
local firstPersonViewmodelHandle: BasePart? = nil
local firstPersonViewmodelOffsets: { [BasePart]: CFrame } = {}
local firstPersonViewmodelCameraOffset: CFrame = FIRST_PERSON_VIEWMODEL_OFFSET -- recomputed per-weapon, see buildFirstPersonViewmodel
local isShowingFirstPersonViewmodel = false
local hiddenRealWeaponTool: Tool? = nil -- the real Tool currently hidden (LocalTransparencyModifier) while its viewmodel clone is shown instead
local lastKnownCameraMode: Enum.CameraMode? = nil

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
	character's own torso — NOT the camera, which sits far behind the
	character in this mode; using the camera's position there was the
	original bug behind the weapon appearing gigantic and floating at
	the lens.
]]
local function getGunBasePosition(character: Model): Vector3
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return camera.CFrame.Position
	end
	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	return torso and torso.Position or camera.CFrame.Position
end

--[[
	Camera ROTATION ONLY (pitch clamped, yaw preserved, roll dropped) —
	same decomposition approach used elsewhere in this project for
	camera-relative aiming math. Position is handled separately by
	getGunBasePosition above, since the appropriate position source
	differs by camera mode while the desired orientation doesn't.

	includePitch=false collapses pitch to 0 (yaw-only) — used for
	third person (see getDesiredHandCFrame): letting third-person's
	held-position TARGET dip/rise with full camera pitch meant looking
	down at zombies (a downward-pitched camera, common for this game's
	elevated third-person view) dragged the whole reach target down
	toward hip height, on top of the offset-magnitude issue described
	on GUN_OFFSET_THIRD_PERSON above — compounding into the "arm never
	visibly raises" symptom. Yaw still applies so the held position
	still turns with the character/camera left-right, just no longer
	slides up/down with it. First-person keeps full pitch (see below)
	since it behaves like a viewmodel glued to the camera itself.
]]
local function getStabilizedCameraRotation(includePitch: boolean): CFrame
	local lookVector = camera.CFrame.LookVector

	local horizontal = Vector3.new(lookVector.X, 0, lookVector.Z)
	local horizontalLength = horizontal.Magnitude
	if horizontalLength < 0.0001 then
		horizontal = Vector3.new(0, 0, -1)
		horizontalLength = 1
	end
	horizontal = horizontal / horizontalLength

	local yaw = math.atan2(-horizontal.X, -horizontal.Z)

	if not includePitch then
		return CFrame.Angles(0, yaw, 0)
	end

	local rawPitch = math.atan2(lookVector.Y, horizontalLength)
	local clampedPitch = math.clamp(rawPitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(clampedPitch, 0, 0)
end

--[[
	Combines base position + rotation + local offset for the given
	character. The rotation component only exists to correctly place
	the offset in world space (e.g. so GUN_OFFSET's "forward" nudges
	toward wherever the camera is actually looking) — callers should
	read only .Position off the result and feed that to the
	Position-type right-hand IKControl. See the file header and
	WeaponIK.lua for why the hand's rotation itself is deliberately
	left alone rather than forced to match this (Transform mode was
	tried and reverted — Roblox's own arm chain is too underdetermined
	for it to converge reliably without Studio-side physics
	constraints).
]]
local function getDesiredHandCFrame(character: Model): CFrame
	local basePosition = getGunBasePosition(character)
	local isFirstPerson = player.CameraMode == Enum.CameraMode.LockFirstPerson
	local rotation = getStabilizedCameraRotation(isFirstPerson)
	return CFrame.new(basePosition) * rotation * getGunOffset()
end

--[[
	Resolves the character's own arm parts for IK, supporting both R15
	(two-segment arm: upper arm -> hand, full elbow bend) and R6
	(single rigid arm part, shoulder-rotation only). Returns nil if
	neither shape is present (unusual/custom rig, or character not
	fully loaded yet) — callers treat that as "IK unsupported, skip it".
]]
type ArmParts = {
	rightChainRoot: BasePart,
	rightEndEffector: BasePart,
	leftChainRoot: BasePart?,
	leftEndEffector: BasePart?,
	torso: BasePart,
}
local function resolveArmParts(character: Model, humanoid: Humanoid): ArmParts?
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		local rightUpperArm = character:FindFirstChild("RightUpperArm") :: BasePart?
		local rightHand = character:FindFirstChild("RightHand") :: BasePart?
		local torso = character:FindFirstChild("UpperTorso") :: BasePart?
		if rightUpperArm and rightHand and torso then
			return {
				rightChainRoot = rightUpperArm,
				rightEndEffector = rightHand,
				leftChainRoot = character:FindFirstChild("LeftUpperArm") :: BasePart?,
				leftEndEffector = character:FindFirstChild("LeftHand") :: BasePart?,
				torso = torso,
			}
		end
	else
		local torso = character:FindFirstChild("Torso") :: BasePart?
		local rightArm = character:FindFirstChild("Right Arm") :: BasePart?
		if torso and rightArm then
			return {
				rightChainRoot = torso,
				rightEndEffector = rightArm,
				leftChainRoot = torso,
				leftEndEffector = character:FindFirstChild("Left Arm") :: BasePart?,
				torso = torso,
			}
		end
	end
	return nil
end

--[[
	Plays the real weapon's own "Reload" Sound if it has one (silently
	does nothing otherwise — not every asset ships one). Resets
	TimePosition first so re-reloading the same weapon in quick
	succession (e.g. after the reload watchdog force-clears a stuck
	one) always restarts the clip instead of Play() no-oping.
]]
local function playReloadSound(tool: Tool)
	local sound = tool:FindFirstChild("Reload", true)
	if sound and sound:IsA("Sound") then
		sound.TimePosition = 0
		sound:Play()
	end
end

--[[
	LocalTransparencyModifier is a per-client rendering override — it
	only affects what THIS client sees, exactly like everything else in
	this LOCAL ONLY file (see the header) — so hiding your own real gun
	here to avoid it visually doubling up with the viewmodel clone below
	doesn't hide it from other players watching you.
]]
local function setRealWeaponVisible(tool: Tool, visible: boolean)
	local transparency = visible and 0 or 1
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			(descendant :: BasePart).LocalTransparencyModifier = transparency
		end
	end
end

--[[
	Tears down the camera-glued viewmodel clone (if any) and restores
	whichever real Tool it was standing in for back to normal
	visibility. Safe to call even when no viewmodel is currently active
	(e.g. already in third person) — every field it touches is nil'd
	out afterward so a repeat call is a clean no-op.
]]
local function destroyFirstPersonViewmodel()
	if firstPersonViewmodelTool then
		firstPersonViewmodelTool:Destroy()
	end
	firstPersonViewmodelTool = nil
	firstPersonViewmodelHandle = nil
	table.clear(firstPersonViewmodelOffsets)
	firstPersonViewmodelCameraOffset = FIRST_PERSON_VIEWMODEL_OFFSET
	isShowingFirstPersonViewmodel = false

	if hiddenRealWeaponTool then
		setRealWeaponVisible(hiddenRealWeaponTool, true)
		hiddenRealWeaponTool = nil
	end
end

--[[
	Determines which of Handle's own local axes is actually "barrel
	forward" for THIS weapon's mesh, from its real Muzzle Attachment
	(always present — see WeaponModelFactory's ensureMuzzleAttachment)
	rather than assuming the generic Tool convention ("-Z is forward")
	documented elsewhere in this codebase. That convention holds for
	the placeholder block Tool, but logged data from the real Weapons
	Kit assets (Pistol/AssaultRifle/Shotgun) shows their own Muzzle
	sitting at a POSITIVE local Z instead (e.g. the AssaultRifle's at
	Z=2.46) — i.e. +Z is forward for those meshes, the exact opposite.
	Getting this backwards visually reads as the barrel pointing back
	toward the camera instead of away from it.

	Every logged local rotation for these assets (HandleAttachment,
	Muzzle) already has Up=(0,1,0) — Handle's own +Y already IS "up",
	no tilt/roll correction needed — so a plain 180° yaw is the whole
	fix whenever Muzzle's local Z sign says +Z is forward instead of -Z.
]]
local function detectNativeForwardCorrection(handle: BasePart): CFrame
	local muzzle = handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") and muzzle.Position.Z > 0 then
		return CFrame.Angles(0, math.rad(180), 0)
	end
	return CFrame.new()
end

--[[
	Builds the camera-glued first-person viewmodel: a full clone of the
	equipped Tool (every BasePart it has, not just Handle — some real
	assets weld extra visual parts alongside Handle rather than nested
	under it, see WeaponModelFactory's ensureHandle), anchored and
	freed of collision, with every part's offset relative to its own
	Handle captured ONCE here. updateFirstPersonViewmodel then just
	re-plants the clone's Handle at a fixed camera-relative spot every
	frame and replays those captured offsets onto the rest — no
	physics/welds/IK/Animation involved at all, so it can never jitter,
	sway with the walk cycle, or drift out of formation with camera
	pitch the way the real, character-attached Tool does (see the file
	header — that's the exact problem this whole system exists to route
	around for first person specifically).
]]
local function buildFirstPersonViewmodel(tool: Tool)
	destroyFirstPersonViewmodel()

	local sourceHandle = tool:FindFirstChild("Handle")
	if not sourceHandle or not sourceHandle:IsA("BasePart") then
		return
	end

	local clone = tool:Clone()
	clone.Name = "FirstPersonViewmodel"

	local handleClone = clone:FindFirstChild("Handle") :: BasePart?
	if not handleClone then
		clone:Destroy()
		return
	end

	local offsets: { [BasePart]: CFrame } = {}
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
			offsets[descendant] = handleClone.CFrame:ToObjectSpace(descendant.CFrame)
		end
	end

	-- Longer weapons (e.g. the 3-stud-long AssaultRifle Handle, vs the
	-- 1-stud Pistol) need to sit further from the camera, or their far
	-- end ends up practically AT/behind the camera's near plane —
	-- that alone produces a huge, severely distorted, screen-spanning
	-- mess that's easy to mistake for a rotation bug even when the
	-- rotation is fine. FIRST_PERSON_VIEWMODEL_OFFSET's X/Y (lateral
	-- placement) stay fixed; only Z (depth) scales with this weapon's
	-- actual length.
	local lateral = FIRST_PERSON_VIEWMODEL_OFFSET.Position
	local depth = -(0.55 + handleClone.Size.Z * 0.35)
	firstPersonViewmodelCameraOffset = CFrame.new(lateral.X, lateral.Y, depth) * detectNativeForwardCorrection(handleClone)

	clone.Parent = camera
	firstPersonViewmodelTool = clone
	firstPersonViewmodelHandle = handleClone
	firstPersonViewmodelOffsets = offsets
	isShowingFirstPersonViewmodel = true
end

--[[
	Called right after createIKForTool sets up the just-equipped tool's
	hold pose, AND every time syncFirstPersonViewmodel notices the
	camera mode itself changed (V key / VIEW button — owned by
	CameraController, which this file has no direct event hook into,
	hence polling once per frame there instead of subscribing) — keeps
	the viewmodel/real-Tool visibility split in sync with whichever
	mode is actually active right now.
]]
local function applyFirstPersonViewmodelState(tool: Tool)
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		buildFirstPersonViewmodel(tool)
		setRealWeaponVisible(tool, false)
		hiddenRealWeaponTool = tool
	else
		destroyFirstPersonViewmodel()
	end
end

local function syncFirstPersonViewmodel()
	local tool = currentTool
	if not tool or player.CameraMode == lastKnownCameraMode then
		return
	end
	lastKnownCameraMode = player.CameraMode
	applyFirstPersonViewmodelState(tool)
end

--[[
	Every frame while showing the viewmodel: plants Handle at a fixed
	camera-relative spot (see firstPersonViewmodelCameraOffset — a
	per-weapon combination of FIRST_PERSON_VIEWMODEL_OFFSET's lateral
	placement, a length-aware depth, and the detected native-forward
	correction, computed once in buildFirstPersonViewmodel) and replays
	every other part's captured local offset on top of that, so the
	whole gun moves as one rigid unit glued to the camera, immune to
	camera pitch and to whatever the real arm/RightHand is actually
	doing underneath.
]]
local function updateFirstPersonViewmodel()
	if not isShowingFirstPersonViewmodel or not firstPersonViewmodelHandle then
		return
	end

	local handleCFrame = camera.CFrame * firstPersonViewmodelCameraOffset
	firstPersonViewmodelHandle.CFrame = handleCFrame

	for part, offset in firstPersonViewmodelOffsets do
		if part ~= firstPersonViewmodelHandle and part.Parent then
			part.CFrame = handleCFrame * offset
		end
	end
end

local function destroyIK()
	WeaponIK.Destroy(rightHandIK)
	WeaponIK.Destroy(leftHandIK)
	rightHandIK = nil
	leftHandIK = nil
	currentArmParts = nil
	destroyFirstPersonViewmodel()
	lastKnownCameraMode = nil
	if aimTargetAttachment then
		aimTargetAttachment:Destroy()
		aimTargetAttachment = nil
	end
	if holdAnimationTrack then
		holdAnimationTrack:Stop(0.1)
		holdAnimationTrack:Destroy()
		holdAnimationTrack = nil
	end
	if fireAnimationTrack then
		fireAnimationTrack:Stop(0)
		fireAnimationTrack:Destroy()
		fireAnimationTrack = nil
	end
	if equipAnimationTrack then
		equipAnimationTrack:Stop(0)
		equipAnimationTrack:Destroy()
		equipAnimationTrack = nil
	end
	if reloadAnimationTrack then
		reloadAnimationTrack:Stop(0)
		reloadAnimationTrack:Destroy()
		reloadAnimationTrack = nil
	end
	reloadingUntilClock = 0
end

--[[
	Shared LoadAnimation plumbing for all four optional WeaponConfig
	animation ids. Returns nil (after warning) if animationId is empty
	or fails to load — every call site below treats nil as "skip this
	flourish, no effect on the others".
]]
local function loadAnimationTrack(humanoid: Humanoid, animationId: string): AnimationTrack?
	if animationId == "" then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		warn(("[WeaponView] failed to load animation %s (%s)"):format(animationId, tostring(track)))
		return nil
	end
	return track
end

--[[
	Loads+plays a looped, Action-priority Animation covering the
	authored "holding this weapon" pose (see WeaponConfig.HoldAnimationId
	and the file header). Action priority sits above the default
	Movement-priority walk/run animation, so for whichever joints this
	animation actually keyframes (intended: just the right arm — see
	the Studio authoring notes in WeaponConfig.lua), it fully overrides
	the walk cycle's arm swing with zero live IK solving involved, and
	therefore zero shake. Any joints NOT keyframed (left arm, legs,
	torso) keep animating from the base walk/idle animation as normal.
]]
local function playHoldAnimation(humanoid: Humanoid, animationId: string)
	local track = loadAnimationTrack(humanoid, animationId)
	if not track then
		return
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15)
	holdAnimationTrack = track
end

--[[
	Loads (but does not play) the three one-shot flourish animations —
	see WeaponConfig's Fire/Equip/ReloadAnimationId. Called once per
	tool equip regardless of whether HoldAnimationId is set, since
	these layer on top of either the live IK reach or the hold
	Animation equally. Explicitly forces Looped=false: these are meant
	to play once and hand control back to whatever's underneath, and
	trusting each clip's own authored Loop flag (which may have been
	left true from whatever it was originally saved as in Studio) would
	risk a "fire"/"reload" animation looping forever instead.
]]
local function loadAuxiliaryAnimations(humanoid: Humanoid, weaponStats: WeaponConfig.WeaponStats?)
	if not weaponStats then
		return
	end

	local fireTrack = loadAnimationTrack(humanoid, weaponStats.FireAnimationId or "")
	if fireTrack then
		fireTrack.Priority = Enum.AnimationPriority.Action
		fireTrack.Looped = false
		fireAnimationTrack = fireTrack
	end

	local equipTrack = loadAnimationTrack(humanoid, weaponStats.EquipAnimationId or "")
	if equipTrack then
		equipTrack.Priority = Enum.AnimationPriority.Action
		equipTrack.Looped = false
		equipAnimationTrack = equipTrack
	end

	local reloadTrack = loadAnimationTrack(humanoid, weaponStats.ReloadAnimationId or "")
	if reloadTrack then
		reloadTrack.Priority = Enum.AnimationPriority.Action
		reloadTrack.Looped = false
		reloadAnimationTrack = reloadTrack
	end
end

--[[
	One-shot dump printed right when a tool's IK is set up — this is the
	first thing to check in the Output when the weapon looks wrong,
	since it shows the raw rig geometry BEFORE any per-frame IK/aim
	logic runs at all. If e.g. RightUpperArm/RightHand's yaw already
	looks unexpected here (not roughly matching Torso's yaw), the issue
	is in the character's own rig/animation, not this script's math.
]]
local function debugDumpOnEquip(character: Model, humanoid: Humanoid, tool: Tool, parts: ArmParts)
	if not DEBUG_LOGGING then
		return
	end
	print(("[WeaponDebug][Client] ===== Equipped %s (RigType=%s) ====="):format(tool.Name, humanoid.RigType.Name))
	print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Torso", parts.torso.CFrame))
	print("[WeaponDebug][Client] " .. CFrameDebug.Describe("RightChainRoot", parts.rightChainRoot.CFrame))
	print("[WeaponDebug][Client] " .. CFrameDebug.Describe("RightHand", parts.rightEndEffector.CFrame))
	if parts.leftEndEffector then
		print("[WeaponDebug][Client] " .. CFrameDebug.Describe("LeftHand", parts.leftEndEffector.CFrame))
	end
	print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Camera", camera.CFrame))

	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Handle(world)", handle.CFrame))
		print("[WeaponDebug][Client] Tool.Grip(local, RightHand->Handle) " .. CFrameDebug.Vector(tool.Grip.Position) .. (" yaw=%.1f"):format(CFrameDebug.YawDegrees(tool.Grip)))
		local muzzle = handle:FindFirstChild("Muzzle")
		if muzzle and muzzle:IsA("Attachment") then
			print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Muzzle(world)", muzzle.WorldCFrame))
		end
	end

	local torsoYaw = CFrameDebug.YawDegrees(parts.torso.CFrame)
	local cameraYaw = CFrameDebug.YawDegrees(camera.CFrame)
	print(("[WeaponDebug][Client] Torso yaw=%.1f camera yaw=%.1f diff=%.1f (diff should be ~0, since faceCamera keeps the body pointed at the camera)"):format(torsoYaw, cameraYaw, torsoYaw - cameraYaw))
end

--[[
	Sets up both IKControls for the just-equipped tool. Safe to call
	repeatedly (always tears down any previous IK first) — every weapon
	switch runs through here via Tool.Equipped.
]]
local function createIKForTool(character: Model, tool: Tool)
	destroyIK()

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local parts = resolveArmParts(character, humanoid)
	if not parts then
		if not hasWarnedNoIKRig then
			hasWarnedNoIKRig = true
			warn("[WeaponView] no recognizable R15/R6 arm parts found — weapon will use Roblox's default equip pose with no aim-follow/support-hand IK.")
		end
		return
	end
	currentArmParts = parts

	debugDumpOnEquip(character, humanoid, tool, parts)

	-- An authored Animation (if this weapon has one configured — see
	-- WeaponConfig.HoldAnimationId) takes priority over BOTH hands'
	-- live IK reach: it's stable/shake-free and its pose is exactly
	-- whatever was posed in Studio, rather than whatever Roblox's
	-- underdetermined arm solver happens to land on (see the file
	-- header and WeaponIK.lua for the full history of why IK alone
	-- couldn't reliably control that). This has to be all-or-nothing
	-- between the two hands, not just the right: leaving the left/
	-- support-hand IK live while the right hand holds a fixed
	-- animated pose still shakes while walking/running, because the
	-- whole gun (and therefore the live IK's LeftGrip target) keeps
	-- moving with the walk cycle's body bob, and Position-mode IK's
	-- unconstrained wrist twist can flip rapidly chasing a target
	-- that's constantly on the move — same underlying "too many
	-- redundant rotational degrees of freedom" issue as before, just
	-- on the other arm. So: author BOTH arms into the same Animation
	-- (posing the support hand near the weapon's own LeftGrip
	-- attachment by eye, using the equipped Tool as a visual
	-- reference in Studio) for a fully static, zero-live-IK held pose.
	local weaponStats = WeaponConfig[tool.Name]

	-- Fire/Equip/Reload flourishes load independently of which hold
	-- mechanism (below) is active — they're layered on top of either
	-- one, not an alternative to it.
	loadAuxiliaryAnimations(humanoid, weaponStats)

	local holdAnimationId = weaponStats and weaponStats.HoldAnimationId or ""
	if holdAnimationId ~= "" then
		playHoldAnimation(humanoid, holdAnimationId)
	else
		local attachment = Instance.new("Attachment")
		attachment.Name = "WeaponAimTarget"
		attachment.Parent = parts.torso
		aimTargetAttachment = attachment

		rightHandIK = WeaponIK.Create(humanoid, parts.rightChainRoot, parts.rightEndEffector, attachment, "WeaponRightHandIK")

		-- Two-handed only if this weapon actually has a LeftGrip (see
		-- WeaponModelFactory) and the rig has a left arm to bend.
		local handle = tool:FindFirstChild("Handle")
		local leftGrip = handle and handle:FindFirstChild("LeftGrip")
		if parts.leftChainRoot and parts.leftEndEffector and leftGrip and leftGrip:IsA("Attachment") then
			leftHandIK = WeaponIK.Create(humanoid, parts.leftChainRoot, parts.leftEndEffector, leftGrip, "WeaponLeftHandIK")
		end
	end

	-- Equip flourish: plays once immediately, blended over whichever
	-- hold mechanism was just set up above (the still-looping hold
	-- Animation, if any, keeps its weight and just becomes visually
	-- overridden by this higher-recency Action-priority track until it
	-- ends, at which point Roblox fades back to the hold track alone —
	-- no extra bookkeeping needed here).
	if equipAnimationTrack then
		equipAnimationTrack.TimePosition = 0
		equipAnimationTrack:Play(0.1)
	end

	-- Covers "already in first person when this tool was equipped"
	-- (weapon switch, initial spawn) — syncFirstPersonViewmodel's own
	-- per-frame poll only catches the camera MODE changing, not a new
	-- tool arriving while the mode stays the same.
	lastKnownCameraMode = player.CameraMode
	applyFirstPersonViewmodelState(tool)
end

local function onToolEquipped(tool: Tool)
	local character = tool.Parent
	if not character or not character:IsA("Model") then
		return
	end
	currentCharacter = character
	currentTool = tool
	createIKForTool(character, tool)
end

local function onToolUnequipped()
	destroyIK()
	currentTool = nil
end

-- Guards against connecting the same Tool's Equipped/Unequipped more
-- than once. Without this, a Tool got tracked again every time it
-- moved Backpack -> Character (watchContainer is called on both, and
-- a Tool triggers ChildAdded on whichever one it's currently entering)
-- — connections accumulated for the lifetime of the Tool instance, so
-- by the Nth weapon switch in a session, a single equip could re-run
-- createIKForTool (and therefore playHoldAnimation/LoadAnimation) N
-- times back to back, visible in debug logging as the same "=====
-- Equipped ... =====" dump printed several times for one actual equip.
local trackedTools: { [Tool]: boolean } = {}

local function trackTool(tool: Instance)
	if not tool:IsA("Tool") then
		return
	end
	if trackedTools[tool] then
		return
	end
	trackedTools[tool] = true
	tool.Equipped:Connect(function()
		onToolEquipped(tool)
	end)
	tool.Unequipped:Connect(onToolUnequipped)
	tool.Destroying:Connect(function()
		trackedTools[tool] = nil
	end)
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		trackTool(child)
	end
	container.ChildAdded:Connect(trackTool)
end

--[[
	One-shot recoil-kick flourish, called from WeaponController on every
	local shot (see ClientMain's OnLocalFire wiring) — a no-op if this
	weapon has no WeaponConfig.FireAnimationId. Restarts from
	TimePosition 0 before every Play() rather than relying on Play()
	alone to restart an already-playing track, so rapid-fire weapons
	(e.g. the assault rifle) get a crisp kick each shot instead of the
	clip only fully playing out for the first shot of a burst.
]]
function WeaponViewController.PlayFireAnimation()
	local track = fireAnimationTrack
	if not track then
		return
	end
	track.TimePosition = 0
	track:Play(0.05)
end

--[[
	Reload dip/return + left-hand release: always plays the reload
	sound and releases the left-hand IK for the duration (guide section
	26 — "left hand releases grip -> reload animation -> left hand
	returns -> IK enabled") since the off hand should visually leave
	the weapon to work the mag/charging handle regardless of how the
	right hand is currently posed.

	If this weapon has an authored WeaponConfig.ReloadAnimationId, that
	takes over entirely: played once, speed-adjusted via AdjustSpeed so
	its total playback time exactly matches the server's real
	durationSeconds (whatever its native authored length is), then the
	left-hand IK re-enables when that's done. Otherwise falls back to
	the original dip/return position TWEEN, which only actually applies
	when aimTargetAttachment exists — i.e. this weapon is using the
	live IK reach, not an authored hold Animation (see
	WeaponConfig.HoldAnimationId) — there's nothing to tween for an
	animated weapon since nothing reads that attachment's position for it.
]]
function WeaponViewController.PlayReloadAnimation(durationSeconds: number)
	local character = currentCharacter
	local tool = currentTool
	if not character or not tool then
		return
	end

	playReloadSound(tool)
	WeaponIK.Disable(leftHandIK)

	local reloadTrack = reloadAnimationTrack
	if reloadTrack then
		reloadTrack.TimePosition = 0
		reloadTrack:Play(0.1)
		if reloadTrack.Length > 0 then
			reloadTrack:AdjustSpeed(reloadTrack.Length / durationSeconds)
		end
		task.delay(durationSeconds, function()
			if currentTool == tool then
				WeaponIK.Enable(leftHandIK)
			end
		end)
		return
	end

	local dipTime = math.clamp(durationSeconds * 0.35, 0.1, 0.6)
	local returnTime = math.max(durationSeconds - dipTime, 0.15)

	local attachment = aimTargetAttachment
	if not attachment then
		task.delay(dipTime + returnTime, function()
			if currentTool == tool then
				WeaponIK.Enable(leftHandIK)
			end
		end)
		return
	end

	-- The right-hand aim-follow loop below stands aside for the whole
	-- dip+return so it doesn't fight these tweens for the same attachment.
	reloadingUntilClock = os.clock() + dipTime + returnTime + 0.1

	-- Only Position (a local, always-tweenable Vector3 property) is
	-- animated — never CFrame/WorldCFrame — since the IKControls here
	-- are Position-type and only ever read this attachment's position;
	-- giving it a rotation would be dead weight at best.
	local parent = attachment.Parent :: BasePart
	local dipHandTarget = (getDesiredHandCFrame(character) * RELOAD_DIP_OFFSET).Position

	TweenService:Create(
		attachment,
		TweenInfo.new(dipTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = parent.CFrame:PointToObjectSpace(dipHandTarget) }
	):Play()

	task.delay(dipTime, function()
		-- Re-fetch rather than trusting the earlier references — the
		-- weapon may have changed (switched, unequipped, died,
		-- respawned) by now.
		local stillAttachment = aimTargetAttachment
		local stillCharacter = currentCharacter
		if stillAttachment ~= attachment or not stillCharacter then
			return -- a different tool/attachment is active now; leave it alone
		end

		local stillParent = attachment.Parent :: BasePart?
		if not stillParent then
			return
		end

		local returnHandTarget = getDesiredHandCFrame(stillCharacter).Position

		TweenService:Create(
			attachment,
			TweenInfo.new(returnTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = stillParent.CFrame:PointToObjectSpace(returnHandTarget) }
		):Play()

		task.delay(returnTime, function()
			if aimTargetAttachment == attachment then
				WeaponIK.Enable(leftHandIK)
			end
		end)
	end)
end

--[[
	Every frame, moves the (invisible, script-owned) aim target
	attachment to the position the right hand should reach for — see
	getDesiredHandCFrame (only .Position is used; the right-hand
	IKControl is Position-type, see WeaponIK.lua's header for why
	rotation is deliberately not forced onto the hand). Roblox's
	engine handles blending this reach with the base walk/idle
	animation.
]]
local function updateAimFollow()
	if os.clock() < reloadingUntilClock then
		return -- the reload tween currently owns the attachment
	end

	local character = currentCharacter
	local attachment = aimTargetAttachment
	if not character or not attachment or not rightHandIK then
		return
	end

	attachment.WorldPosition = getDesiredHandCFrame(character).Position
end

--[[
	Always-on periodic dump (unlike the old tick log this replaces,
	which only ever printed while the live-IK path was active and
	therefore went silent — with zero ongoing diagnostic output at all
	— for any weapon using a HoldAnimationId). Explicitly reports which
	mode is currently active plus mode-specific detail, so "the weapon
	looks unchanged" can be root-caused from Output alone: if
	holdAnimationTrack.IsPlaying is true and WeightCurrent > 0 but
	RightHand(actual) still isn't moving/looks like the raw equip pose,
	the Animation itself is the problem (bad/empty pose data, wrong
	rig, etc) rather than anything in this script.
]]
local function debugTick()
	if not DEBUG_LOGGING or os.clock() - lastDebugTickClock <= DEBUG_TICK_INTERVAL then
		return
	end
	lastDebugTickClock = os.clock()

	local tool = currentTool
	if not tool then
		return
	end
	local parts = currentArmParts :: ArmParts?
	local handle = tool:FindFirstChild("Handle")

	print(("[WeaponDebug][Client] --- tick (%s) mode=%s ---"):format(
		tool.Name,
		holdAnimationTrack and "Animation" or (rightHandIK and "IK" or "none")
	))
	if holdAnimationTrack then
		print(("[WeaponDebug][Client] holdAnimationTrack IsPlaying=%s WeightCurrent=%.2f Speed=%.2f TimePosition=%.2f/%.2f"):format(
			tostring(holdAnimationTrack.IsPlaying),
			holdAnimationTrack.WeightCurrent,
			holdAnimationTrack.Speed,
			holdAnimationTrack.TimePosition,
			holdAnimationTrack.Length
		))
	end
	if aimTargetAttachment then
		print("[WeaponDebug][Client] " .. CFrameDebug.Describe("AimTarget", aimTargetAttachment.WorldCFrame))
	end
	if parts then
		print("[WeaponDebug][Client] " .. CFrameDebug.Describe("RightHand(actual)", parts.rightEndEffector.CFrame))
	end
	if handle and handle:IsA("BasePart") then
		print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Handle(actual)", handle.CFrame))
	end
	print("[WeaponDebug][Client] " .. CFrameDebug.Describe("Camera", camera.CFrame))
end

function WeaponViewController.Init()
	local function handleCharacterAdded(character: Model)
		currentCharacter = character
		onToolUnequipped()
		watchContainer(character)

		-- Tool.Equipped only fires at the MOMENT of equipping — if
		-- PlayerService already parented the starting weapon into the
		-- character before this script got a chance to connect, that
		-- initial equip would otherwise go unnoticed and the weapon
		-- would sit at Roblox's raw default pose (no aim-follow/grip
		-- IK) until the player manually switches weapons at least once.
		local alreadyEquipped = character:FindFirstChildOfClass("Tool")
		if alreadyEquipped then
			onToolEquipped(alreadyEquipped)
		end
	end

	if player.Character then
		handleCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(handleCharacterAdded)
	watchContainer(player:WaitForChild("Backpack"))

	RunService.RenderStepped:Connect(function()
		updateAimFollow()
		syncFirstPersonViewmodel()
		updateFirstPersonViewmodel()
		debugTick()
	end)
end

return WeaponViewController
