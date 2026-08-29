--[[
	UIController.lua (ModuleScript)

	Tier 0 UI is deliberately minimal per the reconciled plan:
	"No UI beyond HP bar and ammo counter." No wave counter, no coins,
	no menus — those arrive in Tier 1.
]]

local Players = game:GetService("Players")

local UIController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local hpLabel: TextLabel
local hpBarFill: Frame
local ammoLabel: TextLabel
local deathLabel: TextLabel

local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Tier0HUD"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = player:WaitForChild("PlayerGui")

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
	ammoLabel.Size = UDim2.fromOffset(160, 28)
	ammoLabel.Position = UDim2.new(1, -180, 1, -60)
	ammoLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	ammoLabel.BackgroundTransparency = 0.3
	ammoLabel.TextColor3 = Color3.new(1, 1, 1)
	ammoLabel.Font = Enum.Font.GothamBold
	ammoLabel.TextSize = 16
	ammoLabel.Text = "30 / 30"
	ammoLabel.Parent = screenGui

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

function UIController.SetAmmo(current: number, max: number)
	if not ammoLabel then
		return
	end
	ammoLabel.Text = string.format("%d / %d", current, max)
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
