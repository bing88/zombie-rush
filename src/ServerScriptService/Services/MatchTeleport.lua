--[[
	MatchTeleport.lua (ModuleScript)

	Cross-place teleports for Hub → Match (reserved private server) and
	Match → Hub. No-ops / returns false when PlaceConfig isn't wired
	(Combined / Studio), so callers can fall back to in-place PivotTo.
]]

local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlaceConfig = require(ReplicatedStorage.Shared.PlaceConfig)

local MatchTeleport = {}

--[[
	Sends the party into an isolated Match server. Returns true if the
	teleport was initiated. On failure, warns and returns false so the
	Hub can keep the party waiting / fall back.
]]
function MatchTeleport.TeleportPartyToMatch(players: { Player }): boolean
	if not PlaceConfig.UsesCrossPlaceTeleport() then
		return false
	end
	if #players == 0 then
		return false
	end

	local matchPlaceId = PlaceConfig.MatchPlaceId
	local okReserve, codeOrErr = pcall(function()
		return TeleportService:ReserveServer(matchPlaceId)
	end)
	if not okReserve then
		warn(("MatchTeleport: ReserveServer failed (%s)"):format(tostring(codeOrErr)))
		return false
	end

	local accessCode = codeOrErr
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode

	local okTeleport, teleportErr = pcall(function()
		TeleportService:TeleportAsync(matchPlaceId, players, options)
	end)
	if not okTeleport then
		warn(("MatchTeleport: TeleportAsync to Match failed (%s)"):format(tostring(teleportErr)))
		return false
	end
	return true
end

--[[
	Sends everyone back to the Hub after defeat (or soft-fail). Returns
	true if teleport was initiated.
]]
function MatchTeleport.TeleportPlayersToHub(players: { Player }): boolean
	if not PlaceConfig.UsesCrossPlaceTeleport() then
		return false
	end
	if #players == 0 then
		return false
	end

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(PlaceConfig.HubPlaceId, players)
	end)
	if not ok then
		warn(("MatchTeleport: TeleportAsync to Hub failed (%s)"):format(tostring(err)))
		return false
	end
	return true
end

return MatchTeleport
