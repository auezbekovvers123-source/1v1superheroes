extends Node
class_name Guard
## The fighter's defence while blocking. Health hands every incoming hit to
## filter() first (on the machine that owns the fighter), which decides:
##   parry        - guard raised within parry_window before the hit: no damage,
##                  the attacker staggers
##   block        - hit from the front: chip damage, little knockback, costs stamina
##   guard break  - not enough stamina to absorb it: full hit, the defender staggers
## Hits from behind (outside block_half_angle) ignore the guard.

@export var block_half_angle_deg: float = 100.0 # how far round the guard covers, from the facing
@export var chip_damage: float = 0.15 # share of the damage that still gets through a block
@export var knockback_scale: float = 0.35
@export var stamina_per_damage: float = 1.6 # stamina spent per point of damage blocked
@export var heavy_stamina_mult: float = 1.5 # kicks cost the guard more
@export var parry_window: float = 0.15 # seconds after raising the guard
@export var parry_lockout: float = 0.4 # the guard must have been down this long for a parry (no mashing)
@export var parry_stagger: float = 0.6 # attacker stagger after being parried
@export var break_stagger: float = 0.7 # defender stagger after a guard break

var player: Player

var _raised := false
var _raised_frame: int = -1000000
var _lowered_frame: int = -1000000
var _parry_armed := false

func setup(p_player: Player) -> void:
	player = p_player

func is_raised() -> bool:
	return _raised

func raise() -> void:
	if _raised:
		return
	_raised = true
	var now := Engine.get_physics_frames()
	_parry_armed = (now - _lowered_frame) >= _ticks(parry_lockout)
	_raised_frame = now

func lower() -> void:
	if not _raised:
		return
	_raised = false
	_lowered_frame = Engine.get_physics_frames()

## True while a hit would still be parried.
func in_parry_window() -> bool:
	return _raised and _parry_armed and (Engine.get_physics_frames() - _raised_frame) <= _ticks(parry_window)

## Called by Health before a hit is applied; edits the hit in place.
func filter(hit: HitInfo) -> void:
	if not _raised or not _covers(hit):
		return
	if in_parry_window():
		hit.parried = true
		hit.damage = 0.0
		hit.knockback = Vector3.ZERO
		hit.hitstop = 0.0
		return
	var cost := hit.damage * stamina_per_damage * (heavy_stamina_mult if hit.kind == HitInfo.Kind.KICK else 1.0)
	if not player.stamina.use(cost):
		hit.guard_broken = true # the full hit lands
		player.stamina.use(player.stamina.value)
		return
	hit.blocked = true
	hit.damage *= chip_damage
	hit.knockback *= knockback_scale
	hit.hitstop *= 0.5

## Is the hit coming from in front? Knockback points away from where it came
## from (punches and thrown items alike); fall back to the attacker's position.
func _covers(hit: HitInfo) -> bool:
	var from := -hit.knockback
	from.y = 0.0
	if from.length() < 0.05 and hit.attacker:
		from = hit.attacker.global_position - player.global_position
		from.y = 0.0
	if from.length() < 0.05:
		return true
	var facing: Vector3 = player.mesh.global_basis.z
	facing.y = 0.0
	return rad_to_deg(facing.normalized().angle_to(from.normalized())) <= block_half_angle_deg

func _ticks(seconds: float) -> int:
	return int(round(seconds * Engine.physics_ticks_per_second))
