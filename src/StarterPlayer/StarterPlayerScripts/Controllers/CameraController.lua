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

	3. Auto-aim ASSIST (not lock): when a zombie is within a small cone
	   around the crosshair and in range, this gently BENDS THE CAMERA'''s
	   look direction toward the nearest body part, so the crosshair
	   drifts onto the target. WeaponController then just fires wherever
	   the camera is currently pointing — manual aim and auto-aim share
	   the exact same direction source, so what you see is always what
	   you shoot. IsLocked() tells WeaponController whether to auto-fire
	   this frame (true whenever a target is acquired, including while
	   the assist is standing down).

	   It deliberately yields to the player: a dead zone stops correcting
	   once the crosshair is essentially on target, active aim input
	   drops it to a fraction of its strength, and the base rate is a
	   pull rather than a snap. Earlier it hard-locked onto a single
	   fixed part per zombie at a rate faster than a player could aim
	   off it, so deliberately shifting from body to head was impossible
	   — the assist just dragged the crosshair straight back.

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

-- Shifts the camera's focus point right and up so the character (and the
-- weapon held in their hands) sits toward the lower-left of the screen
-- instead of dead-center, matching standard over-the-shoulder third-
-- person shooter framing — X pushes the character left, Y pushes them
-- DOWN (the character/gun end up on the OPPOSITE side of the screen from
-- whichever way the focus point shifts, same reasoning for both axes).
-- The Y component specifically exists so the held weapon's silhouette
-- sits clearly below screen-center, leaving clear headroom for the
-- fixed-center crosshair above it — matching first person's own
-- analogous fix, see WeaponViewController's FIRST_PERSON_VIEWMODEL_OFFSET.
-- Kept modest on X (a wider shift looks more "cinematic" but makes the
-- visual gun barrel increasingly diverge from where the crosshair
-- actually sits, since the crosshair marks camera.LookVector — always
-- exact screen-center, which is what shots actually fire along — while
-- the gun's held orientation doesn't bend to match an offset camera).
local SHOULDER_OFFSET = Vector3.new(0.9, 2.2, 0)
local FIRST_PERSON_TOGGLE_KEY = Enum.KeyCode.V

-- Roblox's own default (0.5 studs) lets players scroll the mouse wheel
-- in close enough to put the camera almost inside the character's own
-- head — since the crosshair is a fixed screen-center UI element (see
-- UIController's buildCrosshair), that reads as "the crosshair is
-- overlapping/stuck on my character" any time someone scrolls all the
-- way in. Clamping the minimum keeps the head/shoulders from ever
-- filling the screen center in Classic (third-person) mode; irrelevant
-- in LockFirstPerson, which ignores zoom distance entirely.
local THIRD_PERSON_MIN_ZOOM_DISTANCE = 8

-- Higher = snappier lock-on (reaches ~63% of the way to the target's
-- direction every 1/LOCK_TURN_RATE seconds). Deliberately much gentler
-- than it used to be (was 10): at that rate the assist yanked the
-- crosshair back to its chosen point faster than a player could aim off
-- it, which is what made precise aiming feel impossible.
local LOCK_TURN_RATE = 3.5

-- While the player is actively moving their aim, the assist drops to
-- this fraction of its normal strength. Not zero: a light pull still
-- helps track a moving zombie, but it's weak enough that the player's
-- own input clearly wins.
local MANUAL_AIM_ASSIST_SCALE = 0.15

-- How long after the last aim input the player still counts as "actively
-- aiming". Long enough to cover the gaps between mouse-move events
-- during a slow, careful adjustment.
local MANUAL_AIM_GRACE_SECONDS = 0.35

-- Inside this angle the assist does nothing at all. Once the crosshair
-- is essentially on target, any further correction is the assist
-- overriding deliberate fine aim (e.g. shifting from chest to head),
-- which is exactly the behavior being fixed here.
local ASSIST_DEADZONE_DEGREES = 2.5
local ASSIST_DEADZONE_COS = math.cos(math.rad(ASSIST_DEADZONE_DEGREES))

local isFirstPerson = false
local isLocked = false
local lastManualAimClock = 0

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
	Finds a nearby target and, if one qualifies, gently bends the camera's
	look direction toward it — leaving position untouched, only rotation
	changes. Updates isLocked for WeaponController to read.

	This is aim ASSIST, not aim lock. Three things keep it from
	overriding the player, which the original version did:

	  1. Dead zone — once the crosshair is within ASSIST_DEADZONE_DEGREES
	     of the target point, the assist stops entirely. This is what
	     makes deliberate fine aiming (chest -> head) actually stick
	     instead of being dragged back.
	  2. Manual input backs it off — while the player is actively moving
	     their aim, strength drops to MANUAL_AIM_ASSIST_SCALE so their
	     input clearly wins.
	  3. Much gentler base rate, so even at full strength it reads as a
	     pull rather than a snap.

	Combined with AutoAimController now targeting whichever body part is
	nearest the crosshair, aiming at a head both selects the head AND is
	left alone once you're on it.
]]
local function updateAutoAimLock(deltaTime: number)
	local cameraPosition = camera.CFrame.Position
	local cameraLook = camera.CFrame.LookVector

	local targetPart = AutoAimController.FindTargetPart(cameraPosition, cameraLook)
	if not targetPart then
		isLocked = false
		return
	end

	-- isLocked stays true whenever a valid target is in the cone, even
	-- inside the dead zone / while manually aiming — it means "a target
	-- is acquired", which is what WeaponController and the crosshair
	-- care about, not "the camera is currently being moved".
	isLocked = true

	local desiredLook = (targetPart.Position - cameraPosition).Unit

	-- Already on target: leave the player's aim completely alone.
	if cameraLook:Dot(desiredLook) >= ASSIST_DEADZONE_COS then
		return
	end

	local strength = 1
	if os.clock() - lastManualAimClock < MANUAL_AIM_GRACE_SECONDS then
		strength = MANUAL_AIM_ASSIST_SCALE
	end

	local alpha = math.clamp(deltaTime * LOCK_TURN_RATE * strength, 0, 1)
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
		player.CameraMinZoomDistance = THIRD_PERSON_MIN_ZOOM_DISTANCE
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

	--[[
		Marks the player as "actively aiming" so updateAutoAimLock can back
		the assist off (see MANUAL_AIM_ASSIST_SCALE). Covers mouse look on
		desktop and drag-to-look on touch.

		Deliberately NOT filtered on gameProcessed: while the right mouse
		button is held for camera look, or a touch drag is being consumed
		by the camera, Roblox reports these as game-processed — filtering
		them out would miss exactly the input this needs to detect.

		A small threshold ignores sub-pixel jitter, which would otherwise
		keep the assist permanently suppressed on a resting mouse.
	]]
	local MANUAL_AIM_DELTA_THRESHOLD = 0.5
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		then
			local delta = input.Delta
			if math.abs(delta.X) + math.abs(delta.Y) > MANUAL_AIM_DELTA_THRESHOLD then
				lastManualAimClock = os.clock()
			end
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
