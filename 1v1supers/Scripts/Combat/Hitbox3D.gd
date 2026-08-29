extends Area3D
class_name Hitbox3D
## Hitbox3D — active during attack windows, deals damage via Hurtbox3D/Health
## Attach as child of CharacterBody3D, position at fist/foot. Script auto-configures layers.

signal hit_landed(target: Node, damage: float)

@export var damage: float = 12.0
@export var knockback_strength: float = 3.0
@export var hitstop_duration: float = 0.06
@export var shake_trauma: float = 0.35
@export var override_hitbox_time: bool = false
# If enabled externally, this hitbox is "active". If false, monitors but won't deal.
var active: bool = false:
	set(v):
		active = v
		set_deferred("monitoring", v)
		set_deferred("monitorable", v)
		if v:
			_already_hit.clear()

var _already_hit: Dictionary = {} # instance_id -> true
var _owner_body: CharacterBody3D

func _ready() -> void:
	_owner_body = get_parent_node_3d() as CharacterBody3D
	if _owner_body == null:
		# search up
		var p := get_parent()
		while p and not p is CharacterBody3D:
			p = p.get_parent()
		_owner_body = p as CharacterBody3D
	collision_layer = 0
	collision_mask = 0
	# Hitbox is on layer 2, looks for hurtbox on layer 3
	if collision_layer == 0:
		collision_layer = 2
	# We'll detect Hurtbox3D areas (they are on layer 3)
	collision_mask = 4
	monitoring = false
	monitorable = false
	# Ensure we have a shape
	if get_child_count() == 0:
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.32
		shape.shape = sphere
		add_child(shape)
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)

func try_activate(dmg: float, kb: float, hitstop: float, shake: float, duration: float) -> void:
	damage = dmg
	knockback_strength = kb
	hitstop_duration = hitstop
	shake_trauma = shake
	active = true
	if duration > 0.0:
		var t := get_tree().create_timer(duration)
		t.timeout.connect(func(): if is_instance_valid(self): active = false)

func _on_area_entered(area: Area3D) -> void:
	if not active:
		return
	# Duck-type check for Hurtbox: has health_node or in group hurtbox
	if area.is_in_group("hurtbox") or area.get("health_node") != null:
		_try_hit_hurtbox(area)
	elif area.has_method("take_damage") or area.get_parent().has_method("take_damage"):
		# fallback
		_try_hit_node(area)

func _on_body_entered(body: Node3D) -> void:
	if not active:
		return
	# Support direct Health on body without hurtbox
	if body.has_node("Health"):
		var h = body.get_node("Health")
		if h != null and h.has_method("take_damage"):
			_try_hit_health(h)

func _try_hit_hurtbox(hb: Area3D) -> void:
	var health = hb.get("health_node")
	if health == null:
		# try parent
		var p = hb.get_parent()
		health = p.get_node_or_null("Health")
		if health == null and p.get_parent():
			health = p.get_parent().get_node_or_null("Health")
	if health == null:
		return
	var target_body = hb.get_parent()
	if target_body == _owner_body:
		return # no self-hit
	var tid := target_body.get_instance_id()
	if _already_hit.has(tid):
		return
	_already_hit[tid] = true
	var dir: Vector3 = (target_body.global_position - _owner_body.global_position)
	dir.y = 0.15
	dir = dir.normalized()
	var kb: Vector3 = dir * knockback_strength + Vector3(0, 0.45, 0)
	# Crit if last combo
	var success: bool = health.take_damage(damage, _owner_body, kb, hitstop_duration, shake_trauma)
	if success:
		hit_landed.emit(target_body, damage)
		_on_successful_hit(target_body, hb, kb)

func _try_hit_node(area: Node) -> void:
	var p = area.get_parent()
	var health = p.get_node_or_null("Health")
	if health == null:
		health = area.get_node_or_null("Health")
	if health and health.has_method("take_damage"):
		_try_hit_health(health)

func _try_hit_health(health: Node) -> void:
	var target_body = health.get_parent() as Node3D
	if target_body == _owner_body:
		return
	var tid := target_body.get_instance_id()
	if _already_hit.has(tid):
		return
	_already_hit[tid] = true
	var dir: Vector3 = Vector3.ZERO
	if target_body and _owner_body:
		dir = (target_body.global_position - _owner_body.global_position)
		dir.y = 0.12
		dir = dir.normalized()
	var kb: Vector3 = dir * knockback_strength + Vector3(0, 0.35, 0)
	if health.take_damage(damage, _owner_body, kb, hitstop_duration, shake_trauma):
		hit_landed.emit(target_body, damage)
		_on_successful_hit(target_body, null, kb)

func _on_successful_hit(target: Node, _hurtbox: Area3D, _kb: Vector3) -> void:
	# Attacker feedback: hitstop already in Health, but also do subtle attacker pause
	if _owner_body:
		# Add slight forward stick
		_owner_body.set_meta("hit_confirm", true)
	# Camera shake via attacker pivot
	var pivot = _owner_body.get_node_or_null("SpringArmPivot") if _owner_body else null
	if pivot and pivot.has_method("add_trauma"):
		pivot.add_trauma(shake_trauma)
	# Hit VFX is spawned by Health already; add extra sparks at hitbox pos
	_spawn_sparks(target)

func _spawn_sparks(target: Node) -> void:
	var scene_root = get_tree().current_scene
	if scene_root == null or target == null:
		return
	var pos: Vector3 = global_position
	if target is Node3D:
		pos = (global_position + (target as Node3D).global_position + Vector3(0,1.0,0)) * 0.5
	var p := GPUParticles3D.new()
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0.4, 0)
	mat.spread = 55.0
	mat.initial_velocity_min = 6.0
	mat.initial_velocity_max = 11.0
	mat.gravity = Vector3(0, -9.8, 0)
	mat.scale_min = 0.04
	mat.scale_max = 0.09
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.09, 0.09)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_color = Color(1.0, 0.92, 0.35)
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = sm
	p.draw_pass_1 = mesh
	p.process_material = mat
	p.amount = 10
	p.lifetime = 0.28
	p.one_shot = true
	p.explosiveness = 0.95
	scene_root.add_child(p)
	p.global_position = pos
	p.emitting = true
	var t2 := get_tree().create_timer(1.0)
	t2.timeout.connect(func(): if is_instance_valid(p): p.queue_free())
