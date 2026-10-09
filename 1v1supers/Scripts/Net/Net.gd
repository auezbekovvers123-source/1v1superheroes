extends Node
## Online sessions (autoload "Net"). Press F1 in game for the menu.
##
## Two ways to connect, same game code:
##   Steam  - GodotSteam's SteamMultiplayerPeer + a Steam lobby: invite a friend,
##            no IP addresses or port forwarding. Needs the GodotSteam addon.
##   Direct - ENet over IP / LAN (and two game windows on one PC for testing).
##
## Each machine controls its own fighter. When a level with a Player is running
## during a session, Net registers that fighter for this peer (NetSync owner)
## and spawns a copy (player.tscn + NetworkPlayerInput) for every other peer.
## Every network message goes through this node, so node paths never have to
## match between machines.
##
## Command line (after "--"): --host, --join=ADDRESS[:PORT], --name=NAME,
## --netsim=LAG_MS,JITTER_MS,LOSS_PERCENT (simulated bad connection).

signal status_changed(text: String)
signal session_started()
signal session_ended(reason: String)
signal peers_changed()
## Dev/test channel: `from_peer` sent `cmd` (see send_debug).
signal debug_message(from_peer: int, cmd: String, args: Array)

enum Transport { NONE, ENET, STEAM }

const DEFAULT_PORT := 24680
const MAX_PLAYERS := 2
const PLAYER_SCENE_PATH := "res://Scenes/Characters/player.tscn"
## Where fighters start, relative to the level's Player, when the level has no
## "spawn_point" markers. Index 0 = host.
const SPAWN_OFFSETS: Array[Vector3] = [Vector3.ZERO, Vector3(-6, 0, 1), Vector3(6, 0, 1), Vector3(0, 0, 7)]
const PING_INTERVAL := 1.0

var transport := Transport.NONE
var steam: SteamLobby
var player_name: String = ""
var status: String = "Offline"
## peer id -> display name (other peers)
var names: Dictionary = {}
## peer id -> round trip in ms
var pings: Dictionary = {}
## Network simulator (see set_network_sim)
var sim_lag_ms: int = 0
var sim_jitter_ms: int = 0
var sim_loss: float = 0.0 # 0..1

var _fighters: Dictionary = {} # peer id -> Player (ours and the copies)
var _connected := false
var _my_id: int = 1
var _fresh_world := true
var _attached_scene: Node = null
var _skip_scene_id: int = 0 # the scene being reloaded: never attach to it
var _base_spawn := Vector3.ZERO
var _ping_timer: float = 0.0
var _sim_queue: Array = [] # [deliver at msec, sequence, Callable]
var _sim_seq: int = 0
var _sim_last_at: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	player_name = _default_name()
	steam = SteamLobby.new()
	steam.name = "Steam"
	add_child(steam)
	steam.started.connect(func(): player_name = steam.persona)
	if steam.available:
		player_name = steam.persona # it started while being added
	steam.lobby_ready.connect(_on_steam_lobby_ready)
	steam.failed.connect(func(reason: String): set_status(reason))
	steam.status.connect(set_status)
	steam.invite_accepted.connect(join_steam)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var menu := NetMenu.new()
	menu.name = "NetMenu"
	add_child(menu)
	_handle_command_line.call_deferred()

func _default_name() -> String:
	var user := OS.get_environment("USERNAME")
	if user == "":
		user = OS.get_environment("USER")
	return user if user != "" else "Player"

func _handle_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--name="):
			player_name = arg.trim_prefix("--name=")
		elif arg.begins_with("--netsim="):
			var v := arg.trim_prefix("--netsim=").split(",")
			set_network_sim(int(v[0]), int(v[1]) if v.size() > 1 else 0, float(v[2]) if v.size() > 2 else 0.0)
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			host_direct()
		elif arg.begins_with("--join="):
			var addr := arg.trim_prefix("--join=")
			var port := DEFAULT_PORT
			if addr.contains(":"):
				port = int(addr.get_slice(":", 1))
				addr = addr.get_slice(":", 0)
			join_direct(addr, port)
	var lobby := steam.command_line_lobby()
	if lobby != 0:
		join_steam(lobby)

# --- Queries ------------------------------------------------------------------------

func is_online() -> bool:
	return transport != Transport.NONE

## True once connected (a host is live immediately, a client after the handshake).
func is_connected_session() -> bool:
	return transport != Transport.NONE and _connected

func is_host() -> bool:
	return is_online() and _my_id == 1

func my_id() -> int:
	return _my_id

## The fighter controlled by `peer` (ours included), or null.
func fighter(peer: int) -> Player:
	var f: Variant = _fighters.get(peer)
	return f if f != null and is_instance_valid(f) else null

func fighters() -> Array[Player]:
	var out: Array[Player] = []
	for peer in _fighters:
		var f := fighter(peer)
		if f:
			out.append(f)
	return out

## The peer that controls `node` (0 when it is not a networked fighter).
func peer_of(node: Node) -> int:
	if node == null:
		return 0
	for peer in _fighters:
		if fighter(peer) == node:
			return peer
	return 0

func transport_name() -> String:
	return ["offline", "direct", "Steam"][transport]

# --- Starting and leaving ------------------------------------------------------------

## Hosts over ENet. fresh_world reloads the level so both sides start equal.
func host_direct(port: int = DEFAULT_PORT, fresh_world: bool = true) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		set_status("Could not host on port %d: %s" % [port, error_string(err)])
		return err
	_begin(peer, Transport.ENET, fresh_world)
	_go_live()
	set_status("Hosting on port %d. Waiting for a player..." % port)
	return OK

func join_direct(address: String, port: int = DEFAULT_PORT, fresh_world: bool = true) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		set_status("Could not connect to %s:%d: %s" % [address, port, error_string(err)])
		return err
	_begin(peer, Transport.ENET, fresh_world)
	set_status("Connecting to %s:%d..." % [address, port])
	return OK

## Creates a Steam lobby and hosts in it. Then invite a friend (F1 > Invite).
func host_steam() -> void:
	leave()
	steam.create_lobby(MAX_PLAYERS)

func join_steam(lobby_id: int) -> void:
	leave()
	steam.join_lobby(lobby_id)

func _on_steam_lobby_ready(peer: MultiplayerPeer, hosting: bool) -> void:
	_begin(peer, Transport.STEAM, true)
	if hosting:
		_go_live()
		set_status("Steam lobby %d is open. Invite a friend (F1)." % steam.lobby_id)

func _begin(peer: MultiplayerPeer, kind: Transport, fresh_world: bool) -> void:
	multiplayer.multiplayer_peer = peer
	transport = kind
	_fresh_world = fresh_world
	_connected = false
	_my_id = multiplayer.get_unique_id()

func _go_live() -> void:
	_connected = true
	_my_id = multiplayer.get_unique_id()
	_attached_scene = null
	if _fresh_world and get_tree().current_scene:
		_skip_scene_id = get_tree().current_scene.get_instance_id()
		get_tree().reload_current_scene.call_deferred()
	session_started.emit()
	peers_changed.emit()

## Ends the session (if any) and goes back to offline play.
func leave(reason: String = "") -> void:
	if transport == Transport.NONE:
		return
	for peer in _fighters.keys():
		if peer != _my_id:
			_despawn(peer)
	var me := fighter(_my_id)
	if me and me.has_node("NetSync"):
		(me.get_node("NetSync") as NetSync).detach()
	if transport == Transport.STEAM:
		steam.leave_lobby()
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	transport = Transport.NONE
	_connected = false
	_my_id = 1
	_fighters.clear()
	names.clear()
	pings.clear()
	_attached_scene = null
	_skip_scene_id = 0
	_sim_queue.clear()
	session_ended.emit(reason)
	peers_changed.emit()
	set_status(reason if reason != "" else "Offline")

func set_status(text: String) -> void:
	status = text
	status_changed.emit(text)

# --- Connection events ---------------------------------------------------------------

func _on_connected_to_server() -> void:
	_go_live()
	set_status("Connected (%s)." % transport_name())

func _on_connection_failed() -> void:
	leave("Could not connect.")

func _on_server_disconnected() -> void:
	leave("The host left the game.")

func _on_peer_connected(_peer: int) -> void:
	if is_host() and _connected:
		set_status("A player joined.")

func _on_peer_disconnected(peer: int) -> void:
	_despawn(peer)
	var who: String = names.get(peer, "A player")
	names.erase(peer)
	pings.erase(peer)
	peers_changed.emit()
	if is_connected_session():
		set_status("%s left." % who)

# --- Fighters in the level -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_deliver_simulated()
	if not is_connected_session():
		return
	var scene := get_tree().current_scene
	if scene and scene != _attached_scene and scene.get_instance_id() != _skip_scene_id:
		_attach(scene)
	_ping_timer -= delta
	if _ping_timer <= 0.0:
		_ping_timer = PING_INTERVAL
		_rx_ping.rpc(Time.get_ticks_msec())

## A level is running: our fighter joins the session, copies follow on hello.
func _attach(scene: Node) -> void:
	var me := _find_local_fighter(scene)
	if me == null:
		return # not a level (yet)
	_attached_scene = scene
	_fighters.clear()
	_base_spawn = me.global_position
	var spot := _spawn_for(_index_of(_my_id))
	if _index_of(_my_id) > 0 or not get_tree().get_nodes_in_group("spawn_point").is_empty():
		me.global_position = spot.pos
		me.velocity = Vector3.ZERO
		me.mesh.rotation = Vector3(0, spot.yaw, 0)
		me.camera_rig.rotation.y = spot.yaw - Player.YAW_OFFSET
		me.reset_physics_interpolation()
	me.set_spawn_point(spot.pos)
	_add_sync(me, _my_id, true, player_name)
	_fighters[_my_id] = me
	_rx_hello.rpc(player_name, true)
	_send_full_state(0)
	peers_changed.emit()

func _find_local_fighter(scene: Node) -> Player:
	for n in get_tree().get_nodes_in_group("player"):
		var p := n as Player
		if p and not p.is_remote() and scene.is_ancestor_of(p):
			return p
	return null

func _add_sync(f: Player, peer: int, owned: bool, display: String) -> void:
	var sync := NetSync.new()
	sync.setup(self, f, peer, owned, display)
	f.add_child(sync)

func _send_full_state(to_peer: int) -> void:
	var me := fighter(_my_id)
	if me and me.has_node("NetSync"):
		var sync := me.get_node("NetSync") as NetSync
		if to_peer == 0:
			for peer in multiplayer.get_peers():
				sync.send_full_state(peer)
		else:
			sync.send_full_state(to_peer)

## Spawn order: host first, then by peer id.
func _index_of(peer: int) -> int:
	var ids: Array = multiplayer.get_peers()
	ids.append(_my_id)
	ids.sort()
	return maxi(ids.find(peer), 0)

## {pos, yaw (mesh)} for the fighter with spawn index `index`.
func _spawn_for(index: int) -> Dictionary:
	var points := get_tree().get_nodes_in_group("spawn_point")
	points.sort_custom(func(a: Node, b: Node): return String(a.name) < String(b.name))
	if index < points.size() and points[index] is Node3D:
		var m := points[index] as Node3D
		return {"pos": m.global_position, "yaw": m.global_rotation.y}
	var pos := _base_spawn + SPAWN_OFFSETS[index % SPAWN_OFFSETS.size()]
	var to := _base_spawn - pos
	var yaw := atan2(to.x, to.z) if to.length() > 0.1 else 0.0
	return {"pos": pos, "yaw": yaw}

func _spawn_copy(peer: int) -> void:
	_despawn(peer)
	var scene := _attached_scene
	var p := (load(PLAYER_SCENE_PATH) as PackedScene).instantiate() as Player
	var keyboard := p.get_node_or_null("Input")
	if keyboard:
		p.remove_child(keyboard)
		keyboard.free()
	var replay := NetworkPlayerInput.new()
	replay.name = "Input"
	p.add_child(replay)
	p.name = "Peer_%d" % peer
	scene.add_child(p)
	var spot := _spawn_for(_index_of(peer))
	p.global_position = spot.pos
	p.mesh.rotation = Vector3(0, spot.yaw, 0)
	p.set_spawn_point(spot.pos)
	p.reset_physics_interpolation()
	_add_sync(p, peer, false, names.get(peer, "Player %d" % peer))
	_fighters[peer] = p
	peers_changed.emit()

func _despawn(peer: int) -> void:
	var f := fighter(peer)
	_fighters.erase(peer)
	if f and peer != _my_id:
		var carrier := f.ragdoll.held_by
		if carrier and is_instance_valid(carrier) and carrier.has_node("RagdollGrabber"):
			(carrier.get_node("RagdollGrabber") as RagdollGrabber).release_grab()
		f.queue_free()

# --- Messages ---------------------------------------------------------------------

func send_state(packet: Array) -> void:
	if is_connected_session():
		_rx_state.rpc(packet)

func send_event(tick: int, kind: StringName, args: Array, to_peer: int = 0) -> void:
	if not is_connected_session():
		return
	if to_peer != 0:
		_rx_event.rpc_id(to_peer, tick, kind, args)
	else:
		_rx_event.rpc(tick, kind, args)

## A hit our fighter landed on `victim`'s copy: the victim's machine applies it.
func send_hit(victim: int, data: Array) -> void:
	if is_connected_session():
		_rx_hit.rpc_id(victim, data)

## Dev/test messages (debug_message on the other side). to_peer 0 = everyone.
func send_debug(cmd: String, args: Array = [], to_peer: int = 0) -> void:
	if not is_connected_session():
		return
	if to_peer != 0:
		_rx_debug.rpc_id(to_peer, cmd, args)
	else:
		_rx_debug.rpc(cmd, args)

# Each _rx_ handler only notes the sender (valid during the call) and hands the
# message on, through the network simulator when it is on.

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rx_state(packet: Array) -> void:
	_receive(_on_state.bind(multiplayer.get_remote_sender_id(), packet), false)

@rpc("any_peer", "call_remote", "reliable")
func _rx_event(tick: int, kind: StringName, args: Array) -> void:
	_receive(_on_event.bind(multiplayer.get_remote_sender_id(), tick, kind, args), true)

@rpc("any_peer", "call_remote", "reliable")
func _rx_hit(data: Array) -> void:
	_receive(_on_hit.bind(multiplayer.get_remote_sender_id(), data), true)

## `reattached`: the sender just (re)loaded its level, so any old copy is stale.
@rpc("any_peer", "call_remote", "reliable")
func _rx_hello(display: String, reattached: bool) -> void:
	_receive(_on_hello.bind(multiplayer.get_remote_sender_id(), display, reattached), true)

@rpc("any_peer", "call_remote", "reliable")
func _rx_debug(cmd: String, args: Array) -> void:
	_receive(_on_debug.bind(multiplayer.get_remote_sender_id(), cmd, args), true)

@rpc("any_peer", "call_remote", "unreliable")
func _rx_ping(sent_ms: int) -> void:
	_receive(_on_ping.bind(multiplayer.get_remote_sender_id(), sent_ms), false)

@rpc("any_peer", "call_remote", "unreliable")
func _rx_pong(sent_ms: int) -> void:
	_receive(_on_pong.bind(multiplayer.get_remote_sender_id(), sent_ms), false)

func _on_state(from: int, packet: Array) -> void:
	var f := fighter(from)
	if f and f.input is NetworkPlayerInput and NetCodec.is_valid_packet(packet):
		(f.input as NetworkPlayerInput).push(packet)

func _on_event(from: int, tick: int, kind: StringName, args: Array) -> void:
	var f := fighter(from)
	if f and from != _my_id and f.has_node("NetSync"):
		(f.get_node("NetSync") as NetSync).queue_event(tick, kind, args)

func _on_hit(from: int, data: Array) -> void:
	var me := fighter(_my_id)
	if me == null or data.size() < 6:
		return
	me.health.apply_damage(NetCodec.decode_hit(data, fighter(from)))

func _on_hello(from: int, display: String, reattached: bool) -> void:
	if not is_connected_session():
		return
	names[from] = display
	if _attached_scene and fighter(_my_id):
		if reattached or fighter(from) == null:
			_spawn_copy(from)
		if reattached:
			_rx_hello.rpc_id(from, player_name, false)
			_send_full_state(from)
	peers_changed.emit()

func _on_debug(from: int, cmd: String, args: Array) -> void:
	debug_message.emit(from, cmd, args)

func _on_ping(from: int, sent_ms: int) -> void:
	if is_connected_session():
		_rx_pong.rpc_id(from, sent_ms)

func _on_pong(from: int, sent_ms: int) -> void:
	pings[from] = Time.get_ticks_msec() - sent_ms

# --- Network simulator ---------------------------------------------------------------
# Test a bad connection between two windows on one PC: --netsim=LAG_MS,JITTER_MS,LOSS_PERCENT
# (e.g. --netsim=80,30,5) delays everything this machine receives and drops some
# unreliable packets.

func set_network_sim(lag_ms: int, jitter_ms: int, loss_percent: float) -> void:
	sim_lag_ms = maxi(lag_ms, 0)
	sim_jitter_ms = maxi(jitter_ms, 0)
	sim_loss = clampf(loss_percent / 100.0, 0.0, 1.0)

func _receive(deliver: Callable, reliable: bool) -> void:
	if sim_lag_ms <= 0 and sim_jitter_ms <= 0 and sim_loss <= 0.0:
		deliver.call()
		return
	if not reliable and randf() < sim_loss:
		return
	# Delay varies, order is kept (real links rarely reorder; ENet drops what they do)
	var at := maxi(Time.get_ticks_msec() + sim_lag_ms + randi_range(0, sim_jitter_ms), _sim_last_at)
	_sim_last_at = at
	_sim_seq += 1
	_sim_queue.append([at, _sim_seq, deliver])

func _deliver_simulated() -> void:
	if _sim_queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	_sim_queue.sort_custom(func(a: Array, b: Array): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	while not _sim_queue.is_empty() and int(_sim_queue[0][0]) <= now:
		var item: Array = _sim_queue.pop_front()
		(item[2] as Callable).call()
