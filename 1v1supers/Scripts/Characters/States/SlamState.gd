extends PlayerState
class_name SlamState
## Cape combo: attack while flying. A short hang, then a dive straight down; the
## landing sends a shockwave that hurts, throws back and knocks off balance
## everyone near it (more the closer they are). A short recovery follows, open
## to a counter.

const MIN_HEIGHT := 1.2 # metres above the ground to start a slam
const WINDUP := 0.14 # hang in the air before the dive
const DIVE_SPEED := 26.0
const KEEP_HORIZONTAL := 0.35 # of the flight's sideways speed carried into the dive
const RADIUS := 4.0
const DAMAGE_MAX := 26.0 # at the centre
const DAMAGE_MIN := 8.0 # at the edge
const KNOCKBACK := 16.0
const LIFT := 4.5
const RECOVERY := 0.4
const STAGGER := Vector2(0.3, 0.7) # seconds off balance, at the edge .. centre

var _timer: float = 0.0
var _landed: bool = false
## Bodies the last shockwave hit (for tests and the AI).
var last_hits: Array[Node3D] = []

func can_enter(_args: Dictionary) -> bool:
	return not player.is_on_floor() and not player.is_dead() and player.height_above_ground() >= MIN_HEIGHT

func enter(_args: Dictionary) -> void:
	_timer = 0.0
	_landed = false
	last_hits.clear()
	var v := player.velocity
	player.velocity = Vector3(v.x * KEEP_HORIZONTAL, 2.0, v.z * KEEP_HORIZONTAL)
	player.squash_mesh(Vector3(0.85, 1.15, 0.85), 0.05, 0.12)

func exit() -> void:
	player.ease_mesh_upright()

func overrides_movement() -> bool:
	return true

func move(delta: float) -> void:
	_timer += delta
	var v := player.velocity
	if _landed:
		v.x = player.smooth(v.x, 0.0, 14.0, delta)
		v.z = player.smooth(v.z, 0.0, 14.0, delta)
		v.y -= player.gravity * delta
		player.velocity = v
		player.move_and_slide()
		if _timer >= RECOVERY:
			player.change_state(&"free")
		return
	v.y = player.smooth(v.y, 0.0, 20.0, delta) if _timer < WINDUP else -DIVE_SPEED
	player.velocity = v
	player.move_and_slide()
	player.mesh.rotation.x = player.smooth(player.mesh.rotation.x, deg_to_rad(18.0), 12.0, delta) # lean into the dive
	if player.is_on_floor():
		_land()
	else:
		player.note_airborne(player.velocity.y)

func _land() -> void:
	_landed = true
	_timer = 0.0
	player.footsteps.sync_floor(true)
	player.note_landed_from_flight()
	player.squash_mesh(Vector3(1.35, 0.6, 1.35), 0.0, 0.3)
	player.camera_shake(0.9)
	HitEffects.shockwave(player, player.global_position, RADIUS)
	var centre := player.global_position
	for n in player.get_tree().get_nodes_in_group("fighter"):
		var body := n as Node3D
		if body == null or body == player:
			continue
		var to := body.global_position - centre
		var dist := Vector2(to.x, to.z).length()
		if dist > RADIUS or absf(to.y) > 2.5:
			continue
		var health := body.get_node_or_null("Health") as Health
		if health == null:
			continue
		var k := 1.0 - dist / RADIUS
		var out := Vector3(to.x, 0.0, to.z).normalized() if dist > 0.05 else player.mesh.global_basis.z
		var hit := HitInfo.make(lerpf(DAMAGE_MIN, DAMAGE_MAX, k), player,
			out * KNOCKBACK * (0.4 + 0.6 * k) + Vector3.UP * LIFT * (0.4 + 0.6 * k), HitInfo.Kind.KICK, 0.0, 0.4)
		hit.label = "SLAM!"
		hit.stagger = lerpf(STAGGER.x, STAGGER.y, k)
		if health.take_damage(hit):
			last_hits.append(body)

func allows_jump() -> bool:
	return false

func allows_sprint() -> bool:
	return false

func can_aim() -> bool:
	return false

func suppresses_footsteps() -> bool:
	return true
