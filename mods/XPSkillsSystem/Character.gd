extends "res://Scripts/Character.gd"

var xp_mod = null

func _ready():
    xp_mod = Engine.get_meta("XPMain", null)

func Health(delta):
    # Delegate the damage block to whatever is next in the Character.gd
    # chain (the base game by default, or another mod like injuries system
    # rework that does its own `Health()` damage tuning). We zero
    # gameData.xpRegen across super() so the base game's hardcoded
    # `xpRegen * 0.2` regen block short-circuits — otherwise it would
    # double-apply alongside our configurable regen below. Everything else
    # in the base Health() (damage conditions, Death() trigger) still runs.
    var saved_xp_regen = gameData.xpRegen
    gameData.xpRegen = 0
    super(delta)
    gameData.xpRegen = saved_xp_regen

    # XP: passive health regen. Prestige bonuses add to both max HP and the
    # per-second regen rate on top of skill-tree bonuses, so a player with
    # Regen skill 0 but Regen prestige 2 still gets a slow trickle.
    if xp_mod and !gameData.isDead and gameData.health > 0:
        var regen_rate = xp_mod.get_level(6) * xp_mod.cfg_regen_per_level + xp_mod.prestige_regen_bonus()
        if regen_rate > 0.0:
            var maxHP = 100.0 + xp_mod.get_level(0) * xp_mod.cfg_hp_per_level + xp_mod.prestige_hp_bonus()
            if gameData.health < maxHP:
                gameData.health += delta * regen_rate

# Energy / Hydration / Mental / Temperature drains use the same trick:
# zero out the vanilla `gameData.xpXXX` stat bonus so base class's built-in
# (1 - xpXXX * 0.08) multiplier becomes 1.0, then scale `delta` so the net
# drain rate ends up at `delta * our_multiplier / N`. Identical output to
# the old full-replacement but preserves the override chain.

func Energy(delta):
    if xp_mod == null or gameData.starvation:
        super(delta)
        return
    var bonus = xp_mod.get_level(3) * xp_mod.cfg_hunger_reduce + xp_mod.prestige_hunger_bonus()
    var saved = gameData.xpHunger
    gameData.xpHunger = 0
    super(delta * (1.0 - bonus))
    gameData.xpHunger = saved

func Hydration(delta):
    if xp_mod == null or gameData.dehydration:
        super(delta)
        return
    var bonus = xp_mod.get_level(4) * xp_mod.cfg_thirst_reduce + xp_mod.prestige_thirst_bonus()
    var saved = gameData.xpThirst
    gameData.xpThirst = 0
    super(delta * (1.0 - bonus))
    gameData.xpThirst = saved

func Mental(delta):
    # Heat regen uses raw delta, not the mental multiplier — forward
    # unscaled in that case so the +delta/4 regen in base isn't distorted.
    if xp_mod == null or gameData.heat or gameData.insanity:
        super(delta)
        return
    var bonus = xp_mod.get_level(5) * xp_mod.cfg_mental_reduce + xp_mod.prestige_mental_bonus()
    var saved = gameData.xpMental
    gameData.xpMental = 0
    super(delta * (1.0 - bonus))
    gameData.xpMental = saved

# Stamina has both drain (staminaMult applies) and regen (no mult). We
# can't scale delta without distorting regen, so inject `xpStamina` at the
# equivalent level instead — base's `1 - xpStamina * 0.10` formula will
# produce our desired multiplier on drains. Regen branches don't use the
# multiplier so they pass through untouched.
func Stamina(delta):
    if xp_mod == null:
        super(delta)
        return
    var bonus = xp_mod.get_level(1) * xp_mod.cfg_stamina_reduce + xp_mod.prestige_stamina_bonus()
    var saved = gameData.xpStamina
    gameData.xpStamina = int(round(bonus / 0.10))
    super(delta)
    gameData.xpStamina = saved

# Clamp: base caps health at `100 + xpHealth * 5`. We want
# `100 + (skill_level * cfg_hp_per_level + prestige_hp_bonus)`. Inject the
# equivalent xpHealth (rounded up so base's clamp doesn't trim us below
# the intended max) then re-clamp precisely afterward.
func Clamp():
    if xp_mod == null:
        super()
        return
    var extra: float = xp_mod.get_level(0) * xp_mod.cfg_hp_per_level + xp_mod.prestige_hp_bonus()
    var saved: int = gameData.xpHealth
    gameData.xpHealth = int(ceil(extra / 5.0))
    super()
    gameData.xpHealth = saved
    gameData.health = clampf(gameData.health, 0, 100.0 + extra)

func Death():
    if xp_mod and xp_mod.cfg_death_resets:
        xp_mod.ResetXP()
    super()

func Consume(item: ItemData):
    # super() so mods sitting between us and the base game still run.
    super(item)
    if xp_mod:
        xp_mod.award_skillbook_xp(item)

# Temperature: base has no xp-based multiplier, so we scale delta only in
# the cold-drain branch. Regen branches (indoor/shelter/heat) pass through
# super with unscaled delta.
func Temperature(delta):
    var is_regenerating: bool = gameData.season == 1 or gameData.shelter or gameData.tutorial or gameData.heat
    if xp_mod == null or is_regenerating:
        super(delta)
        return
    var bonus: float = xp_mod.get_level(7) * xp_mod.cfg_coldres_reduce + xp_mod.prestige_coldres_bonus()
    super(delta * (1.0 - bonus))

