extends SceneTree
## Hand hold test: verify single HAND slot, hold anim, attachment, use, drop, blocking

var fails: Array[String] = []
var player: Node
var inv: Node

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("TEST PASS: ", msg)
	else:
		fails.append(msg)
		print("TEST FAIL: ", msg)

func _run() -> void:
	await process_frame
	# Floor
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_shape.position = Vector3(0, -0.5, 0)
	root.add_child(floor_body)

	var ps: PackedScene = load("res://Scenes/Characters/C11_Player.tscn")
	player = ps.instantiate()
	root.add_child(player)
	player.global_position = Vector3(0, 0.2, 0)

	for i in range(20):
		await physics_frame
	inv = player.get_node_or_null("Inventory")
	_check(inv != null, "player has Inventory")
	if inv == null:
		_quit()
		return
	_check(inv.has_method("get_held_item"), "inventory has get_held_item")
	_check(inv.item_count() == 0, "inventory initially empty")
	_check(not player.call("is_holding_item") if player.has_method("is_holding_item") else false, "player not holding initially")

	# Load usable data directly
	var usable_data: ItemData = load("res://Assets/Item/Usable Assets/usable_item.tres") as ItemData
	_check(usable_data != null, "usable_item.tres loaded")
	if usable_data:
		_check(usable_data.is_usable == true, "usable is usable")
		_check(usable_data.is_holdable == true, "usable is holdable")
		_check(usable_data.slot == ItemData.EquipSlot.HAND, "usable slot HAND")

	# Attach via player api
	var ok: bool = player.call("attach_held_item", usable_data) if player.has_method("attach_held_item") else false
	_check(ok, "attach_held_item usable succeeded")
	await process_frame
	await process_frame
	_check(inv.item_count() == 1, "inventory now 1 after attach")
	_check(player.call("is_holding_item"), "player is_holding after attach")
	_check(inv.get_held_item() == usable_data, "held item matches usable_data")
	# Check hand attachment created
	var attach = player.get("hand_attachment")
	_check(attach != null and is_instance_valid(attach), "hand_attachment created")
	if attach:
		_check(attach is BoneAttachment3D, "hand_attachment is BoneAttachment3D")
		print("TEST INFO: hand bone used: %s" % player.get("hand_attachment").bone_name)
	var held_vis = player.get("held_instance")
	_check(held_vis != null and is_instance_valid(held_vis), "held_instance visual created")
	# Check hold anim active (HoldOneShot should be firing)
	if player.get("animator"):
		var ap = player.get("c11_ap") as AnimationPlayer
		if ap and ap.has_animation("UpperBody_ITEMHOLD"):
			_check(ap.get_animation("UpperBody_ITEMHOLD").loop_mode == Animation.LOOP_LINEAR, "Hold anim loops")
		var tree = player.get("animator") as AnimationTree
		if tree:
			var req = tree.get("parameters/HoldOneShot/request")
			print("TEST INFO: HoldOneShot request=%s" % str(req))
			# Should be fired (1)
			# Active may not be immediate one frame?
			await process_frame
			var active = tree.get("parameters/HoldOneShot/active")
			print("TEST INFO: HoldOneShot active=%s" % str(active))

	# Try to pick second item while hand full should fail
	var rock_data: ItemData = load("res://Assets/Item/Usable Assets/rock_item.tres") as ItemData
	_check(rock_data != null, "rock item loaded")
	if rock_data:
		var ok2: bool = player.call("attach_held_item", rock_data) if player.has_method("attach_held_item") else false
		_check(not ok2, "second attach blocked when HAND full")
		_check(inv.item_count() == 1, "inventory still 1 after blocked second")

	# Test usable use via try_use
	var used: bool = player.call("try_use_held_item") if player.has_method("try_use_held_item") else false
	_check(used, "try_use_held_item succeeded for usable")
	await process_frame
	_check(player.get("_is_using_item") == true, "_is_using_item true after use")
	# Check that UpperOneShot fired for ITEMUSE
	var tree2 = player.get("animator") as AnimationTree
	if tree2:
		var use_req = tree2.get("parameters/UpperOneShot/request")
		print("TEST INFO: UpperOneShot request after use=%s" % str(use_req))

	# Attack should be redirected to use when holding usable? Try _try_attack while holding usable should call use again, not combo
	# Reset use flag first? Wait for use to finish? Let it finish quickly (anim length maybe 1s). We can await timer 1s
	for i in range(90):
		await process_frame # ~1.5s at 60fps
	# Now try attack again? Should trigger use again
	# Drop item
	var dropped: bool = player.call("drop_held_item") if player.has_method("drop_held_item") else false
	_check(dropped, "drop_held_item succeeded")
	await process_frame
	await physics_frame
	_check(inv.item_count() == 0, "inventory empty after drop")
	_check(not player.call("is_holding_item"), "player no longer holding after drop")
	_check(player.get("held_instance") == null, "held_instance cleared after drop")
	# After drop, there should be a new pickup spawned in world
	var pickups = get_nodes_in_group("pickup")
	print("TEST INFO: pickups in world after drop: %d" % pickups.size())
	var found_dropped := false
	for p in pickups:
		if p.get("item_id") == "usable_01":
			found_dropped = true
			print("TEST INFO: found dropped usable pickup at %s" % str(p.global_position))
			break
	_check(found_dropped, "dropped usable pickup spawned in world")

	# Now test non-usable blocking: attach rock
	var ok3: bool = player.call("attach_held_item", rock_data) if player.has_method("attach_held_item") else false
	_check(ok3, "attach rock (non-usable) succeeded")
	await process_frame
	_check(player.call("is_holding_item"), "holding rock")
	# Try attack should be blocked
	var before_attacking: bool = player.get("is_attacking") as bool
	player.call("_try_attack")
	await process_frame
	var after_attacking: bool = player.get("is_attacking") as bool
	_check(not after_attacking, "attack blocked while holding non-usable")
	# Dash should be blocked
	var dash_ok: bool = player.call("_try_dash") if player.has_method("_try_dash") else false
	_check(not dash_ok, "dash blocked while holding non-usable")
	# Try use should fail for non-usable
	var use_fail: bool = player.call("try_use_held_item") if player.has_method("try_use_held_item") else false
	_check(not use_fail, "try_use fails for non-usable rock")
	# Drop rock
	player.call("drop_held_item")
	await process_frame
	_check(inv.item_count() == 0, "inventory empty after dropping rock")

	# Test pick via ItemPickup path: create a world pickup and try to pick via attach
	var pickup_scene: PackedScene = load("res://Scenes/Items/RockPickup.tscn")
	var pickup = pickup_scene.instantiate() as Node3D
	root.add_child(pickup)
	pickup.global_position = player.global_position + Vector3(1.0, 0.2, 0)
	for i in range(5):
		await physics_frame
	# Simulate player pressing F near pickup via _try_interact_pickup
	# Move player close
	player.global_position = pickup.global_position - Vector3(0.5, 0, 0)
	await physics_frame
	var picked_via_interact: bool = player.call("_try_interact_pickup") if player.has_method("_try_interact_pickup") else false
	# Wait for pickup delay (pickup anim + delay)
	for i in range(60):
		await process_frame
	_check(inv.item_count() == 1, "pickup via _try_interact succeeded (inv 1)")
	_check(player.call("is_holding_item"), "player holding after world pickup")
	# Cleanup second pickup
	print("TEST RESULT: %s" % ("ALL PASS" if fails.is_empty() else "FAILURES: %d" % fails.size()))
	_quit()

func _quit() -> void:
	print("TEST FINAL: %d fails" % fails.size())
	for f in fails:
		print("  FAIL: %s" % f)
	quit(0 if fails.is_empty() else 1)

func _initialize() -> void:
	_run()

