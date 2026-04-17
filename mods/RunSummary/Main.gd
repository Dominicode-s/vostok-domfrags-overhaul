extends Node

# Run Summary — Pure autoload, no script overrides
# Shows a post-run modal with stats after death or returning to shelter.
# Persists last 10 runs to disk. Hooks Cash/XP mods if present.

var gameData = preload("res://Resources/GameData.tres")

# ─── Run State Machine ───

enum RunState { IDLE, IN_RUN, RUN_ENDED }
var _run_state: int = RunState.IDLE

# ─── Snapshot (captured at run start) ───

var _snap_xp_total: int = 0
var _snap_health: float = 100.0
var _snap_energy: float = 100.0
var _snap_hydration: float = 100.0
var _snap_mental: float = 100.0
var _snap_inv_value: float = 0.0
var _snap_inv_count: int = 0
var _snap_time_real: int = 0
var _snap_time_game: float = 0.0
var _snap_map: String = ""
var _snap_zone: String = ""

# ─── Accumulators (incremented during run) ───

var _acc_kills: int = 0
var _acc_cash_earned: int = 0
var _acc_cash_spent: int = 0
var _acc_conditions: Array = []
var _acc_damage_taken: float = 0.0
var _acc_last_health: float = 100.0
var _acc_energy_used: float = 0.0
var _acc_last_energy: float = 100.0
var _acc_energy_restored: float = 0.0
var _acc_hydration_used: float = 0.0
var _acc_last_hydration: float = 100.0
var _acc_hydration_restored: float = 0.0
var _acc_mental_lost: float = 0.0
var _acc_last_mental: float = 100.0
var _acc_mental_restored: float = 0.0
var _acc_items_picked: int = 0
var _acc_last_inv_count: int = 0
var _inv_snapshot_ready: bool = false
var _acc_boss_kills: int = 0
var _last_inv_poll_ms: int = 0
const INV_POLL_INTERVAL_MS: int = 250  # 4Hz — plenty for pickup delta tracking

# ─── Kill Attribution ───

const FIRE_WINDOW_MS: int = 500  # grace period after releasing fire button
const GRENADE_WINDOW_MS: int = 6000  # 6s covers 3s fuse + travel + buffer
var _last_fire_time: int = 0
var _last_grenade_time: int = 0
var _prev_grenade1: bool = false
var _prev_grenade2: bool = false
var _tracked_ai: Array = []  # alive AI node refs for direct death detection

# ─── Scene Tracking ───

var _interface = null
# _last_scene holds the scene Node itself (not its name). Vostok names every
# gameplay map scene root "Map" (Cabin.tscn, Village.tscn, Area_05.tscn all
# use Map.gd as the root), so comparing scene.name missed map-to-map
# transitions entirely — which left _interface pointing at the freed
# Interface from the previous map and caused crashes when _end_run tried to
# read inventory value during a shelter death.
var _last_scene = null
var _was_dead: bool = false
var _was_shelter: bool = true
var _scene_ready: bool = false
# Records the history path we last loaded. Used to detect Patty profile
# switches — when _get_history_path() returns a different path on a menu→game
# transition, we reload _last_summary. Stays constant without Patty.
var _last_history_path: String = ""

# ─── UI ───

var _canvas_layer: CanvasLayer = null
var _overlay: ColorRect = null
var _modal_visible: bool = false
var _history_visible: bool = false
var _last_summary: Dictionary = {}
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED
var _prev_freeze: bool = false
var _modal_scene: PackedScene = null
var _history_scene: PackedScene = null
var _stats_header_scene: PackedScene = null
var _stats_row_scene: PackedScene = null
var _history_entry_scene: PackedScene = null
var _history_stat_part_scene: PackedScene = null

# All UI styling lives in the .tscn templates via theme/stylebox overrides —
# Main.gd only populates text and toggles visibility.

# ─── Config ───

var cfg_auto_show: bool = true
var cfg_reopen_key: int = KEY_F6

# ─── MCM ───

var _mcm_helpers = null
const MCM_FILE_PATH = "user://MCM/RunSummary"
const MCM_MOD_ID = "RunSummary"
const LOCAL_CFG_PATH = "user://RunSummaryConfig.cfg"
const HISTORY_PATH_LEGACY = "user://RunSummaryHistory.cfg"
const XP_PATH_LEGACY = "user://XPData.cfg"
const REOPEN_ACTION = "run_summary_reopen"

# ─── Condition names for display ───

const CONDITIONS = {
    "bleeding": "Bleeding", "fracture": "Fracture", "burn": "Burn",
    "frostbite": "Frostbite", "insanity": "Insanity", "rupture": "Rupture",
    "headshot": "Headshot", "starvation": "Starvation",
    "dehydration": "Dehydration", "poisoning": "Poisoning"
}

# ─── Initialization ───

func _ready():
    process_mode = Node.PROCESS_MODE_ALWAYS
    Engine.set_meta("RunSummaryMain", self)
    _modal_scene = load("res://mods/RunSummary/scenes/RunSummaryModal.tscn")
    _history_scene = load("res://mods/RunSummary/scenes/RunSummaryHistory.tscn")
    _stats_header_scene = load("res://mods/RunSummary/scenes/templates/RunSummaryStatsHeader.tscn")
    _stats_row_scene = load("res://mods/RunSummary/scenes/templates/RunSummaryStatsRow.tscn")
    _history_entry_scene = load("res://mods/RunSummary/scenes/templates/RunSummaryHistoryEntry.tscn")
    _history_stat_part_scene = load("res://mods/RunSummary/scenes/templates/RunSummaryHistoryStatPart.tscn")
    _mcm_helpers = _try_load_mcm()
    if _mcm_helpers:
        _register_mcm()
    else:
        _load_local_config()
    _register_hotkey(cfg_reopen_key)
    _hook_other_mods()
    # node_added is connected only while IN_RUN — the signal fires for every
    # node the engine spawns (particles, bullets, UI), so staying subscribed
    # in the main menu and shelter wastes a dispatch + property-list walk per
    # spawn and is the main source of the periodic stutter.
    _reload_last_summary_from_history()

func _on_node_added(node: Node):
    # Fast path: reject the vast majority of nodes with an O(1) method lookup
    # before walking the property list for the two `in` checks.
    if not node.has_method("Death"):
        return
    if "dead" in node and "boss" in node:
        if node not in _tracked_ai:
            _tracked_ai.append(node)

func _hook_other_mods():
    var cash_mod = Engine.get_meta("CashMain", null)
    if cash_mod:
        if cash_mod.has_signal("cash_sold"):
            cash_mod.cash_sold.connect(_on_cash_sold)
        if cash_mod.has_signal("cash_bought"):
            cash_mod.cash_bought.connect(_on_cash_bought)
        if cash_mod.has_signal("cash_picked_up"):
            cash_mod.cash_picked_up.connect(_on_cash_picked_up)
        print("[RunSummary] Hooked into Cash System signals")

func _on_cash_sold(amount: int, _items: Array):
    if _run_state == RunState.IN_RUN:
        _acc_cash_earned += amount

func _on_cash_bought(amount: int, _items: Array):
    if _run_state == RunState.IN_RUN:
        _acc_cash_spent += amount

func _on_cash_picked_up(amount: int):
    if _run_state == RunState.IN_RUN:
        _acc_cash_earned += amount

# ─── Main Loop ───

func _process(_delta):
    # Enforce game state every frame while modal is open
    # (game scripts may reset freeze/mouse_mode during scene transitions)
    if _modal_visible:
        if Input.mouse_mode != Input.MOUSE_MODE_CONFINED:
            Input.mouse_mode = Input.MOUSE_MODE_CONFINED
        if "freeze" in gameData and not gameData.freeze:
            gameData.freeze = true

    _update_interface()
    if not is_instance_valid(_interface):
        return

    match _run_state:
        RunState.IDLE:
            _check_run_start()
        RunState.IN_RUN:
            _track_run()
            _check_run_end()
        RunState.RUN_ENDED:
            pass

func _update_interface():
    var scene = get_tree().current_scene
    if scene == null:
        _last_scene = null
        _interface = null
        _scene_ready = false
        return

    # Compare by Node identity, not name — multiple Vostok scenes share the
    # root name "Map" and a naive name compare would hide real transitions.
    if scene != _last_scene:
        _last_scene = scene
        _interface = null
        _scene_ready = false
        # On every scene change, check whether the Patty profile changed
        # while we were in a previous scene / menu. Zero cost without Patty.
        if _get_history_path() != _last_history_path:
            _reload_last_summary_from_history()

    # _interface may have been freed out from under us (e.g. mid-transition
    # race), so test validity explicitly instead of trusting `== null`.
    if not is_instance_valid(_interface):
        _interface = null
        _scene_ready = false
        var core_ui = scene.get_node_or_null("Core/UI")
        if core_ui:
            for child in core_ui.get_children():
                if child.get("containerGrid") != null:
                    _interface = child
                    _scene_ready = true
                    break

func _reload_last_summary_from_history():
    _last_history_path = _get_history_path()
    var history = _load_history()
    _last_summary = history[0] if history.size() > 0 else {}

# ─── Run Lifecycle ───

func _check_run_start():
    if !_scene_ready:
        return
    var scene = get_tree().current_scene
    if scene == null:
        return

    var is_map = scene.name == "Map" or "mapName" in scene
    var in_shelter = gameData.shelter if "shelter" in gameData else false

    if is_map and !in_shelter and !gameData.isDead:
        _start_run(scene)

func _start_run(scene):
    _run_state = RunState.IN_RUN
    if not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    _snap_xp_total = _get_xp_total()
    _snap_health = gameData.health
    _snap_energy = gameData.energy
    _snap_hydration = gameData.hydration
    _snap_mental = gameData.mental if "mental" in gameData else 100.0
    _snap_time_real = Time.get_ticks_msec()
    _snap_time_game = _get_sim_time()
    _snap_map = scene.mapName if "mapName" in scene else "Unknown"
    _snap_zone = gameData.zone if "zone" in gameData else ""
    _snap_inv_value = _get_inv_value()
    _snap_inv_count = _get_inv_count()

    _acc_kills = 0
    _acc_boss_kills = 0
    _last_fire_time = 0
    _last_grenade_time = 0
    _tracked_ai.clear()
    _prev_grenade1 = gameData.grenade1 if "grenade1" in gameData else false
    _prev_grenade2 = gameData.grenade2 if "grenade2" in gameData else false
    _acc_cash_earned = 0
    _acc_cash_spent = 0
    _acc_conditions = []
    _acc_damage_taken = 0.0
    _acc_last_health = gameData.health
    _acc_energy_used = 0.0
    _acc_last_energy = gameData.energy
    _acc_energy_restored = 0.0
    _acc_hydration_used = 0.0
    _acc_last_hydration = gameData.hydration
    _acc_hydration_restored = 0.0
    _acc_mental_lost = 0.0
    _acc_last_mental = gameData.mental if "mental" in gameData else 100.0
    _acc_mental_restored = 0.0
    _acc_items_picked = 0
    _acc_last_inv_count = _snap_inv_count
    _inv_snapshot_ready = _snap_inv_count > 0

    _was_dead = false
    _was_shelter = false

    print("[RunSummary] Run started on %s" % _snap_map)

func _track_run():
    # ─── Track fire/grenade timing (used by both detection methods) ───
    if Input.is_action_pressed("fire") or gameData.isFiring:
        _last_fire_time = Time.get_ticks_msec()

    var g1 = gameData.grenade1 if "grenade1" in gameData else false
    var g2 = gameData.grenade2 if "grenade2" in gameData else false
    if (_prev_grenade1 and !g1) or (_prev_grenade2 and !g2):
        _last_grenade_time = Time.get_ticks_msec()
    _prev_grenade1 = g1
    _prev_grenade2 = g2

    # ─── Kill detection: poll tracked AI nodes for death ───
    var still_alive: Array = []
    for ai in _tracked_ai:
        if !is_instance_valid(ai):
            continue
        if ai.dead:
            if _is_player_attacking():
                if "boss" in ai and ai.boss:
                    _acc_boss_kills += 1
                _acc_kills += 1
        else:
            still_alive.append(ai)
    _tracked_ai = still_alive

    # Track damage taken (accumulate decreases, ignore healing)
    var current_hp = gameData.health
    if current_hp < _acc_last_health:
        _acc_damage_taken += _acc_last_health - current_hp
    _acc_last_health = current_hp

    # Track energy (accumulate drain and restoration separately)
    var current_energy = gameData.energy
    if current_energy < _acc_last_energy:
        _acc_energy_used += _acc_last_energy - current_energy
    elif current_energy > _acc_last_energy:
        _acc_energy_restored += current_energy - _acc_last_energy
    _acc_last_energy = current_energy

    # Track hydration (accumulate drain and restoration separately)
    var current_hydration = gameData.hydration
    if current_hydration < _acc_last_hydration:
        _acc_hydration_used += _acc_last_hydration - current_hydration
    elif current_hydration > _acc_last_hydration:
        _acc_hydration_restored += current_hydration - _acc_last_hydration
    _acc_last_hydration = current_hydration

    # Track mental (accumulate loss and recovery separately)
    if "mental" in gameData:
        var current_mental = gameData.mental
        if current_mental < _acc_last_mental:
            _acc_mental_lost += _acc_last_mental - current_mental
        elif current_mental > _acc_last_mental:
            _acc_mental_restored += current_mental - _acc_last_mental
        _acc_last_mental = current_mental

    # Track conditions
    for key in CONDITIONS:
        if key in gameData and gameData.get(key) and key not in _acc_conditions:
            _acc_conditions.append(key)

    # Track items picked up (count actual Item nodes, not all grid children)
    # Rate-limited — iterating every inventory child every frame was a steady
    # per-frame cost with no gameplay benefit; 4Hz catches every pickup.
    var now_ms = Time.get_ticks_msec()
    if now_ms - _last_inv_poll_ms >= INV_POLL_INTERVAL_MS:
        _last_inv_poll_ms = now_ms
        var inv_count = _get_inv_count()
        if !_inv_snapshot_ready and inv_count > 0:
            _snap_inv_count = inv_count
            _acc_last_inv_count = inv_count
            _snap_inv_value = _get_inv_value()
            _inv_snapshot_ready = true
        elif _inv_snapshot_ready and inv_count > _acc_last_inv_count:
            _acc_items_picked += inv_count - _acc_last_inv_count
        if inv_count > 0:
            _acc_last_inv_count = inv_count

func _check_run_end():
    # Death
    if gameData.isDead and !_was_dead:
        _was_dead = true
        _end_run(true)
        return

    # Returned to shelter
    var in_shelter = gameData.shelter if "shelter" in gameData else false
    if in_shelter and !_was_shelter:
        _was_shelter = true
        _end_run(false)
        return

func _end_run(died: bool):
    _run_state = RunState.RUN_ENDED
    if get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.disconnect(_on_node_added)
    _tracked_ai.clear()

    var elapsed_ms = Time.get_ticks_msec() - _snap_time_real
    var xp_delta = _get_xp_total() - _snap_xp_total

    var summary = {
        "outcome": "DEATH" if died else "EXTRACTED",
        "map": _snap_map,
        "zone": _snap_zone,
        "duration_sec": int(elapsed_ms / 1000),
        "xp_gained": xp_delta,
        "kills": _acc_kills,
        "boss_kills": _acc_boss_kills,
        "damage_taken": int(_acc_damage_taken),
        "items_picked": _acc_items_picked,
        "value_gained": int(_get_inv_value() - _snap_inv_value) if !died else 0,
        "energy_used": int(round(_acc_energy_used)),
        "energy_restored": int(round(_acc_energy_restored)),
        "hydration_used": int(round(_acc_hydration_used)),
        "hydration_restored": int(round(_acc_hydration_restored)),
        "mental_lost": int(round(_acc_mental_lost)),
        "mental_restored": int(round(_acc_mental_restored)),
        "conditions": _acc_conditions.duplicate(),
        "cash_earned": _acc_cash_earned,
        "cash_spent": _acc_cash_spent,
        "timestamp": Time.get_datetime_string_from_system(),
    }

    _last_summary = summary
    _save_to_history(summary)

    print("[RunSummary] Run ended — %s on %s (%ds)" % [summary.outcome, summary.map, summary.duration_sec])

    if cfg_auto_show:
        # Delay to let death screen / shelter load finish
        get_tree().create_timer(1.5).timeout.connect(_show_summary_modal)

# ─── Helpers ───

func _is_player_attacking() -> bool:
    if Input.is_action_pressed("fire"):
        return true
    if gameData.isFiring:
        return true
    var now = Time.get_ticks_msec()
    if _last_fire_time > 0 and (now - _last_fire_time) <= FIRE_WINDOW_MS:
        return true
    if _last_grenade_time > 0 and (now - _last_grenade_time) <= GRENADE_WINDOW_MS:
        return true
    return false

func _get_xp_total() -> int:
    var cfg = ConfigFile.new()
    if cfg.load(_get_xp_data_path()) == OK:
        return cfg.get_value("xp", "xpTotal", 0)
    return 0

# ─── Patty's Profiles compat ─────────────────────────────────
# .cfg files aren't swapped by Patty (only .tres are tracked), so we key our
# own cfg files by the active profile to keep per-profile state isolated.
# Returns "" if Patty isn't installed, in which case we use the legacy paths.

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
        return XP_PATH_LEGACY
    return "user://XPData_" + profile + ".cfg"

func _get_history_path() -> String:
    var profile = _get_active_profile()
    if profile.is_empty():
        return HISTORY_PATH_LEGACY
    return "user://RunSummaryHistory_" + profile + ".cfg"

func _get_inv_value() -> float:
    if is_instance_valid(_interface) and "currentInventoryValue" in _interface:
        return _interface.currentInventoryValue
    return 0.0

func _get_inv_count() -> int:
    if not is_instance_valid(_interface):
        return 0
    var inv_grid = _interface.get("inventoryGrid")
    if not is_instance_valid(inv_grid):
        return 0
    var count = 0
    for child in inv_grid.get_children():
        if child.get("slotData") != null:
            count += 1
    return count

func _get_sim_time() -> float:
    var sim = get_node_or_null("/root/Simulation")
    if sim and "time" in sim:
        return sim.time
    return 0.0

# ─── Input ───

func _input(event):
    if _modal_visible:
        # Esc or hotkey (by keycode) closes modal
        if event is InputEventKey and event.pressed and not event.echo:
            if event.keycode == KEY_ESCAPE or event.keycode == cfg_reopen_key:
                _close_modal()
                get_viewport().set_input_as_handled()
                return
        # Block mouse motion and keyboard from reaching the game
        # Do NOT block mouse buttons — they must reach our CanvasLayer GUI
        if event is InputEventMouseMotion or event is InputEventKey:
            get_viewport().set_input_as_handled()
        return

    # Hotkey to reopen last summary (only when modal is closed)
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == cfg_reopen_key and _last_summary.size() > 0:
            _show_summary_modal()
            get_viewport().set_input_as_handled()

func _unhandled_input(event):
    # Catch any mouse clicks that passed through GUI (clicked overlay, not a button)
    if _modal_visible and event is InputEventMouseButton:
        get_viewport().set_input_as_handled()

# ─── Summary Modal UI ───

func _show_summary_modal():
    if _modal_visible:
        return
    if _last_summary.size() == 0:
        return

    _modal_visible = true
    _history_visible = false
    _prev_mouse_mode = Input.mouse_mode
    _prev_freeze = gameData.freeze if "freeze" in gameData else false

    # Match the game's own UI pattern (UIManager.UIOpen)
    Input.mouse_mode = Input.MOUSE_MODE_CONFINED
    if "freeze" in gameData:
        gameData.freeze = true

    # CanvasLayer on a high layer ensures our UI gets GUI events above everything
    _canvas_layer = CanvasLayer.new()
    _canvas_layer.name = "RunSummaryLayer"
    _canvas_layer.layer = 100
    _canvas_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    get_tree().root.add_child(_canvas_layer)

    _build_modal(_last_summary)

func _build_modal(summary: Dictionary):
    _cleanup_modal()

    _overlay = _modal_scene.instantiate()
    _canvas_layer.add_child(_overlay)

    # Header slots. Title is Title Case with no color override so the theme
    # color from MJRamon's template shows through — outcome is still
    # communicated via the death/extracted word at the front.
    var is_death = summary.get("outcome", "") == "DEATH"
    var title: Label = _overlay.get_node("%Title")
    title.text = "Death Summary" if is_death else "Run Summary"
    _overlay.get_node("%SubtitleMap").text = summary.get("map", "Unknown")
    _overlay.get_node("%SubtitleDuration").text = _format_duration(summary.get("duration_sec", 0))
    _overlay.get_node("%Timestamp").text = summary.get("timestamp", "")

    # Stats — drop the scene's placeholder rows, then instance templates per
    # real section. Keeping a template-per-row instead of building bespoke
    # Labels means the styled bullet/guideline/value layout from the .tscn
    # applies automatically.
    var stats: Node = _overlay.get_node("%StatsContainer")
    for child in stats.get_children():
        child.queue_free()

    # Combat
    var combat: Array = [["Enemies Killed", str(summary.get("kills", 0))]]
    var boss_kills = summary.get("boss_kills", 0)
    if boss_kills > 0:
        combat.append(["Bosses Killed", str(boss_kills)])
    combat.append(["Damage Taken", str(summary.get("damage_taken", 0))])
    _add_stats_section(stats, "Combat", combat)

    # Loot
    var val = summary.get("value_gained", 0)
    var val_str = ("+€" if val >= 0 else "-€") + str(abs(val))
    _add_stats_section(stats, "Loot", [
        ["Items Picked Up", str(summary.get("items_picked", 0))],
        ["Value Gained", val_str],
    ])

    # Economy (conditional)
    var cash_e = summary.get("cash_earned", 0)
    var cash_s = summary.get("cash_spent", 0)
    var economy: Array = []
    if cash_e > 0:
        economy.append(["Cash Earned", "+€" + str(cash_e)])
    if cash_s > 0:
        economy.append(["Cash Spent", "-€" + str(cash_s)])
    _add_stats_section(stats, "Economy", economy)

    # Survival
    var survival: Array = []
    var energy_drain = summary.get("energy_used", 0)
    var energy_gain = summary.get("energy_restored", 0)
    survival.append(["Energy Drain", "-%s%%" % str(energy_drain)])
    if energy_gain > 0:
        survival.append(["Energy Restored", "+%s%%" % str(energy_gain)])
    var hydro_drain = summary.get("hydration_used", 0)
    var hydro_gain = summary.get("hydration_restored", 0)
    survival.append(["Hydration Drain", "-%s%%" % str(hydro_drain)])
    if hydro_gain > 0:
        survival.append(["Hydration Restored", "+%s%%" % str(hydro_gain)])
    var mental_lost = summary.get("mental_lost", 0)
    var mental_gain = summary.get("mental_restored", 0)
    if mental_lost > 0:
        survival.append(["Mental Lost", "-%s%%" % str(mental_lost)])
    if mental_gain > 0:
        survival.append(["Mental Restored", "+%s%%" % str(mental_gain)])
    var conds = summary.get("conditions", [])
    if conds.size() > 0:
        var cond_names: Array = []
        for c in conds:
            cond_names.append(CONDITIONS.get(c, c))
        survival.append(["Conditions", ", ".join(cond_names)])
    _add_stats_section(stats, "Survival", survival)

    # Progression (conditional)
    var xp = summary.get("xp_gained", 0)
    if xp > 0:
        _add_stats_section(stats, "Progression", [["XP Gained", "+" + str(xp)]])

    # Wire buttons
    _overlay.get_node("%HistoryButton").pressed.connect(_toggle_history)
    _overlay.get_node("%CloseButton").pressed.connect(_close_modal)

func _add_stats_section(parent: Node, title: String, rows: Array):
    # Skip empty sections entirely so the modal stays tight.
    if rows.is_empty():
        return
    var header = _stats_header_scene.instantiate()
    parent.add_child(header)
    header.get_node("%Title").text = title
    for row in rows:
        var row_inst = _stats_row_scene.instantiate()
        parent.add_child(row_inst)
        row_inst.get_node("%Title").text = row[0]
        row_inst.get_node("%Value").text = row[1]

func _cleanup_modal():
    if _overlay and is_instance_valid(_overlay):
        _overlay.queue_free()
        _overlay = null

func _close_modal():
    _modal_visible = false
    _history_visible = false
    _cleanup_modal()
    # Also free the canvas layer
    if _canvas_layer and is_instance_valid(_canvas_layer):
        _canvas_layer.queue_free()
        _canvas_layer = null
    Input.mouse_mode = _prev_mouse_mode
    # Restore the freeze state the game had before our modal took over — forcing
    # false here was breaking the shelter UI (it runs with freeze=true), leaving
    # the camera half-locked until the player pressed Esc again to resolve.
    if "freeze" in gameData:
        gameData.freeze = _prev_freeze
    # Allow starting a new run
    if _run_state == RunState.RUN_ENDED:
        _run_state = RunState.IDLE

# ─── History View ───

func _toggle_history():
    if _history_visible:
        # Go back to current summary
        _history_visible = false
        _build_modal(_last_summary)
    else:
        _history_visible = true
        _build_history_view()

func _build_history_view():
    _cleanup_modal()

    _overlay = _history_scene.instantiate()
    _canvas_layer.add_child(_overlay)

    var container: Node = _overlay.get_node("%HistoryContainer")
    var empty_notice: Node = _overlay.get_node("%EmptyNotice")

    # Drop the scene's placeholder entries but keep the EmptyNotice node so we
    # can toggle its visibility instead of recreating it.
    for child in container.get_children():
        if child != empty_notice:
            child.queue_free()

    var history = _load_history()
    empty_notice.visible = history.is_empty()
    for run in history:
        _add_history_entry(container, run)

    _overlay.get_node("%BackButton").pressed.connect(_toggle_history)
    _overlay.get_node("%CloseButton").pressed.connect(_close_modal)

func _add_history_entry(container: Node, run: Dictionary):
    var entry = _history_entry_scene.instantiate()
    container.add_child(entry)

    var is_death = run.get("outcome", "") == "DEATH"
    entry.get_node("%HeaderSuccess").visible = not is_death
    entry.get_node("%HeaderFailure").visible = is_death

    entry.get_node("%Map").text = run.get("map", "?")
    entry.get_node("%Duration").text = _format_duration(run.get("duration_sec", 0))
    entry.get_node("%Timestamp").text = run.get("timestamp", "")

    # The entry ships with placeholder StatPart instances — clear them and
    # add a fresh one per real stat so the flow container sizes correctly.
    var parts: Node = entry.get_node("%PartsContainer")
    for child in parts.get_children():
        child.queue_free()

    var part_texts: Array = []
    var kills = run.get("kills", 0)
    if kills > 0:
        part_texts.append("%d kill%s" % [kills, "s" if kills != 1 else ""])
    var items = run.get("items_picked", 0)
    if items > 0:
        part_texts.append("%d item%s" % [items, "s" if items != 1 else ""])
    var xp = run.get("xp_gained", 0)
    if xp > 0:
        part_texts.append("+%d XP" % xp)
    var cash = run.get("cash_earned", 0)
    if cash > 0:
        part_texts.append("+€%d" % cash)
    var val = run.get("value_gained", 0)
    if val > 0:
        part_texts.append("€%d loot" % val)

    for text in part_texts:
        var part = _history_stat_part_scene.instantiate()
        parts.add_child(part)
        part.get_node("%Summary").text = text

func _format_duration(seconds: int) -> String:
    var mins = seconds / 60
    var secs = seconds % 60
    if mins >= 60:
        var hrs = mins / 60
        mins = mins % 60
        return "%dh %02dm" % [hrs, mins]
    return "%dm %02ds" % [mins, secs]

# ─── Persistence (Run History) ───

func _save_to_history(summary: Dictionary):
    var history = _load_history()
    history.insert(0, summary)
    if history.size() > 10:
        history.resize(10)

    var cfg = ConfigFile.new()
    cfg.set_value("meta", "count", history.size())
    for i in range(history.size()):
        var section = "run_%d" % i
        var run = history[i]
        for key in run:
            var val = run[key]
            if val is Array:
                cfg.set_value(section, key, ",".join(val))
            else:
                cfg.set_value(section, key, val)
    cfg.save(_get_history_path())

func _load_history() -> Array:
    var path = _get_history_path()
    # First-time Patty migration: if no per-profile history yet but the
    # legacy file exists, pull it forward so existing progress carries over.
    # Delete the legacy file afterwards so other profiles don't inherit it.
    if path != HISTORY_PATH_LEGACY and !FileAccess.file_exists(path) and FileAccess.file_exists(HISTORY_PATH_LEGACY):
        var bytes_in = FileAccess.open(HISTORY_PATH_LEGACY, FileAccess.READ)
        if bytes_in:
            var data = bytes_in.get_buffer(bytes_in.get_length())
            bytes_in.close()
            var bytes_out = FileAccess.open(path, FileAccess.WRITE)
            if bytes_out:
                bytes_out.store_buffer(data)
                bytes_out.close()
                DirAccess.remove_absolute(ProjectSettings.globalize_path(HISTORY_PATH_LEGACY))
    var cfg = ConfigFile.new()
    if cfg.load(path) != OK:
        return []
    var count = cfg.get_value("meta", "count", 0)
    var history = []
    for i in range(count):
        var section = "run_%d" % i
        if !cfg.has_section(section):
            continue
        var run = {}
        for key in cfg.get_section_keys(section):
            var val = cfg.get_value(section, key, "")
            if key == "conditions":
                run[key] = val.split(",") if val != "" else []
            else:
                run[key] = val
        history.append(run)
    return history

# ─── Hotkey ───

func _register_hotkey(key_code: int):
    if not InputMap.has_action(REOPEN_ACTION):
        InputMap.add_action(REOPEN_ACTION)
    else:
        InputMap.action_erase_events(REOPEN_ACTION)
    var ev = InputEventKey.new()
    ev.keycode = key_code
    InputMap.action_add_event(REOPEN_ACTION, ev)

# ─── MCM Integration ───

func _try_load_mcm():
    if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
        return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
    return null

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
    var entry = config.get_value(section, key, null)
    if entry == null or not entry is Dictionary:
        return fallback
    return entry.get("value", fallback)

func _register_mcm():
    var config = ConfigFile.new()

    config.set_value("Bool", "cfg_auto_show", {
        "name" = "Auto-show after run",
        "tooltip" = "Automatically show the run summary modal after death or extraction",
        "default" = true, "value" = true,
        "menu_pos" = 1
    })

    config.set_value("Keycode", "cfg_reopen_key", {
        "name" = "Reopen Summary Hotkey",
        "tooltip" = "Press to reopen the last run summary",
        "default" = KEY_F6, "default_type" = "Key",
        "value" = KEY_F6, "type" = "Key",
        "menu_pos" = 2
    })

    if !FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
        DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
        config.save(MCM_FILE_PATH + "/config.ini")
    else:
        _mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, config, MCM_FILE_PATH + "/config.ini")
        config.load(MCM_FILE_PATH + "/config.ini")

    _apply_config(config)

    _mcm_helpers.RegisterConfiguration(
        MCM_MOD_ID,
        "Run Summary",
        MCM_FILE_PATH,
        "Post-run summary modal showing combat, loot, survival, and economy stats",
        {"config.ini" = _on_mcm_save}
    )

func _on_mcm_save(config: ConfigFile):
    _apply_config(config)

func _apply_config(config: ConfigFile):
    cfg_auto_show = _mcm_val(config, "Bool", "cfg_auto_show", true)
    var new_key = _mcm_val(config, "Keycode", "cfg_reopen_key", KEY_F6)
    if new_key != cfg_reopen_key:
        cfg_reopen_key = new_key
        _register_hotkey(cfg_reopen_key)

func _load_local_config():
    var cfg = ConfigFile.new()
    if cfg.load(LOCAL_CFG_PATH) == OK:
        cfg_auto_show = cfg.get_value("config", "auto_show", true)
        cfg_reopen_key = cfg.get_value("config", "reopen_key", KEY_F6)
    _save_local_config()

func _save_local_config():
    var cfg = ConfigFile.new()
    cfg.set_value("config", "auto_show", cfg_auto_show)
    cfg.set_value("config", "reopen_key", cfg_reopen_key)
    cfg.save(LOCAL_CFG_PATH)
