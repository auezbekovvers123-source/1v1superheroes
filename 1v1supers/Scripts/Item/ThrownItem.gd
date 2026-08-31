extends RigidBody3D
class_name ThrownItem
## ThrownItem.gd — Physics projectile for charged throws
## Spawns as RigidBody3D with mesh from ItemData, receives initial velocity based on throw power.
## After settling, remains pickable via try_interact() and belongs to pickup groups for world scans.

@export var item_data: ItemData
var _picked: bool = false
var _life_time: float = 0.0
var _settle_time: float = 0.0
var _mesh_instance: MeshInstance3D = null
var _pickup_area: Area3D = null

const PICKUP_RADIUS: float = 2.0
const SETTLE_VELOCITY_THRESHOLD: float = 0.35
const AUTO_PICKUP_CONVERT_DELAY: float = 0.0 # we stay as RigidBody, no conversion needed
const MIN_PICKUP_DELAY: float = 0.45 # prevent instant re-pickup by thrower

func _ready() -> void:
	add_to_group("pickup")
	add_to_group("item_pickup")
	contact_monitor = true
	max_contacts_reported = 4
	# Default physics properties
	mass = 0.85
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 0.72
	physics_material_override.bounce = 0.28
	gravity_scale = 1.0
	linear_damp = 0.08
	angular_damp = 0.18
	# Ensure we can be picked after delay
	if _pickup_area == null:
		_create_pickup_area()
	# Auto free if falls below world?
	# Debug
	if item_data:
		print("[ThrownItem] Ready '%s' mass=%.2f pos=%s vel=%s" % [item_data.display_name, mass, str(global_position), str(linear_velocity)])

func _create_pickup_area() -> void:
	_pickup_area = Area3D.new()
	_pickup_area.name = "PickupArea"
	_pickup_area.monitoring = true
	_pickup_area.monitorable = true
	_pickup_area.collision_layer = 0
	_pickup_area.collision_mask = 1
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var sph := SphereShape3D.new()
	sph.radius = PICKUP_RADIUS
	col.shape = sph
	_pickup_area.add_child(col)
	add_child(_pickup_area)
	_pickup_area.body_entered.connect(_on_pickup_body_entered)
	_pickup_area.body_exited.connect(_on_pickup_body_exited)

var _inside_bodies: Array[Node3D] = []

func _on_pickup_body_entered(body: Node3D) -> void:
	if _picked:
		return
	if body.is_in_group("player"):
		if not _inside_bodies.has(body):
			_inside_bodies.append(body)

func _on_pickup_body_exited(body: Node3D) -> void:
	_inside_bodies.erase(body)

func _is_player(body: Node) -> bool:
	if body == null:
		return false
	if body.is_in_group("player"):
		return true
	return false

var thrower: Node3D = null
var _throw_power: float = 0.0

func setup(data: ItemData, start_pos: Vector3, throw_dir: Vector3, speed: float, power: float, p_thrower: Node3D = null) -> void:
	item_data = data
	thrower = p_thrower
	_throw_power = power
	# Defer global_position assignment until inside tree — caller will set after add_child
	# Create visual mesh before physics step
	_create_visual(data)
	# Create collision shape for RigidBody
	_create_body_shape(data)
	# Ensure pickup area exists
	if _pickup_area == null:
		_create_pickup_area()
	# Apply throw velocity
	var vel: Vector3 = throw_dir.normalized() * speed
	# Add slight upward arc already baked into throw_dir (caller provides angle)
	# Apply
	linear_velocity = vel
	# Angular velocity for tumbling
	var ang: Vector3 = Vector3(randf_range(-1,1), randf_range(-1,1), randf_range(-1,1)).normalized() * (8.0 + power * 10.0)
	angular_velocity = ang
	# Increase mass slightly with power? keep constant
	mass = 0.75 + power * 0.35
	# Store spawn pos for caller if not yet in tree
	if is_inside_tree():
		global_position = start_pos
	else:
		position = start_pos
	# Debug
	print("[ThrownItem] Setup '%s' power=%.0f%% speed=%.2f dir=%s vel=%s ang=%s" % [data.display_name, power*100.0, speed, str(throw_dir.normalized()), str(vel), str(ang)])

func _create_visual(data: ItemData) -> void:
	# Clean old mesh
	if _mesh_instance and is_instance_valid(_mesh_instance):
		_mesh_instance.queue_free()
		_mesh_instance = null
	var vis: MeshInstance3D = null
	if data.scene:
		var inst = data.scene.instantiate()
		if inst is BoneAttachment3D:
			var found := _find_mesh_in_node(inst)
			if found:
				vis = _clone_meshinstance(found)
			inst.queue_free()
		elif inst is Node3D:
			var found2 := _find_mesh_in_node(inst)
			if found2:
				vis = _clone_meshinstance(found2)
				inst.queue_free()
			else:
				# fallback use inst itself if it's mesh
				if inst is MeshInstance3D:
					vis = inst as MeshInstance3D
				else:
					vis = null
					inst.queue_free()
		else:
			vis = inst as MeshInstance3D
	elif data.mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = data.mesh
		if data.material:
			mi.material_override = data.material
			mi.set_surface_override_material(0, data.material)
		vis = mi
	else:
		var mi2 := MeshInstance3D.new()
		var shape: Mesh
		if data.is_usable:
			var sph := SphereMesh.new()
			sph.radius = 0.12
			sph.height = 0.24
			shape = sph
		else:
			var box := BoxMesh.new()
			box.size = Vector3(0.18,0.18,0.18)
			shape = box
		mi2.mesh = shape
		var mat := StandardMaterial3D.new()
		mat.albedo_color = data.preview_color
		mat.roughness = 0.6
		mi2.material_override = mat
		vis = mi2
	if vis == null:
		# fallback box
		var fallback := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.16,0.16,0.16)
		fallback.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = data.preview_color if data else Color(0.85,0.45,0.15)
		fallback.material_override = mat
		vis = fallback
	vis.name = "ThrownMesh"
	vis.position = Vector3.ZERO
	vis.rotation_degrees = Vector3.ZERO
	vis.scale = data.hold_scale if data and data.hold_scale != Vector3.ZERO else Vector3.ONE
	# Clamp scale to reasonable world size (hold_scale is 1, okay)
	add_child(vis)
	_mesh_instance = vis
	# Scale tweak: world pickup scale is Vector3.ONE but mesh from preview already good
	# Ensure cast shadow
	vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func _create_body_shape(data: ItemData) -> void:
	# Remove old shape if exists (RigidBody collision shape is a child)
	var existing := get_node_or_null("CollisionShape3D_Body")
	if existing:
		existing.queue_free()
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D_Body"
	var shape: Shape3D
	# Infer shape from data.mesh or fallback sphere
	if data and data.mesh is BoxMesh:
		var box_shape := BoxShape3D.new()
		var sz: Vector3 = (data.mesh as BoxMesh).size * 0.5
		if sz.length() < 0.05:
			sz = Vector3(0.08,0.08,0.08)
		box_shape.size = sz * 2.0
		shape = box_shape
	elif data and data.mesh is SphereMesh:
		var sph_shape := SphereShape3D.new()
		sph_shape.radius = (data.mesh as SphereMesh).radius * 0.9
		if sph_shape.radius < 0.05:
			sph_shape.radius = 0.13
		shape = sph_shape
	else:
		# Heuristic by is_usable (sphere) vs holdable (box)
		if data and data.is_usable:
			var sph2 := SphereShape3D.new()
			sph2.radius = 0.13
			shape = sph2
		else:
			var box2 := BoxShape3D.new()
			box2.size = Vector3(0.17,0.17,0.17)
			shape = box2
	col.shape = shape
	add_child(col)

func _find_mesh_in_node(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _find_mesh_in_node(c)
		if r:
			return r
	return null

func _clone_meshinstance(src: MeshInstance3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = src.mesh
	mi.material_override = src.material_override
	if src.mesh:
		for i in range(src.mesh.get_surface_count()):
			var m = src.get_surface_override_material(i)
			if m:
				mi.set_surface_override_material(i, m)
			else:
				var sm = src.mesh.surface_get_material(i)
				if sm:
					mi.set_surface_override_material(i, sm)
	return mi

func _physics_process(delta: float) -> void:
	_life_time += delta
	# Settle detection
	if linear_velocity.length() < SETTLE_VELOCITY_THRESHOLD and angular_velocity.length() < 1.0:
		_settle_time += delta
	else:
		_settle_time = 0.0
	# Optional: after long time, allow pickup conversion to static Area? Keep as RigidBody
	# Free if falls out of world
	if global_position.y < -20.0:
		queue_free()
	# Handle impact damage? If high speed hits dummy/player, apply impulse
	# Check for high-speed collision via contacts
	if _life_time > 0.08 and linear_velocity.length() > 3.0:
		_check_impact_damage()

func _check_impact_damage() -> void:
	# Simple sphere overlap for fighters near us (cheap)
	if item_data == null:
		return
	# Only damage if still moving fast (>3 m/s)
	if linear_velocity.length() < 3.0:
		return
	# Avoid hitting owner immediately (MIN_PICKUP_DELAY grace)
	if _life_time < 0.18:
		return
	var radius: float = 0.5
	var hit_pos: Vector3 = global_position
	for n in get_tree().get_nodes_in_group("fighter"):
		if not is_instance_valid(n) or n is ThrownItem:
			continue
		var body := n as Node3D
		if body == null:
			continue
		if body == thrower:
			# Don't hit thrower within first second nor if very low power
			if _life_time < 1.0 or _throw_power < 0.25:
				continue
		var dist: float = body.global_position.distance_to(hit_pos)
		# approximate hurtbox vertical offset
		var hurt_center: Vector3 = body.global_position + Vector3(0, 0.92, 0)
		var d2: float = hit_pos.distance_to(hurt_center)
		if d2 < 0.85 + radius:
			var health = body.get_node_or_null("Health")
			if health and health.has_method("take_damage"):
				if health.get("is_dead"):
					continue
				# Damage scales with power/speed
				var speed: float = linear_velocity.length()
				var dmg: float = clamp(speed * 1.2, 6.0, 22.0)
				var kb: Vector3 = linear_velocity.normalized() * clamp(speed * 0.5, 2.0, 7.0)
				kb.y = 0.35
				var ok: bool = health.take_damage(dmg, self, kb, 0.0, 0.0)
				if ok:
					print("[ThrownItem] Hit %s for %.0f dmg speed=%.1f" % [body.name, dmg, speed])
					# Bounce a bit
					linear_velocity *= -0.35
					# Prevent repeated hits
					_life_time = 0.0
					break

func try_interact(interactor: Node) -> bool:
	if _picked:
		return false
	if _life_time < MIN_PICKUP_DELAY:
		# Grace period to avoid instantly picking back the item you just threw
		# But allow if interactor is not the thrower? For now enforce delay for all
		if _life_time < MIN_PICKUP_DELAY:
			# Still allow if velocity low? No, enforce delay
			return false
	if item_data == null:
		return false
	var inv = interactor.get_node_or_null("Inventory")
	if inv and inv.has_method("can_pickup"):
		if not inv.can_pickup():
			if interactor.has_method("_on_hand_full_feedback"):
				interactor.call("_on_hand_full_feedback")
			return false
	if inv and inv.has_method("add_item"):
		inv.add_item(item_data)
		if interactor.has_method("attach_held_item"):
			interactor.call("attach_held_item", item_data)
		_do_pickup_effect(interactor)
		return true
	if interactor.has_method("attach_held_item"):
		var ok: bool = interactor.call("attach_held_item", item_data)
		if ok:
			_do_pickup_effect(interactor)
			return true
	return false

func _do_pickup_effect(picker: Node) -> void:
	_picked = true
	# Visual shrink
	if _mesh_instance and is_instance_valid(_mesh_instance):
		var tw := create_tween()
		if tw:
			tw.tween_property(_mesh_instance, "scale", Vector3.ZERO, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	set_deferred("monitoring", false)
	visible = false
	# Disable physics
	freeze = true
	await get_tree().create_timer(0.2).timeout
	queue_free()

# For test compatibility: expose item_id/item_name like ItemPickup
func _get(property: StringName):
	if property == "item_data":
		return item_data
	if property == "item_id":
		return item_data.id if item_data else ""
	if property == "item_name":
		return item_data.display_name if item_data else ""
	if property == "_picked":
		return _picked
	return null

func _set(property: StringName, value) -> bool:
	if property == "item_data":
		item_data = value
		return true
	return false
