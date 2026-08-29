extends WearableItem
class_name CloakWearable
## CloakWearable.gd — Cloak-specific logic: wind sway, equip effects
## Inherits BoneAttachment3D behaviour; expects MeshInstance3D child with ShaderMaterial

@export_group("Cloak Tuning")
@export var base_strength: float = 0.07
@export var base_speed: float = 0.22
@export var wind_gust_strength: float = 0.12
@export var wind_gust_speed: float = 0.35
@export var auto_wind: bool = true
@export var velocity_influence: float = 0.015
@export var gust_chance: float = 0.003
@export var gust_duration: float = 1.2
@export var wind_smooth: float = 2.5

var _mat: ShaderMaterial = null
var _time: float = 0.0
var _owner_body: CharacterBody3D = null
var _gust_timer: float = 0.0
var _current_strength: float = 0.07
var _current_speed: float = 0.22
var _target_strength: float = 0.07
var _target_speed: float = 0.22

# Cape bones physics
@export_group("Cape Bones Physics")
@export var enable_bones: bool = true
@export var cape_bone_count: int = 6
@export var cape_bone_length: float = 0.24
@export var cape_stiffness: float = 9.0
@export var cape_damping: float = 4.5
@export var cape_gravity_sag: float = 12.0
var _cape_skeleton: Skeleton3D = null
var _cape_bone_angles: Array[Vector3] = []
var _cape_bone_vel: Array[Vector3] = []
var _cape_skeleton_ready: bool = false

func _ready() -> void:
	item_name = "Cloak"
	item_id = "cloak_01"
	if bone_name == "" or bone_name == "wearable_generic":
		bone_name = "spine_03.x"
	super._ready()
	# Locate material
	var mi = get_mesh_instance()
	if mi:
		if mi.material_override is ShaderMaterial:
			_mat = mi.material_override as ShaderMaterial
		elif mi.get_surface_override_material(0) is ShaderMaterial:
			_mat = mi.get_surface_override_material(0) as ShaderMaterial
		else:
			# Try mesh surface material
			var mesh: Mesh = mi.mesh
			if mesh and mesh.get_surface_count() > 0:
				var smat = mesh.surface_get_material(0)
				if smat is ShaderMaterial:
					_mat = smat
	# Find owning CharacterBody3D for velocity influence
	_owner_body = _find_owner_body()
	_current_strength = base_strength
	_current_speed = base_speed
	_target_strength = base_strength
	_target_speed = base_speed
	if _mat:
		_mat.set_shader_parameter("strength", _current_strength)
		_mat.set_shader_parameter("speed", _current_speed)
	# Setup cape bones + skin for sorta physics (deferred to ensure Skeleton3D ready)
	if enable_bones:
		call_deferred("_setup_cape_skeleton")

func _find_owner_body() -> CharacterBody3D:
	var n: Node = self
	while n:
		if n is CharacterBody3D:
			return n as CharacterBody3D
		# Also check skeleton owner
		var p = n.get_parent()
		if p is Skeleton3D:
			var owner_node = p.get_parent()
			while owner_node:
				if owner_node is CharacterBody3D:
					return owner_node as CharacterBody3D
				owner_node = owner_node.get_parent()
		n = n.get_parent()
	return null

func _process(delta: float) -> void:
	if not auto_wind or _mat == null:
		return
	_time += delta
	# Handle gust timer
	if _gust_timer > 0.0:
		_gust_timer -= delta
		if _gust_timer <= 0.0:
			# Gust ended, return to base+velocity target
			_target_strength = base_strength
			_target_speed = base_speed
	# If not gusting, compute velocity-influenced target
	if _gust_timer <= 0.0:
		if _owner_body:
			var vel: float = _owner_body.velocity.length()
			var extra: float = clamp(vel * velocity_influence, 0.0, 0.12)
			# gentle sine variation - very small to avoid flicker
			var sway: float = base_strength + extra + sin(_time * 0.6) * 0.008
			var spd: float = base_speed + extra * 0.35
			_target_strength = sway
			_target_speed = spd
		else:
			_target_strength = base_strength + sin(_time * 0.5) * 0.006
			_target_speed = base_speed
		# Random gust trigger (rarer, smoother)
		if randf() < gust_chance:
			trigger_gust()
	# Smoothly lerp current towards target to avoid popping/flicker
	_current_strength = lerp(_current_strength, _target_strength, delta * wind_smooth)
	_current_speed = lerp(_current_speed, _target_speed, delta * wind_smooth)
	# Clamp to avoid extreme values that cause flicker
	_current_strength = clamp(_current_strength, 0.02, 0.22)
	_current_speed = clamp(_current_speed, 0.08, 0.55)
	_mat.set_shader_parameter("strength", _current_strength)
	_mat.set_shader_parameter("speed", _current_speed)
	# Update bone physics for sorta-cloth
	_update_cape_physics(delta)

func trigger_gust() -> void:
	if _gust_timer > 0.0:
		return # don't stack gusts
	_gust_timer = gust_duration
	_target_strength = base_strength + wind_gust_strength
	_target_speed = base_speed + wind_gust_speed
	# Add slight immediate lerp boost so gust is visible but not popping
	_current_strength = lerp(_current_strength, _target_strength, 0.35)

func set_wind(strength: float, speed: float) -> void:
	base_strength = strength
	base_speed = speed
	_target_strength = strength
	_target_speed = speed
	_current_strength = strength
	_current_speed = speed
	if _mat:
		_mat.set_shader_parameter("strength", strength)
		_mat.set_shader_parameter("speed", speed)

func equip(to_skeleton: Skeleton3D, target_bone: String = "") -> bool:
	var ok: bool = super.equip(to_skeleton, target_bone)
	if ok:
		visible = true
		# Play equip puff — defer to next frame to ensure tween is valid
		call_deferred("_play_equip_tween")
	return ok

func _play_equip_tween() -> void:
	var mi = get_mesh_instance()
	if mi == null or not is_inside_tree():
		return
	# Respect configured wearable scale (default 0.145) instead of ONE
	var target_scale: Vector3 = mesh_scale
	if target_scale == Vector3.ZERO:
		target_scale = Vector3.ONE
	mi.scale = target_scale * 0.6
	var tw := create_tween()
	if tw:
		tw.tween_property(mi, "scale", target_scale, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# ---------------- Cape Bones + Sorta Physics ----------------
func _setup_cape_skeleton() -> void:
	if _cape_skeleton_ready or not enable_bones:
		return
	var mi = get_mesh_instance()
	if mi == null or mi.mesh == null:
		push_warning("[Cloak] No mesh for cape skeleton")
		return
	var mesh = mi.mesh
	if mesh.get_surface_count() == 0:
		return
	# Don't double-create
	if has_node("CapeSkeleton"):
		_cape_skeleton = get_node("CapeSkeleton") as Skeleton3D
		_cape_skeleton_ready = true
		return
	# Create Skeleton3D for cape
	var skel = Skeleton3D.new()
	skel.name = "CapeSkeleton"
	add_child(skel)
	# Ensure cape mesh is child of skeleton (reparent)
	var mi_parent = mi.get_parent()
	if mi_parent != skel:
		mi_parent.remove_child(mi)
		skel.add_child(mi)
		# Keep mesh offset relative to skeleton root
		# WearableItem already set mi.position = mesh_offset, keep it
	# Create bones chain
	var count: int = clamp(cape_bone_count, 3, 8)
	var blen: float = cape_bone_length
	for i in range(count):
		var bname = "cape_%d" % i
		skel.add_bone(bname)
		if i == 0:
			skel.set_bone_parent(i, -1)
			skel.set_bone_rest(i, Transform3D.IDENTITY)
		else:
			skel.set_bone_parent(i, i - 1)
			var rest = Transform3D.IDENTITY
			rest.origin = Vector3(0, -blen, 0)
			skel.set_bone_rest(i, rest)
	# Init physics arrays
	_cape_bone_angles.clear()
	_cape_bone_vel.clear()
	for i in range(count):
		_cape_bone_angles.append(Vector3.ZERO)
		_cape_bone_vel.append(Vector3.ZERO)
	_cape_skeleton = skel
	# Generate skin weights so mesh deforms with bones
	_generate_cape_skin(skel, mi, count, blen)
	# Ensure skeleton is reset
	for i in range(count):
		skel.set_bone_pose_position(i, Vector3.ZERO)
		skel.set_bone_pose_rotation(i, Quaternion.IDENTITY)
		skel.set_bone_pose_scale(i, Vector3.ONE)
	_cape_skeleton_ready = true
	print("[Cape] Skeleton ready: %d bones, len %.2f" % [count, blen])

func _generate_cape_skin(skel: Skeleton3D, mi: MeshInstance3D, bone_count: int, bone_len: float) -> void:
	var orig_mesh = mi.mesh
	if orig_mesh == null:
		return
	# Build Skin with bind poses (inverse of global rest)
	var skin = Skin.new()
	var total_len: float = bone_len * (bone_count - 1)
	if total_len < 0.01:
		total_len = 1.0
	# Compute global rest for each bone to get bind
	for i in range(bone_count):
		# accumulate transforms up the chain
		var chain: Array[int] = []
		var cur: int = i
		while cur != -1:
			chain.push_front(cur)
			cur = skel.get_bone_parent(cur)
		var accum = Transform3D.IDENTITY
		for b in chain:
			accum = accum * skel.get_bone_rest(b)
		skin.add_bind(i, accum.affine_inverse())
	# Build new ArrayMesh with bone weights based on vertex height
	var new_mesh = ArrayMesh.new()
	for s_idx in range(orig_mesh.get_surface_count()):
		var arrays = orig_mesh.surface_get_arrays(s_idx)
		var verts = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		if verts == null or verts.size() == 0:
			continue
		var bones = PackedInt32Array()
		var weights = PackedFloat32Array()
		bones.resize(verts.size() * 4)
		weights.resize(verts.size() * 4)
		# Mesh local AABB is approx (-2.49,-9.49,-0.41) size (5.07,9.45,1.16) before scale
		# World Y = local_y * mesh_scale.y + mesh_offset.y (0.18)
		# Top world ~0.18, bottom ~0.18 -9.45*0.145 = 0.18 -1.37 = -1.19
		var top_world: float = mesh_offset.y
		# total_len already is world length of skeleton (~1.2-1.4)
		for vi in range(verts.size()):
			var v = verts[vi]
			var world_y = v.y * mesh_scale.y + mesh_offset.y
			var t: float = clamp((top_world - world_y) / total_len, 0.0, 1.0)
			var f: float = t * (bone_count - 1)
			var b0: int = int(floor(f))
			var b1: int = min(b0 + 1, bone_count - 1)
			var blend: float = f - float(b0)
			if b0 < 0:
				b0 = 0
			var w0: float = 1.0 - blend
			var w1: float = blend
			var base = vi * 4
			bones[base + 0] = b0
			bones[base + 1] = b1
			bones[base + 2] = 0
			bones[base + 3] = 0
			weights[base + 0] = w0
			weights[base + 1] = w1
			weights[base + 2] = 0.0
			weights[base + 3] = 0.0
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		# Ensure format has bones/weights
		var mat = orig_mesh.surface_get_material(s_idx)
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if mat:
			new_mesh.surface_set_material(s_idx, mat)
	# Assign
	mi.mesh = new_mesh
	mi.skin = skin
	mi.skeleton = NodePath(skel.get_path())
	print("[Cape] Skin generated with %d bones" % bone_count)

func _update_cape_physics(delta: float) -> void:
	if not _cape_skeleton_ready or _cape_skeleton == null or cape_bone_count == 0:
		return
	# Keep top bone fixed
	if _cape_skeleton.get_bone_count() != cape_bone_count:
		return
	# Update each bone (skip 0 = root pinned)
	for i in range(1, cape_bone_count):
		var t: float = float(i) / float(cape_bone_count - 1) # 0..1 down the cape
		var ang = _cape_bone_angles[i]
		var vel = _cape_bone_vel[i]
		# Targets based on character velocity, gravity sag, wind - tuned to hang/fall
		var target = Vector3.ZERO
		# Gravity sag: near vertical when idle (cape hangs down), lower bones slightly more
		target.x = lerp(2.0, 5.0, t)
		# Velocity influence: when moving, cape trails behind (horizontal)
		if _owner_body:
			var v: Vector3 = _owner_body.velocity
			var speed: float = v.length()
			var local_vel_x = 0.0
			if speed > 0.1:
				local_vel_x = v.dot(Vector3(1,0,0)) * 0.1
			# Trail: faster = more horizontal, but limited to keep drape
			target.x += clamp(speed * 1.6 * t, 0.0, 18.0) # pitch back when running, max ~18° per bone -> tip ~90° horizontal
			target.z += clamp(local_vel_x * 8.0 * t, -18.0, 18.0) # side sway when strafing
			# Add slight lift when airborne, but keep falling
			if not _owner_body.is_on_floor():
				target.x += 4.0 * t
		# Wind gust sway - much reduced to avoid floating
		target.x += sin(_time * _current_speed * 1.4 + float(i) * 0.6) * _current_strength * 14.0 * t
		target.z += cos(_time * 0.9 + float(i) * 0.7) * _current_strength * 8.0 * t
		# Spring physics - higher damping to settle and fall
		var stiffness: float = lerp(cape_stiffness, cape_stiffness * 0.6, t)
		var damping: float = cape_damping + t * 1.5 # more damping at tip to avoid wobble
		var diff: Vector3 = target - ang
		vel += diff * stiffness * delta
		# Gravity pull towards vertical (down) - gentle, not pushing out
		# Apply slight downward bias (reduce X when t small)
		vel.x += -ang.x * 0.8 * delta * t # restore to vertical
		vel -= vel * damping * delta
		ang += vel * delta
		# Clamp to keep cape hanging, not flipping up
		ang.x = clamp(ang.x, -15.0, 55.0)
		ang.z = clamp(ang.z, -28.0, 28.0)
		_cape_bone_angles[i] = ang
		_cape_bone_vel[i] = vel
		var qx = Quaternion.from_euler(Vector3(deg_to_rad(ang.x), 0, 0))
		var qz = Quaternion.from_euler(Vector3(0, 0, deg_to_rad(ang.z)))
		var q = qx * qz
		_cape_skeleton.set_bone_pose_rotation(i, q)
	# Root stays identity
	_cape_skeleton.set_bone_pose_rotation(0, Quaternion.IDENTITY)
