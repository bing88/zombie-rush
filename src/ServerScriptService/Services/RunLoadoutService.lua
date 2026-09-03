--[[
	RunLoadoutService.lua (ModuleScript)

	Server-side owner of everything a player BUYS during a run: their
	cash, which weapons they've unlocked, and each weapon's upgrade
	level. All three used to live in DataService and persist across
	sessions; none of them do anymore.

	WHY THIS EXISTS. Persistent coins meant power came from a savings
	account instead of from the run: a player with a few runs banked
	could buy every weapon and max its upgrades in wave 1 and never meet
	the difficulty curve again. Worse, it made the reset the plan asks
	for (section 2 — don't scale difficulty with HP alone) impossible to
	tune, because two players in the same wave could be an order of
	magnitude apart in damage for reasons that happened days earlier.

	Making the shop run-scoped turns the upgrade ladder INTO the in-run
	power curve. Wave 15 is survivable because of what you bought this
	run, and every run starts from the same Pistol.

	NOTHING HERE PERSISTS — no DataStore, no DataService writes. Same
	posture and same reasoning as RunUpgradeService (drafted cards), and
	the two are deliberately complementary: cards are free, random and
	adapted to, purchases are paid, deliberate and planned. What DOES
	persist is one number, MetaXP, which only widens the shop menu and
	never grants power — see MetaConfig.

	API SHAPE MIRRORS THE OLD DataService CALLS (IsWeaponUnlocked /
	GetWeaponLevel / SetWeaponLevel / SpendCash) so the services that
	read them — WeaponService for damage and magazine size, PlayerService
	for which Tools to hand out — changed one identifier each rather than
	their logic. Anything that reads "what does this player currently
	have" should come here; DataService is now only for what survives
	the run.

	WIPED AT BOTH ENDS OF A MATCH (see WaveService): at match start,
	which is what makes the fresh start authoritative, and again when a
	run ends, so a player standing in the lobby can never see leftover
	cash they're about to lose. The shop also refuses to sell outside an
	active match — see ShopService — so there's no window where cash can
	be spent on something that's about to be wiped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local RunLoadoutService = {}

type RunLoadout = {
	Cash: number,
	UnlockedWeapons: { [string]: boolean },
	WeaponLevels: { [string]: number },
}

local loadouts: { [Player]: RunLoadout } = {}

--[[
	The state every run begins from: the free starting weapon, no
	upgrades, no cash.

	Seeding the starting weapon here rather than special-casing it in
	IsWeaponUnlocked means there's exactly one definition of "what you
	start with", and it's WeaponConfig.StartingWeapon — the same constant
	PlayerService equips and WeaponController predicts against.
]]
local function freshLoadout(): RunLoadout
	return {
		Cash = 0,
		UnlockedWeapons = { [WeaponConfig.StartingWeapon] = true },
		WeaponLevels = {},
	}
end

--[[
	Lazily creates on first access, so nothing has to be initialised in
	join order. A player who somehow reads their loadout before the match
	resets it gets the same fresh state the reset would have given them.
]]
local function getLoadout(player: Player): RunLoadout
	local loadout = loadouts[player]
	if not loadout then
		loadout = freshLoadout()
		loadouts[player] = loadout
	end
	return loadout
end

function RunLoadoutService.GetCash(player: Player): number
	return getLoadout(player).Cash
end

function RunLoadoutService.AddCash(player: Player, amount: number): number
	local loadout = getLoadout(player)
	loadout.Cash += amount
	return loadout.Cash
end

function RunLoadoutService.SpendCash(player: Player, amount: number): boolean
	local loadout = getLoadout(player)
	if loadout.Cash < amount then
		return false
	end
	loadout.Cash -= amount
	return true
end

function RunLoadoutService.IsWeaponUnlocked(player: Player, weaponName: string): boolean
	return getLoadout(player).UnlockedWeapons[weaponName] == true
end

function RunLoadoutService.UnlockWeapon(player: Player, weaponName: string)
	getLoadout(player).UnlockedWeapons[weaponName] = true
end

function RunLoadoutService.GetWeaponLevel(player: Player, weaponName: string): number
	return getLoadout(player).WeaponLevels[weaponName] or 0
end

function RunLoadoutService.SetWeaponLevel(player: Player, weaponName: string, level: number)
	getLoadout(player).WeaponLevels[weaponName] = level
end

--[[
	Back to the starting Pistol and zero cash.

	Note this does NOT re-hand-out Tools — PlayerService rebuilds the
	Backpack from this state on every spawn, and WaveService teleports
	players into the arena (which respawns them) as part of starting a
	match, so the reset and the Tool rebuild always happen in that order.
]]
function RunLoadoutService.ResetPlayer(player: Player)
	loadouts[player] = freshLoadout()
end

function RunLoadoutService.ResetAll()
	for _, player in Players:GetPlayers() do
		RunLoadoutService.ResetPlayer(player)
	end
end

function RunLoadoutService.Init()
	Players.PlayerRemoving:Connect(function(player)
		loadouts[player] = nil
	end)
end

return RunLoadoutService
