extends "res://tests/test_case.gd"
## The F1 multiplayer menu: opens on F1, freezes our fighter while open (also
## across the level reload a session start does), greys out Steam without the
## addon, hosts a direct session and leaves it.

func run() -> void:
	await load_level()
	var net: Node = root.get_node("Net")
	var menu := net.get_node("NetMenu") as NetMenu

	section("multiplayer menu")
	var f1 := InputEventKey.new()
	f1.physical_keycode = KEY_F1
	f1.pressed = true
	check(InputMap.event_is_action(f1, "net_menu"), "F1 is the multiplayer key")
	check(not net.is_online() and menu._corner.text == "F1: multiplayer", "offline by default, with a hint in the corner")
	player.set_input(LocalPlayerInput.new()) # a human at the keyboard again
	menu.open()
	await frames(2)
	check(menu.is_open() and not player.input.enabled, "opening it stops our fighter")
	if not net.steam.available:
		check(menu._steam_note.text.contains("GodotSteam"), "says Steam needs the GodotSteam addon")
		check(menu._steam_buttons.all(func(b: Button): return b.disabled), "Steam buttons are greyed out")

	section("hosting from the menu")
	menu._addr_edit.text = "127.0.0.1:24714"
	menu._on_host_direct()
	check(net.is_online() and net.is_host() and net.transport_name() == "direct", "Host starts a direct session")
	await frames(30) # the level reloads for a fresh start
	var fresh := current_scene.find_child("Player", true, false) as Player
	check(fresh != null and fresh != player and net.fighter(1) == fresh, "the reloaded level's fighter joins the session")
	check(fresh != null and not fresh.input.enabled, "and stays frozen while the menu is open")
	check(menu._corner.text.begins_with("ONLINE (direct) · 1/2"), "the corner shows the session")
	menu.close()
	check(fresh != null and fresh.input.enabled, "closing the menu gives the controls back")
	net.leave()
	await frames(2)
	check(not net.is_online() and (not fresh.has_node("NetSync") or fresh.get_node("NetSync").is_queued_for_deletion()),
		"leaving goes back to offline play")
	check(fresh.health.route_hit.is_null(), "and hits are local again")
