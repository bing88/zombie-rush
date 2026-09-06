--[[
	PlaceConfig.lua

	Hub + Match place architecture. The same Rojo tree is published to
	TWO places under one Universe; this module decides which role the
	current server is playing.

	Place roles:
	  "Combined" — Studio / unset PlaceIds. Lobby + arena in one place
	               (legacy PivotTo flow). Keeps `rojo serve` Play working.
	  "Hub"      — Lobby + portals only. Parties teleport into Match.
	  "Match"    — Arena + waves only. Starts on join; returns to Hub
	               on defeat.

	SETUP (Creator Dashboard):
	  1. Create a Universe with two places: Hub and Match.
	  2. Publish this project to BOTH (same build is fine).
	  3. Paste the numeric PlaceIds below.
	  4. Enable third-party teleports if needed (same universe = OK).

	Leave both IDs at 0 while developing in Studio so Combined mode stays on.
]]

local PlaceConfig = {}

-- Paste live PlaceIds here after creating Hub + Match places.
PlaceConfig.HubPlaceId = 83629354524851
PlaceConfig.MatchPlaceId = 82763557287248

--[[
	Optional Studio override: "Hub" | "Match" | "Combined" | nil.
	nil = auto-detect from PlaceId (and fall back to Combined when IDs
	are unset). Set to "Hub" or "Match" only when deliberately testing
	one role inside a single Studio place.
]]
PlaceConfig.ForceRole = nil :: string?
PlaceConfig.ForceRole = "Combined"

function PlaceConfig.GetRole(): string
	local forced = PlaceConfig.ForceRole
	if forced == "Hub" or forced == "Match" or forced == "Combined" then
		return forced
	end

	local placeId = game.PlaceId
	if PlaceConfig.HubPlaceId ~= 0 and placeId == PlaceConfig.HubPlaceId then
		return "Hub"
	end
	if PlaceConfig.MatchPlaceId ~= 0 and placeId == PlaceConfig.MatchPlaceId then
		return "Match"
	end
	return "Combined"
end

function PlaceConfig.IsHub(): boolean
	local role = PlaceConfig.GetRole()
	return role == "Hub" or role == "Combined"
end

function PlaceConfig.IsMatch(): boolean
	local role = PlaceConfig.GetRole()
	return role == "Match" or role == "Combined"
end

function PlaceConfig.IsCombined(): boolean
	return PlaceConfig.GetRole() == "Combined"
end

--[[
	True when live Hub↔Match teleports should run (both IDs set and we
	are not in Combined fallback).
]]
function PlaceConfig.UsesCrossPlaceTeleport(): boolean
	return PlaceConfig.HubPlaceId ~= 0
		and PlaceConfig.MatchPlaceId ~= 0
		and not PlaceConfig.IsCombined()
end

return PlaceConfig
