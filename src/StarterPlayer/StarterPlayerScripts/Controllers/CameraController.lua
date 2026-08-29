--[[
	CameraController.lua (ModuleScript)

	Makes the character always face the direction the camera (and
	therefore the crosshair) is pointing, instead of Roblox's default
	behavior of only turning to face whichever direction you're currently
	moving in. This matches third-person shooter expectations: you can
	strafe left/right/backward while always aiming/facing forward.

	How: Humanoid.AutoRotate is disabled so the built-in controller stops
	auto-turning the character toward its movement vector, then every
	frame the character's yaw is manually snapped to match the camera's
	yaw. WASD movement itself is still camera-relative regardless — that's
	unrelated, default Roblox behavior — so strafing keeps working
	correctly; only facing direction changes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

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

function CameraController.Init()
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.AutoRotate = false
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		if character then
			faceCamera(character)
		end
	end)
end

return CameraController
