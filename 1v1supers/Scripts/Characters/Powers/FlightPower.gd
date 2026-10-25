extends Power
class_name FlightPower
## Cape: fly. R takes off (from the ground too) or lands; jumping again while
## already in the air also starts flying.

const DOUBLE_JUMP_AFTER := 0.1 # seconds airborne before a second press counts (not a key bounce)

func handle_intent(i: PlayerInput.Intent) -> void:
	if i.power_pressed:
		if player.is_flying():
			player.change_state(&"free")
		elif not player.is_dead():
			player.try_change_state(&"fly", {"takeoff": player.is_on_floor()})
	elif i.jump_pressed and not player.is_flying() and not player.is_on_floor() \
			and player.air_time > DOUBLE_JUMP_AFTER and player.state.name == &"free":
		player.try_change_state(&"fly")

func hint() -> String:
	return "Flight: R, or jump twice  (Space up, C down, Shift fast, punch = GROUND SLAM)"
