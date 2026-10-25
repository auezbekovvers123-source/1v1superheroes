extends Node
class_name HandHold
## The right hand: what it holds, how the held item looks, using it, throwing it.
## The Inventory is the single source of truth for the held item; this node
## reacts to Inventory.held_item_changed (visual + hold pose) and never keeps its
## own copy.

@export_group("Use")
@export var use_heal_amount: float = 15.0
@export_group("Throw")
@export var throw_max_charge_time: float = 1.15 # seconds of holding to reach 100% power
@export var throw_min_speed: float = 0.95 # 1% power: almost a drop
@export var throw_max_speed: float = 8.9 # 100% power
@export var throw_upward_angle_deg: float = 26.0
@export var throw_hand_forward_offset: float = 0.35 # spawn slightly in front of the hand
@export var throw_angular_tumble: float = 10.0
@export var throw_shake_min: float = 0.14 # camera shake while charging at 1%
@export var throw_shake_max: float = 0.48 # ... and at 100%
@export var throw_release_anim_speed: float = 1.35
@export var drop_power: float = 0.05 # "drop" = a very weak throw

## A thrown item left the hand (online games mirror it on the other machines).
signal thrown(item: ThrownItem)

const HAND_BONES: Array[String] = ["hand.r", "hand_r", "RightHand", "hand.R", "Hand_R"]

var player: Player
var inventory: Inventory
var hand_attachment: BoneAttachment3D = null
var held_instance: Node3D = null

var _attach_tween: Tween = null
var _jitter_base := Vector3.ZERO
var _jitter_active: bool = false

## The item in the hand, or null.
var held_item: ItemData:
	get:
		return inventory.get_held_item() if inventory else null

func setup(p_player: Player, p_inventory: Inventory) -> void:
	player = p_player
	inventory = p_inventory
	inventory.held_item_changed.connect(_on_held_item_changed)

func is_holding() -> bool:
	return held_item != null

func is_holding_usable() -> bool:
	return held_item != null and held_item.is_usable

## Holding something restricts the hands. Usable items still allow ITEMUSE
## (attack presses are redirected to it); nothing held allows everything.
func blocks(action: StringName) -> bool:
	if held_item == null:
		return false
	return action in [&"dash", &"jump", &"grab", &"pickup", &"throw_empty", &"block"] or (action == &"attack" and not held_item.is_usable)

## Puts an item into the hand. Fails (with feedback) when the hand is full.
func pick_up(data: ItemData) -> bool:
	if data == null:
		return false
	if not inventory.can_pickup():
		player.camera_shake(0.18)
		return false
	inventory.add_item(data)
	return true

func _on_held_item_changed(item: ItemData) -> void:
	_clear_visual()
	if item:
		_create_visual(item)
	player.animator.set_hold(&"item", item != null)

# --- Throw / drop ---------------------------------------------------------------

func charge_power(charge_time: float) -> float:
	return clampf(charge_time / throw_max_charge_time, 0.01, 1.0)

## Throws the held item with 0..1 power. The caller plays the release animation.
func throw_item(power: float) -> bool:
	var data := held_item
	if data == null:
		return false
	if player.is_remote():
		return true # the owner's machine throws; its copy of the item arrives over the network
	power = clampf(power, 0.01, 1.0)
	var spawn_pos := _hand_spawn_pos(power)
	inventory.remove_item(data) # clears the visual + hold pose via the signal
	_spawn_thrown(data, spawn_pos, power)
	return true

func _flat_throw_forward() -> Vector3:
	var fwd: Vector3 = player.aim_direction_from_camera()
	# If the aim is behind the character, throw where the body faces instead
	var mesh_fwd: Vector3 = player.mesh.global_basis.z
	mesh_fwd.y = 0
	if mesh_fwd.length() > 0.1:
		mesh_fwd = mesh_fwd.normalized()
		if rad_to_deg(fwd.angle_to(mesh_fwd)) > 85.0:
			fwd = mesh_fwd
	return fwd

func _hand_spawn_pos(power: float) -> Vector3:
	var pos: Vector3 = hand_attachment.global_position if _hand_valid() else player.global_position + Vector3(0, 0.95, 0)
	pos += player.aim_direction_from_camera() * throw_hand_forward_offset
	pos += Vector3.UP * (0.12 + clampf(power, 0.0, 1.0) * 0.06)
	return pos

func _spawn_thrown(data: ItemData, spawn_pos: Vector3, power: float) -> void:
	var fwd := _flat_throw_forward()
	var theta: float = deg_to_rad(throw_upward_angle_deg)
	var dir: Vector3 = (fwd * cos(theta) + Vector3.UP * (sin(theta) + lerpf(0.0, 0.06, power))).normalized()
	var speed: float = lerpf(throw_min_speed, throw_max_speed, power)
	# Carry some of the thrower's running momentum into strong throws
	var carry: Vector3 = Vector3(player.velocity.x, 0, player.velocity.z)
	if carry.length() > 0.5 and power > 0.3:
		dir = (dir * speed + carry * 0.32).normalized()
		speed += carry.length() * 0.18
	var item := ThrownItem.new()
	item.name = "Thrown_%s" % data.id
	HitEffects.parent_for(player).add_child(item)
	item.global_position = spawn_pos
	item.launch(data, dir * speed, power, player, throw_angular_tumble)
	player.camera_shake(lerpf(0.08, 0.28, power))
	player.camera_rig.kick_fov(power * 3.0)
	thrown.emit(item)

## Replays a throw made on another machine: the item leaves this (remote) hand
## exactly where and how fast it left the owner's.
func throw_replayed(data: ItemData, item_name: String, pos: Vector3, velocity: Vector3, spin: Vector3, power: float) -> ThrownItem:
	if held_item:
		inventory.remove_item(held_item)
	var item := ThrownItem.new()
	item.name = item_name
	HitEffects.parent_for(player).add_child(item)
	item.global_position = pos
	item.launch(data, velocity, power, player, 0.0)
	item.angular_velocity = spin
	return item

# --- Use --------------------------------------------------------------------------

## Effect of using the held item (heal + feedback). The caller plays the animation.
func apply_use_effect() -> void:
	var item := held_item
	if item == null:
		return
	player.health.heal(use_heal_amount)
	player.squash_mesh(Vector3(1.08, 0.96, 1.08), 0.08, 0.14)
	if not _hand_valid():
		return
	var puff := GPUParticles3D.new()
	puff.amount = 12
	puff.lifetime = 0.6
	puff.one_shot = true
	puff.explosiveness = 0.9
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 45.0
	mat.initial_velocity_min = 1.2
	mat.initial_velocity_max = 2.4
	mat.gravity = Vector3(0, -1.5, 0)
	mat.scale_min = 0.06
	mat.scale_max = 0.12
	mat.color = item.preview_color
	puff.process_material = mat
	var sphere := SphereMesh.new()
	sphere.radius = 0.04
	sphere.height = 0.08
	puff.draw_pass_1 = sphere
	hand_attachment.add_child(puff)
	puff.emitting = true
	player.get_tree().create_timer(1.0).timeout.connect(puff.queue_free)

# --- Charge jitter (hand trembles harder as throw power rises) --------------------

func begin_jitter() -> void:
	_jitter_active = _hand_valid()
	if _jitter_active:
		_jitter_base = hand_attachment.position

func apply_jitter(power: float, phase: float) -> void:
	if not _jitter_active or not _hand_valid():
		return
	var amp: float = lerpf(0.004, 0.018, power) # metres, hand-local
	hand_attachment.position = _jitter_base + Vector3(sin(phase * 1.9) * amp, cos(phase * 2.3) * amp * 0.7, sin(phase * 1.4 + 0.7) * amp * 0.9)

## smooth=true eases back; false snaps (needed right before a throw spawns from the hand).
func end_jitter(smooth: bool) -> void:
	if not _jitter_active:
		return
	_jitter_active = false
	if not _hand_valid():
		return
	if smooth:
		player.create_tween().tween_property(hand_attachment, "position", _jitter_base, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		hand_attachment.position = _jitter_base

# --- Visual ------------------------------------------------------------------------

func _hand_valid() -> bool:
	return hand_attachment != null and is_instance_valid(hand_attachment)

func _ensure_hand_attachment() -> BoneAttachment3D:
	if _hand_valid():
		return hand_attachment
	var skel := player.get_skeleton()
	if skel == null:
		return null
	var bone := ""
	for cand in HAND_BONES:
		if skel.find_bone(cand) != -1:
			bone = cand
			break
	if bone == "":
		push_warning("[HandHold] No right-hand bone found")
		return null
	hand_attachment = BoneAttachment3D.new()
	hand_attachment.name = "HandHoldAttachment"
	hand_attachment.bone_name = bone
	skel.add_child(hand_attachment)
	return hand_attachment

func _create_visual(data: ItemData) -> void:
	var attach := _ensure_hand_attachment()
	if attach == null:
		return
	var vis := make_item_mesh(data)
	var target_pos: Vector3 = data.hold_offset
	var target_rot: Vector3 = data.hold_rotation_deg * (PI / 180.0)
	var target_scale: Vector3 = data.hold_scale
	# Pop in: start tiny and a little higher, ease into the grip
	vis.scale = target_scale * 0.01
	vis.position = target_pos + Vector3(0, 0.4, 0)
	vis.rotation = target_rot + (Vector3(0, 0.8, 0) if target_rot.length() > 0.01 else Vector3.ZERO)
	attach.add_child(vis)
	held_instance = vis
	_attach_tween = player.create_tween().set_parallel(true)
	_attach_tween.tween_property(vis, "scale", target_scale, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_attach_tween.tween_property(vis, "position", target_pos, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_attach_tween.tween_property(vis, "rotation", target_rot, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _clear_visual() -> void:
	if _attach_tween and _attach_tween.is_valid():
		_attach_tween.kill()
	_attach_tween = null
	if held_instance and is_instance_valid(held_instance):
		held_instance.queue_free()
	held_instance = null

## A static mesh for an item (held in the hand or flying through the air).
static func make_item_mesh(data: ItemData) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if data.scene:
		# Wearables are BoneAttachment scenes: borrow their mesh (static, no skin)
		var inst := data.scene.instantiate()
		var src := RagdollController._find_first(inst, "MeshInstance3D") as MeshInstance3D
		if src:
			mi.mesh = src.mesh
			mi.material_override = src.material_override
			if src.mesh:
				for i in range(src.mesh.get_surface_count()):
					var m: Material = src.get_surface_override_material(i)
					if m == null:
						m = src.mesh.surface_get_material(i)
					if m:
						mi.set_surface_override_material(i, m)
		inst.free()
	elif data.mesh:
		mi.mesh = data.mesh
		if data.material:
			mi.material_override = data.material
	if mi.mesh == null:
		# Simple primitive: sphere for usables, box for everything else
		if data.is_usable:
			var sph := SphereMesh.new()
			sph.radius = 0.12
			sph.height = 0.24
			mi.mesh = sph
		else:
			var box := BoxMesh.new()
			box.size = Vector3(0.18, 0.18, 0.18)
			mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = data.preview_color
		mat.roughness = 0.6
		mat.metallic = 0.1
		mi.material_override = mat
	return mi
