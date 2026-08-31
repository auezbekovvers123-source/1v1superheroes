extends CanvasLayer
class_name InventoryUI
## InventoryUI.gd — TAB inventory presented IN THE LIVING GAME WORLD.
##  - TAB smoothly swings the gameplay camera around to face the character's front
##    (handled by SpringArmPivot.set_inventory_mode). The game does NOT pause —
##    physics, cloth sim and the world keep running; only player input is gated.
##  - Primary inventory (single HAND slot) is flat screen-space UI — a tray at the bottom
##  - Equip sockets are glowing circular rings rendered in world space, attached
##    directly to the character model's bones (EquipSocket3D billboard quads)
##  - Custom drag & drop bridges both surfaces:
##      tray item (2D)  -> ring (3D)     = equip
##      ring gear (3D)  -> tray (2D)     = unequip into HAND
##      click a ring (3D)                = quick-unequip into HAND

const EquipSocket3DScript = preload("res://Scripts/UI/EquipSocket3D.gd")
const InventorySlotScript = preload("res://Scripts/UI/InventorySlot.gd")

var player: CharacterBody3D = null
var inventory: Node = null
var equipment: Node = null

var _is_open: bool = false

# Screen-space UI
var _root: Control = null
var _item_tray: HBoxContainer = null
var _ghost: DragGhost = null

# World-space sockets attached to the player model
var _socket_root: Node3D = null
var _skeleton: Skeleton3D = null
var _sockets: Dictionary = {} # slot (int) -> EquipSocket3D
var _anchors: Dictionary = {} # slot (int) -> Node3D (bone marker)

# Custom cross-surface drag state
var _drag_item: ItemData = null
var _drag_source_socket: EquipSocket3D = null
var _drag_source_slot: Control = null
var _drag_active: bool = false
var _drag_press_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	add_to_group("inventory_ui") # Player gates its input while this is open
	_build_ui()
	_hide_inventory()

	await get_tree().process_frame
	await get_tree().process_frame
	_find_player()

func _find_player() -> void:
	var scene_root := get_tree().current_scene
	if scene_root:
		player = scene_root.get_node_or_null("Prototype/Player") as CharacterBody3D
		if player == null:
			player = scene_root.get_node_or_null("Player") as CharacterBody3D
	if player == null:
		var fighters := get_tree().get_nodes_in_group("fighter")
		for f in fighters:
			if f is CharacterBody3D and f.has_node("Equipment"):
				player = f as CharacterBody3D
				break
	if player:
		inventory = player.get_node_or_null("Inventory")
		equipment = player.get_node_or_null("Equipment")
		if inventory and inventory.has_signal("inventory_changed"):
			if not inventory.inventory_changed.is_connected(_refresh_tray):
				inventory.inventory_changed.connect(_refresh_tray)
		if inventory and inventory.has_signal("held_item_changed"):
			if not inventory.held_item_changed.is_connected(_on_held_via_inventory):
				inventory.held_item_changed.connect(_on_held_via_inventory)
		print("[InventoryUI] Connected to player: %s" % player.name)

func _on_held_via_inventory(_item: ItemData) -> void:
	_refresh_tray()
	_refresh_sockets()

# ───────────────────────────────────────────────────
#  UI Construction (screen space)
# ───────────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE: clicks must fall through to the world-space socket hit-testing in _input
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_tray()

	# Drag ghost — glowing circle that follows the cursor over BOTH surfaces
	_ghost = DragGhost.new()
	_ghost.size = Vector2(72, 72)
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.visible = false
	_root.add_child(_ghost)

	_root.resized.connect(_layout)
	call_deferred("_layout")

func _build_tray() -> void:
	# Minimalist: a single floating HAND slot at bottom-center — no panel, no text
	_item_tray = HBoxContainer.new()
	_item_tray.alignment = BoxContainer.ALIGNMENT_CENTER
	_item_tray.add_theme_constant_override("separation", 14)
	_item_tray.mouse_filter = Control.MOUSE_FILTER_PASS # children (slots) handle clicks
	_root.add_child(_item_tray)

func _layout() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	if vp_size.x < 10 or vp_size.y < 10:
		return
	if _item_tray:
		var tray_size := _item_tray.get_combined_minimum_size().max(Vector2(80, 88))
		_item_tray.size = tray_size
		_item_tray.position = Vector2((vp_size.x - tray_size.x) / 2.0, vp_size.y - tray_size.y - 26.0)

## Tray area (grown for forgiving drops) used for 3D-ring -> 2D-tray unequip targeting
func _tray_drop_rect() -> Rect2:
	if _item_tray == null or not is_instance_valid(_item_tray) or _item_tray.get_child_count() == 0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	return _item_tray.get_global_rect().grow(48.0)

# ───────────────────────────────────────────────────
#  World-Space Sockets on the Character Model
# ───────────────────────────────────────────────────

func _ensure_sockets() -> void:
	if _socket_root and is_instance_valid(_socket_root):
		return
	if player == null:
		return
	_skeleton = _search_skeleton(player)
	if _skeleton == null:
		push_warning("[InventoryUI] No Skeleton3D found on player — sockets disabled")
		return
	_socket_root = Node3D.new()
	_socket_root.name = "InventorySockets"
	_skeleton.add_child(_socket_root)

	# 1: CAPE (upper back), 2: HELMET (head), 3: ARMOR (chest),
	# 4: BOOTS (right foot), 5: ACCESSORY (left hand), 6: HAND (right hand, display-only)
	_create_socket(1, "spine_03.x", Vector3(0.0, 0.48, -0.05), Vector3(0.0, 1.76, 0.0), 0.10)
	_create_socket(2, "spine_03.x", Vector3(0.0, 0.30, 0.06), Vector3(0.0, 1.58, 0.05), 0.10)
	_create_socket(3, "spine_02.x", Vector3(0.0, 0.05, 0.12), Vector3(0.0, 1.25, 0.12), 0.10)
	_create_socket(5, "hand_l.x", Vector3(0.0, 0.0, 0.0), Vector3(0.38, 0.85, 0.02), 0.09)
	_create_socket(4, "foot_r.x", Vector3(0.0, 0.0, 0.05), Vector3(0.18, 0.10, 0.08), 0.09)
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

func _search_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r = _search_skeleton(c)
		if r:
			return r
	return null

# ───────────────────────────────────────────────────
#  Per-Frame: project sockets to screen, drive drag feedback
# ───────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _is_open:
		return

	# Move the drag ghost with the cursor (works over 2D and 3D alike)
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
		sock.update_state(delta, mouse, _drag_item, _drag_source_socket != null)

# ───────────────────────────────────────────────────
#  Input: TAB toggle + custom cross-surface drag
# ───────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
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

func _try_begin_socket_drag() -> void:
	var mp := _root.get_viewport().get_mouse_position()
	# Presses over the tray belong to the tray slots (they start their own drags)
	if _tray_drop_rect().has_point(mp):
		return
	if _drag_active:
		return
	var sock := _socket_at(mp)
	if sock and sock.equipped_item != null and sock.slot != ItemData.EquipSlot.HAND:
		_begin_drag(sock.equipped_item, sock, null)

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

func _begin_drag(item: ItemData, source_socket: EquipSocket3D, source_slot: Control) -> void:
	if item == null or _drag_active:
		return
	_drag_item = item
	_drag_source_socket = source_socket
	_drag_source_slot = source_slot
	_drag_active = true
	_drag_press_pos = _root.get_viewport().get_mouse_position()
	if _ghost:
		_ghost.color = item.preview_color
		_ghost.visible = true
	if source_slot:
		source_slot.modulate = Color(1, 1, 1, 0.35)
	print("[InventoryUI] Drag started: '%s' (from %s)" % [item.display_name, "socket" if source_socket else "tray"])

func _end_drag() -> void:
	if not _drag_active or _drag_item == null:
		_cancel_drag()
		return
	var item := _drag_item
	var source_socket := _drag_source_socket
	var mp := _root.get_viewport().get_mouse_position()
	var moved := mp.distance_to(_drag_press_pos)
	var target_sock := _socket_at(mp)

	if source_socket == null:
		# ── 2D tray → 3D ring: equip ──
		if target_sock and target_sock.slot == item.slot and target_sock.slot != ItemData.EquipSlot.HAND:
			_on_socket_equipped(target_sock.slot, item)
		# else: released nowhere valid → item stays in the tray
	else:
		# ── 3D ring → 2D tray: unequip into HAND ──
		var over_tray := _tray_drop_rect().has_point(mp)
		var clicked_same := moved < 8.0 and target_sock == source_socket
		if over_tray or clicked_same:
			if inventory and not inventory.can_pickup():
				print("[InventoryUI] HAND full — drop it (G) before storing gear")
			else:
				_on_socket_unequipped(source_socket.slot, item)

	# Restore tray slot visuals
	if _drag_source_slot and is_instance_valid(_drag_source_slot):
		_drag_source_slot.modulate = Color.WHITE
	_drag_item = null
	_drag_source_socket = null
	_drag_source_slot = null
	_drag_active = false
	if _ghost:
		_ghost.visible = false
	_refresh_tray()
	_refresh_sockets()

func _cancel_drag() -> void:
	if _drag_source_slot and is_instance_valid(_drag_source_slot):
		_drag_source_slot.modulate = Color.WHITE
	_drag_item = null
	_drag_source_socket = null
	_drag_source_slot = null
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

## Player.gd polls this to gate WASD/jump/keys while the inventory owns the mouse.
func is_inventory_open() -> bool:
	return _is_open

func open_inventory() -> void:
	if player == null or inventory == null or equipment == null:
		_find_player()
	_is_open = true
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Game keeps running (no pause) — only player input is gated via the group

	# Smoothly swing the gameplay camera to face the character's front
	var pivot: Node = player.get_node_or_null("SpringArmPivot") if player else null
	if pivot and pivot.has_method("set_inventory_mode"):
		pivot.set_inventory_mode(true)

	_ensure_sockets()
	_set_sockets_visible(true)
	_refresh_sockets()
	_refresh_tray()
	_layout()

func close_inventory() -> void:
	_is_open = false
	_cancel_drag()
	_set_sockets_visible(false)
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var pivot: Node = player.get_node_or_null("SpringArmPivot") if player else null
	if pivot and pivot.has_method("set_inventory_mode"):
		pivot.set_inventory_mode(false)

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
	if _sockets.is_empty():
		return
	# Equipment sockets (1-5)
	if equipment != null:
		var equipped: Dictionary = equipment.list_equipped()
		for slot_id in _sockets.keys():
			if slot_id == 6:
				continue # HAND socket mirrors the inventory below
			var sock: EquipSocket3D = _sockets[slot_id]
			if equipped.has(slot_id) and equipped[slot_id] != null:
				sock.set_equipped(_find_item_data_for_wearable(equipped[slot_id], slot_id))
			else:
				sock.clear_equipped()
	# HAND socket (6) displays the inventory's held item
	if _sockets.has(6):
		var held = inventory.get_held_item() if inventory and inventory.has_method("get_held_item") else null
		if held:
			_sockets[6].set_equipped(held)
		else:
			_sockets[6].clear_equipped()

func _refresh_tray() -> void:
	for child in _item_tray.get_children():
		child.queue_free()
	if inventory == null:
		return
	var items: Array = inventory.get_items()
	for item in items:
		if item is ItemData:
			var slot_ctrl := InventorySlot.new()
			slot_ctrl.drag_started.connect(_on_tray_drag_started.bind(slot_ctrl))
			slot_ctrl.item_right_clicked.connect(_on_slot_item_dropped)
			_item_tray.add_child(slot_ctrl)
			slot_ctrl.setup(item, Vector2(96, 104))
	# Empty placeholder slot visual when empty (single HAND slot)
	if items.is_empty():
		var empty := InventorySlot.new()
		var placeholder := ItemData.new()
		placeholder.display_name = "EMPTY"
		placeholder.preview_color = Color(1, 1, 1, 0.12)
		empty.setup(placeholder, Vector2(96, 104))
		empty.modulate = Color(1, 1, 1, 0.5)
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_item_tray.add_child(empty)
	call_deferred("_layout")

func _on_tray_drag_started(item: ItemData, slot_ctrl: Control) -> void:
	if _drag_active:
		slot_ctrl.modulate = Color.WHITE
		return
	_begin_drag(item, null, slot_ctrl)

func _find_item_data_for_wearable(wearable: Node, slot_id: int) -> ItemData:
	if wearable and "item_id" in wearable:
		var wearable_id: String = wearable.get("item_id")
		if wearable_id == "cloak_01":
			var res = load("res://Assets/Item/Cloak Assets/cloak_item.tres")
			if res is ItemData:
				return res
		var data := ItemData.new()
		data.id = wearable_id
		data.display_name = wearable.get("item_name") if "item_name" in wearable else wearable_id
		data.slot = slot_id
		if wearable is WearableItem:
			data.scene = load(wearable.scene_file_path) if wearable.scene_file_path != "" else null
			data.bone_name = wearable.bone_name
		data.preview_color = Color(0.78, 0.12, 0.12)
		return data
	var data := ItemData.new()
	data.id = "unknown_%d" % slot_id
	data.display_name = "Item"
	data.slot = slot_id
	data.preview_color = Color(0.5, 0.5, 0.5)
	return data

# ───────────────────────────────────────────────────
#  Drop Item Into The World (right-click in tray)
# ───────────────────────────────────────────────────

func _on_slot_item_dropped(item: ItemData) -> void:
	if inventory == null or item == null:
		return
	# If player currently holds this exact item, delegate to player's drop (handles hand attachment & spawn)
	if player and player.has_method("is_holding_item") and player.has_method("drop_held_item"):
		if player.call("is_holding_item"):
			var held = player.get("held_item") as ItemData
			if held == item:
				player.call("drop_held_item")
				print("[InventoryUI] Dropped '%s' via HAND drop" % item.display_name)
				_refresh_tray()
				_refresh_sockets()
				return
	# 1. Remove from inventory
	inventory.remove_item(item)
	# 2. Spawn item back in the world
	_spawn_item_pickup_in_world(item)
	print("[InventoryUI] Dropped '%s' into the world" % item.display_name)
	_refresh_tray()
	_refresh_sockets()

func _spawn_item_pickup_in_world(item: ItemData) -> void:
	if player == null or item == null:
		return
	# Prefer player's hand drop logic if holding
	if player and player.has_method("is_holding_item") and player.call("is_holding_item"):
		var held = player.get("held_item")
		if held == item and player.has_method("drop_held_item"):
			player.call("drop_held_item")
			return
	# Calculate world spawn position (in front of player)
	var spawn_pos: Vector3 = player.global_position
	var forward: Vector3 = Vector3.FORWARD
	if player.has_node("Mesh"):
		var m: Node3D = player.get_node("Mesh") as Node3D
		forward = m.global_transform.basis.z.normalized()
	elif player.has_node("SpringArmPivot"):
		forward = Vector3.FORWARD.rotated(Vector3.UP, player.get_node("SpringArmPivot").rotation.y)
	forward.y = 0.0
	if forward.length() > 0.1:
		spawn_pos += forward.normalized() * 1.6
	spawn_pos.y += 0.5
	# Load pickup scene
	var pickup_scene: PackedScene = null
	if item.id == "cloak_01":
		pickup_scene = load("res://Scenes/Items/CloakPickup.tscn")
	elif item.id == "usable_01":
		pickup_scene = load("res://Scenes/Items/UsablePickup.tscn")
	elif item.id == "holdable_01":
		pickup_scene = load("res://Scenes/Items/RockPickup.tscn")
	elif item.slot == ItemData.EquipSlot.HAND:
		if item.is_usable:
			pickup_scene = load("res://Scenes/Items/UsablePickup.tscn")
		else:
			pickup_scene = load("res://Scenes/Items/RockPickup.tscn")
	var inst: Node3D = null
	if pickup_scene:
		inst = pickup_scene.instantiate() as Node3D
	else:
		var pickup_script = load("res://Scripts/Item/ItemPickup.gd")
		var area = Area3D.new()
		area.set_script(pickup_script)
		inst = area
	if inst:
		inst.set("item_data", item)
		inst.set("item_name", item.display_name)
		inst.set("item_id", item.id)
		inst.set("wearable_scene", item.scene)
		inst.set("equip_slot", item.slot)
		inst.set("pickup_color", item.preview_color)
		inst.set("auto_pickup", false)
		inst.set("require_interact", true)
		inst.set("pickup_radius", 2.0)
		var level = get_tree().current_scene
		if level:
			level.add_child(inst)
			inst.global_position = spawn_pos
			print("[InventoryUI] Spawned pickup in world at: ", spawn_pos)

# ───────────────────────────────────────────────────
#  Equip / Unequip Logic
# ───────────────────────────────────────────────────

func _on_socket_equipped(slot: int, item: ItemData) -> void:
	if equipment == null or inventory == null:
		return
	if slot == ItemData.EquipSlot.HAND:
		return # HAND ring is display-only; the item is already in the tray

	var old_wearable = equipment.get_equipped(slot)
	if old_wearable and is_instance_valid(old_wearable):
		var old_data := _find_item_data_for_wearable(old_wearable, slot)
		equipment.unequip_slot(slot)
		if old_data:
			inventory.add_item(old_data)

	inventory.remove_item(item)

	if item.scene:
		var wearable = equipment.equip_wearable(item.scene, slot, item.bone_name)
		if wearable:
			if slot == ItemData.EquipSlot.CAPE and player and "cloak" in player:
				player.set("cloak", wearable)
				if wearable.has_method("set_color") and "cloak_color" in player:
					wearable.set_color(player.get("cloak_color"))
			print("[InventoryUI] Equipped '%s' in slot %d" % [item.display_name, slot])
		else:
			inventory.add_item(item)
			push_warning("[InventoryUI] Failed to equip '%s'" % item.display_name)

	_refresh_sockets()
	_refresh_tray()

func _on_socket_unequipped(slot: int, item: ItemData) -> void:
	if equipment == null or inventory == null:
		return
	if slot == ItemData.EquipSlot.HAND:
		return # held item lives in the tray already

	equipment.unequip_slot(slot)
	if slot == ItemData.EquipSlot.CAPE and player and "cloak" in player:
		player.set("cloak", null)

	inventory.add_item(item)
	print("[InventoryUI] Unequipped '%s' from slot %d" % [item.display_name, slot])

	_refresh_sockets()
	_refresh_tray()

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
