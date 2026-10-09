extends Area3D
class_name Hitbox3D
## An attack's damage volume. While active it queries for overlapping Hurtbox3Ds
## every physics frame (one detection path, no deferred monitoring) and hits each
## fighter at most once per activation.

signal hit_landed(target: Node3D, hit: HitInfo)

var owner_body: Node3D = null
var debug_mesh: MeshInstance3D = null

var _active_time: float = 0.0
var _template: HitInfo = null
var _knockback_strength: float = 0.0
var _already_hit: Dictionary = {} # body instance id -> true
var _shape_node: CollisionShape3D = null

func _ready() -> void:
	if owner_body == null:
		owner_body = get_parent() as Node3D
	collision_layer = 0
	collision_mask = 0
	monitoring = false
	monitorable = false
	for c in get_children():
		if c is CollisionShape3D:
			_shape_node = c
			break

## Builds a sphere hitbox with an optional (hidden) debug mesh.
func setup_sphere(radius: float, debug_color: Color) -> void:
	_shape_node = CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	_shape_node.shape = sphere
	add_child(_shape_node)
	debug_mesh = MeshInstance3D.new()
	debug_mesh.name = "DBG"
	var sph := SphereMesh.new()
	sph.radius = radius
	sph.height = radius * 2.0
	debug_mesh.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = debug_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debug_mesh.material_override = mat
	debug_mesh.visible = false
	add_child(debug_mesh)

## Start a hit window. knockback_strength is applied away from the owner.
func activate(template: HitInfo, knockback_strength: float, duration: float) -> void:
	_template = template
	_knockback_strength = knockback_strength
	_active_time = duration
	_already_hit.clear()

func deactivate() -> void:
	_active_time = 0.0

func is_active() -> bool:
	return _active_time > 0.0

func _physics_process(delta: float) -> void:
	if _active_time <= 0.0:
		return
	_query_hits()
	_active_time -= delta

func _query_hits() -> void:
	if _shape_node == null or _shape_node.shape == null:
		return
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _shape_node.shape
	params.transform = _shape_node.global_transform
	params.collide_with_areas = true
	params.collide_with_bodies = false
	params.collision_mask = Hurtbox3D.LAYER
	for result in get_world_3d().direct_space_state.intersect_shape(params, 16):
		var hurtbox := result.collider as Hurtbox3D
		if hurtbox == null or hurtbox.health == null:
			continue
		var target := hurtbox.get_body()
		if target == null or target == owner_body or _already_hit.has(target.get_instance_id()):
			continue
		_already_hit[target.get_instance_id()] = true
		_hit(target, hurtbox.health)

func _hit(target: Node3D, health: Health) -> void:
	var dir: Vector3 = target.global_position - owner_body.global_position
	dir.y = 0.18
	dir = dir.normalized()
	var hit := HitInfo.make(_template.damage, owner_body, dir * _knockback_strength + Vector3(0, 0.35, 0),
		_template.kind, _template.hitstop, _template.shake)
	if not health.take_damage(hit):
		return
	hit_landed.emit(target, hit)
	HitEffects.sparks((global_position + target.global_position + Vector3(0, 1.0, 0)) * 0.5, self)
