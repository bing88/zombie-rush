--[[
	WeaponViewController.lua (ModuleScript)

	Purely cosmetic, local-only tool animation.

	THE ACTUAL FIX, found via evidence not guessing: Tool.Grip does NOT
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
	visible effect. This module now targets that Weld directly instead.

	Everything below (reload dip/return, continuous camera-pitch
	tracking) works exactly as before conceptually — same math, same
	composition (restPose * offset) — just applied to the actual
	render-driving joint instead of the decorative property.

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

-- Rest C0 per weld instance — captured fresh each equip, since Roblox
-- creates a brand-new Weld object every time a Tool is equipped (the old
-- one is destroyed when unequipped/switched away from).
local restC0ByWeld: { [Weld]: CFrame } = {}
local activeTweens: { [Weld]: Tween } = {}

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

local function getRestC0(weld: Weld): CFrame
	local rest = restC0ByWeld[weld]
	if not rest then
		rest = weld.C0
		restC0ByWeld[weld] = rest
	end
	return rest
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

function WeaponViewController.PlayReloadAnimation(durationSeconds: number)
	local welds = findGripWelds()
	if #welds == 0 then
		return
	end

	playReloadSound()

	local dipTime = math.clamp(durationSeconds * 0.35, 0.1, 0.6)
	local returnTime = math.max(durationSeconds - dipTime, 0.15)

	-- Pitch-follow yields weld control for the whole reload sequence
	-- (plus a small buffer) so it doesn't immediately overwrite
	-- whichever tween is currently running.
	reloadingUntilClock = os.clock() + dipTime + returnTime + 0.1

	for _, weld in welds do
		local restC0 = getRestC0(weld)
		TweenService:Create(
			weld,
			TweenInfo.new(dipTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ C0 = restC0 * RELOAD_DIP_OFFSET }
		):Play()
	end

	task.delay(dipTime, function()
		-- Re-fetch rather than trusting the earlier references — the
		-- weapon may have changed (unequipped, died, respawned) by now,
		-- which would mean these exact Weld instances no longer exist.
		local currentWelds = findGripWelds()
		for _, weld in currentWelds do
			TweenService:Create(
				weld,
				TweenInfo.new(returnTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ C0 = getRestC0(weld) }
			):Play()
		end
	end)
end

local function getPitchOffset(): CFrame
	local lookVector = camera.CFrame.LookVector
	local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))
	pitch = math.clamp(pitch, -math.rad(MAX_PITCH_DEGREES), math.rad(MAX_PITCH_DEGREES))
	return CFrame.Angles(pitch, 0, 0)
end

local function updatePitchFollow()
	if os.clock() < reloadingUntilClock then
		return -- the reload tween currently owns the weld(s)
	end

	local welds = findGripWelds()
	if #welds == 0 then
		if not hasLoggedNoGrips then
			hasLoggedNoGrips = true
			print("[WeaponView] updatePitchFollow: no RightGrip/LeftGrip weld found — skipping every frame.")
		end
		return
	end

	local pitchOffset = getPitchOffset()

	local ok, err = pcall(function()
		for _, weld in welds do
			local restC0 = getRestC0(weld)
			local target = restC0 * pitchOffset

			local existingTween = activeTweens[weld]
			if existingTween then
				existingTween:Cancel()
			end
			local tween = TweenService:Create(weld, TweenInfo.new(0.08, Enum.EasingStyle.Linear), { C0 = target })
			activeTweens[weld] = tween
			tween:Play()
		end
	end)

	if not ok then
		warn("[WeaponView] weld pitch-follow errored: " .. tostring(err))
		return
	end

	-- DIAGNOSTIC (throttled to once every 3s): light-touch confirmation
	-- this is actually running and targeting real welds, kept in for
	-- now given how many rounds it took to find the right target.
	local now = os.clock()
	if now - lastDiagnosticPrintTime > 3 then
		lastDiagnosticPrintTime = now
		local pitchDegrees = math.deg(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)))
		print(("[WeaponView] pitch=%.1f deg | tracking %d grip weld(s)"):format(pitchDegrees, #welds))
	end
end

function WeaponViewController.Init()
	RunService.RenderStepped:Connect(updatePitchFollow)
end

return WeaponViewController
