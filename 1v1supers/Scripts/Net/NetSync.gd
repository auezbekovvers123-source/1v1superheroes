extends Node
class_name NetSync
## The network side of one fighter. Net adds it in online games.
##
## Owner (the machine that controls the fighter): every physics tick it sends a
## state packet with the intent the fighter just simulated and where it ended
## up. Things that must never be missed go as reliable events: hits taken,
## heals, respawns, throws, world pickups and the loadout.
##
## Puppet (every other machine): NetworkPlayerInput replays the owner's intents,
## so the copy walks, punches and animates by itself. This node then pulls the
## body toward the owner's position and applies each event on the tick it
## happened on the owner (a throw leaves the hand on the same animation frame).
##
## Hits: whoever lands a hit decides it hit (the attacker's screen is the
## truth). A hit on a puppet goes to the puppet's owner, which applies it and
## mirrors the result to everyone. A puppet's own hits deal no damage here.

const SNAP_DISTANCE := 2.5 # further off than this the puppet teleports
const POS_CORRECTION := 0.18 # share of the position error removed per tick
const VEL_CORRECTION := 0.25
const YAW_CORRECTION := 0.2
const FLUSH_EVENTS_AFTER := 30 # ticks without packets before queued events apply anyway

var net: Node # the Net autoload (passed in, so this class never needs the global)
var player: Player
var peer_id: int = 0
var is_owner: bool = false
var display_name: String = ""

# Owner
var _tick: int = 0
var _presses := PackedByteArray()
var _view_yaw: float = 0.0
var _throw_seq: int = 0
var _loadout_dirty := false

# Puppet
## How far the copy had drifted from the owner when corrected (smoothed, metres)
## and how often it had to teleport: a measure of replay quality (F1 panel).
var correction_error: float = 0.0
var snaps: int = 0
var _events: Array = [] # [tick, kind, args], arrival order
var _nameplate: Label3D = null

## Call before adding it under the fighter.
func setup(p_net: Node, p_player: Player, p_peer_id: int, p_is_owner: bool, p_name: String) -> void:
	net = p_net
	player = p_player
	peer_id = p_peer_id
	is_owner = p_is_owner
	display_name = p_name
	name = "NetSync"
	process_physics_priority = 10 # after the fighter's own physics frame

func _ready() -> void:
	_presses.resize(NetCodec.PRESS_COUNT)
	player.health.route_hit = _route_hit
	if is_owner:
		_view_yaw = player.camera_yaw()
		player.health.damaged.connect(_on_damaged)
		player.health.healed.connect(func(_amount: float): send_event(&"hp", [player.health.current]))
		player.respawned.connect(func(): send_event(&"respawn", [player.global_position, player.mesh.rotation.y]))
		player.hand.thrown.connect(_on_thrown)
		player.picked_from_world.connect(_on_picked_from_world)
		player.inventory.inventory_changed.connect(_mark_loadout)
		player.equipment.item_equipped.connect(func(_s: int, _i: ItemData): _mark_loadout())
		player.equipment.item_unequipped.connect(func(_s: int, _i: ItemData): _mark_loadout())
	else:
		_make_nameplate()
		player.health.health_changed.connect(func(_c: float, _m: float): _update_nameplate())
		player.state_changed.connect(func(_f: StringName, _t: StringName): _update_nameplate())

## Back to offline play (the session ended).
func detach() -> void:
	if player and is_instance_valid(player) and player.health.route_hit == _route_hit:
		player.health.route_hit = Callable()
	queue_free()

func _physics_process(_delta: float) -> void:
	if is_owner:
		_owner_tick()
	else:
		_puppet_tick()

# --- Owner ------------------------------------------------------------------------

func _owner_tick() -> void:
	var i := player.intent
	var pressed := NetCodec.presses(i)
	for k in NetCodec.PRESS_COUNT:
		if pressed[k]:
			_presses[k] = (_presses[k] + 1) & 0xFF
	if not player.camera_rig.inventory_mode: # the inventory swings the camera round: not a turn
		_view_yaw = player.camera_yaw()
	_tick += 1
	var p := []
	p.resize(NetCodec.SIZE)
	p[NetCodec.TICK] = _tick
	p[NetCodec.MOVE] = i.move
	p[NetCodec.HELD] = NetCodec.held_bits(i)
	p[NetCodec.PRESSES] = NetCodec.pack_counters(_presses)
	p[NetCodec.VIEW_YAW] = _view_yaw
	p[NetCodec.AIM_POINT] = player.aim_point()
	p[NetCodec.POS] = player.global_position
	p[NetCodec.VEL] = player.velocity
	p[NetCodec.MESH_YAW] = player.mesh.rotation.y
	p[NetCodec.STAMINA] = player.stamina.value
	net.send_state(p)
	if _loadout_dirty:
		_loadout_dirty = false
		send_event(&"loadout", NetCodec.encode_loadout(player))

## Reliable event about this fighter, stamped with the tick of the packet that
## carries its result (the one sent at the end of this physics frame).
func send_event(kind: StringName, args: Array, to_peer: int = 0) -> void:
	net.send_event(_tick + 1, kind, args, to_peer)

## Everything a machine that just joined needs to draw this fighter right.
func send_full_state(to_peer: int) -> void:
	send_event(&"loadout", NetCodec.encode_loadout(player), to_peer)
	send_event(&"hp", [player.health.current], to_peer)

func _mark_loadout() -> void:
	_loadout_dirty = true

func _on_damaged(hit: HitInfo) -> void:
	send_event(&"hit", [NetCodec.encode_hit(hit, net.peer_of(hit.attacker)), player.health.current])

func _on_thrown(item: ThrownItem) -> void:
	_throw_seq += 1
	item.name = "Thrown_%d_%d" % [peer_id, _throw_seq] # same name on every machine
	send_event(&"throw", [String(item.name), NetCodec.item_path(item.item_data), item.global_position,
		item.linear_velocity, item.angular_velocity, item.throw_power])

func _on_picked_from_world(item: Node3D) -> void:
	var scene := get_tree().current_scene
	if scene and scene.is_ancestor_of(item):
		send_event(&"pickup", [String(scene.get_path_to(item))])

# --- Hits ----------------------------------------------------------------------------

func _route_hit(hit: HitInfo) -> bool:
	var attacker := hit.attacker as Player
	if attacker and attacker.is_remote():
		return false # the attacker's own machine decides what it hit
	if is_owner:
		return player.health.apply_damage(hit)
	if attacker == null or not player.health.can_take_damage():
		return false # world damage to a puppet is its owner's call
	# One report per swing until the owner's answer comes back
	player.health.set_invulnerable(player.health.invuln_time)
	net.send_hit(peer_id, NetCodec.encode_hit(hit, net.my_id()))
	return true

# --- Puppet ----------------------------------------------------------------------------

## Called by Net when an event for this fighter arrives.
func queue_event(tick: int, kind: StringName, args: Array) -> void:
	_events.append([tick, kind, args])

func _puppet_tick() -> void:
	var ni := player.input as NetworkPlayerInput
	if ni == null:
		return
	if ni.fresh:
		_correct(ni.packet)
	_apply_events(ni.tick if ni.starved_ticks < FLUSH_EVENTS_AFTER and ni.tick >= 0 else 1 << 62)

## Pulls the copy toward where the owner ended up after the same tick.
func _correct(p: Array) -> void:
	player.stamina.value = p[NetCodec.STAMINA]
	if player.is_dead() or player.ragdoll.is_ragdolled():
		return # the ragdoll flops on its own on each machine
	var target: Vector3 = p[NetCodec.POS]
	var err := target - player.global_position
	correction_error = lerpf(correction_error, err.length(), 0.05)
	if err.length() > SNAP_DISTANCE:
		snaps += 1
		player.global_position = target
		player.velocity = p[NetCodec.VEL]
		player.reset_physics_interpolation()
	else:
		player.global_position += err * POS_CORRECTION
		player.velocity = player.velocity.lerp(p[NetCodec.VEL], VEL_CORRECTION)
	if player.state.name != &"turn": # a turn clip owns the facing until it bakes
		player.mesh.rotation.y = lerp_angle(player.mesh.rotation.y, p[NetCodec.MESH_YAW], YAW_CORRECTION)

func _apply_events(upto_tick: int) -> void:
	while not _events.is_empty() and int(_events[0][0]) <= upto_tick:
		var e: Array = _events.pop_front()
		_apply_event(e[1], e[2])

func _apply_event(kind: StringName, a: Array) -> void:
	match kind:
		&"hit":
			var data: Array = a[0]
			var hit := NetCodec.decode_hit(data, net.fighter(NetCodec.hit_attacker_peer(data)))
			player.health.apply_damage(hit, float(a[1]))
		&"hp":
			player.health.set_current(float(a[0]))
		&"respawn":
			_release_from_carrier()
			player.respawn()
			player.global_position = a[0]
			player.mesh.rotation.y = float(a[1])
			player.reset_physics_interpolation()
		&"throw":
			var data := NetCodec.load_item(a[1])
			if data:
				player.hand.throw_replayed(data, a[0], a[2], a[3], a[4], float(a[5]))
		&"pickup":
			var item := get_tree().current_scene.get_node_or_null(NodePath(a[0])) if get_tree().current_scene else null
			if item is ItemPickup:
				if not (item as ItemPickup).try_interact(player):
					(item as ItemPickup).take_away()
			elif item is ThrownItem:
				if not (item as ThrownItem).try_interact(player, true):
					(item as ThrownItem).take_away()
		&"loadout":
			_apply_loadout(a[0], a[1])

## Makes the copy hold and wear exactly what the owner does.
func _apply_loadout(hand_path: String, worn: Dictionary) -> void:
	if NetCodec.item_path(player.held_item) != hand_path:
		player.inventory.clear()
		var want := NetCodec.load_item(hand_path)
		if want:
			player.inventory.add_item(want)
	var slots := player.equipment.list_items().keys()
	for slot in worn:
		if not slot in slots:
			slots.append(slot)
	for slot in slots:
		var want_path: String = worn.get(slot, "")
		if NetCodec.item_path(player.equipment.get_item(slot)) == want_path:
			continue
		player.equipment.unequip(slot)
		var want := NetCodec.load_item(want_path)
		if want:
			player.equipment.equip(want)

## Someone on this machine carries our ragdoll: let go before it respawns.
func _release_from_carrier() -> void:
	var carrier := player.ragdoll.held_by
	if carrier and is_instance_valid(carrier):
		var grabber := carrier.get_node_or_null("RagdollGrabber") as RagdollGrabber
		if grabber:
			grabber.release_grab()

# --- Nameplate ------------------------------------------------------------------------

func _make_nameplate() -> void:
	_nameplate = Label3D.new()
	_nameplate.name = "Nameplate"
	_nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nameplate.no_depth_test = true
	_nameplate.fixed_size = false
	_nameplate.pixel_size = 0.004
	_nameplate.font_size = 44
	_nameplate.outline_size = 10
	_nameplate.position = Vector3(0, 2.2, 0)
	player.add_child(_nameplate)
	_update_nameplate()

func _update_nameplate() -> void:
	if _nameplate == null:
		return
	var hp := player.health
	_nameplate.text = "%s\n%s" % [display_name, "KO" if hp.is_dead else "%d HP" % ceili(hp.current)]
	var t := hp.current / maxf(hp.max_health, 1.0)
	_nameplate.modulate = Color(1, 0.35, 0.3) if t < 0.3 else Color(1, 1, 1)
