extends CharacterBody3D
const HealthCls = preload("res://Scripts/Combat/Health.gd")
const HurtboxCls = preload("res://Scripts/Combat/Hurtbox3D.gd")
const HitboxCls = preload("res://Scripts/Combat/Hitbox3D.gd")
const CloakScene = preload("res://Scenes/Items/Cloak.tscn")
const EquipmentCls = preload("res://Scripts/Item/Equipment.gd")
const InventoryCls = preload("res://Scripts/Item/Inventory.gd")
const RagdollCls = preload("res://Scripts/Combat/RagdollController.gd")
const GrabberCls = preload("res://Scripts/Combat/RagdollGrabber.gd")
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

# --- Layered AnimationTree (upper-body) ---
# When true, upper actions (punch/pickup/throw) play on a filtered OneShot
# over the locomotion BlendTree so the lower body keeps walking/running.
var use_layered_anims: bool = true
var _upper_action_active: bool = false
var _is_fullbody_action: bool = false # kick uses full body (not filtered)

# --- Upper look (walking punch) - twist spine to face target ---
var _skeleton: Skeleton3D = null
var _spine_bone_idx: int = -1
var _upper_look_weight: float = 0.0
var _upper_look_angle: float = 0.0

# --- Walk blend smoothing (left <-> right etc) ---
var _walk_blend_pos: Vector2 = Vector2(0, 1)
@export_group("Animation Smoothing")
@export var walk_blend_smoothing: float = 14.0 # higher = snappier response; 9 still smooths left<->right reversals without snapping
@export var walk_blend_smoothing_idle: float = 20.0 # faster when leaving idle to avoid sluggish first step
@export var walk_direct_xfade: float = 0.22 # direct AnimationPlayer crossfade for 8-way Walk (left<->right) — longer = no snap

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
var is_picking_up: bool = false
var is_aiming: bool = false
var aim_point: Vector3 = Vector3.ZERO
var aim_direction: Vector3 = Vector3.FORWARD

# --- Hand Hold (single HAND slot) ---
const HOLD_ANIM: String = "UpperBody_ITEMHOLD"
const USE_ANIM: String = "UpperBody_ITEMUSE"
var held_item: ItemData = null
var held_instance: Node3D = null
var hand_attachment: BoneAttachment3D = null
var _is_holding: bool = false
var _is_using_item: bool = false
var _use_timer: float = 0.0
var _hold_attach_tween: Tween = null
var _hand_bone_name: String = "hand.r"

# --- Dash (Ctrl) ---
var is_dashing: bool = false
var dash_timer: float = 0.0
var dash_recovery_timer: float = 0.0
var dash_direction: Vector3 = Vector3.ZERO
var dash_anim_speed: float = 1.0
var _dash_key_latched: bool = false
var _dash_is_diagonal: bool = false # true if dash started from W+A/W+D/S+A/S+D

@export_group("Movement")
@export var walk_speed: float = 2.1 # 105% of 2.0
@export var walk_anim_speed: float = 1.25 # 125% walk anim speed
@export var run_speed: float = 5.0
@export var jump_strength: float = 15.0
@export var gravity: float = 50.0

@export_group("Dash")
@export var dash_speed: float = 9.34 # burst velocity during dash — 2x further than 4.67 (was 14.0 -> 4.67 -> 9.34)
@export var dash_duration: float = 0.22 # how long the dash burst lasts
@export var dash_recovery: float = 0.18 # brief slowdown after burst before full control returns
@export var dash_anim_speed_scale: float = 1.6 # play dash anim faster than authored speed
@export var dash_cancel_attack_window: float = 0.55 # after attack start, allow dash to cancel (s)

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
@export var sprint_rotation_speed: float = 22.0
@export var strafe_rotation_speed: float = 32.0
@export var instant_strafe_lock: bool = false
@export_group("Turn In Place (Camera Threshold)")
@export var turn_threshold_deg: float = 90.0
@export var turn_enabled: bool = true
@export var turn_only_when_idle: bool = true # if false, also triggers while walking slowly
@export var turn_anim_speed: float = 1.8
@export var turn_rotation_duration: float = 0.16 # how fast mesh tweens 90deg after anim (s)
@export var turn_cooldown: float = 0.02 # small lock after turn to avoid double trigger
var _is_turning: bool = false
var _turn_cooldown_timer: float = 0.0
var _turn_tween: Tween = null
var _last_turn_cam_yaw: float = 0.0
var _turn_reference_initialized: bool = false
@export_group("Aiming")
@export var aim_snap_angle: float = 45.0 # degrees cone around crosshair that auto-locks punches while aiming

@export_group("Combat Feel")
@export var attack_lunge_decay: float = 8.0
@export var hit_punch_scale: float = 0.14
@export var target_snap_angle: float = 180.0 # degrees - dead-center: any angle within range snaps
@export var target_snap_range: float = 8.0 # was 6.0 - increased to prevent whiffing at edge
@export var combo_chain_window: float = 0.22 # how early before end you can queue (s)
@export var whiff_recovery_mult: float = 1.15 # whiff = longer recovery visual

const ANIMATION_BLEND: float = 9.0 # lower = smoother Idle<->Walk<->Run blend (was 7.0, snapped)

@onready var player_mesh: Node3D = $Mesh
@onready var spring_arm_pivot: Node3D = $SpringArmPivot
@onready var animator: AnimationTree = $AnimationTree
@onready var aim_camera: Camera3D = $SpringArmPivot/SpringArm3D/CameraHolder/Camera3D

# Combat nodes (created dynamically if missing)
var health: Node
var hurtbox: Area3D
var hitbox_main: Area3D
var hitbox_kick: Area3D
var ragdoll: RagdollController = null
var grabber: RagdollGrabber = null

# Wearable / Equipment
var equipment: Equipment = null
var inventory: Inventory = null
var cloak: WearableItem = null
@export var auto_equip_cloak: bool = false
@export var cloak_bone: String = "spine_03.x"
@export var cloak_color: Color = Color(0.78, 0.12, 0.12, 1)

func _ready() -> void:
	add_to_group("player")
	add_to_group("fighter")
	_setup_c11_if_present()
	_setup_combat_nodes()
	# Connect health signals
	if health:
		health.damaged.connect(_on_damaged)
		health.died.connect(_on_died)
	_setup_ragdoll()
	_setup_grabber()
	_setup_wearables()
	_setup_hand_hold()

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

func _setup_ragdoll() -> void:
	var existing = get_node_or_null("RagdollController")
	if existing and existing is RagdollController:
		ragdoll = existing as RagdollController
		return
	ragdoll = RagdollCls.new()
	ragdoll.name = "RagdollController"
	ragdoll.impulse_multiplier = 1.35
	add_child(ragdoll)

func _setup_grabber() -> void:
	var existing_g = get_node_or_null("RagdollGrabber")
	if existing_g and existing_g is RagdollGrabber:
		grabber = existing_g as RagdollGrabber
		return
	grabber = GrabberCls.new()
	grabber.name = "RagdollGrabber"
	grabber.grab_radius = 2.8
	grabber.grab_bone_radius = 1.6
	grabber.debug_log = true
	add_child(grabber)

func _setup_wearables() -> void:
	# Equipment manager
	var existing = get_node_or_null("Equipment")
	if existing and existing is Equipment:
		equipment = existing as Equipment
	else:
		equipment = EquipmentCls.new()
		equipment.name = "Equipment"
		add_child(equipment)
		# Place Equipment near top so it initializes after skeleton
		move_child(equipment, 0)
	# Inventory bag
	var existing_inv = get_node_or_null("Inventory")
	if existing_inv and existing_inv is Inventory:
		inventory = existing_inv as Inventory
	else:
		inventory = InventoryCls.new()
		inventory.name = "Inventory"
		add_child(inventory)
	# Connect inventory HAND signals
	if inventory and inventory.has_signal("held_item_changed"):
		if not inventory.held_item_changed.is_connected(_on_held_item_changed):
			inventory.held_item_changed.connect(_on_held_item_changed)
	# If inventory already has held item (scene reload), sync
	if inventory and inventory.has_method("get_held_item"):
		var existing_held = inventory.get_held_item()
		if existing_held:
			call_deferred("attach_held_item", existing_held)
	# Defer cloak equip one frame to ensure skeleton is ready
	if auto_equip_cloak:
		call_deferred("_equip_cloak_deferred")

func _setup_hand_hold() -> void:
	# Ensure hand attachment exists; will be created lazily on first attach
	if inventory and inventory.has_signal("held_item_changed"):
		if not inventory.held_item_changed.is_connected(_on_held_item_changed):
			inventory.held_item_changed.connect(_on_held_item_changed)

func _on_held_item_changed(item: ItemData) -> void:
	# Sync from Inventory signal — if null we already detached via drop, else attach
	if item == null:
		if _is_holding and held_item != null:
			# Inventory cleared externally — ensure visual detached (unless dropping already handled)
			if held_instance and is_instance_valid(held_instance):
				_detach_held_visual()
			_exit_hold_state()
			held_item = null
			_is_holding = false
	else:
		if not _is_holding or held_item != item:
			attach_held_item(item)

func _on_hand_full_feedback() -> void:
	print("[Hand] Cannot pick up — HAND already holds '%s'. Drop with G first." % (held_item.display_name if held_item else "?"))
	if spring_arm_pivot and spring_arm_pivot.has_method("add_trauma"):
		spring_arm_pivot.add_trauma(0.18)

func _equip_cloak_deferred() -> void:
	if not auto_equip_cloak:
		return
	if equipment == null:
		equipment = get_node_or_null("Equipment") as Equipment
		if equipment == null:
			return
	# ItemData.EquipSlot.CAPE = 1
	var slot: int = 1
	if equipment.has_equipped(slot):
		cloak = equipment.get_equipped(slot) as WearableItem
		if cloak:
			cloak.set_color(cloak_color)
		return
	var wearable = equipment.equip_wearable(CloakScene, slot, cloak_bone)
	if wearable:
		cloak = wearable
		if cloak.has_method("set_color"):
			cloak.set_color(cloak_color)
		print("[Player] Cloak equipped on bone '%s'" % cloak_bone)
	else:
		push_warning("[Player] Failed to equip cloak")

func equip_cloak() -> bool:
	if cloak and is_instance_valid(cloak) and cloak.visible:
		return true
	if equipment == null:
		_setup_wearables()
		await get_tree().process_frame
	return _try_equip_cloak()

func _try_equip_cloak() -> bool:
	if equipment == null:
		return false
	var wearable = equipment.equip_wearable(CloakScene, 1, cloak_bone)
	if wearable:
		cloak = wearable
		cloak.set_color(cloak_color)
		return true
	return false

func unequip_cloak() -> void:
	if equipment and equipment.has_equipped(1):
		equipment.unequip_slot(1)
		cloak = null
		print("[Player] Cloak unequipped")
	elif cloak and is_instance_valid(cloak):
		cloak.visible = false
		cloak = null

func toggle_cloak() -> void:
	if equipment and equipment.has_equipped(1):
		var c = equipment.get_equipped(1)
		if c and c.visible:
			unequip_cloak()
		else:
			if c:
				c.visible = true
				cloak = c
			else:
				_try_equip_cloak()
	else:
		_try_equip_cloak()

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
	ap.playback_default_blend_time = 0.18 # smoother crossfade for all walks (was 0.08, snapped)
	for n in COMBO_ANIMS + ["jump_start", "Landing", "Landing_hard", "pick_up", "pickup", "Pick_up", "PickUp"]:
		if ap.has_animation(n):
			ap.get_animation(n).loop_mode = Animation.LOOP_NONE
	for anim_name in ap.get_animation_list():
		if anim_name.to_lower().begins_with("pick"):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_NONE
	# Dodge dash animations must be one-shot, not looping
	for dodge_name in ["Dodge_forward", "Dodge_backward", "Dodge_right", "Dodge_left"]:
		if ap.has_animation(dodge_name):
			ap.get_animation(dodge_name).loop_mode = Animation.LOOP_NONE
	# Turn in place must be one-shot, not looping (otherwise overlaps Idle)
	for turn_name in ["Turn_left", "Turn_right", "turn_left", "turn_right"]:
		if ap.has_animation(turn_name):
			ap.get_animation(turn_name).loop_mode = Animation.LOOP_NONE
	# Hold should loop (idle hold), Use should be one-shot
	if ap.has_animation(HOLD_ANIM):
		ap.get_animation(HOLD_ANIM).loop_mode = Animation.LOOP_LINEAR
		print("[C11] Hold anim loop enabled: %s" % HOLD_ANIM)
	if ap.has_animation(USE_ANIM):
		ap.get_animation(USE_ANIM).loop_mode = Animation.LOOP_NONE
	# Also ensure generic Upperbody_ variants loop correctly
	for anim_name in ap.get_animation_list():
		if anim_name.begins_with("UpperBody_ITEMHOLD") or anim_name.begins_with("Upperbody_ITEMHOLD"):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
		if anim_name.begins_with("UpperBody_ITEMUSE") or anim_name.begins_with("Upperbody_ITEMUSE"):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_NONE
	c11_ap = ap
	# --- Layered vs Direct mode ---
	if use_layered_anims and animator:
		c11_use_direct = false
		_setup_layered_tree(ap)
		if not c11_ap.animation_finished.is_connected(_on_c11_animation_finished):
			c11_ap.animation_finished.connect(_on_c11_animation_finished)
		print("[C11] Layered AnimationTree mode enabled (upper-body filtered). AP: ", get_path_to(ap))
	else:
		c11_use_direct = true
		if not c11_ap.animation_finished.is_connected(_on_c11_animation_finished):
			c11_ap.animation_finished.connect(_on_c11_animation_finished)
		if animator:
			animator.active = false
			print("[C11] Direct AnimationPlayer mode enabled, tree disabled. AP: ", get_path_to(ap))
		_play_c11("Idle")

func _setup_layered_tree(ap: AnimationPlayer) -> void:
	if animator == null:
		return
	# Make tree unique per-instance so filter edits don't leak globally
	if animator.tree_root:
		animator.tree_root = animator.tree_root.duplicate(true)
	animator.anim_player = animator.get_path_to(ap)
	animator.active = true
	# Ensure locomotion defaults
	animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_NONE)
	animator.set("parameters/UpperScale/scale", 1.0)
	animator.set("parameters/WalkScale/scale", walk_anim_speed)
	animator.set("parameters/WalkSpace/blend_mode", 0) # interpolated (inverse-distance) — smooth left<->right strafe, no snap
	animator.set("parameters/ground_air_transition/transition_request", "grounded")
	animator.set("parameters/iwr_blend/blend_amount", -1.0)
	_walk_blend_pos = Vector2(0, 1) # forward default
	animator.set("parameters/WalkSpace/blend_position", _walk_blend_pos)
	# Ensure filter is correctly set (re-apply in case duplicate lost it)
	var upper_node = animator.tree_root.get_node("UpperOneShot")
	if upper_node and upper_node is AnimationNodeOneShot:
		upper_node.filter_enabled = true
	# --- Hold layer defaults ---
	var tree = animator.tree_root as AnimationNodeBlendTree
	if tree and not tree.has_node("HoldAction"):
		# Fallback: create hold nodes programmatically if scene was not updated
		var hold_anim = AnimationNodeAnimation.new()
		hold_anim.animation = StringName(HOLD_ANIM)
		tree.add_node("HoldAction", hold_anim)
		var hold_scale = AnimationNodeTimeScale.new()
		tree.add_node("HoldScale", hold_scale)
		var hold_oneshot = AnimationNodeOneShot.new()
		hold_oneshot.filter_enabled = true
		if upper_node and upper_node is AnimationNodeOneShot:
			hold_oneshot.filters = (upper_node.filters as Array).duplicate()
		hold_oneshot.fadein_time = 0.25
		hold_oneshot.fadeout_time = 0.22
		tree.add_node("HoldOneShot", hold_oneshot)
		# Rewire: ground -> HoldOneShot -> UpperOneShot
		# disconnect existing UpperOneShot input 0 if needed
		# Try safe disconnect/connect
		var ok_disc = false
		# Godot 4.4 has disconnect_node(name, idx); use try
		if tree.has_node("HoldOneShot") and tree.has_node("UpperOneShot"):
			# disconnect UpperOneShot 0 if connected to ground
			tree.disconnect_node("UpperOneShot", 0)
			tree.connect_node("HoldOneShot", 0, "ground_air_transition")
			tree.connect_node("HoldScale", 0, "HoldAction")
			tree.connect_node("HoldOneShot", 1, "HoldScale")
			tree.connect_node("UpperOneShot", 0, "HoldOneShot")
			print("[C11] HoldOneShot created programmatically")
	else:
		# Ensure Hold nodes have correct filter/animation
		var hold_anim_node = animator.tree_root.get_node("HoldAction") as AnimationNodeAnimation
		if hold_anim_node and ap.has_animation(HOLD_ANIM):
			hold_anim_node.animation = StringName(HOLD_ANIM)
		var hold_node = animator.tree_root.get_node("HoldOneShot")
		if hold_node and hold_node is AnimationNodeOneShot:
			hold_node.filter_enabled = true
			hold_node.fadein_time = 0.25
			hold_node.fadeout_time = 0.22
			if upper_node and upper_node.filters.size() > 0:
				# Ensure filters sync
				pass
	animator.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_NONE)
	animator.set("parameters/HoldScale/scale", 1.0)
	# If we already hold item from deferred attach, re-enter hold
	if _is_holding and held_item:
		_enter_hold_state()

# ============================================================
# Hand Hold System — single HAND slot, bone-filtered hold loop
# ============================================================
func _get_hand_bone_candidates() -> Array[String]:
	return ["hand.r", "hand_r", "hand.r.x", "hand_r.x", "RightHand", "c_hand_fk.r", "hand.R", "Hand_R"]

func _find_hand_bone(skel: Skeleton3D) -> int:
	if skel == null:
		return -1
	for cand in _get_hand_bone_candidates():
		var idx := skel.find_bone(cand)
		if idx != -1:
			_hand_bone_name = cand
			return idx
		# case-insensitive fallback
		for i in range(skel.get_bone_count()):
			if skel.get_bone_name(i).to_lower() == cand.to_lower():
				_hand_bone_name = skel.get_bone_name(i)
				return i
	# last resort: any bone containing hand and r
	for i in range(skel.get_bone_count()):
		var bn := skel.get_bone_name(i).to_lower()
		if "hand" in bn and (".r" in bn or "_r" in bn or "right" in bn):
			_hand_bone_name = skel.get_bone_name(i)
			return i
	return -1

func _ensure_hand_attachment() -> BoneAttachment3D:
	if hand_attachment and is_instance_valid(hand_attachment):
		return hand_attachment
	var skel := _get_skeleton()
	if skel == null:
		push_warning("[HandHold] No skeleton for hand attachment")
		return null
	var idx := _find_hand_bone(skel)
	if idx == -1:
		push_warning("[HandHold] Right hand bone not found, fallback to hand.r")
		_hand_bone_name = "hand.r"
	else:
		print("[HandHold] Using hand bone '%s' idx=%d" % [_hand_bone_name, idx])
	hand_attachment = BoneAttachment3D.new()
	hand_attachment.name = "HandHoldAttachment"
	hand_attachment.bone_name = _hand_bone_name
	# Use use_external_skeleton if needed? BoneAttachment3D handles it automatically when parent is Skeleton3D
	skel.add_child(hand_attachment)
	# Ensure attachment is at origin initially
	hand_attachment.position = Vector3.ZERO
	hand_attachment.rotation = Vector3.ZERO
	return hand_attachment

func attach_held_item(data: ItemData) -> bool:
	if data == null:
		return false
	if _is_holding and held_item == data:
		# Already holding same — idempotent
		return true
	# Capacity check: allow if inventory already contains this exact data (we already added), else block if full
	if inventory and inventory.has_method("is_hand_full") and inventory.has_method("get_held_item"):
		if inventory.is_hand_full():
			var held_in_inv: ItemData = inventory.get_held_item()
			if held_in_inv != data and held_item != data:
				print("[HandHold] HAND full, cannot attach '%s' (holding '%s')" % [data.display_name, held_in_inv.display_name if held_in_inv else "?"] )
				return false
	elif inventory and inventory.has_method("is_hand_full") and inventory.is_hand_full() and held_item != data:
		print("[HandHold] HAND full, cannot attach '%s'" % data.display_name)
		return false
	# If already holding different, drop first? spec says hold only one — caller should block
	if _is_holding and held_item != null and held_item != data:
		print("[HandHold] Already holding '%s', cannot attach '%s'" % [held_item.display_name, data.display_name])
		return false
	held_item = data
	_is_holding = true
	# Inventory sync (if not already added via pickup, ensure it is)
	if inventory and inventory.has_method("has_item") and not inventory.has_item(data):
		# Only add if empty or if held item is this data; Inventory will enforce capacity
		if inventory.has_method("can_pickup") and not inventory.can_pickup():
			# inventory is full with different item — shouldn't happen because we checked above, but keep warning
			var hi: ItemData = inventory.get_held_item() if inventory.has_method("get_held_item") else null
			if hi != data:
				print("[HandHold] Inventory HAND full, cannot sync '%s'" % data.display_name)
				held_item = null
				_is_holding = false
				return false
		if inventory.has_method("can_pickup") and inventory.can_pickup():
			inventory.add_item(data)
		elif not inventory.has_method("can_pickup"):
			inventory.add_item(data)
	# Visual
	_create_held_visual(data)
	_enter_hold_state()
	print("[HandHold] Attached '%s' usable=%s to hand '%s'" % [data.display_name, str(data.is_usable), _hand_bone_name])
	return true

func _create_held_visual(data: ItemData) -> void:
	_detach_held_visual()
	var attach := _ensure_hand_attachment()
	if attach == null:
		return
	var vis: Node3D = null
	if data.scene:
		var inst = data.scene.instantiate()
		# If scene is BoneAttachment (wearable), extract mesh child
		if inst is BoneAttachment3D:
			# Find mesh inside
			var mi = (inst as BoneAttachment3D).find_child("CloakMesh", true, false) as MeshInstance3D
			if mi == null:
				mi = _find_mesh_in_node(inst)
			if mi:
				# detach mesh from BoneAttachment and add to hand
				var mesh_copy := _clone_meshinstance(mi)
				vis = mesh_copy
			inst.queue_free()
		elif inst is Node3D:
			vis = inst as Node3D
		else:
			vis = inst as Node3D
	elif data.mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = data.mesh
		if data.material:
			mi.material_override = data.material
			mi.set_surface_override_material(0, data.material)
		vis = mi
	else:
		# Fallback primitive based on item_id/color
		var mi2 := MeshInstance3D.new()
		var shape: Mesh
		if data.is_usable:
			var sph := SphereMesh.new()
			sph.radius = 0.12
			sph.height = 0.24
			shape = sph
		else:
			var box := BoxMesh.new()
			box.size = Vector3(0.18, 0.18, 0.18)
			shape = box
		mi2.mesh = shape
		var mat := StandardMaterial3D.new()
		mat.albedo_color = data.preview_color
		mat.roughness = 0.6
		mat.metallic = 0.1
		mi2.material_override = mat
		vis = mi2
	if vis == null:
		return
	# Apply hold transform from ItemData
	vis.position = data.hold_offset
	vis.rotation_degrees = data.hold_rotation_deg
	vis.scale = data.hold_scale
	# Smooth attach: start small + offset then tween to target
	var target_pos := vis.position
	var target_rot := vis.rotation
	var target_scale := vis.scale
	vis.scale = target_scale * 0.01
	vis.position = target_pos + Vector3(0,0.4,0)
	attach.add_child(vis)
	held_instance = vis
	if _hold_attach_tween and _hold_attach_tween.is_valid():
		_hold_attach_tween.kill()
	_hold_attach_tween = create_tween()
	_hold_attach_tween.set_parallel(true)
	_hold_attach_tween.tween_property(vis, "scale", target_scale, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_hold_attach_tween.tween_property(vis, "position", target_pos, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Slight rotation settle
	if target_rot.length() > 0.01:
		vis.rotation = target_rot + Vector3(0, 0.8, 0)
		_hold_attach_tween.tween_property(vis, "rotation", target_rot, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

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
	# copy surface materials
	if src.mesh:
		for i in range(src.mesh.get_surface_count()):
			var m = src.get_surface_override_material(i)
			if m:
				mi.set_surface_override_material(i, m)
			else:
				var sm = src.mesh.surface_get_material(i)
				if sm:
					mi.set_surface_override_material(i, sm)
	if src.skin:
		mi.skin = src.skin
	if src.skeleton:
		# Don't copy skeleton for hand item; we want static mesh
		pass
	return mi

func _detach_held_visual() -> void:
	if held_instance and is_instance_valid(held_instance):
		held_instance.queue_free()
	held_instance = null
	if _hold_attach_tween and _hold_attach_tween.is_valid():
		_hold_attach_tween.kill()
		_hold_attach_tween = null

func _enter_hold_state() -> void:
	if c11_ap == null:
		return
	if not c11_ap.has_animation(HOLD_ANIM):
		push_warning("[HandHold] Missing hold anim '%s', available: %s" % [HOLD_ANIM, str(c11_ap.get_animation_list())])
		return
	if use_layered_anims and animator and animator.active:
		var hold_anim_node = animator.tree_root.get_node("HoldAction") as AnimationNodeAnimation
		if hold_anim_node:
			hold_anim_node.animation = StringName(HOLD_ANIM)
		animator.set("parameters/HoldScale/scale", 1.0)
		var hold_node = animator.tree_root.get_node("HoldOneShot") as AnimationNodeOneShot
		if hold_node:
			hold_node.fadein_time = 0.25
			hold_node.fadeout_time = 0.22
			hold_node.filter_enabled = true
		animator.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		print("[HandHold] HOLD OneShot fired: %s (filtered upper, loops)" % HOLD_ANIM)
	else:
		# Direct mode fallback: just play hold
		_play_c11(HOLD_ANIM, 0.25, 1.0)
	_is_holding = true

func _exit_hold_state() -> void:
	if use_layered_anims and animator and animator.active:
		animator.set("parameters/HoldOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
		print("[HandHold] HOLD faded out")
	else:
		if c11_ap and c11_ap.current_animation == HOLD_ANIM:
			if c11_ap.has_animation("Idle"):
				_play_c11("Idle", 0.2)
	_is_holding = false
	_is_using_item = false
	_use_timer = 0.0

func drop_held_item() -> bool:
	if not _is_holding or held_item == null:
		print("[HandHold] No item to drop")
		return false
	var data := held_item
	# Remove from inventory HAND
	if inventory and inventory.has_method("remove_item"):
		inventory.remove_item(data)
	held_item = null
	_exit_hold_state()
	_detach_held_visual()
	_spawn_pickup_from_hand(data)
	print("[HandHold] Dropped '%s' from hand" % data.display_name)
	return true

func _spawn_pickup_from_hand(data: ItemData) -> void:
	var spawn_pos: Vector3 = global_position
	var fwd: Vector3 = Vector3.FORWARD
	if player_mesh:
		fwd = player_mesh.global_basis.z.normalized()
	elif spring_arm_pivot:
		fwd = Vector3.FORWARD.rotated(Vector3.UP, spring_arm_pivot.rotation.y)
	fwd.y = 0.12
	if fwd.length() > 0.1:
		spawn_pos += fwd.normalized() * 1.4
	# If hand attachment exists, use its global pos
	if hand_attachment and is_instance_valid(hand_attachment) and held_instance == null:
		# held_instance already freed, but attachment pos is hand world
		spawn_pos = hand_attachment.global_position + fwd * 0.3
	spawn_pos.y = maxf(spawn_pos.y, global_position.y + 0.35)
	var pickup_scene: PackedScene = null
	# Try to load generic pickup for this item
	if data.id == "cloak_01":
		pickup_scene = load("res://Scenes/Items/CloakPickup.tscn") as PackedScene
	elif data.id == "usable_01" or data.id.begins_with("usable"):
		pickup_scene = load("res://Scenes/Items/UsablePickup.tscn") as PackedScene
	elif data.id == "holdable_01" or data.id.begins_with("holdable"):
		pickup_scene = load("res://Scenes/Items/RockPickup.tscn") as PackedScene
	elif data.slot == ItemData.EquipSlot.HAND:
		if data.is_usable:
			pickup_scene = load("res://Scenes/Items/UsablePickup.tscn") as PackedScene
		else:
			pickup_scene = load("res://Scenes/Items/RockPickup.tscn") as PackedScene
	var inst: Node3D = null
	if pickup_scene:
		inst = pickup_scene.instantiate() as Node3D
		if inst:
			# override item_data to our data
			inst.set("item_data", data)
			inst.set("item_name", data.display_name)
			inst.set("item_id", data.id)
			inst.set("wearable_scene", data.scene)
			inst.set("equip_slot", data.slot)
			inst.set("pickup_color", data.preview_color)
	else:
		var pickup_script = load("res://Scripts/Item/ItemPickup.gd")
		var area = Area3D.new()
		area.set_script(pickup_script)
		# Setup mesh manually via ItemData
		var mi := MeshInstance3D.new()
		mi.name = "PickupMesh"
		if data.mesh:
			mi.mesh = data.mesh
			if data.material:
				mi.material_override = data.material
		elif data.scene:
			# Extract mesh from scene
			var tmp = data.scene.instantiate()
			var found = _find_mesh_in_node(tmp)
			if found:
				mi.mesh = found.mesh
				mi.material_override = found.material_override
			tmp.queue_free()
		else:
			var box := BoxMesh.new()
			box.size = Vector3(0.22,0.22,0.22)
			mi.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = data.preview_color
			mi.material_override = mat
		area.add_child(mi)
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 2.0
		cs.shape = sph
		area.add_child(cs)
		area.set("item_data", data)
		area.set("item_name", data.display_name)
		area.set("item_id", data.id)
		area.set("wearable_scene", data.scene)
		area.set("equip_slot", data.slot)
		area.set("pickup_color", data.preview_color)
		area.set("auto_pickup", false)
		area.set("require_interact", true)
		inst = area
	if inst:
		var level = get_tree().current_scene
		if level == null:
			level = get_tree().root
		if level:
			level.add_child(inst)
			inst.global_position = spawn_pos
			# Ensure in pickup group for tests
			if not inst.is_in_group("pickup"):
				inst.add_to_group("pickup")
			if not inst.is_in_group("item_pickup"):
				inst.add_to_group("item_pickup")
			# Add slight impulse / bounce visual
			if inst.has_node("PickupMesh"):
				var pm = inst.get_node("PickupMesh") as MeshInstance3D
				if pm:
					var tw := create_tween()
					pm.scale = Vector3.ONE * 0.1
					tw.tween_property(pm, "scale", data.hold_scale if data.hold_scale != Vector3.ZERO else Vector3.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			print("[HandHold] Spawned pickup '%s' at %s" % [data.display_name, str(spawn_pos)])
		else:
			push_warning("[HandHold] No level to spawn pickup")

func try_use_held_item() -> bool:
	if not _is_holding or held_item == null:
		return false
	if not held_item.is_usable:
		print("[HandHold] Item '%s' not usable" % held_item.display_name)
		return false
	if _is_using_item:
		return false
	if c11_ap == null or not c11_ap.has_animation(USE_ANIM):
		# fallback to generic use anim name from ItemData
		var cand := held_item.use_anim
		if c11_ap and c11_ap.has_animation(cand):
			return _play_use_anim(cand)
		print("[HandHold] Missing use anim '%s'" % USE_ANIM)
		return false
	return _play_use_anim(USE_ANIM)

func _play_use_anim(anim: String) -> bool:
	if c11_ap == null or not c11_ap.has_animation(anim):
		return false
	_is_using_item = true
	var anim_len: float = c11_ap.get_animation(anim).length
	_use_timer = anim_len / 1.0
	if use_layered_anims and animator and animator.active:
		var upper_anim_node = animator.tree_root.get_node("UpperAction") as AnimationNodeAnimation
		if upper_anim_node:
			upper_anim_node.animation = StringName(anim)
		animator.set("parameters/UpperScale/scale", 1.0)
		var upper_node = animator.tree_root.get_node("UpperOneShot") as AnimationNodeOneShot
		if upper_node:
			upper_node.filter_enabled = true
			upper_node.fadein_time = 0.08
			upper_node.fadeout_time = 0.14
		animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		print("[HandHold] ITEMUSE fired: %s (filtered upper)" % anim)
		# Return to hold after use — OneShot will fade back to HoldOneShot base
		get_tree().create_timer(_use_timer + 0.14).timeout.connect(func():
			_is_using_item = false
			print("[HandHold] ITEMUSE finished, back to HOLD")
		)
	else:
		_play_c11(anim, 0.08, 1.0)
		get_tree().create_timer(_use_timer + 0.12).timeout.connect(func(): _is_using_item = false)
	# Placeholder effect: heal 15 HP, emit particles
	_do_use_effect()
	return true

func _do_use_effect() -> void:
	if held_item == null:
		return
	print("[HandHold] Used '%s' — effect triggered" % held_item.display_name)
	if health and health.has_method("heal"):
		health.call("heal", 15.0)
	elif health and "current" in health:
		var cur: float = health.get("current")
		var max_h: float = health.get("max_health")
		health.set("current", clampf(cur + 15.0, 0, max_h))
		print("[HandHold] Healed 15 HP (now %.0f/%.0f)" % [health.get("current"), health.get("max_health")])
	# Visual flash
	if player_mesh:
		var tw := create_tween()
		tw.tween_property(player_mesh, "scale", Vector3(1.08, 0.96, 1.08), 0.08)
		tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.14)
	# Particle puff at hand
	if hand_attachment:
		var puff := GPUParticles3D.new()
		puff.emitting = true
		puff.amount = 12
		puff.lifetime = 0.6
		puff.one_shot = true
		puff.explosiveness = 0.9
		var mat := ParticleProcessMaterial.new()
		mat.direction = Vector3(0,1,0)
		mat.spread = 45.0
		mat.initial_velocity_min = 1.2
		mat.initial_velocity_max = 2.4
		mat.gravity = Vector3(0, -1.5, 0)
		mat.scale_min = 0.06
		mat.scale_max = 0.12
		mat.color = held_item.preview_color
		puff.process_material = mat
		var sphere := SphereMesh.new()
		sphere.radius = 0.04
		sphere.height = 0.08
		puff.draw_pass_1 = sphere
		hand_attachment.add_child(puff)
		get_tree().create_timer(1.0).timeout.connect(func(): if is_instance_valid(puff): puff.queue_free())
	# For consumable usable, optionally consume on use (keep for now, but log)
	if held_item.type == ItemData.ItemType.CONSUMABLE:
		print("[HandHold] Consumable used — you may want to drop/consume it (not auto-consumed)")

func is_holding_item() -> bool:
	return _is_holding and held_item != null

func can_use_held_item() -> bool:
	return is_holding_item() and held_item.is_usable and not _is_using_item

func _is_action_blocked_when_holding(action: String) -> bool:
	if not is_holding_item():
		return false
	if held_item and held_item.is_usable:
		# Usable items allow walking/sprinting + ITEMUSE, block everything else (punch/dash/etc)
		if action in ["punch", "dash", "jump", "grab", "throw", "pickup", "cloak"]:
			# Allow punch to be remapped to USE — so punch not blocked but redirected
			if action == "punch":
				return false # let _try_attack handle redirect to USE
			return true
		return false
	else:
		# Non-usable: only walk/sprint allowed — block all other actions
		if action in ["punch", "dash", "jump", "grab", "throw", "pickup", "attack", "cloak"]:
			return true
		return false

func _is_upper_action_active() -> bool:
	if animator and animator.active and use_layered_anims:
		# OneShot active or internal_active indicates upper anim playing
		var active = animator.get("parameters/UpperOneShot/active")
		# internal_active is also a bool param (read-only)
		if active is bool and active:
			return true
	return _upper_action_active and _attack_timer < _attack_total

func _play_upper_action(anim: String, speed_scale: float = 1.0, fadein: float = 0.08, fadeout: float = 0.14) -> void:
	if c11_ap == null or not c11_ap.has_animation(anim):
		return
	if animator == null or not animator.active:
		_play_c11(anim, fadein, speed_scale)
		return
	# Configure the upper leaf animation + time scale
	var upper_anim_node = animator.tree_root.get_node("UpperAction") as AnimationNodeAnimation
	if upper_anim_node:
		upper_anim_node.animation = StringName(anim)
	animator.set("parameters/UpperScale/scale", speed_scale)
	var upper_node = animator.tree_root.get_node("UpperOneShot")
	if upper_node and upper_node is AnimationNodeOneShot:
		upper_node.fadein_time = fadein
		upper_node.fadeout_time = fadeout
		# Kick is always full-body. Punches are full-body when standing, upper-only when moving (as requested)
		var is_kick: bool = anim == "kick_spin"
		if is_kick:
			upper_node.filter_enabled = false
			_is_fullbody_action = true
		elif anim in COMBO_ANIMS:
			# moving if input or velocity indicates locomotion - otherwise standing full-body
			var ix := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
			var iz := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
			var is_moving := Vector2(ix, iz).length() > 0.12 or velocity.length() > 0.12
			upper_node.filter_enabled = is_moving # moving -> filtered upper only (perfect), standing -> full body head-to-toe
			_is_fullbody_action = not is_moving
		else:
			# pick_up/throw etc keep filtered upper
			upper_node.filter_enabled = true
			_is_fullbody_action = false
	animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_upper_action_active = true
	# For hitbox timing we still use _attack_timer logic
	_attack_timer = 0.0
	_has_hit_this_swing = false
	_hitbox_active = false
	c11_current_anim = anim

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var f = _find_animation_player(c)
		if f:
			return f
	return null

func _play_c11(anim: String, blend: float = 0.2, speed_scale: float = 1.0) -> void:
	if c11_ap == null or not c11_ap.has_animation(anim):
		return
	if c11_current_anim == anim and c11_ap.is_playing():
		# keep speed_scale in sync if caller requested different speed (e.g. 120% walk)
		if c11_ap.speed_scale != speed_scale:
			c11_ap.speed_scale = speed_scale
		return
	c11_ap.play(anim, blend, speed_scale)
	c11_ap.speed_scale = speed_scale
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
	if use_layered_anims and animator and animator.active:
		_play_upper_action(anim, spd, COMBO_BLEND, 0.14)
	else:
		c11_ap.play(anim, COMBO_BLEND, spd)
		c11_current_anim = anim
	# --- Aim FIRST: face the camera crosshair so punches go where you look ---
	var aim_dir: Vector3 = _compute_aim_dir()
	if aim_camera and is_instance_valid(aim_camera):
		aim_dir = _aim_dir_from_point(_compute_aim_point())
	_snap_to_target(aim_dir)
	# --- Lunge in snapped/aimed direction ---
	var forward: Vector3 = player_mesh.global_basis.z
	forward.y = 0
	forward = forward.normalized()
	if forward.length() < 0.2:
		forward = aim_dir
	_lunge_velocity = forward * COMBO_LUNGE[idx] * 1.35
	# --- Punch scale anticip. ---
	_do_attack_anticipation(idx)
	# --- Whiff FOV kick handled via spring pivot ---
	print("[Combo] %d/%d %s dmg=%.0f hs=%.2f" % [idx + 1, COMBO_ANIMS.size(), anim, COMBO_DAMAGE[idx], COMBO_HITSTOP[idx]])

func _compute_aim_dir() -> Vector3:
	# Flat world direction the camera/crosshair is pointing at (ground-projected)
	var dir: Vector3 = Vector3.FORWARD
	if spring_arm_pivot:
		dir = Vector3.FORWARD.rotated(Vector3.UP, spring_arm_pivot.rotation.y)
	dir.y = 0
	if dir.length() < 0.01:
		dir = Vector3.FORWARD
	return dir.normalized()

func _compute_aim_point() -> Vector3:
	# Raycast from camera through screen center to get a precise world aim point
	var cam: Camera3D = aim_camera
	if cam == null or not is_instance_valid(cam):
		return global_position + _compute_aim_dir() * 20.0
	var vp_center := get_viewport().get_visible_rect().size * 0.5
	var from := cam.global_position
	var to := cam.project_ray_origin(vp_center) + cam.project_ray_normal(vp_center) * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	# Exclude the player's own body AND combat areas (hurtbox/hitboxes) so the
	# crosshair ray isn't blocked by the player's torso hanging in front of the
	# camera — otherwise the aim point resolves to behind the player and they
	# spin 180 degrees.
	var exclude: Array[RID] = [get_rid()]
	for child in get_children():
		if child is CollisionObject3D:
			exclude.append((child as CollisionObject3D).get_rid())
	q.exclude = exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		return hit.position
	return to

func _aim_dir_from_point(point: Vector3) -> Vector3:
	var dir := point - global_position
	dir.y = 0
	if dir.length() < 0.05:
		return _compute_aim_dir()
	dir = dir.normalized()
	var cam_dir := _compute_aim_dir()
	# Safety: if the aim point resolves behind/sideways of the camera view
	# (e.g. looking straight down at your feet), fall back to the camera
	# forward so the player never snaps 180 degrees.
	if rad_to_deg(cam_dir.angle_to(dir)) > 85.0:
		return cam_dir
	return dir

func _snap_to_target(aim_dir: Vector3) -> void:
	if player_mesh == null:
		return
	if aim_dir.length() < 0.1:
		aim_dir = _compute_aim_dir()
	var best: Node3D = null
	var best_ang: float = aim_snap_angle if is_aiming else target_snap_angle
	var best_dist: float = INF
	var snap_cone: float = aim_snap_angle if is_aiming else target_snap_angle
	# Search fighters/dummies/health groups — pick the enemy closest to the camera aim ray
	var candidates: Array[Node] = []
	candidates.append_array(get_tree().get_nodes_in_group("health"))
	candidates.append_array(get_tree().get_nodes_in_group("dummy"))
	candidates.append_array(get_tree().get_nodes_in_group("fighter"))
	var seen: Dictionary = {}
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
		var ang: float = rad_to_deg(aim_dir.angle_to(to_flat))
		if ang > snap_cone:
			continue
		# Pick smallest angle (closest to crosshair); tie-break closest distance
		if ang < best_ang - 0.01 or (abs(ang - best_ang) < 0.01 and dist < best_dist):
			best_ang = ang
			best_dist = dist
			best = body
	# Face the aim point by default so punches go where the crosshair points;
	# if an enemy sits near the crosshair, snap dead-center onto it so hits never whiff.
	var face_dir: Vector3 = aim_dir
	if best:
		var dir: Vector3 = best.global_position - global_position
		dir.y = 0
		if dir.length() >= 0.01:
			face_dir = dir.normalized()
	player_mesh.rotation.y = atan2(face_dir.x, face_dir.z)

func _get_skeleton() -> Skeleton3D:
	if _skeleton and is_instance_valid(_skeleton):
		return _skeleton
	if player_mesh == null:
		return null
	_skeleton = player_mesh.get_node_or_null("C11/root/Skeleton3D") as Skeleton3D
	if _skeleton == null:
		_skeleton = _find_skeleton(player_mesh)
	return _skeleton

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null

func _find_best_target(aim_dir: Vector3) -> Node3D:
	if aim_dir.length() < 0.1:
		aim_dir = _compute_aim_dir()
	var best: Node3D = null
	var best_ang: float = target_snap_angle
	var best_dist: float = INF
	var snap_cone: float = target_snap_angle
	var candidates: Array[Node] = []
	candidates.append_array(get_tree().get_nodes_in_group("health"))
	candidates.append_array(get_tree().get_nodes_in_group("dummy"))
	candidates.append_array(get_tree().get_nodes_in_group("fighter"))
	var seen: Dictionary = {}
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
		var ang: float = rad_to_deg(aim_dir.angle_to(to_flat))
		if ang > snap_cone:
			continue
		if ang < best_ang - 0.01 or (abs(ang - best_ang) < 0.01 and dist < best_dist):
			best_ang = ang
			best_dist = dist
			best = body
	return best

func _update_upper_skeleton_look(delta: float, look_dir: Vector3) -> void:
	var skel := _get_skeleton()
	if skel == null:
		return
	if _spine_bone_idx == -1:
		_spine_bone_idx = skel.find_bone("spine_03.x")
		if _spine_bone_idx == -1:
			_spine_bone_idx = skel.find_bone("spine_03")
		if _spine_bone_idx == -1:
			_spine_bone_idx = skel.find_bone("spine_02.x")
		if _spine_bone_idx == -1:
			return
	look_dir.y = 0
	if look_dir.length() < 0.01:
		return
	look_dir = look_dir.normalized()
	var mesh_yaw: float = player_mesh.rotation.y
	var target_yaw: float = atan2(look_dir.x, look_dir.z)
	var delta_yaw: float = angle_difference(mesh_yaw, target_yaw)
	delta_yaw = clamp(delta_yaw, deg_to_rad(-65.0), deg_to_rad(65.0))
	_upper_look_angle = lerp_angle(_upper_look_angle, delta_yaw, delta * 12.0)
	_upper_look_weight = lerpf(_upper_look_weight, 1.0, delta * 10.0)
	var q := Quaternion(Vector3.UP, _upper_look_angle * _upper_look_weight)
	skel.set_bone_pose_rotation(_spine_bone_idx, q)
	# also drive neck a bit for head look
	var neck_idx := skel.find_bone("neck.x")
	if neck_idx != -1:
		var nq := Quaternion(Vector3.UP, _upper_look_angle * _upper_look_weight * 0.35)
		skel.set_bone_pose_rotation(neck_idx, nq)

func _clear_upper_skeleton_look(delta: float) -> void:
	if _upper_look_weight <= 0.01 and _upper_look_angle == 0.0:
		return
	_upper_look_weight = lerpf(_upper_look_weight, 0.0, delta * 12.0)
	_upper_look_angle = lerp_angle(_upper_look_angle, 0.0, delta * 12.0)
	var skel := _get_skeleton()
	if skel == null or _spine_bone_idx == -1:
		return
	if _upper_look_weight < 0.02:
		skel.clear_bones_global_pose_override()
		# reset to rest
		skel.set_bone_pose_rotation(_spine_bone_idx, Quaternion.IDENTITY)
		var neck_idx := skel.find_bone("neck.x")
		if neck_idx != -1:
			skel.set_bone_pose_rotation(neck_idx, Quaternion.IDENTITY)
	else:
		var q := Quaternion(Vector3.UP, _upper_look_angle * _upper_look_weight)
		skel.set_bone_pose_rotation(_spine_bone_idx, q)
		var neck_idx := skel.find_bone("neck.x")
		if neck_idx != -1:
			var nq := Quaternion(Vector3.UP, _upper_look_angle * _upper_look_weight * 0.35)
			skel.set_bone_pose_rotation(neck_idx, nq)

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
	# Heavy hit cancels dash so knockback plays cleanly
	if _is_crit and is_dashing:
		is_dashing = false
		_is_fullbody_action = false
		dash_timer = 0.0
		if use_layered_anims and animator and animator.active:
			animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)

func _on_died(_killer: Node) -> void:
	is_attacking = false
	_upper_action_active = false
	_is_fullbody_action = false
	combo_queued = false
	_hitbox_active = false
	if hitbox_main: hitbox_main.set("active", false)
	if hitbox_kick: hitbox_kick.set("active", false)
	# Drop grabbed body if we die
	if grabber and grabber.is_grabbing():
		grabber.release_grab()
	# --- GTA5 ragdoll ---
	if ragdoll == null:
		_setup_ragdoll()
	if ragdoll:
		var dir: Vector3 = Vector3.ZERO
		var pos: Vector3 = global_position + Vector3(0, 0.9, 0)
		var stren: float = 7.5
		if _killer is Node3D and _killer != self:
			dir = (global_position - (_killer as Node3D).global_position)
			dir.y = 0.22
			if dir.length() < 0.1:
				dir = Vector3.FORWARD
			dir = dir.normalized()
			if _killer is CharacterBody3D:
				var kv: Vector3 = (_killer as CharacterBody3D).velocity
				if kv.length() > 1.0:
					dir = (dir + kv.normalized()*0.5).normalized()
					stren += kv.length() * 0.25
		else:
			dir = Vector3(randf_range(-1,1), 0.22, randf_range(-1,1)).normalized()
		# Also add last knockback if available via health
		if health and health.has_method("get") and health.get("_last_knockback") != null:
			var kb: Vector3 = health.get("_last_knockback")
			if kb.length() > 0.5:
				dir = kb.normalized()
				stren = kb.length() * 0.9 + 5.0
		ragdoll.start_ragdoll(dir, pos, stren)
	else:
		# Fallback scale tween if ragdoll missing
		if player_mesh:
			var tw := create_tween()
			tw.tween_property(player_mesh, "scale", Vector3(1.15, 0.75, 1.15), 0.15)
			tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.4)

func _respawn_after_death() -> void:
	if has_meta("is_being_grabbed") and bool(get_meta("is_being_grabbed")):
		print("[Player] respawn BLOCKED while grabbed")
		return
	# Called by Health after timer — reset ragdoll before teleport
	if grabber and grabber.is_grabbing():
		grabber.release_grab()
	if ragdoll and ragdoll.is_ragdolled():
		ragdoll.reset_ragdoll()
	global_position = Vector3(0, 2.2, 0)
	velocity = Vector3.ZERO
	_stun_timer = 0.0
	is_attacking = false
	_upper_action_active = false
	_is_fullbody_action = false
	combo_queued = false
	combo_index = 0
	if health:
		health.current = health.max_health
		health.is_dead = false
		health._invuln_timer = 0.35
	if player_mesh:
		player_mesh.scale = Vector3.ONE
	if c11_ap:
		c11_ap.active = true
		if animator and animator.active and use_layered_anims:
			animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
			animator.set("parameters/ground_air_transition/transition_request", "grounded")
			animator.set("parameters/iwr_blend/blend_amount", -1.0)
		elif c11_ap.has_animation("Idle"):
			c11_ap.play("Idle", 0.2)

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
	# If holding usable, redirect to ITEMUSE instead of combo
	if is_holding_item():
		if held_item and held_item.is_usable:
			if try_use_held_item():
				return
		else:
			print("[HandHold] Attack blocked — holding non-usable '%s'" % held_item.display_name)
			return
	var now := Time.get_ticks_msec()
	if now - _last_try_msec < 70:
		return
	_last_try_msec = now
	var f = Engine.get_physics_frames()
	if _attack_frame == f:
		return
	_attack_frame = f
	if c11_ap == null:
		return
	# Allow layered OneShot mode even though c11_use_direct is false
	if not c11_use_direct and not (use_layered_anims and animator and animator.active):
		return
	if not is_on_floor():
		return
	if _stun_timer > 0.0:
		return
	if _is_action_blocked_when_holding("punch"):
		return
	if not is_attacking:
		_play_attack(0)
		return
	if combo_index < COMBO_ANIMS.size() - 1:
		# Queue window: allow at any time after 15% but earlier queue = buffered, later = immediate
		var can_queue := true
		var prog: float = 0.0
		if use_layered_anims and animator and animator.active:
			if _attack_total > 0.0:
				prog = _attack_timer / _attack_total
				if prog < 0.15:
					can_queue = false
		else:
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

func _check_camera_turn() -> void:
	if not turn_enabled:
		return
	if _is_turning:
		return
	if _turn_cooldown_timer > 0.0:
		return
	if player_mesh == null or spring_arm_pivot == null:
		return
	if ragdoll and ragdoll.is_ragdolled():
		return
	if health and health.is_dead:
		return
	if is_aiming:
		return
	if is_dashing:
		return
	if is_attacking and _is_fullbody_action:
		return
	if not is_on_floor():
		return
	if is_picking_up and _is_fullbody_action:
		return
	var input_x := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var input_z := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	var is_idle: bool = Vector2(input_x, input_z).length() <= 0.12 and velocity.length() <= 0.45
	if turn_only_when_idle and not is_idle:
		# Reset deadzone reference while moving so idle re-entry starts fresh
		_last_turn_cam_yaw = spring_arm_pivot.rotation.y
		_turn_reference_initialized = true
		return
	var cam_yaw: float = spring_arm_pivot.rotation.y
	if not _turn_reference_initialized:
		_last_turn_cam_yaw = cam_yaw
		_turn_reference_initialized = true
		return
	# Deadzone is 45° of camera yaw movement since last turn - triggers ONLY ONCE per 45°
	var cam_delta: float = angle_difference(_last_turn_cam_yaw, cam_yaw)
	if abs(rad_to_deg(cam_delta)) < turn_threshold_deg - 0.7:
		return
	var dir: int = 1 if cam_delta > 0.0 else -1
	var anim: String = "Turn_left" if dir > 0 else "Turn_right"
	# Update reference immediately so next 45° must be NEW movement (single fire per deadzone)
	_last_turn_cam_yaw = cam_yaw
	if c11_ap:
		if not c11_ap.has_animation(anim):
			# fallback case-insensitive search
			var want: String = anim.to_lower()
			for a in c11_ap.get_animation_list():
				if a.to_lower() == want:
					anim = a
					break
			if not c11_ap.has_animation(anim):
				# try lower variants turn_right / turn_left
				for cand in ["turn_right", "turn_left", "Turn_Right", "Turn_Left"]:
					if c11_ap.has_animation(cand) and cand.to_lower() == want:
						anim = cand
						break
		if not c11_ap.has_animation(anim):
			# no turn anim available - just snap rotation without anim
			var step_fallback: float = deg_to_rad(turn_threshold_deg) * dir
			player_mesh.rotation.y += step_fallback
			_turn_cooldown_timer = turn_cooldown
			print("[Turn] no anim found, snapped %.1f deg" % rad_to_deg(step_fallback))
			return
	_trigger_turn(dir, anim)


func _trigger_turn(dir: int, anim: String) -> void:
	_is_turning = true
	var anim_len: float = 0.9
	if c11_ap and c11_ap.has_animation(anim):
		anim_len = c11_ap.get_animation(anim).length / max(turn_anim_speed, 0.1)
	_turn_cooldown_timer = anim_len + turn_cooldown + 0.24
	var blend_in: float = 0.22
	var blend_out: float = 0.24
	# Use skeleton's actual root delta to avoid 90 vs 113 mismatch flicker (Turn_left ~113°, Turn_right ~-106°)
	var step: float = _get_turn_step(anim, dir)
	_is_fullbody_action = true
	# Keep AnimationTree active and use OneShot full-body so pre/mid blend is smooth (no disable flicker)
	if use_layered_anims and animator and animator.active:
		var upper_oneshot = animator.tree_root.get_node("UpperOneShot") as AnimationNodeOneShot
		if upper_oneshot:
			upper_oneshot.filter_enabled = false
			upper_oneshot.fadein_time = blend_in
			upper_oneshot.fadeout_time = blend_out
		var upper_anim = animator.tree_root.get_node("UpperAction") as AnimationNodeAnimation
		if upper_anim:
			upper_anim.animation = StringName(anim)
		animator.set("parameters/UpperScale/scale", turn_anim_speed)
		animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		c11_current_anim = anim
		print("[Turn] %s dir=%d via OneShot len=%.2f step=%.1f" % [anim, dir, anim_len, rad_to_deg(step)])
		# Mesh stays 0 during Turn (skeleton 0->step), then Mesh 0->step cancels skeleton step->0.
		# CRITICAL: OneShot fadeout is a CROSSFADE that starts at (clip_len - fadeout), NOT after
		# the clip ends. So the mesh tween must run during that exact same window. Linear easing
		# mirrors the fadeout's linear blend so mesh + skeleton yaw sums to a constant step.
		if _turn_tween and _turn_tween.is_valid():
			_turn_tween.kill()
		_turn_tween = create_tween()
		_turn_tween.set_trans(Tween.TRANS_LINEAR)
		_turn_tween.tween_interval(maxf(anim_len - blend_out, 0.0))
		_turn_tween.tween_property(player_mesh, "rotation:y", player_mesh.rotation.y + step, blend_out)
		_turn_tween.tween_callback(func():
			if not _is_turning:
				return
			_is_turning = false
			_is_fullbody_action = false
			c11_current_anim = ""
			if upper_oneshot:
				upper_oneshot.filter_enabled = true
				upper_oneshot.fadein_time = 0.08
				upper_oneshot.fadeout_time = 0.14
		)
	else:
		# Fallback direct AP (no tree) - tween mesh over the AP crossfade to match
		# (state machine replays Idle at clip end with ~0.2s crossfade; linear matches it)
		_play_c11(anim, blend_in, turn_anim_speed)
		c11_current_anim = anim
		print("[Turn] %s dir=%d direct len=%.2f step=%.1f" % [anim, dir, anim_len, rad_to_deg(step)])
		if _turn_tween and _turn_tween.is_valid():
			_turn_tween.kill()
		_turn_tween = create_tween()
		_turn_tween.set_trans(Tween.TRANS_LINEAR)
		_turn_tween.tween_interval(anim_len)
		_turn_tween.tween_property(player_mesh, "rotation:y", player_mesh.rotation.y + step, 0.2)
		_turn_tween.tween_callback(func():
			if not _is_turning:
				return
			_is_turning = false
			_is_fullbody_action = false
			c11_current_anim = ""
		)


func _get_turn_step(anim: String, dir: int) -> float:
	# Use skeleton root's actual yaw delta to avoid flicker (113° vs 90° mismatch causes snap back)
	if c11_ap and c11_ap.has_animation(anim):
		var a: Animation = c11_ap.get_animation(anim)
		for i in range(a.get_track_count()):
			var path: String = str(a.track_get_path(i))
			if path == "root/Skeleton3D:root.x" and a.track_get_type(i) == Animation.TYPE_ROTATION_3D:
				var cnt: int = a.track_get_key_count(i)
				if cnt >= 2:
					var q0: Quaternion = a.track_get_key_value(i, 0)
					var q1: Quaternion = a.track_get_key_value(i, cnt - 1)
					var y0: float = q0.get_euler().y
					var y1: float = q1.get_euler().y
					var delta: float = angle_difference(y0, y1)
					if abs(delta) > deg_to_rad(30.0) and abs(delta) < deg_to_rad(160.0):
						# Enforce requested direction (swapped mapping already)
						return abs(delta) * dir
				break
	return deg_to_rad(90.0) * dir


func _cancel_turn() -> void:
	if not _is_turning and not _is_fullbody_action:
		return
	_is_turning = false
	_is_fullbody_action = false
	if _turn_tween and _turn_tween.is_valid():
		_turn_tween.kill()
	_turn_tween = null
	if animator and animator.active and use_layered_anims:
		# The visual heading during Turn = mesh yaw + skeleton root yaw. ABORT snaps the
		# skeleton root to 0 instantly, so transfer its current yaw onto the mesh first
		# or the model pops back toward the original heading mid-turn.
		_bake_turn_skeleton_yaw_into_mesh()
		animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
		# restore filter for punches
		var upper_oneshot = animator.tree_root.get_node("UpperOneShot") as AnimationNodeOneShot
		if upper_oneshot:
			upper_oneshot.filter_enabled = true
			upper_oneshot.fadein_time = 0.08
			upper_oneshot.fadeout_time = 0.14
	if c11_ap:
		if c11_ap.has_animation("Idle"):
			c11_ap.play("Idle", 0.18)
		c11_current_anim = "Idle"
	_turn_cooldown_timer = turn_cooldown * 0.5
	print("[Turn] cancelled")


func _bake_turn_skeleton_yaw_into_mesh() -> void:
	if player_mesh == null:
		return
	var skel := _get_skeleton()
	if skel == null:
		return
	var bone_idx: int = skel.find_bone("root")
	if bone_idx < 0:
		return
	# Yaw the turn anim applied so far = current pose relative to the rest pose
	var q_rest: Quaternion = skel.get_bone_rest(bone_idx).basis.get_rotation_quaternion()
	var q_now: Quaternion = skel.get_bone_pose_rotation(bone_idx)
	var rel: Quaternion = q_rest.inverse() * q_now
	player_mesh.rotation.y += rel.get_euler().y


func _on_c11_animation_finished(anim_name: String) -> void:
	# Handle turn finish - timer handles bake/re-enable; avoid snap by not clearing early
	if anim_name in ["Turn_left", "Turn_right", "turn_left", "turn_right"]:
		# If turn was cancelled, flags already cleared; otherwise let timer bake 90deg
		if _is_turning:
			# keep _is_turning true until timer bakes, just ensure cooldown
			_turn_cooldown_timer = max(_turn_cooldown_timer, turn_cooldown)
		else:
			_is_fullbody_action = false
			c11_current_anim = ""
		return
	# Handle dash finish (clean up full-body state)
	if is_dashing and anim_name == c11_current_anim:
		is_dashing = false
		_is_fullbody_action = false
		c11_current_anim = ""
		return
	# Handle pickup
	if anim_name.to_lower().begins_with("pick") or anim_name.to_lower() == "pick_up" or anim_name.to_lower() == "pickup":
		is_picking_up = false
		_upper_action_active = false
		_is_fullbody_action = false
		c11_current_anim = ""
		if not (use_layered_anims and animator and animator.active):
			_play_c11("Idle")
		return
	# Handle ITEMUSE finish (hand hold use)
	if anim_name == USE_ANIM or anim_name.to_lower().begins_with("upperbody_itemuse"):
		_is_using_item = false
		_use_timer = 0.0
		c11_current_anim = ""
		_upper_action_active = false
		_is_fullbody_action = false
		print("[HandHold] USE anim finished: %s" % anim_name)
		return
	if anim_name == HOLD_ANIM or anim_name.to_lower().begins_with("upperbody_itemhold"):
		# Hold loops — should not finish unless faded out
		return
	if anim_name not in COMBO_ANIMS:
		# Also clear throw/punch filtered upper when generic upper finishes
		if anim_name in ["throw", "beam", "Summon", "NO"]:
			_upper_action_active = false
			_is_fullbody_action = false
			c11_current_anim = ""
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
			_upper_action_active = false
			_is_fullbody_action = false
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

func _try_dash() -> bool:
	if _is_action_blocked_when_holding("dash"):
		print("[HandHold] Dash blocked — holding '%s'" % (held_item.display_name if held_item else "item"))
		return false
	if _is_using_item:
		print("[Dash] guard: using item")
		return false
	if c11_ap == null:
		print("[Dash] guard: c11_ap null")
		return false
	if is_dashing:
		print("[Dash] guard: already dashing")
		return false
	if dash_recovery_timer > 0.0:
		print("[Dash] guard: in recovery (%.2fs left)" % dash_recovery_timer)
		return false
	if not is_on_floor():
		print("[Dash] guard: not on floor")
		return false
	if ragdoll and ragdoll.is_ragdolled():
		print("[Dash] guard: ragdolled")
		return false
	if health and health.is_dead:
		print("[Dash] guard: dead")
		return false
	# If mid-pickup, don't allow dash (block with full body action)
	if is_picking_up and _is_fullbody_action:
		print("[Dash] guard: mid-pickup")
		return false
	if Input.is_action_pressed("run"):
		print("[Dash] guard: sprinting")
		return false
	var has_dodge: bool = c11_ap.has_animation("Dodge_forward")
	print("[Dash] has Dodge_forward: %s" % has_dodge)
	# Decide direction: dominant input axis, else camera forward
	var dir: Vector3 = _compute_dash_direction()
	if dir.length() < 0.01:
		dir = _compute_aim_dir()
	dir.y = 0
	if dir.length() < 0.01:
		dir = player_mesh.global_basis.z if player_mesh else Vector3.FORWARD
	dir = dir.normalized()
	# Cancel attack if within cancel window (no-op if not attacking)
	_cancel_attack_for_dash()
	# Detect diagonal: W+A/W+D/S+A/S+D — both axes active
	var _ix_diag: float = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var _iz_diag: float = Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	_dash_is_diagonal = abs(_ix_diag) > 0.1 and abs(_iz_diag) > 0.1
	# Keep body strafe-locked by default; diagonal dashes will rotate in _physics_process
	dash_direction = dir
	dash_timer = dash_duration
	dash_recovery_timer = dash_duration + dash_recovery
	is_dashing = true
	# Pick directional dash anim based on dominant axis (4 cardinal)
	var anim: String = _pick_dash_anim(dir)
	dash_anim_speed = dash_anim_speed_scale
	# Play as full-body action via the layered OneShot (filter disabled for full-body override)
	if use_layered_anims and animator and animator.active:
		# Configure upper leaf for dash, set scale, then disable filter so it overrides legs
		var upper_anim_node = animator.tree_root.get_node("UpperAction") as AnimationNodeAnimation
		if upper_anim_node:
			upper_anim_node.animation = StringName(anim)
		animator.set("parameters/UpperScale/scale", dash_anim_speed)
		var upper_node = animator.tree_root.get_node("UpperOneShot")
		if upper_node and upper_node is AnimationNodeOneShot:
			upper_node.filter_enabled = false
			upper_node.fadein_time = 0.06
			upper_node.fadeout_time = 0.12
		animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_is_fullbody_action = true
	else:
		# Direct AnimationPlayer mode (no tree): just play it
		_play_c11(anim, 0.06, dash_anim_speed)
	c11_current_anim = anim
	print("[Dash] %s dir=(%.2f,%.2f) speed=%.1f" % [anim, dir.x, dir.z, dash_speed])
	return true

func _compute_dash_direction() -> Vector3:
	var ix: float = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var iz: float = Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	var v: Vector2 = Vector2(ix, iz)
	if v.length() < 0.1:
		return Vector3.ZERO
	# Rotate input by camera yaw so dash is camera-relative
	var yaw: float = spring_arm_pivot.rotation.y if spring_arm_pivot else 0.0
	var world: Vector3 = Vector3(v.x, 0, v.y).rotated(Vector3.UP, yaw)
	world.y = 0
	if world.length() < 0.01:
		return Vector3.ZERO
	return world.normalized()

func _pick_dash_anim(dir: Vector3) -> String:
	# Diagonal dashes (W+A/W+D/S+A/S+D) always map to Dodge_forward (W diagonal)
	# or Dodge_backward (S diagonal) and will rotate the body. Cardinals keep
	# the 4-way dominant-axis mapping.
	var ix := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var iz := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
	# If no input, convert world dash dir to camera-local (inverse yaw) so
	# dir=(world) correctly maps to ix/iz. Without this, world X/Z was
	# misinterpreted as input X/Z and always biased toward forward.
	if abs(ix) < 0.05 and abs(iz) < 0.05:
		var yaw: float = spring_arm_pivot.rotation.y if spring_arm_pivot else 0.0
		var local_dir: Vector3 = Vector3(dir.x, 0, dir.z).rotated(Vector3.UP, -yaw)
		ix = local_dir.x
		iz = local_dir.z
		# Still no direction (e.g. zero dir) -> default forward
		if abs(ix) < 0.05 and abs(iz) < 0.05:
			ix = 0.0
			iz = -1.0
	# Diagonal: both axes active -> forward diagonal = Dodge_forward, backward diagonal = Dodge_backward
	if abs(ix) > 0.1 and abs(iz) > 0.1:
		var anim_diag: String = "Dodge_forward" if iz < 0.0 else "Dodge_backward"
		# Fallback if missing, otherwise return directly (no dominant-axis check)
		if c11_ap and not c11_ap.has_animation(anim_diag):
			for cand in ["Dodge_forward", "Dodge_backward", "Dodge_right", "Dodge_left"]:
				if c11_ap.has_animation(cand):
					anim_diag = cand
					break
		print("[Dash] pick ix=%.2f iz=%.2f -> %s (diagonal)" % [ix, iz, anim_diag])
		return anim_diag
	var v := Vector2(ix, iz)
	var anim: String = "Dodge_forward"
	# Dominant axis decides cardinal — avoids forward always winning on diagonals
	if abs(v.x) > abs(v.y):
		anim = "Dodge_right" if v.x > 0.0 else "Dodge_left"
	else:
		# iz < 0 is forward (W), iz > 0 is backward (S)
		anim = "Dodge_forward" if v.y < 0.0 else "Dodge_backward"
	# Fall back to a known animation if the chosen name doesn't exist on the rig
	if c11_ap and not c11_ap.has_animation(anim):
		var found: bool = false
		for cand in ["Dodge_forward", "Dodge_backward", "Dodge_right", "Dodge_left"]:
			if c11_ap.has_animation(cand):
				anim = cand
				found = true
				break
		if not found:
			if c11_ap.has_animation("running"):
				anim = "running"
			else:
				anim = "Idle"
	print("[Dash] pick ix=%.2f iz=%.2f -> %s" % [ix, iz, anim])
	return anim

func _cancel_attack_for_dash() -> void:
	if not is_attacking:
		return
	# Only cancel within the configured cancel window (mid-attack)
	if _attack_timer > dash_cancel_attack_window:
		return
	# Abort current combo swing
	is_attacking = false
	_upper_action_active = false
	_is_fullbody_action = false
	combo_queued = false
	_has_hit_this_swing = false
	_hitbox_active = false
	if hitbox_main: hitbox_main.set("active", false)
	if hitbox_kick: hitbox_kick.set("active", false)
	# Abort upper OneShot so it stops mixing into dash
	if use_layered_anims and animator and animator.active:
		animator.set("parameters/UpperOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	_lunge_velocity = Vector3.ZERO

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
	# Dash on Ctrl. Try multiple keycode paths because Ctrl can come through as either
	# physical_keycode (4194322 = KEY_LEFT_CTRL) or keycode depending on layout/OS.
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = event.keycode
		var pkc: int = event.physical_keycode
		# Known modifier keycodes:
		#   4194322 = KEY_LEFT_CTRL, 4194323 = KEY_RIGHT_CTRL
		#   4194326 = KEY_META (Win/Cmd key) — also reported as Ctrl on some systems
		#   4194306 = KEY_CTRL (some Godot versions)
		var is_ctrl: bool = (pkc == 4194322 or pkc == 4194323 or pkc == 4194326
			or kc == 4194322 or kc == 4194323 or kc == 4194326 or kc == 4194306)
		if is_ctrl:
			# Rising-edge latch so holding Ctrl doesn't re-fire dash every frame
			if not _dash_key_latched:
				_dash_key_latched = true
				if _try_dash():
					get_viewport().set_input_as_handled()
				else:
					print("[Dash] _try_dash returned false")
	# Clear latch on key release so next press re-triggers
	if event is InputEventKey and not event.pressed:
		var kc2: int = event.keycode
		var pkc2: int = event.physical_keycode
		var is_ctrl_release: bool = (pkc2 == 4194322 or pkc2 == 4194323 or pkc2 == 4194326
			or kc2 == 4194322 or kc2 == 4194323 or kc2 == 4194326 or kc2 == 4194306)
		if is_ctrl_release:
			_dash_key_latched = false
	if event is InputEventKey and event.pressed and not event.echo:
		# KEY_QUOTELEFT is the ` key, KEY_ASCIITILDE is ~ (shift+`), also check unicode 96 (`) and 126 (~)
		if event.keycode == KEY_QUOTELEFT or event.keycode == KEY_ASCIITILDE or event.physical_keycode == 96 or event.unicode == 96 or event.unicode == 126:
			_toggle_hitbox_debug()
			get_viewport().set_input_as_handled()
			return
		# Toggle cloak with C
		if event.keycode == KEY_C:
			if _is_action_blocked_when_holding("cloak"):
				print("[HandHold] Cloak toggle blocked while holding")
			else:
				toggle_cloak()
			get_viewport().set_input_as_handled()
			return
		# Grab ragdoll / Pick up item with F (grab takes priority) — when holding usable, F triggers USE
		if event.keycode == KEY_F:
			if is_holding_item() and held_item and held_item.is_usable:
				if try_use_held_item():
					get_viewport().set_input_as_handled()
					return
			if _try_grab_or_pickup():
				get_viewport().set_input_as_handled()
				return
		# Drop held item or Throw (upper-body while walking) with G / Q
		if event.keycode == KEY_G or event.keycode == KEY_Q:
			if is_holding_item():
				# Drop takes priority over throw when holding
				if event.keycode == KEY_G:
					drop_held_item()
				else:
					# Q while holding usable could also trigger use? Keep drop for both
					drop_held_item()
				get_viewport().set_input_as_handled()
				return
			if c11_ap and c11_ap.has_animation("throw"):
				if not is_picking_up and not (is_attacking and _is_fullbody_action):
					is_picking_up = true
					_is_fullbody_action = false
					_play_upper_action("throw", 1.45, 0.1, 0.12) if use_layered_anims and animator and animator.active else _play_c11("throw", 0.1, 1.45)
					var tlen: float = c11_ap.get_animation("throw").length / 1.45
					get_tree().create_timer(tlen + 0.12).timeout.connect(func(): is_picking_up = false)
					# TODO: spawn projectile / drop logic can be hooked here
					print("[Upper] throw while moving")
				get_viewport().set_input_as_handled()
				return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not is_picking_up:
			_try_attack()

func _try_grab_or_pickup() -> bool:
	if _is_action_blocked_when_holding("grab"):
		print("[HandHold] Grab blocked while holding '%s'" % held_item.display_name)
		return false
	# If currently grabbing, release first (F toggles)
	if grabber and grabber.is_grabbing():
		grabber.release_grab()
		print("[Player] Released ragdoll")
		return true
	# Try grab nearest ragdolled body before item pickup (neck-exact)
	if grabber:
		if grabber.try_grab_nearest():
			print("[Player] Grabbed ragdoll at neck")
			_play_grab_pickup_anim()
			return true
	# Fallback to item pickup
	return _try_interact_pickup()

func _play_grab_pickup_anim() -> void:
	# Play pick_up exactly as item pickup, so dummy is visibly lifted from neck
	if c11_ap == null or is_picking_up:
		return
	var pickup_anim := ""
	for candidate in ["pick_up", "pickup", "Pick_up", "PickUp", "pick_up_item"]:
		if c11_ap.has_animation(candidate):
			pickup_anim = candidate
			break
	if pickup_anim == "":
		for anim_name in c11_ap.get_animation_list():
			if anim_name.to_lower().begins_with("pick"):
				pickup_anim = anim_name
				break
	if pickup_anim != "" and c11_ap:
		is_picking_up = true
		_is_fullbody_action = false
		if use_layered_anims and animator and animator.active:
			_play_upper_action(pickup_anim, 1.35, 0.08, 0.14)
			# Clear is_picking_up when upper OneShot finishes (timer based)
			var ulen: float = c11_ap.get_animation(pickup_anim).length / 1.35
			get_tree().create_timer(ulen + 0.14).timeout.connect(func(): is_picking_up = false)
		else:
			_play_c11(pickup_anim, 0.08, 1.35)
		# is_picking_up will be cleared by _on_c11_animation_finished when pick* ends (direct) or timer (layered)
		# Don't block ragdoll carry: allow tiny movement during pick (freeze is handled in _physics_process is_picking_up branch)
		if player_mesh:
			var dir := Vector3.ZERO
			if grabber and grabber.get_grabbed_body():
				var body := grabber.get_grabbed_body() as Node3D
				if body:
					dir = (body.global_position - global_position)
					dir.y = 0
					if dir.length() > 0.05:
						player_mesh.look_at(global_position - dir.normalized(), Vector3.UP)

func _try_interact_pickup() -> bool:
	if _is_action_blocked_when_holding("pickup"):
		if is_holding_item():
			print("[HandHold] Pickup blocked — HAND full with '%s' (drop with G)" % held_item.display_name)
		return false
	if is_picking_up:
		return false
	# In layered mode, allow pickup while punching (upper queue) — only block if fullbody kick
	if is_attacking and _is_fullbody_action:
		return false
	# Hand full check — block picking another
	if is_holding_item():
		print("[HandHold] Cannot pick up — already holding '%s'" % held_item.display_name)
		return false
	
	var best_pickup: Node3D = null
	var best_dist: float = 3.5
	
	for group_name in ["pickup", "item_pickup"]:
		for p in get_tree().get_nodes_in_group(group_name):
			if p is Node3D and is_instance_valid(p) and p.visible and not p.get("_picked"):
				var dist: float = global_position.distance_to(p.global_position)
				if dist < best_dist:
					best_dist = dist
					best_pickup = p as Node3D
	
	if best_pickup == null:
		return false

	# Turn player towards the pickup
	if player_mesh:
		var dir := (best_pickup.global_position - global_position)
		dir.y = 0.0
		if dir.length() > 0.05:
			player_mesh.look_at(global_position - dir.normalized(), Vector3.UP)
	
	# Check for pickup animation in c11_ap
	var pickup_anim := ""
	if c11_ap:
		for candidate in ["pick_up", "pickup", "Pick_up", "PickUp", "pick_up_item"]:
			if c11_ap.has_animation(candidate):
				pickup_anim = candidate
				break
		if pickup_anim == "":
			for anim_name in c11_ap.get_animation_list():
				if anim_name.to_lower().begins_with("pick"):
					pickup_anim = anim_name
					break

	if pickup_anim != "" and c11_ap:
		is_picking_up = true
		_is_fullbody_action = false
		if use_layered_anims and animator and animator.active:
			_play_upper_action(pickup_anim, 1.25, 0.1, 0.14)
			var anim_len2: float = c11_ap.get_animation(pickup_anim).length / 1.25
			var delay2: float = clampf(anim_len2 * 0.45, 0.15, 0.45)
			get_tree().create_timer(delay2).timeout.connect(func():
				if is_instance_valid(best_pickup) and best_pickup.has_method("try_interact"):
					best_pickup.call("try_interact", self)
			)
			get_tree().create_timer(anim_len2 + 0.14).timeout.connect(func(): is_picking_up = false)
		else:
			_play_c11(pickup_anim, 0.1, 1.25)
			var anim_len: float = c11_ap.get_animation(pickup_anim).length / 1.25
			var delay: float = clampf(anim_len * 0.45, 0.15, 0.45)
			get_tree().create_timer(delay).timeout.connect(func():
				if is_instance_valid(best_pickup) and best_pickup.has_method("try_interact"):
					best_pickup.call("try_interact", self)
			)
	else:
		if best_pickup.has_method("try_interact"):
			best_pickup.call("try_interact", self)
	
	return true

func _physics_process(delta: float) -> void:
	# GTA ragdoll: if ragdolled, skip all player movement/attack logic and let physics bones control collision
	if ragdoll and ragdoll.is_ragdolled():
		# Keep velocity zero; physics bones simulate the body. We still need gravity? Ragdoll handles it via PhysicalBones.
		# Freeze CharacterBody motion so it doesn't slide; ragdoll bones are separate PhysicsBody3Ds
		velocity = Vector3.ZERO
		return
	if health and health.is_dead:
		# Dead but not yet ragdolled (fallback) — no movement
		velocity.x = lerp(velocity.x, 0.0, delta * 6.0)
		velocity.z = lerp(velocity.z, 0.0, delta * 6.0)
		velocity.y -= gravity * delta
		move_and_slide()
		return
	if is_picking_up:
		# Layered pick_up is upper-body only (filtered) → allow walking while picking
		if use_layered_anims and animator and animator.active and not _is_fullbody_action:
			# Allow slow walk while upper pickup plays — just reduce speed, don't freeze
			pass
		else:
			velocity.x = lerp(velocity.x, 0.0, delta * 14.0)
			velocity.z = lerp(velocity.z, 0.0, delta * 14.0)
			if not is_on_floor():
				velocity.y -= gravity * delta
			move_and_slide()
			return
	if Input.is_action_just_pressed("punch") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_try_attack()
	# Dash trigger — InputMap action + raw Ctrl keycode fallback (4194322 = KEY_LEFT_CTRL, 4194323 = KEY_RIGHT_CTRL)
	var dash_pressed: bool = false
	if Input.is_action_just_pressed("dash") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		dash_pressed = true
	if not dash_pressed:
		# Polled Ctrl/Meta fallback: works even if InputMap action isn't registered yet (no editor restart)
		# 4194322 = KEY_LEFT_CTRL, 4194323 = KEY_RIGHT_CTRL, 4194326 = KEY_META (some systems)
		var ctrl_held: bool = Input.is_key_pressed(4194322) or Input.is_key_pressed(4194323) or Input.is_key_pressed(4194326)
		if ctrl_held:
			if not _dash_key_latched:
				_dash_key_latched = true
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					dash_pressed = true
		else:
			_dash_key_latched = false
	if dash_pressed:
		_try_dash()
	# ---- Aiming (hold RMB) ---- 
	var should_aim: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not is_picking_up
	if should_aim != is_aiming:
		is_aiming = should_aim
		if spring_arm_pivot and spring_arm_pivot.has_method("set_aiming"):
			spring_arm_pivot.set_aiming(is_aiming)
	if is_aiming:
		aim_point = _compute_aim_point()
		aim_direction = _aim_dir_from_point(aim_point)
	# Timers
	if _stun_timer > 0.0:
		_stun_timer -= delta
	if _hit_confirm_timer > 0.0:
		_hit_confirm_timer -= delta
	if dash_recovery_timer > 0.0:
		dash_recovery_timer -= delta
	if _turn_cooldown_timer > 0.0:
		_turn_cooldown_timer -= delta
	# Turning can be cancelled by walking/sprint/punch/jump/dash - before checking new turn
	if _is_turning:
		var ix_c := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		var iz_c := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
		var has_move_input := Vector2(ix_c, iz_c).length() > 0.12
		var cancel_by_punch := Input.is_action_just_pressed("punch")
		var cancel_by_jump := Input.is_action_just_pressed("jump")
		var cancel_by_dash := Input.is_action_just_pressed("dash")
		# Also raw Ctrl keys for dash
		if not cancel_by_dash:
			cancel_by_dash = Input.is_key_pressed(4194322) or Input.is_key_pressed(4194323)
		if has_move_input or cancel_by_punch or cancel_by_jump or cancel_by_dash:
			_cancel_turn()
	# Check 45deg camera turn threshold -> triggers Turn_left/Turn_right
	_check_camera_turn()
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
	# Layered combo timer finish (AnimationTree OneShot doesn't emit animation_finished reliably)
	if use_layered_anims and animator and animator.active and is_attacking:
		if _attack_timer >= _attack_total:
			# avoid double firing if signal already handled this frame
			if c11_current_anim in COMBO_ANIMS:
				var _fin_idx := COMBO_ANIMS.find(c11_current_anim)
				# only fire if this is the current combo_index anim (prevents stale)
				if _fin_idx == combo_index:
					_on_c11_animation_finished(c11_current_anim)
	# Also ensure is_attacking can restart after timer if somehow stuck (fallback)
	if use_layered_anims and animator and animator.active and is_attacking and _attack_timer > _attack_total + 0.05:
		# force clear if still stuck
		is_attacking = false
		_upper_action_active = false
		_is_fullbody_action = false
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
	# In layered mode, allow sprint/walk while upper punch is active (only block for fullbody kick)
	var block_sprint := is_attacking and (_is_fullbody_action or not use_layered_anims)
	var is_sprinting: bool = Input.is_action_pressed("run") and not block_sprint and _stun_timer <= 0.0 and not is_aiming
	var grab_slow: float = 0.68 if (grabber and grabber.is_grabbing()) else 1.0
	if is_sprinting:
		speed = run_speed * grab_slow
		if grabber and grabber.is_grabbing():
			speed = run_speed * 0.78 # slightly less slow when running with body
	else:
		speed = walk_speed * grab_slow
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
	# ---- Dash movement state (overrides locomotion while active) ----
	if is_dashing:
		# Lock horizontal velocity to dash direction for the full burst
		velocity.x = dash_direction.x * dash_speed
		velocity.z = dash_direction.z * dash_speed
		dash_timer -= delta
		if dash_timer <= 0.0:
			is_dashing = false
			_is_fullbody_action = false
			c11_current_anim = ""
		# Dash bypasses normal locomotion lerp entirely
		pass
	elif dash_recovery_timer > 0.0:
		# Brief slowdown before full control returns — still biased to dash dir
		var decay: float = clampf(1.0 - (delta / maxf(dash_recovery, 0.001)), 0.0, 1.0)
		var recovery_speed: float = dash_speed * decay
		# Blend back to target locomotion
		velocity.x = lerp(dash_direction.x * recovery_speed, target_x, 0.18)
		velocity.z = lerp(dash_direction.z * recovery_speed, target_z, 0.18)
	else:
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
	# For layered upper punches, don't damp — let lower body walk/run freely
	var should_damp := is_attacking and _lunge_velocity.length() < 0.2 and (_is_fullbody_action or not use_layered_anims)
	if should_damp:
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
		var is_sprinting_now := Input.is_action_pressed("run") and velocity.length() > 0.5 and not is_aiming
		if _is_turning:
			# Turning tween drives rotation - don't override. Still update upper look.
			_clear_upper_skeleton_look(delta)
			# keep hitbox etc handled below; skip normal rotation
			pass
		elif is_dashing:
			if _dash_is_diagonal:
				# Diagonal dash: W+A/W+D face dash dir (forward diagonals),
				# S+A/S+D face the opposite forward diagonal (S+A -> W+D, S+D -> W+A)
				# so Dodge_backward doesn't turn the back to camera.
				var yaw: float = spring_arm_pivot.rotation.y if spring_arm_pivot else 0.0
				var local_diag: Vector3 = dash_direction.rotated(Vector3.UP, -yaw)
				var is_back_diag: bool = local_diag.z > 0.05 # iz >0 = S
				var face_dir: Vector3 = dash_direction
				if is_back_diag:
					face_dir = -dash_direction # flip: S+A -> forward+right, S+D -> forward+left
				var target_yaw_diag: float = atan2(face_dir.x, face_dir.z)
				var rot_speed: float = sprint_rotation_speed * 1.6
				player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, target_yaw_diag, rot_speed * delta)
				if abs(angle_difference(player_mesh.rotation.y, target_yaw_diag)) < 0.02:
					player_mesh.rotation.y = target_yaw_diag
			else:
				# Cardinal / idle dash: keep strafe-locked (no rotation) — same as walking
				var cam_yaw_dash: float = spring_arm_pivot.rotation.y + YAW_OFFSET
				if instant_strafe_lock:
					player_mesh.rotation.y = cam_yaw_dash
				else:
					player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, cam_yaw_dash, strafe_rotation_speed * delta)
		elif is_attacking and _is_fullbody_action:
			# Standing / kick - full body faces target (head-to-toe)
			var aim_dir_full := _compute_aim_dir()
			if aim_camera and is_instance_valid(aim_camera):
				aim_dir_full = _aim_dir_from_point(_compute_aim_point())
			_snap_to_target(aim_dir_full)
			_clear_upper_skeleton_look(delta)
		elif is_attacking and not _is_fullbody_action:
			if is_sprinting_now:
				# Running has no walk+punch blend - keep sprint facing, no upper snap (as requested)
				_clear_upper_skeleton_look(delta)
				if has_input:
					var target_angle := atan2(move_direction.x, move_direction.z)
					player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, target_angle, sprint_rotation_speed * delta)
				else:
					var cam_yaw2 := spring_arm_pivot.rotation.y + YAW_OFFSET
					player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, cam_yaw2, strafe_rotation_speed * delta)
			else:
				# Walking filtered - keep mesh strafe-locked (legs walk where you input) but twist upper spine to target
				var aim_dir_up := _compute_aim_dir()
				if aim_camera and is_instance_valid(aim_camera):
					aim_dir_up = _aim_dir_from_point(_compute_aim_point())
				var look_target := _find_best_target(aim_dir_up)
				var look_dir: Vector3 = aim_dir_up
				if look_target:
					look_dir = (look_target.global_position - global_position)
					look_dir.y = 0
					if look_dir.length() < 0.01:
						look_dir = aim_dir_up
					else:
						look_dir = look_dir.normalized()
				_update_upper_skeleton_look(delta, look_dir)
				# Mesh stays facing camera, so WalkSpace handles leg direction
				var cam_yaw3 := spring_arm_pivot.rotation.y + YAW_OFFSET
				if instant_strafe_lock:
					player_mesh.rotation.y = cam_yaw3
				else:
					player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, cam_yaw3, strafe_rotation_speed * delta)
		else:
			_clear_upper_skeleton_look(delta)
			if is_aiming:
				var aim_yaw: float = atan2(aim_direction.x, aim_direction.z)
				player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, aim_yaw, strafe_rotation_speed * delta)
			elif is_sprinting_now and has_input:
				var target_angle := atan2(move_direction.x, move_direction.z)
				player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, target_angle, sprint_rotation_speed * delta)
			elif has_input:
				# Walking / strafe: keep original strafe-locked follow (not idle)
				var cam_yaw := spring_arm_pivot.rotation.y + YAW_OFFSET
				if instant_strafe_lock:
					player_mesh.rotation.y = cam_yaw
				else:
					player_mesh.rotation.y = lerp_angle(player_mesh.rotation.y, cam_yaw, strafe_rotation_speed * delta)
			else:
				# IDLE: HOLD yaw - don't follow camera continuously.
				# Rotation only happens via 45deg threshold turn (Turn_left/Turn_right).
				pass
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
	var block_jump := is_attacking and (_is_fullbody_action or not use_layered_anims)
	if _is_action_blocked_when_holding("jump"):
		block_jump = true
	var can_jump := coyote_timer > 0.0 and jump_buffer_timer > 0.0 and not block_jump and _stun_timer <= 0.0 and not _is_using_item
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
		_jump_stretch()
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

func _jump_stretch() -> void:
	if player_mesh == null:
		return
	player_mesh.scale = Vector3(0.88, 1.18, 0.88)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(player_mesh, "scale", Vector3.ONE, 0.12)

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
	if use_layered_anims and animator and animator.active:
		if c11_ap.has_animation("jump_start"):
			_play_upper_action("jump_start", 1.35, 0.06, 0.08)
			var n = animator.tree_root.get_node("UpperOneShot")
			if n: n.filter_enabled = false
			_is_fullbody_action = true
			_jump_anim_timer = 0.28
			return
		_jump_anim_timer = 0.28
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
		if use_layered_anims and animator and animator.active:
			var spd2 := 1.35 if power < 0.65 else 1.1
			_play_upper_action(anim, spd2, 0.06, 0.1)
			var n2 = animator.tree_root.get_node("UpperOneShot")
			if n2: n2.filter_enabled = false
			_is_fullbody_action = true
			_land_anim_timer = 0.32 if power < 0.65 else 0.42
			return
		var spd := 1.35 if power < 0.65 else 1.1
		c11_ap.play(anim, 0.06, spd)
		c11_current_anim = anim
		_land_anim_timer = 0.32 if power < 0.65 else 0.42

func play_throw() -> void:
	if c11_ap == null or not c11_ap.has_animation("throw"):
		return
	if is_picking_up:
		return
	_is_fullbody_action = false
	_play_upper_action("throw", 1.45, 0.1, 0.12) if use_layered_anims and animator and animator.active else _play_c11("throw", 0.1, 1.45)

func play_pick_throw_combo(anim_name: String, speed: float = 1.25) -> void:
	if c11_ap == null or not c11_ap.has_animation(anim_name):
		return
	_is_fullbody_action = false
	if use_layered_anims and animator and animator.active:
		_play_upper_action(anim_name, speed)
	else:
		_play_c11(anim_name, 0.1, speed)

func animate(delta: float) -> void:
	# Turn-in-place is exclusive - don't let Idle/Walk override Turn_left/Turn_right
	if _is_turning or (_is_fullbody_action and c11_current_anim in ["Turn_left", "Turn_right", "turn_left", "turn_right"]):
		return
	# --- Layered mode: lower body always follows locomotion, upper via OneShot ---
	if use_layered_anims and animator and animator.active:
		# Keep all WalkSpace animations at walk_anim_speed (125%) without touching movement speed
		animator.set("parameters/WalkScale/scale", walk_anim_speed)
		# Don't block locomotion during upper punch/pickup/throw — only fullbody kick blocks slightly
		if is_on_floor():
			animator.set("parameters/ground_air_transition/transition_request", "grounded")
			if velocity.length() > 0.1:
				if speed == run_speed and Input.is_action_pressed("run"):
					animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), 1.0, delta * ANIMATION_BLEND))
				else:
					# Slow walk — keep direction anim but still locomote while punching
					# For upper-body punches we keep a simple Walk blend so legs keep stepping
					# Use -1..0..1 blend: -1 idle, 0 walk, 1 run . While carrying upper, still 0 for walk.
					var target_blend: float = 0.0
					if velocity.length() < 0.1:
						target_blend = -1.0
					elif speed == run_speed and Input.is_action_pressed("run"):
						target_blend = 1.0
					animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), target_blend, delta * ANIMATION_BLEND))
			else:
				animator.set("parameters/iwr_blend/blend_amount", lerp(animator.get("parameters/iwr_blend/blend_amount"), -1.0, delta * ANIMATION_BLEND))
			# 8-way directional walk: smoothed BlendSpace2D — lerps left<->right etc for smooth strafe
			var ix := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
			var iz := Input.get_action_strength("move_backwards") - Input.get_action_strength("move_forwards")
			var walk_pos := Vector2(ix, -iz) # X strafe, Y forward positive -> matches WalkSpace points at (±1,±1)
			# Framerate-independent exponential smoothing (no popping at variable framerates)
			# t = 1 - exp(-k*dt); k = blend_speed (1/s). Critically damped feel.
			# Faster when starting from idle (input magnitude ramping up) to avoid sluggish first step.
			var input_strength: float = walk_pos.length()
			var was_idle: bool = _walk_blend_pos.length() < 0.18
			var k: float = walk_blend_smoothing_idle if (was_idle and input_strength > 0.3) else walk_blend_smoothing
			# Use exponential smoothing per-axis; clamps to 1.0 so framerate spikes can't overshoot
			var t: float = 1.0 - exp(-k * delta)
			t = clamp(t, 0.0, 1.0)
			_walk_blend_pos = _walk_blend_pos.lerp(walk_pos, t)
			# snap to target when very close to prevent endless micro-lerp
			if _walk_blend_pos.distance_to(walk_pos) < 0.015:
				_walk_blend_pos = walk_pos
			animator.set("parameters/WalkSpace/blend_position", _walk_blend_pos)
		else:
			animator.set("parameters/ground_air_transition/transition_request", "air")
		# Sync OneShot active flag for is_attacking logic
		if animator.get("parameters/UpperOneShot/active") == false and _upper_action_active:
			# OneShot finished -> clear timers similar to _on_c11_animation_finished
			if _attack_timer >= _attack_total - 0.08:
				_upper_action_active = false
		return
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
					_play_c11("running", 0.2, 1.0)
				else:
					var walk_anim := _get_slow_walk_anim()
					var s_spd := walk_anim_speed if walk_anim != "Idle" else 1.0
					_play_c11(walk_anim, walk_direct_xfade, s_spd)
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
