--[[
	ShopController.lua (ModuleScript)

	Upgrades are purchasable anytime from this panel — no need to walk to
	a physical stall (unlike unlocking a new weapon for the first time,
	which stays at the physical Stall_Buy* parts per the original
	design; this panel only handles upgrading a weapon you already own).
	Server-side validation is identical either way — see ShopService's
	PurchaseUpgradeRequest handler, which reuses the exact same
	tryBuyUpgrade function the physical stalls call.

	Toggle with the U key or the on-screen "UPGRADES" tab button (for
	touch/mobile, where there's no keyboard).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local PurchaseUpgradeRequest = Remotes.PurchaseUpgradeRequest
local TOGGLE_KEY = Enum.KeyCode.U

local ShopController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local panel: Frame
local tabButton: TextButton
local rows: { [string]: { LevelLabel: TextLabel, BuyButton: TextButton } } = {}

local latestOwned: { [string]: boolean } = {}
local latestLevels: { [string]: number } = {}
local visible = false

local function setPanelVisible(value: boolean)
	visible = value
	if panel then
		panel.Visible = value
	end
end

local function refreshRow(weaponName: string)
	local row = rows[weaponName]
	if not row then
		return
	end

	local owned = latestOwned[weaponName] == true
	local level = latestLevels[weaponName] or 0

	if not owned then
		row.LevelLabel.Text = "Not unlocked"
		row.BuyButton.Text = "LOCKED"
		row.BuyButton.AutoButtonColor = false
		row.BuyButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		return
	end

	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	local nextLevel = level + 1

	if not weaponUpgrades or nextLevel > UpgradeConfig.MaxLevel then
		row.LevelLabel.Text = ("Level %d / %d (MAX)"):format(level, UpgradeConfig.MaxLevel)
		row.BuyButton.Text = "MAXED"
		row.BuyButton.AutoButtonColor = false
		row.BuyButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		return
	end

	local levelData = weaponUpgrades.Levels[nextLevel]
	row.LevelLabel.Text = ("Level %d / %d"):format(level, UpgradeConfig.MaxLevel)
	row.BuyButton.Text = ("Upgrade — %d coins"):format(levelData.Cost)
	row.BuyButton.AutoButtonColor = true
	row.BuyButton.BackgroundColor3 = Color3.fromRGB(60, 130, 70)
end

local function refreshAllRows()
	for weaponName in rows do
		refreshRow(weaponName)
	end
end

local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShopHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Tab button: always visible, toggles the panel. Bottom-left, clear
	-- of the HP bar / ammo / fire button clusters elsewhere on screen.
	tabButton = Instance.new("TextButton")
	tabButton.Name = "UpgradesTabButton"
	tabButton.Size = UDim2.fromOffset(120, 32)
	tabButton.Position = UDim2.new(0, 20, 1, -100)
	tabButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	tabButton.BackgroundTransparency = 0.2
	tabButton.TextColor3 = Color3.new(1, 1, 1)
	tabButton.Font = Enum.Font.GothamBold
	tabButton.TextSize = 14
	tabButton.Text = "UPGRADES (U)"
	tabButton.Parent = screenGui

	panel = Instance.new("Frame")
	panel.Name = "UpgradesPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 220)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 36)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Text = "Weapon Upgrades"
	title.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	local listHolder = Instance.new("Frame")
	listHolder.Size = UDim2.new(1, -20, 1, -46)
	listHolder.Position = UDim2.new(0, 10, 0, 40)
	listHolder.BackgroundTransparency = 1
	listHolder.Parent = panel
	layout.Parent = listHolder

	for _, weaponName in WeaponConfig.Order do
		local row = Instance.new("Frame")
		row.Name = weaponName .. "Row"
		row.Size = UDim2.new(1, 0, 0, 50)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.BackgroundTransparency = 0.2
		row.Parent = listHolder

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 6)
		rowCorner.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.4, 0, 1, 0)
		nameLabel.Position = UDim2.new(0, 10, 0, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 15
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = weaponName
		nameLabel.Parent = row

		local levelLabel = Instance.new("TextLabel")
		levelLabel.Size = UDim2.new(0.3, 0, 1, 0)
		levelLabel.Position = UDim2.new(0.4, 0, 0, 0)
		levelLabel.BackgroundTransparency = 1
		levelLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		levelLabel.Font = Enum.Font.Gotham
		levelLabel.TextSize = 13
		levelLabel.Text = "..."
		levelLabel.Parent = row

		local buyButton = Instance.new("TextButton")
		buyButton.Size = UDim2.new(0.3, -10, 1, -10)
		buyButton.Position = UDim2.new(0.7, 0, 0, 5)
		buyButton.BackgroundColor3 = Color3.fromRGB(60, 130, 70)
		buyButton.TextColor3 = Color3.new(1, 1, 1)
		buyButton.Font = Enum.Font.GothamBold
		buyButton.TextSize = 12
		buyButton.TextWrapped = true
		buyButton.Text = "..."
		buyButton.Parent = row

		local buyCorner = Instance.new("UICorner")
		buyCorner.CornerRadius = UDim.new(0, 4)
		buyCorner.Parent = buyButton

		buyButton.Activated:Connect(function()
			PurchaseUpgradeRequest:FireServer(weaponName)
		end)

		rows[weaponName] = { LevelLabel = levelLabel, BuyButton = buyButton }
	end

	tabButton.Activated:Connect(function()
		setPanelVisible(not visible)
	end)
end

function ShopController.Init()
	if not screenGui then
		buildUI()
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setPanelVisible(not visible)
		end
	end)
end

--[[
	Called from ClientMain when the WeaponsOwned remote fires (initial
	sync on join, and again after every successful purchase anywhere —
	physical stall or this panel).
]]
function ShopController.SetOwnedWeapons(owned: { [string]: boolean }, levels: { [string]: number })
	latestOwned = owned
	latestLevels = levels
	refreshAllRows()
end

return ShopController
