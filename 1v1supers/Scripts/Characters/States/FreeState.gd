extends PlayerState
class_name FreeState
## No action running: walking, running, jumping, idling. Every action starts here.

func allows_air_anims() -> bool:
	return true

func handle_intent(i: PlayerInput.Intent) -> void:
	if i.attack_pressed:
		player.start_attack_or_use()
	if player.state != self:
		return
	if i.dash_pressed and player.try_change_state(&"dash"):
		return
	if i.interact_pressed:
		player.interact()
	if player.state != self:
		return
	if i.throw_pressed:
		player.start_throw()

func physics_update(_delta: float) -> void:
	player.check_turn_in_place()
