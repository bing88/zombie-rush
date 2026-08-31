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

local UIController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local hpLabel: TextLabel
local hpBarFill: Frame
local ammoContainer: Frame
local ammoLabel: TextLabel
local reloadButton: TextButton
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
local confirmYesButton: TextButton
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

	tick("Top", UDim2.fromOffset(0, -(GAP + TICK_LENGTH / 2)), UDim2.fromOffset(THICKNESS, TICK_LENGTH))
	tick("Bottom", UDim2.fromOffset(0, GAP + TICK_LENGTH / 2), UDim2.fromOffset(THICKNESS, TICK_LENGTH))
	tick("Left", UDim2.fromOffset(-(GAP + TICK_LENGTH / 2), 0), UDim2.fromOffset(TICK_LENGTH, THICKNESS))
	tick("Right", UDim2.fromOffset(GAP + TICK_LENGTH / 2, 0), UDim2.fromOffset(TICK_LENGTH, THICKNESS))

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
	-- hit (white) or kill (gold), separate from the crosshair itself so
	-- the two can animate independently.
	hitmarker = Instance.new("Frame")
	hitmarker.Name = "Hitmarker"
	hitmarker.AnchorPoint = Vector2.new(0.5, 0.5)
	hitmarker.Position = UDim2.fromScale(0.5, 0.5)
	hitmarker.Size = UDim2.fromOffset(24, 24)
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

	-- HP bar (bottom-left)
	local hpBarBackground = Instance.new("Frame")
	hpBarBackground.Name = "HPBarBackground"
	hpBarBackground.Size = UDim2.fromOffset(240, 28)
	hpBarBackground.Position = UDim2.new(0, 20, 1, -60)
	hpBarBackground.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBarBackground.BorderSizePixel = 0
	hpBarBackground.Parent = screenGui

	hpBarFill = Instance.new("Frame")
	hpBarFill.Name = "HPBarFill"
	hpBarFill.Size = UDim2.fromScale(1, 1)
	hpBarFill.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	hpBarFill.BorderSizePixel = 0
	hpBarFill.Parent = hpBarBackground

	hpLabel = Instance.new("TextLabel")
	hpLabel.Name = "HPLabel"
	hpLabel.Size = UDim2.fromScale(1, 1)
	hpLabel.BackgroundTransparency = 1
	hpLabel.TextColor3 = Color3.new(1, 1, 1)
	hpLabel.Font = Enum.Font.GothamBold
	hpLabel.TextSize = 16
	hpLabel.Text = "100 / 100"
	hpLabel.Parent = hpBarBackground

	-- Coin counter (top-left)
	coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinLabel"
	coinLabel.Size = UDim2.fromOffset(180, 32)
	coinLabel.Position = UDim2.new(0, 20, 0, 20)
	coinLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	coinLabel.BackgroundTransparency = 0.3
	coinLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.TextSize = 18
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = "  Coins: 0"
	coinLabel.Parent = screenGui

	-- Wave counter (top-center)
	waveLabel = Instance.new("TextLabel")
	waveLabel.Name = "WaveLabel"
	waveLabel.AnchorPoint = Vector2.new(0.5, 0)
	waveLabel.Size = UDim2.fromOffset(320, 32)
	waveLabel.Position = UDim2.new(0.5, 0, 0, 20)
	waveLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	waveLabel.BackgroundTransparency = 0.3
	waveLabel.TextColor3 = Color3.new(1, 1, 1)
	waveLabel.Font = Enum.Font.GothamBold
	waveLabel.TextSize = 18
	waveLabel.Text = ""
	waveLabel.Parent = screenGui

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

	bossHPFill = Instance.new("Frame")
	bossHPFill.Name = "BossHPFill"
	bossHPFill.Size = UDim2.fromScale(1, 1)
	bossHPFill.BackgroundColor3 = Color3.fromRGB(160, 40, 200)
	bossHPFill.BorderSizePixel = 0
	bossHPFill.Parent = bossHPBackground

	bossHPLabel = Instance.new("TextLabel")
	bossHPLabel.Name = "BossHPLabel"
	bossHPLabel.Size = UDim2.fromScale(1, 1)
	bossHPLabel.BackgroundTransparency = 1
	bossHPLabel.TextColor3 = Color3.new(1, 1, 1)
	bossHPLabel.Font = Enum.Font.GothamBold
	bossHPLabel.TextSize = 16
	bossHPLabel.Text = "BOSS"
	bossHPLabel.Parent = bossHPBackground

	-- Ammo counter (bottom-right, above reload/fire buttons). Wrapped in a
	-- container Frame so the fire-shake tween can animate Position without
	-- fighting the label's own text updates.
	ammoContainer = Instance.new("Frame")
	ammoContainer.Name = "AmmoContainer"
	ammoContainer.AnchorPoint = Vector2.new(1, 1)
	ammoContainer.Size = UDim2.fromOffset(100, 32)
	ammoContainer.Position = AMMO_POSITION
	ammoContainer.BackgroundTransparency = 1
	ammoContainer.Parent = screenGui

	ammoLabel = Instance.new("TextLabel")
	ammoLabel.Name = "AmmoLabel"
	ammoLabel.Size = UDim2.fromScale(1, 1)
	ammoLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	ammoLabel.BackgroundTransparency = 0.3
	ammoLabel.TextColor3 = Color3.new(1, 1, 1)
	ammoLabel.Font = Enum.Font.GothamBold
	ammoLabel.TextSize = 13
	ammoLabel.TextWrapped = true
	ammoLabel.Text = "Pistol\n12 / 12"
	ammoLabel.Parent = ammoContainer

	local ammoCorner = Instance.new("UICorner")
	ammoCorner.CornerRadius = UDim.new(0, 4)
	ammoCorner.Parent = ammoLabel

	-- Reload button (works via mouse click or touch tap on any platform)
	reloadButton = Instance.new("TextButton")
	reloadButton.Name = "ReloadButton"
	reloadButton.AnchorPoint = Vector2.new(1, 1)
	reloadButton.Size = UDim2.fromOffset(110, 40)
	reloadButton.Position = UDim2.new(1, -150, 1, -150)
	reloadButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	reloadButton.BackgroundTransparency = 0.2
	reloadButton.TextColor3 = Color3.new(1, 1, 1)
	reloadButton.Font = Enum.Font.GothamBold
	reloadButton.TextSize = 16
	reloadButton.Text = "RELOAD"
	reloadButton.Parent = screenGui

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

	-- Death overlay (hidden by default)
	deathLabel = Instance.new("TextLabel")
	deathLabel.Name = "DeathLabel"
	deathLabel.Size = UDim2.fromScale(1, 0.15)
	deathLabel.Position = UDim2.fromScale(0, 0.4)
	deathLabel.BackgroundTransparency = 1
	deathLabel.TextColor3 = Color3.fromRGB(220, 40, 40)
	deathLabel.Font = Enum.Font.GothamBold
	deathLabel.TextSize = 40
	deathLabel.Text = "YOU DIED — respawning..."
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
	confirmDialog.Size = UDim2.fromOffset(320, 150)
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
	dialogTitle.Text = "Start the match now?"
	dialogTitle.ZIndex = 11
	dialogTitle.Parent = confirmDialog

	confirmYesButton = Instance.new("TextButton")
	confirmYesButton.Size = UDim2.fromOffset(130, 44)
	confirmYesButton.Position = UDim2.new(0, 20, 1, -60)
	confirmYesButton.BackgroundColor3 = Color3.fromRGB(60, 150, 70)
	confirmYesButton.TextColor3 = Color3.new(1, 1, 1)
	confirmYesButton.Font = Enum.Font.GothamBold
	confirmYesButton.TextSize = 16
	confirmYesButton.Text = "YES, START"
	confirmYesButton.ZIndex = 11
	confirmYesButton.Parent = confirmDialog

	local yesCorner = Instance.new("UICorner")
	yesCorner.CornerRadius = UDim.new(0, 6)
	yesCorner.Parent = confirmYesButton

	confirmNoButton = Instance.new("TextButton")
	confirmNoButton.Size = UDim2.fromOffset(130, 44)
	confirmNoButton.Position = UDim2.new(1, -150, 1, -60)
	confirmNoButton.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
	confirmNoButton.TextColor3 = Color3.new(1, 1, 1)
	confirmNoButton.Font = Enum.Font.GothamBold
	confirmNoButton.TextSize = 16
	confirmNoButton.Text = "NOT YET"
	confirmNoButton.ZIndex = 11
	confirmNoButton.Parent = confirmDialog

	local noCorner = Instance.new("UICorner")
	noCorner.CornerRadius = UDim.new(0, 6)
	noCorner.Parent = confirmNoButton

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

	-- Same row as Upgrades/Leaderboard, next available x-offset (20 + 120
	-- + 10 gap = 150 for Leaderboard, 150 + 140 + 10 = 300 for this one).
	viewToggleButton = Instance.new("TextButton")
	viewToggleButton.Name = "ViewToggleButton"
	viewToggleButton.Size = UDim2.fromOffset(100, 32)
	viewToggleButton.Position = UDim2.new(0, 300, 1, -100)
	viewToggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	viewToggleButton.BackgroundTransparency = 0.2
	viewToggleButton.TextColor3 = Color3.new(1, 1, 1)
	viewToggleButton.Font = Enum.Font.GothamBold
	viewToggleButton.TextSize = 14
	viewToggleButton.Text = "VIEW (V)"
	viewToggleButton.Parent = screenGui

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
	if not ammoLabel then
		return
	end
	if isReloading then
		ammoLabel.Text = weaponName .. "\nRELOADING..."
	else
		ammoLabel.Text = string.format("%s\n%d / %d", weaponName, current, max)
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
		coinLabel.Text = "  Coins: " .. tostring(amount)
	end
end

function UIController.SetWave(waveNumber: number, totalWaves: number, state: string)
	if not waveLabel then
		return
	end
	if state == "Boss" then
		waveLabel.Text = "BOSS FIGHT"
	elseif state == "Break" then
		waveLabel.Text = string.format("Wave %d / %d complete", waveNumber, totalWaves)
	else
		waveLabel.Text = string.format("Wave %d / %d", waveNumber, totalWaves)
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
function UIController.ShowStartConfirmation(onAnswer: (boolean) -> ())
	if not confirmBackdrop then
		return
	end

	local yesConnection: RBXScriptConnection
	local noConnection: RBXScriptConnection

	local function respond(answer: boolean)
		confirmBackdrop.Visible = false
		yesConnection:Disconnect()
		noConnection:Disconnect()
		onAnswer(answer)
	end

	yesConnection = confirmYesButton.Activated:Connect(function()
		respond(true)
	end)
	noConnection = confirmNoButton.Activated:Connect(function()
		respond(false)
	end)

	confirmBackdrop.Visible = true
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
	Flashes the crosshair hitmarker — white for a regular hit, gold for a
	kill. Auto-hides after a short beat regardless of further hits (each
	call restarts the timer rather than stacking).
]]
function UIController.ShowHitmarker(killed: boolean)
	if not hitmarker then
		return
	end
	local color = killed and Color3.fromRGB(255, 210, 90) or Color3.new(1, 1, 1)
	for _, child in hitmarker:GetChildren() do
		if child:IsA("Frame") then
			child.BackgroundColor3 = color
		end
	end
	hitmarker.Visible = true

	if hitmarkerHideThread then
		task.cancel(hitmarkerHideThread)
	end
	hitmarkerHideThread = task.delay(killed and 0.28 or 0.15, function()
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
