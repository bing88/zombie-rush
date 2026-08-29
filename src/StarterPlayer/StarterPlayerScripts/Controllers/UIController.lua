--[[
	UIController.lua (ModuleScript)

	Tier 0 UI is deliberately minimal per the reconciled plan:
	HP bar, ammo counter, crosshair, and a reload button. No wave counter,
	no coins, no menus — those arrive in Tier 1.

	The reload button exists mainly for mobile/touch, where there's no R
	key. Desktop can use either the button or the R key (see
	WeaponController).
]]

local Players = game:GetService("Players")

local UIController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local hpLabel: TextLabel
local hpBarFill: Frame
local ammoLabel: TextLabel
local reloadButton: TextButton
local fireButton: TextButton
local deathLabel: TextLabel

local function buildCrosshair(parent: ScreenGui)
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(20, 20)
	crosshair.BackgroundTransparency = 1
	crosshair.Parent = parent

	local vertical = Instance.new("Frame")
	vertical.Name = "Vertical"
	vertical.AnchorPoint = Vector2.new(0.5, 0.5)
	vertical.Position = UDim2.fromScale(0.5, 0.5)
	vertical.Size = UDim2.fromOffset(2, 14)
	vertical.BackgroundColor3 = Color3.new(1, 1, 1)
	vertical.BorderSizePixel = 0
	vertical.Parent = crosshair

	local horizontal = Instance.new("Frame")
	horizontal.Name = "Horizontal"
	horizontal.AnchorPoint = Vector2.new(0.5, 0.5)
	horizontal.Position = UDim2.fromScale(0.5, 0.5)
	horizontal.Size = UDim2.fromOffset(14, 2)
	horizontal.BackgroundColor3 = Color3.new(1, 1, 1)
	horizontal.BorderSizePixel = 0
	horizontal.Parent = crosshair
end

local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Tier0HUD"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = player:WaitForChild("PlayerGui")

	buildCrosshair(screenGui)

	-- HP bar
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

	-- Ammo counter
	ammoLabel = Instance.new("TextLabel")
	ammoLabel.Name = "AmmoLabel"
	ammoLabel.AnchorPoint = Vector2.new(1, 1)
	ammoLabel.Size = UDim2.fromOffset(160, 28)
	ammoLabel.Position = UDim2.new(1, -20, 1, -200)
	ammoLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	ammoLabel.BackgroundTransparency = 0.3
	ammoLabel.TextColor3 = Color3.new(1, 1, 1)
	ammoLabel.Font = Enum.Font.GothamBold
	ammoLabel.TextSize = 16
	ammoLabel.Text = "30 / 30"
	ammoLabel.Parent = screenGui

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

function UIController.SetAmmo(current: number, max: number, isReloading: boolean?)
	if not ammoLabel then
		return
	end
	if isReloading then
		ammoLabel.Text = "RELOADING..."
	else
		ammoLabel.Text = string.format("%d / %d", current, max)
	end
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

return UIController
