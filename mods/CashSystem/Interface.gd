extends "res://Scripts/Interface.gd"

# Override Drop to handle Cash without needing a Database.gd override
func Drop(target):
	if target.slotData and target.slotData.itemData \
			and target.slotData.itemData.file == "Cash":
		var cash_mod = Engine.get_meta("CashMain", null)
		if cash_mod and cash_mod.cash_pickup_scene:
			_drop_cash_item(target, cash_mod.cash_pickup_scene)
		else:
			PlayError()
		return
	super.Drop(target)

# Override ContextPlace to handle Cash without needing a Database.gd override
func ContextPlace():
	if contextItem and contextItem.slotData and contextItem.slotData.itemData \
			and contextItem.slotData.itemData.file == "Cash":
		var cash_mod = Engine.get_meta("CashMain", null)
		if !cash_mod or !cash_mod.cash_pickup_scene:
			PlayError()
			return

		var map = get_tree().current_scene.get_node_or_null("/root/Map")
		if !map:
			PlayError()
			return
		var pickup = cash_mod.cash_pickup_scene.instantiate()
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
		return
	super.ContextPlace()

func _drop_cash_item(target, scene: PackedScene):
	var map = get_tree().current_scene.get_node_or_null("/root/Map")
	if !map:
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
	pickup.Unfreeze()

	# Assign a fresh SlotData to guarantee independence from other pickups
	var slot = SlotData.new()
	slot.itemData = target.slotData.itemData
	slot.amount = target.slotData.amount
	pickup.slotData = slot

	target.reparent(self)
	target.queue_free()
	PlayDrop()
	UpdateStats(true)

	var cash_mod = Engine.get_meta("CashMain", null)
	if cash_mod:
		cash_mod.cash_dropped.emit(slot.amount)
