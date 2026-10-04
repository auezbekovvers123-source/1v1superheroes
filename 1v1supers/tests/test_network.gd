extends "res://tests/test_case.gd"
## Online play over ENet on localhost. This process hosts; it starts a second
## Godot process (tests/net_client.gd) that joins and is driven through Net's
## debug channel. Checks what each side sees of the other: movement, view,
## hits in both directions (applied once, by the victim's machine), KO and
## respawn, world pickups, throws, worn items and leaving.
## The Steam transport needs a running Steam client and is not covered here.

const ROCK := "res://Assets/Item/Usable Assets/rock_item.tres"
const CLOAK := "res://Assets/Item/Cloak Assets/cloak_item.tres"

var net: Node
var client_pid := -1
var _reports: Array = []

func run() -> void:
	net = root.get_node("Net")
	await load_level()
	player.turn_enabled = false
	net.debug_message.connect(func(_from: int, cmd: String, args: Array):
		if cmd == "report":
			_reports.append(args[0]))
	await _run_session()
	if client_pid > 0 and OS.is_process_running(client_pid):
		OS.kill(client_pid)
	net.leave()

func _run_session() -> void:
	section("connecting")
	check(net.host_direct(_port(), false) == OK, "hosts on localhost:%d" % _port())
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tests/net_client.gd",
		"--", "--port=%d" % _port()]
	var sim := _netsim()
	if not sim.is_empty():
		net.set_network_sim(sim[0], sim[1], sim[2])
		args.append("--netsim=%d,%d,%d" % sim)
		print("   (both machines receive with %d ms lag, +0..%d ms jitter, %d%% packet loss)" % sim)
	client_pid = OS.create_process(OS.get_executable_path(), args)
	check(client_pid > 0, "client process started")
	var copy: Player = null
	for i in 60 * 60:
		await physics_frame
		if net.fighters().size() == 2:
			break
	for f: Player in net.fighters():
		if f != player:
			copy = f
	check(copy != null, "the client's fighter appears here")
	if copy == null:
		return
	var client_id: int = net.peer_of(copy)
	check(copy.is_remote() and copy.input is NetworkPlayerInput, "it is a network copy")
	check(not copy.is_in_group("local_player") and not copy.camera_rig.camera.current, "the copy never takes the camera or HUD")
	check(net.fighter(net.my_id()) == player, "our own fighter is registered as ours")
	await seconds(1.0)
	var r := await _report()
	check(not r.is_empty(), "the client answers")
	if r.is_empty():
		return
	check(r.host_hp == 100.0 and r.hand == "", "the client sees us too")
	check(hdist(r.pos, player.global_position) > 4.0, "the client starts at its own spawn point")
	check(hdist(copy.global_position, r.pos) < 0.1, "the copy stands where the client is (off by %.3f)" % hdist(copy.global_position, r.pos))

	section("movement and view")
	await place_player(Vector3(-15, 0.05, -15))
	_cmd("place", [Vector3(10, 0.05, -10), PI]) # facing -Z, camera looking -Z
	await seconds(0.5)
	var start: Vector3 = copy.global_position
	_cmd("move", [Vector2(0, -1)])
	await seconds(0.5)
	near(Vector2(copy.velocity.x, copy.velocity.z).length(), copy.walk_speed, 0.25, "copy walking speed")
	await seconds(0.5)
	_cmd("move", [Vector2.ZERO])
	await seconds(1.0)
	r = await _report()
	check(hdist(r.pos, start) > 1.5, "the client walked %.2f m" % hdist(r.pos, start))
	check(hdist(copy.global_position, r.pos) < 0.15, "the copy ends where the client stopped (off by %.3f)" % hdist(copy.global_position, r.pos))
	_cmd("yaw", [1.0])
	await seconds(0.5)
	near(copy.camera_yaw(), 1.0, 0.01, "copy view yaw follows the client's camera")

	section("hits: the victim's machine applies them, once")
	await _face_off()
	pin.tap(&"attack")
	await seconds(1.0)
	r = await _report()
	near(r.hp, 89.0, 0.01, "our punch took 11 HP from the client (on its machine)")
	near(copy.health.current, 89.0, 0.01, "and our copy of it shows the same")
	check(player.health.current == 100.0, "the client's copy hit nobody here")
	await _face_off()
	_cmd("tap", ["attack"])
	await seconds(1.0)
	r = await _report()
	near(player.health.current, 89.0, 0.01, "the client's punch took 11 HP from us, exactly once")
	near(r.host_hp, 89.0, 0.01, "and the client sees our HP drop")

	section("KO and respawn")
	copy.health.take_damage(HitInfo.make(500.0, player, Vector3(0, 2, 0)))
	await seconds(1.0)
	r = await _report()
	check(r.dead, "a lethal hit on the copy knocks out the client on its machine")
	check(copy.is_dead() and copy.ragdoll.is_ragdolled(), "the copy ragdolls here")
	await seconds(copy.respawn_delay + 0.8)
	r = await _report()
	check(not r.dead and r.hp == 100.0 and r.state == "free", "the client respawned")
	check(not copy.is_dead() and copy.health.current == 100.0, "the copy respawned with it")
	check(hdist(copy.global_position, r.pos) < 0.3, "at the same spot (off by %.3f)" % hdist(copy.global_position, r.pos))

	section("world pickup")
	var rock_pickup := current_scene.get_node("RockPickup") as ItemPickup
	_cmd("place", [Vector3(-2, 0.05, 1.6), PI]) # facing the rock pickup
	await seconds(0.6)
	_cmd("tap", ["interact"])
	await seconds(1.5)
	r = await _report()
	check(r.hand == ROCK, "the client picked up the rock")
	check(NetCodec.item_path(copy.held_item) == ROCK, "the copy holds it too")
	check(not rock_pickup.is_pickable(), "and the pickup is gone here as well")

	section("throw")
	_cmd("place", [Vector3(12, 0.05, 12), 0.0]) # facing +Z, open floor
	await seconds(0.6)
	_cmd("hold", ["throw", true])
	await seconds(0.5)
	_cmd("hold", ["throw", false])
	await seconds(0.6)
	var thrown := current_scene.get_node_or_null("Thrown_%d_1" % client_id) as ThrownItem
	check(thrown != null, "the client's throw appears here under the same name")
	check(copy.held_item == null, "the copy's hand is empty after the throw")
	if thrown:
		check(thrown.thrower == copy and thrown.item_data.resource_path == ROCK, "thrown by the copy, it is the rock")
		check(thrown.global_position.z > 12.5, "and it flew forward (z %.2f)" % thrown.global_position.z)

	section("worn items")
	_cmd("give", [CLOAK])
	await seconds(0.3)
	_cmd("equip", [ItemData.EquipSlot.CAPE])
	await seconds(0.5)
	r = await _report()
	check(r.fly, "the client wears the cape")
	check(copy.equipment.has_power("fly") and copy.held_item == null, "the copy wears it too")

	section("leaving")
	_cmd("quit")
	for i in 60 * 5:
		await physics_frame
		if net.fighters().size() == 1:
			break
	check(net.fighters().size() == 1 and (not is_instance_valid(copy) or copy.is_queued_for_deletion()), "the copy disappears when the client leaves")
	check(net.is_online(), "the host stays online")
	for i in 60 * 5:
		await physics_frame
		if not OS.is_process_running(client_pid):
			break
	check(not OS.is_process_running(client_pid), "the client process exited")

func _port() -> int:
	return 24711

## [lag ms, jitter ms, loss %] for both machines, or [] for a clean connection.
func _netsim() -> Array:
	return []

## Puts both fighters 1.1 m apart, facing each other.
func _face_off() -> void:
	await place_player(Vector3(-10.9, 0.05, -12), PI / 2.0) # body faces -X
	_cmd("place", [Vector3(-12, 0.05, -12), PI / 2.0]) # body faces +X
	await seconds(0.6)

func _cmd(cmd: String, args: Array = []) -> void:
	net.send_debug(cmd, args)

func _report() -> Dictionary:
	_reports.clear()
	_cmd("report")
	for i in 60 * 5:
		await physics_frame
		if not _reports.is_empty():
			return _reports[0]
	return {}
