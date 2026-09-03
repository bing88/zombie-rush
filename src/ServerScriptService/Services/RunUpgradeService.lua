--[[
	RunUpgradeService.lua (ModuleScript)

	Server-side owner of every player's RUN-SCOPED upgrades — the ones
	drafted three-at-a-time between waves (pool in
	ReplicatedStorage.Shared.RunUpgradeConfig) — and the only place other
	services should ask about their effects.

	Deliberately modelled on PerkService: same "ask for a multiplier and
	multiply unconditionally, it returns a neutral 1 when the player has
	nothing" shape, so call sites stay one-liners and never branch on
	whether a run upgrade is owned. The three read helpers are
	GetScale/GetTimeScale/GetTotal; which one a given stat uses is fixed
	and documented in RunUpgradeConfig's header (getting it backwards
	would make a "faster" card slower, so that mapping lives in exactly
	one place).

	NOTHING HERE PERSISTS. No DataStore, no DataService writes. Run
	upgrades exist only in this module's tables for the lifetime of a
	single match and are wiped by ResetAll() when the next one starts —
	that impermanence is the whole point, since it's what lets each run
	take a different shape instead of everyone converging on the same
	saved account power.

	Current consumers:
	  WeaponService  Damage, HeadshotDamage, Magazine, FireRate,
	                 ReloadSpeed, ExplodeOnKill
	  PlayerService  MaxHealth, MoveSpeed (via onUpgradeApplied, below)
	  WaveService    CoinGain, HealPerKill

	DRAFT LIFECYCLE, and why the server owns the offer:

	  WaveService, at the start of each break
	    -> OfferDraftToAll(participants)   picks 3 eligible cards each,
	                                       remembers them, sends them
	    -> [client picks one]              RunUpgradeChosen remote
	    -> CloseDrafts()                   at the end of the break,
	                                       auto-resolves anyone who
	                                       didn't pick

	The offer is generated and stored server-side rather than letting the
	client send back an arbitrary card id, so a player can only ever
	apply one of the three cards they were actually shown, once. Without
	that, RunUpgradeChosen would be a "grant me any upgrade, repeatedly"
	exploit — the same reason WeaponService derives the fired weapon from
	the equipped Tool instead of trusting the client's claim.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local RunUpgradeConfig = require(ReplicatedStorage.Shared.RunUpgradeConfig)

local RunUpgradeOffer = Remotes.RunUpgradeOffer
local RunUpgradeChosen = Remotes.RunUpgradeChosen
local RunUpgradesChanged = Remotes.RunUpgradesChanged

local RunUpgradeService = {}

local NEUTRAL_MULTIPLIER = 1

-- [player][statName] = summed Amount across every stack the player owns.
local statTotals: { [Player]: { [string]: number } } = {}
-- [player][cardId] = how many times that card has been drafted this run.
local cardStacks: { [Player]: { [string]: number } } = {}
-- [player] = { cardId, cardId, cardId } — the offer currently open for
-- them, or nil if they have no draft pending.
local pendingOffers: { [Player]: { string } } = {}

local upgradeAppliedHandlers: { (Player) -> () } = {}

--[[
	Runs `handler` whenever that player takes a pick, so services can
	push a drafted change onto live state instead of waiting for the
	next natural refresh. Current subscribers:

	  PlayerService  re-applies MaxHealth/MoveSpeed to the character the
	                 player is standing in right now. Without this,
	                 Survivor/Adrenaline would do nothing until the next
	                 respawn — which only happens on death, so drafting
	                 "+25 max health" while alive (the entire point of
	                 drafting between waves) would feel like a dud pick.
	  WeaponService  re-sends the ammo state, so Extended Mag's larger
	                 capacity shows up in the HUD immediately rather
	                 than on the next shot/reload/weapon switch.

	A LIST rather than one settable handler: both of the above have to
	run, and neither service should have to know the other exists to
	avoid clobbering its registration. Each subscriber owns the property
	it writes (PlayerService owns humanoid stats because it already
	applies the equivalent Robux perks on spawn; this module writes
	neither), so there's still exactly one writer per property.
]]
function RunUpgradeService.OnUpgradeApplied(handler: (Player) -> ())
	table.insert(upgradeAppliedHandlers, handler)
end

--[[ Raw summed Amount for a stat — used directly by the flat stats. ]]
function RunUpgradeService.GetTotal(player: Player, stat: string): number
	local totals = statTotals[player]
	return (totals and totals[stat]) or 0
end

--[[
	For stats where BIGGER is better (damage, magazine, coins...):
	1 + total, i.e. a neutral 1 when nothing is owned.
]]
function RunUpgradeService.GetScale(player: Player, stat: string): number
	local total = RunUpgradeService.GetTotal(player, stat)
	if total == 0 then
		return NEUTRAL_MULTIPLIER
	end
	return 1 + total
end

--[[
	For stats that scale a DURATION, where smaller is better (shot delay,
	reload seconds): 1/(1 + total). See RunUpgradeConfig's header for why
	this divides rather than subtracting.
]]
function RunUpgradeService.GetTimeScale(player: Player, stat: string): number
	local total = RunUpgradeService.GetTotal(player, stat)
	if total == 0 then
		return NEUTRAL_MULTIPLIER
	end
	return 1 / (1 + total)
end

function RunUpgradeService.GetStacks(player: Player, cardId: string): number
	local stacks = cardStacks[player]
	return (stacks and stacks[cardId]) or 0
end

--[[
	Everything the client needs to render the run's build: each owned
	card with its stack count, plus the two scales the client applies
	itself.

	FireRate/ReloadSpeed have to be mirrored client-side because
	WeaponController does its own local fire-rate and reload prediction
	(so shooting feels instant instead of waiting a round trip). If only
	the server knew about a Gunslinger pick, the server would happily
	accept faster shots while the client kept throttling at the base rate
	— the upgrade would be paid for and completely invisible. These are
	sent as already-computed scales rather than raw totals so the
	client can't disagree with the server about how they combine.
]]
local function buildClientState(player: Player)
	local owned = {}
	local stacks = cardStacks[player]
	if stacks then
		for cardId, count in stacks do
			local card = RunUpgradeConfig.GetCard(cardId)
			if card then
				table.insert(owned, {
					Id = card.Id,
					Name = card.Name,
					Description = card.Description,
					Stacks = count,
					MaxStacks = card.MaxStacks,
					IconId = card.IconId,
				})
			end
		end
		table.sort(owned, function(a, b)
			return a.Name < b.Name
		end)
	end

	return {
		Owned = owned,
		FireRateScale = RunUpgradeService.GetTimeScale(player, "FireRate"),
		ReloadScale = RunUpgradeService.GetTimeScale(player, "ReloadSpeed"),
	}
end

local function pushClientState(player: Player)
	RunUpgradesChanged:FireClient(player, buildClientState(player))
end

local function applyCard(player: Player, card)
	local stacks = cardStacks[player]
	if not stacks then
		stacks = {}
		cardStacks[player] = stacks
	end
	local totals = statTotals[player]
	if not totals then
		totals = {}
		statTotals[player] = totals
	end

	stacks[card.Id] = (stacks[card.Id] or 0) + 1
	totals[card.Stat] = (totals[card.Stat] or 0) + card.Amount

	for _, handler in upgradeAppliedHandlers do
		-- Isolated: one subscriber erroring (e.g. on a character that
		-- vanished mid-break) must not stop the others from running or
		-- abort the pick that was already committed above.
		local ok, err = pcall(handler, player)
		if not ok then
			warn(("RunUpgradeService: upgrade-applied handler failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end
	pushClientState(player)
end

--[[
	Wipes a player's entire run — called per player on join/leave and for
	everyone at the start of a match.
]]
function RunUpgradeService.ResetPlayer(player: Player)
	statTotals[player] = nil
	cardStacks[player] = nil
	pendingOffers[player] = nil
	if player.Parent then
		pushClientState(player)
	end
end

function RunUpgradeService.ResetAll()
	for _, player in Players:GetPlayers() do
		RunUpgradeService.ResetPlayer(player)
	end
end

--[[
	Picks up to OfferCount distinct cards the player can still take, at
	random, without replacement.

	Cards already at MaxStacks are filtered out first, so a maxed pick
	never wastes one of the three slots — that matters most in a deep run,
	where a player who has maxed two axes would otherwise keep being
	offered them and effectively stop receiving choices at all. When
	fewer than three cards remain eligible the offer is simply shorter
	(the client lays out however many it's sent); when NONE remain the
	player gets no draft at all rather than an empty prompt.
]]
local function rollOffer(player: Player): { string }
	local eligible = {}
	for _, card in RunUpgradeConfig.Cards do
		if RunUpgradeService.GetStacks(player, card.Id) < card.MaxStacks then
			table.insert(eligible, card.Id)
		end
	end

	-- Partial Fisher-Yates: only shuffle as far as we need to draw.
	local drawCount = math.min(RunUpgradeConfig.OfferCount, #eligible)
	for index = 1, drawCount do
		local swapWith = math.random(index, #eligible)
		eligible[index], eligible[swapWith] = eligible[swapWith], eligible[index]
	end

	local offer = {}
	for index = 1, drawCount do
		table.insert(offer, eligible[index])
	end
	return offer
end

--[[
	Stacks/MaxStacks ride along with each offered card so the draft UI can
	show "OWNED 2/5" on a card the player has already taken before —
	which is the only way to tell a fresh pick from a stack-up while
	choosing, and the main thing that makes deliberately specializing
	into one axis a readable decision rather than a guess.
]]
local function buildOfferPayload(player: Player, offer: { string })
	local payload = {}
	for _, cardId in offer do
		local card = RunUpgradeConfig.GetCard(cardId)
		if card then
			table.insert(payload, {
				Id = card.Id,
				Name = card.Name,
				Description = card.Description,
				Stacks = RunUpgradeService.GetStacks(player, card.Id),
				MaxStacks = card.MaxStacks,
				IconId = card.IconId,
			})
		end
	end
	return payload
end

--[[
	Opens a draft for each given player. Called by WaveService at the
	start of every break.
]]
function RunUpgradeService.OfferDraftToAll(players: { Player })
	for _, player in players do
		local offer = rollOffer(player)
		if #offer > 0 then
			pendingOffers[player] = offer
			RunUpgradeOffer:FireClient(player, buildOfferPayload(player, offer))
		end
	end
end

--[[
	Ends the draft window. Anyone who never picked gets the first card
	they were offered, automatically.

	Auto-picking rather than forfeiting is deliberate: the offer arrives
	mid-run with zombies about to spawn, and a player who was reviving a
	teammate, mid-reload, or simply slow to read three cards shouldn't be
	permanently behind the rest of the party for it. A random-but-real
	upgrade is a far better failure mode than a wasted wave, and the
	client is told what it got (see RunUpgradesChanged) so the pick never
	happens silently.
]]
function RunUpgradeService.CloseDrafts()
	for player, offer in pendingOffers do
		if player.Parent and offer[1] then
			local card = RunUpgradeConfig.GetCard(offer[1])
			if card then
				applyCard(player, card)
			end
		end
	end
	pendingOffers = {}
	-- Clearing the offers is what closes the window: a RunUpgradeChosen
	-- arriving after this point (a click that raced the break ending)
	-- finds no pending offer and is ignored, so it can't double-apply on
	-- top of the auto-pick above.
	RunUpgradeOffer:FireAllClients(nil) -- tells any still-open card UI to dismiss itself
end

function RunUpgradeService.Init()
	RunUpgradeChosen.OnServerEvent:Connect(function(player: Player, cardId: unknown)
		if typeof(cardId) ~= "string" then
			return
		end

		local offer = pendingOffers[player]
		if not offer then
			return -- no draft open for them: a stale/duplicate/forged click
		end

		local wasOffered = false
		for _, offeredId in offer do
			if offeredId == cardId then
				wasOffered = true
				break
			end
		end
		if not wasOffered then
			return -- they were never shown this card
		end

		local card = RunUpgradeConfig.GetCard(cardId :: string)
		if not card then
			return
		end
		if RunUpgradeService.GetStacks(player, card.Id) >= card.MaxStacks then
			return -- already maxed (only reachable via a duplicated click)
		end

		-- Consume the offer BEFORE applying, so two clicks landing in the
		-- same frame can't both pass the checks above and stack twice.
		pendingOffers[player] = nil
		applyCard(player, card)
	end)

	Players.PlayerRemoving:Connect(function(player)
		RunUpgradeService.ResetPlayer(player)
	end)
end

return RunUpgradeService
