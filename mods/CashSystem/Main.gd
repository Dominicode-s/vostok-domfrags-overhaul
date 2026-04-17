extends Node

# Signals for other mods to hook into
signal cash_sold(amount: int, items: Array)
signal cash_bought(amount: int, items: Array)
signal cash_dropped(amount: int)
signal cash_picked_up(amount: int)

var gameData = preload("res://Resources/GameData.tres")

# Physical cash item (created at runtime, saved to user://)
var cash_item_data: ItemData = null
var cash_pickup_scene: PackedScene = null
const CASH_FILE = "Cash"

# Shelter scene tracking (for Cash persistence)
var _last_scene_name: String = ""
var _cash_data_refreshed: bool = false

# Config
var cfg_sell_rate: float = 0.8
var cfg_death_resets: bool = true
var cfg_loot_enabled: bool = true
var cfg_loot_max_amount: int = 200
var cfg_loot_rarity: int = 0

# MCM integration
var _mcm_helpers = null
const MCM_FILE_PATH = "user://MCM/CashSystem"
const MCM_MOD_ID = "CashSystem"

# Internal state
var _was_trading: bool = false
var _ui_injected: bool = false
var _interface = null
var _trader = null

# Trade UI refs
var _wallet_container: Control = null
var _cash_label: Label = null
var _sell_btn: Button = null
var _buy_btn: Button = null
var _deal_panel = null
var _status_timer: float = 0.0

# Inventory badge refs
var _inv_badge: Label = null
var _inv_badge_injected: bool = false
var _was_dead: bool = false
var _pending_cash_restore: int = -1

# Migration from v1.x virtual wallet
var _migration_pending: int = -1

# ─── Initialization ───

func _ready():
    Engine.set_meta("CashMain", self)
    _cleanup_stale_cache()
    _init_cash_item()
    _init_cash_pickup()
    _check_migration()
    _mcm_helpers = _try_load_mcm()
    if _mcm_helpers:
        _register_mcm()
    else:
        LoadConfig()
    _apply_loot_config()
    overrideScript("res://mods/CashSystem/Interface.gd")

func _on_scene_changed(scene_name: String):
    # After a shelter loads, the vanilla LoadShelter skips Cash items
    # (Database.get("Cash") returns null). We spawn them ourselves.
    var shelter_path = "user://" + scene_name + ".tres"
    if !FileAccess.file_exists(shelter_path):
        return
    if !cash_pickup_scene:
        return
    # Wait for vanilla LoadShelter to finish (it awaits 0.1s internally)
    await get_tree().create_timer(0.3).timeout
    _load_shelter_cash(scene_name)
    # Refresh stale icon/tetris on any Cash items loaded from old saves
    _refresh_cash_item_data()

func _load_shelter_cash(shelter_name: String):
    var shelter = load("user://" + shelter_name + ".tres")
    if !shelter:
        return
    var count = 0
    for item in shelter.items:
        if item.slotData.itemData.file != CASH_FILE:
            continue
        if !item.position.is_finite() or !item.rotation.is_finite():
            continue
        if item.position.y < -10.0:
            continue
        var map = get_tree().current_scene.get_node_or_null("/root/Map")
        if !map:
            return
        var pickup = cash_pickup_scene.instantiate()
        map.add_child(pickup)
        pickup.slotData.Update(item.slotData)
        pickup.name = item.name
        pickup.global_position = item.position
        pickup.global_rotation = item.rotation
        pickup.Freeze()
        pickup.UpdateAttachments()
        count += 1
    if count > 0:
        print("[CashSystem] Restored %d Cash item(s) in shelter" % count)

func _refresh_cash_item_data():
    # Patch any Cash items that were deserialized from old saves with stale icon/tetris
    if !cash_item_data:
        return
    var iface = _get_interface()
    if iface:
        for element in iface.inventoryGrid.get_children():
            if element.slotData and element.slotData.itemData \
                    and element.slotData.itemData.file == CASH_FILE:
                if element.slotData.itemData != cash_item_data:
                    var amt = element.slotData.amount if "amount" in element.slotData else 0
                    element.slotData.itemData = cash_item_data
                    if amt > 0:
                        element.slotData.amount = amt
    # Also patch world pickups
    for node in get_tree().get_nodes_in_group("Item"):
        if "slotData" in node and node.slotData and node.slotData.itemData \
                and node.slotData.itemData.file == CASH_FILE:
            if node.slotData.itemData != cash_item_data:
                var amt = node.slotData.amount if "amount" in node.slotData else 0
                node.slotData.itemData = cash_item_data
                if amt > 0:
                    node.slotData.amount = amt

func overrideScript(path: String):
    var script = load(path)
    if !script:
        push_warning("CashSystem: Failed to load " + path)
        return
    script.reload()
    var parent = script.get_base_script()
    if !parent:
        push_warning("CashSystem: No base script for " + path)
        return
    script.take_over_path(parent.resource_path)

func _cleanup_stale_cache():
    # Remove legacy CashIcon.tres — icon is now embedded directly in ItemData
    var stale = "user://CashIcon.tres"
    if FileAccess.file_exists(stale):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

func _inject_into_loot_pool():
    var lt = load("res://Loot/LT_Master.tres")
    if !lt:
        print("[CashSystem] Could not load LT_Master — cash won't spawn in containers")
        return
    for item in lt.items:
        if item and item.file == CASH_FILE:
            return
    lt.items.append(cash_item_data)
    print("[CashSystem] Cash added to loot pool (%d total items)" % lt.items.size())

func _remove_from_loot_pool():
    var lt = load("res://Loot/LT_Master.tres")
    if !lt: return
    for i in range(lt.items.size() - 1, -1, -1):
        if lt.items[i] and lt.items[i].file == CASH_FILE:
            lt.items.remove_at(i)

func _apply_loot_config():
    if !cash_item_data: return
    cash_item_data.defaultAmount = int(cfg_loot_max_amount)
    match int(cfg_loot_rarity):
        0: cash_item_data.rarity = cash_item_data.Rarity.Common
        1: cash_item_data.rarity = cash_item_data.Rarity.Rare
        2: cash_item_data.rarity = cash_item_data.Rarity.Legendary
    if cfg_loot_enabled:
        _inject_into_loot_pool()
    else:
        _remove_from_loot_pool()

func _init_cash_item():
    var tetris_path = "user://CashTetris.tscn"
    var item_path = "user://CashItemData.tres"
    var icon_res_path = "user://CashIcon.tres"

    # Always rebuild icon fresh — prevents stale cache after icon updates
    var icon = _load_mod_image("icon.png")
    if !icon:
        icon = _make_placeholder_texture()

    # Save icon as a Godot resource so tetris tscn can reference it (user:// PNGs can't be loaded directly)
    ResourceSaver.save(icon, icon_res_path)
    ResourceLoader.load(icon_res_path, "", ResourceLoader.CACHE_MODE_REPLACE)

    # Build tetris scene as text referencing the external icon resource (like vanilla items)
    var tscn_text = _build_tetris_tscn(icon_res_path)
    var f = FileAccess.open(tetris_path, FileAccess.WRITE)
    if f:
        f.store_string(tscn_text)
        f.close()
    var tetris = ResourceLoader.load(tetris_path, "", ResourceLoader.CACHE_MODE_REPLACE)

    var item = ItemData.new()
    item.file = CASH_FILE
    item.name = "Vostok Dollars"
    item.inventory = "Cash"
    item.rotated = "Cash"
    item.equipment = "Cash"
    item.display = "€"
    item.type = "Valuables"
    item.weight = 0.0
    item.value = 1
    item.icon = icon
    item.tetris = tetris
    item.size = Vector2(1, 1)
    item.stackable = true
    item.showAmount = true
    item.defaultAmount = 200
    item.maxAmount = 99999
    # Loot pool defaults — overridden by _apply_loot_config() after MCM loads
    item.rarity = item.Rarity.Common
    item.civilian = true
    item.industrial = true
    item.military = false
    ResourceSaver.save(item, item_path)
    # Bust Godot's resource cache so ext_resources in pickup .tscn get fresh data
    ResourceLoader.load(item_path, "", ResourceLoader.CACHE_MODE_REPLACE)
    cash_item_data = item

func _make_placeholder_texture() -> ImageTexture:
    var img = Image.create(128, 128, false, Image.FORMAT_RGBA8)
    # Dark muted base so the white amount text is readable
    img.fill(Color(0.08, 0.14, 0.08))
    # Subtle thin border
    for x in range(128):
        for y in range(3):
            img.set_pixel(x, y, Color(0.15, 0.25, 0.15))
            img.set_pixel(x, 127 - y, Color(0.15, 0.25, 0.15))
    for y in range(128):
        for x in range(3):
            img.set_pixel(x, y, Color(0.15, 0.25, 0.15))
            img.set_pixel(127 - x, y, Color(0.15, 0.25, 0.15))
    # Faint € symbol in the center
    var ec = Color(0.18, 0.32, 0.18)
    for y in range(40, 90):
        for x in range(50, 55):
            img.set_pixel(x, y, ec)
    for x in range(55, 78):
        for y in range(40, 44):
            img.set_pixel(x, y, ec)
    for x in range(55, 78):
        for y in range(86, 90):
            img.set_pixel(x, y, ec)
    for x in range(44, 72):
        for y in range(58, 62):
            img.set_pixel(x, y, ec)
    for x in range(44, 72):
        for y in range(68, 72):
            img.set_pixel(x, y, ec)
    return ImageTexture.create_from_image(img)

func _build_tetris_tscn(icon_path: String) -> String:
    var lines = PackedStringArray()
    lines.append('[gd_scene format=3]')
    lines.append('')
    lines.append('[ext_resource type="Material" path="res://UI/Effects/MT_Item.tres" id="1"]')
    lines.append('[ext_resource type="Texture2D" path="' + icon_path + '" id="2"]')
    lines.append('')
    lines.append('[node name="' + CASH_FILE + '" type="Sprite2D"]')
    lines.append('material = ExtResource("1")')
    lines.append('position = Vector2(32, 32)')
    lines.append('scale = Vector2(0.5, 0.5)')
    lines.append('texture = ExtResource("2")')
    lines.append('')
    return "\n".join(lines)

func _init_cash_pickup():
    var pickup_path = "user://CashPickup.tscn"
    var mesh_path = "user://CashBundleMesh.res"
    # Build custom 3D mesh from OBJ model assets
    var has_custom_mesh = false
    var obj_file = _mod_file_path("cash_bundle.obj")
    if obj_file != "":
        var mesh = _parse_obj(obj_file)
        if mesh:
            var note_mat = StandardMaterial3D.new()
            note_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
            note_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
            note_mat.albedo_color = Color(1, 1, 1)
            note_mat.roughness = 0.85
            note_mat.metallic = 0.0
            var note_path = _mod_file_path("new_note.jpg")
            if note_path != "":
                var note_bytes = FileAccess.get_file_as_bytes(note_path)
                if !note_bytes.is_empty():
                    var note_img = Image.new()
                    if note_img.load_jpg_from_buffer(note_bytes) == OK:
                        note_img.srgb_to_linear()
                        note_img.generate_mipmaps()
                        note_mat.albedo_texture = ImageTexture.create_from_image(note_img)
            mesh.surface_set_material(0, note_mat)
            if mesh.get_surface_count() > 1:
                var band_mat = StandardMaterial3D.new()
                band_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
                band_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
                band_mat.albedo_color = Color(1, 1, 1)
                band_mat.roughness = 0.92
                band_mat.metallic = 0.0
                var band_path = _mod_file_path("band_strap.jpg")
                if band_path != "":
                    var band_bytes = FileAccess.get_file_as_bytes(band_path)
                    if !band_bytes.is_empty():
                        var band_img = Image.new()
                        if band_img.load_jpg_from_buffer(band_bytes) == OK:
                            band_img.srgb_to_linear()
                            band_img.generate_mipmaps()
                            band_mat.albedo_texture = ImageTexture.create_from_image(band_img)
                mesh.surface_set_material(1, band_mat)
            ResourceSaver.save(mesh, mesh_path, ResourceSaver.FLAG_COMPRESS)
            ResourceLoader.load(mesh_path, "", ResourceLoader.CACHE_MODE_REPLACE)
            has_custom_mesh = true
    var tscn = _build_cash_pickup_tscn(has_custom_mesh)
    var f = FileAccess.open(pickup_path, FileAccess.WRITE)
    if f:
        f.store_string(tscn)
        f.close()
        cash_pickup_scene = ResourceLoader.load(pickup_path, "", ResourceLoader.CACHE_MODE_REPLACE)
    else:
        print("[CashSystem] Failed to write pickup scene")

func _build_cash_pickup_tscn(custom_mesh: bool = false) -> String:
    var lines = PackedStringArray()
    lines.append('[gd_scene format=3]')
    lines.append('')
    lines.append('[ext_resource type="PhysicsMaterial" path="res://Items/Physics/Item_Physics.tres" id="1"]')
    lines.append('[ext_resource type="Script" path="res://Scripts/Pickup.gd" id="2"]')
    lines.append('[ext_resource type="Resource" path="user://CashItemData.tres" id="3"]')
    lines.append('[ext_resource type="Script" path="res://Scripts/SlotData.gd" id="4"]')
    if custom_mesh:
        lines.append('[ext_resource type="ArrayMesh" path="user://CashBundleMesh.res" id="5"]')
    lines.append('')
    lines.append('[sub_resource type="Resource" id="SlotData_1"]')
    lines.append('script = ExtResource("4")')
    lines.append('resource_local_to_scene = true')
    lines.append('itemData = ExtResource("3")')
    lines.append('')
    if !custom_mesh:
        lines.append('[sub_resource type="BoxMesh" id="BoxMesh_1"]')
        lines.append('size = Vector3(0.08, 0.04, 0.05)')
        lines.append('')
        lines.append('[sub_resource type="StandardMaterial3D" id="Material_1"]')
        lines.append('albedo_color = Color(0.12, 0.3, 0.12, 1)')
        lines.append('')
    lines.append('[sub_resource type="BoxShape3D" id="BoxShape_1"]')
    lines.append('size = Vector3(0.18, 0.035, 0.07)')
    lines.append('')
    lines.append('[node name="Cash" type="RigidBody3D" node_paths=PackedStringArray("mesh", "collision") groups=["Item"]]')
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
    lines.append('layers = 4')
    lines.append('visibility_range_end = 25.0')
    lines.append('cast_shadow = 0')
    if custom_mesh:
        lines.append('mesh = ExtResource("5")')
    else:
        lines.append('mesh = SubResource("BoxMesh_1")')
        lines.append('surface_material_override/0 = SubResource("Material_1")')
    lines.append('')
    lines.append('[node name="Collision" type="CollisionShape3D" parent="."]')
    lines.append('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.015, 0)')
    lines.append('shape = SubResource("BoxShape_1")')
    lines.append('')
    return "\n".join(lines)

# ─── Asset Loading Helpers ───

func _mod_file_path(filename: String) -> String:
    var res_path = "res://mods/CashSystem/" + filename
    if FileAccess.file_exists(res_path):
        return res_path
    var base = OS.get_executable_path().get_base_dir()
    var disk_path = base.path_join("mods").path_join("CashSystem").path_join(filename)
    if FileAccess.file_exists(disk_path):
        return disk_path
    return ""

func _load_mod_image(filename: String) -> ImageTexture:
    var path = _mod_file_path(filename)
    if path == "": return null
    var bytes = FileAccess.get_file_as_bytes(path)
    if bytes.is_empty(): return null
    var img = Image.new()
    var ext = filename.get_extension().to_lower()
    var err = ERR_FILE_UNRECOGNIZED
    if ext == "png":
        err = img.load_png_from_buffer(bytes)
    elif ext == "jpg" or ext == "jpeg":
        err = img.load_jpg_from_buffer(bytes)
    if err != OK: return null
    return ImageTexture.create_from_image(img)

func _parse_obj(path: String) -> ArrayMesh:
    var file = FileAccess.open(path, FileAccess.READ)
    if !file: return null
    var v: Array = []
    var vt: Array = []
    var vn: Array = []
    var surfs: Array = [[]]
    var cur: int = 0
    while !file.eof_reached():
        var line = file.get_line().strip_edges()
        if line.begins_with("v "):
            var p = line.split(" ", false)
            v.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
        elif line.begins_with("vt "):
            var p = line.split(" ", false)
            vt.append(Vector2(float(p[1]), float(p[2])))
        elif line.begins_with("vn "):
            var p = line.split(" ", false)
            vn.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
        elif line.begins_with("usemtl "):
            if surfs[cur].size() > 0:
                surfs.append([])
                cur += 1
        elif line.begins_with("f "):
            var parts = line.split(" ", false)
            for i in range(3, parts.size()):
                for idx in [1, i, i - 1]:
                    surfs[cur].append(parts[idx])
    file.close()
    var mesh = ArrayMesh.new()
    for surf in surfs:
        if surf.size() == 0: continue
        var st = SurfaceTool.new()
        st.begin(Mesh.PRIMITIVE_TRIANGLES)
        for face_str in surf:
            var c = face_str.split("/")
            if c.size() > 2 and c[2] != "":
                st.set_normal(vn[int(c[2]) - 1])
            if c.size() > 1 and c[1] != "":
                st.set_uv(vt[int(c[1]) - 1])
            st.add_vertex(v[int(c[0]) - 1])
        st.generate_tangents()
        mesh = st.commit(mesh)
    return mesh

func _check_migration():
    if FileAccess.file_exists("user://CashData.cfg"):
        var cfg = ConfigFile.new()
        if cfg.load("user://CashData.cfg") == OK:
            _migration_pending = cfg.get_value("wallet", "cash", 0)
        DirAccess.remove_absolute(ProjectSettings.globalize_path("user://CashData.cfg"))

# ─── Cash Helpers (physical inventory items) ───

func CountCash() -> int:
    var iface = _get_interface()
    if !iface: return 0
    var total = 0
    for element in iface.inventoryGrid.get_children():
        if element.slotData and element.slotData.itemData \
                and element.slotData.itemData.file == CASH_FILE:
            total += element.slotData.amount
    return total

func AddCash(amount: int) -> bool:
    if amount <= 0: return false
    var iface = _get_interface()
    if !iface: return false

    var slot = SlotData.new()
    slot.itemData = cash_item_data
    slot.amount = amount

    if iface.AutoStack(slot, iface.inventoryGrid):
        return true

    if slot.amount > 0:
        return iface.Create(slot, iface.inventoryGrid, true)
    return true

func RemoveCash(amount: int) -> bool:
    if amount <= 0: return true
    var iface = _get_interface()
    if !iface: return false
    if CountCash() < amount: return false

    var remaining = amount
    var to_remove: Array = []

    for element in iface.inventoryGrid.get_children():
        if remaining <= 0: break
        if element.slotData and element.slotData.itemData \
                and element.slotData.itemData.file == CASH_FILE:
            if element.slotData.amount <= remaining:
                remaining -= element.slotData.amount
                to_remove.append(element)
            else:
                element.slotData.amount -= remaining
                element.UpdateDetails()
                remaining = 0

    for element in to_remove:
        iface.inventoryGrid.Pick(element)
        element.queue_free()

    return remaining <= 0

func RemoveAllCash():
    var iface = _get_interface()
    if !iface: return
    var to_remove: Array = []
    for element in iface.inventoryGrid.get_children():
        if element.slotData and element.slotData.itemData \
                and element.slotData.itemData.file == CASH_FILE:
            to_remove.append(element)
    for element in to_remove:
        iface.inventoryGrid.Pick(element)
        element.queue_free()

# ─── Process ───

func _process(delta):
    # Shelter scene change detection (for Cash persistence)
    var scene = get_tree().current_scene
    if scene and "mapName" in scene:
        var mn = str(scene.mapName)
        if mn != "" and mn != _last_scene_name:
            _last_scene_name = mn
            _on_scene_changed(mn)
    elif scene:
        _last_scene_name = ""

    # Migration from v1.x virtual wallet
    if _migration_pending >= 0:
        var iface = _get_interface()
        if iface and !gameData.isTransitioning:
            if _migration_pending > 0:
                call_deferred("AddCash", _migration_pending)
            _migration_pending = -1

    # One-shot: refresh stale Cash itemData from old saves (fixes icon)
    if !_cash_data_refreshed and cash_item_data:
        var iface2 = _get_interface()
        if iface2 and iface2.inventoryGrid.get_child_count() > 0:
            _refresh_cash_item_data()
            _cash_data_refreshed = true

    # Death reset
    if gameData.isDead:
        if !_was_dead:
            if cfg_death_resets:
                call_deferred("RemoveAllCash")
            else:
                # Base game wipes inventory on death — snapshot now, restore on respawn.
                _pending_cash_restore = CountCash()
            _was_dead = true
    else:
        _was_dead = false
        if _pending_cash_restore > 0:
            var iface_r = _get_interface()
            if iface_r and !gameData.isTransitioning:
                call_deferred("AddCash", _pending_cash_restore)
                _pending_cash_restore = -1

    var iface = _get_interface()

    # Inventory cash badge
    if iface:
        var inv_ui = iface.get_node_or_null("Inventory")
        if inv_ui and inv_ui.visible:
            if !_inv_badge_injected:
                call_deferred("_inject_inv_badge", iface)
            elif _inv_badge and is_instance_valid(_inv_badge):
                _inv_badge.text = str(CountCash())
        else:
            _cleanup_inv_badge()

    # Trade panel
    if gameData.isTrading:
        if !_ui_injected:
            call_deferred("_inject_ui")
        elif _cash_label:
            if _status_timer > 0.0:
                _status_timer -= delta
                if _status_timer <= 0.0:
                    _cash_label.text = "€" + str(CountCash())
                    _cash_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
            else:
                _cash_label.text = "€" + str(CountCash())
    else:
        if _was_trading:
            _cleanup_trade_ui()
        _was_trading = false

# ─── Interface Helpers ───

func _get_interface():
    if _interface and is_instance_valid(_interface):
        return _interface
    var tree = get_tree()
    if !tree or !tree.current_scene: return null
    _interface = tree.current_scene.get_node_or_null("/root/Map/Core/UI/Interface")
    return _interface

# ─── Trade UI ───

func _cleanup_trade_ui():
    if _sell_btn and is_instance_valid(_sell_btn) and _sell_btn.pressed.is_connected(_on_sell):
        _sell_btn.pressed.disconnect(_on_sell)
    if _buy_btn and is_instance_valid(_buy_btn) and _buy_btn.pressed.is_connected(_on_buy):
        _buy_btn.pressed.disconnect(_on_buy)
    if _wallet_container and is_instance_valid(_wallet_container):
        _wallet_container.queue_free()
    if _deal_panel and is_instance_valid(_deal_panel):
        _deal_panel.offset_bottom = 128.0
    _ui_injected = false
    _wallet_container = null
    _deal_panel = null
    _cash_label = null
    _sell_btn = null
    _buy_btn = null
    _status_timer = 0.0
    _trader = null

func _cleanup_inv_badge():
    if _inv_badge and is_instance_valid(_inv_badge):
        _inv_badge.queue_free()
    _inv_badge = null
    _inv_badge_injected = false

func _inject_inv_badge(iface):
    if _inv_badge_injected: return
    var header = iface.get_node_or_null("Inventory/Header")
    if !header: return

    header.offset_right = 384.0

    var inv_label = header.get_node_or_null("Label")
    if inv_label:
        inv_label.offset_right = -256.0

    var cash_ctrl = Control.new()
    cash_ctrl.name = "Cash"
    cash_ctrl.offset_left = 320.0
    cash_ctrl.offset_right = 384.0
    cash_ctrl.offset_bottom = 32.0

    var icon = Label.new()
    icon.text = "€"
    icon.modulate = Color(1, 1, 1, 0.25)
    icon.add_theme_font_size_override("font_size", 14)
    icon.offset_top = 5.0
    icon.offset_right = 16.0
    icon.offset_bottom = 27.0
    icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    cash_ctrl.add_child(icon)

    _inv_badge = Label.new()
    _inv_badge.name = "Value"
    _inv_badge.text = str(CountCash())
    _inv_badge.modulate = Color(0, 1, 0, 1)
    _inv_badge.add_theme_font_size_override("font_size", 13)
    _inv_badge.anchor_right = 1.0
    _inv_badge.anchor_bottom = 1.0
    _inv_badge.offset_left = 24.0
    _inv_badge.grow_horizontal = Control.GROW_DIRECTION_BOTH
    _inv_badge.grow_vertical = Control.GROW_DIRECTION_BOTH
    _inv_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    cash_ctrl.add_child(_inv_badge)

    header.add_child(cash_ctrl)

    var info_script = GDScript.new()
    info_script.source_code = "extends Control\nvar title: String\nvar type: String\nvar info: String\n"
    info_script.reload()
    var info_node = Control.new()
    info_node.set_script(info_script)
    info_node.name = "Info"
    info_node.offset_right = 64.0
    info_node.offset_bottom = 32.0
    info_node.title = "Cash"
    info_node.type = "Inventory Stat"
    info_node.info = "Physical cash in your inventory. Earn by selling items to traders."
    cash_ctrl.add_child(info_node)
    iface.hoverInfos.append(info_node)

    _inv_badge_injected = true

func _inject_ui():
    if _ui_injected: return
    var iface = _get_interface()
    if !iface: return
    _trader = iface.trader
    if !_trader: return

    var deal_panel = iface.get_node_or_null("Deal/Panel")
    if !deal_panel: return
    _deal_panel = deal_panel

    var old = deal_panel.get_node_or_null("WalletRow")
    if old: old.queue_free()

    deal_panel.offset_bottom = 150.0

    _wallet_container = Control.new()
    _wallet_container.name = "WalletRow"
    _wallet_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _wallet_container.offset_right = 384.0
    _wallet_container.offset_bottom = 150.0

    var divider = ColorRect.new()
    divider.color = Color(1, 1, 1, 0.08)
    divider.offset_left = 8.0
    divider.offset_top = 126.0
    divider.offset_right = 376.0
    divider.offset_bottom = 127.0
    _wallet_container.add_child(divider)

    var title = Label.new()
    title.text = "CASH"
    title.add_theme_font_size_override("font_size", 10)
    title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
    title.offset_left = 10.0
    title.offset_top = 128.0
    title.offset_right = 60.0
    title.offset_bottom = 148.0
    title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _wallet_container.add_child(title)

    _cash_label = Label.new()
    _cash_label.text = "€" + str(CountCash())
    _cash_label.add_theme_font_size_override("font_size", 11)
    _cash_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
    _cash_label.offset_left = 58.0
    _cash_label.offset_top = 128.0
    _cash_label.offset_right = 196.0
    _cash_label.offset_bottom = 148.0
    _cash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _cash_label.clip_text = true
    _wallet_container.add_child(_cash_label)

    _sell_btn = Button.new()
    _sell_btn.text = "Sell"
    _sell_btn.focus_mode = Control.FOCUS_NONE
    _sell_btn.add_theme_font_size_override("font_size", 10)
    _sell_btn.offset_left = 200.0
    _sell_btn.offset_top = 129.0
    _sell_btn.offset_right = 284.0
    _sell_btn.offset_bottom = 147.0
    _sell_btn.pressed.connect(_on_sell)
    _wallet_container.add_child(_sell_btn)

    _buy_btn = Button.new()
    _buy_btn.text = "Buy"
    _buy_btn.focus_mode = Control.FOCUS_NONE
    _buy_btn.add_theme_font_size_override("font_size", 10)
    _buy_btn.offset_left = 290.0
    _buy_btn.offset_top = 129.0
    _buy_btn.offset_right = 376.0
    _buy_btn.offset_bottom = 147.0
    _buy_btn.pressed.connect(_on_buy)
    _wallet_container.add_child(_buy_btn)

    deal_panel.add_child(_wallet_container)

    _ui_injected = true
    _was_trading = true

# ─── Sell / Buy ───

func _on_sell():
    if !_interface: return

    var total_value: int = 0
    var selected: Array = []

    for element in _interface.inventoryGrid.get_children():
        if element.selected:
            # Skip cash items — you can't sell money
            if element.slotData.itemData.file == CASH_FILE:
                continue
            total_value += element.Value()
            selected.append(element)

    if selected.size() == 0:
        _flash_status("Pick items", Color(1.0, 0.4, 0.4))
        return

    var sell_value = int(round(total_value * cfg_sell_rate))

    for element in selected:
        _interface.inventoryGrid.Pick(element)
        element.queue_free()

    if sell_value > 0:
        AddCash(sell_value)

    _interface.ResetTrading()
    _interface.UpdateStats(true)
    _flash_status("+€" + str(sell_value), Color(0.4, 1.0, 0.4))
    _play_sound()
    cash_sold.emit(sell_value, selected)

func _on_buy():
    if !_interface or !_trader: return

    var total_cost: int = 0
    var selected: Array = []

    for element in _interface.supplyGrid.get_children():
        if element.selected:
            total_cost += int(round(element.Value() * ((_trader.tax * 0.01 + 1))))
            selected.append(element)

    if selected.size() == 0:
        _flash_status("Pick items", Color(1.0, 0.4, 0.4))
        return

    var current_cash = CountCash()
    if current_cash < total_cost:
        _flash_status("€" + str(total_cost - current_cash) + " short", Color(1.0, 0.4, 0.4))
        return

    RemoveCash(total_cost)

    for element in selected:
        if element.slotData.itemData.type == "Furniture":
            _interface.Create(element.slotData, _interface.catalogGrid, false)
        else:
            _interface.Create(element.slotData, _interface.inventoryGrid, true)

    for element in selected:
        _trader.RemoveFromSupply(element.slotData.itemData)
        _interface.supplyGrid.Pick(element)
        element.queue_free()

    _interface.ResetTrading()
    _interface.UpdateStats(true)
    _flash_status("-€" + str(total_cost), Color(0.4, 1.0, 0.4))
    _play_sound()
    cash_bought.emit(total_cost, selected)

func _flash_status(text: String, color: Color):
    if _cash_label:
        _cash_label.text = text
        _cash_label.add_theme_color_override("font_color", color)
        _status_timer = 2.0

func _play_sound():
    if _interface and _trader:
        _trader.PlayTraderTrade()

# ─── MCM Integration ───

func _try_load_mcm():
    if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
        return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
    return null

func _register_mcm():
    var _config = ConfigFile.new()

    _config.set_value("Int", "cfg_sell_rate", {
        "name" = "Sell Rate (%)",
        "tooltip" = "Percentage of item value received when selling (80 = 80%)",
        "default" = 80, "value" = 80,
        "minRange" = 10, "maxRange" = 100,
        "menu_pos" = 1
    })
    _config.set_value("Bool", "cfg_death_resets", {
        "name" = "Death Resets Cash",
        "tooltip" = "Remove all cash items from inventory on death",
        "default" = true, "value" = true,
        "menu_pos" = 2
    })
    _config.set_value("Bool", "cfg_loot_enabled", {
        "name" = "Cash in Loot",
        "tooltip" = "Cash spawns in civilian and industrial loot containers",
        "default" = true, "value" = true,
        "menu_pos" = 3
    })
    _config.set_value("Int", "cfg_loot_max_amount", {
        "name" = "Max Loot Amount",
        "tooltip" = "Maximum cash per loot stack — containers spawn 1 to this value",
        "default" = 200, "value" = 200,
        "minRange" = 10, "maxRange" = 1000,
        "menu_pos" = 4
    })
    _config.set_value("Dropdown", "cfg_loot_rarity", {
        "name" = "Loot Rarity",
        "tooltip" = "Cash spawn rarity tier in loot containers",
        "default" = 0, "value" = 0,
        "options" = ["Common (84%)", "Rare (13%)", "Legendary (2%)"],
        "menu_pos" = 5
    })

    if !FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
        DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
        _config.save(MCM_FILE_PATH + "/config.ini")
    else:
        # Migrate: remove stale sections from older versions
        var _saved = ConfigFile.new()
        _saved.load(MCM_FILE_PATH + "/config.ini")
        var _dirty = false
        if _saved.has_section("Float"):
            _saved.erase_section("Float")
            _dirty = true
        if _saved.has_section_key("Int", "cfg_loot_rarity"):
            _saved.erase_section_key("Int", "cfg_loot_rarity")
            _dirty = true
        if _dirty:
            _saved.save(MCM_FILE_PATH + "/config.ini")
        _mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, _config, MCM_FILE_PATH + "/config.ini")
        _config.load(MCM_FILE_PATH + "/config.ini")

    _apply_mcm_config(_config)

    _mcm_helpers.RegisterConfiguration(
        MCM_MOD_ID,
        "Cash System",
        MCM_FILE_PATH,
        "Configure sell rates and cash behavior",
        {"config.ini" = _on_mcm_save}
    )

func _on_mcm_save(config: ConfigFile):
    _apply_mcm_config(config)
    _apply_loot_config()

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
    var entry = config.get_value(section, key, null)
    if entry == null or not entry is Dictionary:
        return fallback
    return entry.get("value", fallback)

func _apply_mcm_config(config: ConfigFile):
    cfg_sell_rate = _mcm_val(config, "Int", "cfg_sell_rate", 80) / 100.0
    cfg_death_resets = _mcm_val(config, "Bool", "cfg_death_resets", cfg_death_resets)
    cfg_loot_enabled = _mcm_val(config, "Bool", "cfg_loot_enabled", cfg_loot_enabled)
    cfg_loot_max_amount = _mcm_val(config, "Int", "cfg_loot_max_amount", cfg_loot_max_amount)
    cfg_loot_rarity = _mcm_val(config, "Dropdown", "cfg_loot_rarity", cfg_loot_rarity)

# ─── Config (fallback when MCM not installed) ───

func SaveConfig():
    var cfg = ConfigFile.new()
    cfg.set_value("config", "sell_rate", cfg_sell_rate)
    cfg.set_value("config", "death_resets", cfg_death_resets)
    cfg.set_value("config", "loot_enabled", cfg_loot_enabled)
    cfg.set_value("config", "loot_max_amount", cfg_loot_max_amount)
    cfg.set_value("config", "loot_rarity", cfg_loot_rarity)
    cfg.save("user://CashConfig.cfg")

func LoadConfig():
    var cfg = ConfigFile.new()
    if cfg.load("user://CashConfig.cfg") == OK:
        cfg_sell_rate = cfg.get_value("config", "sell_rate", 0.8)
        cfg_death_resets = cfg.get_value("config", "death_resets", true)
        cfg_loot_enabled = cfg.get_value("config", "loot_enabled", true)
        cfg_loot_max_amount = cfg.get_value("config", "loot_max_amount", 200)
        cfg_loot_rarity = cfg.get_value("config", "loot_rarity", 0)
    else:
        SaveConfig()
