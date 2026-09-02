--[[
	ComboService.lua (ModuleScript)

	Server-side owner of every player's kill streak (plan section 19) and
	the only place other services should ask what a streak is currently
	worth.

	Same read-helper shape as PerkService and RunUpgradeService —
	GetDamageScale/GetFireRateTimeScale return a neutral 1 when the player
	has no streak, so WeaponService multiplies unconditionally and never
	branches on whether a combo is running. Which helper a stat uses is
	the same convention as RunUpgradeService: bonuses where bigger is
	better multiply by (1 + bonus), and anything scaling a DURATION (the
	minimum gap between shots) divides instead, so "+10% fire rate" means
	shots land 10% more often rather than 10% further apart.

	NOTHING HERE PERSISTS, and nothing here is ever saved: a streak is
	sub-wave state that decays in DecaySeconds.

	KILLS ARRIVE FROM WaveService, not WeaponService. WaveService's
	ZombieService.ZombieDied handler is the one place a kill is already
	attributed to a player regardless of HOW it happened — a direct shot,
	Demolitionist splash, or an Exploder popping next to another zombie
	all arrive there. Counting in WeaponService instead would silently
	miss every indirect kill, which is exactly the aggressive play the
	streak is supposed to reward. (Bloodthirst healing lives there for
	the same reason.)

	DECAY IS POLLED, NOT SCHEDULED. Init spawns one heartbeat for the
	whole server rather than a per-kill task.delay cancelled and replaced
	on the next kill. At the streak lengths this ladder is built around
	(100+ kills) that would mean thousands of scheduled-then-orphaned
	timers per run, and getting the cancellation wrong in either
	direction either resets a live streak or never resets a dead one. One
	loop reading a timestamp can't drift out of sync with the count.

	THE CLIENT MIRRORS THE FIRE-RATE SCALE. WeaponController predicts
	shots locally so firing feels instant, so a streak the client didn't
	know about would be a bonus the server accepted and the client kept
	throttling — earned, paid for, and completely invisible. The scale is
	sent already computed (see pushState) so the client can't disagree
	with the server about how it combines. This is the same trap
	documented in RunUpgradeService's buildClientState.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local ComboConfig = require(ReplicatedStorage.Shared.ComboConfig)

local ComboChanged = Remotes.ComboChanged

local ComboService = {}

local NEUTRAL_MULTIPLIER = 1

-- [player] = current streak length. Absent means zero; the two are
-- treated identically everywhere below.
local comboCounts: { [Player]: number } = {}
-- [player] = os.clock() of their most recent kill, for decay.
local lastKillClock: { [Player]: number } = {}

function ComboService.GetCount(player: Player): number
	return comboCounts[player] or 0
end

function ComboService.GetTier(player: Player): ComboConfig.ComboTier?
	return ComboConfig.GetTier(ComboService.GetCount(player))
end

--[[ Bigger-is-better bonus: 1 + the tier's Damage, neutral 1 with no streak. ]]
function ComboService.GetDamageScale(player: Player): number
	local tier = ComboService.GetTier(player)
	if not tier or tier.Damage == 0 then
		return NEUTRAL_MULTIPLIER
	end
	return 1 + tier.Damage
end

--[[
	Duration scale for the minimum gap between shots: 1/(1 + FireRate).
	See the header for why this divides rather than subtracting.
]]
function ComboService.GetFireRateTimeScale(player: Player): number
	local tier = ComboService.GetTier(player)
	if not tier or tier.FireRate == 0 then
		return NEUTRAL_MULTIPLIER
	end
	return 1 / (1 + tier.FireRate)
end

--[[
	How much faster this streak charges the ultimate. Read by
	UltimateService when a kill lands — this module deliberately doesn't
	call into UltimateService itself, so the dependency runs one way
	(ultimate knows about combo, combo knows about neither).
]]
function ComboService.GetChargeMultiplier(player: Player): number
	local tier = ComboService.GetTier(player)
	return tier and tier.ChargeMultiplier or NEUTRAL_MULTIPLIER
end

--[[
	`tierUp` flashes the HUD and is sent only on the kill that crosses a
	rung, not on every kill at that rung — the client can't derive it
	itself without tracking the previous tier, and the flash is meaningless
	if it fires 40 times in a row.
]]
local function pushState(player: Player, tierUp: boolean)
	if not player.Parent then
		return
	end
	local count = ComboService.GetCount(player)
	local tier = ComboConfig.GetTier(count)
	local nextTier = ComboConfig.GetNextTier(count)

	ComboChanged:FireClient(player, {
		Count = count,
		TierName = tier and tier.Name or nil,
		TierColor = tier and tier.Color or nil,
		NextTierAt = nextTier and nextTier.Kills or nil,
		-- Already-computed scales: the client applies FireRateScale to
		-- its local fire prediction and only displays the damage bonus.
		FireRateScale = ComboService.GetFireRateTimeScale(player),
		DamageBonus = tier and tier.Damage or 0,
		FireRateBonus = tier and tier.FireRate or 0,
		-- The full window, restarted client-side on every one of these
		-- messages. The client animates its own decay bar from this
		-- rather than the server streaming a countdown every frame; the
		-- server's own timestamp stays the authority on the actual reset.
		DecaySeconds = ComboConfig.DecaySeconds,
		TierUp = tierUp,
	})
end

--[[ One kill, attributed. Extends the streak and restarts its decay. ]]
function ComboService.RegisterKill(player: Player)
	local previousTier = ComboService.GetTier(player)
	local count = ComboService.GetCount(player) + 1
	comboCounts[player] = count
	lastKillClock[player] = os.clock()

	local newTier = ComboConfig.GetTier(count)
	-- Comparing by identity is enough: GetTier hands back the same table
	-- from ComboConfig.Tiers every time for a given rung.
	pushState(player, newTier ~= nil and newTier ~= previousTier)
end

--[[
	Drops the streak immediately. Called on decay, on death (see
	PlayerService) and at match start.
]]
function ComboService.ResetPlayer(player: Player)
	local hadStreak = (comboCounts[player] or 0) > 0
	comboCounts[player] = nil
	lastKillClock[player] = nil
	if hadStreak then
		pushState(player, false) -- Count is now 0, which hides the HUD readout
	end
end

function ComboService.ResetAll()
	for _, player in Players:GetPlayers() do
		ComboService.ResetPlayer(player)
	end
end

function ComboService.Init()
	-- Decay heartbeat. 0.1s is far finer than the 4s window, so the
	-- streak never visibly outlives the client's own emptied decay bar.
	task.spawn(function()
		while true do
			task.wait(0.1)
			local now = os.clock()
			for player, killedAt in lastKillClock do
				if now - killedAt >= ComboConfig.DecaySeconds then
					ComboService.ResetPlayer(player)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Clears both tables directly: ResetPlayer's pushState would be
		-- a FireClient at a player who is already gone.
		comboCounts[player] = nil
		lastKillClock[player] = nil
	end)
end

return ComboService
