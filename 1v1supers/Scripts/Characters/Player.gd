extends CharacterBody3D
const HealthCls = preload("res://Scripts/Combat/Health.gd")
const HurtboxCls = preload("res://Scripts/Combat/Hurtbox3D.gd")
const HitboxCls = preload("res://Scripts/Combat/Hitbox3D.gd")
## Player.gd — Third-person CharacterBody3D controller + SATISFYING COMBAT
## Features:
##  - Over-the-shoulder camera via SpringArmPivot (Node3D) + SpringArm3D + Camera3D
##  - Mouse look handled in SpringArmPivot.gd
##  - Movement toggles: Walk strafe-locked vs Sprint free
##  - C11 AnimationPlayer direct mode + combo + hitstop + shake + lunge + hitboxes
##  Combat feel pillars: hitstop, camera shake, punch scale, forward lunge, whiff/hit differentiation,
##  target snap, combo buffer, screen FOV kick, particle & sound on hit, knockback, stun.

const LERP_VALUE: float = 0.15

var snap_vector: Vector3 = Vector3.DOWN
var speed: float

# C11 direct playback state
var c11_ap: AnimationPlayer = null
var c11_use_direct: bool = false
var c11_current_anim: String = ""

# --- Combo attack (LMB) : Right hook > left punch > Right cross > leg kick ---
const COMBO_ANIMS: Array[String] = ["punch_hook", "punch_left_simple1", "punch_cross", "kick_spin"]
const COMBO_BLEND: float = 0.12
const COMBO_RESET_TIME: float = 1.2
const COMBO_SPEED: float = 2.7 # ~2x punch speed (was 1.35)
const KICK_SPEED: float = 1.35 # keep kick at original pacing
var is_attacking: bool = false
var combo_index: int = 0
var combo_reset_timer: float = 0.0
var combo_queued: bool = false
var _attack_frame: int = -1
var _last_try_msec: int = -1000

# --- Satisfying combat tuning ---
# Per-attack profile: damage, active window (fraction of anim), lunge, hitstop, shake, knockback
# Hit windows centered at ~50% of anim to match visual fist extension (animation was delayed)
# punch_hook 1.90s / 2.7 = 0.704s → mid 0.352s, punch_left 1.07/2.7=0.395s → mid 0.198s, punch_cross 1.40/2.7=0.519s → mid 0.259s, kick_spin 1.37/1.35=1.01s → mid 0.506s
const COMBO_DAMAGE: Array[float] = [11.0, 9.0, 17.0, 24.0]
const COMBO_HIT_START: Array[float] = [0.28, 0.16, 0.21, 0.40] # sec after play — middle (≈42% of total)
const COMBO_HIT_END: Array[float] = [0.43, 0.25, 0.32, 0.66] # sec after play — middle (≈62% of total)
const COMBO_LUNGE: Array[float] = [2.2, 1.7, 3.0, 3.8] # forward impulse
const COMBO_HITSTOP: Array[float] = [0.055, 0.045, 0.085, 0.12]
const COMBO_SHAKE: Array[float] = [0.28, 0.22, 0.42, 0.68]
const COMBO_KNOCKBACK: Array[float] = [2.3, 1.6, 4.0, 6.0]
const COMBO_STUN: Array[float] = [0.14, 0.12, 0.24, 0.36]

var _attack_timer: float = 0.0
var _attack_total: float = 0.0
var _hitbox_active: bool = false
var _has_hit_this_swing: bool = false
var _lunge_velocity: Vector3 = Vector3.ZERO
var _stun_timer: float = 0.0
var _hit_confirm_timer: float = 0.0
var _whiff_shake: float = 0.08
var _hitbox_debug_visible: bool = false # toggle with ` (grave) — hitbox DBG meshes invisible by default

@export_group("Movement")
@export var walk_speed: float = 2.0
@export var run_speed: float = 5.0
@export var jump_strength: float = 15.0
@export var gravity: float = 50.0

@export_group("Jump Feel - Satisfying")
@export var coyote_time: float = 0.14
@export var jump_buffer_time: float = 0.14
@export var jump_cut_multiplier: float = 0.45
@export var fall_gravity_multiplier: float = 1.6
@export var jump_horizontal_boost: float = 0.6
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var was_on_floor: bool = false
var _prev_fall_velocity: float = 0.0
var _jump_anim_timer: float = 0.0
var _land_anim_timer: float = 0.0

@export_group("Rotation Modes")
@export var sprint_rotation_speed: float = 12.0
@export var strafe_rotation_speed: float = 18.0
@export var instant_strafe_lock: bool = false
@export_group("Combat Feel")
@export var attack_lunge_decay: float = 8.0
@export var hit_punch_scale: float = 0.14
@export var target_snap_angle: float = 180.0 # degrees - dead-center: any angle within range snaps
@export var target_snap_range: float = 8.0 # was 6.0 - increased to prevent whiffing at edge
@export var combo_chain_window: float = 0.22 # how early before end you can queue (s)
@export var whiff_recovery_mult: float = 1.15 # whiff = longer recovery visual

const ANIMATION_BLEND: float = 7.0

@onready var player_mesh: Node3D = $Mesh
@onready var spring_arm_pivot: Node3D = $SpringArmPivot
@onready var animator: AnimationTree = $AnimationTree

# Combat nodes (created dynamically if missing)
var health: Node
var hurtbox: Area3D
var hitbox_main: Area3D
var hitbox_kick: Area3D

func _ready() -> void:
	_setup_c11_if_present()
	_setup_combat_nodes()
	# Connect health signals
	if health:
		health.damaged.connect(_on_damaged)
		health.died.connect(_on_died)

func _setup_combat_nodes() -> void:
	# --- Health ---
	var h = get_node_or_null("Health")
	if h == null:
		h = HealthCls.new()
		h.name = "Health"
		h.max_health = 100.0
		h.invuln_time = 0.08
		add_child(h)
	health = h
	# --- Hurtbox (center mass) ---
	var hb = get_node_or_null("Hurtbox3D")
	if hb == null:
		hb = HurtboxCls.new()
		hb.name = "Hurtbox3D"
		add_child(hb)
		# position slightly up
		hb.position = Vector3(0, 0.92, 0)
	hurtbox = hb as Area3D
	# --- Hitbox main (fist) --- bigger, forgiving
	var hx = get_node_or_null("Hitbox_Main")
	if hx == null:
		hx = HitboxCls.new()
		hx.name = "Hitbox_Main"
		add_child(hx)
		hx.position = Vector3(0, 1.02, 1.0)
		var col = hx.get_node_or_null("CollisionShape3D")
		if col and col.shape is SphereShape3D:
			(col.shape as SphereShape3D).radius = 0.62
		# add debug mesh so you SEE coverage (wireframe)
		var dbg = hx.get_node_or_null("DBG")
		if dbg == null:
			var mi = MeshInstance3D.new()
			mi.name = "DBG"
			var sph = SphereMesh.new()
			sph.radius = 0.62
			sph.height = 1.24
			mi.mesh = sph
			var dmat = StandardMaterial3D.new()
			dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			dmat.albedo_color = Color(1,0.2,0.2,0.18)
			dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi.material_override = dmat
			mi.visible = false
			hx.add_child(mi)
	hitbox_main = hx as Area3D
	hitbox_main.set("active", false)
	hitbox_main.hit_landed.connect(_on_hit_landed)
	# --- Kick hitbox (foot) --- larger too
	var hk = get_node_or_null("Hitbox_Kick")
	if hk == null:
		hk = HitboxCls.new()
		hk.name = "Hitbox_Kick"
		add_child(hk)
		hk.position = Vector3(0, 0.45, 1.1)
		var col2 = hk.get_node_or_null("CollisionShape3D")
		if col2 and col2.shape is SphereShape3D:
			(col2.shape as SphereShape3D).radius = 0.68
		var dbg2 = hk.get_node_or_null("DBG")
		if dbg2 == null:
			var mi2 = MeshInstance3D.new()
			mi2.name = "DBG"
			var sph2 = SphereMesh.new()
			sph2.radius = 0.68
			sph2.height = 1.36
			mi2.mesh = sph2
			var dmat2 = StandardMaterial3D.new()
			dmat2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			dmat2.albedo_color = Color(0.2,0.6,1,0.18)
			dmat2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi2.material_override = dmat2
			mi2.visible = false
			hk.add_child(mi2)
	hitbox_kick = hk as Area3D
	hitbox_kick.set("active", false)
	hitbox_kick.hit_landed.connect(_on_hit_landed)
	# Add to enemy-search group
	add_to_group("fighter")
	# Ensure collision layer for body
	collision_layer = 1
	collision_mask = 1

func _setup_c11_if_present() -> void:
	var c11_node = null
	var ap: AnimationPlayer = null
	for child_name in ["C11", "С11"]:
		var candidate = get_node_or_null("Mesh/" + child_name)
		if candidate:
			c11_node = candidate
			ap = candidate.get_node_or_null("AnimationPlayer") as AnimationPlayer
			if ap == null:
				ap = _find_animation_player(candidate)
			break
	if c11_node == null:
		for child in $Mesh.get_children():
			var found = _find_animation_player(child)
			if found and found.has_animation("Idle") and found.has_animation("running"):
				c11_node = child
				ap = found
				break
	if ap == null:
		return
	c11_node.visible = true
	var legacy = get_node_or_null("Mesh/Armature")
	if legacy:
		legacy.visible = false
	for n in ["Idle", "Walk", "Walk_left", "Walk_right", "Walk_backwards", "Walk_Left_forward", "Walk_Right_forward", "Walk_Left_backwards", "Walk_Right_backwards", "running", "falling_idle", "fly_1", "fly_2", "T_pose"]:
		if ap.has_animation(n):
			var anim = ap.get_animation(n)
			anim.loop_mode = Animation.LOOP_LINEAR
			anim.loop_mode = Animation.LOOP_LINEAR
	if ap.has_animation("running"):
		var run_anim = ap.get_animation("running")
		for tidx in range(run_anim.get_track_count()):
			var path_str = str(run_anim.track_get_path(tidx))
			if "position" in path_str or "translation" in path_str:
				var cnt = run_anim.track_get_key_count(tidx)
				if cnt < 2:
					continue
				var first = run_anim.track_get_key_value(tidx, 0)
				var last = run_anim.track_get_key_value(tidx, cnt - 1)
				if first is Vector3 and last is Vector3:
					if abs(first.x - last.x) > 0.005 or abs(first.z - last.z) > 0.005:
						run_anim.track_set_key_value(tidx, cnt - 1, Vector3(first.x, last.y, first.z))
	ap.playback_default_blend_time = 0.08
	for n in COMBO_ANIMS + ["jump_start", "Landing", "Landing_hard"]:
		if ap.has_animation(n):
			ap.get_animation(n).loop_mode = Animation.LOOP_NONE
	c11_ap = ap
	c11_use_direct = true
	if not c11_ap.animation_finished.is_connected(_on_c11_animation_finished):
		c11_ap.animation_finished.connect(_on_c11_animation_finished)
	if animator:
		animator.active = false
		print("[C11] Direct AnimationPlayer mode enabled, tree disabled. AP: ", get_path_to(ap))
	_play_c11("Idle")

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var f = _find_animation_player(c)
		if f:
			return f
	return null

func _play_c11(anim: String, blend: float = 0.2) -> void:
	if c11_ap == null or not c11_ap.has_animation(anim):
		return
	if c11_current_anim == anim and c11_ap.is_playing():
		return
	c11_ap.play(anim, blend)
	c11_current_anim = anim

# --- Combo helpers (satisfying) ---
func _play_attack(idx: int) -> void:
	if c11_ap == null:
		return
	if idx < 0 or idx >= COMBO_ANIMS.size():
		return
	var anim = COMBO_ANIMS[idx]
	if not c11_ap.has_animation(anim):
		push_warning("[Combo] missing animation: " + anim)
		return
	combo_index = idx
	is_attacking = true
	combo_queued = false
	combo_reset_timer = 0.0
	_attack_timer = 0.0
	_has_hit_this_swing = false
	_hit_confirm_timer = 0.0
	_hitbox_active = false
	# total duration approx — punches use COMBO_SPEED (2.7), kick uses KICK_SPEED (1.35)
	var spd: float = COMBO_SPEED if idx < 3 else KICK_SPEED
	var len: float = c11_ap.get_animation(anim).length / spd
	_attack_total = len
	# Stop previous hitboxes
	if hitbox_main: hitbox_main.set("active", false)
	if hitbox_kick: hitbox_kick.set("active", false)
	c11_ap.play(anim, COMBO_BLEND, spd)
	c11_current_anim = anim
	# --- Target snap FIRST: dead-center on enemy so lunge + hitbox are aligned ---
	_snap_to_target()
	# --- Lunge in snapped direction ---
	var forward: Vector3 = player_mesh.global_basis.z
	forward.y = 0
	forward = forward.normalized()
	if forward.length() < 0.2 and spring_arm_pivot:
		forward = Vector3.FORWARD.rotated(Vector3.UP, spring_arm_pivot.rotation.y)
		forward.y = 0
		forward = forward.normalized()
	_lunge_velocity = forward * COMBO_LUNGE[idx] * 1.35
	# --- Punch scale anticip. ---
	_do_attack_anticipation(idx)
	# --- Whiff FOV kick handled via spring pivot ---
	print("[Combo] %d/%d %s dmg=%.0f hs=%.2f" % [idx + 1, COMBO_ANIMS.size(), anim, COMBO_DAMAGE[idx], COMBO_HITSTOP[idx]])

func _snap_to_target() -> void:
	if player_mesh == null:
		return
	var best: Node3D = null
	var best_ang: float = 180.0
	var best_dist: float = INF
	# Search fighters/dummies/health groups — pick most screen-centered enemy within range (dead-center)
	var candidates: Array[Node] = []
	candidates.append_array(get_tree().get_nodes_in_group("health"))
	candidates.append_array(get_tree().get_nodes_in_group("dummy"))
	candidates.append_array(get_tree().get_nodes_in_group("fighter"))
	var seen: Dictionary = {}
	# Use camera look direction for "centered" test (where player is actually looking)
	var cam_fwd: Vector3 = Vector3.ZERO
	if spring_arm_pivot:
		# Pivot's forward is Vector3.FORWARD (-Z) rotated by yaw; matches SpringArmPivot.gd
		cam_fwd = Vector3.FORWARD.rotated(Vector3.UP, spring_arm_pivot.rotation.y)
		cam_fwd.y = 0
		cam_fwd = cam_fwd.normalized()
	else:
		cam_fwd = player_mesh.global_basis.z
		cam_fwd.y = 0
		cam_fwd = cam_fwd.normalized()
		if cam_fwd.length() < 0.1:
			cam_fwd = Vector3.FORWARD
	for n in candidates:
		var body: Node3D = null
		if n.is_in_group("health"):
			body = (n as Node).get_parent() as Node3D
		elif n is Node3D:
			body = n as Node3D
		if body == null or body == self or seen.has(body.get_instance_id()):
			continue
		seen[body.get_instance_id()] = true
		var to: Vector3 = body.global_position - global_position
		var dist: float = to.length()
		if dist > target_snap_range or dist < 0.4:
			continue
		var to_flat: Vector3 = to
		to_flat.y = 0
		if to_flat.length() < 0.01:
			continue
		to_flat = to_flat.normalized()
		var fwd_len: float = cam_fwd.length()
		var fwd: Vector3 = cam_fwd if fwd_len > 0.1 else Vector3.FORWARD.rotated(Vector3.UP, spring_arm_pivot.rotation.y if spring_arm_pivot else 0.0)
		var ang: float = rad_to_deg(fwd.angle_to(to_flat))
		if ang > target_snap_angle:
			continue
		# Pick smallest angle; tie-break closest distance for dead-center.
		if ang < best_ang - 0.01 or (abs(ang - best_ang) < 0.01 and dist < best_dist):
			best_ang = ang
			best_dist = dist
			best = body
	if best:
		var dir: Vector3 = (best.global_position - global_position)
		dir.y = 0
		if dir.length() < 0.01:
			return
		var base_yaw: float = atan2(dir.x, dir.z)
		# INSTANT dead-center snap — no tween, no 8° deadzone, no duration. Ensures punch never whiffs due to facing.
		player_mesh.rotation.y = base_yaw
		# Force update of global transform so hitbox/lunge computed next line use new facing immediately
		# (no need to defer; _play_attack reads global_basis after this)
		# Camera does NOT snap — only character

func _do_attack_anticipation(idx: int) -> void:
	if player_mesh == null:
		return
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# Slight squash before punch
	var sx: float = 1.0 + (0.05 if idx < 3 else 0.08)
	var sy: float = 0.94
	tw.tween_property(player_mesh, "scale", Vector3(sx, sy, sx), 0.06)
	tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.09)
	# Flash trail hint (simple)
	if idx == 3:
		_do_spin_trail()

func _do_spin_trail() -> void:
	# Temporary cylinder trail for kick
	var trail := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.35
	cyl.height = 0.06
	cyl.radial_segments = 16
	trail.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.6, 0.18, 0.55)
	trail.material_override = mat
	add_child(trail)
	trail.position = Vector3(0, 0.45, 0.0)
	var tw := create_tween()
	tw.tween_property(trail, "scale", Vector3(2.2, 1, 2.2), 0.18)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.18)
	tw.tween_callback(func(): if is_instance_valid(trail): trail.queue_free())

func _update_attack_hitbox(delta: float) -> void:
	if not is_attacking:
		# ensure debug hidden when not attacking
		if hitbox_main:
			var dbg = hitbox_main.get_node_or_null("DBG")
			if dbg: dbg.visible = false
		if hitbox_kick:
			var dbg2 = hitbox_kick.get_node_or_null("DBG")
			if dbg2: dbg2.visible = false
		return
	_attack_timer += delta
	var idx := combo_index
	var hs: float = COMBO_HIT_START[idx]
	var he: float = COMBO_HIT_END[idx]
	var should_active: bool = _attack_timer >= hs and _attack_timer <= he
	# debug visibility sync — only if hitbox debug toggled with ` (invisible by default)
	if hitbox_main:
		var dbg = hitbox_main.get_node_or_null("DBG")
		if dbg: dbg.visible = should_active and idx != 3 and _hitbox_debug_visible
	if hitbox_kick:
		var dbg2 = hitbox_kick.get_node_or_null("DBG")
		if dbg2: dbg2.visible = should_active and idx == 3 and _hitbox_debug_visible
	if should_active and not _hitbox_active:
		_hitbox_active = true
		var dmg: float = COMBO_DAMAGE[idx]
		var kb: float = COMBO_KNOCKBACK[idx]
		var hstop: float = COMBO_HITSTOP[idx]
		var shake: float = COMBO_SHAKE[idx]
		# Choose correct hitbox
		var box: Area3D = hitbox_kick if idx == 3 else hitbox_main
		var dur: float = he - hs
		# Damage scales slightly with combo progression
		dmg *= 1.0 + idx * 0.08
		box.call("try_activate", dmg, kb, hstop, shake, dur)
		print("[Hitbox] activate %s dmg=%.0f fwd=%.2f side=%.2f" % [box.name, dmg, box.position.z, box.position.x])
	elif not should_active and _hitbox_active:
		_hitbox_active = false
		if hitbox_main: hitbox_main.set("active", false)
		if hitbox_kick: hitbox_kick.set("active", false)
		_manual_hit_ids.clear()
	# Fallback manual overlap check (guarantees hit even if Area fails - covers bodies)
	if should_active:
		_do_manual_hit_check(idx)

var _manual_hit_ids: Dictionary = {}
func _do_manual_hit_check(idx: int) -> void:
	# Manual sphere overlap as backup - ensures dummies get hit even if Area layers mis-match
	if _has_hit_this_swing:
		# we already hit someone this swing via Area, but allow hitting other dummies too
		pass
	var box: Area3D = hitbox_kick if idx == 3 else hitbox_main
	if box == null:
		return
	var hit_world: Vector3 = global_position + box.position
	var hit_radius: float = 0.62 if idx != 3 else 0.68
	# Hurtbox capsule approx: center at dummy pos + (0,0.92,0), radius 0.48, half-height 0.91
	for n in get_tree().get_nodes_in_group("dummy"):
		if not is_instance_valid(n) or n == self:
			continue
		var dummy = n as Node3D
		if dummy == null:
			continue
		var hid: int = dummy.get_instance_id()
		# per-swing dedup for manual check (cleared on hitbox deactivate)
		if _manual_hit_ids.has(hid):
			continue
		var hurt_center: Vector3 = dummy.global_position + Vector3(0, 0.92, 0)
		var dist: float = hit_world.distance_to(hurt_center)
		# capsule vs sphere: approx sphere is 0.62, capsule radius 0.48 + half-height 0.91
		# Use cylinder distance: horizontal + vertical
		var horiz: Vector2 = Vector2(hit_world.x - hurt_center.x, hit_world.z - hurt_center.z)
		var vert: float = abs(hit_world.y - hurt_center.y)
		var is_hit: bool = false
		if vert <= 0.91 + hit_radius:
			if horiz.length() <= 0.48 + hit_radius:
				is_hit = true
		elif vert <= 0.91 + 0.48 + hit_radius:
			# caps
			var cap_center_y: float = hurt_center.y + sign(hit_world.y - hurt_center.y) * 0.91
			var cap_dist: float = Vector3(horiz.x, hit_world.y - cap_center_y, horiz.y).length()
			if cap_dist <= 0.48 + hit_radius:
				is_hit = true
		if is_hit:
			# Check if Area already handled this target (per hitbox _already_hit)
			var already_via_area: bool = false
			if box.has_method("get") and box.get("_already_hit") is Dictionary:
				var d: Dictionary = box.get("_already_hit")
				if d.has(hid):
					already_via_area = true
			if already_via_area:
				continue
			# Directly damage health to guarantee hit
			var health_node = dummy.get_node_or_null("Health")
			if health_node and health_node.has_method("take_damage"):
				# Avoid hitting dead
				if health_node.get("is_dead"):
					continue
				var dir: Vector3 = (dummy.global_position - global_position)
				dir.y = 0.18
				dir = dir.normalized()
				var kb: Vector3 = dir * COMBO_KNOCKBACK[idx] + Vector3(0,0.35,0)
				var dmg: float = COMBO_DAMAGE[idx] * (1.0 + idx * 0.08)
				var hstop: float = COMBO_HITSTOP[idx]
				var shake: float = COMBO_SHAKE[idx]
				print("[ManualHit] %s dist=%.2f horiz=%.2f vert=%.2f" % [dummy.name, dist, horiz.length(), vert])
				var ok: bool = health_node.take_damage(dmg, self, kb, hstop, shake)
				if ok:
					# mark as hit to avoid repeat this swing
					var dict: Dictionary = box.get("_already_hit")
					if dict != null:
						dict[hid] = true
					_has_hit_this_swing = false # allow _on_hit_landed to fire
					_on_hit_landed(dummy, dmg)
					_manual_hit_ids[hid] = true

func _on_hit_landed(target: Node, dmg: float) -> void:
	if _has_hit_this_swing:
		return
	_has_hit_this_swing = true
	_hit_confirm_timer = 0.18
	# Punch scale on hit (pop)
	if player_mesh:
		var tw := create_tween()
		tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		var s: float = 1.0 + hit_punch_scale + (0.06 if combo_index == 3 else 0.0)
		tw.tween_property(player_mesh, "scale", Vector3(s, 0.92, s), 0.06)
		tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.14)
	# Hitstop already handled in Health.gd (time_scale), add extra attacker freeze visual
	# Camera shake already via Hitbox3D -> pivot
	# Lunge damp on hit (stick)
	_lunge_velocity *= 0.18
	# Allow faster chain on hit: reduce remaining time slightly
	if _attack_total > 0.0:
		var remain: float = _attack_total - _attack_timer
		if remain > 0.12:
			# shorten recovery by 30% on hit (more responsive)
			_attack_timer += remain * 0.30
	# Sound/pitch handled in Health
	print("[Hit] %s for %.0f!" % [target.name, dmg])

func _on_damaged(amount: float, from: Node, _kb: Vector3, _is_crit: bool) -> void:
	# Self hit reaction
	_stun_timer = 0.18 if _is_crit else 0.11
	_do_hurt_flash(_is_crit)
	if spring_arm_pivot and spring_arm_pivot.has_method("add_trauma"):
		spring_arm_pivot.add_trauma(0.32 if not _is_crit else 0.62)
	# Interrupt attack if stunned hard?
	if _is_crit and is_attacking:
		# heavy hit breaks combo
		combo_queued = false

func _on_died(_killer: Node) -> void:
	is_attacking = false
	combo_queued = false
	_hitbox_active = false
	if hitbox_main: hitbox_main.set("active", false)
	if hitbox_kick: hitbox_kick.set("active", false)
	# Ragdoll-ish: push down scale
	if player_mesh:
		var tw := create_tween()
		tw.tween_property(player_mesh, "scale", Vector3(1.15, 0.75, 1.15), 0.15)
		tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.4)

func _do_hurt_flash(is_crit: bool) -> void:
	if player_mesh == null:
		return
	var tw := create_tween()
	var col: Color = Color(1.0, 0.25, 0.25, 0.55) if not is_crit else Color(1.0, 0.9, 0.2, 0.65)
	# Use a temporary overlay mesh flash (cheap)
	var flash := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.65, 1.85, 0.55)
	flash.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = col
	flash.material_override = mat
	player_mesh.add_child(flash)
	flash.position = Vector3(0, 0.92, 0)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.18)
	tw.tween_callback(func(): if is_instance_valid(flash): flash.queue_free())
	# Scale punch
	var tw2 := create_tween()
	tw2.tween_property(player_mesh, "scale", Vector3(1.07, 0.93, 1.07), 0.07)
	tw2.tween_property(player_mesh, "scale", Vector3.ONE, 0.13)

func _try_attack() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_try_msec < 70:
		return
	_last_try_msec = now
	var f = Engine.get_physics_frames()
	if _attack_frame == f:
		return
	_attack_frame = f
	if c11_ap == null or not c11_use_direct:
		return
	if not is_on_floor():
		return
	if _stun_timer > 0.0:
		return
	if not is_attacking:
		_play_attack(0)
		return
	if combo_index < COMBO_ANIMS.size() - 1:
		# Queue window: allow at any time after 15% but earlier queue = buffered, later = immediate
		var can_queue := true
		var prog: float = 0.0
		if c11_ap.current_animation_length > 0.0:
			prog = c11_ap.current_animation_position / c11_ap.current_animation_length
			if prog < 0.15:
				can_queue = false
		# If hit confirmed, allow instant queue even earlier
		if _has_hit_this_swing and prog < 0.15:
			can_queue = true
		if can_queue:
			combo_queued = true
		else:
			combo_queued = true

func _on_c11_animation_finished(anim_name: String) -> void:
	if anim_name not in COMBO_ANIMS:
		return
	# Disable hitboxes
	if hitbox_main: hitbox_main.set("active", false)
	if hitbox_kick: hitbox_kick.set("active", false)
	_hitbox_active = false
	_lunge_velocity = Vector3.ZERO
	if combo_queued and combo_index < COMBO_ANIMS.size() - 1:
		_play_attack(combo_index + 1)
	else:
		if anim_name == COMBO_ANIMS[combo_index]:
			var had_hit: bool = _has_hit_this_swing
			is_attacking = false
			if combo_index == COMBO_ANIMS.size() - 1:
				combo_index = 0
				combo_reset_timer = 0.0
				combo_queued = false
				print("[Combo] reset (full)")
			else:
				combo_reset_timer = COMBO_RESET_TIME
				# Whiff has longer feel, hit recovers faster
				if not had_hit:
					# slight stun on whiff final frame (camera tiny shake)
					if spring_arm_pivot and spring_arm_pivot.has_method("add_trauma"):
						spring_arm_pivot.add_trauma(_whiff_shake)
			c11_current_anim = ""
			_has_hit_this_swing = false

func _toggle_hitbox_debug() -> void:
	_hitbox_debug_visible = not _hitbox_debug_visible
	print("[HitboxDebug] %s" % ("ON (visible)" if _hitbox_debug_visible else "OFF (invisible)"))
	# Immediately hide DBGs if turning off
	if not _hitbox_debug_visible:
		if hitbox_main:
			var dbg = hitbox_main.get_node_or_null("DBG")
			if dbg: dbg.visible = false
		if hitbox_kick:
			var dbg2 = hitbox_kick.get_node_or_null("DBG")
			if dbg2: dbg2.visible = false

func _unhandled_input(event: InputEvent) -> void:
	# Toggle hitbox debug visibility with ` (grave/backtick) — covers QWERTY/QWERTZ/unicode
	if event is InputEventKey and event.pressed and not event.echo:
		# KEY_QUOTELEFT is the ` key, KEY_ASCIITILDE is ~ (shift+`), also check unicode 96 (`) and 126 (~)
		if event.keycode == KEY_QUOTELEFT or event.keycode == KEY_ASCIITILDE or event.physical_keycode == 96 or event.unicode == 96 or event.unicode == 126:
			_toggle_hitbox_debug()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_try_attack()

func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("punch"):
		_try_attack()
	# Timers
	if _stun_timer > 0.0:
		_stun_timer -= delta
	if _hit_confirm_timer > 0.0:
		_hit_confirm_timer -= delta
	# Combo reset window
	if not is_attacking and combo_reset_timer > 0.0:
		combo_reset_timer -= delta
		if combo_reset_timer <= 0.0:
			combo_index = 0
			combo_queued = false
			combo_reset_timer = 0.0
			print("[Combo] reset (timeout)")
	# Attack hitbox windowing
	_update_attack_hitbox(delta)
	# Lunge decay
	if _lunge_velocity.length() > 0.01:
		_lunge_velocity = _lunge_velocity.lerp(Vector3.ZERO, attack_lunge_decay * delta)
	else:
		_lunge_velocity = Vector3.ZERO
	# If stunned, damp inputs
	var stun_mult: float = 0.08 if _stun_timer > 0.0 else 1.0
	# ---- Input direction (WASD) ----
	var move_direction: Vector3 = Vector3.ZERO
	move_direction.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	move_direction.z = Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	if move_direction.length() > 1.0:
		move_direction = move_direction.normalized()
	if spring_arm_pivot:
		move_direction = move_direction.rotated(Vector3.UP, spring_arm_pivot.rotation.y)
	# ---- Speed toggle ----
	var is_sprinting: bool = Input.is_action_pressed("run") and not is_attacking and _stun_timer <= 0.0
	if is_sprinting:
		speed = run_speed
	else:
		speed = walk_speed
	# ---- Coyote + Buffer + Gravity ----
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		coyote_timer -= delta
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer -= delta
	var grav_mult: float = 1.0
	if velocity.y < 0.0:
		grav_mult = fall_gravity_multiplier
	elif velocity.y > 0.0 and not Input.is_action_pressed("jump"):
		grav_mult = 1.8
	velocity.y -= gravity * grav_mult * delta
	# ---- Horizontal velocity ----
	var target_x := move_direction.x * speed * stun_mult
	var target_z := move_direction.z * speed * stun_mult
	if is_on_floor():
		velocity.x = lerp(velocity.x, target_x, 0.28)
		velocity.z = lerp(velocity.z, target_z, 0.28)
	else:
		velocity.x = lerp(velocity.x, target_x, 0.16)
		velocity.z = lerp(velocity.z, target_z, 0.16)
	# Apply lunge (only on ground, during attack)
	if is_attacking and is_on_floor() and _lunge_velocity.length() > 0.1:
		velocity.x += _lunge_velocity.x * delta * 11.0
		velocity.z += _lunge_velocity.z * delta * 11.0
	# Damp movement while attacking (but lunge overrides) — if no lunge, heavy damp
	if is_attacking and _lunge_velocity.length() < 0.2:
		velocity.x *= 0.42
		velocity.z *= 0.42
	# Stun clamp
	if _stun_timer > 0.0:
		velocity.x *= 0.22
		velocity.z *= 0.22
	# ---- Rotation modes ----
	const YAW_OFFSET: float = PI # Mesh has flip Transform3D(-1) so +PI makes visual back to camera (away)
	if player_mesh and spring_arm_pivot:
		var has_input: bool = move_direction.length() > 0.1
		# During attack, lock to attack direction (no strafe snap)
		if is_attacking:
			# keep current facing, slight lerp to maintain
			pass
		elif is_sprinting and has_input:
			var target_angle := atan2(move_direction.x, move_direction.z)
			player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, target_angle, sprint_rotation_speed * delta)
		else:
			var cam_yaw := spring_arm_pivot.rotation.y + YAW_OFFSET
			if instant_strafe_lock:
				player_mesh.rotation.y = cam_yaw
			else:
				player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, cam_yaw, strafe_rotation_speed * delta)
	# ---- Keep hitbox in front of character, rotate with mesh (world-correct side) ---
	if hitbox_main and player_mesh:
		var fwd: Vector3 = player_mesh.global_basis.z
		fwd.y = 0
		if fwd.length() > 0.001:
			fwd = fwd.normalized()
		var right: Vector3 = -player_mesh.global_basis.x
		right.y = 0
		if right.length() > 0.001:
			right = right.normalized()
		# Dynamic lateral offset: hook = right, left = left
		var side: float = 0.0
		if is_attacking:
			if combo_index == 0: side = 0.28
			elif combo_index == 1: side = -0.25
		# World offset from body origin (body rotation is identity, so world == body local)
		var world_off_main: Vector3 = fwd * 0.72 + right * side
		var world_off_kick: Vector3 = fwd * 0.88 # kick is centered
		# Body is at rotation 0, so world offset == local position
		hitbox_main.position = Vector3(world_off_main.x, 1.02, world_off_main.z)
		if hitbox_kick:
			hitbox_kick.position = Vector3(world_off_kick.x, 0.42, world_off_kick.z)
	# ---- Jump / snap ----
	var just_landed: bool = is_on_floor() and not was_on_floor
	var can_jump := coyote_timer > 0.0 and jump_buffer_timer > 0.0 and not is_attacking and _stun_timer <= 0.0
	if Input.is_action_just_released("jump") and velocity.y > 2.0:
		velocity.y *= jump_cut_multiplier
	if can_jump:
		velocity.y = jump_strength
		if move_direction.length() > 0.1:
			velocity.x += move_direction.x * jump_horizontal_boost
			velocity.z += move_direction.z * jump_horizontal_boost
		snap_vector = Vector3.ZERO
		coyote_timer = 0.0
		jump_buffer_timer = 0.0
		was_on_floor = false
		_do_squash(0.88, 1.18, 0.12)
		_play_jump_anim()
	elif just_landed:
		snap_vector = Vector3.DOWN
		var land_power: float = clampf(abs(_prev_fall_velocity) / 18.0, 0.0, 1.0)
		if land_power > 0.15:
			_do_squash(1.15 + land_power * 0.15, 0.88 - land_power * 0.08, 0.13)
			_play_land_anim(land_power)
			if spring_arm_pivot and spring_arm_pivot.has_method("add_trauma"):
				spring_arm_pivot.add_trauma(land_power * 0.35)
	else:
		if is_on_floor():
			snap_vector = Vector3.DOWN
	_prev_fall_velocity = velocity.y
	was_on_floor = is_on_floor()
	if _jump_anim_timer > 0.0:
		_jump_anim_timer -= delta
	if _land_anim_timer > 0.0:
		_land_anim_timer -= delta
	apply_floor_snap()
	move_and_slide()
	animate(delta)

func _get_slow_walk_anim() -> String:
	var ix := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var iz := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	var v := Vector2(ix, iz)
	if v.length() < 0.1:
		return "Idle"
	var is_right := ix > 0.1
	var is_left := ix < -0.1
	var is_forward := iz < -0.1
	var is_back := iz > 0.1
	var anim: String = "Walk"
	if is_forward and is_right:
		anim = "Walk_Right_forward"
	elif is_forward and is_left:
		anim = "Walk_Left_forward"
	elif is_back and is_right:
		anim = "Walk_Right_backwards"
	elif is_back and is_left:
		anim = "Walk_Left_backwards"
	elif is_right:
		anim = "Walk_right"
	elif is_left:
		anim = "Walk_left"
	elif is_forward:
		anim = "Walk"
	elif is_back:
		anim = "Walk_backwards"
	if c11_ap and not c11_ap.has_animation(anim):
		if anim in ["Walk_Right_forward", "Walk_Right_backwards"] and c11_ap.has_animation("Walk_right"):
			return "Walk_right"
		if anim in ["Walk_Left_forward", "Walk_Left_backwards"] and c11_ap.has_animation("Walk_left"):
			return "Walk_left"
		return "Walk"
	return anim

func _do_squash(sx: float, sy: float, dur: float) -> void:
	if player_mesh == null:
		return
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(player_mesh, "scale", Vector3(sx, sy, sx), dur * 0.35)
	tw.tween_property(player_mesh, "scale", Vector3.ONE, dur * 0.65)

func _play_jump_anim() -> void:
	if c11_ap == null:
		return
	if c11_ap.has_animation("jump_start"):
		c11_ap.play("jump_start", 0.06, 1.35)
		c11_current_anim = "jump_start"
		_jump_anim_timer = 0.28
	elif c11_ap.has_animation("falling_idle"):
		_play_c11("falling_idle", 0.08)

func _play_land_anim(power: float) -> void:
	if c11_ap == null:
		return
	var anim := "Landing" if power < 0.65 else "Landing_hard"
	if not c11_ap.has_animation(anim):
		anim = "Landing" if c11_ap.has_animation("Landing") else "Idle"
	if c11_ap.has_animation(anim):
		var spd := 1.35 if power < 0.65 else 1.1
		c11_ap.play(anim, 0.06, spd)
		c11_current_anim = anim
		_land_anim_timer = 0.32 if power < 0.65 else 0.42

func animate(delta: float) -> void:
	if is_attacking:
		return
	if c11_use_direct and c11_ap:
		if _jump_anim_timer > 0.0 and c11_current_anim == "jump_start" and c11_ap.is_playing():
			return
		if _land_anim_timer > 0.0 and c11_current_anim in ["Landing", "Landing_hard"] and c11_ap.is_playing():
			return
		if is_on_floor():
			if velocity.length() > 0.1:
				if speed == run_speed and Input.is_action_pressed("run"):
					_play_c11("running")
				else:
					_play_c11(_get_slow_walk_anim())
			else:
				_play_c11("Idle")
		else:
			if _jump_anim_timer > 0.0 and c11_ap.has_animation("jump_start"):
				return
			if c11_ap.has_animation("falling_idle"):
				_play_c11("falling_idle")
			else:
				_play_c11("Idle")
		return
	if animator == null:
		return
	if is_on_floor():
		animator.set("parameters/ground_air_transition/transition_request", "grounded")
		if velocity.length() > 0:
			if speed == run_speed:
				animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), 1.0, delta * ANIMATION_BLEND))
			else:
				animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), 0.0, delta * ANIMATION_BLEND))
		else:
			animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), -1.0, delta * ANIMATION_BLEND))
	else:
		animator.set("parameters/ground_air_transition/transition_request", "air")
