--[[
	WeaponViewController.lua (ModuleScript)

	Purely cosmetic, local-only tool animation via Tool.Grip — never
	touches the character's body rig at all (no Motor6D, no IKControl).

	Two things live here now:
	1. Reload dip/return tween (unchanged from before).
	2. Continuous camera-pitch tracking: tilts the weapon's Grip to
	   follow the camera looking up/down, so the gun visibly responds
	   to aim direction in both first- and third-person.

	WHY GRIP AND NOT THE ARM RIG: an earlier, much more ambitious
	attempt tried to make the character's actual ARM visibly track aim
	direction via the body rig (first Motor6D, then — once diagnostics
	revealed this specific avatar type uses Roblox's newer constraint-
	based rig with no Motor6D at all — IKControl). Ten diagnostic
	rounds of genuinely verified-correct configuration (confirmed
	parenting, confirmed property values, confirmed animation-priority
	settings) never produced a single visible change in-game, and one
	round actively regressed. That approach is not used anymore.

	Grip is a much smaller, more reliable target: it's a plain CFrame
	property with no rig-compatibility questions, and this exact
	mechanism (tweening Grip) was already proven to work for the reload
	animation before any of that IK work started. The tradeoff: this
	tilts the WEAPON itself, not the arm/hand holding it — the arm still
	follows Roblox's default walk/idle animation and can still swing
	somewhat with footsteps. It does NOT fully solve "the arm never
	shakes while walking," only "the gun visibly follows where you're
	looking," which is a smaller but far more achievable claim given
	what's actually been possible to get working.

	LOCAL ONLY regardless: Grip changes made client-side aren't visible
	to other players watching you — same limitation as everything else
	client-side in this codebase; a shared version needs either a real
	authored Animation asset or a server-synced system.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)

local WeaponViewController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local RELOAD_GRIP = CFrame.new(0, -0.6, 0.3) * CFrame.Angles(math.rad(35), 0, 0)

-- Kept modest so the barrel tilt reads as "following your aim" rather
-- than an exaggerated/cartoonish swing.
local MAX_PITCH_DEGREES = 35

-- Pitch-follow backs off until this os.clock() timestamp passes, so it
-- doesn't fight the reload dip/return tween below for control of Grip.
local reloadingUntilClock = 0

local function getEquippedTool(): Tool?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Tool")
end

local function getDefaultGrip(tool: Tool): CFrame
	local attributeValue = tool:GetAttribute("DefaultGrip")
	if typeof(attributeValue) == "CFrame" then
		return attributeValue
	end
	return WeaponModelFactory.DEFAULT_GRIP
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

function WeaponViewController.PlayReloadAnimation(durationSeconds: number)
	local tool = getEquippedTool()
	if not tool then
		return
	end

	playReloadSound(tool)

	-- Dip down quickly, then spend the remaining time returning to grip —
	-- roughly mimics "pull mag out fast, seat new one more deliberately".
	local dipTime = math.clamp(durationSeconds * 0.35, 0.1, 0.6)
	local returnTime = math.max(durationSeconds - dipTime, 0.15)

	-- Pitch-follow yields Grip control for the whole reload sequence
	-- (plus a small buffer) so it doesn't immediately overwrite
	-- whichever tween is currently running.
	reloadingUntilClock = os.clock() + dipTime + returnTime + 0.1

	TweenService:Create(
		tool,
		TweenInfo.new(dipTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Grip = RELOAD_GRIP }
	):Play()

	task.delay(dipTime, function()
		-- Tool may have changed (unequipped, died, respawned) by the time
		-- this fires — re-fetch rather than trusting the earlier reference.
		local currentTool = getEquippedTool()
		if not currentTool then
			return
		end
		TweenService:Create(
			currentTool,
			TweenInfo.new(returnTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Grip = getDefaultGrip(currentTool) }
		):Play()
	end)
end

local function getPitchOffset(): CFrame
	local lookVector = camera.CFrame.LookVector
	local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))
	pitch = math.clamp(pitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	return CFrame.Angles(pitch, 0, 0)
end

local hasLoggedNoTool = false
local hasLoggedError = false
local lastDiagnosticPrintTime = 0

-- Reused across frames rather than creating a brand-new Tween every
-- single frame (cheaper, and avoids any risk of tween-creation churn
-- itself being the problem).
local pitchTween: Tween? = nil
local pitchTweenTool: Tool? = nil

--[[
	Switched from direct assignment (tool.Grip = newGrip) to a very
	short TweenService tween toward the same value. This is a direct
	test of a real hypothesis: the ONLY Grip-based effect confirmed to
	actually work visually anywhere in this codebase is the reload dip,
	which has always used TweenService — direct assignment was never
	actually verified to be visually respected the same way, and it
	produced an identical "the data is provably correct, nothing moves"
	symptom to the earlier IKControl attempt. If tweening fixes it, that
	confirms direct Grip assignment isn't visually honored the way
	tweened assignment is, at least for this equipped asset — if it
	doesn't fix it either, that rules this hypothesis out cleanly.
]]
local function updatePitchFollow()
	if os.clock() < reloadingUntilClock then
		return -- the reload tween currently owns Grip
	end
	local tool = getEquippedTool()
	if not tool then
		-- DIAGNOSTIC (temporary, logs once): confirms whether "no
		-- equipped Tool found" is why nothing happens, same check that
		-- caught a real issue elsewhere in this codebase before.
		if not hasLoggedNoTool then
			hasLoggedNoTool = true
			print("[WeaponView] updatePitchFollow: no equipped Tool found — skipping every frame.")
		end
		return
	end

	local defaultGrip = getDefaultGrip(tool)
	local pitchOffset = getPitchOffset()
	local newGrip = defaultGrip * pitchOffset

	local ok, err = pcall(function()
		if pitchTweenTool ~= tool then
			-- Weapon switched since the last frame — drop the old tween
			-- reference rather than trying to reuse one bound to a
			-- different (possibly destroyed) Tool instance.
			pitchTween = nil
			pitchTweenTool = tool
		end
		if pitchTween then
			pitchTween:Cancel()
		end
		pitchTween = TweenService:Create(tool, TweenInfo.new(0.08, Enum.EasingStyle.Linear), { Grip = newGrip })
		pitchTween:Play()
	end)

	if not ok then
		-- DIAGNOSTIC (temporary, logs once): the previous version
		-- silently swallowed this every single frame with zero
		-- visibility — if Grip assignment is erroring on the real
		-- equipped asset for any reason, this was invisible before.
		if not hasLoggedError then
			hasLoggedError = true
			warn("[WeaponView] tween-based Grip update errored: " .. tostring(err))
		end
		return
	end

	-- DIAGNOSTIC (throttled to once every 2s): confirms the computed
	-- values actually change as you look around, and that what we set
	-- matches what's actually on the Tool a moment later (in case
	-- something else is silently resetting Grip back after we set it).
	local now = os.clock()
	if now - lastDiagnosticPrintTime > 2 then
		lastDiagnosticPrintTime = now
		local pitchDegrees = math.deg(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)))
		print(
			("[WeaponView] (tween mode) pitch=%.1f deg | defaultGrip=%s | tweenTarget=%s | tool.Grip actually reads=%s"):format(
				pitchDegrees,
				tostring(defaultGrip),
				tostring(newGrip),
				tostring(tool.Grip)
			)
		)
	end
end

function WeaponViewController.Init()
	RunService.RenderStepped:Connect(updatePitchFollow)
end

return WeaponViewController
