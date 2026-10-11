extends PlayerState
class_name LaserState
## Firing the laser visor's heat beam: from the eyes to whatever is under the
## crosshair, damaging what it touches several times a second. Slow walk, the
## body turns with the aim. Ends when either mouse button is let go, the
## stamina runs out or the visor comes off.

const DPS := 30.0
const TICK := 0.1 # seconds between damage ticks
const RANGE := 40.0
const STAMINA_PER_SEC := 20.0
const MIN_STAMINA := 5.0
const KNOCKBACK := 1.6

var _beam: LaserBeam = null
var _tick_timer: float = 0.0

func can_enter(_args: Dictionary) -> bool:
	return player.has_power("laser") and player.stamina.has(MIN_STAMINA) and not player.is_dead()

func enter(_args: Dictionary) -> void:
	_tick_timer = 0.0
	_beam = LaserBeam.new()
	_beam.name = "LaserBeam"
	player.add_child(_beam)

func exit() -> void:
	if _beam and is_instance_valid(_beam):
		_beam.queue_free()
	_beam = null

func handle_intent(i: PlayerInput.Intent) -> void:
	if not (i.aim_held and i.attack_held):
		player.change_state(&"free")
		return
	if i.dash_pressed:
		player.try_change_state(&"dash")

func physics_update(delta: float) -> void:
	if not player.has_power("laser") or not player.stamina.use(STAMINA_PER_SEC * delta):
		player.change_state(&"free")
		return
	var eyes := player.eye_points()
	var from: Vector3 = (eyes[0] + eyes[1]) * 0.5
	var dir := player.aim_point() - from
	if dir.length() < 0.1:
		dir = player.aim_direction_from_camera()
	dir = dir.normalized()
	var hit := _cast(from, from + dir * RANGE)
	var end: Vector3 = hit.position if hit else from + dir * RANGE
	_beam.show_beam(eyes[0], eyes[1], end, not hit.is_empty())
	_tick_timer -= delta
	if _tick_timer <= 0.0:
		_tick_timer += TICK
		if hit:
			_burn(hit.collider, dir)

func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | Hurtbox3D.LAYER)
	q.collide_with_areas = true
	var exclude: Array[RID] = [player.get_rid()]
	for child in player.get_children():
		if child is CollisionObject3D:
			exclude.append((child as CollisionObject3D).get_rid())
	q.exclude = exclude
	return player.get_world_3d().direct_space_state.intersect_ray(q)

func _burn(collider: Object, dir: Vector3) -> void:
	var health: Health = null
	if collider is Hurtbox3D:
		health = (collider as Hurtbox3D).health
	elif collider is Node and (collider as Node).has_node("Health"):
		health = (collider as Node).get_node("Health") as Health
	if health == null:
		return
	var push := Vector3(dir.x, 0.0, dir.z).normalized() * KNOCKBACK + Vector3(0, 0.15, 0)
	health.take_damage(HitInfo.make(DPS * TICK, player, push, HitInfo.Kind.ENERGY))

func update_facing(delta: float) -> bool:
	var aim := player.aim_direction_from_camera()
	player.face_yaw(atan2(aim.x, aim.z), player.strafe_rotation_speed, delta)
	return true

func move_speed_scale() -> float:
	return 0.5

func allows_sprint() -> bool:
	return false
