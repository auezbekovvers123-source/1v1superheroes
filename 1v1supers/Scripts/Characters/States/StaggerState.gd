extends PlayerState
class_name StaggerState
## Knocked off balance (parried, or guard broken): no actions until it wears off.

var _timer: float = 0.0

func enter(args: Dictionary) -> void:
	_timer = args.get("time", 0.5)
	player.combat.close_window()
	player.animator.stop_action(true)
	player.grabber.release_grab()
	player.stagger_effect()

func physics_update(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		player.change_state(&"free")

func set_horizontal_velocity(delta: float, _target: Vector2) -> bool:
	player.velocity.x = player.smooth(player.velocity.x, 0.0, 6.0, delta)
	player.velocity.z = player.smooth(player.velocity.z, 0.0, 6.0, delta)
	return true

func update_facing(_delta: float) -> bool:
	return true # reeling: no turning

func allows_sprint() -> bool:
	return false

func allows_jump() -> bool:
	return false

func can_aim() -> bool:
	return false
