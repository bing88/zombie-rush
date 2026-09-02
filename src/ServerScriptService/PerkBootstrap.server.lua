--[[
	PerkBootstrap.server.lua

	Starts PerkService and owns the two perk remotes.

	The purchase prompt is triggered SERVER-side
	(MarketplaceService:PromptGamePassPurchase) from a client request
	carrying only a perk KEY, rather than letting the client prompt a
	game pass id directly. The client never supplies an id, so it can't
	be talked into prompting an unrelated pass, and the key is validated
	against PerkConfig before anything happens. The purchase itself is
	still entirely Roblox's — nothing here grants a perk; ownership is
	always re-read from MarketplaceService afterward (see PerkService).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Remotes = require(ReplicatedStorage.Remotes)
local PerkConfig = require(ReplicatedStorage.Shared.PerkConfig)
local PerkService = require(script.Parent.Services.PerkService)

local PerksUpdated = Remotes.PerksUpdated
local RequestPerkPurchase = Remotes.RequestPerkPurchase

local function pushOwnedPerks(player: Player)
	if player.Parent then
		PerksUpdated:FireClient(player, PerkService.GetOwnedKeys(player))
	end
end

PerkService.Init(pushOwnedPerks)

RequestPerkPurchase.OnServerEvent:Connect(function(player: Player, perkKey: unknown)
	if typeof(perkKey) ~= "string" then
		return
	end
	local perk = PerkConfig.GetPerk(perkKey)
	if not perk or not PerkConfig.IsConfigured(perk) then
		-- Unknown key, or a perk still on the placeholder GamePassId 0.
		-- Prompting id 0 would just error, so this is also what keeps an
		-- unconfigured game from throwing when someone taps a perk.
		return
	end
	if PerkService.Owns(player, perkKey) then
		return -- already owned; don't prompt a duplicate purchase
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, perk.GamePassId)
	end)
	if not ok then
		warn(("PerkBootstrap: failed to prompt purchase of %s: %s"):format(perkKey, tostring(err)))
	end
end)
