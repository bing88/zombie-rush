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

local RunUpgradeOffer = Remotes.RunUpgradeOffer
local RunUpgradeChosen = Remotes.RunUpgradeChosen
local RunUpgradesChanged = Remotes.RunUpgradesChanged

local RunDraftController = {}

local player = Players.LocalPlayer

local screenGui: ScreenGui
local draftPanel: Frame
local draftTitle: TextLabel
local cardRow: Frame
local buildList: Frame
local buildListTitle: TextLabel

-- The offer currently on screen, so a number key can resolve to a card
-- id. Empty whenever no draft is open, which is also what makes the
-- 1-3 keybinds inert outside a draft.
local currentOffer: { { Id: string, Name: string, Description: string, Stacks: number?, MaxStacks: number? } } = {}
local cardButtons: { TextButton } = {}

local CARD_WIDTH = 190
local CARD_HEIGHT = 210
local CARD_GAP = 14

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
local function choose(cardId: string)
	if #currentOffer == 0 then
		return
	end
	currentOffer = {}
	RunUpgradeChosen:FireServer(cardId)
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

	-- Keyboard hint, matching the number key that selects this card.
	local keyBadge = Instance.new("TextLabel")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0.5, 0)
	keyBadge.Position = UDim2.new(0.5, 0, 0, 12)
	keyBadge.Size = UDim2.fromOffset(26, 26)
	keyBadge.BackgroundColor3 = Color3.fromRGB(48, 48, 56)
	keyBadge.Font = Enum.Font.GothamBold
	keyBadge.TextSize = 14
	keyBadge.TextColor3 = Color3.fromRGB(200, 200, 210)
	keyBadge.Text = tostring(index)
	keyBadge.Parent = button
	styleCorner(keyBadge, 6)

	local name = Instance.new("TextLabel")
	name.Name = "CardName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0, 10, 0, 52)
	name.Size = UDim2.new(1, -20, 0, 44)
	name.Font = Enum.Font.GothamBlack
	name.TextSize = 17
	name.TextColor3 = ACCENT
	name.TextWrapped = true
	name.TextYAlignment = Enum.TextYAlignment.Top
	name.Text = card.Name
	name.Parent = button

	local description = Instance.new("TextLabel")
	description.Name = "CardDescription"
	description.BackgroundTransparency = 1
	description.Position = UDim2.new(0, 12, 0, 100)
	description.Size = UDim2.new(1, -24, 0, 62)
	description.Font = Enum.Font.Gotham
	description.TextSize = 14
	description.TextColor3 = Color3.fromRGB(225, 225, 235)
	description.TextWrapped = true
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.Text = card.Description
	description.Parent = button

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
		owned.Position = UDim2.new(0.5, 0, 1, -12)
		owned.Size = UDim2.new(1, -20, 0, 18)
		owned.Font = Enum.Font.GothamBold
		owned.TextSize = 12
		owned.TextColor3 = Color3.fromRGB(150, 200, 150)
		owned.Text = ("OWNED %d/%d"):format(stacks, card.MaxStacks or stacks)
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
	Refreshes the compact owned-upgrades list. Hidden entirely when the
	run has no picks yet (i.e. in the lobby and during wave 1) rather
	than showing an empty box.
]]
local function renderBuildList(owned: { { Name: string, Stacks: number } })
	for _, child in buildList:GetChildren() do
		if child:IsA("TextLabel") and child ~= buildListTitle then
			child:Destroy()
		end
	end

	if #owned == 0 then
		buildList.Visible = false
		return
	end

	buildList.Visible = true
	for index, entry in owned do
		local label = Instance.new("TextLabel")
		label.Name = "BuildEntry" .. tostring(index)
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, 16)
		label.Position = UDim2.new(0, 0, 0, 18 + (index - 1) * 16)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 12
		label.TextColor3 = Color3.fromRGB(215, 215, 225)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = entry.Stacks > 1 and ("%s  x%d"):format(entry.Name, entry.Stacks) or entry.Name
		label.Parent = buildList
	end

	buildList.Size = UDim2.fromOffset(190, 24 + #owned * 16)
end

function RunDraftController.Show(offer)
	currentOffer = offer
	clearCards()

	local count = #offer
	cardRow.Size = UDim2.fromOffset(count * CARD_WIDTH + (count - 1) * CARD_GAP, CARD_HEIGHT)

	for index, card in offer do
		local button = buildCard(index, card)
		button.Position = UDim2.fromOffset((index - 1) * (CARD_WIDTH + CARD_GAP), 0)
		button.Parent = cardRow
		table.insert(cardButtons, button)
	end

	draftTitle.Text = "CHOOSE AN UPGRADE"
	draftPanel.Visible = true

	-- Short fade-in so the panel doesn't pop into existence over the
	-- wave-cleared moment.
	draftPanel.BackgroundTransparency = 1
	TweenService:Create(draftPanel, TweenInfo.new(0.18), { BackgroundTransparency = 0.12 }):Play()
end

function RunDraftController.Hide()
	currentOffer = {}
	draftPanel.Visible = false
	clearCards()
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
	draftPanel.Size = UDim2.fromOffset(3 * CARD_WIDTH + 2 * CARD_GAP + 48, CARD_HEIGHT + 96)
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
	subtitle.Text = "Press 1, 2 or 3 to choose. Lasts this run only."
	subtitle.Parent = draftPanel

	cardRow = Instance.new("Frame")
	cardRow.Name = "CardRow"
	cardRow.AnchorPoint = Vector2.new(0.5, 0)
	cardRow.Position = UDim2.new(0.5, 0, 0, 70)
	cardRow.Size = UDim2.fromOffset(3 * CARD_WIDTH + 2 * CARD_GAP, CARD_HEIGHT)
	cardRow.BackgroundTransparency = 1
	cardRow.Parent = draftPanel

	-- Owned-upgrades list, bottom-left, clear of the hotbar (bottom
	-- center) and the ammo readout (bottom right).
	buildList = Instance.new("Frame")
	buildList.Name = "BuildList"
	buildList.AnchorPoint = Vector2.new(0, 1)
	buildList.Position = UDim2.new(0, 16, 1, -20)
	buildList.Size = UDim2.fromOffset(190, 24)
	buildList.BackgroundTransparency = 1
	buildList.Visible = false
	buildList.Parent = screenGui

	buildListTitle = Instance.new("TextLabel")
	buildListTitle.Name = "BuildListTitle"
	buildListTitle.BackgroundTransparency = 1
	buildListTitle.Size = UDim2.new(1, 0, 0, 16)
	buildListTitle.Font = Enum.Font.GothamBold
	buildListTitle.TextSize = 12
	buildListTitle.TextColor3 = ACCENT
	buildListTitle.TextXAlignment = Enum.TextXAlignment.Left
	buildListTitle.Text = "THIS RUN"
	buildListTitle.Parent = buildList

	--[[
		A nil payload means "the draft window closed" — sent to everyone
		by RunUpgradeService.CloseDrafts, including players who already
		picked (whose panel is long since hidden) and anyone whose pick
		was auto-resolved for them. Dismissing on it guarantees the panel
		can never outlive its break and hang over the next wave.
	]]
	RunUpgradeOffer.OnClientEvent:Connect(function(offer)
		if type(offer) ~= "table" or #offer == 0 then
			RunDraftController.Hide()
			return
		end
		RunDraftController.Show(offer)
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
end

return RunDraftController
