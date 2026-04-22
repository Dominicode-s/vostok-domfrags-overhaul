extends Node

# Vostok AI — Tactical Overhaul
#
# MML v3.0.0 migration: replaces the previous take_over_path() subclass pattern
# (AI.gd / AISpawner.gd extending res://Scripts/AI.gd and AISpawner.gd) with
# hook registrations against MML's RTVModLib. Every behavior the subclass used
# to add is now implemented as a pre/replace/post hook callback on this
# autoload. Per-AI state that used to live on the subclass (`vai_*` members)
# is now kept on each AI instance via `set_meta()` / `get_meta()`, so multiple
# mods can coexist without clobbering each other's additions to AI.gd.
#
# Hook map (see _register_ai_hooks / _register_aispawner_hooks):
#   ai-initialize-post              — personality pick, squad register, tuning
#   ai-_physics_process-pre         — early tick (panic / backup / sighting edge)
#   ai-_physics_process-post        — late tick (suppression / investigation / cohesion)
#   ai-decision                     — REPLACE: personality-weighted state pick
#   ai-hearing-post                 — gunshot/footstep broadcast to squad
#   ai-firedetection-post           — broadcast sighting on fire detection
#   ai-weapondamage-post            — damage reaction + suppression + callout
#   ai-death-pre                    — broadcast death to squad, unregister
#   ai-hunt-post                    — sweep investigation queue around LKL
#   ai-fire-pre                     — enforce reaction-time delay before first shot
#   ai-fireaccuracy                 — REPLACE: adjust spread by suppression / panic / role
#   aispawner-spawnwanderer         — REPLACE: occasionally spawn a squad group

const MCM_MOD_ID := "VostokAI"
const MCM_FILE_PATH := "user://MCM/VostokAI"
const LOCAL_CFG := "user://VostokAI_settings.cfg"

# ─── Tuning constants (migrated from AI.gd) ──────────────────────────

const VAI_SUPPRESSION_DECAY_PER_SEC := 18.0
const VAI_SUPPRESSION_ON_HIT := 45.0
const VAI_SUPPRESSION_ON_NEAR_MISS := 12.0
const VAI_SUPPRESSION_ON_DIRECT_AIM := 6.0
const VAI_SUPPRESSION_COVER_THRESHOLD := 55.0
const VAI_SUPPRESSION_MAX := 100.0

const VAI_INVESTIGATE_STEPS := 3
const VAI_INVESTIGATE_RADIUS := 8.0
const VAI_CALLOUT_COOLDOWN_MS := 1500

const VAI_COWARD_FLEE_HP := 45.0
const VAI_METHODICAL_FLEE_HP := 20.0
const VAI_GUARD_RETURN_DISTANCE := 25.0

const VAI_COHESION_CHECK_INTERVAL := 1.8
const VAI_COHESION_ARRIVE_SLOP := 6.0

const VAI_PANIC_DURATION_MS := 11000
const VAI_PANIC_HP_THRESHOLD := 0.22
const VAI_PANIC_SUPPRESSION_THRESHOLD := 55.0
const VAI_BACKUP_HP_THRESHOLD := 0.45
const VAI_BACKUP_DELAY_MS := 5500
const VAI_BACKUP_SPAWN_RADIUS := 10.0

const FLANK_SLOTS := ["LEFT", "RIGHT", "CENTER"]

# ─── Config (MCM-backed) ─────────────────────────────────────────────

var cfg_enabled: bool = true
var cfg_personalities_on: bool = true
var cfg_squad_on: bool = true
var cfg_suppression_on: bool = true
var cfg_damage_react_on: bool = true
var cfg_hearing_on: bool = true
var cfg_investigation_on: bool = true
var cfg_difficulty_scaling_on: bool = true
var cfg_difficulty: float = 1.0

var cfg_hear_gunshot: float = 250.0
var cfg_hear_running: float = 40.0
var cfg_hear_walking: float = 12.0
var cfg_hear_crouch: float = 5.0

var cfg_squad_radius: float = 50.0

var cfg_weight_coward: int = 15
var cfg_weight_aggressor: int = 25
var cfg_weight_methodical: int = 30
var cfg_weight_guard: int = 20
var cfg_weight_frenzy: int = 10

var cfg_group_spawn_on: bool = true
var cfg_group_spawn_chance: float = 0.35
var cfg_group_min: int = 2
var cfg_group_max: int = 4
var cfg_squad_cohesion_on: bool = true
var cfg_cohesion_distance: float = 25.0

var cfg_reaction_time_on: bool = true
var cfg_panic_on: bool = true
var cfg_call_backup_on: bool = true
var cfg_backup_cooldown_ms: int = 45000
var cfg_weapon_roles_on: bool = true
var cfg_formations_on: bool = true

var _last_backup_call_ms: int = 0

var _mcm_helpers = null

# ─── Squad coordinator state ─────────────────────────────────────────

var _agents: Array = []
var _flank_slots: Dictionary = {}   # agent -> slot string
var _last_broadcast_time_ms: int = 0
var _next_squad_id: int = 0

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
		_register_ai_hooks()
		_register_aispawner_hooks()

# ─── Hook registration ───────────────────────────────────────────────

func _register_ai_hooks() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		push_warning("[VostokAI] RTVModLib not available — AI hooks disabled")
		return
	lib.hook("ai-initialize-post",       _hook_ai_initialize_post)
	lib.hook("ai-_physics_process-pre",  _hook_ai_physics_pre)
	lib.hook("ai-_physics_process-post", _hook_ai_physics_post)
	lib.hook("ai-decision",              _hook_ai_decision)
	lib.hook("ai-hearing-post",          _hook_ai_hearing_post)
	lib.hook("ai-firedetection-post",    _hook_ai_firedetection_post)
	lib.hook("ai-weapondamage-post",     _hook_ai_weapondamage_post)
	lib.hook("ai-death-pre",             _hook_ai_death_pre)
	lib.hook("ai-hunt-post",             _hook_ai_hunt_post)
	lib.hook("ai-fire-pre",              _hook_ai_fire_pre)
	lib.hook("ai-fireaccuracy",          _hook_ai_fireaccuracy)

func _register_aispawner_hooks() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		push_warning("[VostokAI] RTVModLib not available — AISpawner hooks disabled")
		return
	lib.hook("aispawner-spawnwanderer", _hook_aispawner_spawnwanderer)

# ─── Per-AI state helpers (set_meta-backed replacement for `vai_*` vars) ─

# All per-instance state the old AI.gd subclass held as member vars now lives
# on each AI via metadata. One helper per logical member, with a default so
# the callsite doesn't need its own null check. These ARE hot-path — keep
# them tiny.

func _get_ai() -> Node:
	# Canonical "who is the current hook's caller" resolver. Every AI hook
	# callback starts with this and early-returns on null/invalid.
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		return null
	var c = lib._caller
	if c == null or not is_instance_valid(c):
		return null
	return c

func _ai_personality(ai: Node) -> String:
	return ai.get_meta("vai_personality", "GUARD")

func _ai_set_personality(ai: Node, p: String) -> void:
	ai.set_meta("vai_personality", p)

func _ai_registered(ai: Node) -> bool:
	return bool(ai.get_meta("vai_registered", false))

func _ai_set_registered(ai: Node, v: bool) -> void:
	ai.set_meta("vai_registered", v)

func _ai_suppression(ai: Node) -> float:
	return float(ai.get_meta("vai_suppression", 0.0))

func _ai_set_suppression(ai: Node, v: float) -> void:
	ai.set_meta("vai_suppression", v)

func _ai_last_callout_ms(ai: Node) -> int:
	return int(ai.get_meta("vai_last_callout_ms", 0))

func _ai_set_last_callout_ms(ai: Node, v: int) -> void:
	ai.set_meta("vai_last_callout_ms", v)

func _ai_investigation_queue(ai: Node) -> Array:
	if not ai.has_meta("vai_investigation_queue"):
		ai.set_meta("vai_investigation_queue", [])
	return ai.get_meta("vai_investigation_queue")

func _ai_investigation_pending(ai: Node) -> bool:
	return bool(ai.get_meta("vai_investigation_pending", false))

func _ai_set_investigation_pending(ai: Node, v: bool) -> void:
	ai.set_meta("vai_investigation_pending", v)

func _ai_last_seen_ms(ai: Node) -> int:
	return int(ai.get_meta("vai_last_seen_ms", 0))

func _ai_set_last_seen_ms(ai: Node, v: int) -> void:
	ai.set_meta("vai_last_seen_ms", v)

func _ai_prev_visible(ai: Node) -> bool:
	return bool(ai.get_meta("vai_prev_visible", false))

func _ai_set_prev_visible(ai: Node, v: bool) -> void:
	ai.set_meta("vai_prev_visible", v)

func _ai_first_sighted_ms(ai: Node) -> int:
	return int(ai.get_meta("vai_first_sighted_ms", 0))

func _ai_set_first_sighted_ms(ai: Node, v: int) -> void:
	ai.set_meta("vai_first_sighted_ms", v)

func _ai_panicked(ai: Node) -> bool:
	return bool(ai.get_meta("vai_panicked", false))

func _ai_set_panicked(ai: Node, v: bool) -> void:
	ai.set_meta("vai_panicked", v)

func _ai_panic_end_ms(ai: Node) -> int:
	return int(ai.get_meta("vai_panic_end_ms", 0))

func _ai_set_panic_end_ms(ai: Node, v: int) -> void:
	ai.set_meta("vai_panic_end_ms", v)

func _ai_backup_requested(ai: Node) -> bool:
	return bool(ai.get_meta("vai_backup_requested", false))

func _ai_set_backup_requested(ai: Node, v: bool) -> void:
	ai.set_meta("vai_backup_requested", v)

func _ai_backup_fire_ms(ai: Node) -> int:
	return int(ai.get_meta("vai_backup_fire_ms", 0))

func _ai_set_backup_fire_ms(ai: Node, v: int) -> void:
	ai.set_meta("vai_backup_fire_ms", v)

func _ai_squad_leader(ai: Node):
	return ai.get_meta("vai_squad_leader", null)

func _ai_is_leader(ai: Node) -> bool:
	return bool(ai.get_meta("vai_is_leader", false))

func _ai_cohesion_timer(ai: Node) -> float:
	return float(ai.get_meta("vai_cohesion_timer", 0.0))

func _ai_set_cohesion_timer(ai: Node, v: float) -> void:
	ai.set_meta("vai_cohesion_timer", v)

func _ai_formation_slot(ai: Node) -> int:
	return int(ai.get_meta("vai_formation_slot", 0))

# ─── AI hook callbacks ───────────────────────────────────────────────

func _hook_ai_initialize_post() -> void:
	var ai = _get_ai()
	if ai == null:
		return
	if not cfg_enabled:
		return
	# Pick personality (boss forced aggressive)
	var p: String = pick_personality()
	if ai.get("boss"):
		p = "AGGRESSOR"
	_ai_set_personality(ai, p)
	register_agent(ai)
	_ai_set_registered(ai, true)
	_apply_personality_tuning(ai)

func _apply_personality_tuning(ai: Node) -> void:
	# Tweak vanilla voice cadence so each archetype feels distinct
	match _ai_personality(ai):
		"COWARD":     ai.voiceCycle = randf_range(20.0, 60.0)
		"AGGRESSOR":  ai.voiceCycle = randf_range(5.0, 20.0)
		"METHODICAL": ai.voiceCycle = randf_range(15.0, 45.0)
		"GUARD":      ai.voiceCycle = randf_range(10.0, 40.0)
		"FRENZY":     ai.voiceCycle = randf_range(3.0, 15.0)

# _physics_process-pre — cheap early ticks, safe BEFORE vanilla body runs.
# We split because the old subclass mixed pre and post work; reaction-time
# edge detection and panic-expiry must be up to date BEFORE Decision()
# (which vanilla can call during States() in its own body this frame).
func _hook_ai_physics_pre(_delta: float) -> void:
	var ai = _get_ai()
	if ai == null or not cfg_enabled:
		return
	if ai.pause or ai.dead:
		return
	_vai_tick_sighting_edge(ai)
	if cfg_panic_on:
		_vai_tick_panic(ai)
	if cfg_call_backup_on:
		_vai_tick_backup(ai)

# _physics_process-post — state-based ticks that read what vanilla just did.
# Suppression / investigation / cohesion all consume state vanilla freshly
# updated (playerVisible, playerDistance3D, agent state), so they run AFTER.
func _hook_ai_physics_post(delta: float) -> void:
	var ai = _get_ai()
	if ai == null or not cfg_enabled:
		return
	if ai.pause or ai.dead:
		return
	if cfg_suppression_on:
		_vai_tick_suppression(ai, delta)
	if cfg_investigation_on:
		_vai_tick_investigation(ai)
	if cfg_squad_cohesion_on:
		_vai_tick_cohesion(ai, delta)
	# Track last time we saw the player (for losing-contact detection)
	if ai.playerVisible:
		_ai_set_last_seen_ms(ai, Time.get_ticks_msec())

# Decision — REPLACE hook. Old override signalled "skip super" by always
# calling ChangeState itself and never calling super() on the happy path.
# Under hooks we skip_super() when we actually made a decision; when
# personalities are off we return without skip_super and let vanilla run.
func _hook_ai_decision() -> void:
	var ai = _get_ai()
	if ai == null:
		return
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		return
	if not cfg_enabled or not cfg_personalities_on:
		# Let vanilla Decision() handle it.
		return

	# Panicked bots — erratic shifts, nothing else.
	if _ai_panicked(ai):
		ai.ChangeState("Shift")
		lib.skip_super()
		return

	if cfg_panic_on and _vai_should_panic(ai):
		_vai_enter_panic(ai)
		lib.skip_super()
		return

	# Low HP override — regardless of personality, heavily wounded agents
	# take cover (or flee if they're cowards/methodicals).
	var hp_ratio: float = clamp(float(ai.health) / 100.0, 0.0, 1.0)
	var personality: String = _ai_personality(ai)
	if hp_ratio < VAI_COWARD_FLEE_HP / 100.0 and personality == "COWARD":
		if not ai.AISpawner.noHiding and _roll_chance(0.75):
			ai.ChangeState("Hide")
			lib.skip_super()
			return
	if hp_ratio < VAI_METHODICAL_FLEE_HP / 100.0 and personality == "METHODICAL":
		if not ai.AISpawner.noHiding and _roll_chance(0.55):
			ai.ChangeState("Hide")
			lib.skip_super()
			return
	# Suppression override — heavy suppression pushes toward cover
	if _ai_suppression(ai) >= VAI_SUPPRESSION_COVER_THRESHOLD and personality != "FRENZY":
		ai.ChangeState("Cover")
		lib.skip_super()
		return

	# Normal personality-weighted decision
	var dist: float = float(ai.playerDistance3D)
	var has_semi: bool = ai.weaponData != null and ai.weaponData.weaponAction != "Manual"
	var can_push: bool = bool(ai.playerVisible) and dist < 100.0 and not bool(gameData.isTrading)
	var weights: Dictionary = _decision_weights(ai, dist, has_semi, can_push)
	if cfg_weapon_roles_on:
		_apply_weapon_role_bias(ai, weights, dist)
	var choice: String = _weighted_pick(weights)
	if choice != "":
		# Guards should return to their post if they've been pushed too far
		if personality == "GUARD" and ai.currentState == ai.State.Combat:
			if ai.currentPoint and ai.global_position.distance_to(ai.currentPoint.global_position) > VAI_GUARD_RETURN_DISTANCE:
				ai.attackReturn = true
		ai.ChangeState(choice)
	# Always skip super — we've made (or explicitly declined) a decision.
	lib.skip_super()

func _hook_ai_hearing_post() -> void:
	# Vanilla Hearing only handles run/walk at short range. We extend with
	# gunshot (very loud) and crouch (quiet). Post runs AFTER vanilla, so
	# vanilla's `Decision()` trigger on walk/run was already fired and the
	# state may already be Combat. Our additions still make sense: they can
	# update LKL and cascade a squad callout for longer-range stimuli.
	var ai = _get_ai()
	if ai == null or not cfg_enabled or not cfg_hearing_on:
		return

	# Gunshots — broader than vanilla FireDetection (which needs narrow cone).
	if gameData.isFiring and ai.playerDistance3D < cfg_hear_gunshot:
		if ai.currentState != ai.State.Ambush:
			ai.lastKnownLocation = ai.playerPosition
		if ai.currentState == ai.State.Wander or ai.currentState == ai.State.Guard or ai.currentState == ai.State.Patrol:
			ai.Decision()
		elif ai.currentState == ai.State.Ambush:
			ai.ChangeState("Combat")
		_vai_call_out_to_squad(ai, ai.playerPosition)
		return

	# Crouch — quiet but detectable at close range. Vanilla doesn't handle it.
	if gameData.isCrouching and ai.playerDistance3D < cfg_hear_crouch:
		if ai.currentState != ai.State.Ambush:
			ai.lastKnownLocation = ai.playerPosition
		if ai.currentState == ai.State.Wander or ai.currentState == ai.State.Guard or ai.currentState == ai.State.Patrol:
			ai.Decision()

func _hook_ai_firedetection_post(_delta: float) -> void:
	var ai = _get_ai()
	if ai == null or not cfg_enabled:
		return
	if ai.fireDetected and cfg_squad_on:
		_vai_call_out_to_squad(ai, ai.playerPosition)

# WeaponDamage — post-hook because we need vanilla to have applied the
# damage + updated `dead`. If vanilla killed the agent this frame we skip
# our reaction (Death hook will broadcast). Old subclass captured pre-state
# via `var was_dead = bool(dead)` before super(); that's not needed in a
# post hook — vanilla is guaranteed to have updated `dead` already, so we
# just check it.
func _hook_ai_weapondamage_post(_hitbox: String, _damage: float) -> void:
	var ai = _get_ai()
	if ai == null or not cfg_enabled:
		return
	if ai.dead:
		return
	# Suppression bump
	if cfg_suppression_on:
		_ai_set_suppression(ai, min(VAI_SUPPRESSION_MAX, _ai_suppression(ai) + VAI_SUPPRESSION_ON_HIT))
	# Every hit tells you exactly where the player is
	ai.lastKnownLocation = ai.playerPosition
	if cfg_squad_on:
		broadcast_sighting(ai, ai.playerPosition)
	if cfg_damage_react_on:
		_vai_react_to_damage(ai)

# Death — PRE hook so we broadcast before vanilla tears down the agent's
# state (flash/collision/agent.velocity all get zeroed in super). Broadcast
# uses global_position which remains valid; vanilla doesn't move the agent.
func _hook_ai_death_pre(_direction, _force) -> void:
	var ai = _get_ai()
	if ai == null:
		return
	if cfg_enabled and cfg_squad_on:
		broadcast_death(ai, ai.global_position)
	if _ai_registered(ai):
		unregister_agent(ai)
		_ai_set_registered(ai, false)

func _hook_ai_hunt_post(_delta: float) -> void:
	# Active investigation — after reaching LKL while hunting, sweep N points.
	var ai = _get_ai()
	if ai == null or not cfg_enabled or not cfg_investigation_on:
		return
	if ai.playerVisible:
		# Reacquired — cancel investigation
		_ai_investigation_queue(ai).clear()
		_ai_set_investigation_pending(ai, false)
		return
	if ai.agent.is_target_reached() or ai.agent.is_navigation_finished():
		var q: Array = _ai_investigation_queue(ai)
		if q.size() > 0:
			var next_point: Vector3 = q.pop_front()
			ai.MoveToPoint(next_point)
		else:
			_ai_set_investigation_pending(ai, false)

# Fire — PRE hook + conditional skip_super. Enforces a reaction-time delay
# on the FIRST shot of a fresh sighting (edge on playerVisible). After that
# delay elapses, every subsequent frame falls through naturally.
func _hook_ai_fire_pre(_delta: float) -> void:
	var ai = _get_ai()
	if ai == null or not cfg_enabled or not cfg_reaction_time_on:
		return
	if not ai.playerVisible:
		return
	var elapsed_ms: int = Time.get_ticks_msec() - _ai_first_sighted_ms(ai)
	if elapsed_ms < _vai_reaction_delay_ms(ai):
		var lib = Engine.get_meta("RTVModLib", null)
		if lib != null:
			lib.skip_super()

# FireAccuracy — REPLACE hook. We need to return a modified aim Vector3,
# and post-hooks under MML can't reshape the caller's return value, so we
# fully replace vanilla's logic here. We reproduce vanilla's base spread
# behavior (distance-banded offset) and layer our mod's factors on top.
func _hook_ai_fireaccuracy():
	var ai = _get_ai()
	if ai == null or not cfg_enabled:
		return   # let vanilla run (no skip_super)
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		return

	# Reproduce vanilla's base spread (distance-banded offsets in its local
	# basis). Keeps parity with the game's feel when our mod factors sum to
	# 1.0, and scales cleanly when they don't.
	var spreadMultiplier: float = 1.0
	if ai.fullAuto and not ai.boss:
		spreadMultiplier = 2.0
	var offset: Vector3 = Vector3.ZERO
	if ai.playerDistance3D < 10.0 or ai.boss:
		offset.x = randf_range(-0.1, 0.1) * spreadMultiplier
		offset.y = randf_range(-0.1, 0.1) * spreadMultiplier
	elif ai.playerDistance3D > 10.0 and ai.playerDistance3D < 50.0:
		offset.x = randf_range(-1.0, 1.0) * spreadMultiplier
		offset.y = randf_range(-1.0, 1.0) * spreadMultiplier
	else:
		offset.x = randf_range(-2.0, 2.0) * spreadMultiplier
		offset.y = randf_range(-2.0, 2.0) * spreadMultiplier

	# Apply our mod's factor stack to the offset before projecting into basis.
	var suppression_factor: float = 1.0 + (_ai_suppression(ai) / VAI_SUPPRESSION_MAX) * 1.8
	var accuracy_mult: float = get_accuracy_mult()
	var factor: float = suppression_factor / max(0.1, accuracy_mult)
	match _ai_personality(ai):
		"AGGRESSOR": factor *= 1.15
		"METHODICAL": factor *= 0.75
		"GUARD":      factor *= 0.9
		"FRENZY":     factor *= 1.5
		"COWARD":     factor *= 1.1
	if cfg_weapon_roles_on:
		match _vai_weapon_role(ai):
			"rifle_bolt":  factor *= 0.55
			"shotgun":     factor *= 1.6
			"pistol":      factor *= 1.25
			"rifle_auto":  factor *= 1.0
	if _ai_panicked(ai):
		factor *= 3.2

	offset *= factor
	var aimBasis: Vector3 = ai.global_transform.basis * offset
	var fireDirection: Vector3 = ai.playerPosition + Vector3(0, 1.0, 0)
	lib.skip_super()
	return fireDirection + aimBasis

# ─── Per-tick helpers (all take the AI as first arg) ─────────────────

func _vai_tick_suppression(ai: Node, delta: float) -> void:
	var supp: float = _ai_suppression(ai)
	if supp > 0.0:
		supp = max(0.0, supp - VAI_SUPPRESSION_DECAY_PER_SEC * delta)

	# Accumulate from player fire when roughly aligned with player aim.
	if gameData.isFiring and ai.playerDistance3D < 150.0:
		if ai.fireVector > 0.93:
			supp = min(VAI_SUPPRESSION_MAX,
				supp + VAI_SUPPRESSION_ON_DIRECT_AIM * delta * 60.0)
		elif ai.fireVector > 0.7 and ai.playerDistance3D < 50.0:
			supp = min(VAI_SUPPRESSION_MAX,
				supp + VAI_SUPPRESSION_ON_NEAR_MISS * delta * 60.0)

	_ai_set_suppression(ai, supp)

	# Heavy suppression → seek cover (once, not every frame)
	if supp >= VAI_SUPPRESSION_COVER_THRESHOLD:
		var s = ai.currentState
		if s == ai.State.Combat or s == ai.State.Hunt or s == ai.State.Defend:
			if _ai_personality(ai) != "FRENZY":
				ai.ChangeState("Cover")
				_ai_set_suppression(ai, VAI_SUPPRESSION_COVER_THRESHOLD - 10.0)

func _vai_tick_investigation(ai: Node) -> void:
	if not cfg_investigation_on:
		return
	var now := Time.get_ticks_msec()
	var time_since_seen_ms: int = now - _ai_last_seen_ms(ai)
	if ai.currentState == ai.State.Hunt and not ai.playerVisible and time_since_seen_ms > 3500 and not _ai_investigation_pending(ai):
		_vai_start_investigation(ai)

func _vai_start_investigation(ai: Node) -> void:
	_ai_set_investigation_pending(ai, true)
	var q: Array = _ai_investigation_queue(ai)
	q.clear()
	var base: Vector3 = ai.lastKnownLocation
	for i in VAI_INVESTIGATE_STEPS:
		var angle: float = randf() * TAU
		var radius: float = VAI_INVESTIGATE_RADIUS * (0.5 + randf() * 1.5)
		var offset := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		q.append(base + offset)

func _vai_tick_cohesion(ai: Node, delta: float) -> void:
	if _ai_is_leader(ai):
		return
	var leader = _ai_squad_leader(ai)
	if leader == null:
		return
	if not is_instance_valid(leader) or leader.get("dead"):
		ai.set_meta("vai_squad_leader", null)
		return
	var s = ai.currentState
	if s != ai.State.Wander and s != ai.State.Patrol and s != ai.State.Idle:
		return
	var t: float = _ai_cohesion_timer(ai) - delta
	if t > 0.0:
		_ai_set_cohesion_timer(ai, t)
		return
	_ai_set_cohesion_timer(ai, VAI_COHESION_CHECK_INTERVAL)
	var max_dist: float = cfg_cohesion_distance
	var dist: float = ai.global_position.distance_to(leader.global_position)
	if dist <= max_dist:
		return
	var target: Vector3 = leader.global_position
	if cfg_formations_on:
		target += _vai_formation_offset(ai, leader)
	else:
		target += Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	ai.MoveToPoint(target)

func _vai_formation_offset(ai: Node, leader: Node) -> Vector3:
	var yaw: float = leader.rotation.y
	var fwd: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	match _ai_formation_slot(ai):
		1: return -fwd * 3.5 + right * -2.8
		2: return -fwd * 3.5 + right * 2.8
		3: return -fwd * 6.0
		4: return -fwd * 5.5 + right * -4.5
		5: return -fwd * 5.5 + right * 4.5
		_: return -fwd * 2.5

func _vai_tick_sighting_edge(ai: Node) -> void:
	var vis: bool = ai.playerVisible
	if vis and not _ai_prev_visible(ai):
		_ai_set_first_sighted_ms(ai, Time.get_ticks_msec())
	_ai_set_prev_visible(ai, vis)

func _vai_reaction_delay_ms(ai: Node) -> int:
	var base: int
	match _ai_personality(ai):
		"AGGRESSOR":  base = 180
		"FRENZY":     base = 160
		"GUARD":      base = 330
		"METHODICAL": base = 440
		"COWARD":     base = 720
		_:            base = 300
	var mult: float = 1.0 / max(0.3, get_reaction_mult())
	base = int(float(base) * mult)
	return base + randi_range(-80, 80)

func _vai_tick_panic(ai: Node) -> void:
	if _ai_panicked(ai) and Time.get_ticks_msec() > _ai_panic_end_ms(ai):
		_ai_set_panicked(ai, false)

func _vai_should_panic(ai: Node) -> bool:
	if _ai_panicked(ai):
		return false
	var p: String = _ai_personality(ai)
	if not (p == "COWARD" or p == "METHODICAL"):
		return false
	var hp_ratio: float = clamp(float(ai.health) / 100.0, 0.0, 1.0)
	if hp_ratio >= VAI_PANIC_HP_THRESHOLD:
		return false
	if _ai_suppression(ai) < VAI_PANIC_SUPPRESSION_THRESHOLD:
		return false
	return true

func _vai_enter_panic(ai: Node) -> void:
	_ai_set_panicked(ai, true)
	_ai_set_panic_end_ms(ai, Time.get_ticks_msec() + VAI_PANIC_DURATION_MS)
	ai.PlayCombat()
	ai.ChangeState("Shift")

func _vai_tick_backup(ai: Node) -> void:
	# Step 1: request backup once if wounded Coward/Guard engaged the player
	if not _ai_backup_requested(ai):
		var hp_ratio: float = clamp(float(ai.health) / 100.0, 0.0, 1.0)
		if hp_ratio < VAI_BACKUP_HP_THRESHOLD:
			var p: String = _ai_personality(ai)
			if p == "COWARD" or p == "GUARD":
				var s = ai.currentState
				if s == ai.State.Combat or s == ai.State.Cover or s == ai.State.Defend or s == ai.State.Hunt:
					if try_request_backup():
						_ai_set_backup_requested(ai, true)
						_ai_set_backup_fire_ms(ai, Time.get_ticks_msec() + VAI_BACKUP_DELAY_MS)
						ai.PlayCombat()
	# Step 2: fire the spawn when the delay elapses
	if _ai_backup_requested(ai) and Time.get_ticks_msec() >= _ai_backup_fire_ms(ai):
		_ai_set_backup_fire_ms(ai, 0x7FFFFFFF)   # disarm
		var spawner = ai.AISpawner
		if is_instance_valid(spawner) and spawner.has_method("SpawnMinion"):
			var ox: float = randf_range(-VAI_BACKUP_SPAWN_RADIUS, VAI_BACKUP_SPAWN_RADIUS)
			var oz: float = randf_range(-VAI_BACKUP_SPAWN_RADIUS, VAI_BACKUP_SPAWN_RADIUS)
			var spawn_pos: Vector3 = ai.global_position + Vector3(ox, 0.0, oz)
			spawner.SpawnMinion(spawn_pos)

func _vai_react_to_damage(ai: Node) -> void:
	var hp_ratio: float = clamp(float(ai.health) / 100.0, 0.0, 1.0)
	var can_hide: bool = not ai.AISpawner.noHiding
	match _ai_personality(ai):
		"COWARD":
			if hp_ratio < 0.6 and can_hide:
				ai.ChangeState("Hide")
			else:
				ai.ChangeState("Cover")
		"AGGRESSOR":
			if ai.playerVisible and ai.weaponData != null and ai.weaponData.weaponAction != "Manual":
				ai.ChangeState("Attack")
			else:
				ai.ChangeState("Shift")
		"METHODICAL":
			if hp_ratio < 0.3 and can_hide:
				ai.ChangeState("Hide")
			else:
				ai.ChangeState("Cover")
		"GUARD":
			if hp_ratio < 0.35:
				ai.ChangeState("Cover")
			else:
				ai.ChangeState("Defend")
		"FRENZY":
			ai.ChangeState("Shift")

func _vai_weapon_role(ai: Node) -> String:
	if ai.weaponData == null:
		return "unknown"
	var wtype: String = ""
	var waction: String = ""
	if "weaponType" in ai.weaponData and ai.weaponData.weaponType != null:
		wtype = String(ai.weaponData.weaponType)
	if "weaponAction" in ai.weaponData and ai.weaponData.weaponAction != null:
		waction = String(ai.weaponData.weaponAction)
	if wtype == "Pistol":
		return "pistol"
	if waction == "Pump":
		return "shotgun"
	if waction == "Bolt" or waction == "Manual":
		return "rifle_bolt"
	if waction == "Semi-Auto" or waction == "Semi":
		return "rifle_auto"
	return "unknown"

func _vai_call_out_to_squad(ai: Node, location: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now - _ai_last_callout_ms(ai) < VAI_CALLOUT_COOLDOWN_MS:
		return
	_ai_set_last_callout_ms(ai, now)
	broadcast_sighting(ai, location)

# ─── Decision-weight helpers ─────────────────────────────────────────

func _decision_weights(ai: Node, dist: float, has_semi: bool, can_push: bool) -> Dictionary:
	var w: Dictionary = {
		"Combat": 10.0,
		"Cover": 5.0,
		"Vantage": 5.0,
		"Defend": 5.0,
		"Hide": 3.0,
		"Hunt": 2.0,
		"Shift": 2.0,
		"Attack": 2.0,
	}
	match _ai_personality(ai):
		"COWARD":
			w["Cover"] *= 4.0
			w["Hide"] *= 4.0
			w["Defend"] *= 2.0
			w["Combat"] *= 0.6
			w["Vantage"] *= 1.5
			w["Hunt"] = 0.0
			w["Shift"] = 0.0
			w["Attack"] = 0.0
		"AGGRESSOR":
			w["Attack"] *= 5.0
			w["Hunt"] *= 4.0
			w["Shift"] *= 3.0
			w["Combat"] *= 1.3
			w["Hide"] = 0.0
			w["Cover"] *= 0.5
			w["Defend"] *= 0.5
		"METHODICAL":
			w["Vantage"] *= 3.5
			w["Cover"] *= 2.5
			w["Defend"] *= 1.8
			w["Shift"] *= 1.4
			w["Combat"] *= 1.1
			w["Attack"] *= 0.6
			w["Hunt"] *= 0.8
		"GUARD":
			w["Defend"] *= 4.0
			w["Combat"] *= 1.5
			w["Cover"] *= 1.5
			w["Vantage"] *= 1.2
			w["Attack"] *= 0.3
			w["Hunt"] *= 0.5
			w["Hide"] *= 0.3
		"FRENZY":
			w["Shift"] *= 5.0
			w["Attack"] *= 4.0
			w["Combat"] *= 1.8
			w["Hunt"] *= 3.0
			w["Cover"] *= 0.2
			w["Hide"] = 0.0
			w["Defend"] *= 0.3

	if not can_push:
		w["Hunt"] = 0.0
		w["Shift"] = 0.0
		w["Attack"] = 0.0
	if not has_semi:
		w["Attack"] = 0.0
	if dist < 20.0:
		w["Vantage"] *= 0.3
		w["Cover"] *= 0.5
	if dist > 60.0:
		w["Attack"] *= 0.5
		w["Shift"] *= 0.7
	if ai.AISpawner != null and ai.AISpawner.noHiding:
		w["Hide"] = 0.0
	return w

func _apply_weapon_role_bias(ai: Node, w: Dictionary, dist: float) -> void:
	match _vai_weapon_role(ai):
		"pistol":
			if dist > 25.0:
				w["Attack"] = float(w.get("Attack", 0.0)) * 2.0
				w["Shift"] = float(w.get("Shift", 0.0)) * 2.0
				w["Hunt"] = float(w.get("Hunt", 0.0)) * 1.8
				w["Vantage"] = float(w.get("Vantage", 0.0)) * 0.2
			else:
				w["Combat"] = float(w.get("Combat", 0.0)) * 1.6
		"shotgun":
			w["Attack"] = float(w.get("Attack", 0.0)) * 2.5
			w["Shift"] = float(w.get("Shift", 0.0)) * 2.0
			w["Vantage"] = float(w.get("Vantage", 0.0)) * 0.1
			w["Cover"] = float(w.get("Cover", 0.0)) * 0.6
		"rifle_bolt":
			w["Vantage"] = float(w.get("Vantage", 0.0)) * 3.0
			w["Defend"] = float(w.get("Defend", 0.0)) * 2.0
			w["Cover"] = float(w.get("Cover", 0.0)) * 1.6
			w["Attack"] = 0.0
			w["Hunt"] = float(w.get("Hunt", 0.0)) * 0.3
			w["Shift"] = float(w.get("Shift", 0.0)) * 0.4
		"rifle_auto":
			w["Combat"] = float(w.get("Combat", 0.0)) * 1.2
			w["Defend"] = float(w.get("Defend", 0.0)) * 1.2
		_:
			pass

func _weighted_pick(weights: Dictionary) -> String:
	var total := 0.0
	for v in weights.values():
		total += float(v)
	if total <= 0.0:
		return ""
	var roll := randf() * total
	for key in weights.keys():
		roll -= float(weights[key])
		if roll <= 0.0:
			return String(key)
	return ""

func _roll_chance(p: float) -> bool:
	return randf() < p

# ─── AISpawner hook ──────────────────────────────────────────────────

# Replaces vanilla SpawnWanderer with a group-spawn option. When disabled,
# out of budget, or the roll doesn't hit, we do nothing and let vanilla run.
func _hook_aispawner_spawnwanderer() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		return
	var spawner = lib._caller
	if spawner == null or not is_instance_valid(spawner):
		return
	if not cfg_enabled or not cfg_group_spawn_on:
		return   # let vanilla run
	if randf() >= cfg_group_spawn_chance:
		return   # let vanilla run
	var group_size: int = randi_range(cfg_group_min, cfg_group_max)
	group_size = mini(group_size, spawner.APool.get_child_count())
	if group_size < 2:
		return   # let vanilla run
	_vai_spawn_group(spawner, group_size)
	lib.skip_super()

func _vai_spawn_group(spawner: Node, size: int) -> void:
	var valid_points: Array = []
	for point in spawner.spawns:
		var d: float = point.global_position.distance_to(gameData.playerPosition)
		if d > spawner.spawnDistance:
			valid_points.append(point)
	if valid_points.is_empty():
		print("[VostokAI Spawner] No valid spawn points for squad")
		return
	var base_point = valid_points[randi_range(0, valid_points.size() - 1)]
	_next_squad_id += 1
	var squad_id: int = _next_squad_id
	var leader_ref = null
	var spawned: int = 0

	for i in size:
		if spawner.APool.get_child_count() == 0:
			print("[VostokAI Spawner] APool ended mid-group")
			break
		var agent_node = spawner.APool.get_child(0)
		agent_node.reparent(spawner.agents)
		agent_node.global_transform = base_point.global_transform
		agent_node.global_position += Vector3(
			randf_range(-3.0, 3.0), 0.0, randf_range(-3.0, 3.0)
		)
		agent_node.currentPoint = base_point
		# Stamp squad metadata via set_meta — legacy `vai_X in node_ref`
		# checks still succeed because set_meta-backed properties pass `in`
		# via Object's has_meta path (tested in our v3 migration).
		agent_node.set_meta("vai_squad_id", squad_id)
		agent_node.set_meta("vai_is_leader", i == 0)
		agent_node.set_meta("vai_formation_slot", i)
		if i == 0:
			leader_ref = agent_node
		else:
			agent_node.set_meta("vai_squad_leader", leader_ref)
		agent_node.ActivateWanderer()
		spawner.activeAgents += 1
		spawned += 1

	print("[VostokAI Spawner] Squad of %d spawned (id=%d)" % [spawned, squad_id])

# ─── Squad registry (unchanged — called from hook callbacks) ─────────

func register_agent(agent: Node) -> void:
	if not _agents.has(agent):
		_agents.append(agent)

func unregister_agent(agent: Node) -> void:
	_agents.erase(agent)
	_flank_slots.erase(agent)
	_rebalance_flanks()

func _alive_agents() -> Array:
	var out: Array = []
	for a in _agents:
		if is_instance_valid(a) and not a.get("dead"):
			out.append(a)
	return out

# ─── Sighting broadcast ──────────────────────────────────────────────

# Used to call `ally.vai_receive_callout(...)` via has_method on the AI.gd
# subclass. Post-migration, the recipient method lives here on Main.gd,
# so we dispatch to `_receive_callout(ally, ...)` directly — no subclass
# required on the AI instance.
func broadcast_sighting(source: Node, location: Vector3) -> void:
	if not cfg_squad_on:
		return
	if not is_instance_valid(source):
		return
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
		_receive_callout(ally, location, source)

func broadcast_death(source: Node, location: Vector3) -> void:
	if not cfg_squad_on:
		return
	if not is_instance_valid(source):
		return
	var radius := cfg_squad_radius * 1.5
	for ally in _alive_agents():
		if ally == source:
			continue
		var dist: float = ally.global_position.distance_to(source.global_position)
		if dist > radius:
			continue
		_receive_death_alert(ally, location, source)

# Receive-callout / receive-death — used to be methods on the AI subclass;
# now they're methods here that take the ally AI as the first argument.
func _receive_callout(ai: Node, location: Vector3, _source: Node) -> void:
	if ai.dead or ai.pause:
		return
	if ai.currentState != ai.State.Ambush:
		ai.lastKnownLocation = location
	var s = ai.currentState
	if s == ai.State.Wander or s == ai.State.Guard or s == ai.State.Patrol or s == ai.State.Idle:
		match _ai_personality(ai):
			"COWARD":
				if _roll_chance(0.5):
					ai.ChangeState("Cover")
				else:
					ai.ChangeState("Defend")
			"AGGRESSOR":
				if ai.playerDistance3D < 80.0 and ai.weaponData != null and ai.weaponData.weaponAction != "Manual":
					ai.ChangeState("Attack")
				else:
					ai.ChangeState("Hunt")
			"METHODICAL":
				if _roll_chance(0.5):
					ai.ChangeState("Vantage")
				else:
					ai.ChangeState("Cover")
			"GUARD":
				ai.ChangeState("Defend")
			"FRENZY":
				if _roll_chance(0.6):
					ai.ChangeState("Shift")
				else:
					ai.ChangeState("Combat")

func _receive_death_alert(ai: Node, location: Vector3, _source: Node) -> void:
	if ai.dead or ai.pause:
		return
	ai.lastKnownLocation = location
	_ai_set_suppression(ai, min(VAI_SUPPRESSION_MAX, _ai_suppression(ai) + 30.0))
	match _ai_personality(ai):
		"COWARD":
			if not ai.AISpawner.noHiding:
				ai.ChangeState("Hide")
			else:
				ai.ChangeState("Cover")
		"AGGRESSOR":
			ai.ChangeState("Attack" if ai.weaponData != null and ai.weaponData.weaponAction != "Manual" else "Hunt")
		"METHODICAL":
			ai.ChangeState("Cover")
		"GUARD":
			ai.ChangeState("Defend")
		"FRENZY":
			ai.ChangeState("Shift")

# Legacy alias shims — in case other mods stored a reference to Main and
# were calling these older names. Safe to keep; tiny overhead.
func vai_receive_callout(location: Vector3, source: Node) -> void:
	broadcast_sighting(source, location)

func vai_receive_death_alert(location: Vector3, source: Node) -> void:
	broadcast_death(source, location)

# ─── Flanking slot assignment ───────────────────────────────────────

func request_flank_slot(agent: Node) -> String:
	if not cfg_squad_on:
		return "CENTER"
	var counts := {"LEFT": 0, "RIGHT": 0, "CENTER": 0}
	for a in _flank_slots.keys():
		if is_instance_valid(a) and not a.get("dead"):
			counts[_flank_slots[a]] += 1
		else:
			_flank_slots.erase(a)
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
	for a in _flank_slots.keys():
		if not is_instance_valid(a) or a.get("dead"):
			_flank_slots.erase(a)

# ─── Personality assignment ─────────────────────────────────────────

func pick_personality() -> String:
	if not cfg_personalities_on:
		return "GUARD"
	var scaling := _get_progression_scale()
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

func _get_progression_scale() -> float:
	if not cfg_difficulty_scaling_on:
		return 0.0
	var xp := 0
	var xp_mod = Engine.get_meta("XPMain", null)
	if xp_mod and "xpTotal" in xp_mod:
		xp = xp_mod.xpTotal
	elif "xpTotal" in gameData:
		xp = gameData.xpTotal
	if xp < 200:    return 0.0
	if xp < 1000:   return 0.33
	if xp < 3000:   return 0.66
	return 1.0

func get_accuracy_mult() -> float:
	var base: float = cfg_difficulty
	var scale: float = _get_progression_scale()
	return base * (1.0 + scale * 0.3)

func get_reaction_mult() -> float:
	var base: float = cfg_difficulty
	var scale: float = _get_progression_scale()
	return base * (1.0 + scale * 0.4)

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
