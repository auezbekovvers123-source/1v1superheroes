extends "res://tests/test_case.gd"
## The second machine for test_network.gd and test_steam_flow.gd (started by
## them, not run on its own): joins the host over ENet on localhost, or through
## the fake Steam with --fake-steam, and does what the host tells it through
## Net's debug channel, answering "report" with what it sees.

var net: Node
var done := false

func run() -> void:
	net = root.get_node("Net")
	var port := 24711
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	await load_level()
	player.turn_enabled = false
	net.debug_message.connect(_on_command)
	net.session_ended.connect(func(_reason: String): done = true)
	if "--fake-steam" in OS.get_cmdline_user_args():
		# Accept the host's invite (lobby 1000 + host's Steam id 111)
		var fake: Object = load("res://tests/fake_steam.gd").new(222, "ClientPlayer")
		net.steam.use_steam(fake, func() -> MultiplayerPeer: return load("res://tests/fake_steam_peer.gd").new())
		fake.join_requested.emit(1111, 111)
	else:
		check(net.join_direct("127.0.0.1", port, false) == OK, "client connects")
	var waited := 0
	while not done and waited < 180 * 60:
		await physics_frame
		waited += 1
		if not is_instance_valid(player) or player.is_queued_for_deletion():
			await _rebind() # a session start reloaded the level
	net.leave()
	net.steam.stop()
	await frames(10)

## Takes over the new level's fighter after a reload.
func _rebind() -> void:
	player = null
	while player == null:
		await physics_frame
		var p := current_scene.find_child("Player", true, false) as Player if current_scene else null
		if p and not p.is_queued_for_deletion():
			player = p
	pin = ScriptedPlayerInput.new()
	player.set_input(pin)
	player.turn_enabled = false

func _on_command(from: int, cmd: String, args: Array) -> void:
	if player == null:
		return
	match cmd:
		"move":
			pin.set_move(args[0])
		"hold":
			pin.hold(StringName(args[0]), args[1])
		"tap":
			pin.tap(StringName(args[0]))
		"yaw":
			player.camera_rig.rotation.y = args[0]
		"place":
			if player.state.name != &"free" and not player.is_dead():
				player.change_state(&"free")
			player.global_position = args[0]
			player.velocity = Vector3.ZERO
			player.mesh.rotation = Vector3(0, args[1], 0)
			player.camera_rig.rotation.y = float(args[1]) - Player.YAW_OFFSET
			player.reset_physics_interpolation()
		"give":
			player.pick_up_item(load(args[0]))
		"equip":
			player.equip_from_hand(args[0])
		"report":
			net.send_debug("report", [_report()], from)
		"quit":
			done = true

func _report() -> Dictionary:
	var host_copy: Player = net.fighter(1)
	return {
		"id": net.my_id(),
		"pos": player.global_position,
		"hp": player.health.current,
		"state": String(player.state.name),
		"dead": player.is_dead(),
		"hand": NetCodec.item_path(player.held_item),
		"fly": player.has_power("fly"),
		"host_hp": host_copy.health.current if host_copy else -1.0,
		"host_pos": host_copy.global_position if host_copy else Vector3.ZERO,
	}
