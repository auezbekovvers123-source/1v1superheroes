extends Node
class_name RagdollController
## RagdollController — GTA5 style ragdoll on death
## Drop as child of CharacterBody3D (Player or Dummy). Auto-finds Skeleton3D, builds PhysicalBones,
## starts simulation on death, applies knockback impulse and lets physics flop.
## Supports both C11 (С11.glb) skeleton and Object_Character skeleton generically.

@export var skeleton_path: NodePath = NodePath("")
@export var capsule_radius_scale: float = 1.0
@export var keep_simulating_on_respawn: bool = false
@export var auto_find_skeleton: bool = true
@export var impulse_multiplier: float = 1.35
@export var debug_log: bool = false

var skeleton: Skeleton3D = null
var _character_body: CharacterBody3D = null
var _health: Node = null
var _anim_player: AnimationPlayer = null
var _anim_tree: AnimationTree = null
var _collision_shape: CollisionShape3D = null
var _original_collision_layer: int = 1
var _original_collision_mask: int = 1
var _is_ragdolled: bool = false
var _built: bool = false
var _last_hit_dir: Vector3 = Vector3.ZERO
var _last_hit_pos: Vector3 = Vector3.ZERO

# GTA feel tuning
const DAMP_LINEAR: float = 0.35
const DAMP_ANGULAR: float = 0.38
const JOINT_DAMP: float = 0.25

func _ready() -> void:
	_character_body = get_parent() as CharacterBody3D
	if _character_body == null:
		# search up
		var p := get_parent()
		while p and not p is CharacterBody3D:
			p = p.get_parent()
		_character_body = p as CharacterBody3D
	if _character_body:
		_original_collision_layer = _character_body.collision_layer
		_original_collision_mask = _character_body.collision_mask
		_collision_shape = _character_body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_health = _character_body.get_node_or_null("Health")
		if _health and _health.has_signal("died"):
			if not _health.died.is_connected(_on_health_died):
				_health.died.connect(_on_health_died)
			if _health.has_signal("health_changed") and not _health.health_changed.is_connected(_on_health_changed):
				pass
		# Also listen for respawn/reset: Health emits health_changed when revived, but better hook explicit
		# Dummy/Player will call reset_ragdoll() on respawn.

	_find_skeleton()
	_find_anim_players()
	if debug_log:
		print("[Ragdoll] ready on %s skeleton=%s" % [_character_body.name if _character_body else "?", skeleton])

func _find_skeleton() -> void:
	if skeleton and is_instance_valid(skeleton):
		return
	if skeleton_path != NodePath("") :
		skeleton = get_node_or_null(skeleton_path) as Skeleton3D
		if skeleton:
			return
	if auto_find_skeleton and _character_body:
		skeleton = _search_skeleton(_character_body)
	if skeleton == null:
		# fallback global search
		skeleton = _search_skeleton(get_tree().current_scene) if get_tree().current_scene else null

func _search_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var r := _search_skeleton(c)
		if r:
			return r
	return null

func _find_anim_players() -> void:
	if _character_body == null:
		return
	_anim_player = _find_anim_player(_character_body)
	_anim_tree = _character_body.get_node_or_null("AnimationTree") as AnimationTree
	if _anim_tree == null:
		_anim_tree = _find_anim_tree(_character_body)

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var f := _find_anim_player(c)
		if f:
			return f
	return null

func _find_anim_tree(n: Node) -> AnimationTree:
	if n is AnimationTree:
		return n as AnimationTree
	for c in n.get_children():
		var f := _find_anim_tree(c)
		if f:
			return f
	return null

# --- Public API ---
func is_ragdolled() -> bool:
	return _is_ragdolled

func start_ragdoll(hit_direction: Vector3 = Vector3.ZERO, hit_position: Vector3 = Vector3.ZERO, hit_strength: float = 5.0) -> void:
	if _is_ragdolled:
		return
	_find_skeleton()
	if skeleton == null:
		push_warning("[Ragdoll] No Skeleton3D found for %s" % (_character_body.name if _character_body else "unknown"))
		return
	_ensure_physical_bones()

	_last_hit_dir = hit_direction
	_last_hit_pos = hit_position

	# Stop animations
	if _anim_tree:
		_anim_tree.active = false
	if _anim_player:
		_anim_player.active = false
		_anim_player.stop(false)
		# keep current pose frozen so physical bones spawn in place
		# don't reset

	# Disable CharacterBody collision so it doesn't fight physical bones
	if _character_body:
		_character_body.collision_layer = 0
		_character_body.collision_mask = 0
		if _collision_shape:
			_collision_shape.disabled = true
		# Stop movement
		_character_body.velocity = Vector3.ZERO
		# Disable processing that would move body (Player/Dummy will check is_ragdolled)

	# Start physics simulation
	skeleton.physical_bones_start_simulation()
	# Also ensure all PhysicalBones are awake and have proper layers
	for child in skeleton.get_children():
		if child is PhysicalBone3D:
			var pb := child as PhysicalBone3D
			# can_sleep is valid; sleeping/freeze are not on PhysicalBone3D in Godot 4
			pb.can_sleep = false
			# Restore collision layers (reset_ragdoll zeroes them)
			pb.collision_layer = 1
			pb.collision_mask = 1

	_is_ragdolled = true

	# Apply GTA-style impulse next physics frame to ensure bodies are awake
	call_deferred("_apply_ragdoll_impulse", hit_direction, hit_position, hit_strength)
	if debug_log:
		print("[Ragdoll] START %s dir=%s pos=%s str=%.1f" % [_character_body.name, hit_direction, hit_position, hit_strength])

func reset_ragdoll() -> void:
	if not _is_ragdolled and not _built:
		return
	if skeleton and is_instance_valid(skeleton):
		for child in skeleton.get_children():
			if child is PhysicalBone3D:
				var pb := child as PhysicalBone3D
				pb.linear_velocity = Vector3.ZERO
				pb.angular_velocity = Vector3.ZERO
				pb.can_sleep = true
		if _is_ragdolled:
			skeleton.physical_bones_stop_simulation()
			for child in skeleton.get_children():
				if child is PhysicalBone3D:
					var pb2 := child as PhysicalBone3D
					pb2.linear_velocity = Vector3.ZERO
					pb2.angular_velocity = Vector3.ZERO
			if skeleton.has_method("reset_bone_poses"):
				skeleton.reset_bone_poses()
			elif skeleton.has_method("clear_bones_global_pose_override"):
				skeleton.clear_bones_global_pose_override()
			if skeleton.has_method("force_update_bone_child_transforms"):
				skeleton.force_update_bone_child_transforms()
	_is_ragdolled = false
	# Disable physical bone collisions so they don't fight CharacterBody3D move_and_slide
	if skeleton and is_instance_valid(skeleton):
		for child in skeleton.get_children():
			if child is PhysicalBone3D:
				var pb3 := child as PhysicalBone3D
				pb3.collision_layer = 0
				pb3.collision_mask = 0
	if _character_body:
		_character_body.collision_layer = _original_collision_layer
		_character_body.collision_mask = _original_collision_mask
		if _collision_shape and is_instance_valid(_collision_shape):
			var lock_active: bool = false
			if _character_body.get("_respawn_lock") != null:
				lock_active = float(_character_body.get("_respawn_lock")) > 0.0
			if not lock_active:
				_collision_shape.disabled = false
		_character_body.velocity = Vector3.ZERO
		if _character_body.has_method("reset_physics_interpolation"):
			_character_body.reset_physics_interpolation()

	# Re-enable animations
	if _anim_tree and is_instance_valid(_anim_tree):
		_anim_tree.active = true
	if _anim_player and is_instance_valid(_anim_player):
		_anim_player.active = true
		# play idle
		if _anim_player.has_animation("Idle"):
			_anim_player.play("Idle", 0.2)
		elif _anim_player.has_animation("idle"):
			_anim_player.play("idle", 0.2)
		# Ensure skeleton pose is fresh
		if skeleton and is_instance_valid(skeleton) and skeleton.has_method("force_update_bone_child_transforms"):
			skeleton.force_update_bone_child_transforms()

	if debug_log and _character_body:
		print("[Ragdoll] RESET %s" % _character_body.name)

func _on_health_died(killer: Node) -> void:
	# Determine hit direction from killer
	var dir := Vector3.ZERO
	var pos := _character_body.global_position if _character_body else Vector3.ZERO
	var strength := 6.0
	if _character_body and killer is Node3D and killer != _character_body:
		dir = (_character_body.global_position - (killer as Node3D).global_position)
		dir.y = 0.15
		if dir.length() < 0.1:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		pos = _character_body.global_position + Vector3(0, 0.9, 0)
		# try to get last knockback from health meta or use strength based on last damage
		if _health and _health.get("current") != null:
			pass
		# use killer velocity if available
		if killer is CharacterBody3D:
			var kv: Vector3 = (killer as CharacterBody3D).velocity
			if kv.length() > 1.0:
				dir = (dir + kv.normalized() * 0.6).normalized()
				strength += kv.length() * 0.25
	else:
		dir = Vector3(randf_range(-1,1), 0.2, randf_range(-1,1)).normalized()
		if _character_body:
			pos = _character_body.global_position
	strength *= impulse_multiplier
	start_ragdoll(dir, pos, strength)

func _on_health_changed(_cur: float, _max: float) -> void:
	pass

# --- Internal: build physical bones ---
func _ensure_physical_bones() -> void:
	if _built:
		return
	if skeleton == null:
		return
	# If already has PhysicalBones, consider built
	var has_pb := false
	for c in skeleton.get_children():
		if c is PhysicalBone3D:
			has_pb = true
			break
	if has_pb:
		_built = true
		return

	var bone_count := skeleton.get_bone_count()
	if debug_log:
		print("[Ragdoll] Building %d bones for %s" % [bone_count, _character_body.name if _character_body else "?"])
		for i in range(bone_count):
			print("  bone %d: %s parent=%d" % [i, skeleton.get_bone_name(i), skeleton.get_bone_parent(i)])

	for i in range(bone_count):
		var bname: String = skeleton.get_bone_name(i)
		if bname.is_empty():
			continue
		var lname := bname.to_lower()
		# Skip tiny end bones and most finger details — keep one hand bone; skip toes end etc
		if lname in ["headtop_end", "toes_01.l", "toes_01.r", "righttoe_end", "lefttoe_end", "righttoe_end", "lefttoe_end", "toes_01.l", "toes_01.r"]:
			# keep foot but skip toe end? Actually keep toes as small box, skip end
			if lname.ends_with("_end"):
				continue
		if lname.begins_with("index") or lname.begins_with("middle") or lname.begins_with("ring") or lname.begins_with("pinky") or lname.begins_with("thumb"):
			# skip finger phalanges except base? Keep first phalange for hand shape? Skip all to reduce count
			# Keep hand.r / hand.l as proxy
			if lname != "hand.l" and lname != "hand.r" and lname != "lefthand" and lname != "righthand" and lname != "hand.l" and lname != "hand.r":
				continue
		# Create PhysicalBone
		var cfg := _config_for_bone(bname, i)
		if cfg.is_empty():
			continue
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + bname
		pb.bone_name = bname
		pb.mass = cfg.get("mass", 1.5)
		pb.friction = 0.75
		pb.bounce = 0.05
		pb.linear_damp = DAMP_LINEAR
		pb.angular_damp = DAMP_ANGULAR
		pb.gravity_scale = 1.0
		pb.can_sleep = false
		# Make ragdoll collide with world (layer 1) and with other ragdolls (layer 2)
		pb.collision_layer = 1
		pb.collision_mask = 1
		# Joint: choose based on bone
		var jtype: int = cfg.get("joint_type", 0) # 0=PIN
		pb.joint_type = jtype
		# Damping for joint
		# Note: joint_damp not exposed? Use body damp already.

		# Body offset: center shape a bit along bone direction for limbs
		# For now identity; capsule centered at bone origin — GTA style doesn't need perfect alignment
		# But for thighs/legs we offset slightly down to span between joints
		if cfg.has("body_offset"):
			pb.body_offset = cfg["body_offset"]

		skeleton.add_child(pb)
		# Needs to be internal? PhysicalBone must be direct child of Skeleton3D
		pb.owner = skeleton.owner if skeleton.owner else get_tree().current_scene

		# Add collision shape
		var cs := CollisionShape3D.new()
		cs.name = "CS_" + bname
		var shape: Shape3D = null
		var stype: String = cfg.get("shape", "capsule")
		if stype == "capsule":
			var cap := CapsuleShape3D.new()
			cap.radius = cfg.get("radius", 0.08) * capsule_radius_scale
			cap.height = cfg.get("height", 0.28)
			shape = cap
		elif stype == "sphere":
			var sph := SphereShape3D.new()
			sph.radius = cfg.get("radius", 0.12) * capsule_radius_scale
			shape = sph
		elif stype == "box":
			var box := BoxShape3D.new()
			box.size = cfg.get("size", Vector3(0.26, 0.16, 0.16))
			shape = box
		else:
			var cap2 := CapsuleShape3D.new()
			cap2.radius = 0.08
			cap2.height = 0.25
			shape = cap2
		cs.shape = shape
		# Shape transform: for capsules, Godot Y-up matches bone direction for most vertical bones (spine). For limbs which are horizontal T-pose, still Y-up may be off. But we can try to rotate 90deg for arms.
		if cfg.has("shape_transform"):
			cs.transform = cfg["shape_transform"]
		pb.add_child(cs)
		cs.owner = skeleton.owner if skeleton.owner else get_tree().current_scene

	_built = true
	if debug_log:
		print("[Ragdoll] Built %d PhysicalBones" % _count_physical_bones())

func _count_physical_bones() -> int:
	if skeleton == null:
		return 0
	var c := 0
	for child in skeleton.get_children():
		if child is PhysicalBone3D:
			c += 1
	return c

func _config_for_bone(bname: String, idx: int) -> Dictionary:
	var lname := bname.to_lower()
	var cfg: Dictionary = {}

	# --- C11 naming (С11.glb) ---
	if bname == "root.x" or lname == "root.x":
		cfg = {"shape":"box", "size": Vector3(0.32, 0.22, 0.20), "mass": 5.0, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif bname == "spine_01.x":
		cfg = {"shape":"capsule", "radius": 0.13, "height": 0.28, "mass": 3.5, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif bname == "spine_02.x":
		cfg = {"shape":"capsule", "radius": 0.13, "height": 0.26, "mass": 3.2, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif bname == "spine_03.x":
		cfg = {"shape":"capsule", "radius": 0.12, "height": 0.24, "mass": 3.0, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif bname == "neck.x":
		cfg = {"shape":"capsule", "radius": 0.07, "height": 0.16, "mass": 1.0, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif bname == "head.x":
		cfg = {"shape":"sphere", "radius": 0.145, "mass": 1.4, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	# Arms C11: shoulder.l/r, arm_stretch.l/r, forearm_stretch.l/r, hand.l/r
	elif lname == "shoulder.l" or lname == "shoulder.r":
		cfg = {"shape":"capsule", "radius": 0.06, "height": 0.14, "mass": 0.9, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "arm_stretch.l" or lname == "arm_stretch.r" or lname == "arm_stretch.l" or lname == "arm_stretch.r":
		cfg = {"shape":"capsule", "radius": 0.07, "height": 0.30, "mass": 1.6, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
		# arms in T-pose are horizontal, rotate capsule to align with X axis? Capsule is Y-up, so rotate Z 90
		cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
	elif lname == "forearm_stretch.l" or lname == "forearm_stretch.r":
		cfg = {"shape":"capsule", "radius": 0.06, "height": 0.28, "mass": 1.2, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
		cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
	elif lname == "hand.l" or lname == "hand.r":
		cfg = {"shape":"sphere", "radius": 0.07, "mass": 0.6, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif lname == "thigh_stretch.l" or lname == "thigh_stretch.r":
		cfg = {"shape":"capsule", "radius": 0.095, "height": 0.40, "mass": 2.8, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "leg_stretch.l" or lname == "leg_stretch.r":
		cfg = {"shape":"capsule", "radius": 0.085, "height": 0.40, "mass": 2.0, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
	elif lname == "foot.l" or lname == "foot.r":
		cfg = {"shape":"box", "size": Vector3(0.14, 0.07, 0.26), "mass": 0.9, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif lname == "toes_01.l" or lname == "toes_01.r":
		cfg = {"shape":"sphere", "radius": 0.06, "mass": 0.4, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
		# fallback generic for Object_Character skeleton
	elif lname == "hips" or lname == "hips":
		cfg = {"shape":"box", "size": Vector3(0.30, 0.20, 0.20), "mass": 5.0, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif lname == "spine" or lname == "spine1" or lname == "spine2":
		cfg = {"shape":"capsule", "radius": 0.12, "height": 0.26, "mass": 3.0, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "neck":
		cfg = {"shape":"capsule", "radius": 0.07, "height": 0.14, "mass": 1.0, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "head":
		cfg = {"shape":"sphere", "radius": 0.14, "mass": 1.3, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "leftshoulder" or lname == "rightshoulder":
		cfg = {"shape":"capsule", "radius": 0.06, "height": 0.12, "mass": 0.8, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "leftarm" or lname == "rightarm":
		cfg = {"shape":"capsule", "radius": 0.07, "height": 0.28, "mass": 1.5, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
		cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
	elif lname == "leftforearm" or lname == "rightforearm":
		cfg = {"shape":"capsule", "radius": 0.06, "height": 0.26, "mass": 1.1, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
		cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
	elif lname == "lefthand" or lname == "righthand":
		cfg = {"shape":"sphere", "radius": 0.07, "mass": 0.6, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif lname == "leftupleg" or lname == "rightupleg":
		cfg = {"shape":"capsule", "radius": 0.09, "height": 0.38, "mass": 2.6, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
	elif lname == "leftleg" or lname == "rightleg":
		cfg = {"shape":"capsule", "radius": 0.08, "height": 0.38, "mass": 1.9, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
	elif lname == "leftfoot" or lname == "rightfoot":
		cfg = {"shape":"box", "size": Vector3(0.13, 0.07, 0.24), "mass": 0.85, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	elif lname == "lefttoebase" or lname == "righttoebase":
		cfg = {"shape":"sphere", "radius": 0.05, "mass": 0.35, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
	else:
		# Generic fallback for unexpected bones (e.g., spine variants)
		if "spine" in lname:
			cfg = {"shape":"capsule", "radius": 0.11, "height": 0.24, "mass": 2.8, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
		elif "thigh" in lname or "upleg" in lname:
			cfg = {"shape":"capsule", "radius": 0.09, "height": 0.36, "mass": 2.5, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
		elif "leg" in lname and "up" not in lname:
			cfg = {"shape":"capsule", "radius": 0.08, "height": 0.36, "mass": 1.8, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
		elif "arm" in lname and "fore" not in lname:
			cfg = {"shape":"capsule", "radius": 0.07, "height": 0.28, "mass": 1.4, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
			cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
		elif "forearm" in lname:
			cfg = {"shape":"capsule", "radius": 0.06, "height": 0.26, "mass": 1.0, "joint_type": PhysicalBone3D.JOINT_TYPE_HINGE}
			cfg["shape_transform"] = Transform3D(Basis.from_euler(Vector3(0, 0, deg_to_rad(90))), Vector3.ZERO)
		elif "hand" in lname:
			cfg = {"shape":"sphere", "radius": 0.065, "mass": 0.55, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
		elif "foot" in lname:
			cfg = {"shape":"box", "size": Vector3(0.13, 0.07, 0.22), "mass": 0.8, "joint_type": PhysicalBone3D.JOINT_TYPE_PIN}
		elif "head" in lname and "top" not in lname:
			cfg = {"shape":"sphere", "radius": 0.13, "mass": 1.2, "joint_type": PhysicalBone3D.JOINT_TYPE_CONE}
		else:
			# skip unknown finger bones etc.
			return {}

	return cfg

func _apply_ragdoll_impulse(dir: Vector3, pos: Vector3, strength: float) -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	if dir.length() < 0.01:
		dir = Vector3(randf_range(-1,1), 0.2, randf_range(-1,1)).normalized()
	# Normalize and add upward GTA-style lift
	dir = dir.normalized()
	var base_impulse: Vector3 = dir * strength
	# Find all physical bones
	var bones: Array[PhysicalBone3D] = []
	for child in skeleton.get_children():
		if child is PhysicalBone3D:
			bones.append(child as PhysicalBone3D)
	if bones.is_empty():
		return
	# Apply to hips/root more
	var hips_names := ["root.x", "Hips", "hips", "root"]
	var hips_bone: PhysicalBone3D = null
	for b in bones:
		if b.bone_name in hips_names:
			hips_bone = b
			break
	if hips_bone == null and bones.size() > 0:
		# fallback: first bone (usually hips)
		hips_bone = bones[0]

	# GTA5 style: big initial fling + spin + limb wobble
	for pb in bones:
		var bone_pos: Vector3 = pb.global_position
		var dist: float = bone_pos.distance_to(pos) if pos != Vector3.ZERO else 0.0
		var falloff: float = clamp(1.0 - dist / 2.8, 0.25, 1.0)
		# Bone-specific multiplier: torso gets more, limbs get slightly less but more spin
		var is_torso: bool = pb.bone_name.to_lower() in ["root.x", "spine_01.x", "spine_02.x", "spine_03.x", "hips", "spine", "spine1", "spine2"]
		var is_head: bool = "head" in pb.bone_name.to_lower()
		var mult: float = 1.0
		if is_torso:
			mult = 1.15
		elif is_head:
			mult = 0.95
		else:
			mult = 0.85
		var impulse: Vector3 = base_impulse * falloff * mult
		# Add vertical GTA launch: ragdolls pop up slightly then flop
		impulse.y += randf_range(1.5, 3.2) * falloff
		# Add randomness for natural flop
		impulse += Vector3(randf_range(-1.2,1.2), randf_range(-0.4,0.9), randf_range(-1.2,1.2))
		# Limb wobble: add lateral
		if not is_torso and not is_head:
			impulse += Vector3(randf_range(-1.8,1.8), 0, randf_range(-1.8,1.8)) * 0.5

		pb.apply_central_impulse(impulse)
		# Add spin — GTA ragdolls spin and tumble (PhysicalBone3D has no apply_torque_impulse, use angular_velocity)
		var torque := Vector3(randf_range(-4,4), randf_range(-4,4), randf_range(-4,4))
		if is_torso:
			torque *= 0.7
		else:
			torque *= 1.3
		pb.angular_velocity += torque

	# Extra HIPS boost — ensures whole body flies if hit hard (GTA punch launch)
	if hips_bone and is_instance_valid(hips_bone):
		var launch: Vector3 = dir * strength * 1.45 + Vector3(0, 3.8, 0) + Vector3(randf_range(-1.0,1.0), 0, randf_range(-1.0,1.0))
		hips_bone.apply_central_impulse(launch)
		hips_bone.angular_velocity += Vector3(randf_range(-6,6), randf_range(-6,6), randf_range(-6,6))

	# Also give initial velocity to character body? Not needed after simulation started — physical bones own it
	# But we can also push skeleton's global position slightly to avoid z-fighting with floor
