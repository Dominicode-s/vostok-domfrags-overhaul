extends Node

var gameData = preload("res://Resources/GameData.tres")

# New-game detection — marker file is wiped by FormatSave() on new game
var _prev_menu: bool = false

# Kill Attribution
const GRENADE_WINDOW_MS: int = 6000
const FIRE_WINDOW_MS: int = 2000
const KILL_GRACE_MS: int = 3000
var last_grenade_time: int = 0
var _last_fire_time: int = 0
var _prev_grenade1: bool = false
var _prev_grenade2: bool = false

# Compat — AI death polling for kill XP (no AI.gd override needed)
var _tracked_ai: Array = []
var _pending_kills: Array = []

# Compat — Container tracking for search XP (no LootContainer.gd override)
var _awarded_containers: Dictionary = {}
var _prev_interface: bool = false

# Compat — Trade tracking (no Interface.gd trade hook needed)
var _trade_btn: Button = null
var _trade_connected: bool = false

# Compat — Task tracking (no Trader.gd override needed)
# Persisted per-trader completed-task counts, keyed by traderData.name.
# Loader.LoadTrader() clears + repopulates tasksCompleted on interaction,
# so an in-memory baseline would treat every re-populate as fresh completions.
var _tracked_traders: Array = []
var cfg_trader_task_counts: Dictionary = {}

# Compat — Patty's Profiles: records the XPData path we last loaded. When
# _get_xp_data_path() starts returning a different path, we reload state.
# Stays as the legacy path when Patty isn't installed, so the comparison
# never fires and the compat layer is fully dormant.
var _last_xp_path: String = ""

# Compat — Speed bonus (no Controller.gd override needed)
# Base speeds are captured on first Controller contact so we amplify whatever
# the game (or another mod) set as the real base, rather than hardcoded guesses.
var _controller_ref: Node = null
var _controller_base_walk: float = 2.5
var _controller_base_sprint: float = 5.0

# Scavenger SFX
var _sfx_search: AudioStreamMP3
# Scavenger SFX config (MCM)
var cfg_scavenger_sfx_enabled: bool = true
var cfg_scavenger_sfx_volume: int = 80  # 0-100 (%) mapped to dB

# Composure — cache the hit-shake Node3D (runs res://Scripts/Damage.gd) so we
# can dampen its rotation in _physics_process without overriding the script.
var _damage_node: Node3D = null

# Recoil — weapon rigs are preloaded in Database.gd so take_over_path can't
# replace the script. Instead we modify recoil data values when equipped.

# XP State
var xp: int = 0
var xpTotal: int = 0
var xpHealth: int = 0
var xpStamina: int = 0
var xpCarry: int = 0
var xpHunger: int = 0
var xpThirst: int = 0
var xpMental: int = 0
var xpRegen: int = 0
var xpColdRes: int = 0
var xpStealth: int = 0
var xpRecoil: int = 0
var xpSpeed: int = 0
var xpScavenger: int = 0
var xpComposure: int = 0

# Skills UI state (formerly on Interface.gd subclass; now held here so hooks
# can build + refresh the UI without extending vanilla Interface).
var skillsButton: Button
var skillsUI: Control
var skillsXPLabel: Label
var skillRows: Array = []
var skillNames = ["Vitality", "Endurance", "Pack Mule", "Hunger Resist", "Thirst Resist", "Iron Will", "Regeneration", "Cold Resistance", "Stealth", "Recoil Control", "Athleticism", "Scavenger", "Composure"]
var skillMaxDefault = [10, 10, 10, 10, 10, 10, 5, 10, 10, 10, 5, 5, 5]
var skillCostBaseDefault = [25, 25, 20, 20, 20, 20, 50, 20, 25, 25, 30, 30, 25]
var skillDescs = ["+5 Max HP", "-10% Stamina Drain", "+2kg Carry Weight", "-8% Hunger Drain", "-8% Thirst Drain", "-8% Mental Drain", "+0.2 HP/sec Regen", "-8% Cold Drain", "-5% AI Hearing Range", "-5% Weapon Recoil", "+4% Movement Speed", "+5% Loot Chance (better at higher levels)", "-10% Camera Shake From Hits"]
var skillsBuilt = false
var skillDescLabels: Array = []
var _xp_ui_refresh_timer: float = 0.0
var _skills_vbox: VBoxContainer
var _skill_row_panels: Array = []
var _prestige_button: Button = null
var _prestige_status_label: Label = null
var _prestige_modal: Control = null
var _prestige_section: VBoxContainer = null

# Config — XP rewards
var cfg_xp_container: float = 1.0
var cfg_xp_kill: int = 25
var cfg_xp_boss: int = 100
var cfg_xp_trade: int = 10
var cfg_xp_task: int = 50

# Container XP fraction accumulator — persists progress when the per-search
# reward is fractional (e.g. 0.3), so every ~3–4 containers grants 1 XP.
var _container_xp_fraction: float = 0.0

# Config — Death behavior
var cfg_death_resets: bool = true

# Config — Skill bonuses per level
var cfg_hp_per_level: float = 5.0
var cfg_stamina_reduce: float = 0.10
var cfg_carry_per_level: float = 2.0
var cfg_hunger_reduce: float = 0.08
var cfg_thirst_reduce: float = 0.08
var cfg_mental_reduce: float = 0.08
var cfg_regen_per_level: float = 0.02
var cfg_coldres_reduce: float = 0.08
var cfg_stealth_reduce: float = 0.05
var cfg_recoil_reduce: float = 0.05
var cfg_speed_bonus: float = 0.04
var cfg_scavenger_chance: float = 0.05
var cfg_shake_reduce: float = 0.10

# Skill Books — 9 dedicated items built at runtime from SKILLBOOK_DEFS.
# Reuses the vanilla MS_Book mesh with a per-book tinted material so we
# don't ship .obj files; inventory icons are generated procedurally as
# placeholders (real art can be dropped in mods/XPSkillsSystem/Books/
# <file>_icon.png later without code changes).
var cfg_skillbooks_enabled: bool = true
var cfg_skillbook_base_xp: int = 200
var cfg_skillbook_dual_multiplier: float = 0.6

const SKILLBOOK_PREFIX: String = "XPSkillbook_"

# Every skill book ships as a Rare civilian-loot item. The color tints both
# the 3D cover material and the placeholder inventory icon.
const SKILLBOOK_DEFS: Array = [
    {"file": "Fitness",      "name": "Fitness Manual",            "skills": ["pack_mule"],                      "color": Color(0.80, 0.30, 0.20)},
    {"file": "Athletic",     "name": "Athletic Training Guide",   "skills": ["athleticism"],                    "color": Color(0.90, 0.55, 0.15)},
    {"file": "Medical",      "name": "Field Medical Handbook",    "skills": ["vitality", "regeneration"],       "color": Color(0.85, 0.20, 0.20)},
    {"file": "Wilderness",   "name": "Wilderness Survival Primer","skills": ["hunger_resist", "thirst_resist"], "color": Color(0.40, 0.55, 0.25)},
    {"file": "Marksmanship", "name": "Combat Marksmanship",       "skills": ["recoil_control", "composure"],    "color": Color(0.30, 0.35, 0.40)},
    {"file": "Meditations",  "name": "Meditations",               "skills": ["iron_will"],                      "color": Color(0.55, 0.30, 0.70)},
    {"file": "Unseen",       "name": "Art of Moving Unseen",      "skills": ["stealth"],                        "color": Color(0.20, 0.22, 0.30)},
    {"file": "Scavenger",    "name": "Scavenger's Almanac",       "skills": ["scavenger"],                      "color": Color(0.55, 0.45, 0.25)},
    {"file": "Arctic",       "name": "Arctic Field Guide",        "skills": ["cold_resistance", "endurance"],   "color": Color(0.35, 0.55, 0.75)},
]

# Built at runtime in _init_skillbook_items and keyed by ItemData.file.
# Needed for fast lookup on Consume and for shelter respawn.
var _skillbook_catalog: Dictionary = {}  # file -> {skills: Array, item_data: ItemData, pickup: PackedScene}

# Shelter persistence — base LoadShelter won't know our items exist, so we
# re-instantiate any skill-book pickups saved in the shelter .tres ourselves.
var _sb_last_scene_name: String = ""

# Path to the runtime-parsed book mesh. Referencing res://...MS_Book.obj as
# a path-only ext_resource has proven fragile for community users — Godot
# resolves via UID first and path fallback second, and the fallback can
# fail in some mod-load configurations. We parse the vanilla .obj ourselves
# into a stable user:// ArrayMesh to eliminate that failure mode.
const SKILLBOOK_MESH_PATH: String = "user://XPSkillbook_Mesh.res"

var skill_xp_pool: Dictionary = {}

# Config — Skill max levels
var cfg_max_levels: Array = [10, 10, 10, 10, 10, 10, 5, 10, 10, 10, 5, 5, 5]

# Config — Skill cost bases
var cfg_cost_bases: Array = [25, 25, 20, 20, 20, 20, 50, 20, 25, 25, 30, 30, 25]

# Config — Skill enabled toggles (index matches skill order)
var skill_ids: Array = ["vitality", "endurance", "pack_mule", "hunger_resist", "thirst_resist", "iron_will", "regeneration", "cold_resistance", "stealth", "recoil_control", "athleticism", "scavenger", "composure"]
var cfg_skill_enabled: Dictionary = {
	"vitality": true, "endurance": true, "pack_mule": true,
	"hunger_resist": true, "thirst_resist": true, "iron_will": true,
	"regeneration": true, "cold_resistance": true, "stealth": true,
	"recoil_control": true, "athleticism": true, "scavenger": true,
	"composure": true
}

# ─── Prestige ─────────────────────────────────────────────────
# Permanent bonuses earned by wiping all XP + skill levels. Unlocked
# when every enabled skill is at its max level. Each prestige rank
# adds a small additive bonus ON TOP of the skill tree (not baked
# into effective skill level). Stored separately at
# user://XPPrestige_<profile>.cfg so death / ResetXP don't wipe it
# (unless cfg_prestige_reset_on_death is on).

var cfg_prestige_enabled: bool = true
var cfg_prestige_reset_on_death: bool = false

# Per-skill permanent bonus magnitudes (per prestige rank).
# Roughly half the strength of a skill level so combined they're
# meaningful but not absurd. All exposed in MCM.
var cfg_prestige_hp: float = 3.0        # Vitality: +3 max HP
var cfg_prestige_stamina: float = 0.03  # Endurance: -3% drain
var cfg_prestige_carry: float = 1.0     # Pack Mule: +1 kg
var cfg_prestige_hunger: float = 0.02   # Hunger: -2% drain
var cfg_prestige_thirst: float = 0.02   # Thirst: -2% drain
var cfg_prestige_mental: float = 0.02   # Iron Will: -2% drain
var cfg_prestige_regen: float = 0.005   # Regen: +0.005 HP/s (25% of a skill level at default base regen)
var cfg_prestige_coldres: float = 0.02  # Cold Resist: -2% drain
var cfg_prestige_stealth: float = 0.02  # Stealth: -2% (no-op, kept for consistency)
var cfg_prestige_recoil: float = 0.02   # Recoil: -2% recoil
var cfg_prestige_speed: float = 0.01    # Athleticism: +1% speed
var cfg_prestige_scavenger: float = 0.02  # Scavenger: +2% loot chance
var cfg_prestige_composure: float = 0.02  # Composure: -2% camera shake

# Per-skill prestige rank caps. -1 = unlimited (only Vitality by default).
# Order matches skill_ids.
var cfg_prestige_caps: Array = [-1, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10]

# Runtime prestige state — skill_id -> rank count.
var prestige_counts: Dictionary = {}

# MCM integration
var _mcm_helpers = null
const MCM_FILE_PATH = "user://MCM/XPSkillsSystem"
const MCM_MOD_ID = "XPSkillsSystem"

func _ready():
    Engine.set_meta("XPMain", self)
    # Run _physics_process AFTER Damage.gd's so our Composure dampening scales
    # the rotation it just wrote. process_physics_priority: higher = later.
    process_physics_priority = 10
    # Rewrite any pre-v2.0 marker with a clean Resource. Older versions may
    # have saved a custom resource referencing override scripts that v2.0+
    # deleted, which caused script-load crashes on boot.
    _migrate_marker_file()
    _mcm_helpers = _try_load_mcm()
    if _mcm_helpers:
        _register_mcm()
    else:
        LoadConfig()
    LoadXP()
    # Install script overrides on the next frame so every other autoload has
    # finished its own _ready first. Calling reload()/take_over_path() inline
    # during autoload init can race with mods that already resolved the base
    # script (MCM in particular).
    _register_character_hooks()
    _register_interface_hooks()
    call_deferred("_install_skillbook_hooks")
    get_tree().node_added.connect(_on_node_added)

# Character hooks — replaces the old Character.gd subclass under MML v3.0.0.
# Design:
#   Health   → post-hook only (add regen after super)
#   Energy / Hydration / Mental / Stamina / Temperature → pre+post pair
#       pre  saves "before" state on the character instance
#       post reads it, computes what super drained, applies skill reducer
#   Clamp    → replace + skip_super (full replacement — XP widens max HP which
#              a post-hook can't recover from after super's clampf)
#   Death    → pre-hook (reset XP before super handles death chain)
#   Consume  → post-hook (award skillbook XP after super processes eat)
func _register_character_hooks() -> void:
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null:
        push_warning("[XPSkillsSystem] RTVModLib not available — Character hooks disabled")
        return
    lib.hook("character-health-post",      _hook_character_health_post)
    lib.hook("character-energy-pre",       _hook_character_energy_pre)
    lib.hook("character-energy-post",      _hook_character_energy_post)
    lib.hook("character-hydration-pre",    _hook_character_hydration_pre)
    lib.hook("character-hydration-post",   _hook_character_hydration_post)
    lib.hook("character-mental-pre",       _hook_character_mental_pre)
    lib.hook("character-mental-post",      _hook_character_mental_post)
    lib.hook("character-stamina-pre",      _hook_character_stamina_pre)
    lib.hook("character-stamina-post",     _hook_character_stamina_post)
    lib.hook("character-temperature-pre",  _hook_character_temperature_pre)
    lib.hook("character-temperature-post", _hook_character_temperature_post)
    lib.hook("character-clamp",            _hook_character_clamp)
    lib.hook("character-death-pre",        _hook_character_death_pre)
    lib.hook("character-consume-post",     _hook_character_consume_post)

func _hook_character_health_post(_delta):
    # Passive regen after super processes damage. Prestige regen + per-skill
    # rate both count; max HP also widens via prestige.
    if gameData.isDead or gameData.health <= 0:
        return
    var regen_rate: float = get_level(6) * cfg_regen_per_level + prestige_regen_bonus()
    if regen_rate <= 0.0:
        return
    var maxHP: float = 100.0 + get_level(0) * cfg_hp_per_level + prestige_hp_bonus()
    if gameData.health < maxHP:
        gameData.health += _delta * regen_rate

func _hook_character_energy_pre(_delta):
    var ch = _get_hook_caller()
    if ch == null:
        return
    ch.set_meta("_xp_energy_before", gameData.energy)

func _hook_character_energy_post(_delta):
    if gameData.starvation:
        return
    var ch = _get_hook_caller()
    if ch == null or not ch.has_meta("_xp_energy_before"):
        return
    var before: float = ch.get_meta("_xp_energy_before")
    var drained: float = before - gameData.energy
    if drained > 0.0:
        var bonus: float = get_level(3) * cfg_hunger_reduce + prestige_hunger_bonus()
        gameData.energy = before - drained * (1.0 - bonus)

func _hook_character_hydration_pre(_delta):
    var ch = _get_hook_caller()
    if ch == null:
        return
    ch.set_meta("_xp_hydration_before", gameData.hydration)

func _hook_character_hydration_post(_delta):
    if gameData.dehydration:
        return
    var ch = _get_hook_caller()
    if ch == null or not ch.has_meta("_xp_hydration_before"):
        return
    var before: float = ch.get_meta("_xp_hydration_before")
    var drained: float = before - gameData.hydration
    if drained > 0.0:
        var bonus: float = get_level(4) * cfg_thirst_reduce + prestige_thirst_bonus()
        gameData.hydration = before - drained * (1.0 - bonus)

func _hook_character_mental_pre(_delta):
    var ch = _get_hook_caller()
    if ch == null:
        return
    ch.set_meta("_xp_mental_before", gameData.mental)

func _hook_character_mental_post(_delta):
    # Heat branch in base is a regen, insanity branch is its own thing —
    # neither should be scaled.
    if gameData.heat or gameData.insanity:
        return
    var ch = _get_hook_caller()
    if ch == null or not ch.has_meta("_xp_mental_before"):
        return
    var before: float = ch.get_meta("_xp_mental_before")
    var drained: float = before - gameData.mental
    if drained > 0.0:
        var bonus: float = get_level(5) * cfg_mental_reduce + prestige_mental_bonus()
        gameData.mental = before - drained * (1.0 - bonus)

func _hook_character_stamina_pre(_delta):
    var ch = _get_hook_caller()
    if ch == null:
        return
    ch.set_meta("_xp_body_stamina_before", gameData.bodyStamina)
    ch.set_meta("_xp_arm_stamina_before", gameData.armStamina)

func _hook_character_stamina_post(_delta):
    var ch = _get_hook_caller()
    if ch == null or not ch.has_meta("_xp_body_stamina_before"):
        return
    var bonus: float = get_level(1) * cfg_stamina_reduce + prestige_stamina_bonus()
    var body_before: float = ch.get_meta("_xp_body_stamina_before")
    var arm_before: float = ch.get_meta("_xp_arm_stamina_before")
    var body_drained: float = body_before - gameData.bodyStamina
    var arm_drained: float = arm_before - gameData.armStamina
    if body_drained > 0.0:
        gameData.bodyStamina = body_before - body_drained * (1.0 - bonus)
    if arm_drained > 0.0:
        gameData.armStamina = arm_before - arm_drained * (1.0 - bonus)

func _hook_character_temperature_pre(_delta):
    var ch = _get_hook_caller()
    if ch == null:
        return
    ch.set_meta("_xp_temperature_before", gameData.temperature)

func _hook_character_temperature_post(_delta):
    # Regen branches (summer / indoor shelter / tutorial / heat) don't scale.
    var is_regenerating: bool = gameData.season == 1 or gameData.shelter or gameData.tutorial or gameData.heat
    if is_regenerating:
        return
    var ch = _get_hook_caller()
    if ch == null or not ch.has_meta("_xp_temperature_before"):
        return
    var before: float = ch.get_meta("_xp_temperature_before")
    var drained: float = before - gameData.temperature
    if drained > 0.0:
        var bonus: float = get_level(7) * cfg_coldres_reduce + prestige_coldres_bonus()
        gameData.temperature = before - drained * (1.0 - bonus)

# Clamp is a full replacement — XP's wider max HP would be clamped back down
# by vanilla's hardcoded 100. skip_super() keeps our clamps as the final word.
func _hook_character_clamp():
    var maxHP: float = 100.0 + get_level(0) * cfg_hp_per_level + prestige_hp_bonus()
    gameData.health       = clampf(gameData.health, 0, maxHP)
    gameData.energy       = clampf(gameData.energy, 0, 100)
    gameData.hydration    = clampf(gameData.hydration, 0, 100)
    gameData.mental       = clampf(gameData.mental, 0, 100)
    gameData.temperature  = clampf(gameData.temperature, 0, 100)
    gameData.cat          = clampf(gameData.cat, 0, 100)
    gameData.bodyStamina  = clampf(gameData.bodyStamina, 0, 100)
    gameData.armStamina   = clampf(gameData.armStamina, 0, 100)
    gameData.oxygen       = clampf(gameData.oxygen, 0, 100)
    var lib = Engine.get_meta("RTVModLib", null)
    if lib != null:
        lib.skip_super()

func _hook_character_death_pre():
    if cfg_death_resets:
        ResetXP()

func _hook_character_consume_post(item: ItemData):
    award_skillbook_xp(item)

func _get_hook_caller():
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null:
        return null
    var c = lib._caller
    if c == null or not is_instance_valid(c):
        return null
    return c

# Interface hooks — replaces the old Interface.gd subclass under MML v3.0.0.
#   Drop / ContextPlace  → replace + skip_super for skillbooks; fall through otherwise
#   Open                 → post-hook, lazy-build the Skills UI
#   HideAllTools / DisableTools / EnableTools / LoadDefaultTool → post-hooks,
#                          mirror the skills button to the vanilla tool states
#   UpdateStats          → post-hook, apply carry-weight bonus on top of super
# The _process override that polled UpdateSkillsUI is now part of this
# autoload's own _process (see _poll_skills_ui_refresh call site).
func _register_interface_hooks() -> void:
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null:
        push_warning("[XPSkillsSystem] RTVModLib not available — Interface hooks disabled")
        return
    lib.hook("interface-drop",                _hook_interface_drop)
    lib.hook("interface-contextplace",        _hook_interface_contextplace)
    lib.hook("interface-open-post",           _hook_interface_open_post)
    lib.hook("interface-hidealltools-post",   _hook_interface_hidealltools_post)
    lib.hook("interface-disabletools-post",   _hook_interface_disabletools_post)
    lib.hook("interface-enabletools-post",    _hook_interface_enabletools_post)
    lib.hook("interface-loaddefaulttool-post", _hook_interface_loaddefaulttool_post)
    lib.hook("interface-updatestats-post",    _hook_interface_updatestats_post)

func _hook_interface_drop(target) -> void:
    if target == null or target.slotData == null or target.slotData.itemData == null:
        return
    var f: String = str(target.slotData.itemData.file)
    if not f.begins_with("XPSkillbook_"):
        return
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null: return
    var iface = lib._caller
    if iface == null or not is_instance_valid(iface):
        return
    _drop_skillbook(iface, target, _get_skillbook_pickup(f))
    lib.skip_super()

func _hook_interface_contextplace() -> void:
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null: return
    var iface = lib._caller
    if iface == null or not is_instance_valid(iface):
        return
    var ctx = iface.contextItem
    if ctx == null or ctx.slotData == null or ctx.slotData.itemData == null:
        return
    var f: String = str(ctx.slotData.itemData.file)
    if not f.begins_with("XPSkillbook_"):
        return
    _place_skillbook(iface, _get_skillbook_pickup(f))
    lib.skip_super()

func _hook_interface_open_post() -> void:
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null: return
    var iface = lib._caller
    if iface == null or not is_instance_valid(iface):
        return
    # Rebuild if UI was freed (scene change) or never built.
    if not skillsBuilt or skillsUI == null or not is_instance_valid(skillsUI):
        BuildSkillsUI(iface)
        skillsBuilt = true
    RefreshSkillDescs()

func _hook_interface_hidealltools_post() -> void:
    if skillsUI and is_instance_valid(skillsUI):
        skillsUI.hide()

func _hook_interface_disabletools_post() -> void:
    if skillsButton and is_instance_valid(skillsButton):
        skillsButton.disabled = true

func _hook_interface_enabletools_post() -> void:
    if skillsButton and is_instance_valid(skillsButton):
        skillsButton.disabled = false

func _hook_interface_loaddefaulttool_post(_tool: int) -> void:
    if skillsButton and is_instance_valid(skillsButton):
        skillsButton.set_pressed_no_signal(false)

func _hook_interface_updatestats_post(updateLabels: bool) -> void:
    # Apply Pack Mule carry-weight bonus on top of whatever vanilla (and any
    # mod between us and vanilla) already computed. Idempotent labels refresh.
    var lib = Engine.get_meta("RTVModLib", null)
    if lib == null: return
    var iface = lib._caller
    if iface == null or not is_instance_valid(iface):
        return
    var bonus: float = get_level(2) * cfg_carry_per_level + prestige_carry_bonus()
    if bonus == 0.0:
        return
    iface.currentInventoryCapacity += bonus
    if iface.currentInventoryWeight > iface.currentInventoryCapacity:
        if !gameData.overweight and iface.character:
            iface.character.Overweight(true)
    elif iface.character:
        iface.character.Overweight(false)
    if updateLabels:
        if iface.currentInventoryCapacity > 0:
            iface.inventoryWeightPercentage = iface.currentInventoryWeight / iface.currentInventoryCapacity
        iface.inventoryCapacity.text = str("%.1f" % iface.currentInventoryCapacity)
        iface.equipmentCapacity.text = str(int(round(iface.currentInventoryCapacity))) + "kg"
        if iface.inventoryWeightPercentage > 1: iface.inventoryWeight.modulate = Color.RED
        elif iface.inventoryWeightPercentage >= 0.5: iface.inventoryWeight.modulate = Color.YELLOW
        else: iface.inventoryWeight.modulate = Color.GREEN

# Helper: drop a skillbook as a pickup in the world. Same positioning logic
# as the old Interface.gd subclass, with iface-scoped references.
func _drop_skillbook(iface, target, scene: PackedScene) -> void:
    var map = get_tree().current_scene.get_node_or_null("/root/Map")
    if map == null or scene == null:
        iface.PlayError()
        return
    var dir: Vector3
    var pos: Vector3
    var rot: Vector3
    var force: float = 2.5
    if iface.trader and iface.hoverGrid == null:
        dir = iface.trader.global_transform.basis.z
        pos = (iface.trader.global_position + Vector3(0, 1.0, 0)) + dir / 2
        rot = Vector3(-25, iface.trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif iface.hoverGrid != null and iface.hoverGrid.get_parent().name == "Container":
        dir = iface.container.global_transform.basis.z
        pos = (iface.container.global_position + Vector3(0, 0.5, 0)) + dir / 2
        rot = Vector3(-25, iface.container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    else:
        dir = -iface.camera.global_transform.basis.z
        pos = (iface.camera.global_position + Vector3(0, -0.25, 0)) + dir / 2
        rot = Vector3(-25, iface.camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    var pickup = scene.instantiate()
    map.add_child(pickup)
    if !pickup.is_in_group("Item"):
        pickup.add_to_group("Item")
    pickup.position = pos
    pickup.rotation_degrees = rot
    pickup.linear_velocity = dir * force
    if pickup.has_method("Unfreeze"):
        pickup.Unfreeze()
    var slot = SlotData.new()
    slot.itemData = target.slotData.itemData
    slot.amount = target.slotData.amount
    pickup.slotData = slot
    target.reparent(iface)
    target.queue_free()
    iface.PlayDrop()
    iface.UpdateStats(true)

func _place_skillbook(iface, scene: PackedScene) -> void:
    if scene == null:
        iface.PlayError()
        return
    var map = get_tree().current_scene.get_node_or_null("/root/Map")
    if map == null:
        iface.PlayError()
        return
    var pickup = scene.instantiate()
    map.add_child(pickup)
    if !pickup.is_in_group("Item"):
        pickup.add_to_group("Item")
    pickup.slotData.Update(iface.contextItem.slotData)
    iface.placer.ContextPlace(pickup)
    if iface.contextGrid:
        iface.contextGrid.Pick(iface.contextItem)
    iface.contextItem.reparent(iface)
    iface.contextItem.queue_free()
    iface.Reset()
    iface.HideContext()
    iface.PlayClick()
    iface.UIManager.ToggleInterface()

# ─── Skills UI builders (migrated from Interface.gd) ──────────────────────────

func BuildSkillsUI(iface) -> void:
    Engine.set_meta("XPInterface", iface)
    var buttonsContainer = iface.get_node_or_null("Tools/Buttons/Margin/Buttons")
    if buttonsContainer == null:
        push_warning("[XPSkillsSystem] Tools/Buttons/Margin/Buttons not found on Interface")
        return
    skillsButton = Button.new()
    skillsButton.text = "Skills"
    skillsButton.toggle_mode = true
    skillsButton.focus_mode = Control.FOCUS_NONE
    skillsButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    skillsButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
    buttonsContainer.add_child(skillsButton)
    buttonsContainer.move_child(skillsButton, buttonsContainer.get_child_count() - 2)
    skillsButton.pressed.connect(_on_skills_pressed.bind(iface))

    var tools = iface.get_node_or_null("Tools")
    if tools == null:
        push_warning("[XPSkillsSystem] Tools node not found on Interface")
        return
    skillsUI = Control.new()
    skillsUI.name = "Skills"
    skillsUI.offset_left = 0
    skillsUI.offset_top = 0
    skillsUI.offset_right = 512
    skillsUI.offset_bottom = 704
    tools.add_child(skillsUI)
    skillsUI.hide()

    var bg = ColorRect.new()
    bg.color = Color(0.08, 0.08, 0.08, 0.95)
    bg.offset_right = 512
    bg.offset_bottom = 704
    skillsUI.add_child(bg)

    var margin = MarginContainer.new()
    margin.offset_right = 512
    margin.offset_bottom = 704
    margin.add_theme_constant_override("margin_left", 16)
    margin.add_theme_constant_override("margin_right", 16)
    margin.add_theme_constant_override("margin_top", 16)
    margin.add_theme_constant_override("margin_bottom", 16)
    skillsUI.add_child(margin)

    var scroll = ScrollContainer.new()
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    margin.add_child(scroll)

    _skills_vbox = VBoxContainer.new()
    _skills_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _skills_vbox.add_theme_constant_override("separation", 10)
    scroll.add_child(_skills_vbox)

    var header = HBoxContainer.new()
    header.add_theme_constant_override("separation", 16)
    _skills_vbox.add_child(header)

    var titleLabel = Label.new()
    titleLabel.text = "SKILLS"
    titleLabel.add_theme_font_size_override("font_size", 20)
    titleLabel.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
    header.add_child(titleLabel)

    skillsXPLabel = Label.new()
    skillsXPLabel.text = "XP: 0"
    skillsXPLabel.add_theme_font_size_override("font_size", 16)
    skillsXPLabel.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
    skillsXPLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    skillsXPLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    header.add_child(skillsXPLabel)

    var sep = HSeparator.new()
    sep.custom_minimum_size.y = 4
    _skills_vbox.add_child(sep)

    _build_skill_rows()
    _build_prestige_section(iface)


func _build_skill_rows() -> void:
    skillRows.clear()
    skillDescLabels.clear()
    _skill_row_panels.clear()
    for i in skillNames.size():
        if not is_skill_enabled(i):
            skillRows.append(null)
            skillDescLabels.append(null)
            continue
        var rowPanel = PanelContainer.new()
        rowPanel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        var stylebox = StyleBoxFlat.new()
        stylebox.bg_color = Color(0.12, 0.12, 0.12, 0.8)
        stylebox.set_corner_radius_all(4)
        stylebox.content_margin_left = 10
        stylebox.content_margin_right = 10
        stylebox.content_margin_top = 6
        stylebox.content_margin_bottom = 6
        rowPanel.add_theme_stylebox_override("panel", stylebox)
        _skills_vbox.add_child(rowPanel)

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 10)
        rowPanel.add_child(row)

        var nameLabel = Label.new()
        nameLabel.text = skillNames[i]
        nameLabel.custom_minimum_size.x = 120
        nameLabel.add_theme_font_size_override("font_size", 14)
        nameLabel.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
        row.add_child(nameLabel)

        var levelLabel = Label.new()
        levelLabel.text = "0/" + str(cfg_max_levels[i])
        levelLabel.custom_minimum_size.x = 42
        levelLabel.add_theme_font_size_override("font_size", 14)
        levelLabel.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
        levelLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        row.add_child(levelLabel)

        var prestigeLabel = Label.new()
        prestigeLabel.text = ""
        prestigeLabel.custom_minimum_size.x = 32
        prestigeLabel.add_theme_font_size_override("font_size", 13)
        prestigeLabel.add_theme_color_override("font_color", Color(0.95, 0.55, 1.0))
        prestigeLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        prestigeLabel.tooltip_text = "Prestige ranks in this skill"
        row.add_child(prestigeLabel)

        var descLabel = Label.new()
        descLabel.text = skillDescs[i]
        descLabel.add_theme_font_size_override("font_size", 12)
        descLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        descLabel.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
        descLabel.clip_text = true
        descLabel.tooltip_text = skillDescs[i]
        row.add_child(descLabel)
        skillDescLabels.append(descLabel)

        var upgradeBtn = Button.new()
        upgradeBtn.text = "+" + str(cfg_cost_bases[i]) + " XP"
        upgradeBtn.custom_minimum_size.x = 90
        upgradeBtn.custom_minimum_size.y = 30
        upgradeBtn.focus_mode = Control.FOCUS_NONE
        upgradeBtn.pressed.connect(_on_skill_upgrade.bind(i))
        row.add_child(upgradeBtn)

        skillRows.append({"level": levelLabel, "prestige": prestigeLabel, "button": upgradeBtn, "index": i})
        _skill_row_panels.append(rowPanel)

func RebuildSkills(iface) -> void:
    if not skillsBuilt or not _skills_vbox:
        return
    for panel in _skill_row_panels:
        if panel and is_instance_valid(panel):
            panel.queue_free()
    _skill_row_panels.clear()
    if _prestige_section and is_instance_valid(_prestige_section):
        _prestige_section.queue_free()
    _prestige_section = null
    _prestige_button = null
    _prestige_status_label = null
    _build_skill_rows()
    _build_prestige_section(iface)
    RefreshSkillDescs()
    UpdateSkillsUI()

func RefreshSkillDescs() -> void:
    if skillDescLabels.size() < 13: return
    var descs = [
        "+" + str(cfg_hp_per_level) + " Max HP",
        "-" + str(int(cfg_stamina_reduce * 100)) + "% Stamina Drain",
        "+" + str(cfg_carry_per_level) + "kg Carry Weight",
        "-" + str(int(cfg_hunger_reduce * 100)) + "% Hunger Drain",
        "-" + str(int(cfg_thirst_reduce * 100)) + "% Thirst Drain",
        "-" + str(int(cfg_mental_reduce * 100)) + "% Mental Drain",
        "+" + ("%.2f" % cfg_regen_per_level) + " HP/sec Regen",
        "-" + str(int(cfg_coldres_reduce * 100)) + "% Cold Drain",
        "-" + str(int(cfg_stealth_reduce * 100)) + "% AI Hearing Range",
        "-" + str(int(cfg_recoil_reduce * 100)) + "% Weapon Recoil",
        "+" + str(int(cfg_speed_bonus * 100)) + "% Movement Speed",
        "+" + str(int(cfg_scavenger_chance * 100)) + "% Extra Loot Chance",
        "-" + str(int(cfg_shake_reduce * 100)) + "% Camera Shake From Hits"
    ]
    for i in descs.size():
        if skillDescLabels[i] != null:
            skillDescLabels[i].text = descs[i]

func _on_skills_pressed(iface) -> void:
    if iface == null or not is_instance_valid(iface):
        return
    iface.HideAllTools()
    if skillsUI and is_instance_valid(skillsUI):
        skillsUI.show()
    if iface.eventsButton:   iface.eventsButton.set_pressed_no_signal(false)
    if iface.craftingButton: iface.craftingButton.set_pressed_no_signal(false)
    if iface.notesButton:    iface.notesButton.set_pressed_no_signal(false)
    if iface.mapButton:      iface.mapButton.set_pressed_no_signal(false)
    if iface.casetteButton:  iface.casetteButton.set_pressed_no_signal(false)
    if skillsButton and is_instance_valid(skillsButton):
        skillsButton.set_pressed_no_signal(true)
    UpdateSkillsUI()
    iface.PlayClick()

func _on_skill_upgrade(index: int) -> void:
    var iface = _find_interface()
    var currentLevel = get_level(index)
    if currentLevel >= cfg_max_levels[index]:
        if iface: iface.PlayError()
        return
    var cost = cfg_cost_bases[index] * (currentLevel + 1)
    if xp < cost:
        if iface: iface.PlayError()
        return
    xp -= cost
    _set_level_by_index(index, currentLevel + 1)
    SaveXP()
    UpdateSkillsUI()
    if iface:
        iface.UpdateStats(true)
        iface.PlayClick()

func UpdateSkillsUI() -> void:
    if skillsXPLabel == null or not is_instance_valid(skillsXPLabel): return
    skillsXPLabel.text = "XP: " + str(xp) + "  (Total: " + str(xpTotal) + ")"
    for row in skillRows:
        if row == null:
            continue
        var i = row.index
        var level = get_level(i)
        row.level.text = str(level) + "/" + str(cfg_max_levels[i])
        var nextCost = cfg_cost_bases[i] * (level + 1)
        if level >= cfg_max_levels[i]:
            row.button.text = "MAX"
            row.button.disabled = true
        else:
            row.button.text = "+" + str(nextCost) + " XP"
            row.button.disabled = xp < nextCost
        var prank = get_prestige_count(i)
        if "prestige" in row and row.prestige != null:
            row.prestige.text = ("✦" + str(prank)) if prank > 0 else ""
    _update_prestige_ui()

# ─── Prestige UI ──────────────────────────────────────────────────────────────

func _build_prestige_section(iface) -> void:
    _prestige_section = VBoxContainer.new()
    _prestige_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _prestige_section.add_theme_constant_override("separation", 6)
    _skills_vbox.add_child(_prestige_section)

    var spacer = Control.new()
    spacer.custom_minimum_size.y = 8
    _prestige_section.add_child(spacer)

    var sep = HSeparator.new()
    sep.custom_minimum_size.y = 2
    _prestige_section.add_child(sep)

    var prestigeHeader = Label.new()
    prestigeHeader.text = "PRESTIGE"
    prestigeHeader.add_theme_font_size_override("font_size", 16)
    prestigeHeader.add_theme_color_override("font_color", Color(0.95, 0.55, 1.0))
    _prestige_section.add_child(prestigeHeader)

    _prestige_status_label = Label.new()
    _prestige_status_label.text = ""
    _prestige_status_label.add_theme_font_size_override("font_size", 12)
    _prestige_status_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
    _prestige_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
    _prestige_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _prestige_section.add_child(_prestige_status_label)

    _prestige_button = Button.new()
    _prestige_button.text = "Prestige"
    _prestige_button.custom_minimum_size.y = 34
    _prestige_button.focus_mode = Control.FOCUS_NONE
    _prestige_button.pressed.connect(_on_prestige_pressed.bind(iface))
    _prestige_section.add_child(_prestige_button)

func _update_prestige_ui() -> void:
    if _prestige_button == null or _prestige_status_label == null:
        return
    if not cfg_prestige_enabled:
        _prestige_button.disabled = true
        _prestige_button.visible = false
        _prestige_status_label.visible = false
        return
    _prestige_button.visible = true
    _prestige_status_label.visible = true
    var available = is_prestige_available()
    _prestige_button.disabled = not available
    if available:
        _prestige_status_label.text = "All enabled skills maxed. Pick a stat to prestige — all XP and skill levels will be wiped in exchange for a permanent bonus to that stat."
        _prestige_status_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.55))
    else:
        _prestige_status_label.text = "Max every enabled skill to unlock Prestige. Prestige grants a permanent stat bonus that survives death, in exchange for wiping all XP and levels."
        _prestige_status_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))

func _on_prestige_pressed(iface) -> void:
    if not is_prestige_available():
        if iface: iface.PlayError()
        return
    _show_prestige_picker(iface)
    if iface: iface.PlayClick()

func _close_prestige_modal() -> void:
    if _prestige_modal and is_instance_valid(_prestige_modal):
        _prestige_modal.queue_free()
    _prestige_modal = null

func _show_prestige_picker(iface) -> void:
    _close_prestige_modal()
    if skillsUI == null or not is_instance_valid(skillsUI):
        return

    _prestige_modal = Control.new()
    _prestige_modal.offset_left = 0
    _prestige_modal.offset_top = 0
    _prestige_modal.offset_right = 512
    _prestige_modal.offset_bottom = 704
    _prestige_modal.mouse_filter = Control.MOUSE_FILTER_STOP
    skillsUI.add_child(_prestige_modal)

    var bg = ColorRect.new()
    bg.color = Color(0.0, 0.0, 0.0, 0.85)
    bg.offset_right = 512
    bg.offset_bottom = 704
    bg.mouse_filter = Control.MOUSE_FILTER_STOP
    _prestige_modal.add_child(bg)

    var margin = MarginContainer.new()
    margin.offset_right = 512
    margin.offset_bottom = 704
    margin.add_theme_constant_override("margin_left", 20)
    margin.add_theme_constant_override("margin_right", 20)
    margin.add_theme_constant_override("margin_top", 24)
    margin.add_theme_constant_override("margin_bottom", 24)
    _prestige_modal.add_child(margin)

    var vbox = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 8)
    margin.add_child(vbox)

    var title = Label.new()
    title.text = "CHOOSE PRESTIGE"
    title.add_theme_font_size_override("font_size", 20)
    title.add_theme_color_override("font_color", Color(0.95, 0.55, 1.0))
    vbox.add_child(title)

    var sub = Label.new()
    sub.text = "Pick one stat. All XP and skill levels will be wiped."
    sub.add_theme_font_size_override("font_size", 12)
    sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
    sub.autowrap_mode = TextServer.AUTOWRAP_WORD
    vbox.add_child(sub)

    var sep2 = HSeparator.new()
    sep2.custom_minimum_size.y = 4
    vbox.add_child(sep2)

    var scroll = ScrollContainer.new()
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.custom_minimum_size.y = 480
    vbox.add_child(scroll)

    var list_vbox = VBoxContainer.new()
    list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list_vbox.add_theme_constant_override("separation", 6)
    scroll.add_child(list_vbox)

    for i in skillNames.size():
        if not is_skill_enabled(i):
            continue
        var cap_reached = not can_prestige_skill(i)
        var prank = get_prestige_count(i)
        var cap = get_prestige_cap(i)
        var row_btn = Button.new()
        row_btn.custom_minimum_size.y = 36
        row_btn.focus_mode = Control.FOCUS_NONE
        var cap_text = "∞" if cap < 0 else str(cap)
        var prefix = "[MAX] " if cap_reached else ""
        row_btn.text = "%s%s  (✦%d / %s)" % [prefix, skillNames[i], prank, cap_text]
        row_btn.disabled = cap_reached
        row_btn.pressed.connect(_on_prestige_skill_picked.bind(iface, i))
        list_vbox.add_child(row_btn)

    var spacer2 = Control.new()
    spacer2.custom_minimum_size.y = 8
    vbox.add_child(spacer2)

    var cancel_btn = Button.new()
    cancel_btn.text = "Cancel"
    cancel_btn.custom_minimum_size.y = 34
    cancel_btn.focus_mode = Control.FOCUS_NONE
    cancel_btn.pressed.connect(_close_prestige_modal)
    vbox.add_child(cancel_btn)

func _on_prestige_skill_picked(iface, skill_index: int) -> void:
    _show_prestige_confirm(iface, skill_index)

func _show_prestige_confirm(iface, skill_index: int) -> void:
    _close_prestige_modal()
    if skillsUI == null or not is_instance_valid(skillsUI):
        return
    var skill_name = skillNames[skill_index]
    var current_rank = get_prestige_count(skill_index)

    _prestige_modal = Control.new()
    _prestige_modal.offset_left = 0
    _prestige_modal.offset_top = 0
    _prestige_modal.offset_right = 512
    _prestige_modal.offset_bottom = 704
    _prestige_modal.mouse_filter = Control.MOUSE_FILTER_STOP
    skillsUI.add_child(_prestige_modal)

    var bg = ColorRect.new()
    bg.color = Color(0.0, 0.0, 0.0, 0.9)
    bg.offset_right = 512
    bg.offset_bottom = 704
    bg.mouse_filter = Control.MOUSE_FILTER_STOP
    _prestige_modal.add_child(bg)

    var center = CenterContainer.new()
    center.offset_right = 512
    center.offset_bottom = 704
    _prestige_modal.add_child(center)

    var panel = PanelContainer.new()
    var stylebox = StyleBoxFlat.new()
    stylebox.bg_color = Color(0.12, 0.12, 0.14, 1.0)
    stylebox.set_border_width_all(2)
    stylebox.border_color = Color(0.95, 0.55, 1.0, 0.8)
    stylebox.set_corner_radius_all(6)
    stylebox.content_margin_left = 20
    stylebox.content_margin_right = 20
    stylebox.content_margin_top = 18
    stylebox.content_margin_bottom = 18
    panel.add_theme_stylebox_override("panel", stylebox)
    panel.custom_minimum_size = Vector2(400, 0)
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    var title = Label.new()
    title.text = "PRESTIGE " + skill_name.to_upper() + "?"
    title.add_theme_font_size_override("font_size", 18)
    title.add_theme_color_override("font_color", Color(0.95, 0.55, 1.0))
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(title)

    var msg = Label.new()
    msg.text = "This will wipe all your XP and skill levels. " + skill_name + "'s prestige rank will go from " + str(current_rank) + " to " + str(current_rank + 1) + ". This cannot be undone."
    msg.add_theme_font_size_override("font_size", 12)
    msg.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    msg.autowrap_mode = TextServer.AUTOWRAP_WORD
    msg.custom_minimum_size.x = 360
    vbox.add_child(msg)

    var spacer = Control.new()
    spacer.custom_minimum_size.y = 4
    vbox.add_child(spacer)

    var btn_row = HBoxContainer.new()
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_theme_constant_override("separation", 12)
    vbox.add_child(btn_row)

    var confirm_btn = Button.new()
    confirm_btn.text = "Yes, Prestige"
    confirm_btn.custom_minimum_size = Vector2(160, 36)
    confirm_btn.focus_mode = Control.FOCUS_NONE
    confirm_btn.pressed.connect(_on_prestige_confirmed.bind(iface, skill_index))
    btn_row.add_child(confirm_btn)

    var cancel_btn = Button.new()
    cancel_btn.text = "Cancel"
    cancel_btn.custom_minimum_size = Vector2(120, 36)
    cancel_btn.focus_mode = Control.FOCUS_NONE
    cancel_btn.pressed.connect(_close_prestige_modal)
    btn_row.add_child(cancel_btn)

func _on_prestige_confirmed(iface, skill_index: int) -> void:
    if do_prestige(skill_index):
        if iface: iface.PlayClick()
        _close_prestige_modal()
        UpdateSkillsUI()
        if iface: iface.UpdateStats(true)
    else:
        if iface: iface.PlayError()

# Locate the current Interface node to route UI-callback events that need it
# (like skill-upgrade buttons) without capturing it at connect time.
func _find_interface():
    var scene = get_tree().current_scene
    if scene == null:
        return null
    return scene.get_node_or_null("Core/UI/Interface")

# Poll for Skills-UI refresh. Replaces the old Interface._process() override
# that couldn't survive the take_over_path removal (vanilla Interface has no
# _process). Cheap — the branch short-circuits when the UI isn't visible.
func _poll_skills_ui_refresh(delta: float) -> void:
    if skillsUI == null or not is_instance_valid(skillsUI) or not skillsUI.visible:
        return
    _xp_ui_refresh_timer += delta
    if _xp_ui_refresh_timer >= 0.5:
        _xp_ui_refresh_timer = 0.0
        UpdateSkillsUI()

func _install_skillbook_hooks():
    # Emergency bypass — drop this marker file if skill-book init ever
    # misbehaves. Keeps the rest of the mod (XP, skills, prestige) working
    # while the books are disabled.
    if FileAccess.file_exists("user://XPSkillsDisableBooks.txt"):
        print("[XP Skills] Bypass marker found — skipping skill-book init")
        return
    _ensure_skillbook_mesh()
    # Catches SKILLBOOK_DEFS drift at boot instead of silently failing
    # inside award_skillbook_xp when a consumed book lists an unknown skill.
    for def in SKILLBOOK_DEFS:
        for sid in def.skills:
            if skill_ids.find(sid) < 0:
                push_warning("[XP Skills] SKILLBOOK_DEFS['" + str(def.file) + "'] references unknown skill id '" + sid + "'")
    if _skillbook_catalog.is_empty():
        _init_skillbook_items()
    else:
        # Already initialized — flipping the MCM toggle shouldn't recreate
        # every resource and invalidate world/inventory references. Just
        # update the consumable flag and let the loot injector re-run.
        for book_file in _skillbook_catalog.keys():
            var item: ItemData = _skillbook_catalog[book_file].item_data
            item.usable = cfg_skillbooks_enabled
            item.phrase = "Read" if cfg_skillbooks_enabled else ""
    _apply_skillbook_loot_injection()

func _skillbook_file(def: Dictionary) -> String:
    return SKILLBOOK_PREFIX + str(def.file)

const SKILLBOOK_CACHE_PATH: String = "user://XPSkillsBookCache.cfg"
# Bump whenever the on-disk .tres/.tscn layout changes so existing caches
# get invalidated and rebuilt. v2 = icon referenced via ext_resource
# instead of inline PackedByteArray. v3 = item.generalist flag set so
# books appear in the Generalist trader's supply. v4 = pickup references
# the runtime-parsed user://XPSkillbook_Mesh.res instead of the vanilla
# res://Items/Books/Files/MS_Book.obj (UID-resolution flakiness fix).
const SKILLBOOK_CACHE_VERSION: int = 5

func _init_skillbook_items():
    # Fast path: if the source PNGs haven't changed since the last rebuild
    # and all generated .tres/.tscn are still on disk, just load them into
    # memory. Skips ~18 PNG decodes + ~27 disk writes per boot.
    var sig: String = _skillbook_source_signature()
    var cache := ConfigFile.new()
    cache.load(SKILLBOOK_CACHE_PATH)
    var cached_sig: String = str(cache.get_value("cache", "signature", ""))
    var all_present: bool = true
    for def in SKILLBOOK_DEFS:
        var bf: String = _skillbook_file(def)
        if !FileAccess.file_exists("user://" + bf + ".tres") or !FileAccess.file_exists("user://" + bf + ".tscn"):
            all_present = false
            break
    if cached_sig != "" and cached_sig == sig and all_present:
        print("[XP Skills] Skill-book cache hit — loading pre-built resources")
        for def in SKILLBOOK_DEFS:
            if !_load_cached_skillbook(def):
                # A cached file failed to load — fall back to rebuild and
                # stop using the cache for this boot.
                _build_skillbook_files(def)
        return
    print("[XP Skills] Skill-book cache miss — rebuilding 9 books from source")
    for def in SKILLBOOK_DEFS:
        _build_skillbook_files(def)
    cache.set_value("cache", "signature", sig)
    cache.save(SKILLBOOK_CACHE_PATH)

func _load_cached_skillbook(def: Dictionary) -> bool:
    # Preload both ItemData AND the pickup scene (with its cover texture)
    # at boot. Lazy-loading was experimented with and reverted — community
    # crash reports pointed at on-demand resolution during container-open
    # flows. Costs ~1MB per book of decoded cover texture but keeps the
    # resource cache fully warm before any gameplay interaction.
    var book_file: String = _skillbook_file(def)
    var item_path: String = "user://" + book_file + ".tres"
    var pickup_path: String = "user://" + book_file + ".tscn"
    var item = ResourceLoader.load(item_path)
    if item == null:
        return false
    var scene = ResourceLoader.load(pickup_path)
    if scene == null:
        return false
    _skillbook_catalog[book_file] = {
        "skills": def.skills.duplicate(),
        "item_data": item,
        "pickup": scene,
        "pickup_path": pickup_path,
    }
    return true

func _get_skillbook_pickup(book_file: String) -> PackedScene:
    if !_skillbook_catalog.has(book_file):
        return null
    var entry = _skillbook_catalog[book_file]
    # Preloaded at boot — this is just a catalog lookup now. Fall back to
    # a disk read only if the entry was somehow cleared mid-session.
    if entry.get("pickup") != null:
        return entry.pickup
    var path: String = str(entry.get("pickup_path", ""))
    if path == "" or !FileAccess.file_exists(path):
        return null
    var scene = ResourceLoader.load(path)
    if scene != null:
        entry.pickup = scene
    return scene

func _skillbook_source_signature() -> String:
    # Collect <filename>:<size>:<mtime> for every PNG under Books/ so the
    # signature changes if any source art is added, removed, or edited.
    var parts: Array = ["v:" + str(SKILLBOOK_CACHE_VERSION)]
    var dirs: Array = [
        "res://mods/XPSkillsSystem/Books",
        OS.get_executable_path().get_base_dir().path_join("mods").path_join("XPSkillsSystem").path_join("Books"),
    ]
    for dir_path in dirs:
        var dir := DirAccess.open(dir_path)
        if dir == null:
            continue
        dir.list_dir_begin()
        var fname := dir.get_next()
        while fname != "":
            if !dir.current_is_dir() and fname.to_lower().ends_with(".png"):
                var full: String = dir_path.path_join(fname)
                var mtime: int = FileAccess.get_modified_time(full)
                var size: int = -1
                var af := FileAccess.open(full, FileAccess.READ)
                if af:
                    size = af.get_length()
                    af.close()
                parts.append("%s:%d:%d" % [fname, size, mtime])
            fname = dir.get_next()
        dir.list_dir_end()
        break
    parts.sort()
    return "|".join(parts)

func _build_skillbook_files(def: Dictionary):
    # Idempotent: creates on-disk .tres/.tscn files for this book and
    # links their in-memory cache entries. If the book is already in
    # _skillbook_catalog, we rebuild disk files (in case FormatSave wiped
    # them on a New Game) but keep the existing ItemData instance so
    # LT_Master references stay valid across the reset.
    var book_file: String = _skillbook_file(def)
    var icon_res_path: String = "user://" + book_file + "_Icon.tres"
    var tetris_path: String = "user://" + book_file + "_Tetris.tscn"
    var item_path: String = "user://" + book_file + ".tres"
    var pickup_path: String = "user://" + book_file + ".tscn"

    # Prefer real art if present, otherwise fall back to the placeholder.
    # Drop a PNG at mods/XPSkillsSystem/Books/<File>/icon.png to take over.
    var icon: ImageTexture = _load_skillbook_icon_override(str(def.file))
    if icon == null:
        icon = _build_skillbook_icon(def.color)
    ResourceSaver.save(icon, icon_res_path)
    # Without this the ItemData serializer embeds the full icon bitmap
    # inline (~500KB per book). take_over_path binds the in-memory instance
    # to its saved file, so ItemData writes a cheap ext_resource reference.
    icon.take_over_path(icon_res_path)

    var tetris_src: String = _build_skillbook_tetris_tscn(book_file, icon_res_path)
    var tf := FileAccess.open(tetris_path, FileAccess.WRITE)
    if tf:
        tf.store_string(tetris_src)
        tf.close()
    var tetris = ResourceLoader.load(tetris_path, "", ResourceLoader.CACHE_MODE_REPLACE)

    var item: ItemData
    if _skillbook_catalog.has(book_file):
        item = _skillbook_catalog[book_file].item_data
    else:
        item = ItemData.new()
    item.file = book_file
    item.name = def.name
    item.inventory = str(def.file)
    item.rotated = str(def.file)
    item.equipment = str(def.file)
    item.display = str(def.file)
    item.type = "Literature"
    item.weight = 0.4
    item.value = 75
    item.icon = icon
    item.tetris = tetris
    item.size = Vector2(1, 2)
    item.usable = cfg_skillbooks_enabled
    item.phrase = "Read" if cfg_skillbooks_enabled else ""
    item.rarity = item.Rarity.Rare
    item.civilian = true
    item.generalist = true
    item.grandma = true
    ResourceSaver.save(item, item_path)
    ResourceLoader.load(item_path, "", ResourceLoader.CACHE_MODE_REPLACE)

    # Optional real cover texture — if the modder ships cover.png, save it
    # as a .tres so the pickup scene can pull it in as an ext_resource.
    # No CACHE_MODE_REPLACE here: the pickup .tscn is lazy-loaded and will
    # resolve this resource from disk on first use.
    var cover_tex_path: String = ""
    var cover_tex: ImageTexture = _load_skillbook_cover_override(str(def.file))
    if cover_tex != null:
        cover_tex_path = "user://" + book_file + "_Cover.tres"
        ResourceSaver.save(cover_tex, cover_tex_path)

    var pickup_src: String = _build_skillbook_pickup_tscn(book_file, def.color, cover_tex_path)
    var pf := FileAccess.open(pickup_path, FileAccess.WRITE)
    if pf:
        pf.store_string(pickup_src)
        pf.close()
    # Eagerly load the pickup scene so its cover texture lives in the
    # resource cache before any gameplay code touches it. Reverted the
    # lazy-load experiment — community crash reports pointed at on-demand
    # resolution during container-open flows.
    var pickup_scene: PackedScene = ResourceLoader.load(pickup_path, "", ResourceLoader.CACHE_MODE_REPLACE)
    _skillbook_catalog[book_file] = {
        "skills": def.skills.duplicate(),
        "item_data": item,
        "pickup": pickup_scene,
        "pickup_path": pickup_path,
    }

func _ensure_skillbook_files():
    # Called after FormatSave on New Game. Rewrites the disk files and
    # refreshes cache without touching the in-memory ItemData references
    # that LT_Master.items already points to.
    for def in SKILLBOOK_DEFS:
        _build_skillbook_files(def)

func _skillbook_mod_file(rel_path: String) -> String:
    # Matches the Cash-mod helper: when packaged, files live at
    # res://mods/XPSkillsSystem/...; in an uncompressed dev install they
    # sit next to the executable under <game>/mods/XPSkillsSystem/...
    var res_path := "res://mods/XPSkillsSystem/" + rel_path
    if FileAccess.file_exists(res_path):
        return res_path
    var base := OS.get_executable_path().get_base_dir()
    var disk_path := base.path_join("mods").path_join("XPSkillsSystem").path_join(rel_path)
    if FileAccess.file_exists(disk_path):
        return disk_path
    return ""

func _load_skillbook_icon_override(file_key: String) -> ImageTexture:
    # The tetris Sprite2D renders at 0.5× scale, so the texture needs to be
    # 128×256 to fit a 1×2 inventory slot cleanly. Any source resolution gets
    # resampled down to that target.
    var tex := _load_skillbook_png_at([
        "Books/" + file_key + "/icon.png",
        "Books/" + file_key + " icon.png",
        "Books/" + file_key + "_icon.png",
    ], file_key, "icon")
    if tex == null:
        return null
    var img := tex.get_image()
    if img == null:
        return null
    if img.get_width() != 128 or img.get_height() != 256:
        img.resize(128, 256, Image.INTERPOLATE_LANCZOS)
        return ImageTexture.create_from_image(img)
    return tex

func _load_skillbook_cover_override(file_key: String) -> ImageTexture:
    return _load_skillbook_png_at([
        "Books/" + file_key + "/cover.png",
        "Books/" + file_key + ".png",
    ], file_key, "cover")

func _load_skillbook_png_at(rel_paths: Array, file_key: String = "", kind: String = "") -> ImageTexture:
    for rel in rel_paths:
        var path := _skillbook_mod_file(rel)
        if path == "":
            continue
        var tex := _read_png_as_texture(path)
        if tex != null:
            return tex
    # Case-insensitive flat-layout fallback — user-supplied art sometimes has
    # inconsistent capitalisation (e.g. "arctic icon.png" vs catalog "Arctic").
    if file_key != "" and kind != "":
        var hit := _case_insensitive_find(file_key, kind)
        if hit != "":
            var tex2 := _read_png_as_texture(hit)
            if tex2 != null:
                return tex2
    return null

func _read_png_as_texture(path: String) -> ImageTexture:
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty():
        return null
    var img := Image.new()
    if img.load_png_from_buffer(bytes) != OK:
        return null
    return ImageTexture.create_from_image(img)

func _case_insensitive_find(file_key: String, kind: String) -> String:
    # Scan Books/ for "<key> <kind>.png" ignoring case. Tries both the
    # packaged (res://) and disk-based mod dirs since FileAccess.file_exists
    # can't detect directories, only files.
    var needles: Array = [file_key.to_lower() + " " + kind + ".png"]
    if kind == "cover":
        needles.append(file_key.to_lower() + ".png")
    var candidates: Array = [
        "res://mods/XPSkillsSystem/Books",
        OS.get_executable_path().get_base_dir().path_join("mods").path_join("XPSkillsSystem").path_join("Books"),
    ]
    for dir_path in candidates:
        var dir := DirAccess.open(dir_path)
        if dir == null:
            continue
        dir.list_dir_begin()
        var fname := dir.get_next()
        while fname != "":
            if !dir.current_is_dir():
                var low := fname.to_lower()
                for n in needles:
                    if low == n:
                        dir.list_dir_end()
                        return dir_path.path_join(fname)
            fname = dir.get_next()
        dir.list_dir_end()
    return ""

func _build_skillbook_icon(tint: Color) -> ImageTexture:
    # 128x256 placeholder — matches vanilla Icon_Book_* dimensions so real
    # art can drop in at the same resolution without resampling.
    var img := Image.create(128, 256, false, Image.FORMAT_RGBA8)
    img.fill(tint)
    var edge := tint.lightened(0.15)
    var shadow := tint.darkened(0.35)
    for x in range(128):
        for t in range(4):
            img.set_pixel(x, t, edge)
            img.set_pixel(x, 255 - t, shadow)
    for y in range(256):
        for t in range(4):
            img.set_pixel(t, y, shadow)
            img.set_pixel(127 - t, y, shadow)
    # Vertical spine line
    for y in range(16, 240):
        for x in range(8, 12):
            img.set_pixel(x, y, shadow)
    # Horizontal "title band"
    var band := tint.darkened(0.25)
    for y in range(64, 96):
        for x in range(20, 112):
            img.set_pixel(x, y, band)
    return ImageTexture.create_from_image(img)

func _build_skillbook_tetris_tscn(book_file: String, icon_path: String) -> String:
    var lines := PackedStringArray()
    lines.append('[gd_scene format=3]')
    lines.append('')
    lines.append('[ext_resource type="Material" path="res://UI/Effects/MT_Item.tres" id="1"]')
    lines.append('[ext_resource type="Texture2D" path="' + icon_path + '" id="2"]')
    lines.append('')
    lines.append('[node name="' + book_file + '" type="Sprite2D"]')
    lines.append('material = ExtResource("1")')
    lines.append('position = Vector2(32, 64)')
    lines.append('scale = Vector2(0.5, 0.5)')
    lines.append('texture = ExtResource("2")')
    lines.append('')
    return "\n".join(lines)

func _ensure_skillbook_mesh():
    # Load the vanilla book mesh via the Godot resource loader (which
    # reads the IMPORTED ArrayMesh — the raw .obj source is stripped
    # from the PCK in packaged builds, so FileAccess can't read it as
    # text) and save it to a stable user:// path that pickup .tscn
    # files can reference without UID resolution.
    if FileAccess.file_exists(SKILLBOOK_MESH_PATH):
        return
    var obj_path: String = "res://Items/Books/Files/MS_Book.obj"
    if !ResourceLoader.exists(obj_path):
        push_warning("[XP Skills] Vanilla book mesh not found at " + obj_path + " — skill books will fall back to BoxMesh")
        return
    var mesh = ResourceLoader.load(obj_path)
    if mesh == null:
        push_warning("[XP Skills] Failed to load " + obj_path + " — skill books will fall back to BoxMesh")
        return
    ResourceSaver.save(mesh, SKILLBOOK_MESH_PATH, ResourceSaver.FLAG_COMPRESS)

func _build_skillbook_pickup_tscn(book_file: String, tint: Color, cover_tex_path: String = "") -> String:
    # Reuses the vanilla book mesh saved at SKILLBOOK_MESH_PATH. If that
    # mesh file isn't present (ResourceLoader couldn't load the vanilla
    # .obj for some reason) we fall back to a simple BoxMesh sub-resource
    # so the scene still loads cleanly — an ext_resource to a missing
    # file would fail the entire .tscn parse.
    var has_mesh: bool = FileAccess.file_exists(SKILLBOOK_MESH_PATH)
    var lines := PackedStringArray()
    lines.append('[gd_scene format=3]')
    lines.append('')
    lines.append('[ext_resource type="PhysicsMaterial" path="res://Items/Physics/Item_Physics.tres" id="1"]')
    lines.append('[ext_resource type="Script" path="res://Scripts/Pickup.gd" id="2"]')
    lines.append('[ext_resource type="Resource" path="user://' + book_file + '.tres" id="3"]')
    lines.append('[ext_resource type="Script" path="res://Scripts/SlotData.gd" id="4"]')
    if has_mesh:
        lines.append('[ext_resource type="ArrayMesh" path="' + SKILLBOOK_MESH_PATH + '" id="5"]')
    if cover_tex_path != "":
        lines.append('[ext_resource type="Texture2D" path="' + cover_tex_path + '" id="6"]')
    lines.append('')
    lines.append('[sub_resource type="Resource" id="SlotData_1"]')
    lines.append('script = ExtResource("4")')
    lines.append('resource_local_to_scene = true')
    lines.append('itemData = ExtResource("3")')
    lines.append('')
    lines.append('[sub_resource type="StandardMaterial3D" id="Material_1"]')
    if cover_tex_path != "":
        lines.append('albedo_texture = ExtResource("6")')
    else:
        lines.append('albedo_color = Color(%s, %s, %s, 1)' % [tint.r, tint.g, tint.b])
    lines.append('roughness = 0.85')
    lines.append('')
    if !has_mesh:
        lines.append('[sub_resource type="BoxMesh" id="BoxMesh_1"]')
        lines.append('size = Vector3(0.14, 0.2, 0.02)')
        lines.append('')
    lines.append('[sub_resource type="BoxShape3D" id="BoxShape_1"]')
    lines.append('size = Vector3(0.14, 0.2, 0.02)')
    lines.append('')
    lines.append('[node name="' + book_file + '" type="RigidBody3D" node_paths=PackedStringArray("mesh", "collision") groups=["Item"]]')
    lines.append('collision_layer = 4')
    lines.append('collision_mask = 29')
    lines.append('physics_material_override = ExtResource("1")')
    lines.append('script = ExtResource("2")')
    lines.append('slotData = SubResource("SlotData_1")')
    lines.append('mesh = NodePath("Mesh")')
    lines.append('collision = NodePath("Collision")')
    lines.append('')
    lines.append('[node name="Mesh" type="MeshInstance3D" parent="."]')
    lines.append('layers = 4')
    lines.append('visibility_range_end = 25.0')
    if has_mesh:
        lines.append('mesh = ExtResource("5")')
    else:
        lines.append('mesh = SubResource("BoxMesh_1")')
    lines.append('surface_material_override/0 = SubResource("Material_1")')
    lines.append('')
    lines.append('[node name="Collision" type="CollisionShape3D" parent="."]')
    lines.append('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.1, 0)')
    lines.append('shape = SubResource("BoxShape_1")')
    lines.append('')
    return "\n".join(lines)

func _apply_skillbook_loot_injection():
    # Runs after _init_skillbook_items, so every SKILLBOOK_PREFIX ItemData
    # is already created. Append-only; we never remove items we don't own.
    var lt = load("res://Loot/LT_Master.tres")
    if !lt:
        push_warning("[XP Skills] Could not load LT_Master — skill books will not spawn as loot.")
        return
    var owned: Dictionary = {}
    for book_file in _skillbook_catalog.keys():
        owned[book_file] = _skillbook_catalog[book_file].item_data
    # Remove any previous injections so toggling the MCM switch off leaves
    # the loot table clean.
    for i in range(lt.items.size() - 1, -1, -1):
        var it = lt.items[i]
        if it and "file" in it and str(it.file).begins_with(SKILLBOOK_PREFIX):
            lt.items.remove_at(i)
    if cfg_skillbooks_enabled:
        for book_file in owned.keys():
            lt.items.append(owned[book_file])
        print("[XP Skills] Injected %d skill book(s) into LT_Master (now %d total items)" % [owned.size(), lt.items.size()])

func _respawn_skillbooks_deferred(shelter_name: String):
    # Base LoadShelter awaits 0.1s internally. Wait a touch longer so every
    # vanilla item has been spawned before we add ours on top.
    await get_tree().create_timer(0.3).timeout
    _respawn_skillbooks_in_shelter(shelter_name)

func _respawn_skillbooks_in_shelter(shelter_name: String):
    # Base LoadShelter calls Database.get(item.file) and skips when it's
    # null, which it will be for every SKILLBOOK_PREFIX item. Without this
    # step, books dropped in the Cabin or Tent vanish on shelter reload.
    var path: String = "user://" + shelter_name + ".tres"
    if !FileAccess.file_exists(path):
        return
    var shelter = load(path)
    if !shelter or not ("items" in shelter):
        return
    var map = get_tree().current_scene.get_node_or_null("/root/Map")
    if !map:
        return
    var count: int = 0
    for item in shelter.items:
        if item == null or item.slotData == null or item.slotData.itemData == null:
            continue
        var file_name: String = str(item.slotData.itemData.file)
        if !file_name.begins_with(SKILLBOOK_PREFIX):
            continue
        if !_skillbook_catalog.has(file_name):
            continue
        if !item.position.is_finite() or !item.rotation.is_finite():
            continue
        if item.position.y < -10.0:
            continue
        var pickup_scene: PackedScene = _get_skillbook_pickup(file_name)
        if pickup_scene == null:
            continue
        var pickup = pickup_scene.instantiate()
        map.add_child(pickup)
        if !pickup.is_in_group("Item"):
            pickup.add_to_group("Item")
        pickup.slotData.Update(item.slotData)
        pickup.name = item.name
        pickup.global_position = item.position
        pickup.global_rotation = item.rotation
        if pickup.has_method("Freeze"):
            pickup.Freeze()
        if pickup.has_method("UpdateAttachments"):
            pickup.UpdateAttachments()
        count += 1
    if count > 0:
        print("[XP Skills] Restored %d skill book(s) in %s" % [count, shelter_name])

func _migrate_marker_file():
    if FileAccess.file_exists("user://XPSkillsMarker.tres"):
        var marker = Resource.new()
        ResourceSaver.save(marker, "user://XPSkillsMarker.tres")

# --- Patty's Profiles compat ---
# Patty stores per-profile copies of .tres files in user://profiles/<name>/,
# but .cfg files are shared across profiles. We key XPData.cfg by profile so
# each profile gets its own XP/skill state. With no Patty installed, falls
# back to user://XPData.cfg.

func _get_active_profile() -> String:
    if !FileAccess.file_exists("user://profiles/active_profile.cfg"):
        return ""
    var cfg = ConfigFile.new()
    if cfg.load("user://profiles/active_profile.cfg") != OK:
        return ""
    return str(cfg.get_value("profiles", "active", ""))

func _get_xp_data_path() -> String:
    var profile = _get_active_profile()
    if profile.is_empty():
        return "user://XPData.cfg"
    return "user://XPData_" + profile + ".cfg"

func _copy_file_bytes(src: String, dst: String):
    var f_in = FileAccess.open(src, FileAccess.READ)
    if !f_in:
        return
    var data = f_in.get_buffer(f_in.get_length())
    f_in.close()
    var f_out = FileAccess.open(dst, FileAccess.WRITE)
    if !f_out:
        return
    f_out.store_buffer(data)
    f_out.close()

func _process(delta):
    _poll_skills_ui_refresh(delta)
    # Detect menu→game transition to check for new game
    if _prev_menu and !gameData.menu:
        # Patty Profiles compat: if the active profile changed while the
        # player was in the menu, reload state from the new profile's file.
        # Zero cost without Patty — the path never changes so this is a
        # single string compare.
        if _get_xp_data_path() != _last_xp_path:
            LoadXP()
        # Two independent new-game signals. Marker alone is unreliable —
        # any SaveXP between FormatSave and this check recreates it. The
        # initialSpawn flag on Character.tres covers that race because only
        # Loader.SaveCharacter() clears it.
        var is_new_game: bool = false
        if !gameData.tutorial:
            if !FileAccess.file_exists("user://XPSkillsMarker.tres"):
                is_new_game = true
            elif _character_initial_spawn():
                is_new_game = true
        if is_new_game:
            ResetXP()
            # New game wipes prestige too. ResetXP alone only wipes prestige
            # when the hardcore "reset on death" toggle is on, because it
            # also runs on regular death. New game is unambiguous so we
            # always clear prestige here regardless of that toggle.
            prestige_counts.clear()
            var pp = _get_prestige_path()
            if FileAccess.file_exists(pp):
                DirAccess.remove_absolute(ProjectSettings.globalize_path(pp))
            # FormatSave wiped our XPSkillbook_*.tres too — rewrite them so
            # cached pickup scenes can still resolve their ext_resources.
            if !_skillbook_catalog.is_empty():
                _ensure_skillbook_files()
            print("[XP Skills] New game detected — XP and prestige reset")
        _ensure_marker()
        # Seed trader baselines from the authoritative save file. Must happen
        # after LoadXP (so profile-switched counts are respected) and after
        # ResetXP (so new games start with zero baselines rather than stale
        # ones). No-ops for traders already present in cfg_trader_task_counts.
        _sync_trader_baselines_from_save()
    # Detect game→menu transition: drop all per-session caches so a new run
    # starts with a clean slate (fixes stale node refs and container leak).
    if !_prev_menu and gameData.menu:
        _reset_session_state()
    _prev_menu = gameData.menu

    # Keep gameData fields in sync so base game code uses our levels
    # even if another mod stomped our Character.gd override
    if !gameData.menu:
        _sync_to_gamedata()

    # Detect scene change to respawn any skill books saved in shelters.
    # Base LoadShelter skips them (Database.get returns null for our
    # custom items) so we re-instantiate on the frame after load.
    var cur_scene = get_tree().current_scene
    if cur_scene and "mapName" in cur_scene:
        var mn: String = str(cur_scene.mapName)
        if mn != "" and mn != _sb_last_scene_name:
            _sb_last_scene_name = mn
            call_deferred("_respawn_skillbooks_deferred", mn)
    elif cur_scene:
        _sb_last_scene_name = ""

    # Track grenade throws for kill attribution
    var g1 = gameData.grenade1 if "grenade1" in gameData else false
    var g2 = gameData.grenade2 if "grenade2" in gameData else false
    if (_prev_grenade1 and !g1) or (_prev_grenade2 and !g2):
        last_grenade_time = Time.get_ticks_msec()
    _prev_grenade1 = g1
    _prev_grenade2 = g2

    # Track fire input for kill attribution (semi-auto fire window)
    if Input.is_action_pressed("fire") or ("isFiring" in gameData and gameData.isFiring):
        _last_fire_time = Time.get_ticks_msec()

    # Track state transitions (must update before early returns)
    var _interface_just_opened = gameData.interface and !_prev_interface
    _prev_interface = gameData.interface

    if gameData.menu or gameData.shelter:
        return

    # --- Compat XP tracking (replaces script overrides) ---

    # Kill XP — poll tracked AI nodes for death
    _track_kills()

    # Container XP — detect container open via interface state
    if _interface_just_opened and !gameData.isTrading:
        _check_container_xp.call_deferred()

    # Trade XP — connect to Accept button when trading
    if gameData.isTrading and !_trade_connected:
        _connect_trade_button()

    # Task XP — monitor trader task completions
    _track_tasks()

    # Speed bonus — set Controller walk/sprint speeds
    _apply_speed_bonus()

    # Cold resistance is applied inside Character.gd Temperature() override.
    # No Main.gd compensation needed — running both was double-applying it.

func is_player_kill() -> bool:
    if Input.is_action_pressed("fire"):
        return true
    if gameData.isFiring:
        return true
    # Semi-auto fire window — button may be released before death is detected
    if _last_fire_time > 0 and (Time.get_ticks_msec() - _last_fire_time) <= FIRE_WINDOW_MS:
        return true
    if last_grenade_time > 0 and (Time.get_ticks_msec() - last_grenade_time) <= GRENADE_WINDOW_MS:
        return true
    return false

func _on_node_added(node: Node):
    # Recoil reduction on weapon equip
    if node is Node3D and node.name == "Recoil" and node.has_method("ApplyRecoil"):
        _apply_recoil_reduction.call_deferred(node)
        return

    # Composure — cache the camera hit-shake node so _physics_process can
    # scale its rotation without needing a Damage.gd override.
    if node is Node3D:
        var s: Script = node.get_script()
        if s and s.resource_path == "res://Scripts/Damage.gd":
            _damage_node = node
            return

    # AI tracking for kill XP — broadened detection for modded AI classes
    # that may not declare `boss` (e.g. custom factions).
    if "dead" in node and node.has_method("Death"):
        if node not in _tracked_ai:
            _tracked_ai.append(node)
        return

    # Trader tracking for task XP. We don't capture a baseline here because
    # tasksCompleted isn't yet populated — LoadTrader() fills it on interaction.
    # The real baseline lives in cfg_trader_task_counts (persisted in XPData.cfg).
    if "tasksCompleted" in node and "traderData" in node:
        _tracked_traders.append(weakref(node))
        return

func _apply_recoil_reduction(node: Node):
    if !is_instance_valid(node) or !"data" in node or !node.data:
        return
    var level = get_level(9)
    var prestige_reduction = prestige_recoil_bonus()
    if level <= 0 and prestige_reduction <= 0.0:
        return
    var mult = maxf(1.0 - (level * cfg_recoil_reduce) - prestige_reduction, 0.05)
    # Duplicate so we don't modify the shared weapon template resource
    node.data = node.data.duplicate()
    node.data.verticalRecoil *= mult
    node.data.horizontalRecoil *= mult
    node.data.kick *= mult

func is_skill_enabled(index: int) -> bool:
    if index < 0 or index >= skill_ids.size():
        return false
    return cfg_skill_enabled.get(skill_ids[index], true)

# --- Compat: Kill XP (replaces AI.gd override) ---

func _track_kills():
    # Step 1: drain freshly-dead AI into the pending bucket, keep the living.
    var now = Time.get_ticks_msec()
    var still_alive: Array = []
    for ai in _tracked_ai:
        if !is_instance_valid(ai):
            continue
        if ai.dead:
            _pending_kills.append({"ref": ai, "died_at": now})
        else:
            still_alive.append(ai)
    _tracked_ai = still_alive

    # Step 2: re-check is_player_kill() every frame within a grace window,
    # so a single-frame miss (physics vs process divergence, HellMAI's heavier
    # death pipeline, etc.) doesn't permanently lose the kill.
    if _pending_kills.is_empty():
        return
    var still_pending: Array = []
    for pk in _pending_kills:
        var ai = pk.ref
        if !is_instance_valid(ai):
            continue
        if is_player_kill():
            var is_boss: bool = ai.boss if "boss" in ai else false
            var xpReward = cfg_xp_boss if is_boss else cfg_xp_kill
            xp += xpReward
            xpTotal += xpReward
            SaveXP()
        elif (now - pk.died_at) < KILL_GRACE_MS:
            still_pending.append(pk)
    _pending_kills = still_pending

# --- Compat: Container/Search XP (replaces LootContainer.gd override) ---

func _check_container_xp():
    var ui = get_tree().current_scene.get_node_or_null("/root/Map/Core/UI")
    if !ui:
        return
    var iface = ui.get_node_or_null("Interface")
    if !iface or !"container" in iface or !iface.container:
        return
    var cid = iface.container.get_instance_id()
    if cid in _awarded_containers:
        return
    _awarded_containers[cid] = true
    # Accumulate fractional rewards so values like 0.3 actually work:
    # search ~4 containers = +1 XP. Whole-number configs award instantly.
    _container_xp_fraction += cfg_xp_container
    var whole: int = int(floor(_container_xp_fraction))
    if whole > 0:
        xp += whole
        xpTotal += whole
        _container_xp_fraction -= float(whole)
    SaveXP()
    # Scavenger skill — bonus loot from containers. Prestige grants a
    # permanent baseline chance even at skill level 0.
    if get_level(11) > 0 or prestige_scavenger_bonus() > 0.0:
        get_tree().create_timer(0.1).timeout.connect(_try_scavenge.bind(iface, ui))

func _try_scavenge(iface, ui_manager):
    var chance = get_level(11) * cfg_scavenger_chance + prestige_scavenger_bonus()
    if randf() >= chance:
        return
    if iface == null or !is_instance_valid(iface):
        return
    if !"containerGrid" in iface or iface.containerGrid == null:
        return
    if !"container" in iface or !iface.container:
        return
    var level = get_level(11)
    var roll = randf()
    var bonus_item = _try_loot_pool_spawn(level, roll, iface)
    if bonus_item:
        _show_scavenge_notify(ui_manager, bonus_item)
        return
    # Fallback: duplicate an existing container item
    var items = []
    for child in iface.containerGrid.get_children():
        if "slotData" in child:
            items.append(child)
    if items.is_empty():
        return
    var source_item = items[randi() % items.size()]
    if !source_item.slotData or !source_item.slotData.itemData:
        return
    var item_name = str(source_item.slotData.itemData.name)
    var dupe_data = source_item.slotData.duplicate()
    if !dupe_data or !dupe_data.itemData:
        return
    if dupe_data.itemData.stackable:
        dupe_data.amount = 1
    if iface.AutoStack(dupe_data, iface.containerGrid) or iface.Create(dupe_data, iface.containerGrid, true):
        _show_scavenge_notify(ui_manager, item_name)

func _try_loot_pool_spawn(level: int, roll: float, iface) -> String:
    if level <= 2:
        return ""
    # Access loot buckets from the current container
    var container = iface.container if "container" in iface else null
    if !container:
        return ""
    var commonBucket = container.commonBucket if "commonBucket" in container else []
    var rareBucket = container.rareBucket if "rareBucket" in container else []
    var legendaryBucket = container.legendaryBucket if "legendaryBucket" in container else []
    var bucket: Array = []
    if level == 3:
        if roll < 0.30 and commonBucket.size() > 0:
            bucket = commonBucket
    elif level == 4:
        if roll < 0.20 and rareBucket.size() > 0:
            bucket = rareBucket
        elif roll < 0.50 and commonBucket.size() > 0:
            bucket = commonBucket
    elif level >= 5:
        if roll < 0.10 and legendaryBucket.size() > 0:
            bucket = legendaryBucket
        elif roll < 0.35 and rareBucket.size() > 0:
            bucket = rareBucket
        elif roll < 0.60 and commonBucket.size() > 0:
            bucket = commonBucket
    if bucket.is_empty():
        return ""
    var item_data = bucket.pick_random()
    var new_slot = SlotData.new()
    new_slot.itemData = item_data
    if item_data.defaultAmount != 0:
        new_slot.amount = randi_range(1, item_data.defaultAmount)
    if item_data.type == "Weapon" or item_data.subtype == "Light" or item_data.subtype == "NVG":
        new_slot.condition = randi_range(25, 100)
    if iface.AutoStack(new_slot, iface.containerGrid) or iface.Create(new_slot, iface.containerGrid, true):
        return item_data.name
    return ""

func _load_scavenge_sfx():
    if _sfx_search:
        return
    var base = "res://mods/XPSkillsSystem/sounds"
    var f = FileAccess.open(base + "/search.mp3", FileAccess.READ)
    if f:
        _sfx_search = AudioStreamMP3.new()
        _sfx_search.data = f.get_buffer(f.get_length())
        f.close()

func _show_scavenge_notify(ui_manager, item_name: String):
    if cfg_scavenger_sfx_enabled:
        _load_scavenge_sfx()
        if _sfx_search:
            var player = AudioStreamPlayer.new()
            player.stream = _sfx_search
            # Linear 0-100 → dB. 100 = 0 dB (unchanged), 0 = silent (-60 dB
            # floor). linear_to_db maps 1.0 → 0 dB, 0.01 → ~-40 dB.
            var linear: float = clamp(cfg_scavenger_sfx_volume / 100.0, 0.0, 1.0)
            player.volume_db = linear_to_db(linear) if linear > 0.001 else -60.0
            get_tree().root.add_child(player)
            player.play()
            player.finished.connect(player.queue_free)
    var label = Label.new()
    label.text = "⭐ Scavenger: +1 " + item_name
    label.add_theme_font_size_override("font_size", 16)
    label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.anchors_preset = Control.PRESET_CENTER_TOP
    label.offset_top = 60
    label.z_index = 100
    ui_manager.add_child(label)
    var tween = label.create_tween()
    tween.tween_property(label, "modulate:a", 0.0, 1.5).set_delay(1.0)
    tween.tween_callback(label.queue_free)

# --- Compat: Trade XP (replaces Interface.gd trade hook) ---

func _connect_trade_button():
    var ui = get_tree().current_scene.get_node_or_null("/root/Map/Core/UI")
    if !ui:
        return
    var iface = ui.get_node_or_null("Interface")
    if !iface:
        return
    var btn = iface.get_node_or_null("Deal/Panel/Buttons/Accept")
    if btn and btn is Button:
        if !btn.pressed.is_connected(_on_trade_accept):
            btn.pressed.connect(_on_trade_accept)
        _trade_btn = btn
        _trade_connected = true

func _on_trade_accept():
    xp += cfg_xp_trade
    xpTotal += cfg_xp_trade
    SaveXP()

# --- Compat: Task XP (replaces Trader.gd override) ---

func _track_tasks():
    var still_valid: Array = []
    var awarded := false
    for wref in _tracked_traders:
        var trader = wref.get_ref()
        if !trader or !is_instance_valid(trader):
            continue
        still_valid.append(wref)
        # traderData may load slightly after the node is added; skip until ready
        if !("traderData" in trader) or trader.traderData == null:
            continue
        var key: String = str(trader.traderData.name)
        if key.is_empty():
            continue
        var current_count: int = trader.tasksCompleted.size()
        # First sight: seed the baseline. _sync_trader_baselines_from_save() has
        # already run on menu→game to seed historical counts from Traders.tres,
        # so this only fires for truly new traders or new games.
        if not cfg_trader_task_counts.has(key):
            cfg_trader_task_counts[key] = current_count
            continue
        var baseline: int = cfg_trader_task_counts[key]
        if current_count > baseline:
            var completed = current_count - baseline
            xp += cfg_xp_task * completed
            xpTotal += cfg_xp_task * completed
            cfg_trader_task_counts[key] = current_count
            awarded = true
        # Never ratchet the baseline DOWN here. On zone reload the trader is
        # re-instantiated with an empty tasksCompleted until LoadTrader() runs,
        # which would otherwise look like "save wiped" and re-award history
        # on the next repopulate. New games are handled by ResetXP().
    _tracked_traders = still_valid
    if awarded:
        SaveXP()

func _sync_trader_baselines_from_save():
    # Read user://Traders.tres (the base game's authoritative task list) and
    # seed cfg_trader_task_counts for any trader not already tracked. Fixes
    # the first-install scenario where a player has historical trader progress
    # that we'd otherwise miscount once LoadTrader() repopulates tasksCompleted.
    # Uses has() so fresher in-session values are never overwritten.
    if !FileAccess.file_exists("user://Traders.tres"):
        return
    var save = load("user://Traders.tres")
    if save == null:
        return
    # Duck-type instead of `is TraderSave` — the class_name registry may not
    # be ready yet, and any future save format adding new trader sections
    # shouldn't break us either.
    for trader_name in ["Generalist", "Doctor", "Gunsmith", "Grandma"]:
        if cfg_trader_task_counts.has(trader_name):
            continue
        var prop = trader_name.to_lower()
        if prop in save and save.get(prop) is Array:
            cfg_trader_task_counts[trader_name] = save.get(prop).size()

# --- Compat: Speed bonus (replaces Controller.gd override) ---

func _apply_speed_bonus():
    var level = get_level(10)
    var prestige_bonus = prestige_speed_bonus()
    if level <= 0 and prestige_bonus <= 0.0:
        return
    # Never touch the Controller mid-scene-load — is_instance_valid can return
    # true during teardown, and writing to a half-freed node crashes. Users
    # reported this as the athleticism zone-transition CTD.
    if "isTransitioning" in gameData and gameData.isTransitioning:
        return
    if "isCaching" in gameData and gameData.isCaching:
        return
    var bonus = 1.0 + (level * cfg_speed_bonus) + prestige_bonus
    if _controller_ref and is_instance_valid(_controller_ref) and _controller_ref.is_inside_tree():
        _controller_ref.sprintSpeed = _controller_base_sprint * bonus
        _controller_ref.walkSpeed = _controller_base_walk * bonus
        return
    # Stale or first-contact — lazy re-lookup.
    _controller_ref = null
    var scene = get_tree().current_scene
    if !scene:
        return
    var ctrl = scene.get_node_or_null("/root/Map/Core/Controller")
    if ctrl and ctrl.is_inside_tree() and "sprintSpeed" in ctrl and "walkSpeed" in ctrl:
        _controller_ref = ctrl
        # Capture the REAL base speeds before we modify them, so compatible mods
        # that bump base speed (or the game applying injury/state penalties)
        # stack correctly with ours instead of being stomped.
        _controller_base_walk = ctrl.walkSpeed
        _controller_base_sprint = ctrl.sprintSpeed
        ctrl.sprintSpeed = _controller_base_sprint * bonus
        ctrl.walkSpeed = _controller_base_walk * bonus

func _reset_session_state():
    # Drop all per-run caches. Called on entering the main menu so the next
    # run starts clean — prevents stale Node refs across Map reloads and
    # caps _awarded_containers growth.
    _awarded_containers.clear()
    _pending_kills.clear()
    _tracked_ai.clear()
    _tracked_traders.clear()
    _controller_ref = null
    _trade_btn = null
    _trade_connected = false
    _damage_node = null
    _sb_last_scene_name = ""

# --- Compat: Composure (reduces camera shake on hits) ---

func _physics_process(_delta):
    # Scale down the rotation Damage.gd just wrote when the player has
    # Composure skill or prestige ranks. We run after Damage.gd thanks to
    # process_physics_priority, so rotation already holds this frame's value.
    if gameData.menu or gameData.shelter:
        return
    if not gameData.damage and not gameData.impact:
        return
    var level = get_level(12)
    var prestige_bonus = prestige_composure_bonus()
    if level <= 0 and prestige_bonus <= 0.0:
        return
    if not _damage_node or not is_instance_valid(_damage_node):
        return
    var mult = maxf(1.0 - (level * cfg_shake_reduce) - prestige_bonus, 0.05)
    _damage_node.rotation *= mult

func get_level(index: int) -> int:
    if not is_skill_enabled(index):
        return 0
    match index:
        0: return xpHealth
        1: return xpStamina
        2: return xpCarry
        3: return xpHunger
        4: return xpThirst
        5: return xpMental
        6: return xpRegen
        7: return xpColdRes
        8: return xpStealth
        9: return xpRecoil
        10: return xpSpeed
        11: return xpScavenger
        12: return xpComposure
    return 0

# ─── Prestige helpers ─────────────────────────────────────────

func get_prestige_count(skill_index: int) -> int:
    if skill_index < 0 or skill_index >= skill_ids.size():
        return 0
    return int(prestige_counts.get(skill_ids[skill_index], 0))

func get_prestige_cap(skill_index: int) -> int:
    if skill_index < 0 or skill_index >= cfg_prestige_caps.size():
        return 10
    return int(cfg_prestige_caps[skill_index])

func can_prestige_skill(skill_index: int) -> bool:
    # A skill can receive more prestige ranks if its cap is unlimited (-1)
    # or if its current rank count is below the cap.
    var cap = get_prestige_cap(skill_index)
    if cap < 0:
        return true
    return get_prestige_count(skill_index) < cap

func is_prestige_available() -> bool:
    # Unlocked when every ENABLED skill is at its max level, and at least
    # one skill is enabled. Returns false if the prestige feature itself
    # is disabled in MCM.
    if not cfg_prestige_enabled:
        return false
    var has_enabled := false
    for i in skill_ids.size():
        if is_skill_enabled(i):
            has_enabled = true
            if get_level(i) < cfg_max_levels[i]:
                return false
    return has_enabled

func do_prestige(skill_index: int) -> bool:
    # Sanity checks — callers (UI) should already verify these, but be
    # defensive since prestige is destructive.
    if not is_prestige_available():
        return false
    if skill_index < 0 or skill_index >= skill_ids.size():
        return false
    if not can_prestige_skill(skill_index):
        return false
    # Wipe all XP and stored skill levels. _zero_xp_state clears the XP
    # state but NOT prestige_counts, which is the whole point.
    _zero_xp_state()
    var sid: String = skill_ids[skill_index]
    prestige_counts[sid] = int(prestige_counts.get(sid, 0)) + 1
    SaveXP()
    _save_prestige()
    _sync_to_gamedata()
    return true

# Per-skill additive prestige bonuses. Callers (Character.gd, Interface.gd,
# and Main.gd's own compat polling) add these to the skill-tree bonus so
# prestige is a permanent baseline that stacks on top of leveling.

func prestige_hp_bonus() -> float:
    return get_prestige_count(0) * cfg_prestige_hp

func prestige_stamina_bonus() -> float:
    return get_prestige_count(1) * cfg_prestige_stamina

func prestige_carry_bonus() -> float:
    return get_prestige_count(2) * cfg_prestige_carry

func prestige_hunger_bonus() -> float:
    return get_prestige_count(3) * cfg_prestige_hunger

func prestige_thirst_bonus() -> float:
    return get_prestige_count(4) * cfg_prestige_thirst

func prestige_mental_bonus() -> float:
    return get_prestige_count(5) * cfg_prestige_mental

func prestige_regen_bonus() -> float:
    return get_prestige_count(6) * cfg_prestige_regen

func prestige_coldres_bonus() -> float:
    return get_prestige_count(7) * cfg_prestige_coldres

func prestige_stealth_bonus() -> float:
    return get_prestige_count(8) * cfg_prestige_stealth

func prestige_recoil_bonus() -> float:
    return get_prestige_count(9) * cfg_prestige_recoil

func prestige_speed_bonus() -> float:
    return get_prestige_count(10) * cfg_prestige_speed

func prestige_scavenger_bonus() -> float:
    return get_prestige_count(11) * cfg_prestige_scavenger

func prestige_composure_bonus() -> float:
    return get_prestige_count(12) * cfg_prestige_composure

func _get_prestige_path() -> String:
    var profile = _get_active_profile()
    if profile.is_empty():
        return "user://XPPrestige.cfg"
    return "user://XPPrestige_" + profile + ".cfg"

func _save_prestige():
    var cfg = ConfigFile.new()
    for sid in prestige_counts.keys():
        cfg.set_value("prestige", sid, prestige_counts[sid])
    cfg.save(_get_prestige_path())

func _load_prestige():
    prestige_counts.clear()
    var cfg = ConfigFile.new()
    if cfg.load(_get_prestige_path()) != OK:
        return
    if cfg.has_section("prestige"):
        for key in cfg.get_section_keys("prestige"):
            prestige_counts[key] = int(cfg.get_value("prestige", key, 0))

# --- MCM Integration ---

func _try_load_mcm():
    if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
        return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
    return null

func _register_mcm():
    var _config = ConfigFile.new()

    var skill_names_display = ["Vitality", "Endurance", "Pack Mule", "Hunger Resist", "Thirst Resist", "Iron Will", "Regeneration", "Cold Resistance", "Stealth", "Recoil Control", "Athleticism", "Scavenger", "Composure"]
    var menu_pos = 1
    for i in skill_ids.size():
        _config.set_value("Bool", "cfg_skill_" + skill_ids[i], {
            "name" = "Enable " + skill_names_display[i],
            "tooltip" = "Show " + skill_names_display[i] + " in the Skills menu",
            "default" = true, "value" = true,
            "menu_pos" = menu_pos
        })
        menu_pos += 1

    _config.set_value("Float", "cfg_xp_container", {
        "name" = "Container Search XP",
        "tooltip" = "XP earned per container (fractional values supported — e.g. 0.3 awards 1 XP per ~4 containers searched)",
        "default" = 1.0, "value" = 1.0,
        "minRange" = 0.0, "maxRange" = 5.0, "step" = 0.1,
        "menu_pos" = 13
    })
    _config.set_value("Int", "cfg_xp_kill", {
        "name" = "Enemy Kill XP",
        "tooltip" = "XP earned per enemy kill",
        "default" = 25, "value" = 25,
        "minRange" = 0, "maxRange" = 200,
        "menu_pos" = 14
    })
    _config.set_value("Int", "cfg_xp_boss", {
        "name" = "Boss Kill XP",
        "tooltip" = "XP earned per boss kill",
        "default" = 100, "value" = 100,
        "minRange" = 0, "maxRange" = 500,
        "menu_pos" = 15
    })
    _config.set_value("Int", "cfg_xp_trade", {
        "name" = "Trade XP",
        "tooltip" = "XP earned when completing a trade",
        "default" = 10, "value" = 10,
        "minRange" = 0, "maxRange" = 100,
        "menu_pos" = 16
    })
    _config.set_value("Int", "cfg_xp_task", {
        "name" = "Task Complete XP",
        "tooltip" = "XP earned when completing a task",
        "default" = 50, "value" = 50,
        "minRange" = 0, "maxRange" = 500,
        "menu_pos" = 17
    })
    _config.set_value("Bool", "cfg_death_resets", {
        "name" = "Death Resets XP",
        "tooltip" = "Reset all XP and skill levels on death",
        "default" = true, "value" = true,
        "menu_pos" = 18
    })
    _config.set_value("Int", "cfg_hp_per_level", {
        "name" = "HP Per Level",
        "tooltip" = "Max HP bonus per Vitality level",
        "default" = 5, "value" = 5,
        "minRange" = 1, "maxRange" = 25,
        "menu_pos" = 19
    })
    _config.set_value("Int", "cfg_stamina_reduce", {
        "name" = "Stamina Drain Reduce (%)",
        "tooltip" = "Stamina drain reduction per Endurance level (10 = 10% per level)",
        "default" = 10, "value" = 10,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 20
    })
    _config.set_value("Int", "cfg_carry_per_level", {
        "name" = "Carry Weight Per Level (kg)",
        "tooltip" = "Extra carry weight (kg) per Pack Mule level",
        "default" = 2, "value" = 2,
        "minRange" = 1, "maxRange" = 10,
        "menu_pos" = 21
    })
    _config.set_value("Int", "cfg_hunger_reduce", {
        "name" = "Hunger Drain Reduce (%)",
        "tooltip" = "Hunger drain reduction per Hunger Resist level (8 = 8% per level)",
        "default" = 8, "value" = 8,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 22
    })
    _config.set_value("Int", "cfg_thirst_reduce", {
        "name" = "Thirst Drain Reduce (%)",
        "tooltip" = "Thirst drain reduction per Thirst Resist level (8 = 8% per level)",
        "default" = 8, "value" = 8,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 23
    })
    _config.set_value("Int", "cfg_mental_reduce", {
        "name" = "Mental Drain Reduce (%)",
        "tooltip" = "Mental drain reduction per Iron Will level (8 = 8% per level)",
        "default" = 8, "value" = 8,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 24
    })
    _config.set_value("Float", "cfg_regen_per_level", {
        "name" = "Regen HP/s per Level",
        "tooltip" = "Passive HP regen per Regeneration skill level. Granular (0.01 steps) so you can tune it to taste. Default 0.02 means fully maxed Regen (skill 5) = 0.10 HP/s — about 17 minutes to heal from 0 to 100. Set to 0 to disable regen entirely.",
        "default" = 0.02, "value" = 0.02,
        "minRange" = 0.0, "maxRange" = 2.0, "step" = 0.01,
        "menu_pos" = 25
    })
    _config.set_value("Int", "cfg_coldres_reduce", {
        "name" = "Cold Resist Reduce (%)",
        "tooltip" = "Temperature loss reduction per Cold Resistance level (8 = 8% per level)",
        "default" = 8, "value" = 8,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 26
    })
    _config.set_value("Int", "cfg_stealth_reduce", {
        "name" = "Stealth Hearing Reduce (%)",
        "tooltip" = "AI hearing range reduction per Stealth level (5 = 5% per level)",
        "default" = 5, "value" = 5,
        "minRange" = 1, "maxRange" = 15,
        "menu_pos" = 27
    })
    _config.set_value("Int", "cfg_recoil_reduce", {
        "name" = "Recoil Reduce Per Level (%)",
        "tooltip" = "Weapon recoil reduction per Recoil Control level (5 = 5% per level)",
        "default" = 5, "value" = 5,
        "minRange" = 1, "maxRange" = 15,
        "menu_pos" = 28
    })
    _config.set_value("Int", "cfg_speed_bonus", {
        "name" = "Speed Bonus Per Level (%)",
        "tooltip" = "Movement speed increase per Athleticism level (4 = 4% per level)",
        "default" = 4, "value" = 4,
        "minRange" = 1, "maxRange" = 10,
        "menu_pos" = 29
    })
    _config.set_value("Int", "cfg_scavenger_chance", {
        "name" = "Scavenger Chance Per Level (%)",
        "tooltip" = "Chance to find extra loot per Scavenger level (5 = 5% per level)",
        "default" = 5, "value" = 5,
        "minRange" = 1, "maxRange" = 15,
        "menu_pos" = 30
    })
    _config.set_value("Int", "cfg_shake_reduce", {
        "name" = "Composure Shake Reduce Per Level (%)",
        "tooltip" = "Camera shake reduction when taking damage per Composure level (10 = 10% per level). Fully maxed at 5 levels reduces hit shake by 50%.",
        "default" = 10, "value" = 10,
        "minRange" = 1, "maxRange" = 20,
        "menu_pos" = 30.5
    })

    # ─── Prestige ───
    _config.set_value("Bool", "cfg_prestige_enabled", {
        "name" = "Enable Prestige",
        "tooltip" = "When ON, a 'Prestige' button appears at the bottom of the Skills panel once every enabled skill is maxed. Clicking it lets you wipe all XP and skill levels in exchange for a permanent bonus to one chosen stat.",
        "default" = true, "value" = true,
        "menu_pos" = 31
    })
    _config.set_value("Bool", "cfg_prestige_reset_on_death", {
        "name" = "Reset Prestige on Death",
        "tooltip" = "Hardcore option: when ON, dying wipes your prestige ranks along with your XP and skill levels. Default OFF (prestige is permanent).",
        "default" = false, "value" = false,
        "menu_pos" = 32
    })
    _config.set_value("Int", "cfg_prestige_hp", {
        "name" = "Prestige Max HP per Rank",
        "tooltip" = "Permanent max HP gained per Vitality prestige rank.",
        "default" = 3, "value" = 3,
        "minRange" = 0, "maxRange" = 20,
        "menu_pos" = 33
    })
    _config.set_value("Int", "cfg_prestige_stamina", {
        "name" = "Prestige Stamina Reduce per Rank (%)",
        "tooltip" = "Permanent stamina drain reduction per Endurance prestige rank.",
        "default" = 3, "value" = 3,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 34
    })
    _config.set_value("Int", "cfg_prestige_carry", {
        "name" = "Prestige Carry Weight per Rank (kg)",
        "tooltip" = "Permanent carry weight bonus per Pack Mule prestige rank.",
        "default" = 1, "value" = 1,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 35
    })
    _config.set_value("Int", "cfg_prestige_hunger", {
        "name" = "Prestige Hunger Reduce per Rank (%)",
        "tooltip" = "Permanent hunger drain reduction per Hunger Resist prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 36
    })
    _config.set_value("Int", "cfg_prestige_thirst", {
        "name" = "Prestige Thirst Reduce per Rank (%)",
        "tooltip" = "Permanent thirst drain reduction per Thirst Resist prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 37
    })
    _config.set_value("Int", "cfg_prestige_mental", {
        "name" = "Prestige Mental Reduce per Rank (%)",
        "tooltip" = "Permanent mental drain reduction per Iron Will prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 38
    })
    _config.set_value("Float", "cfg_prestige_regen", {
        "name" = "Prestige Regen HP/s per Rank",
        "tooltip" = "Permanent passive HP regen per Regeneration prestige rank. Stacks additively on top of the skill tree. Default 0.005 means one prestige rank ≈ 25% of a skill level at the default base regen rate, matching the other prestige stats.",
        "default" = 0.005, "value" = 0.005,
        "minRange" = 0.0, "maxRange" = 0.1, "step" = 0.001,
        "menu_pos" = 39
    })
    _config.set_value("Int", "cfg_prestige_coldres", {
        "name" = "Prestige Cold Resist per Rank (%)",
        "tooltip" = "Permanent cold drain reduction per Cold Resistance prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 40
    })
    _config.set_value("Int", "cfg_prestige_stealth", {
        "name" = "Prestige Stealth per Rank (%)",
        "tooltip" = "Permanent AI hearing reduction per Stealth prestige rank. Note: Stealth is currently a no-op since v2.0 dropped the AI.gd override.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 41
    })
    _config.set_value("Int", "cfg_prestige_recoil", {
        "name" = "Prestige Recoil Reduce per Rank (%)",
        "tooltip" = "Permanent weapon recoil reduction per Recoil Control prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 42
    })
    _config.set_value("Int", "cfg_prestige_speed", {
        "name" = "Prestige Speed per Rank (%)",
        "tooltip" = "Permanent movement speed bonus per Athleticism prestige rank.",
        "default" = 1, "value" = 1,
        "minRange" = 0, "maxRange" = 5,
        "menu_pos" = 43
    })
    _config.set_value("Int", "cfg_prestige_scavenger", {
        "name" = "Prestige Scavenger per Rank (%)",
        "tooltip" = "Permanent extra loot chance per Scavenger prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 44
    })
    _config.set_value("Int", "cfg_prestige_composure", {
        "name" = "Prestige Composure per Rank (%)",
        "tooltip" = "Permanent camera shake reduction per Composure prestige rank.",
        "default" = 2, "value" = 2,
        "minRange" = 0, "maxRange" = 10,
        "menu_pos" = 44.5
    })
    _config.set_value("Int", "cfg_prestige_cap", {
        "name" = "Prestige Rank Cap (non-Vitality)",
        "tooltip" = "Maximum prestige ranks any non-Vitality skill can accumulate. Vitality (Max HP) is always uncapped.",
        "default" = 10, "value" = 10,
        "minRange" = 1, "maxRange" = 50,
        "menu_pos" = 45
    })

    # ─── Skill Books ───
    _config.set_value("Bool", "cfg_skillbooks_enabled", {
        "name" = "Enable Skill Books",
        "tooltip" = "When ON, 9 dedicated skill books spawn as Rare civilian loot and can be read to grant XP into specific skills. Each book trains one skill (Fitness, Athletics, Meditation, Stealth, Scavenging) or two at 60% total split 50/50 (Medical: Vitality+Regen; Survival: Hunger+Thirst; Combat: Recoil+Composure; Arctic: Cold+Endurance). Toggling off removes them from new-loot rolls and disables the Read action; existing world/inventory books stay but become inert until re-enabled.",
        "default" = true, "value" = true,
        "menu_pos" = 46
    })
    _config.set_value("Int", "cfg_skillbook_base_xp", {
        "name" = "Skill Book Base XP",
        "tooltip" = "XP a solo-skill book (Fitness, Athletics, Meditation, Stealth, Scavenging) grants when read. Dual-skill books (Medical, Survival, Combat, Arctic) use the multiplier below and split the result evenly between their two skills.",
        "default" = 200, "value" = 200,
        "minRange" = 10, "maxRange" = 2000,
        "menu_pos" = 47
    })
    _config.set_value("Int", "cfg_skillbook_dual_multiplier", {
        "name" = "Dual-Skill Book Multiplier (%)",
        "tooltip" = "Dual-skill books grant this percentage of a solo book's base XP, split 50/50 between their two skills. 60 (default) means a dual book grants 0.6 × base, giving each skill 0.3 × base.",
        "default" = 60, "value" = 60,
        "minRange" = 0, "maxRange" = 200,
        "menu_pos" = 48
    })

    # ─── Scavenger SFX ───
    _config.set_value("Bool", "cfg_scavenger_sfx_enabled", {
        "name" = "Scavenger SFX Enabled",
        "tooltip" = "Play a sound cue when the Scavenger skill procs bonus loot from a container. Turn off for silent scavenging.",
        "default" = true, "value" = true,
        "menu_pos" = 49
    })
    _config.set_value("Int", "cfg_scavenger_sfx_volume", {
        "name" = "Scavenger SFX Volume (%)",
        "tooltip" = "Playback volume of the Scavenger bonus-loot sound cue. 100 = unchanged, 0 = silent (same as disabling).",
        "default" = 80, "value" = 80,
        "minRange" = 0, "maxRange" = 100,
        "menu_pos" = 50
    })

    if !FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
        DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
        _config.save(MCM_FILE_PATH + "/config.ini")
    else:
        # Migrate: cfg_regen_per_level (v2.2.3) and cfg_prestige_regen
        # (v2.2.4) both switched from Int sliders to granular Float sliders
        # and lowered their defaults. Strip the stale Int entries so MCM
        # doesn't keep the old values and overwrite our new defaults on
        # next save.
        var _saved = ConfigFile.new()
        if _saved.load(MCM_FILE_PATH + "/config.ini") == OK:
            var changed := false
            for stale_key in ["cfg_regen_per_level", "cfg_prestige_regen"]:
                if _saved.has_section_key("Int", stale_key):
                    _saved.erase_section_key("Int", stale_key)
                    changed = true
            if changed:
                _saved.save(MCM_FILE_PATH + "/config.ini")
        _mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, _config, MCM_FILE_PATH + "/config.ini")
        _config.load(MCM_FILE_PATH + "/config.ini")

    _apply_mcm_config(_config)

    _mcm_helpers.RegisterConfiguration(
        MCM_MOD_ID,
        "XP & Skills System",
        MCM_FILE_PATH,
        "Configure XP rewards, skill bonuses, and gameplay settings",
        {"config.ini" = _on_mcm_save}
    )

func _on_mcm_save(config: ConfigFile):
    _apply_mcm_config(config)
    # Re-run the ItemData patch so flipping "Enable Skill Books" in MCM
    # takes effect immediately instead of requiring a restart.
    _install_skillbook_hooks()
    var ui = Engine.get_meta("XPInterface", null)
    if ui:
        ui.RebuildSkills()

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
    var entry = config.get_value(section, key, null)
    if entry == null or not entry is Dictionary:
        return fallback
    return entry.get("value", fallback)

func _apply_mcm_config(config: ConfigFile):
    for sid in skill_ids:
        var key = "cfg_skill_" + sid
        if config.has_section_key("Bool", key):
            cfg_skill_enabled[sid] = _mcm_val(config, "Bool", key, cfg_skill_enabled.get(sid, true))
    cfg_xp_container = float(_mcm_val(config, "Float", "cfg_xp_container", cfg_xp_container))
    cfg_xp_kill = _mcm_val(config, "Int", "cfg_xp_kill", cfg_xp_kill)
    cfg_xp_boss = _mcm_val(config, "Int", "cfg_xp_boss", cfg_xp_boss)
    cfg_xp_trade = _mcm_val(config, "Int", "cfg_xp_trade", cfg_xp_trade)
    cfg_xp_task = _mcm_val(config, "Int", "cfg_xp_task", cfg_xp_task)
    cfg_death_resets = _mcm_val(config, "Bool", "cfg_death_resets", cfg_death_resets)
    cfg_hp_per_level = float(_mcm_val(config, "Int", "cfg_hp_per_level", 5))
    cfg_stamina_reduce = _mcm_val(config, "Int", "cfg_stamina_reduce", 10) / 100.0
    cfg_carry_per_level = float(_mcm_val(config, "Int", "cfg_carry_per_level", 2))
    cfg_hunger_reduce = _mcm_val(config, "Int", "cfg_hunger_reduce", 8) / 100.0
    cfg_thirst_reduce = _mcm_val(config, "Int", "cfg_thirst_reduce", 8) / 100.0
    cfg_mental_reduce = _mcm_val(config, "Int", "cfg_mental_reduce", 8) / 100.0
    cfg_regen_per_level = float(_mcm_val(config, "Float", "cfg_regen_per_level", cfg_regen_per_level))
    cfg_coldres_reduce = _mcm_val(config, "Int", "cfg_coldres_reduce", 8) / 100.0
    cfg_stealth_reduce = _mcm_val(config, "Int", "cfg_stealth_reduce", 5) / 100.0
    cfg_recoil_reduce = _mcm_val(config, "Int", "cfg_recoil_reduce", 5) / 100.0
    cfg_speed_bonus = _mcm_val(config, "Int", "cfg_speed_bonus", 4) / 100.0
    cfg_scavenger_chance = _mcm_val(config, "Int", "cfg_scavenger_chance", 5) / 100.0
    cfg_shake_reduce = _mcm_val(config, "Int", "cfg_shake_reduce", 10) / 100.0
    # Prestige
    cfg_prestige_enabled = _mcm_val(config, "Bool", "cfg_prestige_enabled", cfg_prestige_enabled)
    cfg_prestige_reset_on_death = _mcm_val(config, "Bool", "cfg_prestige_reset_on_death", cfg_prestige_reset_on_death)
    cfg_prestige_hp = float(_mcm_val(config, "Int", "cfg_prestige_hp", 3))
    cfg_prestige_stamina = _mcm_val(config, "Int", "cfg_prestige_stamina", 3) / 100.0
    cfg_prestige_carry = float(_mcm_val(config, "Int", "cfg_prestige_carry", 1))
    cfg_prestige_hunger = _mcm_val(config, "Int", "cfg_prestige_hunger", 2) / 100.0
    cfg_prestige_thirst = _mcm_val(config, "Int", "cfg_prestige_thirst", 2) / 100.0
    cfg_prestige_mental = _mcm_val(config, "Int", "cfg_prestige_mental", 2) / 100.0
    cfg_prestige_regen = float(_mcm_val(config, "Float", "cfg_prestige_regen", cfg_prestige_regen))
    cfg_prestige_coldres = _mcm_val(config, "Int", "cfg_prestige_coldres", 2) / 100.0
    cfg_prestige_stealth = _mcm_val(config, "Int", "cfg_prestige_stealth", 2) / 100.0
    cfg_prestige_recoil = _mcm_val(config, "Int", "cfg_prestige_recoil", 2) / 100.0
    cfg_prestige_speed = _mcm_val(config, "Int", "cfg_prestige_speed", 1) / 100.0
    cfg_prestige_scavenger = _mcm_val(config, "Int", "cfg_prestige_scavenger", 2) / 100.0
    cfg_prestige_composure = _mcm_val(config, "Int", "cfg_prestige_composure", 2) / 100.0
    # Skill Books
    cfg_skillbooks_enabled = _mcm_val(config, "Bool", "cfg_skillbooks_enabled", cfg_skillbooks_enabled)
    cfg_skillbook_base_xp = int(_mcm_val(config, "Int", "cfg_skillbook_base_xp", cfg_skillbook_base_xp))
    cfg_skillbook_dual_multiplier = _mcm_val(config, "Int", "cfg_skillbook_dual_multiplier", 60) / 100.0
    # Scavenger SFX
    cfg_scavenger_sfx_enabled = _mcm_val(config, "Bool", "cfg_scavenger_sfx_enabled", cfg_scavenger_sfx_enabled)
    cfg_scavenger_sfx_volume = int(_mcm_val(config, "Int", "cfg_scavenger_sfx_volume", cfg_scavenger_sfx_volume))
    # Rebuild caps array from the single non-Vitality cap slider. Vitality
    # stays uncapped (-1); every other slot uses the MCM value.
    var shared_cap = int(_mcm_val(config, "Int", "cfg_prestige_cap", 10))
    cfg_prestige_caps = [-1]
    for _i in range(skill_ids.size() - 1):
        cfg_prestige_caps.append(shared_cap)

# --- Fallback config (used when MCM is not installed) ---

func LoadConfig():
    var cfg = ConfigFile.new()
    if cfg.load("user://XPConfig.cfg") == OK:
        cfg_xp_container = float(cfg.get_value("xp_rewards", "container", 1.0))
        cfg_xp_kill = cfg.get_value("xp_rewards", "kill", 25)
        cfg_xp_boss = cfg.get_value("xp_rewards", "boss", 100)
        cfg_xp_trade = cfg.get_value("xp_rewards", "trade", 10)
        cfg_xp_task = cfg.get_value("xp_rewards", "task", 50)
        cfg_death_resets = cfg.get_value("gameplay", "death_resets_xp", true)
        cfg_hp_per_level = cfg.get_value("bonuses", "hp_per_level", 5.0)
        cfg_stamina_reduce = cfg.get_value("bonuses", "stamina_reduce", 0.10)
        cfg_carry_per_level = cfg.get_value("bonuses", "carry_per_level", 2.0)
        cfg_hunger_reduce = cfg.get_value("bonuses", "hunger_reduce", 0.08)
        cfg_thirst_reduce = cfg.get_value("bonuses", "thirst_reduce", 0.08)
        cfg_mental_reduce = cfg.get_value("bonuses", "mental_reduce", 0.08)
        cfg_regen_per_level = cfg.get_value("bonuses", "regen_per_level", 0.02)
        cfg_coldres_reduce = cfg.get_value("bonuses", "coldres_reduce", 0.08)
        cfg_stealth_reduce = cfg.get_value("bonuses", "stealth_reduce", 0.05)
        cfg_recoil_reduce = cfg.get_value("bonuses", "recoil_reduce", 0.05)
        cfg_speed_bonus = cfg.get_value("bonuses", "speed_bonus", 0.04)
        cfg_scavenger_chance = cfg.get_value("bonuses", "scavenger_chance", 0.05)
        cfg_shake_reduce = cfg.get_value("bonuses", "shake_reduce", 0.10)
        cfg_skillbooks_enabled = cfg.get_value("skillbooks", "enabled", true)
        cfg_skillbook_base_xp = int(cfg.get_value("skillbooks", "base_xp", 200))
        cfg_skillbook_dual_multiplier = float(cfg.get_value("skillbooks", "dual_multiplier", 0.6))
        cfg_scavenger_sfx_enabled = cfg.get_value("scavenger", "sfx_enabled", true)
        cfg_scavenger_sfx_volume = int(cfg.get_value("scavenger", "sfx_volume", 80))
        for sid in skill_ids:
            cfg_skill_enabled[sid] = cfg.get_value("toggles", sid, true)
        var ml = cfg.get_value("skills", "max_levels", "10,10,10,10,10,10,5,10,10,10,5,5,5")
        var cb = cfg.get_value("skills", "cost_bases", "25,25,20,20,20,20,50,20,25,25,30,30,25")
        cfg_max_levels = _parse_int_list(ml, [10, 10, 10, 10, 10, 10, 5, 10, 10, 10, 5, 5, 5])
        cfg_cost_bases = _parse_int_list(cb, [25, 25, 20, 20, 20, 20, 50, 20, 25, 25, 30, 30, 25])
    else:
        SaveConfig()

func SaveConfig():
    var cfg = ConfigFile.new()
    cfg.set_value("xp_rewards", "container", cfg_xp_container)
    cfg.set_value("xp_rewards", "kill", cfg_xp_kill)
    cfg.set_value("xp_rewards", "boss", cfg_xp_boss)
    cfg.set_value("xp_rewards", "trade", cfg_xp_trade)
    cfg.set_value("xp_rewards", "task", cfg_xp_task)
    cfg.set_value("gameplay", "death_resets_xp", cfg_death_resets)
    cfg.set_value("bonuses", "hp_per_level", cfg_hp_per_level)
    cfg.set_value("bonuses", "stamina_reduce", cfg_stamina_reduce)
    cfg.set_value("bonuses", "carry_per_level", cfg_carry_per_level)
    cfg.set_value("bonuses", "hunger_reduce", cfg_hunger_reduce)
    cfg.set_value("bonuses", "thirst_reduce", cfg_thirst_reduce)
    cfg.set_value("bonuses", "mental_reduce", cfg_mental_reduce)
    cfg.set_value("bonuses", "regen_per_level", cfg_regen_per_level)
    cfg.set_value("bonuses", "coldres_reduce", cfg_coldres_reduce)
    cfg.set_value("bonuses", "stealth_reduce", cfg_stealth_reduce)
    cfg.set_value("bonuses", "recoil_reduce", cfg_recoil_reduce)
    cfg.set_value("bonuses", "speed_bonus", cfg_speed_bonus)
    cfg.set_value("bonuses", "scavenger_chance", cfg_scavenger_chance)
    cfg.set_value("bonuses", "shake_reduce", cfg_shake_reduce)
    cfg.set_value("skillbooks", "enabled", cfg_skillbooks_enabled)
    cfg.set_value("skillbooks", "base_xp", cfg_skillbook_base_xp)
    cfg.set_value("skillbooks", "dual_multiplier", cfg_skillbook_dual_multiplier)
    cfg.set_value("scavenger", "sfx_enabled", cfg_scavenger_sfx_enabled)
    cfg.set_value("scavenger", "sfx_volume", cfg_scavenger_sfx_volume)
    for sid in skill_ids:
        cfg.set_value("toggles", sid, cfg_skill_enabled[sid])
    var ml = ",".join(cfg_max_levels.map(func(v): return str(v)))
    var cb = ",".join(cfg_cost_bases.map(func(v): return str(v)))
    cfg.set_value("skills", "max_levels", ml)
    cfg.set_value("skills", "cost_bases", cb)
    cfg.save("user://XPConfig.cfg")

func _parse_int_list(s, fallback: Array) -> Array:
    if s is Array: return s
    var parts = str(s).split(",")
    var result = []
    for p in parts:
        result.append(int(p.strip_edges()))
    if result.size() != fallback.size(): return fallback
    return result

func SaveXP():
    var path = _get_xp_data_path()
    var cfg = ConfigFile.new()
    cfg.set_value("xp", "xp", xp)
    cfg.set_value("xp", "xpTotal", xpTotal)
    cfg.set_value("xp", "xpHealth", xpHealth)
    cfg.set_value("xp", "xpStamina", xpStamina)
    cfg.set_value("xp", "xpCarry", xpCarry)
    cfg.set_value("xp", "xpHunger", xpHunger)
    cfg.set_value("xp", "xpThirst", xpThirst)
    cfg.set_value("xp", "xpMental", xpMental)
    cfg.set_value("xp", "xpRegen", xpRegen)
    cfg.set_value("xp", "xpColdRes", xpColdRes)
    cfg.set_value("xp", "xpStealth", xpStealth)
    cfg.set_value("xp", "xpRecoil", xpRecoil)
    cfg.set_value("xp", "xpSpeed", xpSpeed)
    cfg.set_value("xp", "xpScavenger", xpScavenger)
    cfg.set_value("xp", "xpComposure", xpComposure)
    cfg.set_value("xp", "container_fraction", _container_xp_fraction)
    for trader_name in cfg_trader_task_counts.keys():
        cfg.set_value("trader_task_counts", trader_name, cfg_trader_task_counts[trader_name])
    for sid in skill_xp_pool.keys():
        cfg.set_value("skillbook_pool", sid, float(skill_xp_pool[sid]))
    cfg.save(path)
    _sync_to_gamedata()
    _ensure_marker()

func _sync_to_gamedata():
    # Obsolete under MML v3.0.0 / vanilla post-Apr-2026: base-game GameData.gd
    # no longer declares xp / xpHealth / xpCarry / xpRegen / etc. (those fields
    # lived in a modded pck). Mod-local state on XPMain (this instance) is now
    # the single source of truth — hook callbacks and UI read it directly.
    # Call site kept so SaveXP doesn't have to know about this change.
    pass

func LoadXP():
    var path = _get_xp_data_path()
    # First-time Patty Profiles migration: if the profile-specific file
    # doesn't exist yet but a legacy user://XPData.cfg does, pull it forward
    # so existing progression isn't lost. Delete the legacy afterwards so
    # subsequent new profiles start clean instead of inheriting the first
    # profile's data on every LoadXP.
    if path != "user://XPData.cfg" and !FileAccess.file_exists(path) and FileAccess.file_exists("user://XPData.cfg"):
        _copy_file_bytes("user://XPData.cfg", path)
        DirAccess.remove_absolute(ProjectSettings.globalize_path("user://XPData.cfg"))
    # Zero in-memory state before loading so switching to a profile with no
    # saved file leaves us cleanly at zero instead of carrying the previous
    # profile's XP/skill levels.
    _zero_xp_state()
    var cfg = ConfigFile.new()
    if cfg.load(path) == OK:
        xp = cfg.get_value("xp", "xp", 0)
        xpTotal = cfg.get_value("xp", "xpTotal", 0)
        xpHealth = cfg.get_value("xp", "xpHealth", 0)
        xpStamina = cfg.get_value("xp", "xpStamina", 0)
        xpCarry = cfg.get_value("xp", "xpCarry", 0)
        xpHunger = cfg.get_value("xp", "xpHunger", 0)
        xpThirst = cfg.get_value("xp", "xpThirst", 0)
        xpMental = cfg.get_value("xp", "xpMental", 0)
        xpRegen = cfg.get_value("xp", "xpRegen", 0)
        xpColdRes = cfg.get_value("xp", "xpColdRes", 0)
        xpStealth = cfg.get_value("xp", "xpStealth", 0)
        xpRecoil = cfg.get_value("xp", "xpRecoil", 0)
        xpSpeed = cfg.get_value("xp", "xpSpeed", 0)
        xpScavenger = cfg.get_value("xp", "xpScavenger", 0)
        xpComposure = cfg.get_value("xp", "xpComposure", 0)
        _container_xp_fraction = float(cfg.get_value("xp", "container_fraction", 0.0))
        if cfg.has_section("trader_task_counts"):
            for trader_name in cfg.get_section_keys("trader_task_counts"):
                cfg_trader_task_counts[trader_name] = cfg.get_value("trader_task_counts", trader_name, 0)
        if cfg.has_section("skillbook_pool"):
            for sid in cfg.get_section_keys("skillbook_pool"):
                skill_xp_pool[sid] = float(cfg.get_value("skillbook_pool", sid, 0.0))
    _last_xp_path = path
    # Prestige lives in its own file so it survives ResetXP. Load it here
    # so the active profile's prestige ranks are in memory for Character.gd
    # and the UI to read.
    _load_prestige()
    _sync_to_gamedata()

func _zero_xp_state():
    xp = 0
    xpTotal = 0
    xpHealth = 0
    xpStamina = 0
    xpCarry = 0
    xpHunger = 0
    xpThirst = 0
    xpMental = 0
    xpRegen = 0
    xpColdRes = 0
    xpStealth = 0
    xpRecoil = 0
    xpSpeed = 0
    xpScavenger = 0
    xpComposure = 0
    _container_xp_fraction = 0.0
    cfg_trader_task_counts.clear()
    skill_xp_pool.clear()

func ResetXP():
    _zero_xp_state()
    var path = _get_xp_data_path()
    if FileAccess.file_exists(path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
    # Prestige normally survives death. The MCM hardcore toggle opts in to
    # also wiping prestige on every death reset.
    if cfg_prestige_reset_on_death:
        prestige_counts.clear()
        var pp = _get_prestige_path()
        if FileAccess.file_exists(pp):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(pp))
    _sync_to_gamedata()

func _ensure_marker():
    if !FileAccess.file_exists("user://XPSkillsMarker.tres"):
        var marker = Resource.new()
        ResourceSaver.save(marker, "user://XPSkillsMarker.tres")

func award_skillbook_xp(item_data):
    if !cfg_skillbooks_enabled or item_data == null:
        return
    if !("file" in item_data):
        return
    var file_name: String = str(item_data.file)
    if not _skillbook_catalog.has(file_name):
        return
    var listed: Array = _skillbook_catalog[file_name].skills
    # Same XP budget regardless of how many slots end up disabled — a dual
    # book always grants `base × dual_multiplier`, a solo book always grants
    # `base`. Disabled slots redirect their share to the general XP pool
    # instead of being dropped, so reading a book is never a total waste.
    var total_xp: float = float(cfg_skillbook_base_xp)
    if listed.size() > 1:
        total_xp *= cfg_skillbook_dual_multiplier
    var xp_per_slot: float = total_xp / float(listed.size())
    var general_fallback: float = 0.0
    for sid in listed:
        var idx = skill_ids.find(sid)
        if idx >= 0 and is_skill_enabled(idx):
            skill_xp_pool[sid] = float(skill_xp_pool.get(sid, 0.0)) + xp_per_slot
            _try_level_up_from_pool(sid)
        else:
            general_fallback += xp_per_slot
    if general_fallback > 0.0:
        var g: int = int(round(general_fallback))
        xp += g
    xpTotal += int(round(total_xp))
    SaveXP()
    var ui = Engine.get_meta("XPInterface", null)
    if ui and ui.has_method("UpdateSkillsUI"):
        ui.UpdateSkillsUI()

func _try_level_up_from_pool(sid: String):
    var idx = skill_ids.find(sid)
    if idx < 0:
        return
    if !is_skill_enabled(idx):
        return
    var current_level: int = get_level(idx)
    var max_level: int = int(cfg_max_levels[idx])
    var pool: float = float(skill_xp_pool.get(sid, 0.0))
    while current_level < max_level:
        var cost: float = float(cfg_cost_bases[idx]) * float(current_level + 1)
        if pool < cost:
            break
        pool -= cost
        current_level += 1
        _set_level_by_index(idx, current_level)
    # Drop stranded XP once the skill is maxed — otherwise the pool grows
    # forever and survives into the next run via SaveXP.
    if current_level >= max_level:
        pool = 0.0
    skill_xp_pool[sid] = pool

func _set_level_by_index(idx: int, value: int):
    match idx:
        0: xpHealth = value
        1: xpStamina = value
        2: xpCarry = value
        3: xpHunger = value
        4: xpThirst = value
        5: xpMental = value
        6: xpRegen = value
        7: xpColdRes = value
        8: xpStealth = value
        9: xpRecoil = value
        10: xpSpeed = value
        11: xpScavenger = value
        12: xpComposure = value
        _: push_warning("[XP Skills] _set_level_by_index: unknown skill index " + str(idx))

func _character_initial_spawn() -> bool:
    # Loader.NewGame() sets initialSpawn = true; Loader.SaveCharacter()
    # clears it on the first save, so CACHE_MODE_IGNORE is required —
    # a cached copy would return stale true after the first save.
    if !FileAccess.file_exists("user://Character.tres"):
        return false
    var res = ResourceLoader.load("user://Character.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
    if res == null:
        return false
    if not ("initialSpawn" in res):
        return false
    return res.initialSpawn == true
