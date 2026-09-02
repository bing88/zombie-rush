--[[
	ComboController.lua

	HUD for the two aggression systems: the kill-streak readout (plan
	section 19) and the ultimate charge meter (section 20).

	Both live in one controller because they're one feedback loop on
	screen — the streak's tier is what makes the ultimate meter fill
	faster (see ComboConfig's ChargeMultiplier), and a player watching
	one is watching the other. Splitting them would mean two ScreenGuis
	stacked in the same corner, each having to know the other's height.

	OWN ScreenGui, not part of UIController's Tier1HUD, for the same
	reason RunDraftController has its own: UIController is a 1300-line
	module that rebuilds its HUD around respawns, and these two readouts
	have to survive being downed and revived without being caught up in
	that.

	THE CLIENT ANIMATES, THE SERVER DECIDES. The decay bar runs down
	locally from the DecaySeconds window in each ComboChanged message,
	and the Berserk countdown runs down locally from SecondsLeft —
	neither is streamed per frame. The server still owns the actual
	reset and the actual expiry; if the two ever disagree, the next
	message from the server wins. A remote per frame per player for a
	shrinking bar is exactly the kind of traffic that filled the event
	queue with the old per-hit ZombieHPChanged broadcast.

	THIS CONTROLLER APPLIES NO STATS. It only draws, and it sends
	ActivateUltimate on the keypress. The fire-rate scales the streak and
	Berserk grant are mirrored into WeaponController (which owns local
	fire prediction) from these same two remotes; the server enforces its
	own copy regardless.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local UltimateConfig = require(ReplicatedStorage.Shared.UltimateConfig)

local ComboChanged = Remotes.ComboChanged
local UltimateStateChanged = Remotes.UltimateStateChanged
local ActivateUltimate = Remotes.ActivateUltimate

local ComboController = {}

local player = Players.LocalPlayer

--[[
	`Q` on keyboard, and the ULT circle in UIController's right-hand
	button column on touch — both routed through TryActivate below.

	This started keyboard-only on the reasoning that first person runs
	in LockFirstPerson, which pins the mouse cursor to the middle of the
	screen and makes UI genuinely unclickable there (true, and why the
	draft uses number keys). That reasoning does not extend to touch:
	there's no cursor to lock, so a tap on a ScreenGui button registers
	in first person exactly like anywhere else. The result was a meter
	mobile players could watch fill and never spend.

	The button lives in UIController rather than here because that
	module owns the right-hand touch column (fire/reload/view) — a
	second module positioning buttons into the same strip is how two
	controllers end up overlapping, which already happened once with
	this file's own panels and the bottom-left coin/leaderboard row.
]]
local ULTIMATE_KEYCODE = Enum.KeyCode.Q
local ULTIMATE_KEY_LABEL = "Q"

local IDLE_COLOR = Color3.fromRGB(120, 120, 132)
local READY_COLOR = Color3.fromRGB(120, 255, 160)
local PANEL_BG = Color3.fromRGB(18, 18, 22)

--[[
	Left edge, stacked upward, with the ultimate meter below the streak.

	These offsets are measured from the bottom of the screen and they
	clear UIController's existing bottom-left occupants deliberately: the
	coin counter sits 20-52px up and the leaderboard tab 68-100px up
	(both at UIController's HOTBAR_BOTTOM_MARGIN), so the ultimate meter
	starts at 112 rather than at the corner. The bottom-CENTRE strip is
	the HP bar and weapon hotbar and the bottom-right is the three round
	action buttons, which leaves the left edge above the leaderboard tab
	as the only free column of this size. Anything added to either HUD
	near the bottom-left needs to be checked against the other.

	Ultimate below streak, not above: the meter is permanent and the
	streak panel appears and disappears (see renderCombo), so this way
	the thing that comes and goes does it at the top of the stack instead
	of shoving the permanent element up and down the screen.
]]
local PANEL_WIDTH = 196
local ULTIMATE_PANEL_HEIGHT = 78
local ULTIMATE_PANEL_BOTTOM = 112
local COMBO_PANEL_HEIGHT = 92
local COMBO_PANEL_BOTTOM = ULTIMATE_PANEL_BOTTOM + ULTIMATE_PANEL_HEIGHT + 8

local screenGui: ScreenGui
local comboPanel: Frame
local comboCountLabel: TextLabel
local comboTierLabel: TextLabel
local comboNextLabel: TextLabel
local comboBonusLabel: TextLabel
local decayBar: Frame

local ultimatePanel: Frame
local ultimateFill: Frame
local ultimateLabel: TextLabel
local ultimateHint: TextLabel

-- Locally-run decay animation. decayEndsAt is os.clock() when the streak
-- will hit zero if nothing else is killed; nil means no streak.
local decayEndsAt: number? = nil
local decayWindow = 0

-- Locally-run Berserk countdown, same idea.
local ultimateEndsAt: number? = nil
-- Read by the keybind handler to skip sending an obviously-doomed
-- request; the server re-checks both regardless.
local ultimateReady = false
local ultimateActive = false

-- Set by OnUltimateStateChanged so ClientMain can forward readiness to
-- UIController's ULT button without this module requiring it.
local ultimateStateCallback: ((boolean, boolean, Color3) -> ())? = nil

--[[
	"PRESS Q" or "TAP ULT" on the ready meter, matching how the player
	can actually spend it.

	Keyboard wins when both are available, because a Windows tablet or a
	phone with a paired keyboard reports TouchEnabled AND KeyboardEnabled
	— and on those, the key is the faster of the two. A pure-touch device
	is the only case that must never be told to press a key it doesn't
	have, which was the original bug.
]]
local function readyPrompt(): string
	if UserInputService.KeyboardEnabled then
		return "PRESS " .. ULTIMATE_KEY_LABEL
	elseif UserInputService.TouchEnabled then
		return "TAP ULT"
	end
	return "PRESS " .. ULTIMATE_KEY_LABEL
end

--[[
	The single activation path, shared by the `Q` handler and
	UIController's ULT button.

	The readiness check here is purely to avoid pointless traffic on a
	stray press — UltimateService re-validates charge, liveness, downed
	state and whether a match is even running, and is the only thing that
	can actually spend the meter.
]]
function ComboController.TryActivate()
	if ultimateReady and not ultimateActive then
		ActivateUltimate:FireServer()
	end
end

--[[
	Fires (ready, active, color) whenever the server pushes new ultimate
	state. ClientMain forwards it to UIController.SetUltimateButtonState;
	going through a callback rather than requiring UIController directly
	keeps the controllers independent, matching how ammo and hitmarkers
	are already wired.
]]
function ComboController.OnUltimateStateChanged(callback: (boolean, boolean, Color3) -> ())
	ultimateStateCallback = callback
	-- Push immediately: ClientMain registers this AFTER Init has already
	-- drawn the meter's starting state, so without this the button would
	-- keep its default styling until the first kill pushed an update.
	callback(ultimateReady, ultimateActive, UltimateConfig.Color)
end

local function styleCorner(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function styleStroke(instance: Instance, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = instance
	return stroke
end

--[[
	Streak readout: sits on the left, above the ultimate meter. Hidden
	entirely at a streak of zero rather than showing "0" — a permanent
	idle counter is noise, and the panel appearing is itself the signal
	that a streak has started.
]]
local function buildComboPanel()
	comboPanel = Instance.new("Frame")
	comboPanel.Name = "ComboPanel"
	comboPanel.AnchorPoint = Vector2.new(0, 1)
	comboPanel.Position = UDim2.new(0, 16, 1, -COMBO_PANEL_BOTTOM)
	comboPanel.Size = UDim2.fromOffset(PANEL_WIDTH, COMBO_PANEL_HEIGHT)
	comboPanel.BackgroundColor3 = PANEL_BG
	comboPanel.BackgroundTransparency = 0.25
	comboPanel.BorderSizePixel = 0
	comboPanel.Visible = false
	comboPanel.Parent = screenGui
	styleCorner(comboPanel, 10)
	styleStroke(comboPanel, Color3.fromRGB(70, 70, 80), 1.5)

	comboCountLabel = Instance.new("TextLabel")
	comboCountLabel.Name = "Count"
	comboCountLabel.Position = UDim2.new(0, 12, 0, 6)
	comboCountLabel.Size = UDim2.fromOffset(84, 40)
	comboCountLabel.BackgroundTransparency = 1
	comboCountLabel.Font = Enum.Font.GothamBlack
	comboCountLabel.TextSize = 34
	comboCountLabel.TextXAlignment = Enum.TextXAlignment.Left
	comboCountLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	comboCountLabel.Text = "0x"
	comboCountLabel.Parent = comboPanel
	styleStroke(comboCountLabel, Color3.fromRGB(0, 0, 0), 2)

	comboTierLabel = Instance.new("TextLabel")
	comboTierLabel.Name = "Tier"
	comboTierLabel.AnchorPoint = Vector2.new(1, 0)
	comboTierLabel.Position = UDim2.new(1, -12, 0, 12)
	comboTierLabel.Size = UDim2.fromOffset(96, 22)
	comboTierLabel.BackgroundTransparency = 1
	comboTierLabel.Font = Enum.Font.GothamBold
	comboTierLabel.TextSize = 16
	comboTierLabel.TextXAlignment = Enum.TextXAlignment.Right
	comboTierLabel.TextColor3 = Color3.fromRGB(255, 176, 64)
	comboTierLabel.Text = ""
	comboTierLabel.Parent = comboPanel
	styleStroke(comboTierLabel, Color3.fromRGB(0, 0, 0), 2)

	comboBonusLabel = Instance.new("TextLabel")
	comboBonusLabel.Name = "Bonus"
	comboBonusLabel.Position = UDim2.new(0, 12, 0, 44)
	comboBonusLabel.Size = UDim2.new(1, -24, 0, 16)
	comboBonusLabel.BackgroundTransparency = 1
	comboBonusLabel.Font = Enum.Font.Gotham
	comboBonusLabel.TextSize = 13
	comboBonusLabel.TextXAlignment = Enum.TextXAlignment.Left
	comboBonusLabel.TextColor3 = Color3.fromRGB(210, 210, 218)
	comboBonusLabel.Text = ""
	comboBonusLabel.Parent = comboPanel

	comboNextLabel = Instance.new("TextLabel")
	comboNextLabel.Name = "NextTier"
	comboNextLabel.Position = UDim2.new(0, 12, 0, 60)
	comboNextLabel.Size = UDim2.new(1, -24, 0, 14)
	comboNextLabel.BackgroundTransparency = 1
	comboNextLabel.Font = Enum.Font.Gotham
	comboNextLabel.TextSize = 12
	comboNextLabel.TextXAlignment = Enum.TextXAlignment.Left
	comboNextLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
	comboNextLabel.Text = ""
	comboNextLabel.Parent = comboPanel

	-- Decay track: the streak's remaining time, drained left to right.
	local decayTrack = Instance.new("Frame")
	decayTrack.Name = "DecayTrack"
	decayTrack.AnchorPoint = Vector2.new(0, 1)
	decayTrack.Position = UDim2.new(0, 12, 1, -10)
	decayTrack.Size = UDim2.new(1, -24, 0, 5)
	decayTrack.BackgroundColor3 = Color3.fromRGB(48, 48, 56)
	decayTrack.BorderSizePixel = 0
	decayTrack.Parent = comboPanel
	styleCorner(decayTrack, 3)

	decayBar = Instance.new("Frame")
	decayBar.Name = "DecayBar"
	decayBar.Size = UDim2.fromScale(1, 1)
	decayBar.BackgroundColor3 = Color3.fromRGB(255, 176, 64)
	decayBar.BorderSizePixel = 0
	decayBar.Parent = decayTrack
	styleCorner(decayBar, 3)
end

--[[
	Ultimate meter: bottom-left under the streak panel, always visible so
	the charge is readable even at zero — unlike the streak, it's a
	resource the player is saving, and a meter that only appears when
	full couldn't be saved toward.
]]
local function buildUltimatePanel()
	ultimatePanel = Instance.new("Frame")
	ultimatePanel.Name = "UltimatePanel"
	ultimatePanel.AnchorPoint = Vector2.new(0, 1)
	ultimatePanel.Position = UDim2.new(0, 16, 1, -ULTIMATE_PANEL_BOTTOM)
	ultimatePanel.Size = UDim2.fromOffset(PANEL_WIDTH, ULTIMATE_PANEL_HEIGHT)
	ultimatePanel.BackgroundColor3 = PANEL_BG
	ultimatePanel.BackgroundTransparency = 0.25
	ultimatePanel.BorderSizePixel = 0
	ultimatePanel.Parent = screenGui
	styleCorner(ultimatePanel, 10)
	styleStroke(ultimatePanel, Color3.fromRGB(70, 70, 80), 1.5)

	ultimateLabel = Instance.new("TextLabel")
	ultimateLabel.Name = "Name"
	ultimateLabel.Position = UDim2.new(0, 12, 0, 8)
	ultimateLabel.Size = UDim2.new(1, -24, 0, 20)
	ultimateLabel.BackgroundTransparency = 1
	ultimateLabel.Font = Enum.Font.GothamBold
	ultimateLabel.TextSize = 15
	ultimateLabel.TextXAlignment = Enum.TextXAlignment.Left
	ultimateLabel.TextColor3 = IDLE_COLOR
	ultimateLabel.Text = UltimateConfig.Name
	ultimateLabel.Parent = ultimatePanel
	styleStroke(ultimateLabel, Color3.fromRGB(0, 0, 0), 2)

	ultimateHint = Instance.new("TextLabel")
	ultimateHint.Name = "Hint"
	ultimateHint.Position = UDim2.new(0, 12, 0, 28)
	ultimateHint.Size = UDim2.new(1, -24, 0, 16)
	ultimateHint.BackgroundTransparency = 1
	ultimateHint.Font = Enum.Font.Gotham
	ultimateHint.TextSize = 12
	ultimateHint.TextXAlignment = Enum.TextXAlignment.Left
	ultimateHint.TextColor3 = Color3.fromRGB(150, 150, 160)
	ultimateHint.Text = UltimateConfig.Description
	ultimateHint.Parent = ultimatePanel

	local chargeTrack = Instance.new("Frame")
	chargeTrack.Name = "ChargeTrack"
	chargeTrack.AnchorPoint = Vector2.new(0, 1)
	chargeTrack.Position = UDim2.new(0, 12, 1, -12)
	chargeTrack.Size = UDim2.new(1, -24, 0, 12)
	chargeTrack.BackgroundColor3 = Color3.fromRGB(48, 48, 56)
	chargeTrack.BorderSizePixel = 0
	chargeTrack.Parent = ultimatePanel
	styleCorner(chargeTrack, 6)

	ultimateFill = Instance.new("Frame")
	ultimateFill.Name = "ChargeFill"
	ultimateFill.Size = UDim2.fromScale(0, 1)
	ultimateFill.BackgroundColor3 = IDLE_COLOR
	ultimateFill.BorderSizePixel = 0
	ultimateFill.Parent = chargeTrack
	styleCorner(ultimateFill, 6)
end

--[[
	Pulses the streak panel on a tier-up. Scale rather than colour so it
	reads in peripheral vision while the player is aiming somewhere else
	— the tier colour has already changed by the time this runs.
]]
local function flashTierUp()
	local scale = comboPanel:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = comboPanel
	end
	scale.Scale = 1.18
	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

local function renderCombo(state)
	local count = tonumber(state.Count) or 0
	if count <= 0 then
		comboPanel.Visible = false
		decayEndsAt = nil
		return
	end

	comboPanel.Visible = true
	comboCountLabel.Text = ("%dx"):format(count)

	local tierColor = typeof(state.TierColor) == "Color3" and state.TierColor or Color3.fromRGB(255, 176, 64)
	comboTierLabel.Text = state.TierName or ""
	comboTierLabel.TextColor3 = tierColor
	decayBar.BackgroundColor3 = tierColor

	-- Bonus line, built from whichever bonuses are actually non-zero, so
	-- the first tier doesn't advertise a "+0% DMG" it doesn't grant.
	local fireRateBonus = tonumber(state.FireRateBonus) or 0
	local damageBonus = tonumber(state.DamageBonus) or 0
	local parts = {}
	if fireRateBonus > 0 then
		table.insert(parts, ("+%d%% FIRE RATE"):format(math.floor(fireRateBonus * 100 + 0.5)))
	end
	if damageBonus > 0 then
		table.insert(parts, ("+%d%% DMG"):format(math.floor(damageBonus * 100 + 0.5)))
	end
	comboBonusLabel.Text = table.concat(parts, "   ")

	local nextAt = tonumber(state.NextTierAt)
	comboNextLabel.Text = nextAt and ("NEXT AT %d"):format(nextAt) or "MAX TIER"

	-- Restart the local decay animation. Uses the window the server
	-- sent rather than a local constant so the two can't drift.
	decayWindow = tonumber(state.DecaySeconds) or 4
	decayEndsAt = os.clock() + decayWindow

	if state.TierUp then
		flashTierUp()
	end
end

local function renderUltimate(state)
	local ultimateCharge = math.clamp(tonumber(state.Charge) or 0, 0, 1)
	ultimateReady = state.Ready == true
	ultimateActive = state.Active == true

	-- Mirror the state onto the touch button, which lives in
	-- UIController — see OnUltimateStateChanged.
	if ultimateStateCallback then
		ultimateStateCallback(ultimateReady, ultimateActive, UltimateConfig.Color)
	end

	if ultimateActive then
		ultimateEndsAt = os.clock() + (tonumber(state.SecondsLeft) or 0)
		-- Held full while active: the meter reads as "spending" rather
		-- than instantly empty, and the countdown replaces the charge as
		-- the number that matters for the next few seconds.
		ultimateFill.Size = UDim2.fromScale(1, 1)
		ultimateFill.BackgroundColor3 = UltimateConfig.Color
		ultimateLabel.TextColor3 = UltimateConfig.Color
		return
	end

	ultimateEndsAt = nil
	ultimateFill.Size = UDim2.fromScale(ultimateCharge, 1)

	if ultimateReady then
		ultimateFill.BackgroundColor3 = READY_COLOR
		ultimateLabel.TextColor3 = READY_COLOR
		ultimateLabel.Text = ("%s  —  %s"):format(UltimateConfig.Name, readyPrompt())
		ultimateHint.Text = UltimateConfig.Description
	else
		ultimateFill.BackgroundColor3 = IDLE_COLOR
		ultimateLabel.TextColor3 = IDLE_COLOR
		ultimateLabel.Text = UltimateConfig.Name
		ultimateHint.Text = ("%d%% charged"):format(math.floor(ultimateCharge * 100))
	end
end

function ComboController.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ComboHUD"
	screenGui.ResetOnSpawn = false -- must survive downed/revive and respawns
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = player:WaitForChild("PlayerGui")

	buildComboPanel()
	buildUltimatePanel()
	renderUltimate({ Charge = 0, Ready = false, Active = false })

	ComboChanged.OnClientEvent:Connect(function(state)
		if type(state) == "table" then
			renderCombo(state)
		end
	end)

	UltimateStateChanged.OnClientEvent:Connect(function(state)
		if type(state) == "table" then
			renderUltimate(state)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode ~= ULTIMATE_KEYCODE then
			return
		end
		ComboController.TryActivate()
	end)

	-- One frame loop drives both countdowns. Cheap: two clock reads and
	-- at most two property writes, and it's the alternative to the
	-- server streaming either bar.
	RunService.RenderStepped:Connect(function()
		if decayEndsAt then
			local remaining = decayEndsAt - os.clock()
			if remaining <= 0 then
				-- Emptied locally, but the panel stays until the server
				-- confirms the reset (ComboService's decay heartbeat,
				-- within 0.1s) so the two can't disagree about whether
				-- the streak is really gone.
				decayBar.Size = UDim2.fromScale(0, 1)
				decayEndsAt = nil
			else
				decayBar.Size = UDim2.fromScale(math.clamp(remaining / decayWindow, 0, 1), 1)
			end
		end

		if ultimateEndsAt then
			local remaining = ultimateEndsAt - os.clock()
			if remaining <= 0 then
				ultimateEndsAt = nil
				-- Leaves the visuals alone: the server's expiry push
				-- (UltimateService's heartbeat) is what returns the
				-- panel to its idle state, so this can't flicker it back
				-- early on a slightly fast client clock.
			else
				ultimateHint.Text = ("ACTIVE — %.1fs"):format(remaining)
			end
		end
	end)
end

return ComboController
