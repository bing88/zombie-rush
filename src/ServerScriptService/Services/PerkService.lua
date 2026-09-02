--[[
	PerkService.lua (ModuleScript)

	Server-side source of truth for which Robux perks each player owns,
	and the ONLY place other services should ask about perk effects.

	Ownership comes from MarketplaceService (game passes), never from our
	own DataStore — the platform already remembers purchases permanently,
	so storing them ourselves would just create a second copy that can
	disagree with reality (and, worse, one an exploiter might try to get
	written).

	Ownership is cached per player for the session because
	UserOwnsGamePassAsync is a yielding web call: it must not be on the
	path of anything per-shot or per-frame. The cache is refreshed on
	join and again whenever a purchase completes, which covers every way
	ownership can actually change during a session.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PerkConfig = require(ReplicatedStorage.Shared.PerkConfig)

local PerkService = {}

-- [player][perkKey] = true/false. Absent player = not loaded yet.
local ownership: { [Player]: { [string]: boolean } } = {}

local function fetchOwnership(player: Player, perk): boolean
	if not PerkConfig.IsConfigured(perk) then
		return false -- placeholder id: nobody owns it, don't call the API
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, perk.GamePassId)
	end)
	if not ok then
		-- Network/API failure. Fail CLOSED (treat as unowned) rather than
		-- granting the perk: a temporary outage briefly under-powering a
		-- paying player is recoverable and self-corrects on the next
		-- refresh, whereas failing open would hand every perk to everyone
		-- for free whenever Roblox hiccups.
		warn(("PerkService: ownership check failed for %s / %s"):format(player.Name, perk.Key))
		return false
	end
	return owns == true
end

local function refreshPlayer(player: Player)
	local owned = {}
	for _, perk in PerkConfig.Perks do
		owned[perk.Key] = fetchOwnership(player, perk)
	end
	ownership[player] = owned
end

--[[
	True if the player owns this perk. Safe to call before the async
	refresh completes — it just reports false until the cache is
	populated, which is the same fail-closed stance as above.
]]
function PerkService.Owns(player: Player, perkKey: string): boolean
	local owned = ownership[player]
	return owned ~= nil and owned[perkKey] == true
end

--[[
	The multiplier to apply for this perk: the perk's configured value if
	owned, otherwise a neutral 1. Callers just multiply by this
	unconditionally rather than branching on ownership themselves.
]]
function PerkService.GetMultiplier(player: Player, perkKey: string): number
	if not PerkService.Owns(player, perkKey) then
		return PerkConfig.NEUTRAL_MULTIPLIER
	end
	local perk = PerkConfig.GetPerk(perkKey)
	return perk and perk.Multiplier or PerkConfig.NEUTRAL_MULTIPLIER
end

--[[
	Every perk the player owns, for sending to their client so the shop
	can show "OWNED" instead of a buy button.
]]
function PerkService.GetOwnedKeys(player: Player): { string }
	local keys = {}
	local owned = ownership[player]
	if owned then
		for key, isOwned in owned do
			if isOwned then
				table.insert(keys, key)
			end
		end
	end
	return keys
end

function PerkService.Init(onOwnershipChanged: ((Player) -> ())?)
	local function setup(player: Player)
		-- Spawned rather than awaited: this is several yielding web calls
		-- and must not delay the rest of the join path.
		task.spawn(function()
			refreshPlayer(player)
			if onOwnershipChanged then
				onOwnershipChanged(player)
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerAdded:Connect(setup)

	Players.PlayerRemoving:Connect(function(player)
		ownership[player] = nil
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end
		-- Re-query rather than trusting the event's gamePassId blindly:
		-- one round-trip on a rare event is cheap, and it keeps the cache
		-- derived from a single authority (MarketplaceService) instead of
		-- being partly event-driven and partly queried.
		task.spawn(function()
			refreshPlayer(player)
			if onOwnershipChanged then
				onOwnershipChanged(player)
			end
		end)
	end)
end

return PerkService
