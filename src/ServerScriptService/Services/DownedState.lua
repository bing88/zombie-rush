--[[
	DownedState.lua (ModuleScript)

	Tracks which players are currently "downed" (bleeding out, waiting on
	a teammate revive) during an active match. Same sharing pattern as
	MatchState.lua — a plain ModuleScript both PlayerService (the writer)
	and WeaponService/WaveService (readers) can require, since Roblox
	only allows requiring ModuleScripts, not other Scripts.

	Design: a downed player is NOT actually dead (Humanoid.Health is
	pinned at 1 by PlayerService while downed) — this avoids the
	complications of trying to "undo" a real Humanoid death (broken
	joints, a fired Died event, etc.). WaveService's defeat check reads
	Humanoid.Health directly (>0 = still in it, whether downed or not),
	so this module doesn't need to expose that; it's purely bookkeeping
	for "can this player fire their weapon" (WeaponService) and "is this
	player's revive prompt currently up" (PlayerService).
]]

local DownedState = {}

local downedPlayers: { [Player]: boolean } = {}
local changedBindable = Instance.new("BindableEvent")

DownedState.Changed = changedBindable.Event -- (player: Player, isDowned: boolean)

function DownedState.IsDowned(player: Player): boolean
	return downedPlayers[player] == true
end

function DownedState.SetDowned(player: Player, value: boolean)
	if downedPlayers[player] == value then
		return
	end
	if value then
		downedPlayers[player] = true
	else
		downedPlayers[player] = nil
	end
	changedBindable:Fire(player, value)
end

return DownedState
