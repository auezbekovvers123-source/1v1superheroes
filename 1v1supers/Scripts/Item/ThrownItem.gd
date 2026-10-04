extends RigidBody3D
class_name ThrownItem
## A thrown held-item. Flies with physics, hurts fighters it hits fast enough,
## and can be picked up again (it joins the "pickup" group like ItemPickup).

const PICKUP_DELAY: float = 0.45 # no instant re-pickup by the thrower
const IMPACT_MIN_SPEED: float = 3.0
const IMPACT_RADIUS: float = 0.5

var item_data: ItemData = null
var thrower: Node3D = null
var item_id: String:
	get:
		return item_data.id if item_data else ""
var item_name: String:
	get:
		return item_data.display_name if item_data else ""
## 0..1 charge the item was thrown with.
var throw_power: float:
	get:
		return _throw_power

var _picked: bool = false
var _life_time: float = 0.0
var _throw_power: float = 0.0

func _ready() -> void:
	add_to_group("pickup")
	contact_monitor = true
	max_contacts_reported = 4
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 0.72
	physics_material_override.bounce = 0.28
	linear_damp = 0.08
	angular_damp = 0.18

## Sets the item up and sends it flying. Call after adding it to the tree.
func launch(data: ItemData, velocity: Vector3, power: float, p_thrower: Node3D, tumble: float) -> void:
	item_data = data
	thrower = p_thrower
	_throw_power = power
	mass = 0.75 + power * 0.35
	var vis := HandHold.make_item_mesh(data)
	vis.name = "ThrownMesh"
	vis.scale = data.hold_scale if data.hold_scale != Vector3.ZERO else Vector3.ONE
	add_child(vis)
	var col := CollisionShape3D.new()
	col.shape = _shape_for(data)
	add_child(col)
	# Don't bounce off the thrower's own capsule on the way out
	if p_thrower is PhysicsBody3D:
		add_collision_exception_with(p_thrower)
	linear_velocity = velocity
	angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized() * (tumble * (0.6 + power * 0.8))

static func _shape_for(data: ItemData) -> Shape3D:
	if data.mesh is BoxMesh:
		var box := BoxShape3D.new()
		box.size = ((data.mesh as BoxMesh).size).max(Vector3(0.16, 0.16, 0.16))
		return box
	if data.mesh is SphereMesh:
		var sph := SphereShape3D.new()
		sph.radius = maxf((data.mesh as SphereMesh).radius * 0.9, 0.05)
		return sph
	if data.is_usable:
		var s := SphereShape3D.new()
		s.radius = 0.13
		return s
	var b := BoxShape3D.new()
	b.size = Vector3(0.17, 0.17, 0.17)
	return b

func _physics_process(delta: float) -> void:
	_life_time += delta
	if global_position.y < -20.0:
		queue_free()
		return
	if _life_time > 0.18 and linear_velocity.length() > IMPACT_MIN_SPEED:
		_check_impact()

func _check_impact() -> void:
	for n in get_tree().get_nodes_in_group("fighter"):
		var body := n as Node3D
		if body == null:
			continue
		# The thrower is only hittable by a strong throw coming back after a second
		if body == thrower and (_life_time < 1.0 or _throw_power < 0.25):
			continue
		if global_position.distance_to(body.global_position + Vector3(0, 0.92, 0)) >= 0.85 + IMPACT_RADIUS:
			continue
		var health := body.get_node_or_null("Health") as Health
		if health == null or health.is_dead:
			continue
		var speed: float = linear_velocity.length()
		var kb: Vector3 = linear_velocity.normalized() * clampf(speed * 0.5, 2.0, 7.0)
		kb.y = 0.35
		var hit := HitInfo.make(clampf(speed * 1.2, 6.0, 22.0), thrower, kb, HitInfo.Kind.THROWN)
		if health.take_damage(hit):
			linear_velocity *= -0.35 # bounce off
			_life_time = 0.0 # no repeat hits right away
			break

## Pick the item back up into `picker`'s hand. `ignore_delay` replays a pickup
## that already happened on another machine.
func try_interact(picker: Player, ignore_delay: bool = false) -> bool:
	if _picked or (_life_time < PICKUP_DELAY and not ignore_delay) or item_data == null:
		return false
	if not picker.hand.pick_up(item_data):
		return false
	take_away()
	return true

## Removes the item from the world (picked up, here or on another machine).
func take_away() -> void:
	if _picked:
		return
	_picked = true
	visible = false
	freeze = true
	remove_from_group("pickup")
	get_tree().create_timer(0.2).timeout.connect(queue_free)

func is_pickable() -> bool:
	return not _picked and visible
