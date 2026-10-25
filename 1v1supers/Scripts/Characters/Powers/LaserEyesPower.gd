extends Power
class_name LaserEyesPower
## Laser visor: hold right mouse to aim, hold left mouse to fire a heat beam
## from the eyes (LaserState). It burns stamina while it fires. Combo with the
## cape: fire while flying, hovering in place.

func handle_intent(i: PlayerInput.Intent) -> void:
	if i.aim_held and i.attack_held and (player.state.name == &"free" or player.state.name == &"fly"):
		player.try_change_state(&"laser", {"airborne": player.state.name == &"fly"})

func hint() -> String:
	return "Laser eyes: hold right mouse, then left mouse  (works while flying too)"
