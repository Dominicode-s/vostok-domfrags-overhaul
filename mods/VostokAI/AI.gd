extends "res://Scripts/AI.gd"

# Vostok AI — AI.gd override
#
# Adds on top of the vanilla AI state machine:
#   - Personality archetype (COWARD / AGGRESSOR / METHODICAL / GUARD / FRENZY)
#   - Squad coordination (sighting broadcasts, flank slots, death alerts)
#   - Enhanced hearing (gunshots, footsteps, crouch)
#   - Suppression meter that degrades aim
#   - Damage reaction (taking a hit triggers a personality-dependent response)
#   - Active investigation (sweep LKL area instead of idling)
#   - XP-scaled difficulty (accuracy and reaction speed grow with player progression)
#
# All new state lives in `vai_*` members/methods to avoid clashing with the
# base class. Vanilla methods we replace: Decision, Hearing, FireDetection,
# WeaponDamage, Death. Vanilla methods we extend with super(): Initialize,
# _physics_process, ChangeState, FireAccuracy.

# ─── Tuning constants ────────────────────────────────────────────────

const VAI_SUPPRESSION_DECAY_PER_SEC := 18.0     # Suppression bleeds off over time
const VAI_SUPPRESSION_ON_HIT := 45.0             # Flat bump when we take damage
const VAI_SUPPRESSION_ON_NEAR_MISS := 12.0       # When player fires vaguely at us
const VAI_SUPPRESSION_ON_DIRECT_AIM := 6.0       # When player aims & fires at us
const VAI_SUPPRESSION_COVER_THRESHOLD := 55.0    # Triggers cover-seeking
const VAI_SUPPRESSION_MAX := 100.0

const VAI_INVESTIGATE_STEPS := 3                  # Number of sweep points after losing contact
const VAI_INVESTIGATE_RADIUS := 8.0               # How far each sweep point is from LKL
const VAI_CALLOUT_COOLDOWN_MS := 1500             # Min time between personal callouts

const VAI_COWARD_FLEE_HP := 45.0                  # Below this HP, coward flees
const VAI_METHODICAL_FLEE_HP := 20.0              # Below this HP, methodical flees
const VAI_GUARD_RETURN_DISTANCE := 25.0           # Guards return if pushed too far

# ─── New agent state ─────────────────────────────────────────────────

var vai_personality: String = "GUARD"
var vai_registered: bool = false
var vai_suppression: float = 0.0
var vai_last_callout_ms: int = 0
var vai_investigation_queue: Array = []   # Array[Vector3] of points to sweep
var vai_investigation_pending: bool = false
var vai_flank_slot: String = "CENTER"
var vai_was_in_combat: bool = false
var vai_last_seen_ms: int = 0             # When we last had LOS on player

# Squad membership — set by AISpawner when group spawning
var vai_squad_id: int = 0                 # 0 = no squad (lone wanderer)
var vai_is_leader: bool = false
var vai_squad_leader = null               # another AI ref, or null
var vai_cohesion_timer: float = 0.0

const VAI_COHESION_CHECK_INTERVAL := 1.8
const VAI_COHESION_ARRIVE_SLOP := 6.0     # Stop pulling in when within this radius

# v1.2 — reaction time, panic, backup, weapon roles, formations
var vai_first_sighted_ms: int = 0          # When we gained LOS this time
var vai_prev_visible: bool = false
var vai_panicked: bool = false
var vai_panic_end_ms: int = 0
var vai_backup_requested: bool = false     # One request per lifetime
var vai_backup_fire_ms: int = 0             # When pending spawn should fire
var vai_formation_slot: int = 0             # 0=leader/center, 1=left-back, 2=right-back, 3=rear

const VAI_PANIC_DURATION_MS := 11000
const VAI_PANIC_HP_THRESHOLD := 0.22
const VAI_PANIC_SUPPRESSION_THRESHOLD := 55.0
const VAI_BACKUP_HP_THRESHOLD := 0.45
const VAI_BACKUP_DELAY_MS := 5500
const VAI_BACKUP_SPAWN_RADIUS := 10.0

# Cached main ref (looked up once on Initialize)
var _vai_main = null

# ─── Lifecycle overrides ─────────────────────────────────────────────

func Initialize() -> void:
	super()
	_vai_main = Engine.get_meta("VostokAIMain", null)
	if _vai_main == null or not _vai_main.cfg_enabled:
		return
	# Pick personality
	vai_personality = _vai_main.pick_personality()
	# Bosses get a forced aggressive profile — they should feel different
	if boss:
		vai_personality = "AGGRESSOR"
	# Register with squad coordinator
	_vai_main.register_agent(self)
	vai_registered = true
	# Personality-specific tuning
	_apply_personality_tuning()

func _apply_personality_tuning() -> void:
	# Tweak a few vanilla parameters based on personality. These values feed
	# into the base class's fire/voice logic to make each archetype feel
	# different without re-implementing the whole pipeline.
	match vai_personality:
		"COWARD":
			voiceCycle = randf_range(20.0, 60.0)      # less chatty
		"AGGRESSOR":
			voiceCycle = randf_range(5.0, 20.0)        # very chatty
		"METHODICAL":
			voiceCycle = randf_range(15.0, 45.0)
		"GUARD":
			voiceCycle = randf_range(10.0, 40.0)
		"FRENZY":
			voiceCycle = randf_range(3.0, 15.0)        # constant shouting

# Tick suppression decay on top of vanilla physics. Detect player aim at us
# so we accumulate suppression when under fire.
func _physics_process(delta: float) -> void:
	super(delta)
	if pause or dead:
		return
	if _vai_main == null or not _vai_main.cfg_enabled:
		return
	if _vai_main.cfg_suppression_on:
		_vai_tick_suppression(delta)
	if _vai_main.cfg_investigation_on:
		_vai_tick_investigation()
	if _vai_main.cfg_squad_cohesion_on:
		_vai_tick_cohesion(delta)
	_vai_tick_sighting_edge()
	if _vai_main.cfg_panic_on:
		_vai_tick_panic()
	if _vai_main.cfg_call_backup_on:
		_vai_tick_backup()
	# Track last time we saw the player (for losing-contact detection)
	if playerVisible:
		vai_last_seen_ms = Time.get_ticks_msec()

# ─── Suppression ────────────────────────────────────────────────────

func _vai_tick_suppression(delta: float) -> void:
	# Decay over time
	if vai_suppression > 0.0:
		vai_suppression = max(0.0, vai_suppression - VAI_SUPPRESSION_DECAY_PER_SEC * delta)

	# Accumulate from player fire when we're roughly in their line of fire.
	# `fireVector` is maintained by the base class: it's the dot product of
	# (this AI from player) and (player aim direction). Near 1.0 = player is
	# aimed at this AI.
	if gameData.isFiring and playerDistance3D < 150.0:
		if fireVector > 0.93:
			vai_suppression = min(VAI_SUPPRESSION_MAX,
				vai_suppression + VAI_SUPPRESSION_ON_DIRECT_AIM * delta * 60.0)
		elif fireVector > 0.7 and playerDistance3D < 50.0:
			vai_suppression = min(VAI_SUPPRESSION_MAX,
				vai_suppression + VAI_SUPPRESSION_ON_NEAR_MISS * delta * 60.0)

	# Heavy suppression → seek cover (once, not every frame)
	if vai_suppression >= VAI_SUPPRESSION_COVER_THRESHOLD:
		if currentState == State.Combat or currentState == State.Hunt or currentState == State.Defend:
			if vai_personality != "FRENZY":  # Frenzy ignores suppression
				ChangeState("Cover")
				vai_suppression = VAI_SUPPRESSION_COVER_THRESHOLD - 10.0   # prevent thrash

# ─── Vanilla replacements ───────────────────────────────────────────

# Replaces the vanilla pure-random Decision() with a personality- and
# situation-weighted one.
func Decision() -> void:
	if _vai_main == null or not _vai_main.cfg_enabled or not _vai_main.cfg_personalities_on:
		super()
		return
	# Panicked bots have no tactical decision-making — they shift wildly
	if vai_panicked:
		ChangeState("Shift")
		return
	# Trigger panic if conditions meet
	if _vai_main.cfg_panic_on and _vai_should_panic():
		_vai_enter_panic()
		return
	# Low HP override — regardless of personality, heavily wounded agents
	# take cover (or flee if they're cowards/methodicals).
	var hp_ratio: float = clamp(float(health) / 100.0, 0.0, 1.0)
	if hp_ratio < VAI_COWARD_FLEE_HP / 100.0 and vai_personality == "COWARD":
		if not AISpawner.noHiding and _roll_chance(0.75):
			ChangeState("Hide")
			return
	if hp_ratio < VAI_METHODICAL_FLEE_HP / 100.0 and vai_personality == "METHODICAL":
		if not AISpawner.noHiding and _roll_chance(0.55):
			ChangeState("Hide")
			return
	# Suppression override — heavy suppression pushes toward cover
	if vai_suppression >= VAI_SUPPRESSION_COVER_THRESHOLD and vai_personality != "FRENZY":
		ChangeState("Cover")
		return

	# Normal personality-weighted decision
	var dist: float = float(playerDistance3D)
	var has_semi: bool = weaponData != null and weaponData.weaponAction != "Manual"
	var can_push: bool = bool(playerVisible) and dist < 100.0 and not bool(gameData.isTrading)
	var weights: Dictionary = _decision_weights(dist, has_semi, can_push)
	# Weapon-role bias applied on top of personality
	if _vai_main.cfg_weapon_roles_on:
		_apply_weapon_role_bias(weights, dist)
	var choice: String = _weighted_pick(weights)
	if choice != "":
		# Guards should return to their post if they've been pushed too far
		if vai_personality == "GUARD" and currentState == State.Combat:
			if currentPoint and global_position.distance_to(currentPoint.global_position) > VAI_GUARD_RETURN_DISTANCE:
				attackReturn = true
		ChangeState(choice)

# Adjust state weights based on equipped weapon role. Pistols rush, bolts
# camp vantages, shotguns push close, automatic rifles stay balanced.
func _apply_weapon_role_bias(w: Dictionary, dist: float) -> void:
	var role: String = _vai_weapon_role()
	match role:
		"pistol":
			# Pistol bots want to close the gap — range is dead
			if dist > 25.0:
				w["Attack"] = float(w.get("Attack", 0.0)) * 2.0
				w["Shift"] = float(w.get("Shift", 0.0)) * 2.0
				w["Hunt"] = float(w.get("Hunt", 0.0)) * 1.8
				w["Vantage"] = float(w.get("Vantage", 0.0)) * 0.2
			else:
				w["Combat"] = float(w.get("Combat", 0.0)) * 1.6
		"shotgun":
			# Shotguns are rush weapons — always try to get close
			w["Attack"] = float(w.get("Attack", 0.0)) * 2.5
			w["Shift"] = float(w.get("Shift", 0.0)) * 2.0
			w["Vantage"] = float(w.get("Vantage", 0.0)) * 0.1
			w["Cover"] = float(w.get("Cover", 0.0)) * 0.6
		"rifle_bolt":
			# Bolt-action = patient, long range. No rushing.
			w["Vantage"] = float(w.get("Vantage", 0.0)) * 3.0
			w["Defend"] = float(w.get("Defend", 0.0)) * 2.0
			w["Cover"] = float(w.get("Cover", 0.0)) * 1.6
			w["Attack"] = 0.0
			w["Hunt"] = float(w.get("Hunt", 0.0)) * 0.3
			w["Shift"] = float(w.get("Shift", 0.0)) * 0.4
		"rifle_auto":
			# Balanced — slight bias to holding fire lanes
			w["Combat"] = float(w.get("Combat", 0.0)) * 1.2
			w["Defend"] = float(w.get("Defend", 0.0)) * 1.2
		_:
			pass

func _decision_weights(dist: float, has_semi: bool, can_push: bool) -> Dictionary:
	# Build a weighted dictionary of state -> weight based on personality + situation.
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
	# Personality biases
	match vai_personality:
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

	# Situation biases
	if not can_push:
		w["Hunt"] = 0.0
		w["Shift"] = 0.0
		w["Attack"] = 0.0
	if not has_semi:
		w["Attack"] = 0.0
	if dist < 20.0:
		w["Vantage"] *= 0.3   # no point in repositioning to vantage at knife range
		w["Cover"] *= 0.5
	if dist > 60.0:
		w["Attack"] *= 0.5    # rushing from 60m is suicide
		w["Shift"] *= 0.7
	if AISpawner != null and AISpawner.noHiding:
		w["Hide"] = 0.0

	return w

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

# Replaces vanilla Hearing() with a much richer model. Vanilla only detected
# running < 20m and walking < 5m. We detect gunshots at long range, add
# crouch detection, and factor in player state properly.
func Hearing() -> void:
	if _vai_main == null or not _vai_main.cfg_enabled or not _vai_main.cfg_hearing_on:
		super()
		return
	# Gunshots — the loudest stimulus. Vanilla handles firing separately in
	# FireDetection() for narrow-cone detection; here we broaden it so shots
	# from any direction carry.
	if gameData.isFiring and playerDistance3D < _vai_main.cfg_hear_gunshot:
		if currentState != State.Ambush:
			lastKnownLocation = playerPosition
		if currentState == State.Wander or currentState == State.Guard or currentState == State.Patrol:
			Decision()
		elif currentState == State.Ambush:
			ChangeState("Combat")
		_vai_call_out_to_squad(playerPosition)
		return

	# Footsteps — running / walking / crouching
	var hear_dist := 0.0
	if gameData.isRunning:
		hear_dist = _vai_main.cfg_hear_running
	elif gameData.isWalking:
		hear_dist = _vai_main.cfg_hear_walking
	elif gameData.isCrouching:
		hear_dist = _vai_main.cfg_hear_crouch

	if hear_dist > 0.0 and playerDistance3D < hear_dist:
		if currentState != State.Ambush:
			lastKnownLocation = playerPosition
		if currentState == State.Wander or currentState == State.Guard or currentState == State.Patrol:
			Decision()

# Replaces FireDetection with a version that also broadcasts sightings.
func FireDetection(delta: float) -> void:
	super(delta)
	if _vai_main == null or not _vai_main.cfg_enabled:
		return
	if fireDetected and _vai_main.cfg_squad_on:
		# Tell squadmates roughly where the shot came from
		_vai_call_out_to_squad(playerPosition)

# Replaces WeaponDamage to inject damage reaction + squad callout + suppression.
func WeaponDamage(hitbox: String, damage: float) -> void:
	var was_dead: bool = bool(dead)
	super(hitbox, damage)
	if was_dead or _vai_main == null or not _vai_main.cfg_enabled:
		return
	if dead:
		return   # Death() will handle the broadcast separately
	# Suppression bump
	if _vai_main.cfg_suppression_on:
		vai_suppression = min(VAI_SUPPRESSION_MAX, vai_suppression + VAI_SUPPRESSION_ON_HIT)
	# Every hit tells you exactly where the player is
	lastKnownLocation = playerPosition
	# Squad broadcast — wounded ally shouts
	if _vai_main.cfg_squad_on:
		_vai_main.broadcast_sighting(self, playerPosition)
	# Personality-dependent reaction
	if _vai_main.cfg_damage_react_on:
		_vai_react_to_damage()

func _vai_react_to_damage() -> void:
	var hp_ratio: float = clamp(float(health) / 100.0, 0.0, 1.0)
	match vai_personality:
		"COWARD":
			if hp_ratio < 0.6 and not AISpawner.noHiding:
				ChangeState("Hide")
			else:
				ChangeState("Cover")
		"AGGRESSOR":
			# Take the hit and push through — aggressors retaliate
			if playerVisible and weaponData != null and weaponData.weaponAction != "Manual":
				ChangeState("Attack")
			else:
				ChangeState("Shift")
		"METHODICAL":
			if hp_ratio < 0.3 and not AISpawner.noHiding:
				ChangeState("Hide")
			else:
				ChangeState("Cover")
		"GUARD":
			# Guards dig in when hit — they don't fall back until heavily wounded
			if hp_ratio < 0.35:
				ChangeState("Cover")
			else:
				ChangeState("Defend")
		"FRENZY":
			# Take a shot, shake it off, reposition
			ChangeState("Shift")

# Override Death to broadcast + deregister.
func Death(direction, force) -> void:
	if _vai_main != null and _vai_main.cfg_enabled and _vai_main.cfg_squad_on:
		# Broadcast first, before super() tears down our state
		_vai_main.broadcast_death(self, global_position)
	if _vai_main != null and vai_registered:
		_vai_main.unregister_agent(self)
		vai_registered = false
	super(direction, force)

# ─── Squad integration hooks ─────────────────────────────────────────

# Called by Main.gd when a squadmate sees/hears the player within our
# callout radius. We update our LKL and maybe transition into combat.
func vai_receive_callout(location: Vector3, _source: Node) -> void:
	if dead or pause:
		return
	# Update LKL for non-ambushers (ambushers stay put)
	if currentState != State.Ambush:
		lastKnownLocation = location
	# If idle, transition into combat. Personality decides how aggressive.
	match currentState:
		State.Wander, State.Guard, State.Patrol, State.Idle:
			match vai_personality:
				"COWARD":
					# Cowards go to cover on a callout, don't charge
					if _roll_chance(0.5):
						ChangeState("Cover")
					else:
						ChangeState("Defend")
				"AGGRESSOR":
					if playerDistance3D < 80.0 and weaponData != null and weaponData.weaponAction != "Manual":
						ChangeState("Attack")
					else:
						ChangeState("Hunt")
				"METHODICAL":
					if _roll_chance(0.5):
						ChangeState("Vantage")
					else:
						ChangeState("Cover")
				"GUARD":
					ChangeState("Defend")
				"FRENZY":
					if _roll_chance(0.6):
						ChangeState("Shift")
					else:
						ChangeState("Combat")

# Called when a nearby squadmate dies. We gain immediate certainty about
# the threat's location and are much more likely to push or dig in.
func vai_receive_death_alert(location: Vector3, _source: Node) -> void:
	if dead or pause:
		return
	lastKnownLocation = location
	# Major morale hit — bump suppression even on allies (shaken by the loss)
	vai_suppression = min(VAI_SUPPRESSION_MAX, vai_suppression + 30.0)
	# Overall squad response — biased toward combat readiness
	match vai_personality:
		"COWARD":
			# A squadmate just died — cowards actually break and hide
			if not AISpawner.noHiding:
				ChangeState("Hide")
			else:
				ChangeState("Cover")
		"AGGRESSOR":
			ChangeState("Attack" if weaponData != null and weaponData.weaponAction != "Manual" else "Hunt")
		"METHODICAL":
			ChangeState("Cover")
		"GUARD":
			ChangeState("Defend")
		"FRENZY":
			ChangeState("Shift")

# Broadcast our own sighting to squadmates (throttled per-agent).
func _vai_call_out_to_squad(location: Vector3) -> void:
	if _vai_main == null:
		return
	var now := Time.get_ticks_msec()
	if now - vai_last_callout_ms < VAI_CALLOUT_COOLDOWN_MS:
		return
	vai_last_callout_ms = now
	_vai_main.broadcast_sighting(self, location)

# ─── Investigation ───────────────────────────────────────────────────

# After losing sight of the player while in Combat/Hunt/Attack, queue a
# small search pattern around the last known location so AIs actually
# sweep instead of stopping at LKL.
func _vai_tick_investigation() -> void:
	if _vai_main == null or not _vai_main.cfg_investigation_on:
		return
	# Only investigate if we recently had contact but lost it
	var now := Time.get_ticks_msec()
	var time_since_seen_ms := now - vai_last_seen_ms
	# Start an investigation if we're hunting with no vis
	if currentState == State.Hunt and not playerVisible and time_since_seen_ms > 3500 and not vai_investigation_pending:
		_vai_start_investigation()

# ─── Squad cohesion ──────────────────────────────────────────────────

# Followers pull toward their leader during non-combat states so squads
# that were spawned together actually travel together. Combat states are
# left alone so tactical decisions (cover / flank / push) still work.
func _vai_tick_cohesion(delta: float) -> void:
	if vai_is_leader or vai_squad_leader == null:
		return
	# Validate leader ref — a dead or freed leader releases cohesion
	if not is_instance_valid(vai_squad_leader) or vai_squad_leader.get("dead"):
		vai_squad_leader = null
		return
	# Only pull during idle / wander / patrol. Combat states have their
	# own positioning logic we don't want to fight.
	if currentState != State.Wander and currentState != State.Patrol and currentState != State.Idle:
		return
	vai_cohesion_timer -= delta
	if vai_cohesion_timer > 0.0:
		return
	vai_cohesion_timer = VAI_COHESION_CHECK_INTERVAL
	var max_dist: float = _vai_main.cfg_cohesion_distance
	var dist: float = global_position.distance_to(vai_squad_leader.global_position)
	if dist <= max_dist:
		return
	# Compute the target point. Formations mode picks a proper slot (wedge /
	# column); otherwise we fall back to a small random scatter.
	var target: Vector3 = vai_squad_leader.global_position
	if _vai_main.cfg_formations_on:
		target += _vai_formation_offset()
	else:
		target += Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	MoveToPoint(target)

# Compute this follower's formation offset from the leader based on slot.
# Slots: 1 = back-left, 2 = back-right, 3 = rear-center, 4+ = wider wedge.
# We use the leader's facing (rotation.y) as the formation anchor so the
# group turns together.
func _vai_formation_offset() -> Vector3:
	if vai_squad_leader == null:
		return Vector3.ZERO
	var yaw: float = vai_squad_leader.rotation.y
	# Godot convention: -Z is forward. Leader forward = (-sin(yaw), 0, -cos(yaw)).
	var fwd: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	match vai_formation_slot:
		1: return -fwd * 3.5 + right * -2.8   # back-left wing
		2: return -fwd * 3.5 + right * 2.8    # back-right wing
		3: return -fwd * 6.0                   # rear
		4: return -fwd * 5.5 + right * -4.5    # wide back-left
		5: return -fwd * 5.5 + right * 4.5     # wide back-right
		_: return -fwd * 2.5                   # default trail

# ─── Reaction-time / sighting edge detection ─────────────────────────

# Track rising edges on player visibility so Fire() can enforce a short
# "look before you shoot" delay tuned to personality.
func _vai_tick_sighting_edge() -> void:
	if playerVisible and not vai_prev_visible:
		vai_first_sighted_ms = Time.get_ticks_msec()
	vai_prev_visible = playerVisible

func _vai_reaction_delay_ms() -> int:
	# Base delay ± small jitter. Aggressor/Frenzy snap fast, Coward is slow.
	var base: int
	match vai_personality:
		"AGGRESSOR":  base = 180
		"FRENZY":     base = 160
		"GUARD":      base = 330
		"METHODICAL": base = 440
		"COWARD":     base = 720
		_:            base = 300
	# Difficulty scaling tightens reaction as XP climbs
	if _vai_main != null:
		var mult: float = 1.0 / max(0.3, _vai_main.get_reaction_mult())
		base = int(float(base) * mult)
	# ±80ms jitter so no two bots feel identical
	return base + randi_range(-80, 80)

# ─── Panic ───────────────────────────────────────────────────────────

func _vai_tick_panic() -> void:
	if vai_panicked and Time.get_ticks_msec() > vai_panic_end_ms:
		vai_panicked = false

func _vai_should_panic() -> bool:
	if vai_panicked:
		return false
	if not (vai_personality == "COWARD" or vai_personality == "METHODICAL"):
		return false
	var hp_ratio: float = clamp(float(health) / 100.0, 0.0, 1.0)
	if hp_ratio >= VAI_PANIC_HP_THRESHOLD:
		return false
	if vai_suppression < VAI_PANIC_SUPPRESSION_THRESHOLD:
		return false
	return true

func _vai_enter_panic() -> void:
	vai_panicked = true
	vai_panic_end_ms = Time.get_ticks_msec() + VAI_PANIC_DURATION_MS
	PlayCombat()   # scream
	# Kick an immediate Shift to break the current behavior loop
	ChangeState("Shift")

# ─── Call for backup ─────────────────────────────────────────────────

func _vai_tick_backup() -> void:
	# Step 1: decide if we should request backup
	if not vai_backup_requested:
		var hp_ratio: float = clamp(float(health) / 100.0, 0.0, 1.0)
		if hp_ratio < VAI_BACKUP_HP_THRESHOLD:
			if vai_personality == "COWARD" or vai_personality == "GUARD":
				# Only radio once we've actually engaged the player
				if currentState == State.Combat or currentState == State.Cover or currentState == State.Defend or currentState == State.Hunt:
					if _vai_main != null and _vai_main.try_request_backup():
						vai_backup_requested = true
						vai_backup_fire_ms = Time.get_ticks_msec() + VAI_BACKUP_DELAY_MS
						PlayCombat()  # shout "requesting support!"
	# Step 2: fire the spawn when the delay elapses
	if vai_backup_requested and Time.get_ticks_msec() >= vai_backup_fire_ms:
		# One-shot — flip the flag so we don't re-fire next tick
		vai_backup_fire_ms = 0x7FFFFFFF
		if is_instance_valid(AISpawner) and AISpawner.has_method("SpawnMinion"):
			var ox: float = randf_range(-VAI_BACKUP_SPAWN_RADIUS, VAI_BACKUP_SPAWN_RADIUS)
			var oz: float = randf_range(-VAI_BACKUP_SPAWN_RADIUS, VAI_BACKUP_SPAWN_RADIUS)
			var spawn_pos: Vector3 = global_position + Vector3(ox, 0.0, oz)
			AISpawner.SpawnMinion(spawn_pos)

# ─── Weapon-role helpers ────────────────────────────────────────────

func _vai_weapon_role() -> String:
	# Returns one of: "pistol", "rifle_auto", "rifle_bolt", "shotgun", "unknown"
	if weaponData == null:
		return "unknown"
	var wtype: String = ""
	var waction: String = ""
	if "weaponType" in weaponData and weaponData.weaponType != null:
		wtype = String(weaponData.weaponType)
	if "weaponAction" in weaponData and weaponData.weaponAction != null:
		waction = String(weaponData.weaponAction)
	if wtype == "Pistol":
		return "pistol"
	if waction == "Pump":
		return "shotgun"
	if waction == "Bolt" or waction == "Manual":
		return "rifle_bolt"
	if waction == "Semi-Auto" or waction == "Semi":
		return "rifle_auto"
	return "unknown"

func _vai_start_investigation() -> void:
	vai_investigation_pending = true
	vai_investigation_queue.clear()
	# Generate N points spiralling around LKL
	var base := lastKnownLocation
	for i in VAI_INVESTIGATE_STEPS:
		var angle: float = randf() * TAU
		var radius: float = VAI_INVESTIGATE_RADIUS * (0.5 + randf() * 1.5)
		var offset := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		vai_investigation_queue.append(base + offset)

# Override the vanilla Hunt tick so that after reaching LKL, we sweep through
# our investigation queue before giving up back to Combat.
func Hunt(delta: float) -> void:
	super(delta)
	if _vai_main == null or not _vai_main.cfg_enabled or not _vai_main.cfg_investigation_on:
		return
	if playerVisible:
		# Reacquired — cancel investigation
		vai_investigation_queue.clear()
		vai_investigation_pending = false
		return
	# If we've reached our current target and have queued sweep points, pop the next
	if agent.is_target_reached() or agent.is_navigation_finished():
		if vai_investigation_queue.size() > 0:
			var next_point: Vector3 = vai_investigation_queue.pop_front()
			MoveToPoint(next_point)
		else:
			vai_investigation_pending = false

# ─── Accuracy adjustment ─────────────────────────────────────────────

# Override Fire() to enforce reaction-time delay before the first shot
# of a fresh sighting, and to skip firing entirely while panicked (panic
# fires are routed through the base class at a wider spread anyway — but
# we want the cadence to stay natural).
func Fire(delta: float) -> void:
	if _vai_main != null and _vai_main.cfg_enabled and _vai_main.cfg_reaction_time_on:
		if playerVisible:
			var elapsed_ms: int = Time.get_ticks_msec() - vai_first_sighted_ms
			if elapsed_ms < _vai_reaction_delay_ms():
				return
	super(delta)

# Apply suppression + XP scaling + panic + weapon-role to aim spread.
func FireAccuracy() -> Vector3:
	var direction: Vector3 = super()
	if _vai_main == null or not _vai_main.cfg_enabled:
		return direction
	var suppression_factor: float = 1.0 + (vai_suppression / VAI_SUPPRESSION_MAX) * 1.8
	var accuracy_mult: float = _vai_main.get_accuracy_mult()
	var aim: Vector3 = playerPosition + Vector3(0, 1.0, 0)
	var spread_component: Vector3 = direction - aim
	var factor: float = suppression_factor / max(0.1, accuracy_mult)
	# Personality tweaks
	match vai_personality:
		"AGGRESSOR": factor *= 1.15
		"METHODICAL": factor *= 0.75
		"GUARD":      factor *= 0.9
		"FRENZY":     factor *= 1.5
		"COWARD":     factor *= 1.1
	# Weapon-role accuracy bias
	if _vai_main.cfg_weapon_roles_on:
		match _vai_weapon_role():
			"rifle_bolt":  factor *= 0.55   # bolt shooters are trained
			"shotgun":     factor *= 1.6    # pellet spread feel
			"pistol":      factor *= 1.25   # pistols inaccurate at range
			"rifle_auto":  factor *= 1.0
	# Panic obliterates accuracy
	if vai_panicked:
		factor *= 3.2
	return aim + spread_component * factor
