--[[
	PerkShopController.lua (ModuleScript)

	The Robux perks panel: a "PERKS (P)" tab, a scrolling list of every
	CONFIGURED perk, and a buy button per row that asks the server to
	prompt the real game pass purchase.

	Two deliberate choices:

	  - Perks still on the placeholder GamePassId 0 are hidden entirely
	    rather than shown greyed out. A buy button that can't work is
	    worse than no button, and this way the panel is simply empty
	    until real game passes are configured (with a line explaining
	    that, so an empty panel doesn't look broken).
	  - The buy button sends only the perk KEY. The client never handles
	    game pass ids, so nothing here can be tricked into prompting a
	    purchase for an unrelated pass — the server validates the key and
	    owns the id (see PerkBootstrap).

	Ownership display is driven entirely by the server's PerksUpdated
	push, never assumed locally after a tap — a purchase can be
	cancelled, and the client has no authority over what's owned.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Remotes)
local PerkConfig = require(ReplicatedStorage.Shared.PerkConfig)

local PerkShopController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local panel: Frame
local tabButton: TextButton
local rowsHolder: ScrollingFrame
local emptyLabel: TextLabel

-- [perkKey] = { button = TextButton, owned = boolean }
local rowState: { [string]: { button: TextButton } } = {}
local ownedKeys: { [string]: boolean } = {}

local function setPanelVisible(visible: boolean)
	if panel then
		panel.Visible = visible
	end
end

local function refreshOwnershipDisplay()
	for perkKey, row in rowState do
		local isOwned = ownedKeys[perkKey] == true
		row.button.Text = isOwned and "OWNED" or (PerkConfig.GetPerk(perkKey) or {}).PriceText or "BUY"
		row.button.BackgroundColor3 = isOwned and Color3.fromRGB(45, 90, 45) or Color3.fromRGB(50, 110, 150)
		row.button.AutoButtonColor = not isOwned
	end
end

local function buildRow(perk, index: number)
	local row = Instance.new("Frame")
	row.Name = perk.Key
	row.Size = UDim2.new(1, -12, 0, 54)
	row.Position = UDim2.new(0, 6, 0, (index - 1) * 60)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	row.BackgroundTransparency = 0.2
	row.Parent = rowsHolder

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 6)
	rowCorner.Parent = row

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -110, 0, 22)
	title.Position = UDim2.new(0, 10, 0, 5)
	title.BackgroundTransparency = 1
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.Text = perk.DisplayName
	title.Parent = row

	local description = Instance.new("TextLabel")
	description.Size = UDim2.new(1, -110, 0, 20)
	description.Position = UDim2.new(0, 10, 0, 27)
	description.BackgroundTransparency = 1
	description.TextXAlignment = Enum.TextXAlignment.Left
	description.TextColor3 = Color3.fromRGB(190, 190, 190)
	description.Font = Enum.Font.Gotham
	description.TextSize = 12
	description.TextWrapped = true
	description.Text = perk.Description
	description.Parent = row

	local buyButton = Instance.new("TextButton")
	buyButton.Name = "Buy"
	buyButton.AnchorPoint = Vector2.new(1, 0.5)
	buyButton.Position = UDim2.new(1, -10, 0.5, 0)
	buyButton.Size = UDim2.fromOffset(88, 34)
	buyButton.BackgroundColor3 = Color3.fromRGB(50, 110, 150)
	buyButton.TextColor3 = Color3.new(1, 1, 1)
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextSize = 13
	buyButton.Text = perk.PriceText
	buyButton.Parent = row

	local buyCorner = Instance.new("UICorner")
	buyCorner.CornerRadius = UDim.new(0, 6)
	buyCorner.Parent = buyButton

	buyButton.Activated:Connect(function()
		if ownedKeys[perk.Key] then
			return
		end
		Remotes.RequestPerkPurchase:FireServer(perk.Key)
	end)

	rowState[perk.Key] = { button = buyButton }
end

function PerkShopController.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PerkShopGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.7 -- matches the rest of the HUD
	uiScale.Parent = screenGui

	tabButton = Instance.new("TextButton")
	tabButton.Name = "PerksTabButton"
	tabButton.Size = UDim2.fromOffset(100, 32)
	-- Continues the bottom-left button row (Upgrades 20, Leaderboard
	-- 150, View 300).
	tabButton.Position = UDim2.new(0, 410, 1, -100)
	tabButton.BackgroundColor3 = Color3.fromRGB(60, 45, 20)
	tabButton.BackgroundTransparency = 0.2
	tabButton.TextColor3 = Color3.fromRGB(255, 220, 130)
	tabButton.Font = Enum.Font.GothamBold
	tabButton.TextSize = 14
	tabButton.Text = "PERKS (P)"
	tabButton.Parent = screenGui

	panel = Instance.new("Frame")
	panel.Name = "PerksPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 320)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -8, 0, 8)
	closeButton.Size = UDim2.fromOffset(24, 24)
	closeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 16
	closeButton.Text = "X"
	closeButton.Parent = panel

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 4)
	closeCorner.Parent = closeButton
	closeButton.Activated:Connect(function()
		setPanelVisible(false)
	end)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 36)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 220, 130)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Text = "Perks"
	title.Parent = panel

	rowsHolder = Instance.new("ScrollingFrame")
	rowsHolder.Name = "Rows"
	rowsHolder.Position = UDim2.new(0, 0, 0, 42)
	rowsHolder.Size = UDim2.new(1, 0, 1, -50)
	rowsHolder.BackgroundTransparency = 1
	rowsHolder.BorderSizePixel = 0
	rowsHolder.ScrollBarThickness = 5
	rowsHolder.Parent = panel

	emptyLabel = Instance.new("TextLabel")
	emptyLabel.Size = UDim2.new(1, -24, 0, 80)
	emptyLabel.Position = UDim2.new(0, 12, 0, 10)
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
	emptyLabel.Font = Enum.Font.Gotham
	emptyLabel.TextSize = 13
	emptyLabel.TextWrapped = true
	emptyLabel.Visible = false
	emptyLabel.Text =
		"No perks are available yet.\n\nPerks need real Roblox Game Passes: create them in the Creator Dashboard, then paste each ID into PerkConfig.lua."
	emptyLabel.Parent = rowsHolder

	local shownCount = 0
	for _, perk in PerkConfig.Perks do
		-- Unconfigured perks (GamePassId 0) are hidden rather than shown
		-- as a dead button — see this file's header.
		if PerkConfig.IsConfigured(perk) then
			shownCount += 1
			buildRow(perk, shownCount)
		end
	end
	rowsHolder.CanvasSize = UDim2.new(0, 0, 0, shownCount * 60 + 6)
	emptyLabel.Visible = shownCount == 0

	refreshOwnershipDisplay()

	tabButton.Activated:Connect(function()
		setPanelVisible(not panel.Visible)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.P then
			setPanelVisible(not panel.Visible)
		end
	end)

	Remotes.PerksUpdated.OnClientEvent:Connect(function(keys: { string })
		ownedKeys = {}
		for _, key in keys do
			ownedKeys[key] = true
		end
		refreshOwnershipDisplay()
	end)
end

return PerkShopController
