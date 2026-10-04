extends Node
class_name Health
## Hit points, invulnerability frames and death. Keeps score only: the body that
## owns this node reacts to the signals (knockback, flash, ragdoll, respawn).

signal damaged(hit: HitInfo)
signal healed(amount: float)
signal died(hit: HitInfo)
signal revived()
signal health_changed(current: float, max_val: float)

@export var max_health: float = 100.0
@export var invuln_time: float = 0.08
@export var can_die: bool = true
@export var auto_regen: bool = false
@export var regen_per_second: float = 5.0

var current: float = 100.0
var is_dead: bool = false
## The most recent hit taken (the killing blow once dead).
var last_hit: HitInfo = null
var last_knockback: Vector3:
	get:
		return last_hit.knockback if last_hit else Vector3.ZERO

var _invuln_timer: float = 0.0

func _ready() -> void:
	current = max_health
	add_to_group("health")

func _physics_process(delta: float) -> void:
	if _invuln_timer > 0.0:
		_invuln_timer -= delta
	if auto_regen and not is_dead and current < max_health:
		current = minf(max_health, current + regen_per_second * delta)
		health_changed.emit(current, max_health)

func can_take_damage() -> bool:
	return not is_dead and _invuln_timer <= 0.0

func take_damage(hit: HitInfo) -> bool:
	if not can_take_damage():
		return false
	current = maxf(current - hit.damage, 0.0)
	_invuln_timer = invuln_time
	last_hit = hit
	health_changed.emit(current, max_health)
	damaged.emit(hit)
	var body := get_parent() as Node3D
	if body:
		HitEffects.on_damaged(body, hit)
	if current <= 0.0 and can_die and not is_dead:
		is_dead = true
		died.emit(hit)
	return true

func heal(amount: float) -> void:
	if is_dead:
		return
	current = minf(max_health, current + amount)
	healed.emit(amount)
	health_changed.emit(current, max_health)

## Back to full health (called by the body when it respawns).
func revive(invulnerable_for: float = 0.0) -> void:
	current = max_health
	is_dead = false
	last_hit = null
	_invuln_timer = invulnerable_for
	revived.emit()
	health_changed.emit(current, max_health)

func set_invulnerable(seconds: float) -> void:
	_invuln_timer = maxf(_invuln_timer, seconds)
