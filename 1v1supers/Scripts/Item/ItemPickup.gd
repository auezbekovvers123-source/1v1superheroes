extends Area3D
class_name ItemPickup
## ItemPickup.gd — World item that player can pick up to equip wearable
## Auto-bob + rotate, triggers on body_entered. Supports respawn.

signal picked_up(picker: Node, item_id: String)

@export_group("Item")
@export var item_name: String = "Cloak"
@export var item_id: String = "cloak_01"
@export var wearable_scene: PackedScene
@export var equip_slot: int = 1 # ItemData.EquipSlot.CAPE
@export var bone_name: String = "spine_03.x"
@export var pickup_color: Color = Color(0.78, 0.12, 0.12, 1)
@export var item_data: ItemData  ## Link to ItemData resource for inventory system

@export_group("Pickup")
@export var auto_pickup: bool = false
@export var require_interact: bool = true
@export var respawn_time: float = 0.0 # 0 = no respawn, destroy
@export var pickup_radius: float = 2.0
@export var bob_amplitude: float = 0.18
@export var bob_speed: float = 1.6
@export var rotation_speed: float = 45.0 # degrees per second
@export var pickup_scale: Vector3 = Vector3(0.145, 0.145, 0.145) # world display scale

var _mesh: MeshInstance3D = null
var _base_y: float = 0.0
var _time: float = 0.0
var _picked: bool = false
var _inside_bodies: Array[Node3D] = []

func _ready() -> void:
	# Ensure monitoring
	monitoring = true
	monitorable = true
	collision_layer = 0
	collision_mask = 1 # player on layer 1
	# Find mesh for bobbing
	_mesh = find_child("PickupMesh", true, false) as MeshInstance3D
	if _mesh == null:
		_mesh = get_node_or_null("MeshInstance3D") as MeshInstance3D
	if _mesh == null:
		for c in get_children():
			if c is MeshInstance3D:
				_mesh = c as MeshInstance3D
				break
	# Setup collision shape if missing
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape == null:
		col_shape = CollisionShape3D.new()
		col_shape.name = "CollisionShape3D"
		var sph := SphereShape3D.new()
		sph.radius = pickup_radius
		col_shape.shape = sph
		add_child(col_shape)
		col_shape.owner = owner if owner else self
	else:
		if col_shape.shape is SphereShape3D:
			(col_shape.shape as SphereShape3D).radius = pickup_radius
	# Remember base y for bob
	_base_y = position.y
	if _mesh:
		_base_y = _mesh.position.y
		# Ensure pickup mesh uses pickup_scale (world view) even if wearable scale differs
		_mesh.scale = pickup_scale
		# Apply color if material is ShaderMaterial
		var mat := _mesh.material_override as ShaderMaterial
		if mat == null:
			mat = _mesh.get_surface_override_material(0) as ShaderMaterial
		if mat and mat.has_method("set_shader_parameter"):
			# try set color
			if mat.shader and "color" in mat.shader.get_shader_uniform_list().map(func(u): return u.name):
				mat.set_shader_parameter("color", pickup_color)
	connect("body_entered", _on_body_entered)
	connect("body_exited", _on_body_exited)
	add_to_group("pickup")
	add_to_group("item_pickup")

func _process(delta: float) -> void:
	if _picked and respawn_time <= 0.0:
		return
	_time += delta
	if _mesh and not _picked:
		# Bob
		var y_off: float = sin(_time * bob_speed) * bob_amplitude
		_mesh.position.y = _base_y + y_off
		# Rotate
		_mesh.rotation.y += deg_to_rad(rotation_speed) * delta
	# Interact check
	if require_interact and not auto_pickup and not _picked:
		if _inside_bodies.size() > 0 and (Input.is_key_pressed(KEY_F) or Input.is_action_just_pressed("interact")):
			for body in _inside_bodies:
				if _is_player(body):
					if body.has_method("_try_interact_pickup"):
						body.call("_try_interact_pickup")
					else:
						_try_pickup(body)
					break

func _on_body_entered(body: Node3D) -> void:
	if _picked:
		return
	if not _is_player(body):
		return
	if not _inside_bodies.has(body):
		_inside_bodies.append(body)
	if auto_pickup and not require_interact:
		_try_pickup(body)
	# else wait for interact

func _on_body_exited(body: Node3D) -> void:
	_inside_bodies.erase(body)

func _is_player(body: Node) -> bool:
	if body == null:
		return false
	# Check group or method
	if body.is_in_group("player"):
		return true
	if body.is_in_group("fighter") and body is CharacterBody3D:
		# Assume player if it has equipment/cloak logic
		if body.has_method("equip_cloak") or body.has_method("toggle_cloak") or body.get_node_or_null("Equipment") != null:
			return true
		# Fallback: name == Player
		if body.name == "Player":
			return true
	return false

func _get_or_create_item_data() -> ItemData:
	if item_data != null:
		return item_data
	if item_id == "cloak_01" or (wearable_scene != null and "Cloak" in wearable_scene.resource_path):
		var res = load("res://Assets/Item/Cloak Assets/cloak_item.tres")
		if res is ItemData:
			item_data = res
			return item_data
	var data := ItemData.new()
	data.id = item_id
	data.display_name = item_name
	data.slot = equip_slot as ItemData.EquipSlot
	data.scene = wearable_scene
	data.bone_name = bone_name
	data.preview_color = pickup_color
	item_data = data
	return item_data

func _try_pickup(body: Node) -> bool:
	if _picked:
		return false
	
	# Priority: Add to Inventory bag
	var inv = body.get_node_or_null("Inventory")
	if inv and inv.has_method("add_item"):
		var data = _get_or_create_item_data()
		inv.add_item(data)
		_do_pickup_effect(body)
		return true

	var equipped: bool = false
	# Priority 1: Equipment node direct (fallback if no inventory)
	if body.has_node("Equipment"):
		var equip = body.get_node("Equipment")
		if equip and equip.has_method("equip_wearable") and wearable_scene:
			# Check already equipped
			if equip.has_method("has_equipped") and equip.call("has_equipped", equip_slot):
				print("[Pickup] Player already has item in slot %d" % equip_slot)
				return false
			var ins = equip.call("equip_wearable", wearable_scene, equip_slot, bone_name)
			equipped = ins != null
			if equipped and ins is WearableItem and body.has_method("set"):
				# Sync cloak var on Player if exists
				if "cloak" in body:
					body.set("cloak", ins)
				if "cloak_color" in body and ins.has_method("set_color"):
					ins.call("set_color", body.get("cloak_color"))
		elif equip and wearable_scene == null:
			equipped = false
	if not equipped and wearable_scene and body.has_method("add_child"):
		# Fallback: instance wearable and try equip via WearableItem
		var skel: Skeleton3D = _find_skeleton(body)
		if skel:
			var inst = wearable_scene.instantiate()
			if inst is WearableItem:
				equipped = (inst as WearableItem).equip(skel, bone_name)
				if equipped:
					print("[Pickup] Equipped via skeleton")
					if "cloak" in body:
						body.set("cloak", inst)
				else:
					inst.queue_free()
	if not equipped and body.has_method("equip_cloak"):
		var has_cloak: bool = false
		if "cloak" in body and body.get("cloak") != null and is_instance_valid(body.get("cloak")):
			var c = body.get("cloak")
			if c and c.visible:
				has_cloak = true
		if has_cloak:
			print("[Pickup] Player already has cloak")
			return false
		if body.has_node("Equipment"):
			var equip2 = body.get_node("Equipment")
			if equip2 and equip2.has_method("equip_wearable") and wearable_scene:
				var ins2 = equip2.call("equip_wearable", wearable_scene, equip_slot, bone_name)
				equipped = ins2 != null
		if not equipped:
			body.call("equip_cloak")
			equipped = true
	if not equipped:
		equipped = _force_equip(body)
	if equipped:
		_do_pickup_effect(body)
		return true
	return false

func _force_equip(body: Node) -> bool:
	# Last resort: try calling equip_cloak directly even if method check failed
	if body.has_method("equip_cloak"):
		body.call("equip_cloak")
		return true
	return false

func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for c in root.get_children():
		var r: Skeleton3D = _find_skeleton(c)
		if r:
			return r
	return null

func _do_pickup_effect(picker: Node) -> void:
	_picked = true
	picked_up.emit(picker, item_id)
	print("[Pickup] %s picked up by %s" % [item_name, picker.name])
	# Visual feedback
	if _mesh:
		var tw := create_tween()
		if tw:
			tw.tween_property(_mesh, "scale", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
			tw.parallel().tween_property(_mesh, "position:y", _mesh.position.y + 1.0, 0.25)
	# Disable collision
	set_deferred("monitoring", false)
	visible = false
	# Respawn or free
	if respawn_time > 0.0:
		await get_tree().create_timer(respawn_time).timeout
		_respawn()
	else:
		await get_tree().create_timer(0.35).timeout
		queue_free()

func _respawn() -> void:
	_picked = false
	visible = true
	set_deferred("monitoring", true)
	if _mesh:
		_mesh.scale = pickup_scale
		_mesh.visible = true

func try_interact(interactor: Node) -> bool:
	if _picked:
		return false
	return _try_pickup(interactor)
