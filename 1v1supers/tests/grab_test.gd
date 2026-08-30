extends SceneTree
## Headless test: ragdoll grab. Kill dummy -> let corpse SETTLE -> grab -> verify
## the neck stays glued to the hand -> move player -> verify body follows -> release.

var _player: Node
var _dummy: Node
var fails: Array[String] = []

func _initialize() -> void:
	_run()

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("TEST PASS: ", msg)
	else:
		fails.append(msg)
		print("TEST FAIL: ", msg)

func _run() -> void:
	await process_frame
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_shape.position = Vector3(0, -0.5, 0)
	root.add_child(floor_body)

	var ps: PackedScene = load("res://Scenes/Characters/C11_Player.tscn")
	_player = ps.instantiate()
	root.add_child(_player)
	_player.global_position = Vector3(0, 0.2, 0)
	var ds: PackedScene = load("res://Scenes/Characters/Dummy.tscn")
	_dummy = ds.instantiate()
	root.add_child(_dummy)
	_dummy.global_position = Vector3(1.0, 0.2, 0)

	for i in range(20):
		await physics_frame

	# Kill with a modest fling so the corpse lands nearby (in-game: punch KO)
	var h = _dummy.get_node("Health")
	h.take_damage(999.0, _player, Vector3(0.6, 0.2, 0.1), 0.0, 0.0)

	# Let the ragdoll settle (~1.8s; respawn comes at 2.5s so grab before that)
	for i in range(110):
		await physics_frame
	var rag = _dummy.get_node("RagdollController")
	_check(rag.is_ragdolled(), "dummy still ragdolled before grab")

	var g = _player.get_node("RagdollGrabber")
	var ok: bool = g.try_grab_nearest()
	_check(ok, "try_grab_nearest returned true")
	_check(g.is_grabbing(), "is_grabbing after grab")
	_check(g._joints.size() == 1, "exactly 1 PinJoint created (got %d)" % g._joints.size())
	_check(g._grabbed_bones.size() == 1, "exactly 1 primary bone")
	if g._grabbed_bones.size() > 0:
		_check(String(g._grabbed_bones[0].bone_name) == "neck.x", "primary bone is neck.x (got %s)" % g._grabbed_bones[0].bone_name)

	# --- Phase 1: standing still — the neck must glue to the hand ---
	var max_dist_still := 0.0
	for i in range(90): # 1.5s
		await physics_frame
		if not g.is_grabbing():
			print("TEST FAIL: grab released during hold at frame ", i)
			fails.append("grab released during hold")
			break
		var pb = g._grabbed_bones[0] if g._grabbed_bones.size() > 0 else null
		if pb and is_instance_valid(pb) and g._hand_anchor and is_instance_valid(g._hand_anchor):
			max_dist_still = maxf(max_dist_still, pb.global_position.distance_to(g._hand_anchor.global_position))
	var dist_end := 99.0
	if g.is_grabbing() and g._grabbed_bones.size() > 0 and is_instance_valid(g._grabbed_bones[0]):
		dist_end = g._grabbed_bones[0].global_position.distance_to(g._hand_anchor.global_position)
	print("TEST INFO: hold max_dist=%.2f end_dist=%.2f" % [max_dist_still, dist_end])
	_check(dist_end < 0.4, "neck glued to hand while standing (end dist %.2fm < 0.4m)" % dist_end)

	# --- Phase 2: player walks forward 2.5m — the body must follow ---
	var start_pos: Vector3 = _player.global_position
	var neck_start: Vector3 = g._grabbed_bones[0].global_position
	for i in range(120): # 2s of walking
		await physics_frame
		_player.global_position += Vector3(0.045, 0, 0) # ~2.7 m/s, no input system in headless
		var pb = g._grabbed_bones[0] if g.is_grabbing() and g._grabbed_bones.size() > 0 else null
		if pb and is_instance_valid(pb) and i % 30 == 29:
			var d: float = pb.global_position.distance_to(g._hand_anchor.global_position)
			print("TEST INFO: walk frame %d neck-hand dist=%.2f" % [i, d])
	_check(_player.global_position.distance_to(start_pos) > 2.0, "player moved >2m")
	# During ragdoll the Dummy's CharacterBody node never moves — track the neck bone
	var neck_moved: float = g._grabbed_bones[0].global_position.distance_to(neck_start)
	print("TEST INFO: neck bone moved %.2fm while dragged" % neck_moved)
	_check(neck_moved > 1.0, "ragdoll body followed the player (neck moved %.2fm)" % neck_moved)
	_check(g.is_grabbing(), "grab survived the drag")

	# --- Phase 3: release ---
	g.release_grab()
	_check(not g.is_grabbing(), "released cleanly")
	_check(g._joints.is_empty(), "joints freed on release")

	print("TEST RESULT: ", ("ALL PASS" if fails.is_empty() else "FAILURES: %d" % fails.size()))
	quit(0 if fails.is_empty() else 1)
