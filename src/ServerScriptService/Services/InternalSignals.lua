--[[
	InternalSignals.lua (ModuleScript)

	Server-to-server signaling between services that don't otherwise
	depend on each other, for cases where a plain require() would create
	an awkward or circular dependency. Currently just one signal: telling
	WeaponService to re-sync a player's ammo display after ShopService
	successfully upgrades a weapon (so a magazine-capacity increase shows
	up immediately instead of waiting for the next reload/switch).

	Not a RemoteEvent — this never touches the client. Both WeaponService
	and ShopService require this ModuleScript directly.
]]

local InternalSignals = {}

local ammoRefreshHandler: ((Player) -> ())? = nil

function InternalSignals.SetAmmoRefreshHandler(handler: (Player) -> ())
	ammoRefreshHandler = handler
end

function InternalSignals.RequestAmmoRefresh(player: Player)
	if ammoRefreshHandler then
		ammoRefreshHandler(player)
	end
end

return InternalSignals
