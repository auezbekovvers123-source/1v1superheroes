extends Node
class_name RagdollGrabber
## RagdollGrabber — Press F to grab nearby ragdolled fighter and pin its neck to your right hand.
## Attach as child of a CharacterBody3D (Player or any fighter). Needs a Skeleton3D somewhere under body.
##
## Behaviour:
##  - F toggles grab/release. On grab, creates a real PinJoint3D between a hand-anchored
##    AnimatableBody3D (BoneAttachment3D-driven, sync_to_physics) and the target's neck
##    PhysicalBone3D -> hard, responsive attachment with no stretching.
##  - Rest of the body dangles from the neck through its own ragdoll joints; a gentle
##    formation spring (offsets captured at grab time) keeps it from crumpling.
##  - While held, target cannot respawn (Health.gd defers respawn until release).
##  - Drop on second F, on carrier death/ragdoll, or if target freed.
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
@export var pin_bias: float = 0.9
@export var pin_damping: float = 1.0
@export var debug_log: bool = false
@export var grab_neck_exact: bool = true
@export var neck_bone_candidates: Array[String] = ["neck.x", "neck", "Neck", "neck_X", "Neck.X"]

# --- Formation/drag tuning (responsive but not crumpling) ---
@export var formation_pull: float = 22.0 # accel (m/s^2) toward formation position, scaled by error
@export var formation_max_speed: float = 7.0
@export var formation_max_dist: float = 2.6 # farther than this -> ignore (body trails naturally)

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
var _formation_bones: Array[PhysicalBone3D] = []
var _formation_offsets: Array[Vector3] = [] # offset from hand at grab time (keeps body formation while dragging)
var _formation_offsets_valid: bool = false
var _grab_age: float = 0.0 # seconds since grab (safety drop has a grace period while reeling in)

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
	# Drive the kinematic hand anchor from the animated hand bone EVERY frame.
	# sync_to_physics only pushes the node's own transform changes to the physics
	# server — moving an ancestor (the carrier walking) does NOT move the physics
	# body, so without this the joint would pin the body to a fixed world point.
	_update_hand_anchor_transform()
	# Auto-break conditions
	if _grabbed_body and is_instance_valid(_grabbed_body):
		_grab_age += delta
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
		# Keep grabbed bone awake; joint + formation spring do the pulling
		_update_grab_spring(delta)
		# Safety: only drop if the pinned bone is STILL far from the hand well after
		# the reel-in should have connected (grace 1.2s, and 8m so a flying corpse
		# being reeled in doesn't instantly cancel the grab).
		if not _grabbed_bones.is_empty() and _grab_age > 1.2:
			var pb := _grabbed_bones[0] as PhysicalBone3D
			if is_instance_valid(pb) and _hand_anchor and is_instance_valid(_hand_anchor):
				if pb.global_position.distance_to(_hand_anchor.global_position) > 8.0:
					if debug_log:
						print("[Grabber] Safety drop: pinned bone %.1fm from hand after %.1fs" % [pb.global_position.distance_to(_hand_anchor.global_position), _grab_age])
					release_grab()
					return
	else:
		if _grabbed_body and not is_instance_valid(_grabbed_body):
			_cleanup_after_invalid_target()
		# Also clean if bones cleared but body remains (should not)
		if _grabbed_bones.is_empty() and _grabbed_body != null:
			_cleanup_after_invalid_target()

func _update_hand_anchor_transform() -> void:
	if _hand_anchor == null or not is_instance_valid(_hand_anchor):
		return
	if _skeleton and is_instance_valid(_skeleton) and _hand_bone_idx >= 0:
		# Explicit global_transform set = a real transform change on the node,
		# which sync_to_physics forwards to the physics server (with velocity).
		_hand_anchor.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_hand_bone_idx)

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
	var use_joints := _joints.size() > 0
	# --- Primary grabbed bone(s) ---
	for i in range(_grabbed_bones.size()):
		var b := _grabbed_bones[i] as PhysicalBone3D
		if not is_instance_valid(b):
			continue
		b.can_sleep = false
		if use_joints:
			# PinJoint handles the attachment rigidly — don't fight the solver.
			# Just keep damping sane so it doesn't wobble forever.
			b.linear_damp = 0.9
			b.angular_damp = 1.2
			continue
		# Fallback (no hand anchor/joint): velocity spring toward hand
		var hand_pos: Vector3 = _get_hand_world_pos()
		var offset: Vector3 = _grab_offsets[i] if i < _grab_offsets.size() else Vector3.ZERO
		var target_pos: Vector3 = hand_pos + offset * 0.15
		var dir: Vector3 = target_pos - b.global_position
		var dist: float = dir.length()
		if dist < 0.06:
			b.linear_velocity = b.linear_velocity.lerp(Vector3.ZERO, 6.0 * delta)
			continue
		var desired_vel: Vector3 = dir * 11.0
		if desired_vel.length() > 9.0:
			desired_vel = desired_vel.normalized() * 9.0
		b.linear_velocity = b.linear_velocity.lerp(desired_vel, clamp(delta * 18.0, 0.0, 1.0))
	# --- Formation hold: gently pull the rest of the body toward its grab-time pose
	# relative to the hand, so it trails naturally instead of stretching or crumpling.
	if not _formation_offsets_valid:
		return
	var hand: Vector3 = _get_hand_world_pos()
	for i in range(_formation_bones.size()):
		var pb := _formation_bones[i] as PhysicalBone3D
		if not is_instance_valid(pb) or pb in _grabbed_bones:
			continue
		var off: Vector3 = _formation_offsets[i] if i < _formation_offsets.size() else Vector3.ZERO
		var target: Vector3 = hand + off
		var dir2: Vector3 = target - pb.global_position
		var d2: float = dir2.length()
		if d2 < 0.05 or d2 > formation_max_dist:
			continue
		var desired2: Vector3 = dir2.normalized() * minf(d2 * formation_pull * 0.5, formation_max_speed)
		# Horizontal bias: dragging should slide/trail, not float
		desired2.y *= 0.6
		pb.linear_velocity = pb.linear_velocity.lerp(desired2, clamp(delta * 10.0, 0.0, 1.0))
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
	# Find bones to grab. The BODY being in range was already validated by
	# _find_best_ragdolled_body — so pick the primary bone by priority and let
	# the reel-in pull it to the hand. (Previously the neck was rejected when
	# the fling tossed it >grab_radius from the hand and a random limb like the
	# left forearm got grabbed instead.)
	var bones: Array = []
	if grab_neck_exact:
		var primary := _find_priority_bone(ragdoll, target)
		if primary:
			bones.append(primary)
			if debug_log:
				print("[Grabber] Primary bone: %s (%.2fm from hand — snapping into grip)" % [primary.bone_name, hand_pos.distance_to(primary.global_position)])
	if bones.is_empty():
		bones = _find_nearest_bones_on_target(target, ragdoll, hand_pos, max_grab_bones, grab_bone_radius)
		if bones.is_empty():
			if debug_log:
				print("[Grabber] No bones within %.2f of hand for %s" % [grab_bone_radius, target.name])
			return false

	# --- Store state ---
	_grabbed_body = target
	_grabbed_ragdoll = ragdoll
	_grab_age = 0.0
	_grabbed_bones.clear()
	_grab_offsets.clear()
	var hand_pos_current: Vector3 = _hand_anchor.global_position if (_hand_anchor and is_instance_valid(_hand_anchor)) else hand_pos
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
		# Keep normal-ish mass behaviour; the joint does the work so we don't need
		# extreme gravity/damping hacks that made the body float and feel rubbery.
		b.gravity_scale = 0.55
		b.linear_damp = 0.9
		b.angular_damp = 1.2
		b.friction = 0.2

	# --- Formation bones: capture REAL offsets from the hand at grab time ---
	# (previous bug: offsets were all Vector3.ZERO, pulling every bone INTO the hand)
	_formation_bones.clear()
	_formation_offsets.clear()
	_formation_offsets_valid = false
	var skel_all: Skeleton3D = null
	if ragdoll and ragdoll.get("skeleton") != null:
		skel_all = ragdoll.get("skeleton") as Skeleton3D
	if skel_all == null:
		skel_all = _search_skeleton(target)
	if skel_all:
		for child in skel_all.get_children():
			if not child is PhysicalBone3D:
				continue
			var pb2 := child as PhysicalBone3D
			if pb2 in _grabbed_bones:
				continue
			_formation_bones.append(pb2)
			var off: Vector3 = pb2.global_position - hand_pos_current
			# Clamp very long offsets (far limbs) so they trail instead of snapping
			if off.length() > 1.6:
				off = off.normalized() * 1.6
			_formation_offsets.append(off)
			pb2.can_sleep = false
			pb2.friction = 0.3
			pb2.linear_damp = 0.5
			pb2.angular_damp = 0.8
			pb2.gravity_scale = 0.85
		_formation_offsets_valid = true

	# --- Snap the whole ragdoll into the grip BEFORE creating the joint ---
	# Relocate every bone by the same delta so the neck lands exactly at the hand.
	# Body shape is preserved (no internal joint error), velocities are zeroed, and
	# the PinJoint then starts with ~zero separation instead of exploding (a joint
	# created across metres of gap in Jolt launches the bone at huge speed — that
	# was the "not being held" bug).
	var grab_delta: Vector3 = hand_pos_current - (_grabbed_bones[0] as PhysicalBone3D).global_position
	for b in _grabbed_bones:
		if is_instance_valid(b):
			b.global_position += grab_delta
			b.linear_velocity = Vector3.ZERO
			b.angular_velocity = Vector3.ZERO
	for fb in _formation_bones:
		if is_instance_valid(fb):
			fb.global_position += grab_delta
			fb.linear_velocity = Vector3.ZERO
			fb.angular_velocity = Vector3.ZERO

	# --- THE ACTUAL ATTACHMENT: PinJoint3D from hand anchor to grabbed bone ---
	# Previous code built joints but never added them; the neck was teleported each
	# frame instead, which fought the solver (stretchy/unresponsive).
	_joints.clear()
	if _hand_anchor and is_instance_valid(_hand_anchor):
		for i in range(_grabbed_bones.size()):
			var b := _grabbed_bones[i] as PhysicalBone3D
			if not is_instance_valid(b):
				continue
			# Only hard-pin the primary bone; extra bones follow via spring
			if i > 0:
				break
			var j := _create_pin_joint(_hand_anchor, b)
			if j:
				_joints.append(j)
				if debug_log:
					print("[Grabber] PinJoint created: anchor -> %s at %s" % [b.bone_name, j.global_position])

	# Mark target as grabbed -> blocks respawn (even if joints failed, spring still holds)
	_grabbed_body.set_meta("is_being_grabbed", true)
	_grabbed_body.set_meta("grabbed_by", _carrier)

	# Don't let the carrier's own capsule snag on ANY held bone while carrying
	if _carrier is PhysicsBody3D:
		for pb in _grabbed_bones:
			(_carrier as PhysicsBody3D).add_collision_exception_with(pb)
		for fb in _formation_bones:
			(_carrier as PhysicsBody3D).add_collision_exception_with(fb)

	# Also set on carrier for HUD/debug
	_carrier.set_meta("is_grabbing", true)
	_carrier.set_meta("grabbed_body", _grabbed_body)

	if debug_log:
		print("[Grabber] %s GRABBED %s with %d joint(s) on bones %s" % [_carrier.name, target.name, _joints.size(), bones])

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
			j.queue_free()
	_joints.clear()
	# Restore grabbed bones physics
	for b in _grabbed_bones:
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
			if _carrier is PhysicsBody3D and is_instance_valid(_carrier):
				(_carrier as PhysicsBody3D).remove_collision_exception_with(fb)
	_formation_bones.clear()
	_formation_offsets.clear()
	_formation_offsets_valid = false

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
	# IMPORTANT: no collision at all. The anchor only serves joints — if it collides,
	# the hand shoves ragdoll bones around every frame (jitter/stretch).
	_hand_anchor.collision_layer = 0
	_hand_anchor.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.name = "GrabColl"
	var sph := SphereShape3D.new()
	sph.radius = 0.05
	cs.shape = sph
	cs.disabled = true
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

func _find_priority_bone(ragdoll: Node, target: Node3D) -> PhysicalBone3D:
	# Neck first (GTA-style grab by the neck/shoulder), then torso center, then hips.
	var skel: Skeleton3D = null
	if ragdoll and ragdoll.get("skeleton") != null:
		skel = ragdoll.get("skeleton") as Skeleton3D
	if skel == null:
		skel = _search_skeleton(target)
	if skel == null:
		return null
	var priority: Array[String] = []
	priority.append_array(neck_bone_candidates)
	priority.append_array(["spine_03.x", "spine_02.x", "spine_01.x", "root.x", "hips", "Hips", "spine"])
	for cand in priority:
		for child in skel.get_children():
			if child is PhysicalBone3D and (child as PhysicalBone3D).bone_name == cand:
				return child as PhysicalBone3D
	# Last resort: any bone with "neck"/"spine"/"root" in the name
	for child in skel.get_children():
		if child is PhysicalBone3D:
			var low: String = String((child as PhysicalBone3D).bone_name).to_lower()
			if "neck" in low or "spine" in low or low.begins_with("root"):
				return child as PhysicalBone3D
	return null

func _create_pin_joint(body_a: PhysicsBody3D, body_b: PhysicsBody3D) -> PinJoint3D:
	if body_a == null or body_b == null:
		return null
	var j := PinJoint3D.new()
	j.name = "GrabJoint_%s_%s" % [body_a.name, body_b.name]
	# Anchor the joint AT THE HAND so the bone snaps to the hand immediately
	var hand_pos: Vector3 = body_a.global_position
	# _get_joint_parent falls back to tree root when current_scene is unavailable
	# (e.g. headless tests) — add_child on current_scene would crash there.
	_get_joint_parent().add_child(j)
	j.global_position = hand_pos
	j.node_a = body_a.get_path()
	j.node_b = body_b.get_path()
	# NOTE: PinJoint3D bias is unsupported in Jolt (warning spam) — damping only.
	j.set_param(PinJoint3D.PARAM_DAMPING, pin_damping)
	j.set_param(PinJoint3D.PARAM_IMPULSE_CLAMP, 0.0)
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
	_formation_offsets_valid = false
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
