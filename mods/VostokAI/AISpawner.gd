extends "res://Scripts/AISpawner.gd"

# Vostok AI — AISpawner override
# Augments the vanilla spawner so that some of the scheduled wanderer
# spawns instead produce a small squad (2–4 agents) that starts together
# at the same spawn point. Squad members are tagged with a shared squad
# ID and a leader reference so the AI.gd override can keep them cohering
# during non-combat states.

var _vai_main = null
var _vai_next_squad_id: int = 0

func _ready() -> void:
	super()
	_vai_main = Engine.get_meta("VostokAIMain", null)

# Replace vanilla SpawnWanderer with one that may roll a group spawn.
# When group spawning is disabled, missing Main, or not enough pool slots
# remain, we defer to super() for the vanilla single-spawn path.
func SpawnWanderer() -> void:
	if _vai_main == null or not _vai_main.cfg_enabled or not _vai_main.cfg_group_spawn_on:
		super()
		return
	if randf() >= _vai_main.cfg_group_spawn_chance:
		super()
		return
	# Roll a group size and let it slightly overshoot spawnLimit when the
	# user opted into group spawns. Vanilla's spawner will skip subsequent
	# spawn ticks until the squad thins out, so the overshoot is temporary.
	# We still cap against APool availability (that's a hard limit).
	var group_size: int = randi_range(_vai_main.cfg_group_min, _vai_main.cfg_group_max)
	group_size = mini(group_size, APool.get_child_count())
	if group_size < 2:
		super()
		return
	_vai_spawn_group(group_size)

func _vai_spawn_group(size: int) -> void:
	# Filter spawn points to ones outside the player's spawn bubble
	var valid_points: Array = []
	for point in spawns:
		var d: float = point.global_position.distance_to(gameData.playerPosition)
		if d > spawnDistance:
			valid_points.append(point)
	if valid_points.is_empty():
		print("[VostokAI Spawner] No valid spawn points for squad")
		return
	var base_point = valid_points[randi_range(0, valid_points.size() - 1)]
	_vai_next_squad_id += 1
	var squad_id: int = _vai_next_squad_id
	var leader_ref = null
	var spawned: int = 0

	for i in size:
		if APool.get_child_count() == 0:
			print("[VostokAI Spawner] APool ended mid-group")
			break
		var agent_node = APool.get_child(0)
		agent_node.reparent(agents)
		agent_node.global_transform = base_point.global_transform
		# Small per-agent offset so they don't stack on one point
		agent_node.global_position += Vector3(
			randf_range(-3.0, 3.0), 0.0, randf_range(-3.0, 3.0)
		)
		agent_node.currentPoint = base_point
		# Assign squad metadata — the AI.gd override reads these members.
		# Guard each set with an `in` check in case another AI mod stripped
		# our additions (future-proofing for chain mods).
		if "vai_squad_id" in agent_node:
			agent_node.vai_squad_id = squad_id
		if "vai_is_leader" in agent_node:
			agent_node.vai_is_leader = (i == 0)
		if "vai_formation_slot" in agent_node:
			agent_node.vai_formation_slot = i   # 0 = leader, 1..N = followers
		if i == 0:
			leader_ref = agent_node
		elif "vai_squad_leader" in agent_node:
			agent_node.vai_squad_leader = leader_ref
		agent_node.ActivateWanderer()
		activeAgents += 1
		spawned += 1

	print("[VostokAI Spawner] Squad of %d spawned (id=%d)" % [spawned, squad_id])
