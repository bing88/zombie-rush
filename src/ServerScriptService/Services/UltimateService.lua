--[[
	UltimateService.lua (ModuleScript)

	Server-side owner of every player's ultimate charge and of the buff
	window it buys (plan section 20). Ability numbers live in
	ReplicatedStorage.Shared.UltimateConfig; this module owns only the
	charge/spend/expire state machine.

	Read helpers match PerkService / RunUpgradeService / ComboService:
	GetDamageScale and GetFireRateTimeScale return a neutral 1 whenever
	the ultimate isn't active, so WeaponService multiplies them in
	unconditionally alongside every other source.

	CHARGE IS SERVER-OWNED AND SO IS THE SPEND. ActivateUltimate carries
	no arguments at all — it's a request, not a command, and everything
	that decides whether it's honoured (is the meter full, is the player
	alive, are they downed, is a match even running) is re-checked here.
	A client that fires the remote in a loop gets nothing: the first call
	that passes zeroes the meter before the buff is granted, so a second
	call in the same frame finds an empty meter. This is the same posture
	as RunUpgradeChosen only ever accepting a card the server itself
	offered.

	EXPIRY IS READ, NOT SCHEDULED. IsActive compares against a stored
	deadline instead of a timer flipping a boolean, so the buff can never
	be left switched on by a task that was interrupted, and a player who
	dies or leaves mid-Berserk needs no cleanup. The heartbeat in Init
	exists only to PUSH the expiry to the client's HUD, never to end the
	buff itself.

	CHARGE SURVIVES DEATH, STREAKS DON'T. A run upgrade is permanent for
	the run and a kill streak dies in 4 seconds; charge sits deliberately
	between the two. Wiping it on death would mean the players who most
	need the ability — the ones being overrun — are the only ones who
	never get to use it, and it would make saving charge for the boss
	(the decision section 20 is built around) a bad idea for anyone not
	already winning. It's cleared per match instead, by WaveService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)
local UltimateConfig = require(ReplicatedStorage.Shared.UltimateConfig)
local ComboService = require(script.Parent.ComboService)
local DownedState = require(script.Parent.DownedState)
local MatchState = require(script.Parent.MatchState)

local UltimateStateChanged = Remotes.UltimateStateChanged
local ActivateUltimate = Remotes.ActivateUltimate
local UltimateActivated = Remotes.UltimateActivated

local UltimateService = {}

local NEUTRAL_MULTIPLIER = 1
local FULL_CHARGE = 1

-- [player] = 0..1. Absent means empty.
local charge: { [Player]: number } = {}
-- [player] = os.clock() deadline the buff runs until. Absent means the
-- player has never activated; a value in the past means it has expired.
local activeUntil: { [Player]: number } = {}
-- [player] = true once the expiry heartbeat has pushed this player's
-- lapse, so it pushes once per window instead of every tick forever.
local expiryPushed: { [Player]: boolean } = {}

function UltimateService.GetCharge(player: Player): number
	return charge[player] or 0
end

function UltimateService.IsActive(player: Player): boolean
	local deadline = activeUntil[player]
	return deadline ~= nil and os.clock() < deadline
end

function UltimateService.GetDamageScale(player: Player): number
	if not UltimateService.IsActive(player) then
		return NEUTRAL_MULTIPLIER
	end
	return 1 + UltimateConfig.Damage
end

--[[
	Duration scale for the gap between shots — divides rather than
	subtracts, same convention as ComboService/RunUpgradeService, so
	FireRate = 1.0 halves the gap ("+100% fire rate") instead of
	reaching zero.
]]
function UltimateService.GetFireRateTimeScale(player: Player): number
	if not UltimateService.IsActive(player) then
		return NEUTRAL_MULTIPLIER
	end
	return 1 / (1 + UltimateConfig.FireRate)
end

local function pushState(player: Player)
	if not player.Parent then
		return
	end
	local active = UltimateService.IsActive(player)
	UltimateStateChanged:FireClient(player, {
		Charge = UltimateService.GetCharge(player),
		Ready = UltimateService.GetCharge(player) >= FULL_CHARGE,
		Active = active,
		SecondsLeft = active and math.max((activeUntil[player] or 0) - os.clock(), 0) or 0,
		Name = UltimateConfig.Name,
		Description = UltimateConfig.Description,
		-- Sent so the HUD can show the live fire-rate/damage bonus from
		-- the same numbers the server is actually applying.
		FireRateBonus = UltimateConfig.FireRate,
		DamageBonus = UltimateConfig.Damage,
	})
end

--[[
	Charge for one attributed kill, scaled by the killer's current combo
	tier — this is the whole coupling between sections 19 and 20 (see
	ComboConfig's note on ChargeMultiplier).

	Called from WaveService's ZombieDied handler, for the same reason
	ComboService.RegisterKill is: it's the only place that sees indirect
	kills (splash, Exploder chains) as well as direct ones.

	Charging while the buff is ALREADY running is allowed on purpose.
	Berserk's own kills refilling the meter is the reward loop the plan
	describes ("short periods where the player feels extremely
	powerful"), and it can't runaway-chain, because the meter still needs
	a full 20+ kills to refill and the window is 8 seconds.
]]
function UltimateService.AddChargeForKill(player: Player)
	local current = UltimateService.GetCharge(player)
	if current >= FULL_CHARGE then
		return -- already ready; nothing to push, nothing to bank
	end

	local gain = UltimateConfig.ChargePerKill * ComboService.GetChargeMultiplier(player)
	charge[player] = math.min(current + gain, FULL_CHARGE)
	pushState(player)
end

function UltimateService.ResetPlayer(player: Player)
	charge[player] = nil
	activeUntil[player] = nil
	if player.Parent then
		pushState(player)
	end
end

function UltimateService.ResetAll()
	for _, player in Players:GetPlayers() do
		UltimateService.ResetPlayer(player)
	end
end

function UltimateService.Init()
	ActivateUltimate.OnServerEvent:Connect(function(player: Player)
		if not MatchState.IsMatchActive() then
			return
		end
		if UltimateService.GetCharge(player) < FULL_CHARGE then
			return -- not full: a stale HUD click or a forged call
		end
		if UltimateService.IsActive(player) then
			return -- already berserk; don't let a second press reset the window
		end
		if DownedState.IsDowned(player) then
			return -- bleeding out: can't shoot anyway, so this would burn the meter for nothing
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		-- Spend BEFORE granting, so two presses landing in the same frame
		-- can't both pass the checks above.
		charge[player] = nil
		activeUntil[player] = os.clock() + UltimateConfig.DurationSeconds
		expiryPushed[player] = nil
		pushState(player)

		-- Everyone sees the aura, not just the activating player — a
		-- teammate going berserk is information worth having in a co-op
		-- fight (and it's how the FX get onto other players' screens).
		UltimateActivated:FireAllClients(player, UltimateConfig.DurationSeconds)
	end)

	--[[
		Pushes the moment a buff lapses so the HUD's ACTIVE badge clears
		itself. Purely cosmetic: IsActive is already false by then for
		everything that reads it. expiryPushed keeps this to one push per
		window rather than every 0.2s forever after.
	]]
	task.spawn(function()
		while true do
			task.wait(0.2)
			for player, deadline in activeUntil do
				if os.clock() >= deadline then
					if not expiryPushed[player] then
						expiryPushed[player] = true
						pushState(player)
					end
				else
					expiryPushed[player] = nil
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		charge[player] = nil
		activeUntil[player] = nil
		expiryPushed[player] = nil
	end)
end

return UltimateService
