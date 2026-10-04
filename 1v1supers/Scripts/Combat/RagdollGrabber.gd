extends Node
class_name RagdollGrabber
## Grab a nearby ragdolled fighter by the neck and carry it in the right hand.
## Child of a CharacterBody3D (the carrier) that has a Skeleton3D somewhere below it.
##
##  - A PinJoint3D joins a hand-anchored AnimatableBody3D to the target's neck
##    PhysicalBone3D: a hard, responsive attachment with no stretching.
##  - The rest of the body dangles through its own ragdoll joints; a gentle
##    formation spring (offsets captured at grab time) keeps it from crumpling.
##  - While held, the target's RagdollController.held_by is set, which defers its respawn.
##  - Released on request, on carrier death/ragdoll, or when the target recovers.

@export var grab_radius: float = 2.4
@export var grab_bone_radius: float = 1.2 # max distance from hand to bone to consider
@export var max_grab_bones: int = 2
@export var hand_bone_candidates: Array[String] = ["hand.r", "hand.R", "hand_r", "Hand_R", "righthand", "RightHand"]
@export var pin_damping: float = 1.0
@export var debug_log: bool = false
@export var grab_neck_exact: bool = true
@export var neck_bone_candidates: Array[String] = ["neck.x", "neck", "Neck"]

# --- Formation/drag tuning (responsive but not crumpling) ---
@export var formation_pull: float = 22.0 # accel (m/s^2) toward formation position, scaled by error
@export var formation_max_speed: float = 7.0
@export var formation_max_dist: float = 2.6 # farther than this -> ignore (body trails naturally)

# --- Carrier collision (held body vs carrier capsule) ---
# Held bones keep colliding with the carrier's capsule so the corpse drapes on the
# player instead of clipping through; this pushes out what the solver leaves inside.
@export var collide_with_carrier: bool = true
@export var carrier_separation_margin: float = 0.08 # extra gap beyond capsule+bone radii
@export var carrier_separation_push: float = 8.0 # velocity push when a held bone penetrates the capsule
@export var carrier_separation_max_corr: float = 0.12 # max positional depenetration per physics frame (m)

var _carrier: CharacterBody3D = null
var _carrier_ragdoll: RagdollController = null
var _skeleton: Skeleton3D = null
var _hand_attachment: BoneAttachment3D = null
var _hand_anchor: AnimatableBody3D = null
var _hand_bone_idx: int = -1
var _grabbed: RagdollController = null
var _joints: Array[PinJoint3D] = []
var _grabbed_bones: Array[PhysicalBone3D] = []
var _grab_offsets: Array[Vector3] = []
var _formation_bones: Array[PhysicalBone3D] = []
var _formation_offsets: Array[Vector3] = []
var _grab_age: float = 0.0 # seconds since grab (safety drop has a grace period while reeling in)

func _ready() -> void:
	_carrier = get_parent() as CharacterBody3D
	if _carrier:
		_carrier_ragdoll = _carrier.get_node_or_null("RagdollController") as RagdollController
		_skeleton = RagdollController._find_first(_carrier, "Skeleton3D") as Skeleton3D
	_ensure_hand_anchor()

# --- Public API ---------------------------------------------------------------

func is_grabbing() -> bool:
	return _grabbed != null and is_instance_valid(_grabbed) and not _grabbed_bones.is_empty()

func get_grabbed_body() -> CharacterBody3D:
	return _grabbed.get_body() if is_grabbing() else null

## The bone pinned to the hand (null when not grabbing).
func get_grabbed_bone() -> PhysicalBone3D:
	return _grabbed_bones[0] if is_grabbing() else null

func get_joint_count() -> int:
	return _joints.size()

func get_hand_position() -> Vector3:
	if _hand_anchor and is_instance_valid(_hand_anchor):
		return _hand_anchor.global_position
	if _carrier:
		return _carrier.global_position + Vector3(0, 0.95, 0)
	return Vector3.ZERO

func try_toggle_grab() -> bool:
	if is_grabbing():
		release_grab()
		return true
	return try_grab_nearest()

func try_grab_nearest() -> bool:
	if _carrier == null or is_grabbing():
		return false
	if _carrier_ragdoll and _carrier_ragdoll.is_ragdolled():
		return false
	_ensure_hand_anchor()
	if _skeleton:
		_skeleton.force_update_all_bone_transforms()
	_update_hand_anchor_transform()
	var hand_pos := get_hand_position()
	var target := _find_best_ragdoll(hand_pos)
	if target == null:
		if debug_log:
			print("[Grabber] No ragdolled body within %.1fm of hand %s" % [grab_radius, hand_pos])
		return false
	# The body was already validated as in range: take the neck (then torso) and
	# reel it into the grip, rather than whatever limb happened to land nearest.
	var bones: Array[PhysicalBone3D] = []
	if grab_neck_exact:
		var primary := _find_priority_bone(target)
		if primary:
			bones.append(primary)
	if bones.is_empty():
		bones = _find_nearest_bones(target, hand_pos, max_grab_bones, grab_bone_radius)
		if bones.is_empty():
			return false

	_grabbed = target
	_grab_age = 0.0
	_grabbed_bones.clear()
	_grab_offsets.clear()
	for b in bones:
		_grabbed_bones.append(b)
		_grab_offsets.append(Vector3.ZERO if String(b.bone_name).to_lower() in ["neck.x", "neck"] else b.global_position - hand_pos)
		b.can_sleep = false
		# The joint does the work; mild values keep the body from floating/rubbery
		b.gravity_scale = 0.55
		b.linear_damp = 0.9
		b.angular_damp = 1.2
		b.friction = 0.2
	# Formation: real offsets from the hand at grab time (clamped for far limbs)
	_formation_bones.clear()
	_formation_offsets.clear()
	for pb in target.get_bones():
		if pb in _grabbed_bones:
			continue
		_formation_bones.append(pb)
		var off: Vector3 = pb.global_position - hand_pos
		if off.length() > 1.6:
			off = off.normalized() * 1.6
		_formation_offsets.append(off)
		pb.can_sleep = false
		pb.friction = 0.3
		pb.linear_damp = 0.5
		pb.angular_damp = 0.8
		pb.gravity_scale = 0.85
	# Snap the whole ragdoll into the grip BEFORE creating the joint: a joint created
	# across metres of gap in Jolt launches the bone at huge speed.
	var grab_delta: Vector3 = hand_pos - _grabbed_bones[0].global_position
	for b in _grabbed_bones + _formation_bones:
		b.global_position += grab_delta
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO
	# The attachment: PinJoint3D from the hand anchor to the primary bone only
	_joints.clear()
	if _hand_anchor and is_instance_valid(_hand_anchor):
		var j := _create_pin_joint(_hand_anchor, _grabbed_bones[0])
		if j:
			_joints.append(j)
	target.held_by = _carrier
	_ensure_carrier_collision()
	if debug_log:
		print("[Grabber] %s GRABBED %s with %d joint(s)" % [_carrier.name, target.get_body().name, _joints.size()])
	return true

func release_grab() -> void:
	if _grabbed == null and _joints.is_empty() and _grabbed_bones.is_empty():
		return
	for j in _joints:
		if is_instance_valid(j):
			j.queue_free()
	_joints.clear()
	for b in _grabbed_bones:
		if is_instance_valid(b):
			b.linear_velocity *= 0.35 # small carry-over so the body drops naturally
			b.angular_velocity *= 0.7
	_restore_bone_physics()
	if _grabbed and is_instance_valid(_grabbed):
		_grabbed.held_by = null
		if debug_log:
			print("[Grabber] %s RELEASED %s" % [str(_carrier.name) if _carrier else "?", _grabbed.get_body().name])
	_grabbed = null

# --- Per-frame ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	# Drive the kinematic hand anchor from the animated hand bone EVERY frame:
	# sync_to_physics only forwards the node's own transform changes, so the
	# carrier walking would otherwise leave the joint pinned to a fixed point.
	_update_hand_anchor_transform()
	if _grabbed == null:
		return
	if not is_instance_valid(_grabbed) or _grabbed_bones.is_empty():
		_restore_bone_physics()
		_grabbed = null
		return
	_grab_age += delta
	if _carrier_ragdoll and _carrier_ragdoll.is_ragdolled():
		release_grab()
		return
	if not _grabbed.is_ragdolled():
		release_grab()
		return
	_update_grab_spring(delta)
	if collide_with_carrier:
		_enforce_carrier_separation(delta)
	# Safety: drop only if the pinned bone is STILL far from the hand well after
	# the reel-in should have connected.
	if _grab_age > 1.2:
		var pb := _grabbed_bones[0]
		if is_instance_valid(pb) and pb.global_position.distance_to(get_hand_position()) > 8.0:
			release_grab()

func _update_hand_anchor_transform() -> void:
	if _hand_anchor and is_instance_valid(_hand_anchor) and _skeleton and _hand_bone_idx >= 0:
		# An explicit global_transform set is a real transform change, which
		# sync_to_physics forwards to the physics server (with velocity).
		_hand_anchor.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_hand_bone_idx)

func _update_grab_spring(delta: float) -> void:
	var use_joints := not _joints.is_empty()
	var hand := get_hand_position()
	for i in range(_grabbed_bones.size()):
		var b := _grabbed_bones[i]
		if not is_instance_valid(b):
			continue
		b.can_sleep = false
		if use_joints:
			# The PinJoint holds it rigidly — don't fight the solver
			b.linear_damp = 0.9
			b.angular_damp = 1.2
			continue
		# Fallback (no joint): velocity spring toward the hand
		var target_pos: Vector3 = hand + _grab_offsets[i] * 0.15
		var dir: Vector3 = target_pos - b.global_position
		if dir.length() < 0.06:
			b.linear_velocity = b.linear_velocity.lerp(Vector3.ZERO, 6.0 * delta)
			continue
		b.linear_velocity = b.linear_velocity.lerp((dir * 11.0).limit_length(9.0), clampf(delta * 18.0, 0.0, 1.0))
	# Formation hold: pull the rest of the body toward its grab-time pose relative to the hand
	for i in range(_formation_bones.size()):
		var pb := _formation_bones[i]
		if not is_instance_valid(pb):
			continue
		var dir2: Vector3 = hand + _formation_offsets[i] - pb.global_position
		var d2: float = dir2.length()
		if d2 < 0.05 or d2 > formation_max_dist:
			continue
		var desired: Vector3 = dir2.normalized() * minf(d2 * formation_pull * 0.5, formation_max_speed)
		desired.y *= 0.6 # dragging should slide/trail, not float
		pb.linear_velocity = pb.linear_velocity.lerp(desired, clampf(delta * 10.0, 0.0, 1.0))
		pb.can_sleep = false

func _restore_bone_physics() -> void:
	for b in _grabbed_bones + _formation_bones:
		if is_instance_valid(b):
			b.gravity_scale = 1.0
			b.linear_damp = RagdollController.DAMP_LINEAR
			b.angular_damp = RagdollController.DAMP_ANGULAR
			b.friction = 0.75
	_grabbed_bones.clear()
	_grab_offsets.clear()
	_formation_bones.clear()
	_formation_offsets.clear()

func _ensure_carrier_collision() -> void:
	# Held bones must share a layer with the carrier to generate contacts.
	if _carrier == null:
		return
	var carrier_layer: int = _carrier.collision_layer if _carrier.collision_layer != 0 else 1
	for b in _grabbed_bones + _formation_bones:
		if not is_instance_valid(b):
			continue
		_carrier.remove_collision_exception_with(b)
		if b.collision_layer == 0:
			b.collision_layer = 1
		b.collision_mask = (b.collision_mask | carrier_layer) if b.collision_mask != 0 else 1

func _get_carrier_capsule() -> Dictionary:
	# The carrier's vertical capsule segment in world space (default humanoid fallback)
	var fallback := {"center": _carrier.global_position + Vector3(0, 0.92, 0), "radius": 0.30, "half_height": 0.62}
	var cs := _carrier.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null or not (cs.shape is CapsuleShape3D):
		return fallback
	var cap := cs.shape as CapsuleShape3D
	return {"center": cs.global_position, "radius": cap.radius * cs.scale.x,
		"half_height": maxf((cap.height * 0.5 - cap.radius) * cs.scale.y, 0.05)}

func _estimate_bone_radius(pb: PhysicalBone3D) -> float:
	for child in pb.get_children():
		if child is CollisionShape3D and child.shape:
			var shape: Shape3D = child.shape
			if shape is SphereShape3D:
				return shape.radius
			if shape is CapsuleShape3D:
				return shape.radius
			if shape is BoxShape3D:
				var sz: Vector3 = shape.size
				return minf(minf(sz.x, sz.y), sz.z) * 0.5
	return 0.12

func _enforce_carrier_separation(delta: float) -> void:
	# Soft depenetration: push held bones out of the carrier capsule so the corpse
	# drapes on the player (physics contacts do the hard constraint).
	var cap := _get_carrier_capsule()
	var center: Vector3 = cap["center"]
	var radius: float = cap["radius"]
	var half_height: float = cap["half_height"]
	var hand_pos := get_hand_position()
	for pb in _grabbed_bones + _formation_bones:
		if not is_instance_valid(pb):
			continue
		# The pinned neck lives AT the hand by design — never fight the PinJoint
		if pb in _grabbed_bones and pb.global_position.distance_to(hand_pos) < 0.22:
			continue
		var bone_pos: Vector3 = pb.global_position
		var closest := Vector3(center.x, clampf(bone_pos.y, center.y - half_height, center.y + half_height), center.z)
		var diff: Vector3 = bone_pos - closest
		var dist: float = diff.length()
		var min_dist: float = radius + _estimate_bone_radius(pb) + carrier_separation_margin
		if dist >= min_dist or dist < 0.0001:
			continue
		var push_dir: Vector3 = diff / maxf(dist, 0.0001)
		if dist < 0.02:
			# Degenerate (dead centre): push toward the hand side
			var to_hand: Vector3 = hand_pos - closest
			to_hand.y = 0.0
			push_dir = to_hand.normalized() if to_hand.length() > 0.05 else Vector3.FORWARD
		var penetration: float = min_dist - dist
		pb.global_position += push_dir * minf(penetration, carrier_separation_max_corr)
		# Velocity push so the solver carries the separation instead of snapping back
		var push_vel: Vector3 = (push_dir * (penetration * carrier_separation_push)).limit_length(4.0)
		var inward: float = -pb.linear_velocity.dot(push_dir)
		if inward > 0.0:
			pb.linear_velocity += push_dir * inward * minf(delta * 12.0, 1.0)
		pb.linear_velocity += push_vel * minf(delta * 6.0, 1.0)
		pb.can_sleep = false

# --- Setup / search helpers ----------------------------------------------------

func _ensure_hand_anchor() -> void:
	if _hand_anchor and is_instance_valid(_hand_anchor):
		return
	if _skeleton == null:
		return
	_hand_bone_idx = -1
	for cand in hand_bone_candidates:
		_hand_bone_idx = _skeleton.find_bone(cand)
		if _hand_bone_idx != -1:
			break
	if _hand_bone_idx == -1:
		push_warning("[Grabber] No right-hand bone found on %s" % _skeleton.name)
		return
	_hand_attachment = BoneAttachment3D.new()
	_hand_attachment.name = "GrabHandAttachment"
	_hand_attachment.bone_name = _skeleton.get_bone_name(_hand_bone_idx)
	_skeleton.add_child(_hand_attachment)
	# Kinematic anchor for the joint. No collision at all: if it collided, the hand
	# would shove ragdoll bones around every frame (jitter/stretch).
	_hand_anchor = AnimatableBody3D.new()
	_hand_anchor.name = "GrabHandAnchor"
	_hand_anchor.sync_to_physics = true
	_hand_anchor.collision_layer = 0
	_hand_anchor.collision_mask = 0
	_hand_attachment.add_child(_hand_anchor)

func _find_best_ragdoll(hand_pos: Vector3) -> RagdollController:
	var best: RagdollController = null
	var best_d: float = grab_radius
	for n in get_tree().get_nodes_in_group("ragdoll"):
		var rag := n as RagdollController
		if rag == null or rag == _carrier_ragdoll or not rag.is_ragdolled() or rag.is_held():
			continue
		var body := rag.get_body()
		if body == null:
			continue
		# Distance to the body's centre or its nearest bone, whichever is closer
		var d: float = hand_pos.distance_to(body.global_position + Vector3(0, 0.9, 0))
		for pb in rag.get_bones():
			d = minf(d, hand_pos.distance_to(pb.global_position))
		if d <= best_d:
			best_d = d
			best = rag
	return best

func _find_nearest_bones(target: RagdollController, hand_pos: Vector3, max_count: int, max_dist: float) -> Array[PhysicalBone3D]:
	var bones := target.get_bones()
	bones.sort_custom(func(a, b): return hand_pos.distance_to(a.global_position) < hand_pos.distance_to(b.global_position))
	var out: Array[PhysicalBone3D] = []
	for pb in bones:
		if out.size() >= max_count or hand_pos.distance_to(pb.global_position) > max_dist:
			break
		out.append(pb)
	# Nothing within reach: take the single nearest bone if it is still close-ish
	if out.is_empty() and not bones.is_empty() and hand_pos.distance_to(bones[0].global_position) <= grab_radius * 1.2:
		out.append(bones[0])
	return out

func _find_priority_bone(target: RagdollController) -> PhysicalBone3D:
	# Neck first (GTA-style), then torso centre, then hips
	var priority: Array[String] = []
	priority.append_array(neck_bone_candidates)
	priority.append_array(["spine_03.x", "spine_02.x", "spine_01.x", "root.x", "hips", "Hips", "spine"])
	for cand in priority:
		var b := target.get_bone(cand)
		if b:
			return b
	return null

func _create_pin_joint(body_a: PhysicsBody3D, body_b: PhysicsBody3D) -> PinJoint3D:
	var j := PinJoint3D.new()
	j.name = "GrabJoint"
	HitEffects.parent_for(self).add_child(j)
	j.global_position = body_a.global_position # anchor AT the hand
	j.node_a = body_a.get_path()
	j.node_b = body_b.get_path()
	# PinJoint3D bias is unsupported in Jolt (warning spam) — damping only
	j.set_param(PinJoint3D.PARAM_DAMPING, pin_damping)
	j.set_param(PinJoint3D.PARAM_IMPULSE_CLAMP, 0.0)
	return j

func _exit_tree() -> void:
	if is_grabbing():
		release_grab()
