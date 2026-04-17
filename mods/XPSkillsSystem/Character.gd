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

func Energy(delta):
    if !gameData.starvation:
        var hungerMult = 1.0
        if xp_mod:
            hungerMult = 1.0 - (xp_mod.get_level(3) * xp_mod.cfg_hunger_reduce) - xp_mod.prestige_hunger_bonus()
        gameData.energy -= (delta / 30.0) * hungerMult

    if gameData.energy <= 0 && !gameData.starvation:
        Starvation(true)
    elif gameData.energy > 0 && gameData.starvation:
        Starvation(false)

func Hydration(delta):
    if !gameData.dehydration:
        var thirstMult = 1.0
        if xp_mod:
            thirstMult = 1.0 - (xp_mod.get_level(4) * xp_mod.cfg_thirst_reduce) - xp_mod.prestige_thirst_bonus()
        gameData.hydration -= (delta / 20.0) * thirstMult

    if gameData.hydration <= 0 && !gameData.dehydration:
        Dehydration(true)
    elif gameData.hydration > 0 && gameData.dehydration:
        Dehydration(false)

func Mental(delta):
    if gameData.heat:
        gameData.mental += delta / 4.0

    elif !gameData.insanity:
        var mentalMult = 1.0
        if xp_mod:
            mentalMult = 1.0 - (xp_mod.get_level(5) * xp_mod.cfg_mental_reduce) - xp_mod.prestige_mental_bonus()
        if (gameData.overweight
        || gameData.dehydration
        || gameData.starvation
        || gameData.bleeding
        || gameData.fracture
        || gameData.burn
        || gameData.frostbite
        || gameData.poisoning
        || gameData.rupture
        || gameData.headshot):
            gameData.mental -= (delta / 5.0) * mentalMult
        else:
            gameData.mental -= (delta / 35.0) * mentalMult

    if gameData.mental <= 0 && !gameData.insanity:
        Insanity(true)
    elif gameData.mental > 0 && gameData.insanity:
        Insanity(false)

func Stamina(delta):
    var staminaMult = 1.0
    if xp_mod:
        staminaMult = 1.0 - (xp_mod.get_level(1) * xp_mod.cfg_stamina_reduce) - xp_mod.prestige_stamina_bonus()

    if gameData.bodyStamina > 0 && (gameData.isRunning || gameData.overweight || (gameData.isSwimming && gameData.isMoving)):
        if gameData.overweight || gameData.starvation || gameData.dehydration:
            gameData.bodyStamina -= delta * 4.0 * staminaMult
        else:
            gameData.bodyStamina -= delta * 2.0 * staminaMult

    elif gameData.bodyStamina < 100:
        if gameData.starvation || gameData.dehydration:
            gameData.bodyStamina += delta * 5.0
        else:
            gameData.bodyStamina += delta * 10.0

    if gameData.armStamina > 0 && ((gameData.primary || gameData.secondary) && (gameData.weaponPosition == 2 || gameData.isAiming || gameData.isCanted || gameData.isInspecting || gameData.overweight) || (gameData.isSwimming && gameData.isMoving)):
        if gameData.overweight || gameData.starvation || gameData.dehydration:
            gameData.armStamina -= delta * 4.0 * staminaMult
        else:
            gameData.armStamina -= delta * 2.0 * staminaMult

    elif gameData.armStamina < 100:
        if gameData.starvation || gameData.dehydration:
            gameData.armStamina += delta * 10.0
        else:
            gameData.armStamina += delta * 20.0

func Clamp():
    var maxHP = 100.0
    if xp_mod:
        maxHP += xp_mod.get_level(0) * xp_mod.cfg_hp_per_level + xp_mod.prestige_hp_bonus()
    gameData.health = clampf(gameData.health, 0, maxHP)
    gameData.energy = clampf(gameData.energy, 0, 100)
    gameData.hydration = clampf(gameData.hydration, 0, 100)
    gameData.mental = clampf(gameData.mental, 0, 100)
    gameData.temperature = clampf(gameData.temperature, 0, 100)
    gameData.cat = clampf(gameData.cat, 0, 100)
    gameData.bodyStamina = clampf(gameData.bodyStamina, 0, 100)
    gameData.armStamina = clampf(gameData.armStamina, 0, 100)
    gameData.oxygen = clampf(gameData.oxygen, 0, 100)

func Death():
    if xp_mod and xp_mod.cfg_death_resets:
        xp_mod.ResetXP()
    super()

func Consume(item: ItemData):
    # super() so mods sitting between us and the base game still run.
    super(item)
    if xp_mod:
        xp_mod.award_skillbook_xp(item)

func Temperature(delta):
    if gameData.season == 1 || gameData.shelter || gameData.tutorial || gameData.heat:
        gameData.temperature += delta
    elif gameData.season == 2:
        var coldMult = 1.0
        if xp_mod:
            coldMult = 1.0 - (xp_mod.get_level(7) * xp_mod.cfg_coldres_reduce) - xp_mod.prestige_coldres_bonus()

        if !gameData.frostbite:
            if gameData.isSubmerged:
                gameData.temperature -= (delta * 8.0) * insulation * coldMult
            elif gameData.isWater:
                gameData.temperature -= (delta * 4.0) * insulation * coldMult
            elif gameData.indoor:
                gameData.temperature -= (delta / 10.0) * insulation * coldMult
            else:
                gameData.temperature -= (delta / 5.0) * insulation * coldMult

    if gameData.temperature <= 0 && !gameData.frostbite:
        Frostbite(true)
    elif gameData.temperature > 0 && gameData.frostbite:
        Frostbite(false)
