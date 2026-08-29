extends Node
class_name RagdollGrabber
## RagdollGrabber — Press F to grab nearby ragdolled fighter and link its bones to your right hand.
## Attach as child of a CharacterBody3D (Player or any fighter). Needs a Skeleton3D somewhere under body.
##
## Behaviour:
##  - F toggles grab/release. While holding, finds 1-2 nearest PhysicalBone3D on the ragdolled target
##    and creates PinJoint3D(s) to a hand anchor (AnimatableBody3D driven by BoneAttachment3D).
##  - While held, target cannot respawn (Health.gd defers respawn until release).
##  - Drop on second F, on carrier death/ragdoll, or if target freed/distance excessive.
##
## Usage: Player.gd creates one and calls try_toggle_grab().

@export var grab_radius: float = 2.4
@export var grab_bone_radius: float = 1.2  # max distance from hand to bone to consider
@export var max_grab_bones: int = 2
@export var hand_bone_candidates: Array[String] = [
	"hand.r", "hand.R", "hand_r", "Hand_R",
	"righthand", "RightHand", "RightHand.x",
	"palm.r", "wrist.r"
]
@export var pin_bias: float = 0.85
@export var pin_damping: float = 0.6
@export var debug_log: bool = false
@export var grab_neck_exact: bool = true
@export var neck_bone_candidates: Array[String] = ["neck.x", "neck", "Neck", "neck_X", "Neck.X"]

var _carrier: CharacterBody3D = null
var _skeleton: Skeleton3D = null
var _hand_attachment: BoneAttachment3D = null
var _hand_anchor: AnimatableBody3D = null
var _hand_bone_idx: int = -1
var _hand_bone_name: String = ""
var _grabbed_body: CharacterBody3D = null
var _grabbed_ragdoll: Node = null
var _joints: Array[PinJoint3D] = []
var _joint_parent: Node = null
var _grabbed_bones: Array[PhysicalBone3D] = []
var _grab_offsets: Array[Vector3] = [] # offset from hand at grab time (to keep natural grip)
var _spring_stiffness: float = 11.0
var _spring_damping: float = 2.2
var _formation_bones: Array[PhysicalBone3D] = []
var _formation_offsets: Array[Vector3] = [] # offset from neck at grab time (to keep body formation while dragging)

func _ready() -> void:
	_carrier = get_parent() as CharacterBody3D
	if _carrier == null:
		var p := get_parent()
		while p and not p is CharacterBody3D:
			p = p.get_parent()
		_carrier = p as CharacterBody3D
	_find_skeleton()
	_ensure_hand_anchor()

func _physics_process(delta: float) -> void:
	# Auto-break conditions and spring-driven follow
	if _grabbed_body and is_instance_valid(_grabbed_body):
		# If carrier ragdolled/died -> drop
		if _carrier and _carrier.has_node("RagdollController"):
			var rc = _carrier.get_node("RagdollController")
			if rc and rc.has_method("is_ragdolled") and rc.is_ragdolled():
				release_grab()
				return
		# If grabbed is no longer ragdolled -> drop
		if _grabbed_ragdoll and _grabbed_ragdoll.has_method("is_ragdolled") and not _grabbed_ragdoll.is_ragdolled():
			release_grab()
			return
		# Spring pull: drive each grabbed bone toward hand
		_update_grab_spring(delta)
		# Keep grabbed body near carrier: if distance > 4m, pull whole ragdoll gently (optional)
	else:
		if _grabbed_body and not is_instance_valid(_grabbed_body):
			_cleanup_after_invalid_target()
		# Also clean if bones cleared but body remains (should not)
		if _grabbed_bones.is_empty() and _grabbed_body != null:
			_cleanup_after_invalid_target()

func _get_hand_world_pos() -> Vector3:
	if _hand_anchor and is_instance_valid(_hand_anchor):
		var p: Vector3 = _hand_anchor.global_position
		if p != Vector3.ZERO and p.distance_to(_carrier.global_position) < 5.0:
			return p
	if _skeleton and is_instance_valid(_skeleton) and _hand_bone_idx >= 0:
		# Use skeleton bone pose directly (more reliable than BoneAttachment first frame)
		var bpose: Transform3D = _skeleton.get_bone_global_pose(_hand_bone_idx)
		var world: Transform3D = _skeleton.global_transform * bpose
		return world.origin
	if _carrier:
		return _carrier.global_position + Vector3(0, 0.95, 0)
	return Vector3.ZERO

func _update_grab_spring(delta: float) -> void:
	if _grabbed_bones.is_empty():
		return
	if _carrier == null or not is_instance_valid(_carrier):
		return
	var hand_pos: Vector3 = _get_hand_world_pos()
	# --- Neck: exact parenting (visually connected) ---
	for i in range(_grabbed_bones.size()):
		var b := _grabbed_bones[i] as PhysicalBone3D
		if not is_instance_valid(b):
			continue
		var is_neck: bool = grab_neck_exact and b.bone_name.to_lower() in ["neck.x", "neck"]
		if is_neck:
			# Exact bone-to-bone glue: neck follows hand bone (follows animations)
			b.global_position = hand_pos
			# Optional: align neck rotation to hand for visual continuity
			# b.global_basis = _get_hand_world_basis()
			b.linear_velocity = Vector3.ZERO
			b.angular_velocity = Vector3.ZERO
			b.can_sleep = false
			continue
		else:
			var offset: Vector3 = _grab_offsets[i] if i < _grab_offsets.size() else Vector3.ZERO
			var target_pos: Vector3 = hand_pos + offset * 0.08
			var dir: Vector3 = target_pos - b.global_position
			var dist: float = dir.length()
			if dist < 0.06:
				b.linear_velocity = b.linear_velocity.lerp(Vector3.ZERO, 6.0 * delta)
				b.angular_velocity = b.angular_velocity.lerp(Vector3.ZERO, 6.0 * delta)
				continue
			var desired_vel: Vector3 = dir * _spring_stiffness
			var max_speed: float = 6.5
			if desired_vel.length() > max_speed:
				desired_vel = desired_vel.normalized() * max_speed
			var new_vel: Vector3 = b.linear_velocity.lerp(desired_vel, clamp(delta * 18.0, 0.0, 1.0))
			new_vel = new_vel.lerp(Vector3.ZERO, _spring_damping * delta * 0.07)
			b.linear_velocity = new_vel
			b.linear_velocity.y += 0.8 * delta * 10.0
			b.can_sleep = false
	# --- Formation hold: keep body from stretching by gently pulling other bones toward hand+offset ---
	# This makes drag look natural: you pull neck, the hips/spine/legs trail behind at fixed offset instead of staying
	for i in range(_formation_bones.size()):
		var pb := _formation_bones[i] as PhysicalBone3D
		if not is_instance_valid(pb) or pb in _grabbed_bones:
			continue
		var off: Vector3 = _formation_offsets[i] if i < _formation_offsets.size() else Vector3.ZERO
		var target: Vector3 = hand_pos + off
		# Keep formation on ground plane: lower vertical pull so body drags, not floats
		# Don't lift feet too high — clamp target y to near ground if was on ground
		var dir2: Vector3 = target - pb.global_position
		var d2: float = dir2.length()
		if d2 < 0.05 or d2 > 3.5:
			continue
		# Gentle formation spring — just enough to keep body together while dragging
		var w: float = 0.55
		var desired2: Vector3 = dir2 * 4.5 * w
		var max2: float = 4.0
		if desired2.length() > max2:
			desired2 = desired2.normalized() * max2
		# Horizontal bias: dragging should slide, not lift
		desired2.y *= 0.35
		pb.linear_velocity = pb.linear_velocity.lerp(desired2, clamp(delta * 6.0, 0.0, 1.0))
		pb.can_sleep = false

func _get_hand_world_basis() -> Basis:
	if _hand_anchor and is_instance_valid(_hand_anchor):
		return _hand_anchor.global_basis
	if _skeleton and is_instance_valid(_skeleton) and _hand_bone_idx >= 0:
		var bpose: Transform3D = _skeleton.get_bone_global_pose(_hand_bone_idx)
		var world: Transform3D = _skeleton.global_transform * bpose
		return world.basis
	return Basis()

# --- Public API ---

func is_grabbing() -> bool:
	return _grabbed_body != null and is_instance_valid(_grabbed_body) and (_joints.size() > 0 or _grabbed_bones.size() > 0)

func get_grabbed_body() -> CharacterBody3D:
	return _grabbed_body

func try_toggle_grab() -> bool:
	if is_grabbing():
		release_grab()
		return true
	else:
		return try_grab_nearest()

func try_grab_nearest() -> bool:
	if _carrier == null:
		return false
	if is_grabbing():
		return false
	# Don't grab while carrier is ragdolled
	if _carrier.has_node("RagdollController"):
		var rc = _carrier.get_node("RagdollController")
		if rc and rc.has_method("is_ragdolled") and rc.is_ragdolled():
			return false
	_find_skeleton()
	_ensure_hand_anchor()
	if _skeleton and _skeleton.has_method("force_update_bone_child_transforms"):
		_skeleton.force_update_bone_child_transforms()
	var hand_pos: Vector3 = _get_hand_world_pos()
	if hand_pos == Vector3.ZERO:
		hand_pos = _carrier.global_position + Vector3(0, 0.95, 0)

	var best := _find_best_ragdolled_body(hand_pos)
	if best == null:
		if debug_log:
			print("[Grabber] No ragdolled body within %.1fm of hand %s" % [grab_radius, hand_pos])
		return false

	var target: CharacterBody3D = best as CharacterBody3D
	var ragdoll = target.get_node_or_null("RagdollController")
	if ragdoll == null:
		return false
	# Find bones to grab: if grab_neck_exact, target neck bone directly
	var bones: Array = []
	if grab_neck_exact:
		var skel_neck: Skeleton3D = null
		if ragdoll and ragdoll.get("skeleton") != null:
			skel_neck = ragdoll.get("skeleton") as Skeleton3D
		if skel_neck == null:
			skel_neck = _search_skeleton(target)
		if skel_neck:
			var neck_pb: PhysicalBone3D = null
			for cand in neck_bone_candidates:
				for child in skel_neck.get_children():
					if child is PhysicalBone3D and (child as PhysicalBone3D).bone_name == cand:
						neck_pb = child as PhysicalBone3D
						break
				if neck_pb:
					break
			# Fallback: any bone containing "neck"
			if neck_pb == null:
				for child in skel_neck.get_children():
					if child is PhysicalBone3D and "neck" in (child as PhysicalBone3D).bone_name.to_lower():
						neck_pb = child as PhysicalBone3D
						break
			if neck_pb:
				var nd: float = hand_pos.distance_to(neck_pb.global_position)
				# Only neck-exact if reasonably close (avoid snapping from far); otherwise fallback
				if nd < grab_radius * 1.1:
					bones.append(neck_pb)
					if debug_log:
						print("[Grabber] Neck-exact mode: grabbing %s (%.2fm from hand)" % [neck_pb.bone_name, nd])
				else:
					if debug_log:
						print("[Grabber] Neck too far (%.2fm), fallback to nearest" % nd)
					neck_pb = null # force fallback
			else:
				if debug_log:
					print("[Grabber] Neck bone not found, falling back to nearest")
	if bones.is_empty():
		bones = _find_nearest_bones_on_target(target, ragdoll, hand_pos, max_grab_bones, grab_bone_radius)
		if bones.is_empty():
			if debug_log:
				print("[Grabber] No bones within %.2f of hand for %s" % [grab_bone_radius, target.name])
			return false
		# Always include central torso/hips bone so whole body follows and neck doesn't overstretch (only for nearest mode)
		if not grab_neck_exact:
			var hips_pb: PhysicalBone3D = null
			var skel_for_hips: Skeleton3D = null
			if ragdoll and ragdoll.get("skeleton") != null:
				skel_for_hips = ragdoll.get("skeleton") as Skeleton3D
			if skel_for_hips == null:
				skel_for_hips = _search_skeleton(target)
			if skel_for_hips:
				for cand in ["root.x", "hips", "Hips", "spine_01.x", "spine_02.x"]:
					for child in skel_for_hips.get_children():
						if child is PhysicalBone3D and (child as PhysicalBone3D).bone_name == cand:
							hips_pb = child as PhysicalBone3D
							break
					if hips_pb:
						break
				if hips_pb and hips_pb not in bones:
					if hand_pos.distance_to(hips_pb.global_position) < grab_radius * 1.6:
						bones.append(hips_pb)
						if debug_log:
							print("[Grabber] Added central bone %s to prevent stretch" % hips_pb.bone_name)

	# Store bones for spring-driven follow (primary) + also try PinJoint as secondary
	_grabbed_body = target
	_grabbed_ragdoll = ragdoll
	_grabbed_bones.clear()
	_grab_offsets.clear()
	# Compute per-bone offset so grip looks natural (keep relative offset at grab time)
	var hand_pos_current: Vector3 = _hand_anchor.global_position if _hand_anchor else hand_pos
	if hand_pos_current == Vector3.ZERO:
		hand_pos_current = hand_pos
	for pb in bones:
		var b := pb as PhysicalBone3D
		_grabbed_bones.append(b)
		if grab_neck_exact and b.bone_name.to_lower() in ["neck.x", "neck"]:
			_grab_offsets.append(Vector3.ZERO) # exact hand-to-neck, no gap
		else:
			_grab_offsets.append(b.global_position - hand_pos_current)
		b.can_sleep = false
		# Make grabbed bones lighter while held so they follow easily; also lower friction so they slide
		b.gravity_scale = 0.22 if grab_neck_exact else 0.28
		b.linear_damp = 0.9 if grab_neck_exact else 1.0
		b.angular_damp = 1.4 if grab_neck_exact else 1.6
		b.friction = 0.12 if grab_neck_exact else 0.15

	# For neck-exact, make rest of body slide easily so it gets dragged by neck instead of stretching
	_formation_bones.clear()
	_formation_offsets.clear()
	if grab_neck_exact:
		var skel_all2: Skeleton3D = null
		if ragdoll and ragdoll.get("skeleton") != null:
			skel_all2 = ragdoll.get("skeleton") as Skeleton3D
		if skel_all2 == null:
			skel_all2 = _search_skeleton(target)
		if skel_all2:
			for child in skel_all2.get_children():
				if not child is PhysicalBone3D:
					continue
				var pb2 := child as PhysicalBone3D
				if pb2 in _grabbed_bones:
					continue
				_formation_bones.append(pb2)
				_formation_offsets.append(Vector3.ZERO)
				pb2.can_sleep = false
				pb2.friction = 0.3
				pb2.linear_damp = 0.6
				pb2.angular_damp = 0.9
				pb2.gravity_scale = 0.9

	# No PinJoint for neck-exact — direct bone-to-bone teleport in _update (exact glue, follows anims)
	var created: int = 0

	# Mark target as grabbed -> blocks respawn (even if joints failed, spring still holds)
	_grabbed_body.set_meta("is_being_grabbed", true)
	_grabbed_body.set_meta("grabbed_by", _carrier)

	# Also set on carrier for HUD/debug
	_carrier.set_meta("is_grabbing", true)
	_carrier.set_meta("grabbed_body", _grabbed_body)

	# Disable collision between carrier and grabbed bones via exception (avoid explosive repulsion)
	for pb in bones:
		_hand_anchor.add_collision_exception_with(pb as PhysicalBone3D)
		# Also carrier body exception with that bone? Carrier is CharacterBody, not physics jitter but still
		if _carrier is PhysicsBody3D:
			(_carrier as PhysicsBody3D).add_collision_exception_with(pb as PhysicalBone3D)

	if debug_log:
		print("[Grabber] %s GRABBED %s with %d joint(s) on bones %s" % [_carrier.name, target.name, created, bones])

	# Visual feedback: brief scale punch on mesh
	var mesh = _carrier.get_node_or_null("Mesh")
	if mesh:
		var tw := _carrier.create_tween()
		var s := 1.06
		tw.tween_property(mesh, "scale", Vector3(s, 0.95, s), 0.07)
		tw.tween_property(mesh, "scale", Vector3.ONE, 0.12)

	return true

func release_grab() -> void:
	if _grabbed_body == null and _joints.is_empty() and _grabbed_bones.is_empty():
		return
	var body := _grabbed_body
	if debug_log and body:
		print("[Grabber] %s RELEASED %s" % [_carrier.name if _carrier else "?", body.name])

	# Free joints
	for j in _joints:
		if is_instance_valid(j):
			# Remove exception
			if _hand_anchor and j.get("node_b"):
				var node_b = j.get_node_or_null(j.node_b) as PhysicalBone3D
				if node_b and is_instance_valid(node_b) and _hand_anchor:
					_hand_anchor.remove_collision_exception_with(node_b)
				if _carrier is PhysicsBody3D and node_b:
					(_carrier as PhysicsBody3D).remove_collision_exception_with(node_b)
			j.queue_free()
	_joints.clear()
	# Restore grabbed bones physics
	for i in range(_grabbed_bones.size()):
		var b := _grabbed_bones[i] as PhysicalBone3D
		if is_instance_valid(b):
			b.gravity_scale = 1.0
			b.linear_damp = 0.35
			b.angular_damp = 0.38
			b.friction = 0.75
			# Give a small impulse on release so body drops naturally
			b.linear_velocity *= 0.35
			b.angular_velocity *= 0.7
			if _hand_anchor and is_instance_valid(_hand_anchor):
				_hand_anchor.remove_collision_exception_with(b)
			if _carrier is PhysicsBody3D and is_instance_valid(_carrier):
				(_carrier as PhysicsBody3D).remove_collision_exception_with(b)
	_grabbed_bones.clear()
	_grab_offsets.clear()
	# Restore formation bones (body) physics
	for fb in _formation_bones:
		if is_instance_valid(fb):
			fb.gravity_scale = 1.0
			fb.linear_damp = 0.35
			fb.angular_damp = 0.38
			fb.friction = 0.75
			fb.can_sleep = false
	_formation_bones.clear()
	_formation_offsets.clear()

	if body and is_instance_valid(body):
		if body.has_meta("is_being_grabbed"):
			body.remove_meta("is_being_grabbed")
		if body.has_meta("grabbed_by"):
			body.remove_meta("grabbed_by")
		# Health.gd's _wait_until_not_grabbed will wake up and respawn after original delay.

	if _carrier and is_instance_valid(_carrier):
		if _carrier.has_meta("is_grabbing"):
			_carrier.remove_meta("is_grabbing")
		if _carrier.has_meta("grabbed_body"):
			_carrier.remove_meta("grabbed_body")

	_grabbed_body = null
	_grabbed_ragdoll = null

	# Visual feedback
	if _carrier:
		var mesh = _carrier.get_node_or_null("Mesh")
		if mesh:
			var tw := _carrier.create_tween()
			tw.tween_property(mesh, "scale", Vector3(1.04, 0.97, 1.04), 0.06)
			tw.tween_property(mesh, "scale", Vector3.ONE, 0.11)

# --- Internal helpers ---

func _find_skeleton() -> void:
	if _skeleton and is_instance_valid(_skeleton):
		return
	if _carrier == null:
		return
	_skeleton = _search_skeleton(_carrier)
	if _skeleton == null and get_tree().current_scene:
		_skeleton = _search_skeleton(get_tree().current_scene)

func _search_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var r := _search_skeleton(c)
		if r:
			return r
	return null

func _ensure_hand_anchor() -> void:
	if _hand_anchor and is_instance_valid(_hand_anchor):
		return
	_find_skeleton()
	if _skeleton == null:
		if debug_log:
			print("[Grabber] No Skeleton3D found for %s" % (_carrier.name if _carrier else "?"))
		return
	# Find hand bone index
	_hand_bone_idx = -1
	_hand_bone_name = ""
	var bone_count := _skeleton.get_bone_count()
	for cand in hand_bone_candidates:
		var idx := _skeleton.find_bone(cand)
		if idx != -1:
			_hand_bone_idx = idx
			_hand_bone_name = _skeleton.get_bone_name(idx)
			break
	if _hand_bone_idx == -1:
		# Fuzzy search: find bone containing hand and r
		for i in range(bone_count):
			var bn: String = _skeleton.get_bone_name(i)
			var low := bn.to_lower()
			if "hand" in low and ("r" == low.right(1) or ".r" in low or "_r" in low or "right" in low):
				_hand_bone_idx = i
				_hand_bone_name = bn
				break
	# Fallback: any hand bone
	if _hand_bone_idx == -1:
		for i in range(bone_count):
			var bn: String = _skeleton.get_bone_name(i)
			if "hand" in bn.to_lower():
				_hand_bone_idx = i
				_hand_bone_name = bn
				break
	if _hand_bone_idx == -1:
		if debug_log:
			print("[Grabber] No hand bone found on %s, bones:" % _skeleton.name)
			for i in range(min(bone_count, 20)):
				print("  ", _skeleton.get_bone_name(i))
		return

	# Create BoneAttachment
	# Remove old if any
	var existing = _skeleton.get_node_or_null("GrabHandAttachment") as BoneAttachment3D
	if existing:
		_hand_attachment = existing
		# find anchor under it
		var anc = _hand_attachment.get_node_or_null("GrabHandAnchor") as AnimatableBody3D
		if anc:
			_hand_anchor = anc
			return
	else:
		_hand_attachment = BoneAttachment3D.new()
		_hand_attachment.name = "GrabHandAttachment"
		_hand_attachment.bone_name = _hand_bone_name
		# bone_idx is auto-set from bone_name
		_skeleton.add_child(_hand_attachment)
		_hand_attachment.owner = _skeleton.owner if _skeleton.owner else get_tree().current_scene

	# Create anchor body
	_hand_anchor = AnimatableBody3D.new()
	_hand_anchor.name = "GrabHandAnchor"
	_hand_attachment.add_child(_hand_anchor)
	_hand_anchor.owner = _skeleton.owner if _skeleton.owner else get_tree().current_scene
	# Sync to physics so joints update
	_hand_anchor.sync_to_physics = true
	_hand_anchor.collision_layer = 1
	_hand_anchor.collision_mask = 1
	var cs := CollisionShape3D.new()
	cs.name = "GrabColl"
	var sph := SphereShape3D.new()
	sph.radius = 0.09
	cs.shape = sph
	_hand_anchor.add_child(cs)
	cs.owner = _skeleton.owner if _skeleton.owner else get_tree().current_scene

	if _skeleton and _skeleton.has_method("force_update_bone_child_transforms"):
		_skeleton.force_update_bone_child_transforms()
	if debug_log:
		print("[Grabber] Hand anchor ready on %s bone=%s idx=%d at %s" % [_carrier.name, _hand_bone_name, _hand_bone_idx, _hand_anchor.global_position])

func _find_best_ragdolled_body(hand_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = grab_radius + 1.0
	# Search all fighters and dummies
	var candidates: Array[Node] = []
	candidates.append_array(get_tree().get_nodes_in_group("fighter"))
	candidates.append_array(get_tree().get_nodes_in_group("dummy"))
	candidates.append_array(get_tree().get_nodes_in_group("player"))
	# Also scan health group (covers any body with Health)
	for n in get_tree().get_nodes_in_group("health"):
		var body = (n as Node).get_parent() as Node3D
		if body and body not in candidates:
			candidates.append(body)

	var seen: Dictionary = {}
	for n in candidates:
		var body: Node3D = null
		if n is CharacterBody3D:
			body = n as CharacterBody3D
		elif n is Node and (n as Node).get_parent() is CharacterBody3D:
			body = (n as Node).get_parent() as Node3D
		else:
			continue
		if body == _carrier or body == null or not is_instance_valid(body):
			continue
		var id := body.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		# Must be ragdolled
		var rag = body.get_node_or_null("RagdollController")
		if rag == null or not rag.has_method("is_ragdolled") or not rag.is_ragdolled():
			continue
		# Distance check: use hand to body or to nearest bone
		var d: float = hand_pos.distance_to(body.global_position + Vector3(0, 0.9, 0))
		# Also try nearest bone if skeleton available (more accurate)
		var skel: Skeleton3D = null
		if rag and rag.get("skeleton") != null:
			skel = rag.get("skeleton") as Skeleton3D
		if skel == null:
			skel = _search_skeleton(body)
		if skel:
			var min_bd: float = INF
			for child in skel.get_children():
				if child is PhysicalBone3D:
					var bd: float = hand_pos.distance_to((child as PhysicalBone3D).global_position)
					if bd < min_bd:
						min_bd = bd
			if min_bd != INF:
				d = min(d, min_bd)
		if d > grab_radius:
			continue
		if d < best_d:
			best_d = d
			best = body
	return best

func _find_nearest_bones_on_target(target: Node3D, ragdoll: Node, hand_pos: Vector3, max_count: int, max_dist: float) -> Array:
	var out: Array = []
	var skel: Skeleton3D = null
	if ragdoll and ragdoll.get("skeleton") != null:
		skel = ragdoll.get("skeleton") as Skeleton3D
	if skel == null:
		skel = _search_skeleton(target)
	if skel == null:
		return out
	# Collect all PhysicalBones with distance
	var pairs: Array = []
	for child in skel.get_children():
		if child is PhysicalBone3D:
			var pb := child as PhysicalBone3D
			var d: float = hand_pos.distance_to(pb.global_position)
			if d <= max_dist:
				pairs.append({"pb": pb, "d": d})
	pairs.sort_custom(func(a, b): return a["d"] < b["d"])
	for i in range(min(max_count, pairs.size())):
		out.append(pairs[i]["pb"])
	# If none within max_dist, pick absolute nearest 1 (so grab still works if target slid away a bit)
	if out.is_empty() and pairs.is_empty():
		# Find global nearest regardless of dist (up to grab_radius*1.5)
		var closest: PhysicalBone3D = null
		var best_d: float = INF
		for child in skel.get_children():
			if child is PhysicalBone3D:
				var pb2 := child as PhysicalBone3D
				var d2: float = hand_pos.distance_to(pb2.global_position)
				if d2 < best_d:
					best_d = d2
					closest = pb2
		if closest and best_d <= grab_radius * 1.2:
			out.append(closest)
	return out

func _create_pin_joint(body_a: PhysicsBody3D, body_b: PhysicsBody3D) -> PinJoint3D:
	if body_a == null or body_b == null:
		return null
	var j := PinJoint3D.new()
	j.name = "GrabJoint_%s_%s" % [body_a.name, body_b.name]
	# Use absolute paths; will be resolved after joint is added to scene tree
	j.node_a = body_a.get_path()
	j.node_b = body_b.get_path()
	if j.has_method("set_param"):
		j.set_param(PinJoint3D.PARAM_BIAS, pin_bias)
		j.set_param(PinJoint3D.PARAM_DAMPING, pin_damping)
		j.set_param(PinJoint3D.PARAM_IMPULSE_CLAMP, 0.0)
	# Anchor at hand so bone snaps to hand immediately
	j.global_position = body_a.global_position
	return j

func _get_joint_parent() -> Node:
	if _joint_parent and is_instance_valid(_joint_parent):
		return _joint_parent
	# Prefer current_scene root
	var sc = get_tree().current_scene
	if sc:
		_joint_parent = sc
	else:
		_joint_parent = get_tree().root
	return _joint_parent

func _schedule_respawn_if_needed(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var health = body.get_node_or_null("Health")
	if health == null or not health.get("is_dead"):
		return
	# Don't double schedule if already pending
	# We use a meta to avoid spam
	if body.has_meta("grab_respawn_scheduled"):
		return
	body.set_meta("grab_respawn_scheduled", true)
	# After short delay, attempt respawn (Health will handle via body.respawn / _respawn_after_death)
	# We call after 0.8s so body settles after drop
	var tree := get_tree()
	if tree == null:
		return
	var respawn_delay: float = 1.0
	if body.get("respawn_time") != null:
		respawn_delay = max(float(body.get("respawn_time")), 1.0)
	# For player, fixed 1.0
	if body.is_in_group("player"):
		respawn_delay = 1.0
	# Use timer
	var t := tree.create_timer(respawn_delay)
	t.timeout.connect(func():
		if not is_instance_valid(body):
			return
		body.remove_meta("grab_respawn_scheduled")
		# Check still dead and not grabbed again
		if body.has_meta("is_being_grabbed"):
			# Re-schedule
			_schedule_respawn_if_needed(body)
			return
		var h2 = body.get_node_or_null("Health")
		if h2 and h2.get("is_dead"):
			# Call appropriate respawn
			if body.has_method("respawn"):
				body.call("respawn")
				# Ensure health reset
				if h2 and h2.get("current") <= 0:
					h2.set("current", h2.get("max_health"))
					h2.set("is_dead", false)
					if h2.has_signal("health_changed"):
						h2.emit_signal("health_changed", h2.get("current"), h2.get("max_health"))
			elif body.has_method("_respawn_after_death"):
				body.call("_respawn_after_death")
			else:
				# Fallback via Health
				if h2:
					h2.set("current", h2.get("max_health"))
					h2.set("is_dead", false)
	)

func _cleanup_after_invalid_target() -> void:
	for j in _joints:
		if is_instance_valid(j):
			j.queue_free()
	_joints.clear()
	for b in _grabbed_bones:
		if is_instance_valid(b):
			b.gravity_scale = 1.0
			b.linear_damp = 0.35
			b.angular_damp = 0.38
			b.friction = 0.75
	_grabbed_bones.clear()
	_grab_offsets.clear()
	for fb in _formation_bones:
		if is_instance_valid(fb):
			fb.gravity_scale = 1.0
			fb.linear_damp = 0.35
			fb.angular_damp = 0.38
			fb.friction = 0.75
	_formation_bones.clear()
	_formation_offsets.clear()
	_grabbed_body = null
	_grabbed_ragdoll = null
	if _carrier:
		if _carrier.has_meta("is_grabbing"):
			_carrier.remove_meta("is_grabbing")
		if _carrier.has_meta("grabbed_body"):
			_carrier.remove_meta("grabbed_body")

func _exit_tree() -> void:
	if is_grabbing():
		release_grab()
