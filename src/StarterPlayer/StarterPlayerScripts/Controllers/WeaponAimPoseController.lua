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
	  only) rigs, detected per-character, since a player's avatar type
	  depends on their own account settings, not something this game
	  controls. R6's single-joint arm can approximate "raised toward
	  camera" but not as convincing a two-handed grip as R15's.
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

local function findMotor(parent: Instance, name: string): Motor6D?
	local motor = parent:FindFirstChild(name)
	if motor and motor:IsA("Motor6D") then
		return motor
	end
	return nil
end

local function setupCharacter(character: Model)
	restPoses = {}
	trackedMotors = {}
	currentRigType = nil

	local upperTorso = character:FindFirstChild("UpperTorso")
	local torso = character:FindFirstChild("Torso")

	local motorsToCapture: { Motor6D? } = {}

	if upperTorso then
		currentRigType = "R15"
		local rightUpperArm = character:FindFirstChild("RightUpperArm")
		local leftUpperArm = character:FindFirstChild("LeftUpperArm")
		local rightLowerArm = character:FindFirstChild("RightLowerArm")
		local leftLowerArm = character:FindFirstChild("LeftLowerArm")

		table.insert(motorsToCapture, rightUpperArm and findMotor(rightUpperArm, "RightShoulder"))
		table.insert(motorsToCapture, leftUpperArm and findMotor(leftUpperArm, "LeftShoulder"))
		table.insert(motorsToCapture, rightLowerArm and findMotor(rightLowerArm, "RightElbow"))
		table.insert(motorsToCapture, leftLowerArm and findMotor(leftLowerArm, "LeftElbow"))
	elseif torso then
		currentRigType = "R6"
		table.insert(motorsToCapture, findMotor(torso, "Right Shoulder"))
		table.insert(motorsToCapture, findMotor(torso, "Left Shoulder"))
	end

	for _, motor in motorsToCapture do
		if motor then
			restPoses[motor] = motor.C0
			table.insert(trackedMotors, motor)
		end
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
		return -- no weapon equipped: let the default animation play normally
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local pose = currentRigType == "R15" and R15_POSE or R6_POSE
	local pitchOffset = getPitchOffset()

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
	RunService:BindToRenderStep("WeaponAimPose", Enum.RenderPriority.Last.Value + 1, update)
end

return WeaponAimPoseController
