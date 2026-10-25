extends RefCounted
class_name Power
## A superpower granted by a worn item: the item's ItemData.power_id names it
## (Powers.REGISTRY maps ids to these classes). Wearing the item adds the power,
## taking it off removes it. A power hooks into the fighter only through the
## methods below, so a new item + power never touches the rest of the code.

var player: Player
var id: String

func _init(p_player: Player, p_id: String) -> void:
	player = p_player
	id = p_id

## Put on.
func added() -> void:
	pass

## Taken off (also when the fighter leaves the scene).
func removed() -> void:
	pass

## This frame's input, before the current state sees it. Start the power's
## action here (e.g. change_state into the power's own state).
func handle_intent(_i: PlayerInput.Intent) -> void:
	pass

func physics_update(_delta: float) -> void:
	pass

## Sprint speed while this power is worn (0 = no change).
func run_speed() -> float:
	return 0.0

## Multiplier on the dash burst.
func dash_scale() -> float:
	return 1.0

## A punch or kick is about to start hitting: raise its damage, hitstop, shake
## or label, and return a multiplier on its knockback (1 = unchanged).
func boost_strike(_hit: HitInfo) -> float:
	return 1.0

## One line for the HUD: what it is and how to use it.
func hint() -> String:
	return ""
