--[[
	WeaponAimPoseController.lua (ModuleScript)

	Makes the LOCAL player's own held weapon always point toward wherever
	the camera is aiming — third-person "held with both hands, pointing
	forward, not swinging with the walk/run cycle" and first-person "gun
	visibly tilts up/down as you look up/down" — instead of the default
	walk/run/idle animation's arm-swing pose, which doesn't track aim
	direction at all.

	READ THIS BEFORE ASSUMING IT "JUST WORKS":

	- LOCAL ONLY. This overrides Motor6D.C0 directly from a LocalScript
	  context, which only affects what THIS client renders. Motor6D pose
	  changes made client-side do NOT automatically replicate to other
	  players — everyone else watching you will still see the default
	  walk-animation arm pose, not this aim pose. Making this visible to
	  everyone would need either a real uploaded Animation asset (not
	  something this text-only environment can author — that needs
	  Studio's Animation Editor) or a continuously server-synced pose
	  system (real added complexity and bandwidth). Out of scope here;
	  this fixes what YOU see when you look at your own character.

	- Angle values below are estimates, not verified visually in Studio.
	  Rotations are applied RELATIVE to each joint's own captured rest
	  C0 (read once at spawn) rather than as hardcoded absolute poses,
	  specifically so this adapts to whatever that avatar's natural rest
	  pose already is — but whether the result actually reads as a
	  convincing two-handed rifle grip needs real playtesting to
	  confirm/tune. Retune the *_POSE tables below; nothing else needs
	  to change to adjust the look.

	- Supports both R15 (Shoulder + Elbow per arm) and R6 (Shoulder
	  only) rigs, detected per-character via `Humanoid.RigType` (not by
	  guessing from which body parts happen to exist — see
	  setupCharacter's comments for why that mattered), since a
	  player's avatar type depends on their own account settings, not
	  something this game controls. R6's single-joint arm can
	  approximate "raised toward camera" but not as convincing a
	  two-handed grip as R15's.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WeaponAimPoseController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Rotation OFFSETS applied on top of each joint's captured rest C0 (not
-- absolute poses) — a "raise into a two-handed rifle grip" shape.
local R15_POSE: { [string]: CFrame } = {
	RightShoulder = CFrame.Angles(math.rad(-70), 0, math.rad(-8)),
	RightElbow = CFrame.Angles(math.rad(-35), 0, 0),
	LeftShoulder = CFrame.Angles(math.rad(-75), 0, math.rad(15)),
	LeftElbow = CFrame.Angles(math.rad(-45), 0, 0),
}
local R6_POSE: { [string]: CFrame } = {
	["Right Shoulder"] = CFrame.Angles(math.rad(-75), 0, math.rad(-5)),
	["Left Shoulder"] = CFrame.Angles(math.rad(-80), 0, math.rad(10)),
}

-- Only these joints (the shoulders) directly track camera pitch; elbows
-- keep a fixed bend regardless — reads more like a rigid two-handed
-- grip rotating from the shoulder than every joint independently
-- chasing the camera.
local PITCH_TRACKING_MOTOR_NAMES = {
	RightShoulder = true,
	LeftShoulder = true,
	["Right Shoulder"] = true,
	["Left Shoulder"] = true,
}

local MAX_PITCH_DEGREES = 55 -- clamps how far the pose tilts at extreme up/down look

local restPoses: { [Motor6D]: CFrame } = {}
local trackedMotors: { Motor6D } = {}
local currentRigType: string? = nil -- "R15" | "R6" | nil
local hasLoggedNoWeaponSkip = false
local hasLoggedFirstApply = false
local hasLoggedError = false

local function findMotor(parent: Instance, name: string): Motor6D?
	-- WaitForChild here too, not just for the arm parts one level up —
	-- the joint can attach to its part slightly after the part itself
	-- appears, the same population race, just one level deeper.
	local motor = parent:WaitForChild(name, 5)
	if motor and motor:IsA("Motor6D") then
		return motor
	end
	if motor then
		warn(
			("[WeaponAimPose] '%s' under %s exists but is a %s, not a Motor6D."):format(
				name,
				parent:GetFullName(),
				motor.ClassName
			)
		)
	else
		warn(("[WeaponAimPose] '%s' motor did not appear under %s within 5s."):format(name, parent:GetFullName()))
	end
	return nil
end

--[[
	Same WaitForChild treatment as findMotor, plus an explicit warning
	naming exactly which part failed to appear — this is what turns
	"0 motors found" into an actual answer instead of another guess.
]]
local function waitForPart(character: Model, name: string): Instance?
	local part = character:WaitForChild(name, 5)
	if not part then
		warn(("[WeaponAimPose] '%s' part did not appear under the character within 5s."):format(name))
	end
	return part
end

local function setupCharacter(character: Model)
	restPoses = {}
	trackedMotors = {}
	currentRigType = nil
	hasLoggedNoWeaponSkip = false
	hasLoggedFirstApply = false
	hasLoggedError = false

	-- WaitForChild (which actually yields until the part appears, up to
	-- the timeout), not FindFirstChild (which returns nil immediately if
	-- the part isn't there YET). This is the actual bug the diagnostics
	-- caught: CharacterAdded fires as soon as the character Model exists,
	-- but body parts can still be populating for a moment after that —
	-- a synchronous FindFirstChild right then reliably missed them,
	-- which is exactly why rig detection was finding nothing. This
	-- yields inside its own coroutine (Roblox runs each CharacterAdded
	-- connection callback in its own thread), so it's safe and doesn't
	-- block anything else.
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn("[WeaponAimPose] No Humanoid appeared within 10s — aborting setup for this character.")
		return
	end

	-- Humanoid.RigType is a reliable enum the moment the Humanoid exists
	-- — checking it directly avoids re-guessing rig type from which body
	-- parts happen to exist yet, which was the unreliable part before.
	local motorsToCapture: { Motor6D? } = {}

	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		currentRigType = "R15"
		local rightUpperArm = waitForPart(character, "RightUpperArm")
		local leftUpperArm = waitForPart(character, "LeftUpperArm")
		local rightLowerArm = waitForPart(character, "RightLowerArm")
		local leftLowerArm = waitForPart(character, "LeftLowerArm")

		table.insert(motorsToCapture, rightUpperArm and findMotor(rightUpperArm, "RightShoulder"))
		table.insert(motorsToCapture, leftUpperArm and findMotor(leftUpperArm, "LeftShoulder"))
		table.insert(motorsToCapture, rightLowerArm and findMotor(rightLowerArm, "RightElbow"))
		table.insert(motorsToCapture, leftLowerArm and findMotor(leftLowerArm, "LeftElbow"))
	elseif humanoid.RigType == Enum.HumanoidRigType.R6 then
		currentRigType = "R6"
		local torso = waitForPart(character, "Torso")
		if torso then
			table.insert(motorsToCapture, findMotor(torso, "Right Shoulder"))
			table.insert(motorsToCapture, findMotor(torso, "Left Shoulder"))
		end
	end

	for _, motor in motorsToCapture do
		if motor then
			restPoses[motor] = motor.C0
			table.insert(trackedMotors, motor)
		end
	end

	-- DIAGNOSTIC: confirms setup actually found what it expects. If this
	-- still prints "rig=NONE" or 0 motors after this fix, the problem is
	-- something else entirely (e.g. a genuinely nonstandard rig) — worth
	-- keeping this in until it's confirmed fixed.
	local motorNames = {}
	for _, motor in trackedMotors do
		table.insert(motorNames, motor.Name)
	end
	print(
		("[WeaponAimPose] setupCharacter: rig=%s, tracked %d motor(s): %s"):format(
			currentRigType or "NONE",
			#trackedMotors,
			#motorNames > 0 and table.concat(motorNames, ", ") or "(none found)"
		)
	)
	if #trackedMotors == 0 then
		warn("[WeaponAimPose] Found zero arm motors — character structure didn't match either R15 or R6 expectations. This controller will do nothing for this character.")
	end
end

local function hasEquippedWeapon(character: Model): boolean
	return character:FindFirstChildOfClass("Tool") ~= nil
end

local function getPitchOffset(): CFrame
	local lookVector = camera.CFrame.LookVector
	local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))
	pitch = math.clamp(pitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	-- Looking up (positive pitch) raises the gun to match.
	return CFrame.Angles(pitch, 0, 0)
end

local function update()
	local character = player.Character
	if not character or #trackedMotors == 0 then
		return
	end
	if not hasEquippedWeapon(character) then
		-- DIAGNOSTIC (temporary): only logs once so it doesn't spam —
		-- confirms whether "no Tool found on the character" is why
		-- nothing is happening (e.g. the Tool isn't actually parented
		-- directly under the character the way this expects).
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

	local pose = currentRigType == "R15" and R15_POSE or R6_POSE
	local pitchOffset = getPitchOffset()

	local ok, err = pcall(function()
		for _, motor in trackedMotors do
			local baseOffset = pose[motor.Name]
			if baseOffset then
				local restC0 = restPoses[motor]
				if PITCH_TRACKING_MOTOR_NAMES[motor.Name] then
					motor.C0 = restC0 * pitchOffset * baseOffset
				else
					motor.C0 = restC0 * baseOffset
				end
			end
		end
	end)

	if not ok then
		-- DIAGNOSTIC (temporary): if the pose math itself is erroring
		-- every frame, a silently-failing BindToRenderStep callback
		-- could look identical to "doing nothing" from the outside.
		if not hasLoggedError then
			hasLoggedError = true
			warn("[WeaponAimPose] update() errored: " .. tostring(err))
		end
		return
	end

	if not hasLoggedFirstApply then
		hasLoggedFirstApply = true
		print("[WeaponAimPose] First successful pose apply this life.")
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

	-- BindToRenderStep (not a plain RenderStepped:Connect) so this is
	-- guaranteed to run AFTER Roblox's own animation system applies that
	-- frame's walk/idle pose. Bound at Last (not just "after Camera") —
	-- character animation appears to apply at a priority later than
	-- Camera, which meant an earlier version of this bound too early
	-- and was silently overwritten every frame, producing no visible
	-- effect at all. Last is the latest priority tier RenderStepped
	-- exposes, giving this the final say each frame.
	--
	-- Wrapped in pcall: this call sits near the END of ClientMain's
	-- Init() sequence — if it ever threw unprotected (e.g. a
	-- BindToRenderStep name collision with something else), Lua halts
	-- the REST of that script's execution too, which would have
	-- silently broken every remote-wiring line still below it in
	-- ClientMain, not just this feature. This print/warn pair also
	-- confirms whether registration itself is the actual failure point.
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
