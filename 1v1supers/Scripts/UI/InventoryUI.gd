extends CanvasLayer
class_name InventoryUI
## InventoryUI.gd — TAB inventory presented IN THE LIVING GAME WORLD.
##  - TAB smoothly swings the gameplay camera around to face the character's front
##    (handled by SpringArmPivot.set_inventory_mode). The game does NOT pause —
##    physics, cloth sim and the world keep running; only player input is gated.
##  - NO screen-space tray. The single HAND inventory is the glowing ring on the
##    character's RIGHT HAND (slot 6) — same visual language as the equip sockets.
##  - Equip sockets are glowing circular rings rendered in world space, attached
##    directly to the character model's bones (EquipSocket3D billboard quads)
##  - Drag & drop is entirely world→world between the HAND ring and equip rings:
##      HAND ring (6) -> equip ring (1-5) = equip
##      equip ring (1-5) -> HAND ring (6)  = unequip into HAND
##      click a ring (3D)                  = quick-unequip into HAND (or equip if from HAND)

const EquipSocket3DScript = preload("res://Scripts/UI/EquipSocket3D.gd")

var player: Player = null

var _is_open: bool = false

# Screen-space UI (only ghost; no tray)
var _root: Control = null
var _ghost: DragGhost = null

# World-space sockets attached to the player model
var _socket_root: Node3D = null
var _skeleton: Skeleton3D = null
var _sockets: Dictionary = {} # slot (int) -> EquipSocket3D
var _anchors: Dictionary = {} # slot (int) -> Node3D (bone marker)

# Cross-surface drag state (now purely world sockets)
var _drag_item: ItemData = null
var _drag_source_socket: EquipSocket3D = null
var _drag_active: bool = false
var _drag_press_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	_build_ui()
	_hide_inventory()

	await get_tree().process_frame
	await get_tree().process_frame
	_find_player()

func _find_player() -> void:
	player = get_tree().get_first_node_in_group("local_player") as Player
	if player and not player.inventory.inventory_changed.is_connected(_refresh_sockets):
		player.inventory.inventory_changed.connect(_refresh_sockets)
		player.inventory.held_item_changed.connect(_on_held_via_inventory)
		player.equipment.item_equipped.connect(func(_s, _i): _refresh_sockets())
		player.equipment.item_unequipped.connect(func(_s, _i): _refresh_sockets())

func _on_held_via_inventory(_item: ItemData) -> void:
	_refresh_sockets()

# ───────────────────────────────────────────────────
#  UI Construction (screen space) — ghost only, no tray
# ───────────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE: clicks must fall through to the world-space socket hit-testing in _input
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Drag ghost — glowing circle that follows the cursor over world rings
	_ghost = DragGhost.new()
	_ghost.size = Vector2(72, 72)
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.visible = false
	_root.add_child(_ghost)

# ───────────────────────────────────────────────────
#  World-Space Sockets on the Character Model
# ───────────────────────────────────────────────────

func _ensure_sockets() -> void:
	if _socket_root and is_instance_valid(_socket_root):
		return
	if player == null:
		return
	_skeleton = player.get_skeleton()
	if _skeleton == null:
		push_warning("[InventoryUI] No Skeleton3D found on player — sockets disabled")
		return
	_socket_root = Node3D.new()
	_socket_root.name = "InventorySockets"
	_skeleton.add_child(_socket_root)

	# 1: CAPE (upper back), 2: HELMET (head), 3: ARMOR (chest),
	# 4: BOOTS (right foot), 5: ACCESSORY (left hand), 6: HAND (right hand — the inventory)
	_create_socket(1, "spine_03.x", Vector3(0.0, 0.48, -0.05), Vector3(0.0, 1.76, 0.0), 0.10)
	_create_socket(2, "spine_03.x", Vector3(0.0, 0.30, 0.06), Vector3(0.0, 1.58, 0.05), 0.10)
	_create_socket(3, "spine_02.x", Vector3(0.0, 0.05, 0.12), Vector3(0.0, 1.25, 0.12), 0.10)
	_create_socket(5, "hand.l", Vector3(0.0, 0.0, 0.0), Vector3(0.38, 0.85, 0.02), 0.09)
	_create_socket(4, "foot.r", Vector3(0.0, 0.0, 0.05), Vector3(0.18, 0.10, 0.08), 0.09)
	_create_socket(6, "hand.r", Vector3(0.02, -0.02, 0.06), Vector3(0.42, 0.92, 0.08), 0.12)

func _create_socket(slot_id: int, preferred_bone: String, bone_offset: Vector3, fallback_pos: Vector3, world_radius: float) -> void:
	var marker: Node3D = null
	if _skeleton and _skeleton.find_bone(preferred_bone) != -1:
		var ba := BoneAttachment3D.new()
		ba.bone_name = preferred_bone
		_skeleton.add_child(ba)
		marker = Marker3D.new()
		marker.position = bone_offset
		ba.add_child(marker)
	else:
		marker = Marker3D.new()
		marker.position = fallback_pos
		_socket_root.add_child(marker)
	var sock: EquipSocket3D = EquipSocket3DScript.new(slot_id, world_radius)
	marker.add_child(sock)
	sock.anchor = marker
	_anchors[slot_id] = marker
	_sockets[slot_id] = sock

# ───────────────────────────────────────────────────
#  Per-Frame: project sockets to screen, drive drag feedback
# ───────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _is_open:
		return

	# Move the drag ghost with the cursor
	if _drag_active and _ghost:
		_ghost.position = _root.get_viewport().get_mouse_position() - _ghost.size / 2.0

	# Project every world-space ring to screen space & update its visuals
	var cam := get_viewport().get_camera_3d()
	var mouse := _root.get_viewport().get_mouse_position()
	for slot_id in _sockets.keys():
		var sock: EquipSocket3D = _sockets[slot_id]
		var anchor: Node3D = _anchors.get(slot_id)
		if sock == null or anchor == null or not is_instance_valid(anchor):
			continue
		if cam == null:
			sock.visible_on_screen = false
			continue
		var world_pos: Vector3 = anchor.global_position
		if cam.is_position_behind(world_pos):
			sock.visible_on_screen = false
		else:
			sock.visible_on_screen = true
			sock.screen_position = cam.unproject_position(world_pos)
			var right: Vector3 = cam.global_transform.basis.x
			sock.screen_radius = sock.screen_position.distance_to(cam.unproject_position(world_pos + right * sock.radius))
		sock.update_state(delta, mouse, _drag_item, _drag_source_socket)

# ───────────────────────────────────────────────────
#  Input: TAB toggle + world-socket drag
# ───────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory") and not event.is_echo():
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not _is_open:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_begin_socket_drag()
		else:
			if _drag_active:
				_end_drag()
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Right-click HAND ring to drop held item into world (alternative to G)
		var mp := _root.get_viewport().get_mouse_position()
		var sock := _socket_at(mp)
		if sock and sock.slot == ItemData.EquipSlot.HAND and sock.equipped_item != null:
			_on_hand_right_clicked(sock.equipped_item)
			get_viewport().set_input_as_handled()

func _try_begin_socket_drag() -> void:
	var mp := _root.get_viewport().get_mouse_position()
	if _drag_active:
		return
	var sock := _socket_at(mp)
	# Any socket with an item (including HAND) can start a drag
	if sock and sock.equipped_item != null:
		_begin_drag(sock.equipped_item, sock)

func _socket_at(mp: Vector2) -> EquipSocket3D:
	var best: EquipSocket3D = null
	var best_dist: float = INF
	for slot_id in _sockets.keys():
		var sock: EquipSocket3D = _sockets[slot_id]
		if not sock.visible_on_screen:
			continue
		var d := mp.distance_to(sock.screen_position)
		if d <= maxf(sock.screen_radius * 1.3, 26.0) and d < best_dist:
			best_dist = d
			best = sock
	return best

func _begin_drag(item: ItemData, source_socket: EquipSocket3D) -> void:
	if item == null or _drag_active:
		return
	_drag_item = item
	_drag_source_socket = source_socket
	_drag_active = true
	_drag_press_pos = _root.get_viewport().get_mouse_position()
	if _ghost:
		_ghost.color = item.preview_color
		_ghost.visible = true

func _end_drag() -> void:
	if not _drag_active or _drag_item == null:
		_cancel_drag()
		return
	var item := _drag_item
	var source_socket := _drag_source_socket
	var mp := _root.get_viewport().get_mouse_position()
	var moved := mp.distance_to(_drag_press_pos)
	var target_sock := _socket_at(mp)

	# Click without drag (moved < 8) on same socket = quick action
	var clicked_same := moved < 8.0 and target_sock == source_socket

	if source_socket and source_socket.slot == ItemData.EquipSlot.HAND:
		# ── HAND (6) → equip ring (1-5): equip ──
		if target_sock and target_sock.slot == item.slot and target_sock.slot != ItemData.EquipSlot.HAND:
			player.equip_from_hand(target_sock.slot)
		elif clicked_same:
			# Click HAND alone — no equip target: optionally drop (handled by right-click) so do nothing
			pass
		# else: released nowhere valid → stays in HAND
	else:
		# ── Equip ring (1-5) → HAND (6): unequip into HAND ──
		if target_sock and target_sock.slot == ItemData.EquipSlot.HAND:
			player.unequip_to_hand(source_socket.slot) # fails while the hand is full
		elif clicked_same:
			# Click the equip ring itself: quick-unequip to HAND
			player.unequip_to_hand(source_socket.slot)
		# else: dropped nowhere valid → stays equipped

	_drag_item = null
	_drag_source_socket = null
	_drag_active = false
	if _ghost:
		_ghost.visible = false
	_refresh_sockets()

func _cancel_drag() -> void:
	_drag_item = null
	_drag_source_socket = null
	_drag_active = false
	if _ghost:
		_ghost.visible = false

# ───────────────────────────────────────────────────
#  Open / Close
# ───────────────────────────────────────────────────

func toggle() -> void:
	if _is_open:
		close_inventory()
	else:
		open_inventory()

func is_inventory_open() -> bool:
	return _is_open

func open_inventory() -> void:
	if player == null:
		_find_player()
	if player == null:
		return
	_is_open = true
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# The game keeps running (no pause). The UI owns the mouse now: the fighter ignores its input, the camera swings
	# round to face the character's front
	player.input.enabled = false
	player.camera_rig.set_inventory_mode(true)

	_ensure_sockets()
	_set_sockets_visible(true)
	_refresh_sockets()

func close_inventory() -> void:
	_is_open = false
	_cancel_drag()
	_set_sockets_visible(false)
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if player:
		player.input.enabled = true
		player.camera_rig.set_inventory_mode(false)

## Bone-attached sockets live under BoneAttachment3D nodes on the skeleton, NOT
## under _socket_root — so visibility must be toggled per socket, not just on the root.
func _set_sockets_visible(v: bool) -> void:
	if _socket_root:
		_socket_root.visible = v
	for slot_id in _sockets.keys():
		var sock: Node3D = _sockets[slot_id]
		if sock:
			sock.visible = v

func _hide_inventory() -> void:
	_root.visible = false
	_is_open = false

# ───────────────────────────────────────────────────
#  Data Refresh
# ───────────────────────────────────────────────────

func _refresh_sockets() -> void:
	if _sockets.is_empty() or player == null:
		return
	# Equip rings (1-5) show what is worn; the HAND ring (6) shows the held item
	var worn: Dictionary = player.equipment.list_items()
	for slot_id in _sockets.keys():
		var item: ItemData = player.held_item if slot_id == ItemData.EquipSlot.HAND else worn.get(slot_id)
		if item:
			_sockets[slot_id].set_equipped(item)
		else:
			_sockets[slot_id].clear_equipped()

# Right-click the HAND ring: drop the held item into the world (same as a light G throw)
func _on_hand_right_clicked(_item: ItemData) -> void:
	player.drop_held_item()
	_refresh_sockets()

# ───────────────────────────────────────────────────
#  Drag Ghost (screen-space circle following the cursor)
# ───────────────────────────────────────────────────

class DragGhost:
	extends Control
	var color: Color = Color.WHITE
	var _t: float = 0.0

	func _process(delta: float) -> void:
		if visible:
			_t += delta * 6.0
			queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var r := 24.0 + sin(_t) * 1.5
		draw_circle(c, r + 7.0, Color(color.r, color.g, color.b, 0.22))
		draw_circle(c, r + 3.0, Color(color.r, color.g, color.b, 0.45))
		draw_circle(c, r, color)
		draw_arc(c, r, 0, TAU, 40, Color.WHITE, 2.0)
		draw_circle(c + Vector2(-r * 0.3, -r * 0.3), r * 0.25, Color(1, 1, 1, 0.6))
