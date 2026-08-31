--[[
	CameraController.lua (ModuleScript)

	Three responsibilities:

	1. Character-facing: makes the character always face the direction the
	   camera (and therefore the crosshair) is pointing, instead of
	   Roblox's default behavior of only turning to face the movement
	   direction.

	2. Over-the-shoulder third-person camera offset, with a toggle (V key
	   or the on-screen VIEW button — see UIController/ClientMain) to
	   switch into true first-person (LockFirstPerson).

	3. Auto-aim lock-on: when a zombie is within a small cone around the
	   crosshair and in range, this actually BENDS THE CAMERA's look
	   direction toward it (smoothly, not an instant teleport), so the
	   crosshair visually settles onto the target. WeaponController then
	   just fires wherever the camera is currently pointing — manual aim
	   and auto-aim share the exact same direction source, so what you
	   see is always what you shoot. IsLocked() tells WeaponController
	   whether to auto-fire this frame.

	Implementation note on #3: Roblox's default camera script re-derives
	camera.CFrame from its own internally tracked yaw/pitch every frame,
	so overriding camera.CFrame here only affects the frame it's set on —
	next frame the default script recomputes from its own state, and we
	override again. That's fine while a lock is continuously held (we run
	every frame), but the *instant* a target leaves lock range, control
	reverts entirely and the camera will visibly snap back to wherever the
	default script's own tracked direction currently is. That snap is a
	deliberate, accepted tradeoff here (not a bug) — instant lock-on/
	lock-off is standard for this genre (casual arcade zombie shooters),
	and avoiding it would require fully replacing Roblox's camera system
	rather than layering on top of it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AutoAimController = require(script.Parent.AutoAimController)

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Shifts the camera's focus point right and slightly up so the character
-- sits toward the left of the screen instead of dead-center, matching
-- standard over-the-shoulder third-person shooter framing. Kept modest
-- (not a large offset) — a wider shift looks more "cinematic" but makes
-- the visual gun barrel increasingly diverge from where the crosshair
-- actually sits, since the crosshair marks camera.LookVector (always
-- exact screen-center, which is what shots actually fire along) while
-- the gun's held orientation doesn't bend to match an offset camera.
local SHOULDER_OFFSET = Vector3.new(0.9, 0.3, 0)
local FIRST_PERSON_TOGGLE_KEY = Enum.KeyCode.V

-- Higher = snappier lock-on (reaches ~63% of the way to the target's
-- direction every 1/LOCK_TURN_RATE seconds). Tune to taste.
local LOCK_TURN_RATE = 10

local isFirstPerson = false
local isLocked = false

function CameraController.IsLocked(): boolean
	return isLocked
end

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

--[[
	Finds a nearby target and, if one qualifies, smoothly bends the
	camera's look direction toward it — leaving position untouched, only
	rotation changes. Updates isLocked for WeaponController to read.
]]
local function updateAutoAimLock(deltaTime: number)
	local cameraPosition = camera.CFrame.Position
	local cameraLook = camera.CFrame.LookVector

	local targetPart = AutoAimController.FindTargetPart(cameraPosition, cameraLook)
	if not targetPart then
		isLocked = false
		return
	end

	isLocked = true

	local desiredLook = (targetPart.Position - cameraPosition).Unit
	local alpha = math.clamp(deltaTime * LOCK_TURN_RATE, 0, 1)
	local blendedLook = cameraLook:Lerp(desiredLook, alpha)

	if blendedLook.Magnitude > 0.001 then
		camera.CFrame = CFrame.lookAt(cameraPosition, cameraPosition + blendedLook.Unit)
	end
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

local function toggleFirstPerson()
	isFirstPerson = not isFirstPerson
	local character = player.Character
	if character then
		applyCameraMode(character)
	end
end

--[[
	Exposed so the on-screen VIEW button (see UIController) can trigger
	the same toggle the V key does — one shared function, two input
	paths, so they can never drift into different behavior.
]]
function CameraController.ToggleFirstPerson()
	toggleFirstPerson()
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
			toggleFirstPerson()
		end
	end)

	RunService.RenderStepped:Connect(function(deltaTime)
		updateAutoAimLock(deltaTime)

		local character = player.Character
		if character then
			faceCamera(character)
		end
	end)
end

return CameraController
