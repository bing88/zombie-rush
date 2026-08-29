--[[
	WeaponViewController.lua (ModuleScript)

	Purely cosmetic, local-only tool animation. Tweens the equipped Tool's
	Grip CFrame to fake a reload motion (weapon dips down and tilts, then
	returns) without touching the character's body Motor6Ds.

	Why Grip and not a real animation: a proper reload animation needs an
	authored KeyframeSequence published as an Animation asset (via Studio's
	Animation Editor), which isn't something this script environment can
	produce. Tweening Grip is a placeholder that reads reasonably as "doing
	something with the weapon" without needing an asset ID, and it doesn't
	fight Roblox's default Animate script — that script continuously drives
	the arm's idle/walk/run poses via the body's Motor6Ds, and manually
	overriding those directly would visibly stutter against it. Grip only
	affects how the Handle sits relative to the hand, so it layers on top
	cleanly regardless of whatever the arm is currently doing.

	This is local-only — it doesn't replicate to other clients. Worth
	revisiting with a real animation asset once art/animation exists.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)

local WeaponViewController = {}

local player = Players.LocalPlayer

local DEFAULT_GRIP = WeaponModelFactory.DEFAULT_GRIP
local RELOAD_GRIP = CFrame.new(0, -0.6, 0.3) * CFrame.Angles(math.rad(35), 0, 0)

local function getEquippedTool(): Tool?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Tool")
end

function WeaponViewController.PlayReloadAnimation(durationSeconds: number)
	local tool = getEquippedTool()
	if not tool then
		return
	end

	-- Dip down quickly, then spend the remaining time returning to grip —
	-- roughly mimics "pull mag out fast, seat new one more deliberately".
	local dipTime = math.clamp(durationSeconds * 0.35, 0.1, 0.6)
	local returnTime = math.max(durationSeconds - dipTime, 0.15)

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
			{ Grip = DEFAULT_GRIP }
		):Play()
	end)
end

return WeaponViewController
