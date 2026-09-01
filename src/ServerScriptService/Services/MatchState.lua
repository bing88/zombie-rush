--[[
	MatchState.lua (ModuleScript)

	Tiny shared piece of state so WaveService (the writer) and
	PlayerService (a reader, for join-in-progress teleporting) can agree
	on what the match is currently doing without one Script requiring
	another Script (which Roblox doesn't support — only ModuleScripts are
	requireable).
]]

local MatchState = {}

local state = "Lobby" -- Lobby | Starting | Wave | Break | BossIncoming | Boss | Defeat (no Victory: runs are endless)
local changedBindable = Instance.new("BindableEvent")

MatchState.Changed = changedBindable.Event

function MatchState.Get(): string
	return state
end

function MatchState.Set(newState: string)
	state = newState
	changedBindable:Fire(newState)
end

--[[
	True whenever zombies could plausibly be alive in the arena — used by
	PlayerService to decide whether a freshly-spawned character should be
	moved into the arena (joining a match already underway) instead of
	left at the lobby's default SpawnLocation.
]]
function MatchState.IsMatchActive(): boolean
	return state == "Wave" or state == "Break" or state == "BossIncoming" or state == "Boss"
end

return MatchState
