extends Node

# Quick Stack & Sort — Pure autoload, no script overrides
# Container: Sort button (sorts + auto-stacks)
# Inventory: Sort button + Transfer button (quick stack to container)
# MCM: configurable hotkey for sort (applies to hovered grid)

var gameData = preload("res://Resources/GameData.tres")

var _interface = null
var _last_scene: String = ""

# UI state
var _container_btns: HBoxContainer = null
var _inventory_btns: HBoxContainer = null
var _container_injected: bool = false
var _inventory_injected: bool = false

# Ctrl+LMB drag-select
var _drag_selecting: bool = false
var _drag_selected: Array = []
var _drag_source_grid = null
var _drag_markers: Array = []
var _prev_ctrl_lmb: bool = false
var _drag_pending: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _drag_pending_grid = null
const DRAG_THRESHOLD: float = 8.0

# Item locking (keyed by "itemData.file|gridX,gridY" for per-instance persistence)
var _locked_items: Dictionary = {}  # "file|x,y" → true
var _lock_overlays: Dictionary = {}  # item instance_id → ColorRect
const LOCKS_SAVE_PATH = "user://QuickStackSort_locks.cfg"

# MCM
var _mcm_helpers = null
const MCM_FILE_PATH = "user://MCM/QuickStackSort"
const MCM_MOD_ID = "QuickStackSort"
const SORT_ACTION = "quick_sort"
var cfg_sort_key: int = KEY_Z
var cfg_sort_key_type: String = "Key"

# Lock hotkey config
var cfg_lock_key: int = MOUSE_BUTTON_MIDDLE
var cfg_lock_key_type: String = "Mouse"

const SORT_MODE_OPTIONS = ["Alphabetical", "Type", "Weight", "Value", "Size", "Rarity"]
var cfg_sort_mode: int = 0  # Index into SORT_MODE_OPTIONS

# ─── Initialization ───

func _ready():
	Engine.set_meta("QuickStackMain", self)
	_mcm_helpers = _try_load_mcm()
	if _mcm_helpers:
		_register_mcm()
	_register_hotkey(cfg_sort_key, cfg_sort_key_type)
	_load_locks()

func _process(_delta):
	# Find Interface (under Core/UI in map scenes)
	if _interface == null:
		var scene = get_tree().current_scene
		if scene == null:
			return
		if scene.name != _last_scene:
			_last_scene = scene.name
			_interface = null
			_container_injected = false
			_inventory_injected = false
			_cancel_drag_select()
			# Clear overlays — Item nodes are destroyed on scene change
			# _locked_items persists (keyed by itemData.file)
			_lock_overlays.clear()
		var core_ui = scene.get_node_or_null("Core/UI")
		if core_ui:
			for child in core_ui.get_children():
				if child.get("containerGrid") != null:
					_interface = child
					print("[QuickStack] Found Interface: Core/UI/", child.name)
					break
	if _interface == null:
		return

	# Track container open/close for button injection
	var container_ui = _interface.get_node_or_null("Container")
	var inventory_ui = _interface.get_node_or_null("Inventory")
	var container_open = container_ui != null and container_ui.visible and _interface.container != null
	var inventory_open = inventory_ui != null and inventory_ui.visible

	# Container buttons: Sort only
	if container_open and not _container_injected:
		_inject_container_buttons(container_ui)
	elif not container_open and _container_injected:
		_remove_node(_container_btns)
		_container_btns = null
		_container_injected = false

	# Inventory buttons: Sort + Transfer (transfer only when container is open)
	if inventory_open and not _inventory_injected:
		_inject_inventory_buttons(inventory_ui, container_open)
	elif not inventory_open and _inventory_injected:
		_remove_node(_inventory_btns)
		_inventory_btns = null
		_inventory_injected = false
	# Update transfer button visibility when container opens/closes
	elif _inventory_injected and _inventory_btns:
		var transfer = _inventory_btns.get_node_or_null("TransferBtn")
		var store_all = _inventory_btns.get_node_or_null("StoreAllBtn")
		if transfer:
			transfer.visible = container_open
		if store_all:
			store_all.visible = container_open

	# Ctrl+LMB drag-select (all in _process to avoid input conflicts with game)
	var ctrl_lmb = Input.is_key_pressed(KEY_CTRL) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if ctrl_lmb and not _prev_ctrl_lmb and not _drag_selecting and not _drag_pending:
		var hover_grid = _interface.GetHoverGrid()
		if hover_grid != null:
			_drag_pending = true
			_drag_start_pos = _drag_source_grid.get_local_mouse_position() if _drag_source_grid else hover_grid.get_local_mouse_position()
			_drag_pending_grid = hover_grid
	elif ctrl_lmb and _drag_pending and not _drag_selecting:
		if _drag_pending_grid == null:
			_drag_pending = false
		else:
			var current_pos = _drag_pending_grid.get_local_mouse_position()
			if current_pos.distance_to(_drag_start_pos) >= DRAG_THRESHOLD:
				_drag_pending = false
				_start_drag_select(_drag_pending_grid)
	elif ctrl_lmb and _drag_selecting:
		_try_select_item_at_mouse()
	elif not ctrl_lmb and _drag_selecting:
		_finish_drag_select()
	elif not ctrl_lmb and _drag_pending:
		_drag_pending = false
		_drag_pending_grid = null
	_prev_ctrl_lmb = ctrl_lmb

	# Re-apply lock overlays after scene transitions & track position changes
	if not _locked_items.is_empty():
		_reapply_lock_overlays()
		_update_lock_positions()
		_cleanup_stale_locks()

# ─── UI Injection ───

func _inject_container_buttons(container_ui):
	# Container Header: y=-32 to 0, width=256
	_container_btns = HBoxContainer.new()
	_container_btns.name = "QS_ContainerBtns"
	_container_btns.add_theme_constant_override("separation", 4)
	_container_btns.position = Vector2(0, -56)
	_container_btns.size = Vector2(256, 22)

	var sort_btn = _make_button("↕ Sort", _on_sort_container)
	sort_btn.tooltip_text = "Sort & stack items in container"
	_container_btns.add_child(sort_btn)

	var take_btn = _make_button("⇒ Take All", _on_take_all)
	take_btn.tooltip_text = "Take all items from container to inventory"
	_container_btns.add_child(take_btn)

	container_ui.add_child(_container_btns)
	_container_injected = true

func _inject_inventory_buttons(inventory_ui, container_open: bool):
	# Inventory Header: y=-32 to 0, width=320
	_inventory_btns = HBoxContainer.new()
	_inventory_btns.name = "QS_InventoryBtns"
	_inventory_btns.add_theme_constant_override("separation", 4)
	_inventory_btns.position = Vector2(0, -56)
	_inventory_btns.size = Vector2(320, 22)

	var sort_btn = _make_button("↕ Sort", _on_sort_inventory)
	sort_btn.tooltip_text = "Sort & stack items in inventory"
	_inventory_btns.add_child(sort_btn)

	var transfer_btn = _make_button("⇄ Transfer", _on_quick_stack)
	transfer_btn.name = "TransferBtn"
	transfer_btn.tooltip_text = "Transfer matching items to container"
	transfer_btn.visible = container_open
	_inventory_btns.add_child(transfer_btn)

	var store_btn = _make_button("⇐ Store All", _on_store_all)
	store_btn.name = "StoreAllBtn"
	store_btn.tooltip_text = "Store all inventory items into container"
	store_btn.visible = container_open
	_inventory_btns.add_child(store_btn)

	inventory_ui.add_child(_inventory_btns)
	_inventory_injected = true

func _remove_node(node):
	if node and is_instance_valid(node):
		node.queue_free()

func _make_button(text: String, callback: Callable) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(70, 22)

	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.15, 0.15, 0.15, 0.9)
	style_normal.border_color = Color(0.4, 0.4, 0.4, 0.8)
	style_normal.set_border_width_all(1)
	style_normal.set_corner_radius_all(2)
	style_normal.set_content_margin_all(3)

	var style_hover = StyleBoxFlat.new()
	style_hover.bg_color = Color(0.25, 0.25, 0.25, 0.95)
	style_hover.border_color = Color(0.6, 0.6, 0.6, 0.9)
	style_hover.set_border_width_all(1)
	style_hover.set_corner_radius_all(2)
	style_hover.set_content_margin_all(3)

	var style_pressed = StyleBoxFlat.new()
	style_pressed.bg_color = Color(0.1, 0.3, 0.1, 0.95)
	style_pressed.border_color = Color(0.4, 0.7, 0.4, 0.9)
	style_pressed.set_border_width_all(1)
	style_pressed.set_corner_radius_all(2)
	style_pressed.set_content_margin_all(3)

	btn.add_theme_stylebox_override("normal", style_normal)
	btn.add_theme_stylebox_override("hover", style_hover)
	btn.add_theme_stylebox_override("pressed", style_pressed)
	btn.add_theme_font_size_override("font_size", 11)
	btn.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))

	btn.pressed.connect(callback)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_NONE
	return btn

# ─── Input handler (more reliable than polling in _process) ───

func _input(event):
	if _interface == null:
		return
	# Lock toggle
	if _matches_input(event, cfg_lock_key, cfg_lock_key_type):
		var hover_grid = _interface.GetHoverGrid()
		if hover_grid != null:
			var item = _get_item_at_mouse(hover_grid)
			if item != null:
				_toggle_lock(item)
				get_viewport().set_input_as_handled()
				return
	# Sort hotkey
	if _matches_input(event, cfg_sort_key, cfg_sort_key_type):
		_hotkey_sort()

func _matches_input(event: InputEvent, key_value: int, key_type: String) -> bool:
	if key_type == "Mouse":
		return event is InputEventMouseButton and event.pressed and event.button_index == key_value
	else:
		return event is InputEventKey and event.pressed and not event.echo and event.keycode == key_value

# ─── Hotkey Sort ───

func _hotkey_sort():
	if _interface == null:
		return
	# Defensive gate: only act when the inventory UI is actually open. Belt-
	# and-braces against reports of sort firing during zone transitions or
	# shelter exits. GetHoverGrid() should already return null in those
	# cases, but we also check gameData.interface directly.
	if not _is_inventory_ui_open():
		return
	# Never sort while the player is mid-consume/mid-use. The base game holds
	# a direct `targetItem` reference across an `await` in Interface.Use();
	# if we free that Item during the await, the game applies effects to a
	# garbage slotData and the player can instantly die (e.g. "drank juice
	# and pressed Z" → negative vitals → death).
	if _is_player_occupied():
		_play_error()
		return
	# Use GetHoverGrid() which checks mouse position against all visible grids
	var hover_grid = _interface.GetHoverGrid()
	if hover_grid == null:
		return
	var inv_grid = _interface.inventoryGrid
	var con_grid = _interface.containerGrid
	if hover_grid == inv_grid:
		_on_sort_inventory()
	elif hover_grid == con_grid:
		_on_sort_container()

func _is_inventory_ui_open() -> bool:
	# gameData.interface is true while any inventory panel is visible.
	if "interface" in gameData:
		return bool(gameData.interface)
	return false

func _is_player_occupied() -> bool:
	# True during consume/charge/heal progress bars and similar timed actions.
	# Any grid mutation during this window races with base-game code that
	# still holds direct Item node references.
	if "isOccupied" in gameData:
		return bool(gameData.isOccupied)
	return false

# ─── Ctrl+LMB Drag Select ───

func _start_drag_select(grid):
	_drag_selecting = true
	_drag_selected = []
	_drag_source_grid = grid
	_try_select_item_at_mouse()

func _try_select_item_at_mouse():
	if _drag_source_grid == null:
		return
	var mouse_pos = _drag_source_grid.get_local_mouse_position()
	for child in _drag_source_grid.get_children():
		if child is Item and child not in _drag_selected:
			var rect = Rect2(child.position, child.size)
			if rect.has_point(mouse_pos):
				_drag_selected.append(child)
				_add_selection_marker(child)
				break

func _add_selection_marker(item: Item):
	var marker = ColorRect.new()
	marker.name = "QS_Marker"
	marker.color = Color(0.2, 0.9, 0.2, 0.35)
	marker.position = item.position
	marker.size = item.size
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Add marker to the parent UI panel (Container/Inventory), not the grid
	var panel = _drag_source_grid.get_parent()
	if panel:
		# Convert grid-local position to panel-local position
		marker.position = _drag_source_grid.position + item.position
		panel.add_child(marker)
		marker.z_index = 10
	_drag_markers.append(marker)

func _clear_markers():
	for marker in _drag_markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_drag_markers = []

func _finish_drag_select():
	_drag_selecting = false
	_clear_markers()

	if _drag_selected.is_empty():
		_drag_source_grid = null
		return
	if _is_player_occupied():
		_play_error()
		_drag_selected = []
		_drag_source_grid = null
		return

	var inv_grid = _interface.inventoryGrid
	var con_grid = _interface.containerGrid
	var target_grid = null

	if _interface.container != null:
		if _drag_source_grid == inv_grid:
			target_grid = con_grid
		elif _drag_source_grid == con_grid:
			target_grid = inv_grid

	if target_grid == null:
		_play_error()
		_drag_selected = []
		_drag_source_grid = null
		return

	var transferred: int = 0
	var failed: int = 0
	for item in _drag_selected:
		if not is_instance_valid(item):
			continue
		if item.get_parent() != _drag_source_grid:
			continue
		if _is_locked(item):
			continue
		if _interface.AutoStack(item.slotData, target_grid):
			if is_instance_valid(item) and item.get_parent() == _drag_source_grid:
				_drag_source_grid.Pick(item)
				item.queue_free()
			transferred += 1
		elif _interface.AutoPlace(item, target_grid, _drag_source_grid, false):
			transferred += 1
		else:
			failed += 1

	if transferred > 0:
		_play_click()
		_update_ui()
		if failed > 0:
			_flash_result("Moved %d, %d didn't fit" % [transferred, failed])
		else:
			_flash_result("Moved %d items" % transferred)
	else:
		_play_error()

	_drag_selected = []
	_drag_source_grid = null

func _cancel_drag_select():
	_clear_markers()
	_drag_selected = []
	_drag_selecting = false
	_drag_source_grid = null
	_drag_pending = false
	_drag_pending_grid = null

# ─── Item Locking ───

func _lock_key(item: Item) -> String:
	return item.slotData.itemData.file + "|" + str(int(item.position.x)) + "," + str(int(item.position.y))

func _is_locked(item: Item) -> bool:
	if item.slotData == null or item.slotData.itemData == null:
		return false
	return _locked_items.has(_lock_key(item))

func _toggle_lock(item: Item):
	if item.slotData == null or item.slotData.itemData == null:
		return
	var key = _lock_key(item)
	if _locked_items.has(key):
		_locked_items.erase(key)
		_remove_lock_overlay_from_item(item)
		_play_click()
	else:
		_locked_items[key] = true
		_add_lock_overlay(item)
		_play_click()
	_save_locks()

func _add_lock_overlay(item: Item):
	var item_id = item.get_instance_id()
	if _lock_overlays.has(item_id) and is_instance_valid(_lock_overlays[item_id]):
		return
	var overlay = ColorRect.new()
	overlay.name = "QS_Lock"
	overlay.color = Color(1.0, 0.3, 0.3, 0.15)
	overlay.position = Vector2.ZERO
	overlay.size = item.size
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_meta("lock_key", _lock_key(item))
	item.add_child(overlay)
	var border = ReferenceRect.new()
	border.name = "QS_LockBorder"
	border.editor_only = false
	border.border_color = Color(1.0, 0.35, 0.35, 0.7)
	border.border_width = 1.5
	border.position = Vector2.ZERO
	border.size = item.size
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(border)
	_lock_overlays[item_id] = overlay

func _remove_lock_overlay_from_item(item: Item):
	var item_id = item.get_instance_id()
	if _lock_overlays.has(item_id):
		var overlay = _lock_overlays[item_id]
		if is_instance_valid(overlay):
			var border = item.get_node_or_null("QS_LockBorder")
			if border:
				border.queue_free()
			overlay.queue_free()
		_lock_overlays.erase(item_id)

func _get_all_visible_grids() -> Array:
	var grids: Array = []
	if _interface == null:
		return grids
	var inv_grid = _interface.get("inventoryGrid")
	if inv_grid != null:
		grids.append(inv_grid)
	var con_grid = _interface.get("containerGrid")
	if con_grid != null:
		grids.append(con_grid)
	return grids

func _reapply_lock_overlays():
	if _interface == null or _locked_items.is_empty():
		return
	for grid in _get_all_visible_grids():
		for child in grid.get_children():
			if child is Item and child.slotData != null and child.slotData.itemData != null:
				if _locked_items.has(_lock_key(child)):
					var item_id = child.get_instance_id()
					if not _lock_overlays.has(item_id) or not is_instance_valid(_lock_overlays[item_id]):
						_add_lock_overlay(child)

func _update_lock_positions():
	# Track manual drags AND rotations. The overlay is a child of the Item
	# node so it already moves with it, but we still need to (a) migrate the
	# lock key when position/rotation changes the grid cell and (b) resize
	# the overlay + border when the item's dimensions swap on rotation —
	# otherwise the red highlight keeps the pre-rotation shape and looks
	# stuck in the old cell.
	var updates: Array = []
	for item_id in _lock_overlays:
		var overlay = _lock_overlays[item_id]
		if not is_instance_valid(overlay):
			continue
		var item = overlay.get_parent()
		if item == null or not (item is Item) or item.slotData == null or item.slotData.itemData == null:
			continue
		# Sync size so rotation is visually reflected.
		if overlay.size != item.size:
			overlay.size = item.size
			var border = item.get_node_or_null("QS_LockBorder")
			if border:
				border.size = item.size
		var old_key = overlay.get_meta("lock_key", "")
		var new_key = _lock_key(item)
		if old_key != "" and old_key != new_key:
			updates.append([old_key, new_key, overlay])
	for update in updates:
		_locked_items.erase(update[0])
		_locked_items[update[1]] = true
		update[2].set_meta("lock_key", update[1])
	if not updates.is_empty():
		_save_locks()

func _cleanup_stale_locks():
	var stale: Array = []
	for item_id in _lock_overlays:
		if not is_instance_valid(_lock_overlays[item_id]):
			stale.append(item_id)
	for item_id in stale:
		_lock_overlays.erase(item_id)

func _save_locks():
	var config = ConfigFile.new()
	for lock_key in _locked_items:
		config.set_value("locks", lock_key, true)
	config.save(LOCKS_SAVE_PATH)

func _load_locks():
	var config = ConfigFile.new()
	if config.load(LOCKS_SAVE_PATH) == OK:
		if config.has_section("locks"):
			for key in config.get_section_keys("locks"):
				_locked_items[key] = true

func _get_item_at_mouse(grid) -> Item:
	if grid == null:
		return null
	var mouse_pos = grid.get_local_mouse_position()
	for child in grid.get_children():
		if child is Item:
			var rect = Rect2(child.position, child.size)
			if rect.has_point(mouse_pos):
				return child
	return null

# ─── Quick Stack (Transfer) Logic ───

func _on_quick_stack():
	if _interface == null or _interface.container == null:
		return
	if _is_player_occupied():
		_play_error()
		return

	var inv_grid = _interface.inventoryGrid
	var con_grid = _interface.containerGrid
	if inv_grid == null or con_grid == null:
		return

	# Build set of item files already in the container
	var container_files: Dictionary = {}
	for element in con_grid.get_children():
		if element is Item:
			container_files[element.slotData.itemData.file] = true

	if container_files.is_empty():
		_play_error()
		return

	# Collect inventory items that match container contents
	var to_transfer: Array = []
	for element in inv_grid.get_children():
		if element is Item:
			if container_files.has(element.slotData.itemData.file) and not _is_locked(element):
				to_transfer.append(element)

	if to_transfer.is_empty():
		_play_error()
		return

	var transferred: int = 0
	for inv_item in to_transfer:
		if _interface.AutoStack(inv_item.slotData, con_grid):
			inv_grid.Pick(inv_item)
			inv_item.queue_free()
			transferred += 1
		elif _interface.AutoPlace(inv_item, con_grid, inv_grid, false):
			transferred += 1

	if transferred > 0:
		_play_click()
		_update_ui()
		_flash_result("Transferred %d items" % transferred)
	else:
		_play_error()

# ─── Transfer All Logic ───

func _on_take_all():
	_transfer_all(_interface.containerGrid, _interface.inventoryGrid, "Took")

func _on_store_all():
	_transfer_all(_interface.inventoryGrid, _interface.containerGrid, "Stored")

func _transfer_all(source_grid, target_grid, verb: String):
	if _interface == null or _interface.container == null:
		return
	if source_grid == null or target_grid == null:
		return
	if _is_player_occupied():
		_play_error()
		return

	var items: Array = []
	for element in source_grid.get_children():
		if element is Item and not _is_locked(element):
			items.append(element)

	if items.is_empty():
		_play_error()
		return

	var transferred: int = 0
	var failed: int = 0
	for item in items:
		# Try stacking first, then placing
		if _interface.AutoStack(item.slotData, target_grid):
			source_grid.Pick(item)
			item.queue_free()
			transferred += 1
		elif _interface.AutoPlace(item, target_grid, source_grid, false):
			transferred += 1
		else:
			failed += 1

	if transferred > 0:
		_play_click()
		_update_ui()
		if failed > 0:
			_flash_result("%s %d, %d didn't fit" % [verb, transferred, failed])
		else:
			_flash_result("%s %d items" % [verb, transferred])
	else:
		_play_error()
		_flash_result("No room!")

# ─── Sort Logic (sort + auto-stack) ───

func _on_sort_container():
	if _interface == null or _interface.container == null:
		return
	_sort_grid(_interface.containerGrid)

func _on_sort_inventory():
	if _interface == null:
		return
	_sort_grid(_interface.inventoryGrid)

func _sort_grid(grid):
	if _is_player_occupied():
		_play_error()
		return
	# Collect unlocked items for sorting; locked items stay in place
	var items_data: Array = []
	var children = grid.get_children().duplicate()
	var locked_items: Array = []
	for element in children:
		if element is Item:
			if _is_locked(element):
				locked_items.append(element)
			else:
				items_data.append(element.slotData.duplicate())

	if items_data.is_empty():
		_play_error()
		return

	# Remove only unlocked items from grid
	for element in children:
		if element is Item and not _is_locked(element):
			grid.Pick(element)
			element.queue_free()

	# Auto-stack: merge stackable items before placing
	var merged: Array = _merge_stacks(items_data)

	# Sort items based on MCM sort mode
	merged.sort_custom(_compare_items)

	# Re-create items in sorted order
	var placed: int = 0
	var dropped: int = 0
	for slot_data in merged:
		if _interface.Create(slot_data, grid, true):
			placed += 1
		else:
			dropped += 1

	_play_click()
	_update_ui()
	if dropped > 0:
		_flash_result("Sorted %d, dropped %d" % [placed, dropped])
	else:
		_flash_result("Sorted %d items" % placed)

func _compare_items(a, b) -> bool:
	match cfg_sort_mode:
		0:  # Alphabetical
			var na = a.itemData.name.to_lower()
			var nb = b.itemData.name.to_lower()
			if na != nb: return na < nb
		1:  # Type
			var ta = a.itemData.type.to_lower()
			var tb = b.itemData.type.to_lower()
			if ta != tb: return ta < tb
		2:  # Weight (heaviest first)
			if a.itemData.weight != b.itemData.weight:
				return a.itemData.weight > b.itemData.weight
		3:  # Value (most valuable first)
			if a.itemData.value != b.itemData.value:
				return a.itemData.value > b.itemData.value
		4:  # Size (largest area first)
			var area_a = a.itemData.size.x * a.itemData.size.y
			var area_b = b.itemData.size.x * b.itemData.size.y
			if area_a != area_b: return area_a > area_b
		5:  # Rarity (legendary first)
			if a.itemData.rarity != b.itemData.rarity:
				return a.itemData.rarity > b.itemData.rarity
	# Tiebreaker: alphabetical by name
	return a.itemData.name.to_lower() < b.itemData.name.to_lower()

func _merge_stacks(items: Array) -> Array:
	# Group stackable items by file, merge amounts
	var stacks: Dictionary = {}
	var result: Array = []

	for slot in items:
		if slot.itemData.stackable:
			var file = slot.itemData.file
			if not stacks.has(file):
				stacks[file] = []
			stacks[file].append(slot)
		else:
			result.append(slot)

	# Merge each stackable group into minimum number of full stacks
	for file in stacks:
		var group = stacks[file]
		var total_amount: int = 0
		var template = group[0]
		for slot in group:
			total_amount += slot.amount

		var max_stack = template.itemData.maxAmount
		while total_amount > 0:
			var new_slot = template.duplicate()
			new_slot.amount = min(total_amount, max_stack)
			total_amount -= new_slot.amount
			result.append(new_slot)

	return result

# ─── Audio & UI helpers ───

func _play_click():
	if _interface and _interface.has_method("PlayClick"):
		_interface.PlayClick()

func _play_error():
	if _interface and _interface.has_method("PlayError"):
		_interface.PlayError()

func _update_ui():
	if _interface:
		_interface.UpdateUIDetails()
		_interface.UpdateStats(true)

# ─── Status Flash ───

var _flash_panel: PanelContainer = null
var _flash_label: Label = null
var _flash_tween: Tween = null

func _flash_result(text: String):
	if _flash_panel == null:
		# Background panel
		_flash_panel = PanelContainer.new()
		_flash_panel.name = "QuickStackFlash"

		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.08, 0.08, 0.08, 0.85)
		style.border_color = Color(0.3, 0.8, 0.3, 0.6)
		style.set_border_width_all(1)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(6)
		style.content_margin_left = 12
		style.content_margin_right = 12
		_flash_panel.add_theme_stylebox_override("panel", style)

		# Label inside
		_flash_label = Label.new()
		_flash_label.add_theme_font_size_override("font_size", 12)
		_flash_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		_flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_flash_panel.add_child(_flash_label)

	if _flash_panel.get_parent():
		_flash_panel.get_parent().remove_child(_flash_panel)

	# Attach to whichever panel is visible, centered above the header
	var target = _interface.get_node_or_null("Container")
	if target and target.visible:
		target.add_child(_flash_panel)
	else:
		target = _interface.get_node_or_null("Inventory")
		if target and target.visible:
			target.add_child(_flash_panel)

	_flash_label.text = text

	# Position centered above buttons after layout settles
	await get_tree().process_frame
	if is_instance_valid(_flash_panel) and _flash_panel.get_parent():
		var parent_w = _flash_panel.get_parent().size.x
		var panel_w = _flash_panel.size.x
		_flash_panel.position = Vector2((parent_w - panel_w) / 2.0, -96)

	_flash_panel.modulate = Color(1, 1, 1, 0)

	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	# Fade in
	_flash_tween.tween_property(_flash_panel, "modulate", Color(1, 1, 1, 1), 0.15)
	# Hold
	_flash_tween.tween_interval(1.2)
	# Fade out
	_flash_tween.tween_property(_flash_panel, "modulate", Color(1, 1, 1, 0), 0.4)

# ─── Hotkey Registration ───

func _register_hotkey(key_value: int, key_type: String):
	if not InputMap.has_action(SORT_ACTION):
		InputMap.add_action(SORT_ACTION)
	else:
		InputMap.action_erase_events(SORT_ACTION)
	if key_type == "Mouse":
		var ev = InputEventMouseButton.new()
		ev.button_index = key_value
		InputMap.action_add_event(SORT_ACTION, ev)
	else:
		var ev = InputEventKey.new()
		ev.keycode = key_value
		InputMap.action_add_event(SORT_ACTION, ev)

# ─── MCM Integration ───

func _try_load_mcm():
	if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
		return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
	return null

func _register_mcm():
	var _config = ConfigFile.new()

	_config.set_value("Dropdown", "cfg_sort_mode", {
		"name" = "Sort Mode",
		"tooltip" = "How items are ordered when sorting",
		"default" = 0,
		"value" = 0,
		"options" = SORT_MODE_OPTIONS,
		"menu_pos" = 1
	})

	_config.set_value("Keycode", "cfg_sort_key", {
		"name" = "Sort Hotkey",
		"tooltip" = "Key or mouse button to sort the hovered grid",
		"default" = KEY_Z, "default_type" = "Key",
		"value" = KEY_Z, "type" = "Key",
		"menu_pos" = 2
	})

	_config.set_value("Keycode", "cfg_lock_key", {
		"name" = "Lock Hotkey",
		"tooltip" = "Key or mouse button to toggle lock on hovered item",
		"default" = MOUSE_BUTTON_MIDDLE, "default_type" = "Mouse",
		"value" = MOUSE_BUTTON_MIDDLE, "type" = "Mouse",
		"menu_pos" = 3
	})

	# Migration: remove stale entries from older versions
	var _saved = ConfigFile.new()
	if FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
		_saved.load(MCM_FILE_PATH + "/config.ini")
		var changed = false
		var stale_dropdowns = ["cfg_input_type", "cfg_mouse_btn", "cfg_lock_input_type", "cfg_lock_mouse_btn"]
		for key in stale_dropdowns:
			if _saved.has_section_key("Dropdown", key):
				_saved.erase_section_key("Dropdown", key)
				changed = true
		# Stack multiplier was removed in v2.5.1 — it was unreliable and the
		# player complaints about medicals not stacking weren't worth fixing.
		if _saved.has_section_key("Int", "cfg_stack_multiplier"):
			_saved.erase_section_key("Int", "cfg_stack_multiplier")
			changed = true
		if changed:
			_saved.save(MCM_FILE_PATH + "/config.ini")

	if not FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
		DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
		_config.save(MCM_FILE_PATH + "/config.ini")
	else:
		_mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, _config, MCM_FILE_PATH + "/config.ini")
		_config.load(MCM_FILE_PATH + "/config.ini")

	_apply_mcm_config(_config)

	_mcm_helpers.RegisterConfiguration(
		MCM_MOD_ID,
		"Quick Stack & Sort",
		MCM_FILE_PATH,
		"Sort, stack, and transfer inventory items",
		{"config.ini" = _on_mcm_save}
	)

func _on_mcm_save(config: ConfigFile):
	_apply_mcm_config(config)

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return fallback
	return entry.get("value", fallback)

func _mcm_keycode(config: ConfigFile, key: String, fallback_value: int, fallback_type: String) -> Array:
	var entry = config.get_value("Keycode", key, null)
	if entry == null or not entry is Dictionary:
		return [fallback_value, fallback_type]
	return [entry.get("value", fallback_value), entry.get("type", fallback_type)]

func _apply_mcm_config(config: ConfigFile):
	cfg_sort_mode = _mcm_val(config, "Dropdown", "cfg_sort_mode", cfg_sort_mode)
	var sort_arr = _mcm_keycode(config, "cfg_sort_key", cfg_sort_key, cfg_sort_key_type)
	cfg_sort_key = sort_arr[0]
	cfg_sort_key_type = sort_arr[1]
	var lock_arr = _mcm_keycode(config, "cfg_lock_key", cfg_lock_key, cfg_lock_key_type)
	cfg_lock_key = lock_arr[0]
	cfg_lock_key_type = lock_arr[1]
	_register_hotkey(cfg_sort_key, cfg_sort_key_type)
