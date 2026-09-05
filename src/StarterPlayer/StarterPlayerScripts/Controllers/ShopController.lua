--[[
	ShopController.lua (ModuleScript)

	The in-match ARMORY: buy a weapon you don't have, or upgrade one you
	do, from the same `U` panel. Both spend THIS RUN's cash.

	WAS UPGRADE-ONLY, WITH BUYS AT LOBBY STALLS. That split hid the
	actual decision — rifle vs two more pistol levels — because the two
	costs lived in different places. They're next to each other now so
	the player can see they compete for the same coins.

	The server owns every purchase (see ShopService). This panel only
	renders the state it's sent and fires a weapon name. A buy for a
	weapon the meta track hasn't unlocked, or a spend outside a match,
	is rejected server-side and toasted.

	Toggle with `U` or the on-screen SHOP tab (touch has no keyboard).
	The tab pulses during the between-wave break: that's when shopping
	is free (no zombies), and a still tab next to a 15-second draft is
	easy to forget exists.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local MetaConfig = require(ReplicatedStorage.Shared.MetaConfig)
local WeaponModelFactory = require(ReplicatedStorage.Shared.WeaponModelFactory)

local PurchaseUpgradeRequest = Remotes.PurchaseUpgradeRequest
local PurchaseWeaponRequest = Remotes.PurchaseWeaponRequest
local TOGGLE_KEY = Enum.KeyCode.U

local ShopController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local panel: Frame
local tabButton: TextButton
local tabStroke: UIStroke
local titleLabel: TextLabel
local cashLabel: TextLabel
local metaLabel: TextLabel
local hintLabel: TextLabel
local rows: { [string]: { StatusLabel: TextLabel, ActionButton: TextButton } } = {}

local latestOwned: { [string]: boolean } = {}
local latestLevels: { [string]: number } = {}
local latestAvailable: { [string]: boolean } = {}
local latestCash = 0
local equippedWeapon: string? = nil
local matchOpen = false
local inBreak = false
local visible = false
local tabPulse: Tween? = nil

local BUY_GREEN = Color3.fromRGB(60, 130, 70)
local UPGRADE_BLUE = Color3.fromRGB(50, 110, 160)
local LOCKED_GREY = Color3.fromRGB(60, 60, 60)
local READY_GOLD = Color3.fromRGB(255, 190, 60)

local function setPanelVisible(value: boolean)
	visible = value
	if panel then
		panel.Visible = value
	end
end

local function stopTabPulse()
	if tabPulse then
		tabPulse:Cancel()
		tabPulse = nil
	end
	if tabStroke then
		tabStroke.Color = Color3.fromRGB(90, 90, 90)
		tabStroke.Thickness = 1.5
	end
	if tabButton then
		tabButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	end
end

local function startTabPulse()
	stopTabPulse()
	if not tabStroke or not tabButton then
		return
	end
	tabButton.BackgroundColor3 = Color3.fromRGB(70, 55, 20)
	tabStroke.Color = READY_GOLD
	tabStroke.Thickness = 2.5
	tabPulse = TweenService:Create(tabStroke, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Thickness = 1.2,
	})
	tabPulse:Play()
end

--[[
	Sets a row's progress bar to level/MaxLevel, and its stat preview to
	what the next purchase actually grants. Both are cleared for states
	where there's nothing to preview (locked, maxed, out of match).
]]
local function setRowProgress(row, level: number)
	row.ProgressFill.Size = UDim2.fromScale(math.clamp(level / UpgradeConfig.MaxLevel, 0, 1), 1)
end

local function refreshRow(weaponName: string)
	local row = rows[weaponName]
	if not row then
		return
	end

	local stats = WeaponConfig[weaponName]
	local owned = latestOwned[weaponName] == true
	local available = latestAvailable[weaponName] ~= false
	local level = latestLevels[weaponName] or 0

	setRowProgress(row, owned and level or 0)
	row.StatLabel.Text = ""

	-- Only meaningful for a weapon actually in hand, so it's cleared for
	-- unowned rows regardless of what was equipped previously.
	local isEquipped = owned and equippedWeapon == weaponName
	row.EquippedStroke.Transparency = isEquipped and 0 or 1
	row.NameLabel.Text = isEquipped and (weaponName .. "  •") or weaponName

	if not matchOpen then
		row.StatusLabel.Text = owned and ("Lv %d — lobby"):format(level) or "Buy in a match"
		row.ActionButton.Text = "IN MATCH"
		row.ActionButton.AutoButtonColor = false
		row.ActionButton.BackgroundColor3 = LOCKED_GREY
		return
	end

	if not available then
		local required = MetaConfig.GetWeaponRequiredLevel(weaponName)
		row.StatusLabel.Text = ("Account Lv %d"):format(required)
		row.ActionButton.Text = "LOCKED"
		row.ActionButton.AutoButtonColor = false
		row.ActionButton.BackgroundColor3 = LOCKED_GREY
		return
	end

	if not owned then
		local price = stats and stats.Price or 0
		local canAfford = latestCash >= price
		row.StatusLabel.Text = "Not owned this run"
		-- Base damage as the at-a-glance comparison between weapons.
		-- Shotgun fires multiple pellets, so per-shot damage is what
		-- actually matters there, not per-pellet.
		if stats then
			local pellets = stats.Pellets or 1
			row.StatLabel.Text = pellets > 1
					and ("%d dmg x%d pellets"):format(stats.Damage, pellets)
				or ("%d dmg/shot"):format(stats.Damage)
		end
		row.ActionButton.Text = canAfford and ("BUY — %d"):format(price)
			or ("NEED %d"):format(price - latestCash)
		row.ActionButton.AutoButtonColor = canAfford
		row.ActionButton.BackgroundColor3 = canAfford and BUY_GREEN or LOCKED_GREY
		return
	end

	local weaponUpgrades = UpgradeConfig.Weapons[weaponName]
	local nextLevel = level + 1
	if not weaponUpgrades or nextLevel > UpgradeConfig.MaxLevel then
		row.StatusLabel.Text = ("Level %d / %d  MAX"):format(level, UpgradeConfig.MaxLevel)
		row.ActionButton.Text = "MAXED"
		row.ActionButton.AutoButtonColor = false
		row.ActionButton.BackgroundColor3 = LOCKED_GREY
		return
	end

	local levelData = weaponUpgrades.Levels[nextLevel]
	local cost = levelData.Cost
	local canAfford = latestCash >= cost
	row.StatusLabel.Text = ("Level %d / %d"):format(level, UpgradeConfig.MaxLevel)

	-- Concrete before/after numbers rather than an abstract "+1 level".
	-- Damage is shown as the real per-shot value (base * multiplier) so
	-- it's directly comparable to the buy rows above.
	if stats then
		local currentData = level > 0 and weaponUpgrades.Levels[level] or nil
		local currentMult = currentData and currentData.DamageMultiplier or 1
		local currentBonus = currentData and currentData.MagazineBonus or 0
		local nextMult = levelData.DamageMultiplier
		local nextBonus = levelData.MagazineBonus
		row.StatLabel.Text = ("dmg %d\u{2192}%d   mag %d\u{2192}%d"):format(
			math.floor(stats.Damage * currentMult),
			math.floor(stats.Damage * nextMult),
			stats.MagazineSize + currentBonus,
			stats.MagazineSize + nextBonus
		)
	end

	row.ActionButton.Text = canAfford and ("UPGRADE — %d"):format(cost)
		or ("NEED %d"):format(cost - latestCash)
	row.ActionButton.AutoButtonColor = canAfford
	row.ActionButton.BackgroundColor3 = canAfford and UPGRADE_BLUE or LOCKED_GREY
end

local function refreshAllRows()
	if cashLabel then
		cashLabel.Text = matchOpen and ("$%d this run"):format(latestCash) or "Shop opens in a match"
	end
	if hintLabel then
		if not matchOpen then
			hintLabel.Text = "Every match starts with the Pistol. Buys and upgrades reset when the run ends."
		elseif inBreak then
			hintLabel.Text = "Break — spend now, or save for the next wave."
		else
			hintLabel.Text = "Buys and upgrades last this run only. Rifle now, or more pistol levels?"
		end
	end
	for weaponName in rows do
		refreshRow(weaponName)
	end
end

local function requestAction(weaponName: string)
	if not matchOpen then
		return
	end
	if latestAvailable[weaponName] == false then
		return
	end
	if latestOwned[weaponName] == true then
		PurchaseUpgradeRequest:FireServer(weaponName)
	else
		PurchaseWeaponRequest:FireServer(weaponName)
	end
end

local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShopHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.7
	uiScale.Parent = screenGui

	tabButton = Instance.new("TextButton")
	tabButton.Name = "ShopTabButton"
	tabButton.Size = UDim2.fromOffset(120, 32)
	tabButton.Position = UDim2.new(0, 20, 1, -100)
	tabButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	tabButton.BackgroundTransparency = 0.2
	tabButton.TextColor3 = Color3.new(1, 1, 1)
	tabButton.Font = Enum.Font.GothamBold
	tabButton.TextSize = 14
	tabButton.Text = "SHOP (U)"
	tabButton.Parent = screenGui

	local tabCorner = Instance.new("UICorner")
	tabCorner.CornerRadius = UDim.new(0, 6)
	tabCorner.Parent = tabButton

	tabStroke = Instance.new("UIStroke")
	tabStroke.Color = Color3.fromRGB(90, 90, 90)
	tabStroke.Thickness = 1.5
	tabStroke.Parent = tabButton

	panel = Instance.new("Frame")
	panel.Name = "ShopPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 310)
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

	titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(0.5, 0, 0, 28)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	titleLabel.BackgroundTransparency = 1
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 18
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = "ARMORY"
	titleLabel.Parent = panel

	cashLabel = Instance.new("TextLabel")
	cashLabel.Size = UDim2.new(0.45, -20, 0, 28)
	cashLabel.Position = UDim2.new(0.5, 0, 0, 6)
	cashLabel.BackgroundTransparency = 1
	cashLabel.TextColor3 = Color3.fromRGB(255, 210, 90)
	cashLabel.Font = Enum.Font.GothamBold
	cashLabel.TextSize = 16
	cashLabel.TextXAlignment = Enum.TextXAlignment.Right
	cashLabel.Text = "$0 this run"
	cashLabel.Parent = panel

	metaLabel = Instance.new("TextLabel")
	metaLabel.Size = UDim2.new(1, -24, 0, 16)
	metaLabel.Position = UDim2.new(0, 12, 0, 32)
	metaLabel.BackgroundTransparency = 1
	metaLabel.TextColor3 = Color3.fromRGB(170, 190, 210)
	metaLabel.Font = Enum.Font.Gotham
	metaLabel.TextSize = 12
	metaLabel.TextXAlignment = Enum.TextXAlignment.Left
	metaLabel.Text = "Account Lv 1"
	metaLabel.Parent = panel

	hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.new(1, -24, 0, 18)
	hintLabel.Position = UDim2.new(0, 12, 0, 48)
	hintLabel.BackgroundTransparency = 1
	hintLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
	hintLabel.Font = Enum.Font.Gotham
	hintLabel.TextSize = 12
	hintLabel.TextXAlignment = Enum.TextXAlignment.Left
	hintLabel.TextWrapped = true
	hintLabel.Text = "Every match starts with the Pistol."
	hintLabel.Parent = panel

	local listHolder = Instance.new("Frame")
	listHolder.Size = UDim2.new(1, -20, 1, -80)
	listHolder.Position = UDim2.new(0, 10, 0, 70)
	listHolder.BackgroundTransparency = 1
	listHolder.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = listHolder

	for index, weaponName in WeaponConfig.Order do
		local row = Instance.new("Frame")
		row.Name = weaponName .. "Row"
		row.Size = UDim2.new(1, 0, 0, 66)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.BackgroundTransparency = 0.2
		row.LayoutOrder = index
		row.Parent = listHolder

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 6)
		rowCorner.Parent = row

		-- Highlight ring for the equipped weapon, mirroring how the
		-- hotbar marks the active slot (see UIController) so the two
		-- read as the same idea.
		local equippedStroke = Instance.new("UIStroke")
		equippedStroke.Color = Color3.fromRGB(255, 210, 90)
		equippedStroke.Thickness = 2
		equippedStroke.Transparency = 1 -- shown only on the equipped row
		equippedStroke.Parent = row

		-- Weapon icon from WeaponConfig.IconId (same art as the hotbar).
		local iconImage = WeaponModelFactory.GetIconImage(weaponName)
		local iconHolder = Instance.new("Frame")
		iconHolder.Name = "Icon"
		iconHolder.Size = UDim2.fromOffset(52, 52)
		iconHolder.Position = UDim2.new(0, 8, 0, 7)
		iconHolder.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
		iconHolder.BackgroundTransparency = 0.35
		iconHolder.Parent = row

		local iconCorner = Instance.new("UICorner")
		iconCorner.CornerRadius = UDim.new(0, 6)
		iconCorner.Parent = iconHolder

		local icon = Instance.new("ImageLabel")
		icon.Name = "Thumb"
		icon.Size = UDim2.new(1, -6, 1, -6)
		icon.Position = UDim2.new(0, 3, 0, 3)
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = iconImage or ""
		icon.Parent = iconHolder

		-- Weapons with no catalog asset render as the placeholder block
		-- in-game; show their initial rather than a broken image.
		local iconFallback = Instance.new("TextLabel")
		iconFallback.Size = UDim2.fromScale(1, 1)
		iconFallback.BackgroundTransparency = 1
		iconFallback.TextColor3 = Color3.fromRGB(150, 150, 160)
		iconFallback.Font = Enum.Font.GothamBold
		iconFallback.TextSize = 22
		iconFallback.Text = weaponName:sub(1, 1)
		iconFallback.Visible = iconImage == nil
		iconFallback.Parent = iconHolder

		local TEXT_LEFT = 68 -- clears the icon

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.4, 0, 0, 22)
		nameLabel.Position = UDim2.new(0, TEXT_LEFT, 0, 5)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 15
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = weaponName
		nameLabel.Parent = row

		local statusLabel = Instance.new("TextLabel")
		statusLabel.Size = UDim2.new(0.4, 0, 0, 16)
		statusLabel.Position = UDim2.new(0, TEXT_LEFT, 0, 26)
		statusLabel.BackgroundTransparency = 1
		statusLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
		statusLabel.Font = Enum.Font.Gotham
		statusLabel.TextSize = 12
		statusLabel.TextXAlignment = Enum.TextXAlignment.Left
		statusLabel.Text = "..."
		statusLabel.Parent = row

		-- Upgrade progress: makes "Level 4 / 10" legible at a glance, and
		-- shows how much runway a weapon still has before you sink more
		-- coins into it.
		local progressTrack = Instance.new("Frame")
		progressTrack.Name = "ProgressTrack"
		progressTrack.Size = UDim2.new(0.36, 0, 0, 4)
		progressTrack.Position = UDim2.new(0, TEXT_LEFT, 0, 45)
		progressTrack.BackgroundColor3 = Color3.fromRGB(60, 60, 66)
		progressTrack.BorderSizePixel = 0
		progressTrack.Parent = row

		local progressFill = Instance.new("Frame")
		progressFill.Name = "ProgressFill"
		progressFill.Size = UDim2.fromScale(0, 1)
		progressFill.BackgroundColor3 = UPGRADE_BLUE
		progressFill.BorderSizePixel = 0
		progressFill.Parent = progressTrack

		-- What the next purchase actually BUYS. Without this the upgrade
		-- button is just a price with no stated benefit, which makes
		-- "rifle vs two more pistol levels" hard to judge — the exact
		-- comparison this panel exists to surface.
		local statLabel = Instance.new("TextLabel")
		statLabel.Name = "StatPreview"
		statLabel.Size = UDim2.new(0.32, 0, 0, 30)
		statLabel.Position = UDim2.new(0.4, 4, 0, 14)
		statLabel.BackgroundTransparency = 1
		statLabel.TextColor3 = Color3.fromRGB(160, 210, 160)
		statLabel.Font = Enum.Font.Gotham
		statLabel.TextSize = 11
		statLabel.TextWrapped = true
		statLabel.TextXAlignment = Enum.TextXAlignment.Left
		statLabel.Text = ""
		statLabel.Parent = row

		local actionButton = Instance.new("TextButton")
		actionButton.Size = UDim2.new(0.28, -12, 1, -16)
		actionButton.Position = UDim2.new(0.72, 0, 0, 8)
		actionButton.BackgroundColor3 = BUY_GREEN
		actionButton.TextColor3 = Color3.new(1, 1, 1)
		actionButton.Font = Enum.Font.GothamBold
		actionButton.TextSize = 13
		actionButton.TextWrapped = true
		actionButton.Text = "..."
		actionButton.Parent = row

		local buyCorner = Instance.new("UICorner")
		buyCorner.CornerRadius = UDim.new(0, 4)
		buyCorner.Parent = actionButton

		actionButton.Activated:Connect(function()
			requestAction(weaponName)
		end)

		rows[weaponName] = {
			StatusLabel = statusLabel,
			ActionButton = actionButton,
			ProgressFill = progressFill,
			StatLabel = statLabel,
			EquippedStroke = equippedStroke,
			NameLabel = nameLabel,
		}
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
	owned / levels / available arrive together from ShopService so the
	panel can never show a BUY the server would refuse. available is
	optional for older messages: missing means "treat as unlocked".
]]
function ShopController.SetOwnedWeapons(
	owned: { [string]: boolean },
	levels: { [string]: number },
	available: { [string]: boolean }?
)
	latestOwned = owned
	latestLevels = levels
	if available then
		latestAvailable = available
	end
	refreshAllRows()
end

--[[
	Which weapon the player currently has out. Purely a visual cue in
	this panel — it doesn't gate any purchase (upgrading a weapon you
	aren't holding is perfectly valid), it just answers "which of these
	am I actually using right now?" while comparing upgrade costs.
]]
function ShopController.SetEquippedWeapon(weaponName: string)
	equippedWeapon = weaponName
	refreshAllRows()
end

function ShopController.SetCash(amount: number)
	latestCash = amount
	refreshAllRows()
end

function ShopController.SetMetaProgress(state)
	if type(state) ~= "table" or not metaLabel then
		return
	end
	local level = tonumber(state.Level) or 1
	local into = tonumber(state.XPIntoLevel) or 0
	local forNext = tonumber(state.XPForNextLevel)
	local gained = tonumber(state.XPGained)
	if forNext then
		metaLabel.Text = ("Account Lv %d  —  %d / %d XP"):format(level, into, forNext)
	else
		metaLabel.Text = ("Account Lv %d  —  MAX"):format(level)
	end
	if gained and gained > 0 then
		metaLabel.Text ..= ("   +%d XP"):format(gained)
	end
end

--[[
	matchOpen gates the buttons (server also refuses). inBreak only
	pulses the tab so the break reads as a shopping window without
	auto-opening over the draft cards.
]]
function ShopController.SetMatchState(isMatch: boolean, isBreak: boolean)
	matchOpen = isMatch
	inBreak = isBreak
	if inBreak and isMatch then
		startTabPulse()
	else
		stopTabPulse()
	end
	refreshAllRows()
end

return ShopController
