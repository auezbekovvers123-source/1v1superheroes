extends CanvasLayer
class_name InventoryUI
## InventoryUI.gd — Pure Minimalist 3D Interactive Inventory.
## Features:
##  - 3D Character in center with real-time breathing Idle animation & physics
##  - Sockets are glowing circles physically attached to 3D body parts and tracked in screen space
##  - Drag to rotate character in 360° with smooth inertia
##  - Sockets smoothly appear / glow when hovering near them
##  - NO text clutter — pure visual focus on the hero and gear
##  - Minimalist sketch-style bottom item tray

const EquipSocketScript = preload("res://Scripts/UI/EquipSocket.gd")
const InventorySlotScript = preload("res://Scripts/UI/InventorySlot.gd")
const C11ModelScene = preload("res://Assets/Models/Characters/С11.glb")
const EquipmentCls = preload("res://Scripts/Item/Equipment.gd")

var player: CharacterBody3D = null
var inventory: Node = null
var equipment: Node = null

var _is_open: bool = false

# UI Nodes
var _root: Control = null
var _overlay: ColorRect = null
var _item_tray: HBoxContainer = null
var _tray_panel: PanelContainer = null
var _socket_container: Control = null

# 3D Viewport Nodes
var _vp_container: SubViewportContainer = null
var _sub_viewport: SubViewport = null
var _preview_model_root: Node3D = null
var _preview_c11: Node3D = null
var _preview_skeleton: Skeleton3D = null
var _preview_ap: AnimationPlayer = null
var _preview_equipment: Equipment = null
var _preview_camera: Camera3D = null

# 3D Body Attachment Anchors
var _body_anchors: Dictionary = {} # slot (int) -> Node3D

# Sockets (EquipSlot int -> EquipSocket)
var _sockets: Dictionary = {}

# 3D Drag-Rotation State
var _is_dragging_3d: bool = false
var _rot_velocity: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
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
			inventory.inventory_changed.connect(_refresh_tray)
		print("[InventoryUI] Connected to player: %s" % player.name)

# ───────────────────────────────────────────────────
#  UI Construction
# ───────────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# 1. Dark Vignette Background
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0.04, 0.04, 0.06, 0.92)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_overlay)

	# 2. 3D Character Viewport (Full Screen Center Stage)
	_build_3d_viewport()

	# 3. Socket Overlay Layer (Screen-space 3D tracking)
	_socket_container = Control.new()
	_socket_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_socket_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_socket_container)

	_build_sockets()

	# 4. Minimalist Bottom Item Tray (Matching Sketch)
	_build_tray()

	_root.resized.connect(_layout)
	call_deferred("_layout")

func _build_3d_viewport() -> void:
	_vp_container = SubViewportContainer.new()
	_vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vp_container.stretch = true
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_vp_container.gui_input.connect(_on_viewport_gui_input)
	_root.add_child(_vp_container)

	_sub_viewport = SubViewport.new()
	_sub_viewport.own_world_3d = true
	_sub_viewport.transparent_bg = true
	_sub_viewport.handle_input_locally = false
	_sub_viewport.msaa_3d = Viewport.MSAA_4X
	_sub_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	_sub_viewport.use_hdr_2d = false
	_vp_container.add_child(_sub_viewport)

	# Environment
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_bloom = 0.2
	env.glow_intensity = 0.5
	env_node.environment = env
	_sub_viewport.add_child(env_node)

	# 3-Point Studio Lighting
	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-25, 35, 0)
	key_light.light_color = Color(1.0, 0.98, 0.94)
	key_light.light_energy = 1.4
	key_light.shadow_enabled = true
	_sub_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-15, -60, 0)
	fill_light.light_color = Color(0.4, 0.65, 0.95)
	fill_light.light_energy = 0.8
	_sub_viewport.add_child(fill_light)

	var rim_light := DirectionalLight3D.new()
	rim_light.rotation_degrees = Vector3(20, 165, 0)
	rim_light.light_color = Color(0.3, 0.9, 1.0)
	rim_light.light_energy = 2.6
	_sub_viewport.add_child(rim_light)

	# Stylized Floor Disc Pedestal
	var pedestal := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.85
	cylinder.bottom_radius = 0.90
	cylinder.height = 0.03
	pedestal.mesh = cylinder
	pedestal.position = Vector3(0, -0.015, 0)
	var ped_mat := StandardMaterial3D.new()
	ped_mat.albedo_color = Color(0.08, 0.10, 0.15)
	ped_mat.metallic = 0.9
	ped_mat.roughness = 0.2
	pedestal.material_override = ped_mat
	_sub_viewport.add_child(pedestal)

	# Glowing Pedestal Rim
	var torus := TorusMesh.new()
	torus.inner_radius = 0.84
	torus.outer_radius = 0.87
	var torus_inst := MeshInstance3D.new()
	torus_inst.mesh = torus
	torus_inst.position = Vector3(0, 0.005, 0)
	var t_mat := StandardMaterial3D.new()
	t_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	t_mat.albedo_color = Color(0.3, 0.85, 1.0)
	torus_inst.material_override = t_mat
	_sub_viewport.add_child(torus_inst)

	# 3D Model Root (Rotated by player drag)
	_preview_model_root = Node3D.new()
	_preview_model_root.name = "CharacterPivot"
	_sub_viewport.add_child(_preview_model_root)

	_preview_c11 = C11ModelScene.instantiate()
	_preview_model_root.add_child(_preview_c11)

	# Discover Skeleton & AnimationPlayer
	_preview_skeleton = _search_skeleton(_preview_c11)
	_preview_ap = _search_animation_player(_preview_c11)
	if _preview_ap and _preview_ap.has_animation("Idle"):
		_preview_ap.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
		_preview_ap.play("Idle")

	# Equipment manager for 3D preview
	_preview_equipment = EquipmentCls.new()
	_preview_equipment.name = "PreviewEquipment"
	_preview_model_root.add_child(_preview_equipment)

	# Setup 3D Body Attachment Anchors
	_setup_body_anchors()

	# Camera3D — Framed so the entire 3D character fits comfortably with clearance
	_preview_camera = Camera3D.new()
	_preview_camera.position = Vector3(0, 0.85, 3.6)
	_preview_camera.fov = 38.0
	_sub_viewport.add_child(_preview_camera)

func _search_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r = _search_skeleton(c)
		if r:
			return r
	return null

func _search_animation_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r = _search_animation_player(c)
		if r:
			return r
	return null

func _setup_body_anchors() -> void:
	# Create 3D anchor points attached to the character rig
	# 1: CAPE (Upper Head / Crown)
	_create_anchor(1, "spine_03.x", Vector3(0.0, 0.48, -0.05), Vector3(0.0, 1.76, 0.0))
	# 2: HELMET (Head center)
	_create_anchor(2, "spine_03.x", Vector3(0.0, 0.30, 0.06), Vector3(0.0, 1.58, 0.05))
	# 3: ARMOR (Chest center / mass)
	_create_anchor(3, "spine_02.x", Vector3(0.0, 0.05, 0.12), Vector3(0.0, 1.25, 0.12))
	# 5: ACCESSORY (Left Hand / Wrist)
	_create_anchor(5, "hand_l.x", Vector3(0.0, 0.0, 0.0), Vector3(0.38, 0.85, 0.02))
	# 4: BOOTS (Right Foot / Ankle)
	_create_anchor(4, "foot_r.x", Vector3(0.0, 0.0, 0.05), Vector3(0.18, 0.10, 0.08))

func _create_anchor(slot_id: int, preferred_bone: String, bone_offset: Vector3, fallback_pos: Vector3) -> void:
	if _preview_skeleton and _preview_skeleton.find_bone(preferred_bone) != -1:
		var ba := BoneAttachment3D.new()
		ba.bone_name = preferred_bone
		_preview_skeleton.add_child(ba)
		var marker := Marker3D.new()
		marker.position = bone_offset
		ba.add_child(marker)
		_body_anchors[slot_id] = marker
	else:
		var marker := Marker3D.new()
		marker.position = fallback_pos
		_preview_model_root.add_child(marker)
		_body_anchors[slot_id] = marker

func _build_sockets() -> void:
	# 5 Glowing Sockets from the sketch (NO text)
	# 1: Cape, 2: Helmet, 3: Armor, 4: Boots, 5: Accessory
	var slots := [1, 2, 3, 4, 5]
	for slot_id in slots:
		var sock := EquipSocket.new(slot_id, 24.0)
		sock.socket_equipped.connect(_on_socket_equipped)
		sock.socket_unequipped.connect(_on_socket_unequipped)
		_sockets[slot_id] = sock
		_socket_container.add_child(sock)

func _build_tray() -> void:
	_tray_panel = PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = Color(0.06, 0.07, 0.10, 0.75)
	t_style.border_color = Color(1, 1, 1, 0.25)
	t_style.set_border_width_all(1)
	t_style.corner_radius_top_left = 10
	t_style.corner_radius_top_right = 10
	t_style.corner_radius_bottom_left = 10
	t_style.corner_radius_bottom_right = 10
	t_style.set_content_margin_all(10)
	_tray_panel.add_theme_stylebox_override("panel", t_style)
	_root.add_child(_tray_panel)

	_item_tray = HBoxContainer.new()
	_item_tray.alignment = BoxContainer.ALIGNMENT_CENTER
	_item_tray.add_theme_constant_override("separation", 14)
	_tray_panel.add_child(_item_tray)

func _layout() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	if vp_size.x < 10 or vp_size.y < 10:
		return

	# Position bottom item tray
	if _tray_panel:
		var tray_w := maxf(_tray_panel.get_combined_minimum_size().x, 340.0)
		var tray_h := maxf(_tray_panel.get_combined_minimum_size().y, 114.0)
		_tray_panel.position = Vector2((vp_size.x - tray_w) / 2.0, vp_size.y - tray_h - 28.0)
		_tray_panel.size = Vector2(tray_w, tray_h)

# ───────────────────────────────────────────────────
#  Real-Time 3D Bone Tracking to Screen Space
# ───────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _is_open:
		return

	# Handle 3D rotation momentum
	if _preview_model_root and not _is_dragging_3d and abs(_rot_velocity) > 0.0001:
		_preview_model_root.rotation.y += _rot_velocity * delta * 60.0
		_rot_velocity = lerp(_rot_velocity, 0.0, delta * 6.0)

	# Track 3D body parts to 2D socket positions
	var mouse_pos := _root.get_viewport().get_mouse_position()
	
	if _preview_camera and _sub_viewport:
		for slot_id in _sockets.keys():
			var sock: EquipSocket = _sockets[slot_id]
			if _body_anchors.has(slot_id):
				var anchor: Node3D = _body_anchors[slot_id]
				if anchor and is_instance_valid(anchor):
					var world_pos := anchor.global_position
					var is_behind := _preview_camera.is_position_behind(world_pos)
					if not is_behind:
						var vp_pos := _preview_camera.unproject_position(world_pos)
						# Align center of socket to body position
						sock.position = vp_pos - (sock.size / 2.0)
						sock.visible = true
					else:
						# Dim or hide when facing completely behind
						sock.visible = false
			
			# Update proximity glow
			sock.update_proximity(mouse_pos, delta)

# ───────────────────────────────────────────────────
#  3D Character Drag-to-Rotate
# ───────────────────────────────────────────────────

func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging_3d = mb.pressed
			if mb.pressed:
				_rot_velocity = 0.0
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if _preview_camera:
				_preview_camera.position.z = clampf(_preview_camera.position.z - 0.25, 2.2, 4.8)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if _preview_camera:
				_preview_camera.position.z = clampf(_preview_camera.position.z + 0.25, 2.2, 4.8)
	elif event is InputEventMouseMotion and _is_dragging_3d:
		var mm := event as InputEventMouseMotion
		if _preview_model_root:
			var rot_delta: float = mm.relative.x * 0.012
			_preview_model_root.rotation.y += rot_delta
			_rot_velocity = mm.velocity.x * 0.0003

# ───────────────────────────────────────────────────
#  Open / Close & Input
# ───────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			toggle()
			get_viewport().set_input_as_handled()

func toggle() -> void:
	if _is_open:
		close_inventory()
	else:
		open_inventory()

func open_inventory() -> void:
	if player == null or inventory == null or equipment == null:
		_find_player()
	_is_open = true
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true
	
	_sync_preview_equipment()
	_refresh_sockets()
	_refresh_tray()
	_layout()

func close_inventory() -> void:
	_is_open = false
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false

func _hide_inventory() -> void:
	_root.visible = false
	_is_open = false

# ───────────────────────────────────────────────────
#  Data Refresh & Equipment Sync
# ───────────────────────────────────────────────────

func _sync_preview_equipment() -> void:
	if _preview_equipment == null or equipment == null:
		return
	_preview_equipment.unequip_all()
	var equipped: Dictionary = equipment.list_equipped()
	for slot_id in equipped.keys():
		var w = equipped[slot_id]
		if w and is_instance_valid(w):
			if w is WearableItem and w.scene_file_path != "":
				var scn = load(w.scene_file_path)
				if scn:
					var p_w = _preview_equipment.equip_wearable(scn, slot_id, w.bone_name)
					if p_w and player and "cloak_color" in player and p_w.has_method("set_color"):
						p_w.set_color(player.get("cloak_color"))

func _refresh_sockets() -> void:
	if equipment == null:
		return
	var equipped: Dictionary = equipment.list_equipped()
	for slot_id in _sockets.keys():
		var sock: EquipSocket = _sockets[slot_id]
		if equipped.has(slot_id):
			var wearable = equipped[slot_id]
			var item_data := _find_item_data_for_wearable(wearable, slot_id)
			sock.set_equipped(item_data)
		else:
			sock.clear_equipped()

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

func _refresh_tray() -> void:
	for child in _item_tray.get_children():
		child.queue_free()
	if inventory == null:
		return
	var items: Array = inventory.get_items()
	for item in items:
		if item is ItemData:
			var slot_ctrl := InventorySlot.new()
			slot_ctrl.drag_started.connect(_on_drag_started)
			slot_ctrl.drag_ended.connect(_on_drag_ended)
			slot_ctrl.item_right_clicked.connect(_on_slot_item_dropped)
			_item_tray.add_child(slot_ctrl)
			slot_ctrl.setup(item)
	call_deferred("_layout")

func _on_slot_item_dropped(item: ItemData) -> void:
	if inventory == null or item == null:
		return
	
	# 1. Remove from inventory
	inventory.remove_item(item)
	
	# 2. Spawn item back in the world
	_spawn_item_pickup_in_world(item)
	
	print("[InventoryUI] Dropped '%s' into the world" % item.display_name)
	_refresh_tray()

func _spawn_item_pickup_in_world(item: ItemData) -> void:
	if player == null or item == null:
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

func _on_drag_started(item: ItemData) -> void:
	for slot_id in _sockets.keys():
		var sock: EquipSocket = _sockets[slot_id]
		sock.is_drag_active_globally = true
		sock.is_valid_drag_target = (item.slot == sock.slot)
		sock.queue_redraw()

func _on_drag_ended() -> void:
	for slot_id in _sockets.keys():
		var sock: EquipSocket = _sockets[slot_id]
		sock.is_drag_active_globally = false
		sock.is_valid_drag_target = false
		sock.queue_redraw()

# ───────────────────────────────────────────────────
#  Equip / Unequip Logic
# ───────────────────────────────────────────────────

func _on_socket_equipped(slot: int, item: ItemData) -> void:
	if equipment == null or inventory == null:
		return

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

	_sync_preview_equipment()
	_refresh_sockets()
	_refresh_tray()

func _on_socket_unequipped(slot: int, item: ItemData) -> void:
	if equipment == null or inventory == null:
		return

	equipment.unequip_slot(slot)
	if slot == ItemData.EquipSlot.CAPE and player and "cloak" in player:
		player.set("cloak", null)

	inventory.add_item(item)
	print("[InventoryUI] Unequipped '%s' from slot %d" % [item.display_name, slot])

	_sync_preview_equipment()
	_refresh_sockets()
	_refresh_tray()
