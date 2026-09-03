--[[
	UIController.lua (ModuleScript)

	Tier 1 UI stays "basic" per the reconciled plan (no fancy shop menu —
	that's physical ProximityPrompt stalls, see ShopService) but adds
	what the checklist calls for: wave counter, coin counter, and a boss
	HP bar, plus a small toast for shop feedback and a center banner for
	match state (waiting/starting/boss incoming/victory).
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UIIconConfig = require(ReplicatedStorage.Shared.UIIconConfig)

local UIController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local hpLabel: TextLabel
local hpBarFill: Frame
local ammoContainer: Frame
local ammoNameLabel: TextLabel
local ammoLabel: TextLabel
local reloadButton: TextButton
local ultimateButton: TextButton
local ultimateButtonStroke: UIStroke
local fireButton: TextButton
local deathLabel: TextLabel
local coinLabel: TextLabel
local waveLabel: TextLabel
local modifierLabel: TextLabel
local bossHPBackground: Frame
local bossHPFill: Frame
local bossHPLabel: TextLabel
local stateBanner: TextLabel
local toastLabel: TextLabel
local confirmBackdrop: Frame
local confirmDialog: Frame
local partySizeButtons: { [number]: TextButton } = {}
local partyWaitPanel: Frame
local partyWaitLabel: TextLabel
local partyExitButton: TextButton
local confirmNoButton: TextButton
local vignette: Frame
local hitmarker: Frame
local downedBanner: TextLabel
local objectiveContainer: Frame
local objectiveLabel: TextLabel
local objectiveBarFill: Frame
local scoreboardPanel: Frame
local scoreboardRowsHolder: Frame
local leaderboardPanel: Frame
local leaderboardRowsHolder: Frame
local leaderboardTabButton: TextButton
local leaderboardCloseCallback: (() -> ())? = nil
local viewToggleButton: TextButton

local toastHideThread: thread? = nil
local downedCountdownThread: thread? = nil
local hitmarkerHideThread: thread? = nil

-- Shifted well clear of Roblox's default touch jump button, which sits
-- right in the bottom-right corner — the fire button used to occupy
-- almost the exact same spot, so the jump button's arrow rendered
-- visibly through/behind it.
local AMMO_POSITION = UDim2.new(1, -150, 1, -200)

--[[
	Custom bottom-center weapon hotbar — replaces Roblox's default
	Backpack CoreGui (see UIController.Init's SetCoreGuiEnabled call),
	which only ever drew plain text-on-a-box slots. Reference-game-style:
	fixed-order numbered icon slots, a bright highlight ring on whichever
	slot is currently equipped, and slots for weapons the player doesn't
	own yet simply stay hidden (see SetOwnedWeapons/SetEquippedWeapon).
	Keyed by weapon name (== WeaponConfig.Order entries == Tool.Name).
]]
local weaponHotbarContainer: Frame
local weaponHotbarSlots: { [string]: { Button: TextButton, Stroke: UIStroke } } = {}
local HOTBAR_SLOT_SIZE = 60
local HOTBAR_SLOT_GAP = 8
local HOTBAR_BOTTOM_MARGIN = 20

-- Hitmarker sizes, read both where it's built and by ShowHitmarker,
-- which punches it up to the headshot size and back down again — see
-- that function for why a headshot changes size and not just color.
local HITMARKER_BASE_SIZE = 24
local HITMARKER_HEADSHOT_SIZE = 32

--[[
	Gapped tick-mark crosshair (four short lines + a center dot, with a
	gap around the middle) instead of a solid connected "+". A solid
	cross visually reads as overlapping/part of the weapon model in
	over-the-shoulder framing; four separate gapped segments read more
	clearly as a discrete UI element.
]]
local function buildCrosshair(parent: ScreenGui)
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(28, 28)
	crosshair.BackgroundTransparency = 1
	crosshair.Parent = parent

	local GAP = 4 -- distance from center each tick starts
	local TICK_LENGTH = 7
	local THICKNESS = 2

	local function tick(name: string, position: UDim2, size: UDim2)
		local line = Instance.new("Frame")
		line.Name = name
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = position
		line.Size = size
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BorderSizePixel = 0
		line.Parent = crosshair
	end

	-- NOTE: must be UDim2.new(0.5, offset, 0.5, offset) — NOT
	-- UDim2.fromOffset(offset, offset) (which is scale (0,0), i.e.
	-- measured from the crosshair Frame's top-left corner, not its
	-- center) — that mismatch was exactly why the ticks used to render
	-- ~14px up-and-left of CenterDot below instead of concentric with it.
	tick("Top", UDim2.new(0.5, 0, 0.5, -(GAP + TICK_LENGTH / 2)), UDim2.fromOffset(THICKNESS, TICK_LENGTH))
	tick("Bottom", UDim2.new(0.5, 0, 0.5, GAP + TICK_LENGTH / 2), UDim2.fromOffset(THICKNESS, TICK_LENGTH))
	tick("Left", UDim2.new(0.5, -(GAP + TICK_LENGTH / 2), 0.5, 0), UDim2.fromOffset(TICK_LENGTH, THICKNESS))
	tick("Right", UDim2.new(0.5, GAP + TICK_LENGTH / 2, 0.5, 0), UDim2.fromOffset(TICK_LENGTH, THICKNESS))

	local centerDot = Instance.new("Frame")
	centerDot.Name = "CenterDot"
	centerDot.AnchorPoint = Vector2.new(0.5, 0.5)
	centerDot.Position = UDim2.fromScale(0.5, 0.5)
	centerDot.Size = UDim2.fromOffset(2, 2)
	centerDot.BackgroundColor3 = Color3.new(1, 1, 1)
	centerDot.BorderSizePixel = 0
	centerDot.Parent = crosshair
end

local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Tier1HUD"
	screenGui.ResetOnSpawn = false
	-- false (default) so Roblox reserves space for its own top bar
	-- (menu/leave icons) — otherwise our top-anchored elements (coins,
	-- wave counter) render underneath/overlapping it.
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Uniformly scales every descendant's Size/Position offsets AND text
	-- size — the whole HUD was sized for desktop and read as oversized on
	-- narrower/mobile screens. This single number scales everything
	-- (buttons, labels,
	-- text) as one unit; retune this single number rather than touching
	-- individual element sizes if it needs further adjustment.
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.7
	uiScale.Parent = screenGui

	buildCrosshair(screenGui)

	-- Hitmarker: small X that flashes over the crosshair on a confirmed
	-- hit — white for a body shot, orange-red and larger for a headshot,
	-- gold for a kill (see ShowHitmarker). Separate from the crosshair
	-- itself so the two can animate independently.
	hitmarker = Instance.new("Frame")
	hitmarker.Name = "Hitmarker"
	hitmarker.AnchorPoint = Vector2.new(0.5, 0.5)
	hitmarker.Position = UDim2.fromScale(0.5, 0.5)
	hitmarker.Size = UDim2.fromOffset(HITMARKER_BASE_SIZE, HITMARKER_BASE_SIZE)
	hitmarker.BackgroundTransparency = 1
	hitmarker.Visible = false
	hitmarker.Parent = screenGui

	local function hitmarkerTick(rotation: number)
		local tick = Instance.new("Frame")
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.fromScale(0.5, 0.5)
		tick.Size = UDim2.fromOffset(3, 18)
		tick.Rotation = rotation
		tick.BackgroundColor3 = Color3.new(1, 1, 1)
		tick.BorderSizePixel = 0
		tick.Parent = hitmarker
	end
	hitmarkerTick(45)
	hitmarkerTick(-45)

	-- Full-screen damage vignette (hidden/transparent until SetDamageFlash).
	vignette = Instance.new("Frame")
	vignette.Name = "DamageVignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = Color3.fromRGB(180, 20, 20)
	vignette.BackgroundTransparency = 1
	vignette.ZIndex = 5
	vignette.Parent = screenGui

	-- HP bar — bottom-CENTER, sitting directly above the weapon hotbar
	-- (see buildWeaponHotbar below), matching the reference layout where
	-- the health readout sits right above the weapon slots rather than
	-- tucked in the bottom-left corner.
	local HOTBAR_WIDTH = (#WeaponConfig.Order * HOTBAR_SLOT_SIZE) + (math.max(#WeaponConfig.Order - 1, 0) * HOTBAR_SLOT_GAP)
	local hpBarBackground = Instance.new("Frame")
	hpBarBackground.Name = "HPBarBackground"
	hpBarBackground.AnchorPoint = Vector2.new(0.5, 1)
	hpBarBackground.Size = UDim2.fromOffset(math.max(HOTBAR_WIDTH, 200), 26)
	hpBarBackground.Position = UDim2.new(0.5, 0, 1, -(HOTBAR_BOTTOM_MARGIN + HOTBAR_SLOT_SIZE + 12))
	hpBarBackground.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	hpBarBackground.BackgroundTransparency = 0.15
	hpBarBackground.BorderSizePixel = 0
	hpBarBackground.Parent = screenGui

	local hpBarCorner = Instance.new("UICorner")
	hpBarCorner.CornerRadius = UDim.new(0, 6)
	hpBarCorner.Parent = hpBarBackground

	local hpBarPadding = Instance.new("Frame")
	hpBarPadding.Name = "HPBarPadding"
	hpBarPadding.BackgroundTransparency = 1
	hpBarPadding.Size = UDim2.new(1, -6, 1, -6)
	hpBarPadding.Position = UDim2.fromOffset(3, 3)
	hpBarPadding.Parent = hpBarBackground

	hpBarFill = Instance.new("Frame")
	hpBarFill.Name = "HPBarFill"
	hpBarFill.Size = UDim2.fromScale(1, 1)
	hpBarFill.BackgroundColor3 = Color3.fromRGB(90, 200, 90)
	hpBarFill.BorderSizePixel = 0
	hpBarFill.Parent = hpBarPadding

	local hpBarFillCorner = Instance.new("UICorner")
	hpBarFillCorner.CornerRadius = UDim.new(0, 4)
	hpBarFillCorner.Parent = hpBarFill

	hpLabel = Instance.new("TextLabel")
	hpLabel.Name = "HPLabel"
	hpLabel.Size = UDim2.fromScale(1, 1)
	hpLabel.BackgroundTransparency = 1
	hpLabel.TextColor3 = Color3.new(1, 1, 1)
	hpLabel.Font = Enum.Font.GothamBold
	hpLabel.TextSize = 14
	hpLabel.TextStrokeTransparency = 0.5
	hpLabel.Text = "100 / 100"
	hpLabel.Parent = hpBarBackground

	-- Coin counter — bottom-left, level with the HP bar/hotbar row
	-- (reference keeps currency low on screen, near the HUD it powers,
	-- rather than up with the wave/match-state readouts).
	coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinLabel"
	coinLabel.AnchorPoint = Vector2.new(0, 1)
	coinLabel.Size = UDim2.fromOffset(140, 32)
	coinLabel.Position = UDim2.new(0, 20, 1, -HOTBAR_BOTTOM_MARGIN)
	coinLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	coinLabel.BackgroundTransparency = 0.25
	coinLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.TextSize = 18
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = "  $0"
	coinLabel.Parent = screenGui

	local coinCorner = Instance.new("UICorner")
	coinCorner.CornerRadius = UDim.new(0, 6)
	coinCorner.Parent = coinLabel

	-- Wave counter (top-center) — pill-shaped like the reference's
	-- "Wave 3" chip rather than a plain square label.
	waveLabel = Instance.new("TextLabel")
	waveLabel.Name = "WaveLabel"
	waveLabel.AnchorPoint = Vector2.new(0.5, 0)
	waveLabel.Size = UDim2.fromOffset(200, 34)
	waveLabel.Position = UDim2.new(0.5, 0, 0, 20)
	waveLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	waveLabel.BackgroundTransparency = 0.2
	waveLabel.TextColor3 = Color3.new(1, 1, 1)
	waveLabel.Font = Enum.Font.GothamBold
	waveLabel.TextSize = 20
	waveLabel.Text = ""
	waveLabel.Parent = screenGui

	local waveCorner = Instance.new("UICorner")
	waveCorner.CornerRadius = UDim.new(1, 0)
	waveCorner.Parent = waveLabel

	-- Current wave modifier chip (directly below the wave counter).
	-- Distinct from stateBanner/FlashBanner — this persists for the
	-- whole wave rather than flashing and clearing.
	modifierLabel = Instance.new("TextLabel")
	modifierLabel.Name = "ModifierLabel"
	modifierLabel.AnchorPoint = Vector2.new(0.5, 0)
	modifierLabel.Size = UDim2.fromOffset(320, 22)
	modifierLabel.Position = UDim2.new(0.5, 0, 0, 54)
	modifierLabel.BackgroundTransparency = 1
	modifierLabel.TextColor3 = Color3.fromRGB(180, 210, 255)
	modifierLabel.Font = Enum.Font.Gotham
	modifierLabel.TextSize = 13
	modifierLabel.Text = ""
	modifierLabel.Parent = screenGui

	-- Boss HP bar (top-center, below wave label; hidden until a boss is active)
	bossHPBackground = Instance.new("Frame")
	bossHPBackground.Name = "BossHPBackground"
	bossHPBackground.AnchorPoint = Vector2.new(0.5, 0)
	bossHPBackground.Size = UDim2.fromOffset(420, 28)
	bossHPBackground.Position = UDim2.new(0.5, 0, 0, 82)
	bossHPBackground.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	bossHPBackground.BorderSizePixel = 0
	bossHPBackground.Visible = false
	bossHPBackground.Parent = screenGui

	local bossHPCorner = Instance.new("UICorner")
	bossHPCorner.CornerRadius = UDim.new(0, 6)
	bossHPCorner.Parent = bossHPBackground

	bossHPFill = Instance.new("Frame")
	bossHPFill.Name = "BossHPFill"
	bossHPFill.Size = UDim2.fromScale(1, 1)
	bossHPFill.BackgroundColor3 = Color3.fromRGB(160, 40, 200)
	bossHPFill.BorderSizePixel = 0
	bossHPFill.Parent = bossHPBackground

	local bossHPFillCorner = Instance.new("UICorner")
	bossHPFillCorner.CornerRadius = UDim.new(0, 6)
	bossHPFillCorner.Parent = bossHPFill

	bossHPLabel = Instance.new("TextLabel")
	bossHPLabel.Name = "BossHPLabel"
	bossHPLabel.Size = UDim2.fromScale(1, 1)
	bossHPLabel.BackgroundTransparency = 1
	bossHPLabel.TextColor3 = Color3.new(1, 1, 1)
	bossHPLabel.Font = Enum.Font.GothamBold
	bossHPLabel.TextSize = 16
	bossHPLabel.Text = "BOSS"
	bossHPLabel.Parent = bossHPBackground

	-- Ammo counter (bottom-right, above reload/fire buttons) — reference-
	-- style bordered box: a bright accent-colored outline (UIStroke) with
	-- the weapon's name on its own line and the ammo count below, rather
	-- than the old plain dark box. Wrapped in a container Frame so the
	-- fire-shake tween can animate Position without fighting the labels'
	-- own text updates.
	ammoContainer = Instance.new("Frame")
	ammoContainer.Name = "AmmoContainer"
	ammoContainer.AnchorPoint = Vector2.new(1, 1)
	ammoContainer.Size = UDim2.fromOffset(120, 52)
	ammoContainer.Position = AMMO_POSITION
	ammoContainer.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	ammoContainer.BackgroundTransparency = 0.15
	ammoContainer.Parent = screenGui

	local ammoCorner = Instance.new("UICorner")
	ammoCorner.CornerRadius = UDim.new(0, 8)
	ammoCorner.Parent = ammoContainer

	local ammoStroke = Instance.new("UIStroke")
	ammoStroke.Name = "AmmoStroke"
	ammoStroke.Thickness = 2
	ammoStroke.Color = Color3.fromRGB(255, 175, 60)
	ammoStroke.Parent = ammoContainer

	ammoNameLabel = Instance.new("TextLabel")
	ammoNameLabel.Name = "AmmoNameLabel"
	ammoNameLabel.Size = UDim2.new(1, 0, 0, 20)
	ammoNameLabel.Position = UDim2.fromOffset(0, 4)
	ammoNameLabel.BackgroundTransparency = 1
	ammoNameLabel.TextColor3 = Color3.fromRGB(255, 175, 60)
	ammoNameLabel.Font = Enum.Font.GothamBold
	ammoNameLabel.TextSize = 13
	ammoNameLabel.Text = "Pistol"
	ammoNameLabel.Parent = ammoContainer

	ammoLabel = Instance.new("TextLabel")
	ammoLabel.Name = "AmmoLabel"
	ammoLabel.Size = UDim2.new(1, 0, 0, 24)
	ammoLabel.Position = UDim2.fromOffset(0, 24)
	ammoLabel.BackgroundTransparency = 1
	ammoLabel.TextColor3 = Color3.new(1, 1, 1)
	ammoLabel.Font = Enum.Font.GothamBold
	ammoLabel.TextSize = 18
	ammoLabel.TextWrapped = true
	ammoLabel.Text = "12 / 12"
	ammoLabel.Parent = ammoContainer

	-- Right-side vertical stack of small circular icon buttons (View /
	-- Aim / Reload), reference-style — right edge aligned with the FIRE
	-- button/ammo box below via the same -150 offset, so the whole
	-- right-hand column reads as one deliberate group instead of buttons
	-- scattered at different indents. Helper keeps all three visually
	-- consistent (dark circle, thin accent stroke). IconId from
	-- UIIconConfig replaces the text glyph when set; otherwise the short
	-- bold word stands in.
	local function circleButton(name: string, text: string, bottomOffset: number, iconId: string?): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.AnchorPoint = Vector2.new(1, 1)
		button.Size = UDim2.fromOffset(56, 56)
		button.Position = UDim2.new(1, -150, 1, -bottomOffset)
		button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		button.BackgroundTransparency = 0.15
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 14
		button.TextScaled = true
		button.TextWrapped = true
		button.Text = text
		button.Parent = screenGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0) -- circular
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Color = Color3.fromRGB(90, 90, 90)
		stroke.Parent = button

		if UIIconConfig.IsSet(iconId) then
			button.Text = ""
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.Size = UDim2.fromOffset(32, 32)
			icon.Image = iconId :: string
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Parent = button
		end

		return button
	end

	-- Offsets start above the (now taller, bordered) ammo box — see
	-- AMMO_POSITION/ammoContainer above (bottom edge at distance 200,
	-- 52 tall, so its top edge sits at distance 252 from the bottom).
	reloadButton = circleButton("ReloadButton", "RELOAD", 272, UIIconConfig.Reload)

	-- Aim/ADS placeholder: built but hidden for now (no ADS mechanic yet
	-- to back it) — kept in the code, not deleted, so it's a one-line
	-- Visible flip to bring back once aim-down-sights is actually
	-- implemented, rather than having to rebuild this from scratch.
	local aimButton = circleButton("AimButton", "AIM", 342, nil)
	aimButton.BackgroundTransparency = 0.5
	aimButton.TextTransparency = 0.35
	aimButton.Visible = false
	aimButton.Activated:Connect(function()
		UIController.ShowToast("Aim mode coming soon", true)
	end)

	-- View now takes the Aim slot (342) since Aim is hidden — keeps the
	-- two remaining buttons contiguous instead of leaving a gap.
	viewToggleButton = circleButton("ViewToggleButton", "VIEW", 342, UIIconConfig.View)

	--[[
		Ultimate, continuing the same 70px pitch (56 tall + 14 gap).

		Exists because the ultimate was keyboard-only at first: the
		charge meter is drawn bottom-left by ComboController and `Q`
		spent it, which left touch players with a meter they could watch
		fill and never use. It's here rather than as a tap target on the
		meter itself for two reasons — this right-hand column is already
		where every touch action lives (fire/reload/view), and the
		bottom-LEFT is where Roblox's own movement thumbstick sits on
		mobile, so a button there would compete with walking.

		Colour is driven from outside via SetUltimateButtonState, since
		charge is ComboController's state, not this module's.
	]]
	ultimateButton = circleButton("UltimateButton", "ULT", 412, UIIconConfig.Ult)
	ultimateButtonStroke = ultimateButton:FindFirstChildOfClass("UIStroke") :: UIStroke

	-- Fire button: the ONLY manual firing trigger (see WeaponController —
	-- generic screen-tap/click firing was removed). Works via mouse click
	-- or touch hold on any platform. Positioned bottom-right for thumb
	-- reach on mobile, offset left of the corner to clear Roblox's
	-- default touch jump button (see AMMO_POSITION's comment).
	fireButton = Instance.new("TextButton")
	fireButton.Name = "FireButton"
	fireButton.AnchorPoint = Vector2.new(1, 1)
	fireButton.Size = UDim2.fromOffset(110, 110)
	fireButton.Position = UDim2.new(1, -150, 1, -20)
	fireButton.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
	fireButton.BackgroundTransparency = 0.25
	fireButton.TextColor3 = Color3.new(1, 1, 1)
	fireButton.Font = Enum.Font.GothamBold
	fireButton.TextSize = 18
	fireButton.Text = "FIRE"
	fireButton.Parent = screenGui

	local fireButtonCorner = Instance.new("UICorner")
	fireButtonCorner.CornerRadius = UDim.new(1, 0) -- circular
	fireButtonCorner.Parent = fireButton

	if UIIconConfig.IsSet(UIIconConfig.Fire) then
		fireButton.Text = ""
		local fireIcon = Instance.new("ImageLabel")
		fireIcon.Name = "Icon"
		fireIcon.BackgroundTransparency = 1
		fireIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		fireIcon.Position = UDim2.fromScale(0.5, 0.5)
		fireIcon.Size = UDim2.fromOffset(64, 64)
		fireIcon.Image = UIIconConfig.Fire
		fireIcon.ScaleType = Enum.ScaleType.Fit
		fireIcon.Parent = fireButton
	end

	-- Custom weapon hotbar (bottom-center, above where the HP bar sits) —
	-- replaces Roblox's default Backpack CoreGui (disabled in Init())
	-- with reference-style icon slots: numbered, name-labeled, with a
	-- bright ring around whichever weapon is currently equipped. Slots
	-- for un-owned weapons start hidden (see SetOwnedWeapons).
	weaponHotbarContainer = Instance.new("Frame")
	weaponHotbarContainer.Name = "WeaponHotbar"
	weaponHotbarContainer.AnchorPoint = Vector2.new(0.5, 1)
	weaponHotbarContainer.Size = UDim2.fromOffset(HOTBAR_WIDTH, HOTBAR_SLOT_SIZE)
	weaponHotbarContainer.Position = UDim2.new(0.5, 0, 1, -HOTBAR_BOTTOM_MARGIN)
	weaponHotbarContainer.BackgroundTransparency = 1
	weaponHotbarContainer.Parent = screenGui

	for index, weaponName in WeaponConfig.Order do
		local slot = Instance.new("TextButton")
		slot.Name = weaponName
		slot.AnchorPoint = Vector2.new(0, 1)
		slot.Size = UDim2.fromOffset(HOTBAR_SLOT_SIZE, HOTBAR_SLOT_SIZE)
		slot.Position = UDim2.fromOffset((index - 1) * (HOTBAR_SLOT_SIZE + HOTBAR_SLOT_GAP), HOTBAR_SLOT_SIZE)
		slot.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
		slot.BackgroundTransparency = 0.15
		slot.AutoButtonColor = false
		slot.Text = ""
		slot.Visible = weaponName == WeaponConfig.StartingWeapon -- real ownership comes from SetOwnedWeapons once the server replies
		slot.Parent = weaponHotbarContainer

		local slotCorner = Instance.new("UICorner")
		slotCorner.CornerRadius = UDim.new(0, 10)
		slotCorner.Parent = slot

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(255, 210, 80)
		stroke.Transparency = 1 -- only visible on the currently-equipped slot, see SetEquippedWeapon
		stroke.Parent = slot

		local keyBadge = Instance.new("TextLabel")
		keyBadge.Name = "KeyBadge"
		keyBadge.Size = UDim2.fromOffset(16, 16)
		keyBadge.Position = UDim2.fromOffset(3, 3)
		keyBadge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		keyBadge.BackgroundTransparency = 0.2
		keyBadge.TextColor3 = Color3.new(1, 1, 1)
		keyBadge.Font = Enum.Font.GothamBold
		keyBadge.TextSize = 11
		keyBadge.Text = tostring(index)
		keyBadge.ZIndex = 2
		keyBadge.Parent = slot

		local keyBadgeCorner = Instance.new("UICorner")
		keyBadgeCorner.CornerRadius = UDim.new(0, 4)
		keyBadgeCorner.Parent = keyBadge

		local weaponStats = WeaponConfig[weaponName]
		local iconId = if typeof(weaponStats) == "table" then (weaponStats :: any).IconId else nil
		if UIIconConfig.IsSet(iconId) then
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.new(0.5, 0, 0.5, -6)
			icon.Size = UDim2.fromOffset(40, 40)
			icon.Image = iconId :: string
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Parent = slot
		end

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "NameLabel"
		nameLabel.Size = UDim2.new(1, -6, 0, 14)
		nameLabel.Position = UDim2.new(0, 3, 1, -16)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 10
		nameLabel.TextWrapped = true
		nameLabel.Text = weaponName
		nameLabel.ZIndex = 2
		nameLabel.Parent = slot

		slot.Activated:Connect(function()
			UIController.EquipWeaponByName(weaponName)
		end)

		weaponHotbarSlots[weaponName] = { Button = slot, Stroke = stroke }
	end

	-- Death overlay (hidden by default)
	deathLabel = Instance.new("TextLabel")
	deathLabel.Name = "DeathLabel"
	deathLabel.Size = UDim2.fromScale(1, 0.15)
	deathLabel.Position = UDim2.fromScale(0, 0.4)
	deathLabel.BackgroundTransparency = 1
	deathLabel.TextColor3 = Color3.fromRGB(220, 40, 40)
	deathLabel.Font = Enum.Font.GothamBold
	deathLabel.TextSize = 40
	deathLabel.Text = "YOU DIED — back next wave"
	deathLabel.Visible = false
	deathLabel.Parent = screenGui

	-- Center banner for match state (Lobby/Starting/BossIncoming/Victory)
	stateBanner = Instance.new("TextLabel")
	stateBanner.Name = "StateBanner"
	stateBanner.AnchorPoint = Vector2.new(0.5, 0)
	stateBanner.Size = UDim2.fromScale(1, 0.1)
	stateBanner.Position = UDim2.new(0.5, 0, 0, 100)
	stateBanner.BackgroundTransparency = 1
	stateBanner.TextColor3 = Color3.fromRGB(255, 230, 150)
	stateBanner.Font = Enum.Font.GothamBold
	stateBanner.TextScaled = true
	stateBanner.TextStrokeTransparency = 0.2
	stateBanner.Text = ""
	stateBanner.Visible = false
	stateBanner.Parent = screenGui

	-- Shop/secret feedback toast (top-center, below wave/boss UI)
	toastLabel = Instance.new("TextLabel")
	toastLabel.Name = "ToastLabel"
	toastLabel.AnchorPoint = Vector2.new(0.5, 0)
	toastLabel.Size = UDim2.fromOffset(420, 30)
	toastLabel.Position = UDim2.new(0.5, 0, 0, 120)
	toastLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	toastLabel.BackgroundTransparency = 0.25
	toastLabel.Font = Enum.Font.GothamBold
	toastLabel.TextSize = 16
	toastLabel.Text = ""
	toastLabel.Visible = false
	toastLabel.Parent = screenGui

	-- Start-match confirmation dialog (hidden until the teleport pad
	-- prompts it). Modal-style: dims the background so it's clearly not
	-- part of the regular HUD.
	confirmBackdrop = Instance.new("Frame")
	confirmBackdrop.Name = "StartConfirmBackdrop"
	confirmBackdrop.Size = UDim2.fromScale(1, 1)
	confirmBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	confirmBackdrop.BackgroundTransparency = 0.5
	confirmBackdrop.Visible = false
	confirmBackdrop.ZIndex = 10
	confirmBackdrop.Parent = screenGui

	confirmDialog = Instance.new("Frame")
	confirmDialog.Name = "StartConfirmDialog"
	confirmDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	confirmDialog.Position = UDim2.fromScale(0.5, 0.5)
	confirmDialog.Size = UDim2.fromOffset(316, 190)
	confirmDialog.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	confirmDialog.ZIndex = 11
	confirmDialog.Parent = confirmBackdrop

	local dialogCorner = Instance.new("UICorner")
	dialogCorner.CornerRadius = UDim.new(0, 8)
	dialogCorner.Parent = confirmDialog

	local dialogTitle = Instance.new("TextLabel")
	dialogTitle.Size = UDim2.new(1, -20, 0, 50)
	dialogTitle.Position = UDim2.new(0, 10, 0, 15)
	dialogTitle.BackgroundTransparency = 1
	dialogTitle.TextColor3 = Color3.new(1, 1, 1)
	dialogTitle.Font = Enum.Font.GothamBold
	dialogTitle.TextSize = 18
	dialogTitle.TextWrapped = true
	dialogTitle.Text = "How many players?"
	dialogTitle.ZIndex = 11
	dialogTitle.Parent = confirmDialog

	-- Party size picker (1-4) plus a cancel. Replaces the old
	-- yes/no start confirmation now that portals let the host choose how
	-- many players the run is for (see WaveService's portal/party
	-- system). Buttons are created here once and reused; ShowStartConfirmation
	-- rewires their handlers per invocation.
	partySizeButtons = {}
	for size = 1, 4 do
		local button = Instance.new("TextButton")
		button.Name = ("PartySize%d"):format(size)
		button.Size = UDim2.fromOffset(62, 44)
		button.Position = UDim2.new(0, 18 + (size - 1) * 70, 0, 70)
		button.BackgroundColor3 = Color3.fromRGB(50, 110, 150)
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 20
		button.Text = tostring(size)
		button.ZIndex = 11
		button.Parent = confirmDialog

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		partySizeButtons[size] = button
	end

	confirmNoButton = Instance.new("TextButton")
	confirmNoButton.Size = UDim2.fromOffset(280, 36)
	confirmNoButton.Position = UDim2.new(0, 18, 1, -48)
	confirmNoButton.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
	confirmNoButton.TextColor3 = Color3.new(1, 1, 1)
	confirmNoButton.Font = Enum.Font.GothamBold
	confirmNoButton.TextSize = 15
	confirmNoButton.Text = "CANCEL"
	confirmNoButton.ZIndex = 11
	confirmNoButton.Parent = confirmDialog

	local noCorner = Instance.new("UICorner")
	noCorner.CornerRadius = UDim.new(0, 6)
	noCorner.Parent = confirmNoButton

	-- In-portal waiting panel: shown while standing inside a portal
	-- waiting for the party to fill / the countdown to run out. The exit
	-- button is the only way back out, since the portal is walled off
	-- (see MapBootstrap) — without it a player who changed their mind
	-- would be stuck until the match started.
	partyWaitPanel = Instance.new("Frame")
	partyWaitPanel.Name = "PartyWaitPanel"
	partyWaitPanel.AnchorPoint = Vector2.new(0.5, 0)
	partyWaitPanel.Position = UDim2.new(0.5, 0, 0, 90)
	partyWaitPanel.Size = UDim2.fromOffset(240, 84)
	partyWaitPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	partyWaitPanel.BackgroundTransparency = 0.25
	partyWaitPanel.Visible = false
	partyWaitPanel.Parent = screenGui

	local waitCorner = Instance.new("UICorner")
	waitCorner.CornerRadius = UDim.new(0, 8)
	waitCorner.Parent = partyWaitPanel

	partyWaitLabel = Instance.new("TextLabel")
	partyWaitLabel.Size = UDim2.new(1, -16, 0, 34)
	partyWaitLabel.Position = UDim2.new(0, 8, 0, 6)
	partyWaitLabel.BackgroundTransparency = 1
	partyWaitLabel.TextColor3 = Color3.new(1, 1, 1)
	partyWaitLabel.Font = Enum.Font.GothamBold
	partyWaitLabel.TextSize = 16
	partyWaitLabel.Text = "Waiting for players..."
	partyWaitLabel.Parent = partyWaitPanel

	partyExitButton = Instance.new("TextButton")
	partyExitButton.Name = "PartyExitButton"
	partyExitButton.Size = UDim2.new(1, -16, 0, 32)
	partyExitButton.Position = UDim2.new(0, 8, 0, 44)
	partyExitButton.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
	partyExitButton.TextColor3 = Color3.new(1, 1, 1)
	partyExitButton.Font = Enum.Font.GothamBold
	partyExitButton.TextSize = 15
	partyExitButton.Text = "EXIT PORTAL"
	partyExitButton.Parent = partyWaitPanel

	local exitCorner = Instance.new("UICorner")
	exitCorner.CornerRadius = UDim.new(0, 6)
	exitCorner.Parent = partyExitButton

	-- Downed banner (hidden by default) — separate from deathLabel since
	-- downed and true-death are visually/semantically distinct states.
	downedBanner = Instance.new("TextLabel")
	downedBanner.Name = "DownedBanner"
	downedBanner.Size = UDim2.fromScale(1, 0.15)
	downedBanner.Position = UDim2.fromScale(0, 0.4)
	downedBanner.BackgroundTransparency = 1
	downedBanner.TextColor3 = Color3.fromRGB(255, 90, 90)
	downedBanner.Font = Enum.Font.GothamBold
	downedBanner.TextScaled = true
	downedBanner.TextStrokeTransparency = 0.2
	downedBanner.Text = ""
	downedBanner.Visible = false
	downedBanner.Parent = screenGui

	-- Session objective widget (top-right, small, always visible)
	objectiveContainer = Instance.new("Frame")
	objectiveContainer.Name = "ObjectiveContainer"
	objectiveContainer.AnchorPoint = Vector2.new(1, 0)
	objectiveContainer.Size = UDim2.fromOffset(220, 40)
	objectiveContainer.Position = UDim2.new(1, -20, 0, 20)
	objectiveContainer.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	objectiveContainer.BackgroundTransparency = 0.3
	objectiveContainer.Parent = screenGui

	objectiveLabel = Instance.new("TextLabel")
	objectiveLabel.Size = UDim2.new(1, -10, 0, 18)
	objectiveLabel.Position = UDim2.new(0, 5, 0, 2)
	objectiveLabel.BackgroundTransparency = 1
	objectiveLabel.TextColor3 = Color3.new(1, 1, 1)
	objectiveLabel.Font = Enum.Font.Gotham
	objectiveLabel.TextSize = 12
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Left
	objectiveLabel.Text = "Objective: Headshot kills 0/10"
	objectiveLabel.Parent = objectiveContainer

	local objectiveBarBackground = Instance.new("Frame")
	objectiveBarBackground.Size = UDim2.new(1, -10, 0, 8)
	objectiveBarBackground.Position = UDim2.new(0, 5, 0, 24)
	objectiveBarBackground.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	objectiveBarBackground.BorderSizePixel = 0
	objectiveBarBackground.Parent = objectiveContainer

	objectiveBarFill = Instance.new("Frame")
	objectiveBarFill.Size = UDim2.fromScale(0, 1)
	objectiveBarFill.BackgroundColor3 = Color3.fromRGB(255, 210, 90)
	objectiveBarFill.BorderSizePixel = 0
	objectiveBarFill.Parent = objectiveBarBackground

	-- End-of-match scoreboard (hidden until UIController.ShowScoreboard)
	scoreboardPanel = Instance.new("Frame")
	scoreboardPanel.Name = "ScoreboardPanel"
	scoreboardPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	scoreboardPanel.Position = UDim2.fromScale(0.5, 0.5)
	scoreboardPanel.Size = UDim2.fromOffset(420, 280)
	scoreboardPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	scoreboardPanel.BackgroundTransparency = 0.1
	scoreboardPanel.Visible = false
	scoreboardPanel.ZIndex = 8
	scoreboardPanel.Parent = screenGui

	local scoreboardCorner = Instance.new("UICorner")
	scoreboardCorner.CornerRadius = UDim.new(0, 8)
	scoreboardCorner.Parent = scoreboardPanel

	local scoreboardTitle = Instance.new("TextLabel")
	scoreboardTitle.Size = UDim2.new(1, 0, 0, 36)
	scoreboardTitle.BackgroundTransparency = 1
	scoreboardTitle.TextColor3 = Color3.new(1, 1, 1)
	scoreboardTitle.Font = Enum.Font.GothamBold
	scoreboardTitle.TextSize = 20
	scoreboardTitle.ZIndex = 8
	scoreboardTitle.Text = "Match Results"
	scoreboardTitle.Parent = scoreboardPanel

	local headerRow = Instance.new("Frame")
	headerRow.Size = UDim2.new(1, -20, 0, 24)
	headerRow.Position = UDim2.new(0, 10, 0, 40)
	headerRow.BackgroundTransparency = 1
	headerRow.ZIndex = 8
	headerRow.Parent = scoreboardPanel

	local function headerCell(text: string, xScale: number, width: number)
		local cell = Instance.new("TextLabel")
		cell.Size = UDim2.new(width, 0, 1, 0)
		cell.Position = UDim2.new(xScale, 0, 0, 0)
		cell.BackgroundTransparency = 1
		cell.TextColor3 = Color3.fromRGB(180, 180, 180)
		cell.Font = Enum.Font.GothamBold
		cell.TextSize = 12
		cell.TextXAlignment = Enum.TextXAlignment.Left
		cell.ZIndex = 8
		cell.Text = text
		cell.Parent = headerRow
	end
	headerCell("PLAYER", 0, 0.4)
	headerCell("KILLS", 0.4, 0.2)
	headerCell("DAMAGE", 0.6, 0.2)
	headerCell("COINS", 0.8, 0.2)

	scoreboardRowsHolder = Instance.new("Frame")
	scoreboardRowsHolder.Size = UDim2.new(1, -20, 1, -110)
	scoreboardRowsHolder.Position = UDim2.new(0, 10, 0, 68)
	scoreboardRowsHolder.BackgroundTransparency = 1
	scoreboardRowsHolder.ZIndex = 8
	scoreboardRowsHolder.Parent = scoreboardPanel
	local scoreboardLayout = Instance.new("UIListLayout")
	scoreboardLayout.Padding = UDim.new(0, 4)
	scoreboardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scoreboardLayout.Parent = scoreboardRowsHolder

	-- Leaderboard panel (toggleable, best-wave-reached top 10)
	leaderboardTabButton = Instance.new("TextButton")
	leaderboardTabButton.Name = "LeaderboardTabButton"
	leaderboardTabButton.Size = UDim2.fromOffset(140, 32)
	leaderboardTabButton.Position = UDim2.new(0, 150, 1, -100)
	leaderboardTabButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	leaderboardTabButton.BackgroundTransparency = 0.2
	leaderboardTabButton.TextColor3 = Color3.new(1, 1, 1)
	leaderboardTabButton.Font = Enum.Font.GothamBold
	leaderboardTabButton.TextSize = 14
	leaderboardTabButton.Text = "LEADERBOARD (L)"
	leaderboardTabButton.Parent = screenGui

	-- (View toggle button itself now lives in the right-side circular
	-- icon stack built above, alongside Reload/Aim — see circleButton.)

	leaderboardPanel = Instance.new("Frame")
	leaderboardPanel.Name = "LeaderboardPanel"
	leaderboardPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	leaderboardPanel.Position = UDim2.fromScale(0.5, 0.5)
	leaderboardPanel.Size = UDim2.fromOffset(320, 340)
	leaderboardPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	leaderboardPanel.BackgroundTransparency = 0.1
	leaderboardPanel.Visible = false
	leaderboardPanel.Parent = screenGui

	local leaderboardCorner = Instance.new("UICorner")
	leaderboardCorner.CornerRadius = UDim.new(0, 8)
	leaderboardCorner.Parent = leaderboardPanel

	local leaderboardCloseButton = Instance.new("TextButton")
	leaderboardCloseButton.Name = "CloseButton"
	leaderboardCloseButton.AnchorPoint = Vector2.new(1, 0)
	leaderboardCloseButton.Position = UDim2.new(1, -8, 0, 8)
	leaderboardCloseButton.Size = UDim2.fromOffset(24, 24)
	leaderboardCloseButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	leaderboardCloseButton.TextColor3 = Color3.new(1, 1, 1)
	leaderboardCloseButton.Font = Enum.Font.GothamBold
	leaderboardCloseButton.TextSize = 16
	leaderboardCloseButton.Text = "X"
	leaderboardCloseButton.Parent = leaderboardPanel

	local leaderboardCloseCorner = Instance.new("UICorner")
	leaderboardCloseCorner.CornerRadius = UDim.new(0, 4)
	leaderboardCloseCorner.Parent = leaderboardCloseButton

	leaderboardCloseButton.Activated:Connect(function()
		if leaderboardCloseCallback then
			leaderboardCloseCallback()
		end
	end)

	local leaderboardTitle = Instance.new("TextLabel")
	leaderboardTitle.Size = UDim2.new(1, 0, 0, 36)
	leaderboardTitle.BackgroundTransparency = 1
	leaderboardTitle.TextColor3 = Color3.new(1, 1, 1)
	leaderboardTitle.Font = Enum.Font.GothamBold
	leaderboardTitle.TextSize = 18
	leaderboardTitle.Text = "Best Wave Reached"
	leaderboardTitle.Parent = leaderboardPanel

	leaderboardRowsHolder = Instance.new("Frame")
	leaderboardRowsHolder.Size = UDim2.new(1, -20, 1, -46)
	leaderboardRowsHolder.Position = UDim2.new(0, 10, 0, 40)
	leaderboardRowsHolder.BackgroundTransparency = 1
	leaderboardRowsHolder.Parent = leaderboardPanel
	local leaderboardLayout = Instance.new("UIListLayout")
	leaderboardLayout.Padding = UDim.new(0, 4)
	leaderboardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	leaderboardLayout.Parent = leaderboardRowsHolder
end

function UIController.Init()
	if not screenGui then
		buildUI()
	end
	-- Replaced by the custom icon hotbar built above (see buildUI's
	-- "Custom weapon hotbar" block) — the default plain text-box GUI
	-- would otherwise still draw underneath/alongside it.
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
end

function UIController.SetHP(current: number, max: number)
	if not hpLabel then
		return
	end
	current = math.max(current, 0)
	hpLabel.Text = string.format("%d / %d", current, max)
	hpBarFill.Size = UDim2.fromScale(max > 0 and (current / max) or 0, 1)
end

function UIController.SetAmmo(weaponName: string, current: number, max: number, isReloading: boolean?)
	if not ammoLabel or not ammoNameLabel then
		return
	end
	ammoNameLabel.Text = weaponName
	if isReloading then
		ammoLabel.Text = "RELOADING..."
	else
		ammoLabel.Text = string.format("%d / %d", current, max)
	end
end

--[[
	Small punch/shake on the ammo counter each time the local player
	fires — quick visual feedback tied to the shot itself, separate from
	whether it hit anything. Cheap: nudges the container's Position with
	a couple of quick tweens rather than a full spring/shake library.
]]
function UIController.ShakeAmmoUI()
	if not ammoContainer then
		return
	end

	local shakenPosition = AMMO_POSITION + UDim2.fromOffset(3, 2)

	local outTween = TweenService:Create(
		ammoContainer,
		TweenInfo.new(0.03, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = shakenPosition }
	)
	outTween:Play()
	outTween.Completed:Connect(function()
		TweenService:Create(
			ammoContainer,
			TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = AMMO_POSITION }
		):Play()
	end)
end

function UIController.SetCoins(amount: number)
	if coinLabel then
		coinLabel.Text = "  $" .. tostring(amount)
	end
end

--[[
	Fed by ClientMain from the exact same Remotes.WeaponsOwned event that
	already drives ShopController's shop rows — this just also toggles
	which hotbar slots are visible, so a weapon shows up in the hotbar
	the moment it's actually purchased/granted, no separate round trip.
]]
function UIController.SetOwnedWeapons(owned: { [string]: boolean })
	for weaponName, slot in weaponHotbarSlots do
		slot.Button.Visible = owned[weaponName] == true or weaponName == WeaponConfig.StartingWeapon
	end
end

-- Fed by WeaponController.OnWeaponEquipped (fires on every Tool.Equipped,
-- regardless of whether the switch came from this hotbar, a number key,
-- or Roblox's own equip handling) — keeps the highlight ring in sync
-- with whichever weapon is actually equipped right now.
function UIController.SetEquippedWeapon(weaponName: string)
	for name, slot in weaponHotbarSlots do
		slot.Stroke.Transparency = (name == weaponName) and 0 or 1
	end
end

--[[
	The actual equip action, shared by hotbar slot clicks and ClientMain's
	number-key handler (added because disabling the default Backpack
	CoreGui — see Init() — also removes its built-in 1/2/3 switching).
	Tools live directly under Backpack/Character, so no WeaponController
	round-trip is needed; Humanoid:EquipTool fires the same Tool.Equipped
	that WeaponController already listens to for its own state.
]]
function UIController.EquipWeaponByName(weaponName: string)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local backpack = player:FindFirstChild("Backpack")
	local tool = (character and character:FindFirstChild(weaponName)) or (backpack and backpack:FindFirstChild(weaponName))
	if tool and tool:IsA("Tool") then
		humanoid:EquipTool(tool)
	end
end

--[[
	totalWaves is unused now that runs are endless (WaveService passes
	the current wave number for it) — there's no fixed total to count
	toward, so the label just shows how deep this run has gotten.
	Kept in the signature so the remote's shape doesn't change.
]]
function UIController.SetWave(waveNumber: number, _totalWaves: number, state: string)
	if not waveLabel then
		return
	end
	if state == "Boss" then
		waveLabel.Text = string.format("BOSS — WAVE %d", waveNumber)
	elseif state == "Break" then
		waveLabel.Text = string.format("Wave %d complete", waveNumber)
	else
		waveLabel.Text = string.format("Wave %d", waveNumber)
	end
end

function UIController.SetBossHP(current: number, max: number)
	if not bossHPFill then
		return
	end
	bossHPBackground.Visible = true
	current = math.max(current, 0)
	bossHPFill.Size = UDim2.fromScale(max > 0 and (current / max) or 0, 1)
	bossHPLabel.Text = string.format("BOSS   %d / %d", current, max)
	if current <= 0 then
		task.delay(1.5, function()
			if bossHPBackground then
				bossHPBackground.Visible = false
			end
		end)
	end
end

local bannerFlashThread: thread? = nil

function UIController.SetGameStateBanner(text: string)
	if not stateBanner then
		return
	end
	-- A flash in progress owns the banner until its own timer clears it;
	-- persistent state text (Lobby/Starting/etc.) shouldn't stomp on it
	-- mid-flash only to have the flash's delayed clear erase it moments later.
	if bannerFlashThread then
		return
	end
	if text == "" then
		stateBanner.Visible = false
	else
		stateBanner.Visible = true
		stateBanner.Text = text
	end
end

--[[
	Shows a big banner for a fixed duration then clears itself, regardless
	of whether any further GameStateChanged event arrives — used for
	"Wave N incoming" announcements where the server doesn't send a
	separate "now clear the banner" event afterward.
]]
function UIController.FlashBanner(text: string, duration: number)
	if not stateBanner then
		return
	end
	if bannerFlashThread then
		task.cancel(bannerFlashThread)
	end
	stateBanner.Visible = true
	stateBanner.Text = text
	bannerFlashThread = task.delay(duration, function()
		bannerFlashThread = nil
		if stateBanner then
			stateBanner.Visible = false
		end
	end)
end

function UIController.ShowToast(message: string, success: boolean)
	if not toastLabel then
		return
	end
	toastLabel.Text = message
	toastLabel.TextColor3 = success and Color3.fromRGB(130, 230, 130) or Color3.fromRGB(230, 100, 100)
	toastLabel.Visible = true
	if toastHideThread then
		task.cancel(toastHideThread)
	end
	toastHideThread = task.delay(3, function()
		if toastLabel then
			toastLabel.Visible = false
		end
	end)
end

function UIController.OnReloadPressed(callback: () -> ())
	if reloadButton then
		-- Activated covers both mouse clicks and touch taps, unlike
		-- MouseButton1Click which is desktop-only.
		reloadButton.Activated:Connect(callback)
	end
end

function UIController.OnViewTogglePressed(callback: () -> ())
	if viewToggleButton then
		viewToggleButton.Activated:Connect(callback)
	end
end

function UIController.OnUltimatePressed(callback: () -> ())
	if ultimateButton then
		ultimateButton.Activated:Connect(callback)
	end
end

--[[
	Recolours the ULT button to match the charge meter's three states:
	dim while charging, green when ready to spend, and the ability's own
	colour while it's running.

	Deliberately stays VISIBLE and tappable when not ready rather than
	hiding or disabling itself — a button that disappears takes its own
	explanation with it, and on touch (where there's no `Q` and no
	tooltip) the dim ULT circle is the only thing telling a player the
	ability exists at all. Tapping it early is harmless: ComboController
	drops the press and the server re-checks regardless.
]]
function UIController.SetUltimateButtonState(ready: boolean, active: boolean, color: Color3?)
	if not ultimateButton then
		return
	end

	local accent = color or Color3.fromRGB(120, 255, 160)
	if active then
		ultimateButton.BackgroundColor3 = accent
		ultimateButton.BackgroundTransparency = 0.15
		ultimateButton.TextColor3 = Color3.fromRGB(20, 20, 20)
	elseif ready then
		ultimateButton.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		ultimateButton.BackgroundTransparency = 0.15
		ultimateButton.TextColor3 = accent
	else
		ultimateButton.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		ultimateButton.BackgroundTransparency = 0.5
		ultimateButton.TextColor3 = Color3.fromRGB(150, 150, 150)
	end

	if ultimateButtonStroke then
		ultimateButtonStroke.Color = (ready or active) and accent or Color3.fromRGB(90, 90, 90)
		ultimateButtonStroke.Thickness = (ready or active) and 2.5 or 1.5
	end
end

--[[
	Reports held/released rather than a single click, since firing needs
	to support full-auto (hold to keep firing), unlike Reload's one-shot
	Activated event. InputBegan/InputEnded on the button instance covers
	both mouse and touch.
]]
function UIController.OnFireButtonStateChanged(callback: (boolean) -> ())
	if not fireButton then
		return
	end
	fireButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			callback(true)
		end
	end)
	fireButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			callback(false)
		end
	end)
end

function UIController.ShowDeath()
	if not deathLabel then
		return
	end
	deathLabel.Visible = true
	task.delay(3, function()
		if deathLabel then
			deathLabel.Visible = false
		end
	end)
end

--[[
	Shows the Yes/No "start the match?" dialog triggered by stepping on
	the lobby teleport pad. onAnswer is called exactly once with true or
	false, then the dialog hides itself — callers don't need to hide it
	manually. Re-connects fresh button listeners each call rather than
	keeping one persistent connection, since Activated doesn't carry
	arguments and this is simpler than plumbing a mutable callback
	reference through a single long-lived connection.
]]
--[[
	Shows the party size picker. onAnswer receives the chosen size
	(1-4), or nil if the player cancelled. Connections are made per
	invocation and torn down on answer, so repeated opens don't stack
	duplicate handlers.
]]
function UIController.ShowStartConfirmation(onAnswer: (number?) -> ())
	if not confirmBackdrop then
		return
	end

	local connections: { RBXScriptConnection } = {}

	local function respond(size: number?)
		confirmBackdrop.Visible = false
		for _, connection in connections do
			connection:Disconnect()
		end
		onAnswer(size)
	end

	for size, button in partySizeButtons do
		table.insert(connections, button.Activated:Connect(function()
			respond(size)
		end))
	end
	table.insert(connections, confirmNoButton.Activated:Connect(function()
		respond(nil)
	end))

	confirmBackdrop.Visible = true
end

--[[
	Shows/hides the in-portal waiting panel. joined/target drive the
	label; the panel hides entirely when not in a party.
]]
function UIController.SetPartyStatus(inParty: boolean, joined: number, target: number)
	if not partyWaitPanel then
		return
	end
	partyWaitPanel.Visible = inParty
	if inParty and partyWaitLabel then
		partyWaitLabel.Text = (target > 1)
				and ("Waiting in portal — %d / %d"):format(joined, target)
			or "Starting solo..."
	end
end

function UIController.OnPartyExitPressed(callback: () -> ())
	if partyExitButton then
		partyExitButton.Activated:Connect(callback)
	end
end

--[[
	Brief full-screen red flash on taking damage. Fades back to fully
	transparent over a fixed duration regardless of how much damage was
	taken — intensity doesn't scale with damage amount, just a consistent
	"you got hit" pulse.
]]
function UIController.FlashDamageVignette()
	if not vignette then
		return
	end
	vignette.BackgroundTransparency = 0.6
	TweenService:Create(vignette, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

--[[
	Flashes the crosshair hitmarker. Three readable states, in priority
	order: gold for a kill, orange-red and visibly LARGER for a headshot
	that didn't kill, white for an ordinary body shot. Headshots also
	linger slightly longer than a body shot so the distinction survives
	sustained automatic fire, where markers otherwise blur together.

	Scaling the whole marker (not just recoloring it) is deliberate:
	during rifle fire the color alone is easy to miss, but a size punch
	registers peripherally. HITMARKER_BASE_SIZE is restored on every
	call so back-to-back hits of different kinds can't leave it stuck
	at the enlarged size.

	Auto-hides after a short beat regardless of further hits (each call
	restarts the timer rather than stacking).
]]
function UIController.ShowHitmarker(killed: boolean, headshot: boolean?)
	if not hitmarker then
		return
	end

	local isHeadshot = headshot == true
	local color = Color3.new(1, 1, 1)
	if killed then
		color = Color3.fromRGB(255, 210, 90)
	elseif isHeadshot then
		color = Color3.fromRGB(255, 140, 60)
	end

	for _, child in hitmarker:GetChildren() do
		if child:IsA("Frame") then
			child.BackgroundColor3 = color
		end
	end

	local size = (isHeadshot and not killed) and HITMARKER_HEADSHOT_SIZE or HITMARKER_BASE_SIZE
	hitmarker.Size = UDim2.fromOffset(size, size)
	hitmarker.Visible = true

	if hitmarkerHideThread then
		task.cancel(hitmarkerHideThread)
	end

	local holdSeconds = 0.15
	if killed then
		holdSeconds = 0.28
	elseif isHeadshot then
		holdSeconds = 0.22
	end
	hitmarkerHideThread = task.delay(holdSeconds, function()
		if hitmarker then
			hitmarker.Visible = false
		end
	end)
end

--[[
	Shows/hides the downed banner. When downing, starts a client-side
	countdown display seeded from the server's bleedOutSeconds — purely
	cosmetic ticking (the server owns the real timer independently), so a
	little client/server drift here doesn't matter.
]]
function UIController.SetDowned(isDowned: boolean, bleedOutSeconds: number)
	if not downedBanner then
		return
	end

	if downedCountdownThread then
		task.cancel(downedCountdownThread)
		downedCountdownThread = nil
	end

	if not isDowned then
		downedBanner.Visible = false
		return
	end

	downedBanner.Visible = true
	local remaining = bleedOutSeconds
	downedCountdownThread = task.spawn(function()
		while remaining > 0 do
			downedBanner.Text = ("DOWNED — wait for rescue (%ds)"):format(math.ceil(remaining))
			task.wait(1)
			remaining -= 1
		end
		-- Self-clearing fallback: hide the banner even if the server's
		-- own "no longer downed" signal (SetDowned(false, ...)) is
		-- delayed or never arrives for some reason — this previously
		-- fell through and left the banner permanently stuck on its
		-- last text ("...rescue (1s)") once the loop's countdown ran
		-- out, regardless of what actually happened server-side.
		downedBanner.Visible = false
		downedCountdownThread = nil
	end)
end

function UIController.SetObjective(progress: number, target: number, completed: boolean)
	if not objectiveLabel then
		return
	end
	if completed then
		objectiveLabel.Text = "Objective complete! +100 coins"
		objectiveLabel.TextColor3 = Color3.fromRGB(130, 230, 130)
	else
		objectiveLabel.Text = ("Objective: Headshot kills %d/%d"):format(progress, target)
		objectiveLabel.TextColor3 = Color3.new(1, 1, 1)
	end
	objectiveBarFill.Size = UDim2.fromScale(target > 0 and math.clamp(progress / target, 0, 1) or 0, 1)
end

function UIController.SetWaveModifier(name: string, description: string)
	if not modifierLabel then
		return
	end
	if name == "Normal" or name == "" then
		modifierLabel.Text = ""
	else
		modifierLabel.Text = ("MODIFIER: %s — %s"):format(name, description)
	end
end

--[[
	entries: array of {Name, Kills, DamageDealt, CoinsEarned}, already
	sorted by the server. Rebuilds the row list from scratch each call —
	this only fires once per match (Victory/Defeat), so no need for
	incremental diffing.
]]
function UIController.ShowScoreboard(entries: { { Name: string, Kills: number, DamageDealt: number, CoinsEarned: number } })
	if not scoreboardPanel then
		return
	end

	for _, child in scoreboardRowsHolder:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for i, entry in entries do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 22)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.ZIndex = 8
		row.Parent = scoreboardRowsHolder

		local function cell(text: string, xScale: number, width: number)
			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(width, 0, 1, 0)
			label.Position = UDim2.new(xScale, 0, 0, 0)
			label.BackgroundTransparency = 1
			label.TextColor3 = Color3.new(1, 1, 1)
			label.Font = Enum.Font.Gotham
			label.TextSize = 13
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.ZIndex = 8
			label.Text = text
			label.Parent = row
		end
		cell(entry.Name, 0, 0.4)
		cell(tostring(entry.Kills), 0.4, 0.2)
		cell(tostring(entry.DamageDealt), 0.6, 0.2)
		cell(tostring(entry.CoinsEarned), 0.8, 0.2)
	end

	scoreboardPanel.Visible = true
end

function UIController.HideScoreboard()
	if scoreboardPanel then
		scoreboardPanel.Visible = false
	end
end

function UIController.OnLeaderboardTabPressed(callback: () -> ())
	if leaderboardTabButton then
		leaderboardTabButton.Activated:Connect(callback)
	end
end

--[[
	Registers the callback fired when the panel's own close (X) button is
	pressed. Kept as a callback (rather than the panel just hiding itself
	directly) so ClientMain's tracked "is it open" state and the panel's
	actual visibility can never drift apart — there's exactly one place
	(ClientMain) that decides open/closed, and both the tab button and
	the X button just ask it to change that state rather than mutating
	Visible directly themselves.
]]
function UIController.OnLeaderboardClosePressed(callback: () -> ())
	leaderboardCloseCallback = callback
end

function UIController.SetLeaderboardVisible(visible: boolean)
	if leaderboardPanel then
		leaderboardPanel.Visible = visible
	end
end

function UIController.SetLeaderboardEntries(entries: { { Name: string, BestWave: number } })
	if not leaderboardRowsHolder then
		return
	end

	for _, child in leaderboardRowsHolder:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 22)
		empty.BackgroundTransparency = 1
		empty.TextColor3 = Color3.fromRGB(160, 160, 160)
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 13
		empty.Text = "No entries yet — be the first!"
		empty.Parent = leaderboardRowsHolder
		return
	end

	for i, entry in entries do
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 22)
		row.BackgroundTransparency = 1
		row.TextColor3 = Color3.new(1, 1, 1)
		row.Font = Enum.Font.Gotham
		row.TextSize = 13
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.LayoutOrder = i
		row.Text = ("%d. %s — Wave %d"):format(i, entry.Name, entry.BestWave)
		row.Parent = leaderboardRowsHolder
	end
end

return UIController
