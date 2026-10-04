extends PlayerInput
class_name LocalPlayerInput
## Keyboard + mouse (or any device bound in the InputMap) for the local player.
## Attack, aim and dash only register while the mouse is captured, so clicks on
## a free cursor (ESC, inventory) never swing.

func is_local_human() -> bool:
	return true

func _read(i: Intent) -> void:
	i.move = Input.get_vector("move_left", "move_right", "move_forwards", "move_backwards")
	i.run = Input.is_action_pressed("run")
	i.jump_held = Input.is_action_pressed("jump")
	i.jump_pressed = Input.is_action_just_pressed("jump")
	i.jump_released = Input.is_action_just_released("jump")
	i.interact_pressed = Input.is_action_just_pressed("interact")
	i.throw_held = Input.is_action_pressed("throw")
	i.throw_pressed = Input.is_action_just_pressed("throw")
	i.power_pressed = Input.is_action_just_pressed("power")
	i.fly_down_held = Input.is_action_pressed("fly_down")
	i.debug_hitbox_pressed = Input.is_action_just_pressed("toggle_hitbox_debug")
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		i.attack_pressed = Input.is_action_just_pressed("punch")
		i.aim_held = Input.is_action_pressed("aim")
		i.dash_pressed = Input.is_action_just_pressed("dash")
