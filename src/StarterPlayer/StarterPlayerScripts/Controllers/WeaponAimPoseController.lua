--[[
	WeaponAimPoseController.lua (ModuleScript)

	Makes the LOCAL player's own held weapon always point toward wherever
	the camera is aiming, instead of the default walk/run/idle animation
	(which doesn't track aim direction at all).

	MAJOR REVISION: the original version of this controller manipulated
	Motor6D.C0 directly, which is how classic Roblox R15/R6 rigs work.
	Diagnostics (logged in earlier iterations, kept in git history)
	proved that assumption wrong for at least some avatars — this
	specific rig has NO Motor6D on its arms at all. Instead its joints
	are Attachment + BallSocketConstraint (the physical/ragdoll-capable
	joint) + AnimationConstraint (drives the animated pose) — Roblox's
	newer constraint-based avatar rig system. AnimationConstraint isn't
	meant for direct scripted posing the way Motor6D.C0 was.

	This version uses Roblox's IKControl instead — the modern, actually-
	intended tool for "aim a limb toward a target at runtime", designed
	to work with either rig system. HOWEVER: I have meaningfully LOWER
	confidence in IKControl's exact API (property names, required enum
	values, where it needs to be parented to take effect) than I had in
	Motor6D, which itself took multiple diagnostic rounds to get right.
	Expect this to need further iteration too. Every property this sets
	is wrapped in its own pcall with pass/fail logging specifically so
	the NEXT round of Output-log evidence can pinpoint exactly which
	assumptions are wrong, rather than another all-or-nothing guess.

	R6 rigs still use the OLD Motor6D path below (untested against a
	constraint-based R6 avatar — R6 is Roblox's older/simpler avatar
	type and may not have been migrated to the constraint system the
	same way R15 has; kept as the best available fallback rather than
	confirmed working).

	LOCAL ONLY regardless of rig type or technique: changes made from a
	LocalScript are never visible to other players watching you — see
	further down for why a fully shared version needs either a real
	authored Animation asset or a server-synced system.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WeaponAimPoseController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local IK_TARGET_DISTANCE = 6 -- studs in front of the shoulder the hand should reach toward
local MAX_PITCH_DEGREES = 55

-- ===== R6 fallback path (Motor6D-based, unchanged from the earlier version) =====

local R6_POSE: { [string]: CFrame } = {
	["Right Shoulder"] = CFrame.Angles(math.rad(-75), 0, math.rad(-5)),
	["Left Shoulder"] = CFrame.Angles(math.rad(-80), 0, math.rad(10)),
}

local r6RestPoses: { [Motor6D]: CFrame } = {}
local r6TrackedMotors: { Motor6D } = {}

local function findMotor(parent: Instance, name: string): Motor6D?
	local motor = parent:WaitForChild(name, 5)
	if motor and motor:IsA("Motor6D") then
		return motor
	end
	return nil
end

local function waitForPart(character: Model, name: string): Instance?
	local part = character:WaitForChild(name, 5)
	if not part then
		warn(("[WeaponAimPose] '%s' part did not appear under the character within 5s."):format(name))
	end
	return part
end

-- ===== R15 IKControl path (new) =====

local rightIK: Instance? = nil
local leftIK: Instance? = nil
local rightTargetAnchor: BasePart? = nil
local leftTargetAnchor: BasePart? = nil
local ikSetupSucceeded = false

--[[
	Tries to set a property on an Instance via pcall, logging pass/fail
	individually — this is the actual diagnostic value here: rather than
	one all-or-nothing attempt, we find out exactly which of our
	assumptions about IKControl's API are right and which aren't.
]]
local function trySet(instance: Instance, propertyName: string, value: any): boolean
	local ok, err = pcall(function()
		(instance :: any)[propertyName] = value
	end)
	if ok then
		print(("[WeaponAimPose] IKControl.%s = %s (OK)"):format(propertyName, tostring(value)))
	else
		warn(("[WeaponAimPose] IKControl.%s FAILED: %s"):format(propertyName, tostring(err)))
	end
	return ok
end

--[[
	Tries several plausible values for IKControl.Type until one is
	accepted — I'm not confident which enum member name/value Roblox
	actually uses here, so this probes rather than guessing once.
]]
local function trySetType(ikControl: Instance): boolean
	local candidates = { "LookAt", "Position", "Rotation", "Transform" }
	for _, candidateName in candidates do
		local ok, enumValue = pcall(function()
			return (Enum :: any).IKControlType[candidateName]
		end)
		if ok and enumValue then
			local setOk = trySet(ikControl, "Type", enumValue)
			if setOk then
				print(("[WeaponAimPose] IKControl.Type succeeded with Enum.IKControlType.%s"):format(candidateName))
				return true
			end
		else
			print(("[WeaponAimPose] Enum.IKControlType.%s does not exist."):format(candidateName))
		end
	end
	warn("[WeaponAimPose] No candidate IKControlType enum value worked.")
	return false
end

--[[
	Builds one IKControl for one arm. chainRootPart is where the chain
	starts (shoulder-side), endEffectorPart is what should move/orient
	toward the target (the hand). Returns (ikControl, targetAnchorPart)
	or (nil, nil) if IKControl isn't usable at all on this character.
]]
local function createArmIK(character: Model, humanoid: Humanoid, chainRootPart: BasePart, endEffectorPart: BasePart, label: string): (Instance?, BasePart?)
	local ok, ikControl = pcall(function()
		return Instance.new("IKControl")
	end)
	if not ok then
		warn(("[WeaponAimPose] Instance.new(\"IKControl\") failed for %s: %s"):format(label, tostring(ikControl)))
		return nil, nil
	end
	print(("[WeaponAimPose] Created IKControl for %s."):format(label))

	local targetAnchor = Instance.new("Part")
	targetAnchor.Name = "IKTargetAnchor_" .. label
	targetAnchor.Anchored = true
	targetAnchor.CanCollide = false
	targetAnchor.CanQuery = false
	targetAnchor.Transparency = 1
	targetAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
	targetAnchor.Parent = character

	-- Target is an Attachment (identity offset, so it exactly tracks
	-- targetAnchor's own CFrame every frame), not the Part directly —
	-- Roblox's constraint system consistently anchors to Attachments
	-- (BallSocketConstraint, RopeConstraint, etc.), and assigning a raw
	-- Part where an Attachment was expected can be silently accepted as
	-- "a valid Instance reference" without actually being usable,
	-- which fits the symptom: no error, but zero actual effect.
	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "IKTargetAttachment_" .. label
	targetAttachment.Parent = targetAnchor

	-- Parent under the Animator (a child of Humanoid), not the Humanoid
	-- directly. IKControl is fundamentally an animation-system feature
	-- meant to blend on top of whatever the Animator is already
	-- playing — Roblox's animation-related runtime objects are
	-- typically expected to live under the Animator specifically, not
	-- the Humanoid itself. This is a real, previously-untried gap: the
	-- last two rounds both "succeeded" on every property assignment
	-- with zero actual effect (handToTargetDistance never moved off
	-- ~5), which is consistent with the IKControl existing but never
	-- being picked up by whatever system actually runs IK solving,
	-- because it was never where that system looks for it.
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local createOk, createdOrErr = pcall(function()
			local newAnimator = Instance.new("Animator")
			newAnimator.Parent = humanoid
			return newAnimator
		end)
		if createOk then
			animator = createdOrErr :: Animator
			print(("[WeaponAimPose] No Animator existed under Humanoid — created one for %s."):format(label))
		else
			warn(("[WeaponAimPose] No Animator found and failed to create one for %s: %s"):format(label, tostring(createdOrErr)))
		end
	end

	local parentTarget: Instance = animator or humanoid
	local parentOk, parentErr = pcall(function()
		ikControl.Parent = parentTarget
	end)
	if parentOk then
		print(("[WeaponAimPose] IKControl for %s parented under %s successfully."):format(label, parentTarget.ClassName))
	else
		warn(("[WeaponAimPose] Failed to parent IKControl for %s under %s: %s"):format(label, parentTarget.ClassName, tostring(parentErr)))
	end

	trySet(ikControl, "ChainRoot", chainRootPart)
	trySet(ikControl, "EndEffector", endEffectorPart)
	trySet(ikControl, "Target", targetAttachment)
	trySetType(ikControl)
	trySet(ikControl, "Weight", 1)
	trySet(ikControl, "Enabled", true)

	-- Probing for a Priority-like property — if this exists and defaults
	-- too low, the base Idle/Walk animation (see logPlayingAnimations)
	-- could simply be winning the per-frame blend every time, which
	-- would perfectly explain "IK computes correctly internally
	-- (confirmed by the angle metric) but produces zero visible change."
	-- Not certain this property exists at all on IKControl; each
	-- candidate is independently pcall-guarded via trySet already.
	local priorityCandidates = { "Action", "Action2", "Action3", "Action4", "Movement", "Idle", "Core" }
	for _, candidateName in priorityCandidates do
		local enumOk, enumValue = pcall(function()
			return (Enum :: any).AnimationPriority[candidateName]
		end)
		if enumOk and enumValue then
			if trySet(ikControl, "Priority", enumValue) then
				print(("[WeaponAimPose] IKControl.Priority succeeded with Enum.AnimationPriority.%s"):format(candidateName))
				break
			end
		end
	end

	-- Delayed re-check: confirms the IKControl is STILL where we put
	-- it a moment later, not silently un-parented/rejected by Roblox
	-- after the fact despite the assignment itself not erroring.
	task.defer(function()
		local checkOk, checkErr = pcall(function()
			print(
				("[WeaponAimPose] %s post-setup check: Parent=%s, ChainRoot=%s, EndEffector=%s, Target=%s, Enabled=%s"):format(
					label,
					ikControl.Parent and ikControl.Parent:GetFullName() or "NIL",
					tostring((ikControl :: any).ChainRoot),
					tostring((ikControl :: any).EndEffector),
					tostring((ikControl :: any).Target),
					tostring((ikControl :: any).Enabled)
				)
			)
		end)
		if not checkOk then
			warn(("[WeaponAimPose] %s post-setup check errored: %s"):format(label, tostring(checkErr)))
		end
	end)

	return ikControl, targetAnchor
end

--[[
	DIAGNOSTIC: what animation is actually currently playing on this
	character, and at what priority. If there's an active track (Idle/
	Walk, from the default Animate script) at a priority IKControl
	can't override, that would explain "IK computes correctly internally
	(confirmed by the angle metric) but produces zero visible change" —
	the base animation could simply be winning the per-frame blend every
	time. This is a genuinely different kind of check than anything
	tried so far — not another guessed property, but visibility into
	what IK might be competing against.
]]
local function logPlayingAnimations(humanoid: Humanoid, label: string)
	local ok, err = pcall(function()
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			print(("[WeaponAimPose] %s: no Animator found to inspect playing tracks."):format(label))
			return
		end
		local tracks = animator:GetPlayingAnimationTracks()
		if #tracks == 0 then
			print(("[WeaponAimPose] %s: zero AnimationTracks currently playing."):format(label))
			return
		end
		for _, track in tracks do
			print(
				("[WeaponAimPose] %s: playing track '%s', Priority=%s, Weight=%.2f, Speed=%.2f"):format(
					label,
					track.Name,
					tostring(track.Priority),
					track.WeightCurrent,
					track.Speed
				)
			)
		end
	end)
	if not ok then
		warn(("[WeaponAimPose] logPlayingAnimations(%s) errored: %s"):format(label, tostring(err)))
	end
end

local function setupR15IK(character: Model, humanoid: Humanoid)
	rightIK = nil
	leftIK = nil
	rightTargetAnchor = nil
	leftTargetAnchor = nil
	ikSetupSucceeded = false

	local upperTorso = waitForPart(character, "UpperTorso") :: BasePart?
	local rightHand = waitForPart(character, "RightHand") :: BasePart?
	local leftHand = waitForPart(character, "LeftHand") :: BasePart?

	if not upperTorso or not rightHand or not leftHand then
		warn("[WeaponAimPose] Missing UpperTorso/RightHand/LeftHand — cannot set up IK.")
		return
	end

	logPlayingAnimations(humanoid, "Before IK setup")

	rightIK, rightTargetAnchor = createArmIK(character, humanoid, upperTorso, rightHand, "RightArm")
	leftIK, leftTargetAnchor = createArmIK(character, humanoid, upperTorso, leftHand, "LeftArm")

	ikSetupSucceeded = (rightIK ~= nil) and (leftIK ~= nil)
	print(("[WeaponAimPose] R15 IK setup complete. ikSetupSucceeded=%s"):format(tostring(ikSetupSucceeded)))

	task.delay(2, function()
		logPlayingAnimations(humanoid, "2s after IK setup")
	end)
end

-- ===== Shared character setup =====

local currentRigType: string? = nil
local hasLoggedNoWeaponSkip = false
local hasLoggedFirstApply = false
local hasLoggedUpdateError = false

local function setupCharacter(character: Model)
	currentRigType = nil
	r6RestPoses = {}
	r6TrackedMotors = {}
	hasLoggedNoWeaponSkip = false
	hasLoggedFirstApply = false
	hasLoggedUpdateError = false

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn("[WeaponAimPose] No Humanoid appeared within 10s — aborting setup for this character.")
		return
	end

	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		currentRigType = "R15"
		setupR15IK(character, humanoid)
	elseif humanoid.RigType == Enum.HumanoidRigType.R6 then
		currentRigType = "R6"
		local torso = waitForPart(character, "Torso")
		if torso then
			local rightMotor = findMotor(torso, "Right Shoulder")
			local leftMotor = findMotor(torso, "Left Shoulder")
			for _, motor in { rightMotor, leftMotor } do
				if motor then
					r6RestPoses[motor] = motor.C0
					table.insert(r6TrackedMotors, motor)
				end
			end
		end
		print(("[WeaponAimPose] R6 path: tracked %d motor(s)."):format(#r6TrackedMotors))
	else
		warn("[WeaponAimPose] Unrecognized RigType: " .. tostring(humanoid.RigType))
	end
end

local function hasEquippedWeapon(character: Model): boolean
	return character:FindFirstChildOfClass("Tool") ~= nil
end

--[[
	World-space point the hand should reach toward: out along the
	camera's look direction from the shoulder, roughly where a
	two-handed rifle grip would naturally sit.
]]
--[[
	World-space point the hand should reach toward: out along the
	camera's direction from the torso, roughly where a two-handed rifle
	grip would naturally sit.

	Pitch is clamped rather than using the camera's raw vertical angle
	directly — this is the actual fix for "the gun keeps pointing at
	the floor": a typical over-the-shoulder third-person camera often
	rests at a mildly downward angle even when the player isn't
	deliberately looking down, and that small downward tilt, multiplied
	by IK_TARGET_DISTANCE, was enough to drag the target below torso
	height every frame by default. Clamping means only a genuinely
	deliberate, steeper look up/down meaningfully tilts the aim target;
	the resting camera angle no longer droops the gun on its own.
]]
local function computeHandTargetPosition(originPart: BasePart): Vector3
	local lookVector = camera.CFrame.LookVector

	local horizontal = Vector3.new(lookVector.X, 0, lookVector.Z)
	local horizontalLength = horizontal.Magnitude
	if horizontalLength < 0.0001 then
		-- Looking almost straight up/down: fall back to the origin
		-- part's own forward direction so there's still a sensible yaw.
		horizontal = Vector3.new(originPart.CFrame.LookVector.X, 0, originPart.CFrame.LookVector.Z)
		horizontalLength = horizontal.Magnitude
		if horizontalLength < 0.0001 then
			horizontal = Vector3.new(0, 0, -1)
			horizontalLength = 1
		end
	end
	horizontal = horizontal / horizontalLength -- unit vector, same yaw as the camera

	local rawPitch = math.atan2(lookVector.Y, horizontalLength)
	local clampedPitch = math.clamp(rawPitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))

	-- Same yaw as the camera, but with the clamped (not raw) pitch:
	-- horizontal component scaled by cos(pitch), vertical by sin(pitch).
	local direction = Vector3.new(
		horizontal.X * math.cos(clampedPitch),
		math.sin(clampedPitch),
		horizontal.Z * math.cos(clampedPitch)
	)

	return originPart.Position + direction * IK_TARGET_DISTANCE
end

local lastDiagnosticPrintTime = 0

local function updateR15(character: Model)
	if not ikSetupSucceeded then
		return
	end
	local upperTorso = character:FindFirstChild("UpperTorso") :: BasePart?
	local rightHand = character:FindFirstChild("RightHand") :: BasePart?
	if not upperTorso or not rightTargetAnchor or not leftTargetAnchor then
		return
	end

	local ok, err = pcall(function()
		local targetPosition = computeHandTargetPosition(upperTorso)
		rightTargetAnchor.CFrame = CFrame.new(targetPosition)
		leftTargetAnchor.CFrame = CFrame.new(targetPosition)

		-- DIAGNOSTIC (throttled to once every 3s so it doesn't spam):
		-- the KEY number now is handToTargetDistance — if IK is
		-- actually pulling the hand toward the target, this should
		-- shrink toward ~0. Previous data showed it staying flat
		-- around IK_TARGET_DISTANCE regardless of camera direction,
		-- which is the actual signal that IK wasn't taking effect at
		-- all (the hand was just sitting wherever the default holding
		-- animation put it, never actually converging on the target).
		local now = os.clock()
		if rightHand and now - lastDiagnosticPrintTime > 3 then
			lastDiagnosticPrintTime = now
			local handToTargetDistance = (rightHand.Position - targetPosition).Magnitude

			-- The metric that actually matters, reconsidered: Type=LookAt
			-- most likely ROTATES the hand to face the target rather than
			-- pulling its POSITION all the way there — the arm's real
			-- reach from the shoulder is only a couple studs, nowhere
			-- near IK_TARGET_DISTANCE (6), so a chain respecting its own
			-- bone-length limits would never close that gap to 0 even
			-- while working correctly. handToTargetDistance may have
			-- been the wrong thing to check this whole time. This
			-- compares the hand's current forward direction against the
			-- direction TO the target instead — small angle = hand is
			-- correctly oriented toward the target, regardless of
			-- whether its position ever gets close.
			local handToTargetDirection = (targetPosition - rightHand.Position)
			local angleToTargetDegrees = "n/a"
			if handToTargetDirection.Magnitude > 0.01 then
				local dot = handToTargetDirection.Unit:Dot(rightHand.CFrame.LookVector)
				angleToTargetDegrees = tostring(math.deg(math.acos(math.clamp(dot, -1, 1))))
			end

			print(
				("[WeaponAimPose] handToTargetDistance=%.2f (may not shrink to 0 even if working — see note) | angleBetweenHandForwardAndTargetDir=%s degrees (THIS is what should shrink toward 0 if IK is working) | target.Y-torso.Y=%.2f"):format(
					handToTargetDistance,
					angleToTargetDegrees,
					targetPosition.Y - upperTorso.Position.Y
				)
			)
		end
	end)

	if not ok then
		if not hasLoggedUpdateError then
			hasLoggedUpdateError = true
			warn("[WeaponAimPose] updateR15 errored: " .. tostring(err))
		end
		return
	end

	if not hasLoggedFirstApply then
		hasLoggedFirstApply = true
		print("[WeaponAimPose] First R15 IK target update this life (does not confirm the arm visually moved — only that no error occurred).")
	end
end

local function getPitchOffset(): CFrame
	local lookVector = camera.CFrame.LookVector
	local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))
	pitch = math.clamp(pitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	return CFrame.Angles(pitch, 0, 0)
end

local function updateR6(character: Model)
	if #r6TrackedMotors == 0 then
		return
	end
	local pitchOffset = getPitchOffset()

	local ok, err = pcall(function()
		for _, motor in r6TrackedMotors do
			local baseOffset = R6_POSE[motor.Name]
			if baseOffset then
				motor.C0 = r6RestPoses[motor] * pitchOffset * baseOffset
			end
		end
	end)

	if not ok then
		if not hasLoggedUpdateError then
			hasLoggedUpdateError = true
			warn("[WeaponAimPose] updateR6 errored: " .. tostring(err))
		end
		return
	end

	if not hasLoggedFirstApply then
		hasLoggedFirstApply = true
		print("[WeaponAimPose] First R6 pose apply this life.")
	end
end

local function update()
	local character = player.Character
	if not character then
		return
	end
	if not hasEquippedWeapon(character) then
		if not hasLoggedNoWeaponSkip then
			hasLoggedNoWeaponSkip = true
			print("[WeaponAimPose] Skipping: no equipped Tool found as a direct child of the character.")
		end
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	if currentRigType == "R15" then
		updateR15(character)
	elseif currentRigType == "R6" then
		updateR6(character)
	end
end

function WeaponAimPoseController.Init()
	local function onCharacterAdded(character: Model)
		setupCharacter(character)
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	local ok, err = pcall(function()
		RunService:BindToRenderStep("WeaponAimPose", Enum.RenderPriority.Last.Value + 1, update)
	end)
	if ok then
		print("[WeaponAimPose] BindToRenderStep registered successfully.")
	else
		warn("[WeaponAimPose] BindToRenderStep FAILED to register: " .. tostring(err))
	end
end

return WeaponAimPoseController
