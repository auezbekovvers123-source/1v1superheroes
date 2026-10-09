extends "res://tests/test_case.gd"
## The Steam path end to end with a fake Steam (tests/fake_steam.gd): create a
## lobby, a friend accepts the invite and joins, both fighters appear and play.
## The fake carries the traffic over ENet, so this covers SteamLobby + Net but
## not Valve's servers; only a real Steam client can test those.

const FakeSteam := preload("res://tests/fake_steam.gd")
const FakeSteamPeer := preload("res://tests/fake_steam_peer.gd")

var net: Node
var client_pid := -1
var _reports: Array = []

func run() -> void:
	net = root.get_node("Net")
	await load_level()
	net.debug_message.connect(func(_from: int, cmd: String, args: Array):
		if cmd == "report":
			_reports.append(args[0]))
	await _run_flow()
	if client_pid > 0 and OS.is_process_running(client_pid):
		OS.kill(client_pid)
	net.leave()
	net.steam.stop()

func _run_flow() -> void:
	section("Steam starts")
	var fake := FakeSteam.new(111, "HostPlayer")
	net.steam.use_steam(fake, func() -> MultiplayerPeer: return FakeSteamPeer.new())
	check(net.steam.available and net.steam.persona == "HostPlayer", "Steam is available once the API starts")
	check(fake.calls.has("steamInitEx %d false" % SteamLobby.APP_ID), "initialised for app %d" % SteamLobby.APP_ID)

	section("hosting a lobby")
	net.host_steam()
	await frames(10)
	check(net.is_online() and net.transport_name() == "Steam" and net.is_host(), "hosting a Steam session")
	check(net.steam.lobby_id == 1111, "in our own lobby")
	check(fake.calls.has("createLobby %d %d" % [SteamLobby.LOBBY_TYPE_PUBLIC, net.MAX_PLAYERS]), "created a public lobby for %d" % net.MAX_PLAYERS)
	check(fake.lobby_data.get("game") == SteamLobby.GAME_KEY and fake.lobby_data.get("name") == "HostPlayer's game", "lobby tagged for the lobby browser")
	check(fake.calls.has("setRichPresence connect=+connect_lobby 1111"), "friends can 'Join Game' from the friends list")
	await frames(20)
	player = current_scene.find_child("Player", true, false) as Player
	check(player != null and net.fighter(1) == player, "the reloaded level's fighter is ours")

	section("lobby browser and invites")
	var found: Array = []
	net.steam.lobbies_found.connect(func(l: Array): found.append_array(l), CONNECT_ONE_SHOT)
	net.steam.find_lobbies()
	await frames(3)
	check(found.size() == 1 and found[0].id == 1111 and found[0].name == "HostPlayer's game", "the lobby browser lists it")
	net.steam.invite_friends()
	check(fake.calls.has("invite 1111"), "invite opens the Steam overlay for our lobby")

	section("a friend accepts the invite")
	client_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tests/net_client.gd", "--", "--fake-steam"])
	var copy: Player = null
	for i in 60 * 60:
		await physics_frame
		if net.fighters().size() == 2:
			break
	for f: Player in net.fighters():
		if f != player:
			copy = f
	check(copy != null, "the friend's fighter appears")
	if copy == null:
		return
	check(net.names.get(net.peer_of(copy)) == "ClientPlayer", "named after their Steam persona")
	await seconds(1.0)
	var r := await _report()
	check(not r.is_empty() and r.host_hp == 100.0, "the friend sees us")
	if r.is_empty():
		return
	check(hdist(copy.global_position, r.pos) < 0.1, "their fighter is where they are")

	section("playing")
	pin = ScriptedPlayerInput.new()
	player.set_input(pin)
	await place_player(Vector3(-10.9, 0.05, -12), PI / 2.0)
	net.send_debug("place", [Vector3(-12, 0.05, -12), PI / 2.0])
	await seconds(0.6)
	pin.tap(&"attack")
	await seconds(1.0)
	r = await _report()
	near(r.hp, 89.0, 0.01, "our punch lands on the friend")
	await seconds(2.5) # let the hit sounds finish: exiting mid-sound reads as a leak in headless runs

	section("leaving")
	net.leave("bye")
	check(not net.is_online() and fake.calls.has("leaveLobby 1111"), "leaving closes the lobby")
	for i in 60 * 10:
		await physics_frame
		if not OS.is_process_running(client_pid):
			break
	check(not OS.is_process_running(client_pid), "the friend's game notices the host left")

func _report() -> Dictionary:
	_reports.clear()
	net.send_debug("report")
	for i in 60 * 5:
		await physics_frame
		if not _reports.is_empty():
			return _reports[0]
	return {}
