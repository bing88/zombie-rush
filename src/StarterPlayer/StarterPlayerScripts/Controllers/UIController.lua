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
local bossHPBackground: Frame
local bossHPFill: Frame
local bossHPLabel: TextLabel
local stateBanner: TextLabel
local toastLabel: TextLabel
local confirmBackdrop: Frame
local confirmDialog: Frame
local confirmYesButton: TextButton
local confirmNoButton: TextButton

local toastHideThread: thread? = nil

local AMMO_POSITION = UDim2.new(1, -20, 1, -200)

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

	buildCrosshair(screenGui)

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

	-- Boss HP bar (top-center, below wave label; hidden until a boss is active)
	bossHPBackground = Instance.new("Frame")
	bossHPBackground.Name = "BossHPBackground"
	bossHPBackground.AnchorPoint = Vector2.new(0.5, 0)
	bossHPBackground.Size = UDim2.fromOffset(420, 28)
	bossHPBackground.Position = UDim2.new(0.5, 0, 0, 58)
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
	reloadButton.Position = UDim2.new(1, -20, 1, -150)
	reloadButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	reloadButton.BackgroundTransparency = 0.2
	reloadButton.TextColor3 = Color3.new(1, 1, 1)
	reloadButton.Font = Enum.Font.GothamBold
	reloadButton.TextSize = 16
	reloadButton.Text = "RELOAD"
	reloadButton.Parent = screenGui

	-- Fire button: the ONLY manual firing trigger (see WeaponController —
	-- generic screen-tap/click firing was removed). Works via mouse click
	-- or touch hold on any platform. Positioned bottom-right for
	-- thumb reach on mobile.
	fireButton = Instance.new("TextButton")
	fireButton.Name = "FireButton"
	fireButton.AnchorPoint = Vector2.new(1, 1)
	fireButton.Size = UDim2.fromOffset(110, 110)
	fireButton.Position = UDim2.new(1, -20, 1, -20)
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
	toastLabel.Position = UDim2.new(0.5, 0, 0, 96)
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

return UIController
