extends "res://Scripts/Interface.gd"

var skillsButton: Button
var skillsUI: Control
var skillsXPLabel: Label
var skillRows: Array = []
var skillNames = ["Vitality", "Endurance", "Pack Mule", "Hunger Resist", "Thirst Resist", "Iron Will", "Regeneration", "Cold Resistance", "Stealth", "Recoil Control", "Athleticism", "Scavenger", "Composure"]
var skillKeys = ["xpHealth", "xpStamina", "xpCarry", "xpHunger", "xpThirst", "xpMental", "xpRegen", "xpColdRes", "xpStealth", "xpRecoil", "xpSpeed", "xpScavenger", "xpComposure"]
var skillMax = [10, 10, 10, 10, 10, 10, 5, 10, 10, 10, 5, 5, 5]
var skillCostBase = [25, 25, 20, 20, 20, 20, 50, 20, 25, 25, 30, 30, 25]
var skillDescs = ["+5 Max HP", "-10% Stamina Drain", "+2kg Carry Weight", "-8% Hunger Drain", "-8% Thirst Drain", "-8% Mental Drain", "+0.2 HP/sec Regen", "-8% Cold Drain", "-5% AI Hearing Range", "-5% Weapon Recoil", "+4% Movement Speed", "+5% Loot Chance (better at higher levels)", "-10% Camera Shake From Hits"]
var skillsBuilt = false
var skillDescLabels: Array = []
var _xp_refresh_timer: float = 0.0
var _skills_vbox: VBoxContainer
var _skill_row_panels: Array = []

# Prestige UI state
var _prestige_button: Button = null
var _prestige_status_label: Label = null
var _prestige_modal: Control = null  # overlay panel for picker / confirm
var _prestige_section: VBoxContainer = null  # wrapper so RebuildSkills can drop+rebuild

func ContextPlace():
    # Base ContextPlace calls Database.get(item.file) and fails for custom
    # items. Same fix as Drop — use our catalogued pickup scene.
    if contextItem and contextItem.slotData and contextItem.slotData.itemData:
        var f: String = str(contextItem.slotData.itemData.file)
        if f.begins_with("XPSkillbook_"):
            var xp_mod = Engine.get_meta("XPMain", null)
            if xp_mod:
                _place_skillbook(xp_mod._get_skillbook_pickup(f))
                return
            PlayError()
            return
    super.ContextPlace()

func _place_skillbook(scene: PackedScene):
    if scene == null:
        PlayError()
        return
    var map = get_tree().current_scene.get_node_or_null("/root/Map")
    if map == null:
        PlayError()
        return
    var pickup = scene.instantiate()
    map.add_child(pickup)
    pickup.slotData.Update(contextItem.slotData)
    placer.ContextPlace(pickup)
    if contextGrid:
        contextGrid.Pick(contextItem)
    contextItem.reparent(self)
    contextItem.queue_free()
    Reset()
    HideContext()
    PlayClick()
    UIManager.ToggleInterface()

func Drop(target):
    # Base Drop uses Database.get(file) and queue_frees items whose file
    # isn't registered there — that would silently delete any skill book
    # the player drops. Handle our custom items before delegating.
    if target and target.slotData and target.slotData.itemData:
        var f: String = str(target.slotData.itemData.file)
        if f.begins_with("XPSkillbook_"):
            var xp_mod = Engine.get_meta("XPMain", null)
            if xp_mod:
                _drop_skillbook(target, xp_mod._get_skillbook_pickup(f))
                return
            PlayError()
            return
    super.Drop(target)

func _drop_skillbook(target, scene: PackedScene):
    var map = get_tree().current_scene.get_node_or_null("/root/Map")
    if !map or scene == null:
        PlayError()
        return
    var dir: Vector3
    var pos: Vector3
    var rot: Vector3
    var force = 2.5
    if trader and hoverGrid == null:
        dir = trader.global_transform.basis.z
        pos = (trader.global_position + Vector3(0, 1.0, 0)) + dir / 2
        rot = Vector3(-25, trader.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    elif hoverGrid != null and hoverGrid.get_parent().name == "Container":
        dir = container.global_transform.basis.z
        pos = (container.global_position + Vector3(0, 0.5, 0)) + dir / 2
        rot = Vector3(-25, container.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    else:
        dir = -camera.global_transform.basis.z
        pos = (camera.global_position + Vector3(0, -0.25, 0)) + dir / 2
        rot = Vector3(-25, camera.rotation_degrees.y + 180 + randf_range(-45, 45), 45)
    var pickup = scene.instantiate()
    map.add_child(pickup)
    pickup.position = pos
    pickup.rotation_degrees = rot
    pickup.linear_velocity = dir * force
    if pickup.has_method("Unfreeze"):
        pickup.Unfreeze()
    var slot = SlotData.new()
    slot.itemData = target.slotData.itemData
    slot.amount = target.slotData.amount
    pickup.slotData = slot
    target.reparent(self)
    target.queue_free()
    PlayDrop()
    UpdateStats(true)

func _process(delta):
    if skillsUI and skillsUI.visible:
        _xp_refresh_timer += delta
        if _xp_refresh_timer >= 0.5:
            _xp_refresh_timer = 0.0
            UpdateSkillsUI()

func Open():
    if !skillsBuilt:
        var xp_mod = Engine.get_meta("XPMain", null)
        if xp_mod:
            skillMax = xp_mod.cfg_max_levels
            skillCostBase = xp_mod.cfg_cost_bases
        BuildSkillsUI()
        skillsBuilt = true
    RefreshSkillDescs()
    super()

func HideAllTools():
    super()
    if skillsUI: skillsUI.hide()

func DisableTools():
    super()
    if skillsButton: skillsButton.disabled = true

func EnableTools():
    super()
    if skillsButton: skillsButton.disabled = false

func LoadDefaultTool(tool: int):
    super(tool)
    if skillsButton: skillsButton.set_pressed_no_signal(false)

func UpdateStats(updateLabels: bool):
    await get_tree().physics_frame

    currentInventoryCapacity = 0.0
    currentInventoryWeight = 0.0
    currentInventoryValue = 0.0
    currentEquipmentValue = 0.0
    currentContainerWeight = 0.0
    currentContainerValue = 0.0
    currentEquipmentWeight = 0.0
    currentEquipmentValue = 0.0
    currentEquipmentInsulation = 0.0
    currentSupplyValue = 0.0
    inventoryWeightPercentage = 0.0

    for equipmentSlot in equipment.get_children():
        if equipmentSlot is Slot && equipmentSlot.get_child_count() != 0:
            currentEquipmentWeight += equipmentSlot.get_child(0).Weight()
            currentEquipmentValue += equipmentSlot.get_child(0).Value()
            currentInventoryCapacity += equipmentSlot.get_child(0).slotData.itemData.capacity
            currentEquipmentInsulation += equipmentSlot.get_child(0).slotData.itemData.insulation

    currentInventoryCapacity += baseCarryWeight
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod:
        currentInventoryCapacity += xp_mod.get_level(2) * xp_mod.cfg_carry_per_level + xp_mod.prestige_carry_bonus()
    insulationMultiplier = 1.0 - (currentEquipmentInsulation / 100.0)
    character.insulation = insulationMultiplier

    for element in inventoryGrid.get_children():
        currentInventoryWeight += element.Weight()
        currentInventoryValue += element.Value()

    if currentInventoryWeight > currentInventoryCapacity:
        if !gameData.overweight:
            character.Overweight(true)
    else:
        character.Overweight(false)

    var combinedWeight = currentInventoryWeight + currentEquipmentWeight

    if combinedWeight > 20:
        character.heavyGear = true
    else:
        character.heavyGear = false

    if container:
        for element in containerGrid.get_children():
            currentContainerWeight += element.Weight()
            currentContainerValue += element.Value()

    if trader:
        for element in supplyGrid.get_children():
            currentSupplyValue += element.Value()

    if updateLabels:
        inventoryWeightPercentage = currentInventoryWeight / currentInventoryCapacity
        inventoryCapacity.text = str("%.1f" % currentInventoryCapacity)
        inventoryWeight.text = str("%.1f" % currentInventoryWeight)
        inventoryValue.text = str(int(round(currentInventoryValue)))

        if inventoryWeightPercentage > 1: inventoryWeight.modulate = Color.RED
        elif inventoryWeightPercentage >= 0.5: inventoryWeight.modulate = Color.YELLOW
        else: inventoryWeight.modulate = Color.GREEN

        equipmentCapacity.text = str(int(round(currentInventoryCapacity))) + "kg"
        equipmentValue.text = str(int(round(currentEquipmentValue)))
        equipmentInsulation.text = str(int(round(currentEquipmentInsulation)))

        if currentEquipmentInsulation <= 25: equipmentInsulation.modulate = Color.RED
        elif currentEquipmentInsulation > 25 && currentEquipmentInsulation <= 50: equipmentInsulation.modulate = Color.YELLOW
        else: equipmentInsulation.modulate = Color.GREEN

        if container:
            containerWeight.text = str("%.1f" % currentContainerWeight)
            containerValue.text = str(int(round(currentContainerValue)))
        if trader:
            supplyValue.text = str(int(round(currentSupplyValue)))

# --- Skills UI ---

func BuildSkillsUI():
    Engine.set_meta("XPInterface", self)
    var buttonsContainer = $Tools / Buttons / Margin / Buttons
    skillsButton = Button.new()
    skillsButton.text = "Skills"
    skillsButton.toggle_mode = true
    skillsButton.focus_mode = Control.FOCUS_NONE
    skillsButton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    skillsButton.size_flags_vertical = Control.SIZE_EXPAND_FILL
    buttonsContainer.add_child(skillsButton)
    buttonsContainer.move_child(skillsButton, buttonsContainer.get_child_count() - 2)
    skillsButton.pressed.connect(_on_skills_pressed)

    skillsUI = Control.new()
    skillsUI.name = "Skills"
    skillsUI.offset_left = 0
    skillsUI.offset_top = 0
    skillsUI.offset_right = 512
    skillsUI.offset_bottom = 704
    $Tools.add_child(skillsUI)
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
    _build_prestige_section()


func _build_skill_rows():
    var xp_mod = Engine.get_meta("XPMain", null)
    skillRows.clear()
    skillDescLabels.clear()
    for i in skillNames.size():
        if xp_mod and not xp_mod.is_skill_enabled(i):
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
        levelLabel.text = "0/" + str(skillMax[i])
        levelLabel.custom_minimum_size.x = 42
        levelLabel.add_theme_font_size_override("font_size", 14)
        levelLabel.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
        levelLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        row.add_child(levelLabel)

        # Prestige badge — only visible when that skill has prestige ranks.
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
        upgradeBtn.text = "+" + str(skillCostBase[i]) + " XP"
        upgradeBtn.custom_minimum_size.x = 90
        upgradeBtn.custom_minimum_size.y = 30
        upgradeBtn.focus_mode = Control.FOCUS_NONE
        upgradeBtn.pressed.connect(_on_skill_upgrade.bind(i))
        row.add_child(upgradeBtn)

        skillRows.append({"level": levelLabel, "prestige": prestigeLabel, "button": upgradeBtn, "index": i})
        _skill_row_panels.append(rowPanel)


func RebuildSkills():
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
    _build_prestige_section()
    RefreshSkillDescs()
    UpdateSkillsUI()


func RefreshSkillDescs():
    var xp_mod = Engine.get_meta("XPMain", null)
    if !xp_mod or skillDescLabels.size() < 13: return
    var descs = [
        "+" + str(xp_mod.cfg_hp_per_level) + " Max HP",
        "-" + str(int(xp_mod.cfg_stamina_reduce * 100)) + "% Stamina Drain",
        "+" + str(xp_mod.cfg_carry_per_level) + "kg Carry Weight",
        "-" + str(int(xp_mod.cfg_hunger_reduce * 100)) + "% Hunger Drain",
        "-" + str(int(xp_mod.cfg_thirst_reduce * 100)) + "% Thirst Drain",
        "-" + str(int(xp_mod.cfg_mental_reduce * 100)) + "% Mental Drain",
        "+" + ("%.2f" % xp_mod.cfg_regen_per_level) + " HP/sec Regen",
        "-" + str(int(xp_mod.cfg_coldres_reduce * 100)) + "% Cold Drain",
        "-" + str(int(xp_mod.cfg_stealth_reduce * 100)) + "% AI Hearing Range",
        "-" + str(int(xp_mod.cfg_recoil_reduce * 100)) + "% Weapon Recoil",
        "+" + str(int(xp_mod.cfg_speed_bonus * 100)) + "% Movement Speed",
        "+" + str(int(xp_mod.cfg_scavenger_chance * 100)) + "% Extra Loot Chance",
        "-" + str(int(xp_mod.cfg_shake_reduce * 100)) + "% Camera Shake From Hits"
    ]
    for i in descs.size():
        if skillDescLabels[i] != null:
            skillDescLabels[i].text = descs[i]


func _on_skills_pressed() -> void:
    HideAllTools()
    skillsUI.show()
    eventsButton.set_pressed_no_signal(false)
    craftingButton.set_pressed_no_signal(false)
    notesButton.set_pressed_no_signal(false)
    mapButton.set_pressed_no_signal(false)
    casetteButton.set_pressed_no_signal(false)
    skillsButton.set_pressed_no_signal(true)
    UpdateSkillsUI()
    PlayClick()

func _on_skill_upgrade(index: int):
    var xp_mod = Engine.get_meta("XPMain", null)
    if !xp_mod: return

    var currentLevel = GetSkillLevel(index)
    if currentLevel >= skillMax[index]:
        PlayError()
        return

    var cost = skillCostBase[index] * (currentLevel + 1)
    if xp_mod.xp < cost:
        PlayError()
        return

    xp_mod.xp -= cost
    SetSkillLevel(index, currentLevel + 1)
    xp_mod.SaveXP()
    UpdateSkillsUI()
    UpdateStats(true)
    PlayClick()

func GetSkillLevel(index: int) -> int:
    var xp_mod = Engine.get_meta("XPMain", null)
    if !xp_mod: return 0
    match index:
        0: return xp_mod.xpHealth
        1: return xp_mod.xpStamina
        2: return xp_mod.xpCarry
        3: return xp_mod.xpHunger
        4: return xp_mod.xpThirst
        5: return xp_mod.xpMental
        6: return xp_mod.xpRegen
        7: return xp_mod.xpColdRes
        8: return xp_mod.xpStealth
        9: return xp_mod.xpRecoil
        10: return xp_mod.xpSpeed
        11: return xp_mod.xpScavenger
        12: return xp_mod.xpComposure
    return 0

func SetSkillLevel(index: int, value: int):
    var xp_mod = Engine.get_meta("XPMain", null)
    if !xp_mod: return
    match index:
        0: xp_mod.xpHealth = value
        1: xp_mod.xpStamina = value
        2: xp_mod.xpCarry = value
        3: xp_mod.xpHunger = value
        4: xp_mod.xpThirst = value
        5: xp_mod.xpMental = value
        6: xp_mod.xpRegen = value
        7: xp_mod.xpColdRes = value
        8: xp_mod.xpStealth = value
        9: xp_mod.xpRecoil = value
        10: xp_mod.xpSpeed = value
        11: xp_mod.xpScavenger = value
        12: xp_mod.xpComposure = value

func UpdateSkillsUI():
    if !skillsXPLabel: return
    var xp_mod = Engine.get_meta("XPMain", null)
    if !xp_mod: return
    skillsXPLabel.text = "XP: " + str(xp_mod.xp) + "  (Total: " + str(xp_mod.xpTotal) + ")"
    for row in skillRows:
        if row == null:
            continue
        var i = row.index
        var level = GetSkillLevel(i)
        row.level.text = str(level) + "/" + str(skillMax[i])
        var nextCost = skillCostBase[i] * (level + 1)
        if level >= skillMax[i]:
            row.button.text = "MAX"
            row.button.disabled = true
        else:
            row.button.text = "+" + str(nextCost) + " XP"
            row.button.disabled = xp_mod.xp < nextCost
        # Prestige badge: show "✦N" when this skill has prestige ranks.
        var prank = xp_mod.get_prestige_count(i)
        if "prestige" in row and row.prestige != null:
            row.prestige.text = ("✦" + str(prank)) if prank > 0 else ""
    _update_prestige_ui(xp_mod)

# ─── Prestige UI ──────────────────────────────────────────────

func _build_prestige_section():
    # Wrap in a VBoxContainer so RebuildSkills can drop and recreate the
    # whole block in one step.
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
    _prestige_button.pressed.connect(_on_prestige_pressed)
    _prestige_section.add_child(_prestige_button)

func _update_prestige_ui(xp_mod):
    if _prestige_button == null or _prestige_status_label == null:
        return
    if xp_mod == null or not xp_mod.cfg_prestige_enabled:
        _prestige_button.disabled = true
        _prestige_button.visible = false
        _prestige_status_label.visible = false
        return
    _prestige_button.visible = true
    _prestige_status_label.visible = true
    var available = xp_mod.is_prestige_available()
    _prestige_button.disabled = not available
    if available:
        _prestige_status_label.text = "All enabled skills maxed. Pick a stat to prestige — all XP and skill levels will be wiped in exchange for a permanent bonus to that stat."
        _prestige_status_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.55))
    else:
        _prestige_status_label.text = "Max every enabled skill to unlock Prestige. Prestige grants a permanent stat bonus that survives death, in exchange for wiping all XP and levels."
        _prestige_status_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))

func _on_prestige_pressed():
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod == null or not xp_mod.is_prestige_available():
        PlayError()
        return
    _show_prestige_picker()
    PlayClick()

func _close_prestige_modal():
    if _prestige_modal and is_instance_valid(_prestige_modal):
        _prestige_modal.queue_free()
    _prestige_modal = null

func _show_prestige_picker():
    _close_prestige_modal()
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod == null:
        return

    # Full-panel overlay so the picker feels modal on top of the Skills UI.
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

    # Scrollable list of prestigable skills.
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
        if not xp_mod.is_skill_enabled(i):
            continue
        var cap_reached = not xp_mod.can_prestige_skill(i)
        var prank = xp_mod.get_prestige_count(i)
        var cap = xp_mod.get_prestige_cap(i)
        var row_btn = Button.new()
        row_btn.custom_minimum_size.y = 36
        row_btn.focus_mode = Control.FOCUS_NONE
        var cap_text = "∞" if cap < 0 else str(cap)
        var prefix = "[MAX] " if cap_reached else ""
        row_btn.text = "%s%s  (✦%d / %s)" % [prefix, skillNames[i], prank, cap_text]
        row_btn.disabled = cap_reached
        row_btn.pressed.connect(_on_prestige_skill_picked.bind(i))
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

func _on_prestige_skill_picked(skill_index: int):
    _show_prestige_confirm(skill_index)

func _show_prestige_confirm(skill_index: int):
    _close_prestige_modal()
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod == null:
        return
    var skill_name = skillNames[skill_index]
    var current_rank = xp_mod.get_prestige_count(skill_index)

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
    confirm_btn.pressed.connect(_on_prestige_confirmed.bind(skill_index))
    btn_row.add_child(confirm_btn)

    var cancel_btn = Button.new()
    cancel_btn.text = "Cancel"
    cancel_btn.custom_minimum_size = Vector2(120, 36)
    cancel_btn.focus_mode = Control.FOCUS_NONE
    cancel_btn.pressed.connect(_close_prestige_modal)
    btn_row.add_child(cancel_btn)

func _on_prestige_confirmed(skill_index: int):
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod == null:
        return
    if xp_mod.do_prestige(skill_index):
        PlayClick()
        _close_prestige_modal()
        UpdateSkillsUI()
        UpdateStats(true)
    else:
        PlayError()
