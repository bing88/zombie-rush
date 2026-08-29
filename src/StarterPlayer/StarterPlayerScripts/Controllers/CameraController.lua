--[[
	CameraController.lua (ModuleScript)

	Two responsibilities:

	1. Makes the character always face the direction the camera (and
	   therefore the crosshair) is pointing, instead of Roblox's default
	   behavior of only turning to face whichever direction you're
	   currently moving in. Matches third-person shooter expectations:
	   strafe left/right/backward while always aiming/facing forward.

	2. Over-the-shoulder third-person camera (character offset to the
	   right instead of dead-center) with a toggle to switch into true
	   first-person (LockFirstPerson).

	How #1 works: Humanoid.AutoRotate is disabled so the built-in
	controller stops auto-turning the character toward its movement
	vector, then every frame the character's yaw is manually snapped to
	match the camera's yaw. WASD movement itself is still camera-relative
	regardless — that's unrelated, default Roblox behavior — so strafing
	keeps working correctly; only facing direction changes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Shifts the camera's focus point right and slightly up so the character
-- sits toward the left of the screen instead of dead-center, matching
-- standard over-the-shoulder third-person shooter framing.
local SHOULDER_OFFSET = Vector3.new(1.75, 0.4, 0)
local FIRST_PERSON_TOGGLE_KEY = Enum.KeyCode.V

local isFirstPerson = false

local function faceCamera(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return
	end

	local lookVector = camera.CFrame.LookVector
	-- Flatten to the horizontal plane so the character doesn't tip
	-- forward/backward when the camera pitches up or down.
	lookVector = Vector3.new(lookVector.X, 0, lookVector.Z)
	if lookVector.Magnitude < 0.001 then
		return
	end

	rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector.Unit)
end

local function applyCameraMode(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		return
	end

	if isFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		humanoid.CameraOffset = Vector3.zero
	else
		player.CameraMode = Enum.CameraMode.Classic
		humanoid.CameraOffset = SHOULDER_OFFSET
	end
end

function CameraController.Init()
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.AutoRotate = false
		applyCameraMode(character)
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == FIRST_PERSON_TOGGLE_KEY then
			isFirstPerson = not isFirstPerson
			local character = player.Character
			if character then
				applyCameraMode(character)
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		if character then
			faceCamera(character)
		end
	end)
end

return CameraController
