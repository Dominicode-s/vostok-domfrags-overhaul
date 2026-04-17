extends Node

# ── Signals ──────────────────────────────────────────────────────────────────
signal item_secured(slot_data)
signal item_removed(slot_data)
signal container_restored(items: Array)
signal pouch_equipped(tier: String)
signal pouch_unequipped()

# ── Tier definitions ──────────────────────────────────────────────────────────
const TIERS: Dictionary = {
	"SecurePouch_S": {
		"name": "Field Pouch",
		"slots": 2,
		"cols": 2,
		"weight": 0.3,
		"value": 150,
		"rarity": 0,   # Common
		"civilian": true, "industrial": false, "military": false,
		"icon": "sachel.png",
		"obj":  "field_pouch.obj",
		"texture": "field_pouch_tex.png",   # original GLTF texture
		"size":  Vector3(0.13, 0.18, 0.13),
	},
	"SecurePouch_M": {
		"name": "Secure Pouch",
		"slots": 4,
		"cols": 2,
		"weight": 0.5,
		"value": 400,
		"rarity": 1,   # Rare
		"civilian": false, "industrial": true, "military": false,
		"icon": "black.png",
		"obj":  "secure_pouch.obj",
		"texture": "secure_pouch_tex.png",  # darkened fabric texture
		"size":  Vector3(0.17, 0.20, 0.13),
	},
	"SecurePouch_L": {
		"name": "Secure Case",
		"slots": 6,
		"cols": 3,
		"weight": 0.8,
		"value": 800,
		"rarity": 2,   # Legendary
		"civilian": false, "industrial": false, "military": true,
		"icon": "secure.png",
		"obj":  "secure_case.obj",
		"texture": "secure_case_tex.jpg",
		"mesh_rot": Vector3(0, 90, 0),   # correct for Blender export rotation
		"size":  Vector3(0.13, 0.12, 0.25),
	},
}

const SAVE_FILE: String = "user://SecureContainer.json"
const SESSION_FILE: String = "user://SecureContainer_session.json"

# ── State ─────────────────────────────────────────────────────────────────────
var gameData = preload("res://Resources/GameData.tres")

var _item_data: Dictionary = {}          # file_id -> ItemData
var _pickup_scenes: Dictionary = {}      # file_id -> PackedScene

var _interface: Node = null
var _was_dead: bool = false
var _last_scene: String = ""

# UI nodes (injected at runtime)
var _pouch_slot: Control = null          # The injected equipment slot panel
var _secure_panel: Control = null        # The secure contents panel
var _slot_grid: Control = null           # GridContainer inside _secure_panel
var _slot_injected: bool = false
var _panel_injected: bool = false
var _panel_open: bool = false     # player must double-click the pouch to open
var _in_transition: bool = false  # true after scene change until pouch confirmed back in slot
# Grace period — level transitions briefly null the pouch item before the new
# scene's inventory rebuilds. Without this buffer the unequip-drop path would
# fire and wipe stored items (reports of 5000€ cash vanishing on transition).
const EMPTY_SLOT_GRACE_FRAMES: int = 45
var _empty_slot_frames: int = 0

# Panel drag/position state
var _panel_position: Vector2 = Vector2.ZERO
var _has_custom_position: bool = false
var _panel_dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

# Runtime container state
var _equipped_file: String = ""          # Which tier is equipped ("" = none)
var _contents: Array = []               # Array of SlotData or null per slot
var _pending_equip_tier: String = ""    # Tier to re-equip after respawn

# Cash System bridge — while trading, pouch cash is moved into inventory so
# CashMain's CountCash/RemoveCash pick it up for purchases. Reclaimed at trade
# close, with any profit stacking onto the pouch slots first.
var _was_trading: bool = false
var _trade_bridge_amount: int = 0
var _bridged_cash_slots: Array[int] = []   # pouch indices that held cash

# ── Config Helper ────────────────────────────────────────────────────────────

func _cfg() -> Node:
	return Engine.get_meta("SecureContainerConfig", null)

func _slot_count(tier_file: String) -> int:
	var cfg: Node = _cfg()
	if cfg:
		match tier_file:
			"SecurePouch_S": return cfg.slots_small
			"SecurePouch_M": return cfg.slots_medium
			"SecurePouch_L": return cfg.slots_large
	return TIERS[tier_file].slots

func _cols_for(slot_count: int) -> int:
	return 3 if slot_count > 4 else 2

# Called by Config.gd when the player saves MCM changes
func _on_config_changed() -> void:
	# Rebuild panel if open so slot count / layout updates immediately
	if _panel_injected and _equipped_file != "":
		var iface: Node = _get_interface()
		_cleanup_panel()
		if iface:
			_inject_secure_panel(iface, _equipped_file)

# ── Initialization ────────────────────────────────────────────────────────────

func _ready() -> void:
	Engine.set_meta("SecureContainer", self)
	_create_item_data()
	_init_pickups()
	_inject_into_loot_pool()
	_register_with_database()
	_check_restore()
	overrideScript("res://mods/SecureContainer/Interface.gd")

func _create_item_data() -> void:
	for file_id: String in TIERS:
		var t: Dictionary = TIERS[file_id]

		var icon: ImageTexture = _load_mod_image(t.icon)
		var icon_res_path: String = "user://SC_Icon_%s.tres" % file_id

		if icon:
			ResourceSaver.save(icon, icon_res_path)
			ResourceLoader.load(icon_res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		else:
			icon = _make_placeholder_icon(file_id)

		var tetris_path: String = "user://SC_Tetris_%s.tscn" % file_id
		var tetris_text: String = _build_tetris_tscn(file_id, icon_res_path if icon else "")
		var f: FileAccess = FileAccess.open(tetris_path, FileAccess.WRITE)
		if f:
			f.store_string(tetris_text)
			f.close()
		var tetris: PackedScene = ResourceLoader.load(tetris_path, "", ResourceLoader.CACHE_MODE_REPLACE)

		var item: ItemData = ItemData.new()
		item.file = file_id
		item.name = t.name
		item.inventory = t.name
		item.rotated = t.name
		item.equipment = t.name
		item.display = t.name
		item.type = "Equipment"
		item.weight = t.weight
		item.value = t.value
		item.size = Vector2(1, 1)
		item.stackable = false
		item.showAmount = false
		item.slots = ["Pouch"]
		item.icon = icon
		item.tetris = tetris
		match t.rarity:
			0: item.rarity = item.Rarity.Common
			1: item.rarity = item.Rarity.Rare
			2: item.rarity = item.Rarity.Legendary
		item.civilian  = t.civilian
		item.industrial = t.industrial
		item.military  = t.military

		var item_path: String = "user://SC_Item_%s.tres" % file_id
		ResourceSaver.save(item, item_path)
		# Reload from disk so resource_path is set — without this, Character.tres
		# saves a broken reference and logs "File not found: {item.name}" on load.
		var loaded: ItemData = ResourceLoader.load(item_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		_item_data[file_id] = loaded if loaded else item
		print("[SecureContainer] Created item: %s" % t.name)

func _init_pickups() -> void:
	for file_id: String in TIERS:
		var t: Dictionary = TIERS[file_id]
		var mesh_path: String = "user://SC_Mesh_%s.res" % file_id
		var mat_path: String = ""
		var pickup_path: String = "user://SC_Pickup_%s.tscn" % file_id
		var has_custom_mesh: bool = false

		var obj_path: String = _mod_file_path(t.obj)
		if obj_path != "":
			var mesh: ArrayMesh = _parse_obj(obj_path)
			if mesh:
				# Bake material into the mesh surface so no external .tres is needed
				var mat: StandardMaterial3D = StandardMaterial3D.new()
				mat.roughness = 0.9
				if t.has("texture"):
					var img_tex: ImageTexture = _load_mod_image(t.texture)
					if img_tex:
						mat.albedo_texture = img_tex
				elif t.has("color"):
					mat.albedo_color = t.color
				for i: int in mesh.get_surface_count():
					mesh.surface_set_material(i, mat)
				ResourceSaver.save(mesh, mesh_path)
				ResourceLoader.load(mesh_path, "", ResourceLoader.CACHE_MODE_REPLACE)
				has_custom_mesh = true

		var tscn_text: String = _build_pickup_tscn(file_id, mesh_path, has_custom_mesh)
		var f: FileAccess = FileAccess.open(pickup_path, FileAccess.WRITE)
		if f:
			f.store_string(tscn_text)
			f.close()
		var scene: PackedScene = ResourceLoader.load(pickup_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if scene:
			_pickup_scenes[file_id] = scene

func _inject_into_loot_pool() -> void:
	var loot_cfg: Node = _cfg()
	if loot_cfg and not loot_cfg.spawn_in_loot:
		print("[SecureContainer] Loot spawning disabled via config")
		return
	var lt: Resource = load("res://Loot/LT_Master.tres")
	if not lt:
		print("[SecureContainer] Could not load LT_Master — pouches won't spawn in loot")
		return
	for file_id: String in _item_data:
		var item: ItemData = _item_data[file_id]
		var already: bool = false
		for existing in lt.items:
			if existing and existing.file == file_id:
				already = true
				break
		if not already:
			lt.items.append(item)
	print("[SecureContainer] Pouches added to loot pool")

func _register_with_database() -> void:
	print("[SecureContainer] _register_with_database() called")

	# Dump all /root children so we can see every autoload name
	var root: Node = get_tree().root
	var root_children: Array = []
	for child in root.get_children():
		root_children.append(child.name)
	print("[SecureContainer] /root children: ", root_children)

	# Try to find the Database autoload
	var db: Node = get_node_or_null("/root/Database")
	print("[SecureContainer] /root/Database = ", db)
	if not db:
		print("[SecureContainer] ERROR: Database autoload not found — spawner integration skipped")
		return

	print("[SecureContainer] Database properties: ", db.get_property_list().map(func(p): return p.name))

	if not "master" in db:
		print("[SecureContainer] ERROR: Database has no 'master' property")
		return
	if not db.master:
		print("[SecureContainer] ERROR: Database.master is null")
		return

	print("[SecureContainer] Database.master = ", db.master)
	print("[SecureContainer] Database.master type = ", db.master.get_class())

	if not "items" in db.master:
		print("[SecureContainer] ERROR: Database.master has no 'items' property")
		print("[SecureContainer] Database.master properties: ", db.master.get_property_list().map(func(p): return p.name))
		return

	print("[SecureContainer] Database.master.items count BEFORE: ", db.master.items.size())

	for file_id: String in _item_data:
		var item: ItemData = _item_data[file_id]
		var already: bool = false
		for existing in db.master.items:
			if existing and existing.file == file_id:
				already = true
				break
		if not already:
			db.master.items.append(item)
			print("[SecureContainer] Added to Database: ", item.name)
		else:
			print("[SecureContainer] Already in Database: ", item.name)

	print("[SecureContainer] Database.master.items count AFTER: ", db.master.items.size())

	# If Item Spawner is already loaded, tell it to refresh
	var spawner: Node = get_node_or_null("/root/ItemSpawner")
	print("[SecureContainer] ItemSpawner node = ", spawner)
	if spawner and spawner.has_method("forceRefresh"):
		spawner.forceRefresh()
		print("[SecureContainer] Called forceRefresh() on ItemSpawner")

	print("[SecureContainer] _register_with_database() done")

# ── Process ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Death detection — save contents before the game wipes inventory
	if gameData.isDead:
		if not _was_dead:
			# If we died mid-trade, the bridged cash is sitting in the
			# inventory that's about to be wiped. Restore the cash slots in
			# _contents before the death save so the pouch recovers it on
			# respawn via _try_restore.
			if _trade_bridge_amount > 0:
				_restore_bridged_cash_in_memory()
			_save_contents()
			_was_dead = true
	else:
		_was_dead = false

	# Scene change detection for post-respawn restore
	var scene: Node = get_tree().current_scene
	if scene and "mapName" in scene:
		var mn: String = str(scene.mapName)
		if mn != "" and mn != _last_scene:
			_last_scene = mn
			call_deferred("_try_restore")
	elif scene:
		_last_scene = ""

	# Scene change detection: if the pouch slot was freed (e.g. scene unloaded),
	# reset flags so it gets reinjected into the new scene's Interface.
	if _slot_injected and (not _pouch_slot or not is_instance_valid(_pouch_slot) or not _pouch_slot.is_inside_tree()):
		_slot_injected = false
		_panel_injected = false
		_secure_panel = null
		_slot_grid = null
		_interface = null  # force re-fetch from new scene
		_in_transition = true  # suppress unequip-drop until pouch confirmed in slot

	var iface: Node = _get_interface()
	if not iface:
		return

	_update_cash_bridge()

	var inv: Node = iface.get_node_or_null("Inventory")
	if inv and inv.visible:
		if not _slot_injected:
			call_deferred("_inject_pouch_slot", iface)
		_poll_equipped_state(iface)
	else:
		_cleanup_panel()

# ── Input — shift+click or drag-and-drop to secure ───────────────────────────

func _input(event: InputEvent) -> void:
	# Panel drag — capture motion + release globally so fast drags that leave
	# the header rect don't get stuck.
	if _panel_dragging:
		if event is InputEventMouseMotion:
			_update_drag_position((event as InputEventMouseMotion).global_position)
			return
		if event is InputEventMouseButton:
			var rel: InputEventMouseButton = event as InputEventMouseButton
			if rel.button_index == MOUSE_BUTTON_LEFT and not rel.pressed:
				_panel_dragging = false
				_panel_position = _secure_panel.position
				_has_custom_position = true
				_save_session()
				get_viewport().set_input_as_handled()
				return

	if not (event is InputEventMouseButton):
		return
	var mbe: InputEventMouseButton = event as InputEventMouseButton
	var iface: Node = _get_interface()
	if not iface:
		return

	# Configured button on the equipped pouch item — toggle the panel open/closed
	var cfg: Node = _cfg()
	var open_btn: int = cfg.open_button if cfg else MOUSE_BUTTON_MIDDLE
	var open_btn_type: String = cfg.open_button_type if cfg else "MouseButton"
	var is_open_press: bool = mbe.pressed and _equipped_file != "" \
		and ((open_btn_type in ["Mouse", "MouseButton"] and mbe.button_index == open_btn) \
		or   (open_btn_type == "Key" and false))  # key handled in _input via InputEventKey
	if is_open_press:
		if _pouch_slot and is_instance_valid(_pouch_slot):
			if _pouch_slot.get_global_rect().has_point(mbe.global_position):
				# Panel can't be opened while the cash bridge has pouch cash
				# in inventory — the slots are emptied pending reclaim.
				if _was_trading and _trade_bridge_amount > 0:
					get_viewport().set_input_as_handled()
					return
				_panel_open = not _panel_open
				if _panel_open:
					call_deferred("_inject_secure_panel", iface, _equipped_file)
				else:
					_cleanup_panel()
				get_viewport().set_input_as_handled()
				return

	if mbe.button_index != MOUSE_BUTTON_LEFT:
		return

	if not _panel_injected:
		return

	# Mouse RELEASE: secure a dragged item if it was released over the panel
	if not mbe.pressed:
		var dragged: Node = iface.get("itemDragged")
		if dragged and _secure_panel and is_instance_valid(_secure_panel):
			if _secure_panel.get_global_rect().has_point(mbe.global_position):
				for i: int in _contents.size():
					if _contents[i] == null:
						_secure_dragged(dragged, iface, i)
						get_viewport().set_input_as_handled()
						return
		return

	# Mouse PRESS + Shift: quick-secure the hovered inventory item
	if not mbe.shift_pressed:
		return
	var hover_item: Node = iface.get("hoverItem")
	if not hover_item:
		return
	var hover_grid: Node = iface.get("hoverGrid")
	if not hover_grid or hover_grid != iface.inventoryGrid:
		return
	for i: int in _contents.size():
		if _contents[i] == null:
			_move_to_secure(hover_item, hover_grid, i)
			get_viewport().set_input_as_handled()
			return

# ── Equipment Slot Injection ──────────────────────────────────────────────────

func _inject_pouch_slot(iface: Node) -> void:
	if _slot_injected:
		return

	var slot_script: Script = load("res://Scripts/Slot.gd")
	if not slot_script:
		push_warning("[SecureContainer] Could not load Slot.gd")
		return

	var equipment: Node = _find_equipment_panel(iface)
	if not equipment:
		push_warning("[SecureContainer] Could not find equipment panel")
		return

	_pouch_slot = Panel.new()
	_pouch_slot.name = "Pouch"
	_pouch_slot.set_script(slot_script)
	# Position next to the Player slot (last in the bottom accessory row)
	# Row runs: Matches(0) Light(64) NVG(128) Time(192) Map(256) Player(320) → Pouch(384)
	_pouch_slot.layout_mode = 0
	_pouch_slot.offset_left   = 384.0
	_pouch_slot.offset_top    = 448.0
	_pouch_slot.offset_right  = 448.0
	_pouch_slot.offset_bottom = 512.0
	_apply_slot_style(_pouch_slot, false)

	# Hint must NOT be a child of the slot — vanilla slots store hints in a
	# separate Equipment/Hints container. The equip check is:
	#   hoverSlot.get_child_count() == 0
	# so any child on an empty slot blocks equipping.
	var hint: Label = Label.new()
	hint.name = "SC_Pouch_Hint"
	hint.text = "Pouch"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.layout_mode = 0
	hint.offset_left   = 384.0
	hint.offset_top    = 448.0
	hint.offset_right  = 448.0
	hint.offset_bottom = 512.0
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	_pouch_slot.hint = hint

	# Add hint to the shared Hints container if it exists, otherwise equipment panel
	var hints_container: Node = equipment.get_node_or_null("Hints")
	if hints_container:
		hints_container.add_child(hint)
	else:
		equipment.add_child(hint)

	equipment.add_child(_pouch_slot)
	_slot_injected = true
	print("[SecureContainer] Pouch slot injected into equipment panel")

	if _pending_equip_tier != "":
		call_deferred("_reequip_after_respawn", iface)

func _reequip_after_respawn(iface: Node) -> void:
	if _pending_equip_tier == "" or _pending_equip_tier not in _item_data:
		return
	if not _pouch_slot or not is_instance_valid(_pouch_slot) or not _pouch_slot.is_inside_tree():
		return
	if _pouch_slot.get_child_count() > 0:
		_pending_equip_tier = ""
		return
	var tier: String = _pending_equip_tier
	_pending_equip_tier = ""
	var container_sd: SlotData = SlotData.new()
	container_sd.itemData = _item_data[tier]
	container_sd.amount = 1
	var new_item: Node = iface.item.instantiate()
	iface.add_child(new_item)
	new_item.Initialize(iface, container_sd)
	iface.Equip(new_item, _pouch_slot)
	print("[SecureContainer] Re-equipped %s into Pouch slot after respawn" % tier)

func _find_equipment_panel(iface: Node) -> Node:
	# Equipment is a direct child of Interface (not under Inventory)
	for path: String in ["Equipment", "Inventory/Equipment"]:
		var node: Node = iface.get_node_or_null(path)
		if node:
			return node
	return _scan_for_slots(iface)

func _scan_for_slots(node: Node) -> Node:
	for child: Node in node.get_children():
		if child is Control:
			for sub: Node in child.get_children():
				if sub.get_script() and "Slot" in sub.get_script().resource_path:
					return child
		var result: Node = _scan_for_slots(child)
		if result:
			return result
	return null

# ── Secure Panel UI ───────────────────────────────────────────────────────────

func _poll_equipped_state(iface: Node) -> void:
	if not _pouch_slot or not is_instance_valid(_pouch_slot):
		return

	var found_file: String = ""
	for child: Node in _pouch_slot.get_children():
		if "slotData" in child and child.slotData and child.slotData.itemData:
			found_file = child.slotData.itemData.file
			break

	if found_file != "":
		_in_transition = false  # Pouch confirmed in slot — scene is stable
		_empty_slot_frames = 0

	if found_file == _equipped_file:
		# Same tier — reinject panel only if player had it open
		if found_file != "" and _panel_open and not _panel_injected:
			call_deferred("_inject_secure_panel", iface, found_file)
		return

	# If the slot just became empty while the player is mid-drag, hold off —
	# don't update _equipped_file yet so we re-detect the change next frame.
	if found_file == "" and iface.get("itemDragged") != null:
		return

	# Grace period — ignore transient empty-slot readings caused by level
	# transitions or inventory reloads. Only act on a sustained empty slot.
	if found_file == "" and _equipped_file != "":
		_empty_slot_frames += 1
		if _empty_slot_frames < EMPTY_SLOT_GRACE_FRAMES:
			return

	# Tier changed — full reset
	_equipped_file = found_file
	_cleanup_panel()

	if found_file != "" and found_file in TIERS:
		var slot_count: int = _slot_count(found_file)
		if _contents.size() != slot_count:
			_contents.resize(slot_count)
		# Eagerly load session contents — covers the case where the pouch was
		# re-equipped via level transition and the player hasn't opened the
		# panel yet. Without this, _load_session is deferred until panel open
		# and any unequip path in between would drop/lose items.
		if _contents.filter(func(s: Variant) -> bool: return s != null).is_empty():
			_load_session()
		# Don't auto-open — wait for player middle-click
		emit_signal("pouch_equipped", found_file)
	else:
		if _in_transition or _pending_equip_tier != "":
			# Slot is empty after scene change or pending re-equip — preserve contents
			return
		_panel_open = false
		var drop_cfg: Node = _cfg()
		if drop_cfg and not drop_cfg.drop_on_unequip:
			_return_all_to_inventory()
		else:
			_drop_contents_to_world()
		_delete_session()
		_contents = []
		emit_signal("pouch_unequipped")

func _inject_secure_panel(iface: Node, tier_file: String) -> void:
	if _panel_injected:
		return

	var t: Dictionary = TIERS[tier_file]
	var slot_count: int = _slot_count(tier_file)
	var cols: int = _cols_for(slot_count)
	_contents.resize(slot_count)

	_secure_panel = PanelContainer.new()
	_secure_panel.name = "SC_Panel"

	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.08, 0.97)
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_color = Color(0.32, 0.32, 0.32)
	bg.content_margin_left = 8.0
	bg.content_margin_right = 8.0
	bg.content_margin_top = 6.0
	bg.content_margin_bottom = 8.0
	_secure_panel.add_theme_stylebox_override("panel", bg)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	# Draggable header — click and drag to move the panel anywhere on screen.
	var header: Panel = Panel.new()
	header.custom_minimum_size = Vector2(0, 18)
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	var header_bg: StyleBoxFlat = StyleBoxFlat.new()
	header_bg.bg_color = Color(0.14, 0.14, 0.14)
	header_bg.border_color = Color(0.32, 0.32, 0.32)
	header_bg.border_width_bottom = 1
	header.add_theme_stylebox_override("panel", header_bg)
	var header_label: Label = Label.new()
	header_label.text = "[ %s ]" % t.name.to_upper()
	header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	header_label.add_theme_font_size_override("font_size", 10)
	header_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	header_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(header_label)
	header.gui_input.connect(_on_header_gui_input)
	vbox.add_child(header)

	_slot_grid = GridContainer.new()
	_slot_grid.columns = cols
	_slot_grid.add_theme_constant_override("h_separation", 4)
	_slot_grid.add_theme_constant_override("v_separation", 4)

	for i: int in slot_count:
		_slot_grid.add_child(_build_slot_widget(i))

	vbox.add_child(_slot_grid)

	_secure_panel.add_child(vbox)

	# Parent to Interface so we're in screen-space and never overlap the grids.
	# Position just below the Pouch slot using its global rect.
	_secure_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_secure_panel.z_index = 10
	iface.add_child(_secure_panel)

	# Position below the Pouch slot — resolve after layout is ready next frame
	call_deferred("_position_secure_panel")
	call_deferred("_refresh_slots")

	_panel_injected = true
	_load_session()   # restore contents if they were cleared by a transition
	_refresh_slots()
	print("[SecureContainer] Secure panel injected (%d slots)" % t.slots)

func _position_secure_panel() -> void:
	if not _secure_panel or not is_instance_valid(_secure_panel):
		return
	var iface: Node = _get_interface()
	if not iface:
		return

	var iface_size: Vector2 = iface.get_rect().size
	var panel_size: Vector2 = _secure_panel.get_combined_minimum_size()

	var panel_pos: Vector2
	if _has_custom_position:
		panel_pos = _panel_position
	else:
		if not _pouch_slot or not is_instance_valid(_pouch_slot):
			return
		# Default: to the RIGHT of the pouch slot, top-aligned with it
		var slot_global: Rect2 = _pouch_slot.get_global_rect()
		var iface_inv: Transform2D = iface.get_global_transform().affine_inverse()
		panel_pos = iface_inv * slot_global.position
		panel_pos.x += slot_global.size.x + 8.0

	panel_pos.x = clamp(panel_pos.x, 4.0, iface_size.x - panel_size.x - 4.0)
	panel_pos.y = clamp(panel_pos.y, 4.0, iface_size.y - panel_size.y - 4.0)
	_secure_panel.position = panel_pos

func _build_slot_widget(index: int) -> Control:
	var panel: Panel = Panel.new()
	panel.name = "Slot_%d" % index
	panel.custom_minimum_size = Vector2(80, 80)
	panel.clip_contents = true
	_apply_slot_style(panel, false)

	var icon_rect: TextureRect = TextureRect.new()
	icon_rect.name = "Icon"
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon_rect)

	var amount_lbl: Label = Label.new()
	amount_lbl.name = "Amount"
	amount_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	amount_lbl.offset_right = -4.0
	amount_lbl.offset_bottom = -2.0
	amount_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	amount_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	amount_lbl.add_theme_font_size_override("font_size", 10)
	amount_lbl.add_theme_color_override("font_color", Color.WHITE)
	amount_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(amount_lbl)

	panel.gui_input.connect(_on_slot_gui_input.bind(index))
	panel.mouse_entered.connect(_on_slot_hover.bind(panel, true))
	panel.mouse_exited.connect(_on_slot_hover.bind(panel, false))

	return panel

func _on_slot_gui_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mbe: InputEventMouseButton = event as InputEventMouseButton
	if mbe.pressed and mbe.button_index == MOUSE_BUTTON_LEFT:
		if _contents[index] != null:
			_return_to_inventory(index)

func _on_header_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mbe: InputEventMouseButton = event as InputEventMouseButton
	if mbe.button_index != MOUSE_BUTTON_LEFT or not mbe.pressed:
		return
	# Motion + release are handled globally in _input so fast drags don't
	# break when the cursor leaves the header's small rect.
	_panel_dragging = true
	_drag_offset = mbe.global_position - _secure_panel.global_position
	get_viewport().set_input_as_handled()

func _update_drag_position(global_pos: Vector2) -> void:
	var iface: Node = _get_interface()
	if not iface or not _secure_panel or not is_instance_valid(_secure_panel):
		return
	var target_global: Vector2 = global_pos - _drag_offset
	var local: Vector2 = iface.get_global_transform().affine_inverse() * target_global
	var iface_size: Vector2 = iface.get_rect().size
	var panel_size: Vector2 = _secure_panel.get_rect().size
	local.x = clamp(local.x, 4.0, iface_size.x - panel_size.x - 4.0)
	local.y = clamp(local.y, 4.0, iface_size.y - panel_size.y - 4.0)
	_secure_panel.position = local

# Used by Interface.gd override to null out Hover state when cursor is over our
# panel — prevents clicks passing through to inventory items behind the panel.
func _mouse_over_panel() -> bool:
	if not _panel_injected or not _secure_panel or not is_instance_valid(_secure_panel):
		return false
	var vp: Viewport = _secure_panel.get_viewport()
	if not vp:
		return false
	return _secure_panel.get_global_rect().has_point(vp.get_mouse_position())

func _on_slot_hover(panel: Control, entered: bool) -> void:
	_apply_slot_style(panel, entered and _contents[_slot_grid.get_children().find(panel)] != null)

func _apply_slot_style(panel: Control, highlight: bool) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.20, 0.20, 0.20) if highlight else Color(0.11, 0.11, 0.11)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.55, 0.55, 0.55) if highlight else Color(0.22, 0.22, 0.22)
	panel.add_theme_stylebox_override("panel", style)

func _refresh_slots() -> void:
	if not _slot_grid or not is_instance_valid(_slot_grid):
		return
	var children: Array = _slot_grid.get_children()
	for i: int in _contents.size():
		if i >= children.size():
			break
		var slot: Control = children[i]
		var icon_rect: TextureRect = slot.get_node_or_null("Icon")
		var amount_lbl: Label = slot.get_node_or_null("Amount")
		var sd: SlotData = _contents[i]
		if sd:
			if icon_rect:
				icon_rect.texture = sd.itemData.icon
			if amount_lbl:
				amount_lbl.text = str(sd.amount) if sd.itemData.stackable and sd.amount > 1 else ""
		else:
			if icon_rect:
				icon_rect.texture = null
			if amount_lbl:
				amount_lbl.text = ""

func _cleanup_panel() -> void:
	if _secure_panel and is_instance_valid(_secure_panel):
		_secure_panel.queue_free()
	_secure_panel = null
	_slot_grid = null
	_panel_injected = false

# ── Item Transfer ─────────────────────────────────────────────────────────────

func _is_item_allowed(item_data: ItemData) -> bool:
	if item_data == null:
		return false
	var cfg: Node = _cfg()
	if cfg == null:
		return true
	if item_data.type != "Weapon":
		return true
	if not cfg.allow_weapons:
		return false
	if cfg.weapons_pistol_only and item_data.subtype != "Pistol":
		return false
	return true

func _secure_dragged(dragged: Node, iface: Node, slot_index: int) -> void:
	if not _is_item_allowed(dragged.slotData.itemData):
		print("[SecureContainer] Rejected (restricted): %s" % dragged.slotData.itemData.name)
		return
	# Item is already floating (picked from grid), just copy data, free it, reset drag
	var sd: SlotData = SlotData.new()
	sd.Update(dragged.slotData)
	dragged.queue_free()
	iface.Reset()
	_contents[slot_index] = sd
	_save_session()
	_refresh_slots()
	emit_signal("item_secured", sd)
	print("[SecureContainer] Secured via drag: %s" % sd.itemData.name)

func _move_to_secure(item: Node, grid: Node, slot_index: int) -> void:
	if _contents[slot_index] != null:
		return
	if not _is_item_allowed(item.slotData.itemData):
		print("[SecureContainer] Rejected (restricted): %s" % item.slotData.itemData.name)
		return

	# Copy slot data before removing from inventory
	var sd: SlotData = SlotData.new()
	sd.Update(item.slotData)

	# Remove from inventory grid
	var picked: Node = grid.Pick(item)
	if not picked:
		return
	picked.queue_free()

	_contents[slot_index] = sd
	_save_session()
	_refresh_slots()
	emit_signal("item_secured", sd)
	print("[SecureContainer] Secured: %s" % sd.itemData.name)

func _return_to_inventory(slot_index: int) -> void:
	var sd: SlotData = _contents[slot_index]
	if not sd:
		return

	var iface: Node = _get_interface()
	if not iface:
		return

	var placed: bool = false
	if sd.itemData.stackable:
		placed = iface.AutoStack(sd, iface.inventoryGrid)
	if not placed:
		# useDrop=false — if inventory is full, leave item in pouch rather than
		# letting AutoPlace drop it to the world (which was double-spawning it).
		placed = iface.Create(sd, iface.inventoryGrid, false)

	if placed:
		_contents[slot_index] = null
		_save_session()
		_refresh_slots()
		emit_signal("item_removed", sd)
		print("[SecureContainer] Returned: %s" % sd.itemData.name)
	else:
		print("[SecureContainer] Inventory full — can't return %s" % sd.itemData.name)

func _return_all_to_inventory() -> void:
	var iface: Node = _get_interface()
	if not iface:
		_drop_contents_to_world()  # fallback if no interface
		return
	for i: int in _contents.size():
		var sd: SlotData = _contents[i]
		if not sd:
			continue
		var placed: bool = false
		if sd.itemData.stackable:
			placed = iface.AutoStack(sd, iface.inventoryGrid)
		if not placed:
			placed = iface.Create(sd, iface.inventoryGrid, false)
		if not placed:
			# Inventory full — drop this one
			_drop_single_to_world(sd)

# ── Drop Contents to World ────────────────────────────────────────────────────

func _drop_contents_to_world() -> void:
	for sd: SlotData in _contents:
		if sd == null or not sd.itemData:
			continue
		_drop_single_to_world(sd)

func _drop_single_to_world(sd: SlotData) -> void:
	var map: Node = get_tree().current_scene.get_node_or_null("/root/Map")
	if not map:
		return

	var iface: Node = _get_interface()
	var cam: Node = iface.get("camera") if iface else null

	var base_pos: Vector3
	var base_dir: Vector3
	if cam and is_instance_valid(cam):
		base_dir = -cam.global_transform.basis.z
		base_pos = cam.global_position + Vector3(0, -0.25, 0) + base_dir * 0.6
	else:
		base_pos = Vector3(0, 1, 0)
		base_dir = Vector3(0, 0, 1)

	var db: Node = get_node_or_null("/root/Database")
	var scene: PackedScene = _pickup_scenes.get(sd.itemData.file, null)
	if not scene and db:
		scene = db.get(sd.itemData.file)
	if not scene:
		push_warning("[SecureContainer] No pickup scene for %s — skipping drop" % sd.itemData.file)
		return

	var pickup: Node = scene.instantiate()
	map.add_child(pickup)
	var spread: Vector3 = Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3))
	pickup.position = base_pos + spread
	pickup.rotation_degrees = Vector3(-25, randf_range(0, 360), 45)
	var slot: SlotData = SlotData.new()
	slot.Update(sd)
	pickup.slotData = slot
	if pickup.has_method("Unfreeze"):
		pickup.Unfreeze()
	pickup.linear_velocity = (base_dir + spread.normalized() * 0.3) * 2.0

# ── Cash System Bridge ───────────────────────────────────────────────────────
#
# Goal: pouch cash should count as spendable while trading, and sale proceeds
# should refill the pouch (so a pouch-carried wallet acts like your wallet).
#
# Approach: at trade open we move the pouch cash amount into inventory via
# CashMain.AddCash — the cash slots in _contents are nulled and their indices
# cached. CashMain then sees the total for buying. The panel is forced closed
# so empty cash slots can't be back-filled with other items mid-trade. On
# trade close we pull inventory cash back into the cached slots (up to each
# slot's maxAmount); anything left over stays in inventory as profit / change.
#
# Death safety: if the player dies mid-trade, _process sees isDead and calls
# _restore_bridged_cash_in_memory before _save_contents so the death-save
# file has the original cash slots populated again. The inventory mirror is
# wiped by the vanilla death path (same behaviour as any inventory cash).

const CASH_FILE: String = "Cash"

func _update_cash_bridge() -> void:
	var cfg: Node = _cfg()
	if cfg == null or not cfg.cash_bridge:
		if _was_trading:
			_reclaim_cash_to_pouch()
			_was_trading = false
		return
	var trading: bool = bool(gameData.isTrading) if "isTrading" in gameData else false
	if trading and not _was_trading:
		_bridge_pouch_cash_to_inventory()
		_was_trading = true
	elif not trading and _was_trading:
		_reclaim_cash_to_pouch()
		_was_trading = false

func _count_pouch_cash() -> int:
	var total: int = 0
	for sd: Variant in _contents:
		if sd and sd.itemData and sd.itemData.file == CASH_FILE:
			total += int(sd.amount)
	return total

func _bridge_pouch_cash_to_inventory() -> void:
	_trade_bridge_amount = 0
	_bridged_cash_slots.clear()
	if _equipped_file == "" or _contents.is_empty():
		return
	var cash_mod: Node = Engine.get_meta("CashMain", null)
	if cash_mod == null or not cash_mod.has_method("AddCash"):
		return
	var total: int = _count_pouch_cash()
	if total <= 0:
		return
	# Close the panel so the (now-empty) cash slots can't receive other items
	# mid-trade. Items placed there would block reclamation.
	if _panel_open:
		_panel_open = false
		_cleanup_panel()
	# Persist the pre-bridge pouch state so that a crash mid-trade recovers
	# the original pouch cash rather than the nulled bridged slots. Death
	# during trade is handled separately in _process so _save_contents runs
	# after _restore_bridged_cash_in_memory.
	_save_session()
	if not cash_mod.AddCash(total):
		return
	_trade_bridge_amount = total
	for i: int in _contents.size():
		var sd: SlotData = _contents[i]
		if sd and sd.itemData and sd.itemData.file == CASH_FILE:
			_bridged_cash_slots.append(i)
			_contents[i] = null

func _restore_bridged_cash_in_memory() -> void:
	var cash_mod: Node = Engine.get_meta("CashMain", null)
	if cash_mod == null or cash_mod.cash_item_data == null:
		return
	var cash_data: ItemData = cash_mod.cash_item_data
	var max_amt: int = int(cash_data.maxAmount) if cash_data.maxAmount > 0 else 99999
	var remaining: int = _trade_bridge_amount
	for idx: int in _bridged_cash_slots:
		if remaining <= 0:
			break
		if idx >= _contents.size() or _contents[idx] != null:
			continue
		var take: int = min(remaining, max_amt)
		var sd: SlotData = SlotData.new()
		sd.itemData = cash_data
		sd.amount = take
		_contents[idx] = sd
		remaining -= take
	_trade_bridge_amount = 0
	_bridged_cash_slots.clear()
	_was_trading = false

func _reclaim_cash_to_pouch() -> void:
	var bridged: int = _trade_bridge_amount
	var slots: Array = _bridged_cash_slots.duplicate()
	_trade_bridge_amount = 0
	_bridged_cash_slots.clear()
	if bridged <= 0:
		return
	var cash_mod: Node = Engine.get_meta("CashMain", null)
	if cash_mod == null or not cash_mod.has_method("CountCash") or cash_mod.cash_item_data == null:
		return
	var inv_cash: int = int(cash_mod.CountCash())
	if inv_cash <= 0:
		_save_session()
		_refresh_slots()
		return
	var cash_data: ItemData = cash_mod.cash_item_data
	var max_amt: int = int(cash_data.maxAmount) if cash_data.maxAmount > 0 else 99999
	# Only reclaim into the pouch slots we originally emptied; if a slot got
	# occupied somehow, fall back to inventory for that share.
	var free_slots: Array[int] = []
	for idx: int in slots:
		if idx < _contents.size() and _contents[idx] == null:
			free_slots.append(idx)
	var pouch_capacity: int = max_amt * free_slots.size()
	var to_pouch: int = min(inv_cash, pouch_capacity)
	if to_pouch > 0:
		if not cash_mod.RemoveCash(to_pouch):
			to_pouch = int(cash_mod.CountCash())
			if to_pouch > 0 and not cash_mod.RemoveCash(to_pouch):
				return
	var remaining: int = to_pouch
	for idx: int in free_slots:
		if remaining <= 0:
			break
		var take: int = min(remaining, max_amt)
		var sd: SlotData = SlotData.new()
		sd.itemData = cash_data
		sd.amount = take
		_contents[idx] = sd
		remaining -= take
	if remaining > 0:
		cash_mod.AddCash(remaining)
	_save_session()
	_refresh_slots()

# ── Session Persistence (survives scene changes and main menu) ────────────────

# Serialize a SlotData to a JSON-safe dict. Preserves attachments (nested),
# magazine/container contents (storage), and all firearm state — without this
# guns lose their scope/grip/magazine when secured then re-loaded.
func _serialize_slot_data(sd: SlotData) -> Variant:
	if sd == null or sd.itemData == null:
		return null
	var data: Dictionary = {
		"file":      sd.itemData.file,
		"res_path":  sd.itemData.resource_path,
		"amount":    sd.amount,
		"condition": sd.condition,
		"position":  sd.position,
		"mode":      sd.mode,
		"zoom":      sd.zoom,
		"chamber":   sd.chamber,
		"casing":    sd.casing,
		"state":     sd.state,
		"nested":    [],
		"storage":   [],
	}
	for att: ItemData in sd.nested:
		if att == null:
			continue
		data.nested.append({"file": att.file, "res_path": att.resource_path})
	for sub: SlotData in sd.storage:
		data.storage.append(_serialize_slot_data(sub))
	return data

func _deserialize_slot_data(entry: Variant) -> SlotData:
	if entry == null or not (entry is Dictionary):
		return null
	var item_res: ItemData = _resolve_item_entry(entry)
	if not item_res:
		push_warning("[SecureContainer] Could not restore item: %s" % entry.get("file", "?"))
		return null
	var sd: SlotData = SlotData.new()
	sd.itemData = item_res
	# JSON.parse_string returns all numbers as floats, so `str(amount)` showed
	# "30.0" on restored stackables. Coerce back to int for every numeric field.
	sd.amount    = int(entry.get("amount", 1))
	sd.condition = int(entry.get("condition", 100))
	sd.position  = int(entry.get("position", 0))
	sd.mode      = int(entry.get("mode", 1))
	sd.zoom      = int(entry.get("zoom", 1))
	sd.chamber   = entry.get("chamber", false)
	sd.casing    = entry.get("casing", false)
	sd.state     = entry.get("state", "")
	for n_entry: Variant in entry.get("nested", []):
		if n_entry == null or not (n_entry is Dictionary):
			continue
		var n_item: ItemData = _resolve_item_entry(n_entry)
		if n_item:
			sd.nested.append(n_item)
	for s_entry: Variant in entry.get("storage", []):
		var sub: SlotData = _deserialize_slot_data(s_entry)
		if sub:
			sd.storage.append(sub)
	return sd

func _resolve_item_entry(entry: Dictionary) -> ItemData:
	var res_path: String = entry.get("res_path", "")
	if res_path != "" and ResourceLoader.exists(res_path):
		var r: Resource = ResourceLoader.load(res_path, "ItemData", ResourceLoader.CACHE_MODE_REUSE)
		if r and r is ItemData:
			return r
	return _resolve_item_data(entry.get("file", ""))

func _save_session() -> void:
	if _equipped_file == "":
		return
	var data: Dictionary = {"tier": _equipped_file, "items": []}
	if _has_custom_position:
		data.panel_pos = [_panel_position.x, _panel_position.y]
	for sd: Variant in _contents:
		data.items.append(_serialize_slot_data(sd))
	var f: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()

func _load_session() -> void:
	if not FileAccess.file_exists(SESSION_FILE):
		return
	var f: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not parsed or not (parsed is Dictionary):
		return
	if parsed.get("tier", "") != _equipped_file:
		return  # Session is for a different tier — ignore
	if "panel_pos" in parsed:
		var arr: Array = parsed.panel_pos
		if arr.size() == 2:
			_panel_position = Vector2(float(arr[0]), float(arr[1]))
			_has_custom_position = true
	var items_raw: Array = parsed.get("items", [])
	var slot_count: int = _slot_count(_equipped_file)
	_contents.resize(slot_count)
	for i: int in min(items_raw.size(), slot_count):
		_contents[i] = _deserialize_slot_data(items_raw[i])

func _delete_session() -> void:
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_FILE))

# ── Death Persistence ─────────────────────────────────────────────────────────

func _save_contents() -> void:
	var non_null: Array = _contents.filter(func(s: Variant) -> bool: return s != null)
	if non_null.is_empty() and _equipped_file == "":
		return

	var data: Dictionary = {
		"tier": _equipped_file,
		"items": []
	}

	for sd: Variant in _contents:
		data.items.append(_serialize_slot_data(sd))

	var f: FileAccess = FileAccess.open(SAVE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		print("[SecureContainer] Saved %d secured items (tier: %s)" % [non_null.size(), _equipped_file])

func _check_restore() -> void:
	if FileAccess.file_exists(SAVE_FILE):
		print("[SecureContainer] Restore file found — will restore on next scene load")

func _try_restore() -> void:
	if not FileAccess.file_exists(SAVE_FILE):
		return

	var iface: Node = _get_interface()
	if not iface:
		return

	var f: FileAccess = FileAccess.open(SAVE_FILE, FileAccess.READ)
	if not f:
		return
	var text: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if not parsed or not (parsed is Dictionary):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_FILE))
		return

	var tier_file: String = parsed.get("tier", "")
	var items_raw: Array = parsed.get("items", [])

	# Restore secured contents into _contents and write session file so they
	# are available when the panel is next opened after re-equip.
	if tier_file != "" and tier_file in TIERS:
		var slot_count: int = _slot_count(tier_file)
		_contents.resize(slot_count)
		for i: int in min(items_raw.size(), slot_count):
			_contents[i] = _deserialize_slot_data(items_raw[i])
		# Temporarily set _equipped_file so _save_session writes the correct tier
		var prev_file: String = _equipped_file
		_equipped_file = tier_file
		_save_session()
		_equipped_file = prev_file

	# Schedule re-equip into the Pouch slot on next slot injection
	if tier_file != "" and tier_file in _item_data:
		_pending_equip_tier = tier_file

	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_FILE))

	var item_count: int = _contents.filter(func(s: Variant) -> bool: return s != null).size()
	if item_count > 0 or tier_file != "":
		emit_signal("container_restored", _contents)
		print("[SecureContainer] Restored %s + %d secured items (queued re-equip)" % [tier_file, item_count])

func _resolve_item_data(file_id: String) -> ItemData:
	if file_id == "":
		return null
	if file_id in _item_data:
		return _item_data[file_id]
	# Database autoload — where vanilla items and most mods register
	var db: Node = get_node_or_null("/root/Database")
	if db and "master" in db and db.master and "items" in db.master:
		for item: Variant in db.master.items:
			if item and item.file == file_id:
				return item
	# Loot master — Cash System (and similar mods) register their ItemData here
	# without touching Database. Without this fallback, cash secured via
	# shift-click couldn't be re-resolved on panel reopen and vanished because
	# its in-memory ItemData carries no resource_path.
	if ResourceLoader.exists("res://Loot/LT_Master.tres"):
		var lt: Resource = load("res://Loot/LT_Master.tres")
		if lt and "items" in lt:
			for item: Variant in lt.items:
				if item and item.file == file_id:
					return item
	# Last resort — any live Item node in the scene tree with a matching file.
	# Catches items that only exist as runtime instances (no registry entry).
	for node: Node in get_tree().get_nodes_in_group("Item"):
		if "slotData" in node and node.slotData and node.slotData.itemData \
				and node.slotData.itemData.file == file_id:
			return node.slotData.itemData
	return null

# ── Script Override ───────────────────────────────────────────────────────────

func overrideScript(path: String) -> void:
	var script: Script = load(path)
	if not script:
		push_warning("[SecureContainer] Failed to load override: " + path)
		return
	script.reload()

	# Determine the target path: try get_base_script() first, then parse extends annotation
	var target_path: String = ""
	var parent: Script = script.get_base_script()
	if parent:
		target_path = parent.resource_path
	if target_path == "":
		# Fallback: extract path from the first `extends "..."` line in source
		for line: String in script.source_code.split("\n"):
			var s: String = line.strip_edges()
			if s.begins_with('extends "') and s.ends_with('"'):
				target_path = s.substr(9, s.length() - 10)
				break
	if target_path == "":
		push_warning("[SecureContainer] Could not determine base path for: " + path)
		return
	script.take_over_path(target_path)
	print("[SecureContainer] Overrode: " + target_path)

# ── Interface Helper ──────────────────────────────────────────────────────────

func _get_interface() -> Node:
	if _interface and is_instance_valid(_interface):
		return _interface
	var scene: Node = get_tree().current_scene
	if not scene:
		return null
	_interface = scene.get_node_or_null("/root/Map/Core/UI/Interface")
	return _interface

# ── Asset Helpers ─────────────────────────────────────────────────────────────

func _mod_file_path(filename: String) -> String:
	var res_path: String = "res://mods/SecureContainer/" + filename
	if FileAccess.file_exists(res_path):
		return res_path
	var disk_path: String = OS.get_executable_path().get_base_dir()\
		.path_join("mods").path_join("SecureContainer").path_join(filename)
	if FileAccess.file_exists(disk_path):
		return disk_path
	return ""

func _load_mod_image(filename: String) -> ImageTexture:
	var path: String = _mod_file_path(filename)
	if path == "":
		return null
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img: Image = Image.new()
	var ext: String = filename.get_extension().to_lower()
	var err: int = ERR_FILE_UNRECOGNIZED
	if ext == "png":
		err = img.load_png_from_buffer(bytes)
	elif ext in ["jpg", "jpeg"]:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		return null
	return ImageTexture.create_from_image(img)

func _make_placeholder_icon(file_id: String) -> ImageTexture:
	var colors: Dictionary = {
		"SecurePouch_S": Color(0.15, 0.22, 0.15),
		"SecurePouch_M": Color(0.12, 0.15, 0.22),
		"SecurePouch_L": Color(0.22, 0.15, 0.10),
	}
	var col: Color = colors.get(file_id, Color(0.15, 0.15, 0.15))
	var img: Image = Image.create(128, 128, false, Image.FORMAT_RGBA8)
	img.fill(col)
	for x: int in 128:
		for y: int in [0, 1, 2, 125, 126, 127]:
			img.set_pixel(x, y, col.lightened(0.3))
	for y: int in 128:
		for x: int in [0, 1, 2, 125, 126, 127]:
			img.set_pixel(x, y, col.lightened(0.3))
	return ImageTexture.create_from_image(img)

func _build_tetris_tscn(file_id: String, icon_path: String) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append('[gd_scene format=3]')
	lines.append('')
	lines.append('[ext_resource type="Material" path="res://UI/Effects/MT_Item.tres" id="1"]')
	if icon_path != "":
		lines.append('[ext_resource type="Texture2D" path="' + icon_path + '" id="2"]')
	lines.append('')
	lines.append('[node name="' + file_id + '" type="Sprite2D"]')
	lines.append('material = ExtResource("1")')
	lines.append('position = Vector2(32, 32)')
	lines.append('scale = Vector2(0.5, 0.5)')
	if icon_path != "":
		lines.append('texture = ExtResource("2")')
	lines.append('')
	return "\n".join(lines)

func _build_pickup_tscn(file_id: String, mesh_path: String, custom_mesh: bool) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append('[gd_scene format=3]')
	lines.append('')
	lines.append('[ext_resource type="PhysicsMaterial" path="res://Items/Physics/Item_Physics.tres" id="1"]')
	lines.append('[ext_resource type="Script" path="res://Scripts/Pickup.gd" id="2"]')
	lines.append('[ext_resource type="Resource" path="user://SC_Item_%s.tres" id="3"]' % file_id)
	lines.append('[ext_resource type="Script" path="res://Scripts/SlotData.gd" id="4"]')
	if custom_mesh:
		lines.append('[ext_resource type="ArrayMesh" path="' + mesh_path + '" id="5"]')
	lines.append('')
	lines.append('[sub_resource type="Resource" id="SlotData_1"]')
	lines.append('script = ExtResource("4")')
	lines.append('resource_local_to_scene = true')
	lines.append('itemData = ExtResource("3")')
	lines.append('')

	var t: Dictionary = TIERS.get(file_id, {})

	# Collision box
	var col_size: Vector3
	if t.has("size"):
		col_size = t.size
	else:
		var sz: float = 0.06 + t.get("weight", 0.5) * 0.05
		col_size = Vector3(sz, 0.04, sz * 0.7)

	# Fallback box mesh + colour material for tiers with no custom mesh
	if not custom_mesh:
		lines.append('[sub_resource type="BoxMesh" id="BoxMesh_1"]')
		lines.append('size = Vector3(%f, %f, %f)' % [col_size.x, col_size.y, col_size.z])
		lines.append('')
		var mat_col: Color = t.get("color", Color(0.5, 0.5, 0.5))
		lines.append('[sub_resource type="StandardMaterial3D" id="Material_1"]')
		lines.append('albedo_color = Color(%f, %f, %f, 1)' % [mat_col.r, mat_col.g, mat_col.b])
		lines.append('roughness = 0.85')
		lines.append('metallic = 0.0')
		lines.append('')

	lines.append('[sub_resource type="BoxShape3D" id="BoxShape_1"]')
	lines.append('size = Vector3(%f, %f, %f)' % [col_size.x, col_size.y, col_size.z])
	lines.append('')
	lines.append('[node name="' + file_id + '" type="RigidBody3D" node_paths=PackedStringArray("mesh", "collision") groups=["Item"]]')
	lines.append('collision_layer = 4')
	lines.append('collision_mask = 29')
	lines.append('angular_damp = 5.0')
	lines.append('linear_damp = 2.0')
	lines.append('continuous_cd = true')
	lines.append('physics_material_override = ExtResource("1")')
	lines.append('script = ExtResource("2")')
	lines.append('slotData = SubResource("SlotData_1")')
	lines.append('mesh = NodePath("Mesh")')
	lines.append('collision = NodePath("Collision")')
	lines.append('')
	lines.append('[node name="Mesh" type="MeshInstance3D" parent="."]')
	if t.has("mesh_rot"):
		var r: Vector3 = t.mesh_rot
		var b: Basis = Basis.from_euler(Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z)))
		lines.append('transform = Transform3D(%f, %f, %f, %f, %f, %f, %f, %f, %f, 0, 0, 0)' % [
			b.x.x, b.x.y, b.x.z,
			b.y.x, b.y.y, b.y.z,
			b.z.x, b.z.y, b.z.z,
		])
	lines.append('layers = 4')
	lines.append('visibility_range_end = 25.0')
	lines.append('cast_shadow = 0')
	if custom_mesh:
		# Material is baked into the mesh surface — no override needed
		lines.append('mesh = ExtResource("5")')
	else:
		lines.append('mesh = SubResource("BoxMesh_1")')
		lines.append('surface_material_override/0 = SubResource("Material_1")')
	lines.append('')
	lines.append('[node name="Collision" type="CollisionShape3D" parent="."]')
	var half_y: float = col_size.y * 0.5
	lines.append('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %f, 0)' % half_y)
	lines.append('shape = SubResource("BoxShape_1")')
	lines.append('')
	return "\n".join(lines)

# ── OBJ Parser (same as CashSystem) ──────────────────────────────────────────

func _parse_obj(path: String) -> ArrayMesh:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	var v: Array = []
	var vt: Array = []
	var vn: Array = []
	# Single surface — all usemtl groups merged so surface_material_override/0 covers everything
	var surfs: Array = [[]]
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.begins_with("v "):
			var p: PackedStringArray = line.split(" ", false)
			v.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif line.begins_with("vt "):
			var p: PackedStringArray = line.split(" ", false)
			vt.append(Vector2(float(p[1]), float(p[2])))
		elif line.begins_with("vn "):
			var p: PackedStringArray = line.split(" ", false)
			vn.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif line.begins_with("f "):
			var parts: PackedStringArray = line.split(" ", false)
			for i: int in range(3, parts.size()):
				for idx: int in [1, i, i - 1]:
					surfs[0].append(parts[idx])
	file.close()
	# Bottom-align: center X/Z but put the bottom of the mesh at Y=0
	# so the model sits on the ground matching the collision shape offset
	if v.size() > 0:
		var lo: Vector3 = v[0]
		var hi: Vector3 = v[0]
		for vert: Vector3 in v:
			lo = lo.min(vert)
			hi = hi.max(vert)
		var offset: Vector3 = Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
		for i: int in v.size():
			v[i] -= offset
	var mesh: ArrayMesh = ArrayMesh.new()
	for surf: Array in surfs:
		if surf.size() == 0:
			continue
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for face_str: String in surf:
			var c: PackedStringArray = face_str.split("/")
			if c.size() > 2 and c[2] != "":
				st.set_normal(vn[int(c[2]) - 1])
			if c.size() > 1 and c[1] != "":
				var uv: Vector2 = vt[int(c[1]) - 1]
				st.set_uv(Vector2(uv.x, 1.0 - uv.y))
			st.add_vertex(v[int(c[0]) - 1])
		st.generate_tangents()
		mesh = st.commit(mesh)
	return mesh
