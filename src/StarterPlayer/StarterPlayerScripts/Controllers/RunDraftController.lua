--[[
	RunDraftController.lua

	The between-wave upgrade draft UI: three cards, pick one, plus a
	compact always-on list of what the run has picked so far.

	The server owns the actual decision (see RunUpgradeService) — this
	only renders the offer it's sent and reports back which card was
	clicked. It never applies a stat itself, and it can't: a card the
	player wasn't offered is rejected server-side.

	OWN ScreenGui, not part of UIController's Tier1HUD. The draft is a
	modal, break-only overlay with a completely different lifetime from
	the combat HUD, and UIController is already a 1400-line module that
	rebuilds its HUD around respawns. Keeping this separate means the
	draft can't be accidentally hidden or destroyed by HUD state changes,
	and its own build/teardown stays readable in one file.

	CARDS ARE REBUILT PER OFFER rather than created once and reused: an
	offer can contain fewer than three cards late in a run (when most of
	the pool is maxed out, see RunUpgradeService's rollOffer), so the
	layout has to adapt to the count it's actually given instead of
	hiding leftover frames.

	Number keys 1-3 select alongside clicking, and the subtitle leads with
	the keys rather than the click for a reason: in first person the
	camera runs in LockFirstPerson, which pins the cursor to the middle
	of the screen, so the cards genuinely cannot be clicked in that mode
	(the same is already true of the shop and perk panels). The keybind
	is the path that works everywhere, and ClientMain yields 1-3 to this
	controller while a draft is open (see IsDraftOpen).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local UIIconConfig = require(ReplicatedStorage.Shared.UIIconConfig)
local RunUpgradeConfig = require(ReplicatedStorage.Shared.RunUpgradeConfig)

local RunUpgradeOffer = Remotes.RunUpgradeOffer
local RunUpgradeChosen = Remotes.RunUpgradeChosen
local RunUpgradesChanged = Remotes.RunUpgradesChanged
local RerollDraftRequest = Remotes.RerollDraftRequest

local RunDraftController = {}

local player = Players.LocalPlayer

-- Preview the draft card icons as soon as the client loads, without
-- waiting for a between-wave break. Set false when icon testing is done.
local SHOW_DRAFT_ON_START = false

local screenGui: ScreenGui
local draftPanel: Frame
local draftTitle: TextLabel
local cardRow: Frame
local rerollButton: TextButton
local buildTabButton: TextButton
local buildPanel: Frame
local buildList: Frame
local buildListTitle: TextLabel
local buildEmptyLabel: TextLabel

-- The offer currently on screen, so a number key can resolve to a card
-- id. Empty whenever no draft is open, which is also what makes the
-- 1-3 keybinds inert outside a draft.
local currentOffer: { { Id: string, Name: string, Description: string, Stacks: number?, MaxStacks: number?, IconId: string? } } = {}
local cardButtons: { TextButton } = {}
local buildPanelVisible = false
local ownedCount = 0
-- True only for the SHOW_DRAFT_ON_START preview (no server pending offer).
local isPreviewDraft = false
local latestCash = 0
local currentRerollCost = RunUpgradeConfig.RerollBaseCost

-- Coin label sits at (20, bottom-20) size 140x32 in UIController — this
-- tab sits immediately to its right so the bottom-left row reads
-- coins → RUN → (shop above).
local BUILD_TAB_POSITION = UDim2.new(0, 168, 1, -20)

local CARD_WIDTH = 190
local CARD_HEIGHT = 210
local CARD_GAP = 14
-- Full-bleed art under the key badge: the PNG already bakes name +
-- description, so the TextLabels only show when IconId is empty.
local CARD_ICON_TOP = 36
local CARD_ICON_BOTTOM_PAD = 10
local CARD_ICON_INSET = 10

local ACCENT = Color3.fromRGB(255, 190, 60)
local PANEL_BG = Color3.fromRGB(18, 18, 22)
local CARD_BG = Color3.fromRGB(30, 30, 36)

local function styleCorner(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function styleStroke(instance: Instance, color: Color3, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = instance
	return stroke
end

--[[
	Sends the pick and immediately closes the panel, without waiting for
	the server to confirm.

	Optimistic on purpose: the confirmation arrives as RunUpgradesChanged
	(which updates the build list), and leaving three clickable cards on
	screen for a round trip invites a second click on a different card —
	which the server would reject, correctly, leaving the player thinking
	the UI ate their input. Clearing currentOffer here also disarms the
	number keys for the same reason.
]]
local function buildPreviewOffer()
	local offer = {}
	for _, card in RunUpgradeConfig.Cards do
		table.insert(offer, {
			Id = card.Id,
			Name = card.Name,
			Description = card.Description,
			Stacks = 0,
			MaxStacks = card.MaxStacks,
			IconId = card.IconId,
		})
	end
	return offer
end

--[[
	Sends the pick and immediately closes the panel, without waiting for
	the server to confirm.

	Optimistic on purpose: the confirmation arrives as RunUpgradesChanged
	(which updates the build list), and leaving three clickable cards on
	screen for a round trip invites a second click on a different card —
	which the server would reject, correctly, leaving the player thinking
	the UI ate their input. Clearing currentOffer here also disarms the
	number keys for the same reason.
]]
local function choose(cardId: string)
	if #currentOffer == 0 then
		return
	end
	local preview = isPreviewDraft
	currentOffer = {}
	isPreviewDraft = false
	if not preview then
		RunUpgradeChosen:FireServer(cardId)
	end
	RunDraftController.Hide()
end

local function buildCard(index: number, card): TextButton
	local button = Instance.new("TextButton")
	button.Name = "DraftCard" .. tostring(index)
	button.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	button.BackgroundColor3 = CARD_BG
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	styleCorner(button, 10)
	local stroke = styleStroke(button, Color3.fromRGB(70, 70, 80), 1.5)

	local hasIcon = UIIconConfig.IsSet(card.IconId)

	-- Fallback name/description — visible only when there is no icon art.
	-- When IconId is set, the PNG already includes both strings, and the
	-- ImageLabel below covers this same region.
	local name = Instance.new("TextLabel")
	name.Name = "CardName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0, 10, 0, CARD_ICON_TOP + 24)
	name.Size = UDim2.new(1, -20, 0, 40)
	name.Font = Enum.Font.GothamBlack
	name.TextSize = 16
	name.TextColor3 = ACCENT
	name.TextWrapped = true
	name.TextYAlignment = Enum.TextYAlignment.Top
	name.Text = card.Name
	name.ZIndex = 1
	name.Visible = not hasIcon
	name.Parent = button

	local description = Instance.new("TextLabel")
	description.Name = "CardDescription"
	description.BackgroundTransparency = 1
	description.Position = UDim2.new(0, 12, 0, CARD_ICON_TOP + 72)
	description.Size = UDim2.new(1, -24, 0, 48)
	description.Font = Enum.Font.Gotham
	description.TextSize = 13
	description.TextColor3 = Color3.fromRGB(225, 225, 235)
	description.TextWrapped = true
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.Text = card.Description
	description.ZIndex = 1
	description.Visible = not hasIcon
	description.Parent = button

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, CARD_ICON_TOP)
	icon.Size = UDim2.new(1, -CARD_ICON_INSET * 2, 1, -(CARD_ICON_TOP + CARD_ICON_BOTTOM_PAD))
	icon.BackgroundColor3 = CARD_BG
	icon.BorderSizePixel = 0
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 2
	icon.Parent = button
	if hasIcon then
		-- Opaque card-colored fill so fallback text never peeks through
		-- letterboxing while the asset streams in.
		icon.BackgroundTransparency = 0
		icon.Image = card.IconId :: string
	else
		icon.Image = ""
		icon.BackgroundTransparency = 0.35
		icon.BackgroundColor3 = Color3.fromRGB(48, 48, 56)
		icon.Size = UDim2.fromOffset(64, 64)
		icon.Position = UDim2.new(0.5, 0, 0, CARD_ICON_TOP)
		styleCorner(icon, 8)
	end

	-- Keyboard hint above the art so it stays readable over the icon.
	local keyBadge = Instance.new("TextLabel")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0.5, 0)
	keyBadge.Position = UDim2.new(0.5, 0, 0, 8)
	keyBadge.Size = UDim2.fromOffset(26, 26)
	keyBadge.BackgroundColor3 = Color3.fromRGB(48, 48, 56)
	keyBadge.Font = Enum.Font.GothamBold
	keyBadge.TextSize = 14
	keyBadge.TextColor3 = Color3.fromRGB(200, 200, 210)
	keyBadge.Text = tostring(index)
	keyBadge.ZIndex = 3
	keyBadge.Parent = button
	styleCorner(keyBadge, 6)

	-- Stack readout, shown only for a card the player already owns —
	-- this is what turns "which of these three is best" into "do I
	-- deepen what I already have or branch", so it has to be visible at
	-- the moment of choosing rather than only in the build list.
	local stacks = card.Stacks or 0
	if stacks > 0 then
		local owned = Instance.new("TextLabel")
		owned.Name = "OwnedStacks"
		owned.BackgroundTransparency = 1
		owned.AnchorPoint = Vector2.new(0.5, 1)
		owned.Position = UDim2.new(0.5, 0, 1, -8)
		owned.Size = UDim2.new(1, -20, 0, 16)
		owned.Font = Enum.Font.GothamBold
		owned.TextSize = 11
		owned.TextColor3 = Color3.fromRGB(150, 200, 150)
		owned.Text = ("OWNED %d/%d"):format(stacks, card.MaxStacks or stacks)
		owned.ZIndex = 3
		owned.Parent = button
	end

	button.MouseEnter:Connect(function()
		stroke.Color = ACCENT
		button.BackgroundColor3 = Color3.fromRGB(42, 42, 50)
	end)
	button.MouseLeave:Connect(function()
		stroke.Color = Color3.fromRGB(70, 70, 80)
		button.BackgroundColor3 = CARD_BG
	end)
	button.Activated:Connect(function()
		choose(card.Id)
	end)

	return button
end

local function clearCards()
	for _, button in cardButtons do
		button:Destroy()
	end
	cardButtons = {}
end

--[[
	Refreshes the owned-upgrades list inside the RUN panel. The panel
	itself only opens when the player taps the tab next to coins — the
	list used to sit permanently bottom-left and overlapped the coin /
	shop row as soon as a few cards were drafted.
]]
local function setBuildPanelVisible(value: boolean)
	buildPanelVisible = value
	if buildPanel then
		buildPanel.Visible = value
	end
end

local function refreshBuildTabLabel()
	if not buildTabButton then
		return
	end
	if ownedCount > 0 then
		buildTabButton.Text = ("RUN (%d)"):format(ownedCount)
	else
		buildTabButton.Text = "RUN"
	end
end

local function renderBuildList(owned: { { Name: string, Stacks: number, IconId: string? } })
	for _, child in buildList:GetChildren() do
		if (child:IsA("TextLabel") or child:IsA("Frame")) and child ~= buildListTitle and child ~= buildEmptyLabel then
			child:Destroy()
		end
	end

	ownedCount = #owned
	refreshBuildTabLabel()

	if ownedCount == 0 then
		buildEmptyLabel.Visible = true
		buildList.Size = UDim2.new(1, -16, 0, 40)
		return
	end

	buildEmptyLabel.Visible = false
	local rowHeight = 22
	for index, entry in owned do
		local row = Instance.new("Frame")
		row.Name = "BuildEntry" .. tostring(index)
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, rowHeight)
		row.Position = UDim2.new(0, 0, 0, 22 + (index - 1) * rowHeight)
		row.Parent = buildList

		local iconX = 0
		if UIIconConfig.IsSet(entry.IconId) then
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.fromOffset(16, 16)
			icon.Position = UDim2.fromOffset(0, 3)
			icon.Image = entry.IconId :: string
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Parent = row
			iconX = 20
		end

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -iconX, 1, 0)
		label.Position = UDim2.fromOffset(iconX, 0)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 13
		label.TextColor3 = Color3.fromRGB(215, 215, 225)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = entry.Stacks > 1 and ("%s  x%d"):format(entry.Name, entry.Stacks) or entry.Name
		label.Parent = row
	end

	buildList.Size = UDim2.new(1, -16, 0, 24 + ownedCount * rowHeight)
	buildPanel.Size = UDim2.fromOffset(220, 44 + ownedCount * rowHeight)
end

function RunDraftController.Show(offer, rerollCost: number?)
	currentOffer = offer
	currentRerollCost = rerollCost or RunUpgradeConfig.RerollBaseCost
	clearCards()

	local count = #offer
	local rowWidth = count * CARD_WIDTH + math.max(0, count - 1) * CARD_GAP
	cardRow.Size = UDim2.fromOffset(rowWidth, CARD_HEIGHT)
	draftPanel.Size = UDim2.fromOffset(math.max(rowWidth + 48, 420), CARD_HEIGHT + 140)

	for index, card in offer do
		local button = buildCard(index, card)
		button.Position = UDim2.fromOffset((index - 1) * (CARD_WIDTH + CARD_GAP), 0)
		button.Parent = cardRow
		table.insert(cardButtons, button)
	end

	draftTitle.Text = isPreviewDraft and "ICON PREVIEW" or "CHOOSE AN UPGRADE"
	if rerollButton then
		local canReroll = not isPreviewDraft
		rerollButton.Visible = canReroll
		rerollButton.Text = ("REROLL — %d"):format(currentRerollCost)
		rerollButton.AutoButtonColor = latestCash >= currentRerollCost
		rerollButton.BackgroundColor3 = if latestCash >= currentRerollCost
			then Color3.fromRGB(70, 55, 20)
			else Color3.fromRGB(50, 50, 55)
	end
	draftPanel.Visible = true

	-- Short fade-in so the panel doesn't pop into existence over the
	-- wave-cleared moment.
	draftPanel.BackgroundTransparency = 1
	TweenService:Create(draftPanel, TweenInfo.new(0.18), { BackgroundTransparency = 0.12 }):Play()
end

function RunDraftController.Hide()
	currentOffer = {}
	isPreviewDraft = false
	draftPanel.Visible = false
	if rerollButton then
		rerollButton.Visible = false
	end
	clearCards()
end

function RunDraftController.SetCash(amount: number)
	latestCash = amount
	if rerollButton and rerollButton.Visible and #currentOffer > 0 then
		rerollButton.Text = ("REROLL — %d"):format(currentRerollCost)
		rerollButton.AutoButtonColor = latestCash >= currentRerollCost
		rerollButton.BackgroundColor3 = if latestCash >= currentRerollCost
			then Color3.fromRGB(70, 55, 20)
			else Color3.fromRGB(50, 50, 55)
	end
end

--[[
	True while cards are on screen awaiting a pick.

	ClientMain checks this before handling the number row, because 1-3
	are also the weapon-slot keys (the custom hotbar took over that
	binding when the default Backpack CoreGui was disabled). Without
	this, pressing 1 during a draft would both pick a card and swap
	weapons. The draft wins while it's open — it's modal, it's on a
	timer, and switching weapons mid-break can wait a second.
]]
function RunDraftController.IsDraftOpen(): boolean
	return #currentOffer > 0
end

function RunDraftController.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RunDraftGui"
	screenGui.ResetOnSpawn = false -- a draft must survive the mid-break respawn of a player who died last wave
	screenGui.IgnoreGuiInset = false
	screenGui.DisplayOrder = 5 -- above the combat HUD, which uses the default 0
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Matches UIController's own HUD scale so cards read at the same
	-- size as the rest of the interface on narrow screens.
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.7
	uiScale.Parent = screenGui

	draftPanel = Instance.new("Frame")
	draftPanel.Name = "DraftPanel"
	draftPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	draftPanel.Position = UDim2.fromScale(0.5, 0.42)
	draftPanel.Size = UDim2.fromOffset(3 * CARD_WIDTH + 2 * CARD_GAP + 48, CARD_HEIGHT + 140)
	draftPanel.BackgroundColor3 = PANEL_BG
	draftPanel.BackgroundTransparency = 0.12
	draftPanel.BorderSizePixel = 0
	draftPanel.Visible = false
	draftPanel.Parent = screenGui
	styleCorner(draftPanel, 14)
	styleStroke(draftPanel, ACCENT, 2)

	draftTitle = Instance.new("TextLabel")
	draftTitle.Name = "DraftTitle"
	draftTitle.BackgroundTransparency = 1
	draftTitle.Position = UDim2.new(0, 0, 0, 16)
	draftTitle.Size = UDim2.new(1, 0, 0, 26)
	draftTitle.Font = Enum.Font.GothamBlack
	draftTitle.TextSize = 20
	draftTitle.TextColor3 = ACCENT
	draftTitle.Text = "CHOOSE AN UPGRADE"
	draftTitle.Parent = draftPanel

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "DraftSubtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.new(0, 0, 0, 42)
	subtitle.Size = UDim2.new(1, 0, 0, 18)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 13
	subtitle.TextColor3 = Color3.fromRGB(170, 170, 180)
	subtitle.Text = "Press 1, 2 or 3 to choose. Reroll spends run cash."
	subtitle.Parent = draftPanel

	cardRow = Instance.new("Frame")
	cardRow.Name = "CardRow"
	cardRow.AnchorPoint = Vector2.new(0.5, 0)
	cardRow.Position = UDim2.new(0.5, 0, 0, 70)
	cardRow.Size = UDim2.fromOffset(3 * CARD_WIDTH + 2 * CARD_GAP, CARD_HEIGHT)
	cardRow.BackgroundTransparency = 1
	cardRow.Parent = draftPanel

	rerollButton = Instance.new("TextButton")
	rerollButton.Name = "RerollButton"
	rerollButton.AnchorPoint = Vector2.new(0.5, 1)
	rerollButton.Position = UDim2.new(0.5, 0, 1, -14)
	rerollButton.Size = UDim2.fromOffset(180, 32)
	rerollButton.BackgroundColor3 = Color3.fromRGB(70, 55, 20)
	rerollButton.TextColor3 = Color3.new(1, 1, 1)
	rerollButton.Font = Enum.Font.GothamBold
	rerollButton.TextSize = 14
	rerollButton.Text = "REROLL — 125"
	rerollButton.Visible = false
	rerollButton.Parent = draftPanel
	styleCorner(rerollButton, 6)
	styleStroke(rerollButton, ACCENT, 1.5)
	rerollButton.Activated:Connect(function()
		if isPreviewDraft or #currentOffer == 0 then
			return
		end
		RerollDraftRequest:FireServer()
	end)

	-- RUN tab next to the coin counter (bottom-left). Opens a panel with
	-- the owned draft-upgrade list — used to sit permanently on the
	-- bottom-left and overlapped coins/shop as the list grew.
	buildTabButton = Instance.new("TextButton")
	buildTabButton.Name = "BuildTabButton"
	buildTabButton.AnchorPoint = Vector2.new(0, 1)
	buildTabButton.Position = BUILD_TAB_POSITION
	buildTabButton.Size = UDim2.fromOffset(72, 32)
	buildTabButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	buildTabButton.BackgroundTransparency = 0.2
	buildTabButton.TextColor3 = Color3.new(1, 1, 1)
	buildTabButton.Font = Enum.Font.GothamBold
	buildTabButton.TextSize = 13
	buildTabButton.Text = "RUN"
	buildTabButton.Parent = screenGui
	styleCorner(buildTabButton, 6)
	styleStroke(buildTabButton, Color3.fromRGB(90, 90, 90), 1.5)

	buildPanel = Instance.new("Frame")
	buildPanel.Name = "BuildPanel"
	buildPanel.AnchorPoint = Vector2.new(0, 1)
	buildPanel.Position = UDim2.new(0, 168, 1, -56)
	buildPanel.Size = UDim2.fromOffset(220, 80)
	buildPanel.BackgroundColor3 = PANEL_BG
	buildPanel.BackgroundTransparency = 0.1
	buildPanel.BorderSizePixel = 0
	buildPanel.Visible = false
	buildPanel.Parent = screenGui
	styleCorner(buildPanel, 8)
	styleStroke(buildPanel, ACCENT, 1.5)

	local buildClose = Instance.new("TextButton")
	buildClose.Name = "CloseButton"
	buildClose.AnchorPoint = Vector2.new(1, 0)
	buildClose.Position = UDim2.new(1, -6, 0, 6)
	buildClose.Size = UDim2.fromOffset(22, 22)
	buildClose.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	buildClose.TextColor3 = Color3.new(1, 1, 1)
	buildClose.Font = Enum.Font.GothamBold
	buildClose.TextSize = 14
	buildClose.Text = "X"
	buildClose.Parent = buildPanel
	styleCorner(buildClose, 4)

	buildList = Instance.new("Frame")
	buildList.Name = "BuildList"
	buildList.Position = UDim2.fromOffset(8, 8)
	buildList.Size = UDim2.new(1, -16, 1, -16)
	buildList.BackgroundTransparency = 1
	buildList.Parent = buildPanel

	buildListTitle = Instance.new("TextLabel")
	buildListTitle.Name = "BuildListTitle"
	buildListTitle.BackgroundTransparency = 1
	buildListTitle.Size = UDim2.new(1, -28, 0, 18)
	buildListTitle.Font = Enum.Font.GothamBold
	buildListTitle.TextSize = 13
	buildListTitle.TextColor3 = ACCENT
	buildListTitle.TextXAlignment = Enum.TextXAlignment.Left
	buildListTitle.Text = "THIS RUN"
	buildListTitle.Parent = buildList

	buildEmptyLabel = Instance.new("TextLabel")
	buildEmptyLabel.Name = "EmptyLabel"
	buildEmptyLabel.BackgroundTransparency = 1
	buildEmptyLabel.Position = UDim2.fromOffset(0, 24)
	buildEmptyLabel.Size = UDim2.new(1, 0, 0, 24)
	buildEmptyLabel.Font = Enum.Font.Gotham
	buildEmptyLabel.TextSize = 12
	buildEmptyLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
	buildEmptyLabel.TextXAlignment = Enum.TextXAlignment.Left
	buildEmptyLabel.Text = "No upgrades yet"
	buildEmptyLabel.Parent = buildList

	buildTabButton.Activated:Connect(function()
		setBuildPanelVisible(not buildPanelVisible)
	end)
	buildClose.Activated:Connect(function()
		setBuildPanelVisible(false)
	end)

	--[[
		A nil payload means "the draft window closed" — sent to everyone
		by RunUpgradeService.CloseDrafts, including players who already
		picked (whose panel is long since hidden) and anyone whose pick
		was auto-resolved for them. Dismissing on it guarantees the panel
		can never outlive its break and hang over the next wave.
	]]
	RunUpgradeOffer.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			RunDraftController.Hide()
			return
		end

		local cards = payload.Cards
		local rerollCost = payload.RerollCost
		-- Backward-compatible: older servers sent a bare card array.
		if typeof(cards) ~= "table" then
			if #payload > 0 and payload[1] and payload[1].Id then
				cards = payload
				rerollCost = RunUpgradeConfig.RerollBaseCost
			else
				RunDraftController.Hide()
				return
			end
		end
		if #cards == 0 then
			RunDraftController.Hide()
			return
		end

		isPreviewDraft = false
		RunDraftController.Show(cards, if typeof(rerollCost) == "number" then rerollCost else nil)
	end)

	RunUpgradesChanged.OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		renderBuildList(state.Owned or {})
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or #currentOffer == 0 then
			return
		end
		local index: number? = nil
		if input.KeyCode == Enum.KeyCode.One then
			index = 1
		elseif input.KeyCode == Enum.KeyCode.Two then
			index = 2
		elseif input.KeyCode == Enum.KeyCode.Three then
			index = 3
		end
		local card = index and currentOffer[index]
		if card then
			choose(card.Id)
		end
	end)

	if SHOW_DRAFT_ON_START then
		task.defer(function()
			isPreviewDraft = true
			RunDraftController.Show(buildPreviewOffer())
		end)
	end
end

return RunDraftController
