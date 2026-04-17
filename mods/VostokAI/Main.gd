extends Node

# Vostok AI — Tactical Overhaul
# Autoload: registers the AI.gd override, hosts the squad coordinator,
# and exposes per-run tactical state to each AI instance via Engine meta.

const MCM_MOD_ID := "VostokAI"
const MCM_FILE_PATH := "user://MCM/VostokAI"
const LOCAL_CFG := "user://VostokAI_settings.cfg"

const _AIOverridePath := "res://mods/VostokAI/AI.gd"
const _AISpawnerOverridePath := "res://mods/VostokAI/AISpawner.gd"

# ─── Config (MCM-backed) ─────────────────────────────────────────────

var cfg_enabled: bool = true
var cfg_personalities_on: bool = true
var cfg_squad_on: bool = true
var cfg_suppression_on: bool = true
var cfg_damage_react_on: bool = true
var cfg_hearing_on: bool = true
var cfg_investigation_on: bool = true
var cfg_difficulty_scaling_on: bool = true

# Base difficulty multiplier (applied on top of XP scaling)
var cfg_difficulty: float = 1.0           # 0.5..2.0 accuracy multiplier

# Hearing ranges (m)
var cfg_hear_gunshot: float = 250.0
var cfg_hear_running: float = 40.0
var cfg_hear_walking: float = 12.0
var cfg_hear_crouch: float = 5.0

# Squad coordination radius (m)
var cfg_squad_radius: float = 50.0

# Personality weights (relative, normalized at use)
var cfg_weight_coward: int = 15
var cfg_weight_aggressor: int = 25
var cfg_weight_methodical: int = 30
var cfg_weight_guard: int = 20
var cfg_weight_frenzy: int = 10

# Group spawning + squad cohesion
var cfg_group_spawn_on: bool = true
var cfg_group_spawn_chance: float = 0.35   # Roll per SpawnWanderer call
var cfg_group_min: int = 2
var cfg_group_max: int = 4
var cfg_squad_cohesion_on: bool = true
var cfg_cohesion_distance: float = 25.0    # Max follower-to-leader distance

# v1.2 features
var cfg_reaction_time_on: bool = true
var cfg_panic_on: bool = true
var cfg_call_backup_on: bool = true
var cfg_backup_cooldown_ms: int = 45000    # World-wide cooldown between backup calls
var cfg_weapon_roles_on: bool = true
var cfg_formations_on: bool = true

# Shared state for call-for-backup rate limiting
var _last_backup_call_ms: int = 0

var _mcm_helpers = null

# ─── Squad coordinator state ─────────────────────────────────────────

# Registry of all active AI agents (not squad-grouped — we use proximity
# for callouts, so a single flat list is enough for the game's ~3-10
# active agents at a time).
var _agents: Array = []

# Per-agent flanking slot assignment. Slot is one of "LEFT", "RIGHT",
# "CENTER" — set when an agent enters Combat. Released on state exit.
var _flank_slots: Dictionary = {}   # agent -> slot string

# Alert decay — when a sighting is broadcast, this bumps up so broadcasts
# aren't duplicated back-to-back between ticks.
var _last_broadcast_time_ms: int = 0

var gameData = preload("res://Resources/GameData.tres")

# ─── Lifecycle ───────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.set_meta("VostokAIMain", self)

	_mcm_helpers = _try_load_mcm()
	if _mcm_helpers:
		_register_mcm()
	else:
		_load_local_config()

	if cfg_enabled:
		_install_override(_AIOverridePath)
		_install_override(_AISpawnerOverridePath)

func _install_override(path: String) -> void:
	# Replace the targeted vanilla script with our override. Must run before
	# the first map instantiates the AI pool / AISpawner node.
	var script: Script = load(path)
	if script == null:
		push_warning("Vostok AI: could not load override script at " + path)
		return
	script.reload()
	var base: Script = script.get_base_script()
	if base == null:
		push_warning("Vostok AI: override has no base script — " + path)
		return
	script.take_over_path(base.resource_path)
	print("[VostokAI] Override installed: ", base.resource_path)

# ─── Squad registry ──────────────────────────────────────────────────

func register_agent(agent: Node) -> void:
	if not _agents.has(agent):
		_agents.append(agent)

func unregister_agent(agent: Node) -> void:
	_agents.erase(agent)
	_flank_slots.erase(agent)
	# Recompute flank slots for remaining squadmates in combat
	_rebalance_flanks()

func _alive_agents() -> Array:
	var out: Array = []
	for a in _agents:
		if is_instance_valid(a) and not a.get("dead"):
			out.append(a)
	return out

# ─── Sighting broadcast ──────────────────────────────────────────────

# Called by an AI when it sees the player (or hears a shot or takes damage).
# Nearby allies within callout radius have their LKL updated and are
# encouraged to transition into combat if they were idle.
func broadcast_sighting(source: Node, location: Vector3) -> void:
	if not cfg_squad_on:
		return
	if not is_instance_valid(source):
		return
	# Throttle — one broadcast per 500ms to avoid decision storms
	var now := Time.get_ticks_msec()
	if now - _last_broadcast_time_ms < 500:
		return
	_last_broadcast_time_ms = now

	var radius := cfg_squad_radius
	for ally in _alive_agents():
		if ally == source:
			continue
		var dist: float = ally.global_position.distance_to(source.global_position)
		if dist > radius:
			continue
		# Pass callout to ally — they decide how to react based on their
		# personality and current state.
		if ally.has_method("vai_receive_callout"):
			ally.vai_receive_callout(location, source)

# Called on AI death. Nearby squadmates are immediately alerted with a
# higher urgency — a squadmate dying tells you exactly where the threat is.
func broadcast_death(source: Node, location: Vector3) -> void:
	if not cfg_squad_on:
		return
	if not is_instance_valid(source):
		return
	var radius := cfg_squad_radius * 1.5   # death travels further than words
	for ally in _alive_agents():
		if ally == source:
			continue
		var dist: float = ally.global_position.distance_to(source.global_position)
		if dist > radius:
			continue
		if ally.has_method("vai_receive_death_alert"):
			ally.vai_receive_death_alert(location, source)

# ─── Flanking slot assignment ───────────────────────────────────────

# When an AI enters combat, it requests a flanking slot so squadmates
# spread out across LEFT/RIGHT/CENTER wings instead of bunching together.
# We assign slots round-robin among currently-in-combat allies.
const FLANK_SLOTS := ["LEFT", "RIGHT", "CENTER"]

func request_flank_slot(agent: Node) -> String:
	if not cfg_squad_on:
		return "CENTER"
	# Count current assignments
	var counts := {"LEFT": 0, "RIGHT": 0, "CENTER": 0}
	for a in _flank_slots.keys():
		if is_instance_valid(a) and not a.get("dead"):
			counts[_flank_slots[a]] += 1
		else:
			_flank_slots.erase(a)
	# Pick the least-populated slot
	var best_slot := "CENTER"
	var best_count := 999
	for slot in FLANK_SLOTS:
		if counts[slot] < best_count:
			best_count = counts[slot]
			best_slot = slot
	_flank_slots[agent] = best_slot
	return best_slot

func release_flank_slot(agent: Node) -> void:
	_flank_slots.erase(agent)

func _rebalance_flanks() -> void:
	# Prune stale references
	for a in _flank_slots.keys():
		if not is_instance_valid(a) or a.get("dead"):
			_flank_slots.erase(a)

# ─── Personality assignment ─────────────────────────────────────────

# Called by an AI during its Initialize pass. Returns a personality string
# that will bias all future decisions for this agent. Weights are shifted
# by player progression (difficulty scaling).
func pick_personality() -> String:
	if not cfg_personalities_on:
		return "GUARD"   # vanilla-ish fallback
	var scaling := _get_progression_scale()   # 0..1
	# Apply scaling: higher XP → shift weights toward methodical + aggressor
	var coward := float(cfg_weight_coward) * (1.0 - scaling * 0.5)
	var aggressor := float(cfg_weight_aggressor) * (1.0 + scaling * 0.4)
	var methodical := float(cfg_weight_methodical) * (1.0 + scaling * 0.3)
	var guard := float(cfg_weight_guard)
	var frenzy := float(cfg_weight_frenzy) * (1.0 + scaling * 0.2)
	var total := coward + aggressor + methodical + guard + frenzy
	if total <= 0.0:
		return "GUARD"
	var roll := randf() * total
	if roll < coward:       return "COWARD"
	roll -= coward
	if roll < aggressor:    return "AGGRESSOR"
	roll -= aggressor
	if roll < methodical:   return "METHODICAL"
	roll -= methodical
	if roll < guard:        return "GUARD"
	return "FRENZY"

# Difficulty multiplier applied to AI accuracy + reaction speed.
# Returns 0..1 range based on player progression.
func _get_progression_scale() -> float:
	if not cfg_difficulty_scaling_on:
		return 0.0
	var xp := 0
	var xp_mod = Engine.get_meta("XPMain", null)
	if xp_mod and "xpTotal" in xp_mod:
		xp = xp_mod.xpTotal
	elif "xpTotal" in gameData:
		xp = gameData.xpTotal
	# Map XP to 0..1 scale
	if xp < 200:    return 0.0
	if xp < 1000:   return 0.33
	if xp < 3000:   return 0.66
	return 1.0

func get_accuracy_mult() -> float:
	var base: float = cfg_difficulty
	var scale: float = _get_progression_scale()
	# At max scale, accuracy = base * (1 + 0.3)
	return base * (1.0 + scale * 0.3)

func get_reaction_mult() -> float:
	# Higher reaction = faster decisions when the player is detected.
	var base: float = cfg_difficulty
	var scale: float = _get_progression_scale()
	return base * (1.0 + scale * 0.4)

# Called by an AI when it wants to radio for backup. Shared cooldown stops
# every wounded bandit on the map from calling in a mob at once. Returns
# true if the request was granted (caller should proceed with the spawn);
# false if on cooldown.
func try_request_backup() -> bool:
	if not cfg_call_backup_on:
		return false
	var now: int = Time.get_ticks_msec()
	if now - _last_backup_call_ms < cfg_backup_cooldown_ms:
		return false
	_last_backup_call_ms = now
	return true

# ─── MCM ─────────────────────────────────────────────────────────────

func _try_load_mcm():
	if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
		return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
	return null

func _register_mcm() -> void:
	var _config := ConfigFile.new()
	_config.set_value("Bool", "cfg_enabled", {
		"name": "Enable Vostok AI",
		"tooltip": "Master toggle. When off, vanilla AI behavior is restored (requires relaunch).",
		"default": true, "value": true,
		"menu_pos": 1,
	})
	_config.set_value("Float", "cfg_difficulty", {
		"name": "Base Difficulty",
		"tooltip": "Global accuracy + reaction multiplier. 1.0 = default, 0.7 = easier, 1.5 = brutal.",
		"default": 1.0, "value": 1.0,
		"minRange": 0.5, "maxRange": 2.0, "step": 0.05,
		"menu_pos": 2,
	})
	_config.set_value("Bool", "cfg_personalities_on", {
		"name": "Enable Personalities",
		"tooltip": "Each AI gets assigned one of 5 tactical archetypes at spawn.",
		"default": true, "value": true,
		"menu_pos": 3,
	})
	_config.set_value("Bool", "cfg_squad_on", {
		"name": "Enable Squad Coordination",
		"tooltip": "AIs share contact sightings with nearby allies and take flanking slots.",
		"default": true, "value": true,
		"menu_pos": 4,
	})
	_config.set_value("Bool", "cfg_suppression_on", {
		"name": "Enable Suppression",
		"tooltip": "Bullets passing near an AI build a suppression meter that degrades aim and biases cover.",
		"default": true, "value": true,
		"menu_pos": 5,
	})
	_config.set_value("Bool", "cfg_damage_react_on", {
		"name": "Enable Damage Reaction",
		"tooltip": "AIs change state when hit, based on personality (cover / retaliate / flee).",
		"default": true, "value": true,
		"menu_pos": 6,
	})
	_config.set_value("Bool", "cfg_hearing_on", {
		"name": "Enable Enhanced Hearing",
		"tooltip": "Gunshots and footsteps propagate further and more accurately.",
		"default": true, "value": true,
		"menu_pos": 7,
	})
	_config.set_value("Bool", "cfg_investigation_on", {
		"name": "Enable Active Investigation",
		"tooltip": "After losing contact, AIs sweep through the last known area instead of stopping.",
		"default": true, "value": true,
		"menu_pos": 8,
	})
	_config.set_value("Bool", "cfg_difficulty_scaling_on", {
		"name": "Enable XP-Based Scaling",
		"tooltip": "AI accuracy and aggression scale with your XP band (novice → ghost).",
		"default": true, "value": true,
		"menu_pos": 9,
	})
	_config.set_value("Float", "cfg_hear_gunshot", {
		"name": "Gunshot Hearing Range (m)",
		"tooltip": "How far AIs hear a player gunshot.",
		"default": 250.0, "value": 250.0,
		"minRange": 50.0, "maxRange": 500.0, "step": 10.0,
		"menu_pos": 10,
	})
	_config.set_value("Float", "cfg_hear_running", {
		"name": "Running Hearing Range (m)",
		"tooltip": "How far AIs hear the player running.",
		"default": 40.0, "value": 40.0,
		"minRange": 5.0, "maxRange": 100.0, "step": 1.0,
		"menu_pos": 11,
	})
	_config.set_value("Float", "cfg_hear_walking", {
		"name": "Walking Hearing Range (m)",
		"tooltip": "How far AIs hear the player walking.",
		"default": 12.0, "value": 12.0,
		"minRange": 2.0, "maxRange": 50.0, "step": 1.0,
		"menu_pos": 12,
	})
	_config.set_value("Float", "cfg_hear_crouch", {
		"name": "Crouch Hearing Range (m)",
		"tooltip": "How far AIs hear the player crouch-walking.",
		"default": 5.0, "value": 5.0,
		"minRange": 0.0, "maxRange": 20.0, "step": 0.5,
		"menu_pos": 13,
	})
	_config.set_value("Float", "cfg_squad_radius", {
		"name": "Squad Callout Radius (m)",
		"tooltip": "Max distance at which a sighting broadcast reaches an ally.",
		"default": 50.0, "value": 50.0,
		"minRange": 10.0, "maxRange": 200.0, "step": 5.0,
		"menu_pos": 14,
	})
	_config.set_value("Int", "cfg_weight_coward", {
		"name": "Personality Weight: Coward",
		"tooltip": "Relative frequency of the Coward archetype.",
		"default": 15, "value": 15, "minRange": 0, "maxRange": 100,
		"menu_pos": 20,
	})
	_config.set_value("Int", "cfg_weight_aggressor", {
		"name": "Personality Weight: Aggressor",
		"tooltip": "Relative frequency of the Aggressor archetype.",
		"default": 25, "value": 25, "minRange": 0, "maxRange": 100,
		"menu_pos": 21,
	})
	_config.set_value("Int", "cfg_weight_methodical", {
		"name": "Personality Weight: Methodical",
		"tooltip": "Relative frequency of the Methodical archetype.",
		"default": 30, "value": 30, "minRange": 0, "maxRange": 100,
		"menu_pos": 22,
	})
	_config.set_value("Int", "cfg_weight_guard", {
		"name": "Personality Weight: Guard",
		"tooltip": "Relative frequency of the Guard archetype.",
		"default": 20, "value": 20, "minRange": 0, "maxRange": 100,
		"menu_pos": 23,
	})
	_config.set_value("Int", "cfg_weight_frenzy", {
		"name": "Personality Weight: Frenzy",
		"tooltip": "Relative frequency of the Frenzy archetype.",
		"default": 10, "value": 10, "minRange": 0, "maxRange": 100,
		"menu_pos": 24,
	})
	_config.set_value("Bool", "cfg_group_spawn_on", {
		"name": "Enable Group Spawns",
		"tooltip": "Sometimes spawn a squad of 2–4 AIs together at the same spawn point.",
		"default": true, "value": true,
		"menu_pos": 30,
	})
	_config.set_value("Float", "cfg_group_spawn_chance", {
		"name": "Group Spawn Chance",
		"tooltip": "Probability that a scheduled spawn produces a squad instead of a lone wanderer. 0.0 = never, 1.0 = every time.",
		"default": 0.35, "value": 0.35,
		"minRange": 0.0, "maxRange": 1.0, "step": 0.05,
		"menu_pos": 31,
	})
	_config.set_value("Int", "cfg_group_min", {
		"name": "Group Size: Minimum",
		"tooltip": "Smallest squad size when a group spawn rolls.",
		"default": 2, "value": 2, "minRange": 2, "maxRange": 6,
		"menu_pos": 32,
	})
	_config.set_value("Int", "cfg_group_max", {
		"name": "Group Size: Maximum",
		"tooltip": "Largest squad size when a group spawn rolls. Capped by the spawner's active agent limit.",
		"default": 4, "value": 4, "minRange": 2, "maxRange": 8,
		"menu_pos": 33,
	})
	_config.set_value("Bool", "cfg_squad_cohesion_on", {
		"name": "Enable Squad Cohesion",
		"tooltip": "Followers stay close to their leader during non-combat movement so squads travel together.",
		"default": true, "value": true,
		"menu_pos": 34,
	})
	_config.set_value("Float", "cfg_cohesion_distance", {
		"name": "Cohesion Distance (m)",
		"tooltip": "Max distance a follower can drift from its leader before being pulled back.",
		"default": 25.0, "value": 25.0,
		"minRange": 5.0, "maxRange": 80.0, "step": 1.0,
		"menu_pos": 35,
	})
	_config.set_value("Bool", "cfg_reaction_time_on", {
		"name": "Enable Reaction Time",
		"tooltip": "Bots wait a short personality-scaled delay between first sighting and first shot. Ambushes become viable.",
		"default": true, "value": true,
		"menu_pos": 40,
	})
	_config.set_value("Bool", "cfg_panic_on", {
		"name": "Enable Panic",
		"tooltip": "Cowards and Methodicals at low HP under heavy suppression break — erratic movement, wild fire, ignore cover.",
		"default": true, "value": true,
		"menu_pos": 41,
	})
	_config.set_value("Bool", "cfg_call_backup_on", {
		"name": "Enable Call For Backup",
		"tooltip": "Wounded Cowards/Guards radio for reinforcements. After a short delay a minion spawns near them.",
		"default": true, "value": true,
		"menu_pos": 42,
	})
	_config.set_value("Int", "cfg_backup_cooldown_ms", {
		"name": "Backup Call Cooldown (ms)",
		"tooltip": "World-wide cooldown between backup calls so every wounded bandit doesn't spam minions.",
		"default": 45000, "value": 45000,
		"minRange": 5000, "maxRange": 300000,
		"menu_pos": 43,
	})
	_config.set_value("Bool", "cfg_weapon_roles_on", {
		"name": "Enable Weapon-Role Awareness",
		"tooltip": "Bot tactics bias by equipped weapon: pistols rush, bolt-actions take vantages, shotguns push close, etc.",
		"default": true, "value": true,
		"menu_pos": 44,
	})
	_config.set_value("Bool", "cfg_formations_on", {
		"name": "Enable Squad Formations",
		"tooltip": "Followers take wedge/column slots behind their leader instead of random scatter.",
		"default": true, "value": true,
		"menu_pos": 45,
	})

	if not FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
		DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
		_config.save(MCM_FILE_PATH + "/config.ini")
	else:
		_mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, _config, MCM_FILE_PATH + "/config.ini")
		_config.load(MCM_FILE_PATH + "/config.ini")

	_apply_mcm_config(_config)

	_mcm_helpers.RegisterConfiguration(
		MCM_MOD_ID,
		"Vostok AI",
		MCM_FILE_PATH,
		"Tactical AI overhaul: personalities, squad coordination, suppression, reactive combat.",
		{"config.ini": _on_mcm_save}
	)

func _on_mcm_save(config: ConfigFile) -> void:
	_apply_mcm_config(config)

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return fallback
	return entry.get("value", fallback)

func _apply_mcm_config(config: ConfigFile) -> void:
	cfg_enabled = _mcm_val(config, "Bool", "cfg_enabled", cfg_enabled)
	cfg_difficulty = float(_mcm_val(config, "Float", "cfg_difficulty", cfg_difficulty))
	cfg_personalities_on = _mcm_val(config, "Bool", "cfg_personalities_on", cfg_personalities_on)
	cfg_squad_on = _mcm_val(config, "Bool", "cfg_squad_on", cfg_squad_on)
	cfg_suppression_on = _mcm_val(config, "Bool", "cfg_suppression_on", cfg_suppression_on)
	cfg_damage_react_on = _mcm_val(config, "Bool", "cfg_damage_react_on", cfg_damage_react_on)
	cfg_hearing_on = _mcm_val(config, "Bool", "cfg_hearing_on", cfg_hearing_on)
	cfg_investigation_on = _mcm_val(config, "Bool", "cfg_investigation_on", cfg_investigation_on)
	cfg_difficulty_scaling_on = _mcm_val(config, "Bool", "cfg_difficulty_scaling_on", cfg_difficulty_scaling_on)
	cfg_hear_gunshot = float(_mcm_val(config, "Float", "cfg_hear_gunshot", cfg_hear_gunshot))
	cfg_hear_running = float(_mcm_val(config, "Float", "cfg_hear_running", cfg_hear_running))
	cfg_hear_walking = float(_mcm_val(config, "Float", "cfg_hear_walking", cfg_hear_walking))
	cfg_hear_crouch = float(_mcm_val(config, "Float", "cfg_hear_crouch", cfg_hear_crouch))
	cfg_squad_radius = float(_mcm_val(config, "Float", "cfg_squad_radius", cfg_squad_radius))
	cfg_weight_coward = int(_mcm_val(config, "Int", "cfg_weight_coward", cfg_weight_coward))
	cfg_weight_aggressor = int(_mcm_val(config, "Int", "cfg_weight_aggressor", cfg_weight_aggressor))
	cfg_weight_methodical = int(_mcm_val(config, "Int", "cfg_weight_methodical", cfg_weight_methodical))
	cfg_weight_guard = int(_mcm_val(config, "Int", "cfg_weight_guard", cfg_weight_guard))
	cfg_weight_frenzy = int(_mcm_val(config, "Int", "cfg_weight_frenzy", cfg_weight_frenzy))
	cfg_group_spawn_on = _mcm_val(config, "Bool", "cfg_group_spawn_on", cfg_group_spawn_on)
	cfg_group_spawn_chance = float(_mcm_val(config, "Float", "cfg_group_spawn_chance", cfg_group_spawn_chance))
	cfg_group_min = int(_mcm_val(config, "Int", "cfg_group_min", cfg_group_min))
	cfg_group_max = int(_mcm_val(config, "Int", "cfg_group_max", cfg_group_max))
	if cfg_group_max < cfg_group_min:
		cfg_group_max = cfg_group_min
	cfg_squad_cohesion_on = _mcm_val(config, "Bool", "cfg_squad_cohesion_on", cfg_squad_cohesion_on)
	cfg_cohesion_distance = float(_mcm_val(config, "Float", "cfg_cohesion_distance", cfg_cohesion_distance))
	cfg_reaction_time_on = _mcm_val(config, "Bool", "cfg_reaction_time_on", cfg_reaction_time_on)
	cfg_panic_on = _mcm_val(config, "Bool", "cfg_panic_on", cfg_panic_on)
	cfg_call_backup_on = _mcm_val(config, "Bool", "cfg_call_backup_on", cfg_call_backup_on)
	cfg_backup_cooldown_ms = int(_mcm_val(config, "Int", "cfg_backup_cooldown_ms", cfg_backup_cooldown_ms))
	cfg_weapon_roles_on = _mcm_val(config, "Bool", "cfg_weapon_roles_on", cfg_weapon_roles_on)
	cfg_formations_on = _mcm_val(config, "Bool", "cfg_formations_on", cfg_formations_on)

func _load_local_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(LOCAL_CFG) != OK:
		return
	cfg_enabled = cfg.get_value("settings", "enabled", true)
	cfg_difficulty = float(cfg.get_value("settings", "difficulty", 1.0))
