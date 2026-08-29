--[[
	Remotes/init.lua
	Central place to create and fetch RemoteEvents so client and server
	never hardcode WaitForChild paths all over the codebase.

	Tier 0 only needs two: firing a weapon, and telling clients HP changed.
	Add more as systems grow (Match, Shop, etc. per original section 18).
]]

local remoteNames = {
	"FireWeapon", -- client -> server: player fired their weapon
	"ZombieHPChanged", -- server -> client: for hit feedback / health bars
	"PlayerHPChanged", -- server -> client: for HP UI
	"PlayerDied", -- server -> client: for death UI
}

local Remotes = {}

for _, name in remoteNames do
	local existing = script:FindFirstChild(name)
	if existing then
		Remotes[name] = existing
	else
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = script
		Remotes[name] = remote
	end
end

return Remotes
