extends Node
class_name RagdollController
## GTA-style ragdoll for a CharacterBody3D (Player or Dummy). Builds PhysicalBones
## for the character's Skeleton3D on first use and is the ONLY thing that starts a
## death ragdoll: it listens to Health.died and launches the body along the
## killing blow's knockback.

## A grabber holding this ragdoll changes this (RagdollGrabber sets/clears it).
signal held_changed(is_held: bool)
## Emitted right before the bones go physical: the body should stop any mesh
## scale effects (Jolt cannot simulate non-uniformly scaled bodies).
signal about_to_start()

@export var skeleton_path: NodePath = NodePath("")
@export var capsule_radius_scale: float = 1.0
@export var impulse_multiplier: float = 1.0 # scales every death launch
@export var death_impulse: float = 7.0 # launch strength when the killing blow had no knockback
@export var debug_log: bool = false

var skeleton: Skeleton3D = null
## The fighter carrying this ragdoll right now (null when not held).
var held_by: Node3D = null:
	set(v):
		var was := held_by != null
		held_by = v
		if was != (v != null):
			held_changed.emit(v != null)

var _character_body: CharacterBody3D = null
var _health: Health = null
var _anim_player: AnimationPlayer = null
var _anim_tree: AnimationTree = null
var _collision_shape: CollisionShape3D = null
var _original_collision_layer: int = 1
var _original_collision_mask: int = 1
var _is_ragdolled: bool = false
var _built: bool = false

# GTA feel tuning
const DAMP_LINEAR: float = 0.35
const DAMP_ANGULAR: float = 0.38

func _ready() -> void:
	add_to_group("ragdoll")
	_character_body = get_parent() as CharacterBody3D
	if _character_body:
		_original_collision_layer = _character_body.collision_layer
		_original_collision_mask = _character_body.collision_mask
		_collision_shape = _character_body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_health = _character_body.get_node_or_null("Health") as Health
		if _health:
			_health.died.connect(_on_health_died)
		_anim_tree = _character_body.get_node_or_null("AnimationTree") as AnimationTree
	_find_skeleton()
	if _character_body:
		_anim_player = _find_first(_character_body, "AnimationPlayer") as AnimationPlayer

func get_body() -> CharacterBody3D:
	return _character_body

func is_ragdolled() -> bool:
	return _is_ragdolled

func is_held() -> bool:
	return held_by != null and is_instance_valid(held_by)

## Every PhysicalBone3D of the ragdoll (empty until first ragdolled).
func get_bones() -> Array[PhysicalBone3D]:
	var out: Array[PhysicalBone3D] = []
	if skeleton:
		for c in skeleton.get_children():
			if c is PhysicalBone3D:
				out.append(c)
	return out

func get_bone(bone_name: String) -> PhysicalBone3D:
	for b in get_bones():
		if String(b.bone_name) == bone_name:
			return b
	return null

func _find_skeleton() -> void:
	if skeleton and is_instance_valid(skeleton):
		return
	if skeleton_path != NodePath(""):
		skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if skeleton == null and _character_body:
		skeleton = _find_first(_character_body, "Skeleton3D") as Skeleton3D

static func _find_first(node: Node, type_name: String) -> Node:
	if node == null:
		return null
	if node.is_class(type_name):
		return node
	for c in node.get_children():
		var r := _find_first(c, type_name)
		if r:
			return r
	return null

func start_ragdoll(hit_direction: Vector3 = Vector3.ZERO, hit_position: Vector3 = Vector3.ZERO, hit_strength: float = 5.0) -> void:
	if _is_ragdolled:
		return
	_find_skeleton()
	if skeleton == null:
		push_warning("[Ragdoll] No Skeleton3D found for %s" % (str(_character_body.name) if _character_body else "unknown"))
		return
	_ensure_physical_bones()
	about_to_start.emit()
	# Freeze animation so the bones start from the current pose
	if _anim_tree:
		_anim_tree.active = false
	if _anim_player:
		_anim_player.active = false
		_anim_player.stop(false)
	# The CharacterBody must not fight the physical bones
	if _character_body:
		_character_body.collision_layer = 0
		_character_body.collision_mask = 0
		if _collision_shape:
			_collision_shape.disabled = true
		_character_body.velocity = Vector3.ZERO
	skeleton.physical_bones_start_simulation()
	for pb in get_bones():
		pb.can_sleep = false
		pb.collision_layer = 1 # reset_ragdoll zeroes these
		pb.collision_mask = 1
	_is_ragdolled = true
	# Apply the launch next frame so the bodies are awake
	call_deferred("_apply_ragdoll_impulse", hit_direction, hit_position, hit_strength)
	if debug_log:
		print("[Ragdoll] START %s dir=%s str=%.1f" % [_character_body.name, hit_direction, hit_strength])

## Stops the simulation and puts the character back under animation control.
## restore_collision=false leaves the body's CollisionShape3D disabled (the caller
## re-enables it later, e.g. after a respawn lock).
func reset_ragdoll(restore_collision: bool = true) -> void:
	if not _is_ragdolled and not _built:
		return
	held_by = null
	if skeleton and is_instance_valid(skeleton):
		for pb in get_bones():
			pb.linear_velocity = Vector3.ZERO
			pb.angular_velocity = Vector3.ZERO
			pb.can_sleep = true
		if _is_ragdolled:
			skeleton.physical_bones_stop_simulation()
			skeleton.reset_bone_poses()
			skeleton.force_update_all_bone_transforms()
		# Free the physical bones until the next death: left in place they follow the
		# animated skeleton, whose stretch bones scale non-uniformly, and Jolt rebuilds
		# (and complains about) every bone shape on each scale change.
		for pb in get_bones():
			skeleton.remove_child(pb)
			pb.queue_free()
		_built = false
	_is_ragdolled = false
	if _character_body:
		_character_body.collision_layer = _original_collision_layer
		_character_body.collision_mask = _original_collision_mask
		if _collision_shape and restore_collision:
			_collision_shape.disabled = false
		_character_body.velocity = Vector3.ZERO
		_character_body.reset_physics_interpolation()
	if _anim_tree:
		_anim_tree.active = true
	if _anim_player:
		_anim_player.active = true
		if _anim_tree == null and _anim_player.has_animation("Idle"):
			_anim_player.play("Idle", 0.2)
	if debug_log and _character_body:
		print("[Ragdoll] RESET %s" % _character_body.name)

## The ONLY place a death ragdoll is started. Direction/strength come from the
## killing blow's knockback when there was one, else from the killer's position.
func _on_health_died(hit: HitInfo) -> void:
	if _character_body == null:
		return
	var killer: Node3D = hit.attacker if hit else null
	var pos: Vector3 = _character_body.global_position + Vector3(0, 0.9, 0)
	var dir := Vector3.ZERO
	var strength: float = death_impulse
	var kb: Vector3 = hit.knockback if hit else Vector3.ZERO
	if kb.length() > 0.5:
		dir = kb.normalized()
		strength = kb.length() * 0.9 + 5.0
	elif killer and is_instance_valid(killer) and killer != _character_body:
		dir = _character_body.global_position - killer.global_position
		dir.y = 0.2
		if dir.length() < 0.1:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		if killer is CharacterBody3D:
			var kv: Vector3 = (killer as CharacterBody3D).velocity
			if kv.length() > 1.0:
				dir = (dir + kv.normalized() * 0.5).normalized()
				strength += kv.length() * 0.25
	else:
		dir = Vector3(randf_range(-1, 1), 0.2, randf_range(-1, 1)).normalized()
	start_ragdoll(dir, pos, strength * impulse_multiplier)

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
		print("[Ragdoll] Building %d bones for %s" % [bone_count, str(_character_body.name) if _character_body else "?"])
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
		var cfg := _config_for_bone(bname)
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
		pb.joint_type = jtype as PhysicalBone3D.JointType
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

func _config_for_bone(bname: String) -> Dictionary:
	var lname := bname.to_lower()
	var cfg: Dictionary = {}

	# --- C11 naming (C11.glb) ---
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
