extends PlayerInput
class_name ScriptedPlayerInput
## Input driven from code: tests, AI opponents, network replay.
##   set_move(Vector2(0, -1))   # walk forward
##   hold(&"run", true)         # held buttons: run, jump, aim, throw, fly_down, block
##   tap(&"attack")             # one-frame presses: attack, dash, interact, power, jump, throw, debug_hitbox

const HELD := [&"run", &"jump", &"aim", &"throw", &"fly_down", &"block"]

var _move := Vector2.ZERO
var _held := {}
var _was_held := {}
var _taps := {}

func set_move(v: Vector2) -> void:
	_move = v.limit_length(1.0)

func hold(action: StringName, on: bool) -> void:
	assert(action in HELD, "not a held action: %s" % action)
	_held[action] = on

func tap(action: StringName) -> void:
	_taps[action] = true

## Releases everything.
func reset() -> void:
	_move = Vector2.ZERO
	_held.clear()
	_taps.clear()

func _is_down(action: StringName) -> bool:
	return _held.get(action, false) or _taps.get(action, false)

func _read(i: Intent) -> void:
	i.move = _move
	i.run = _is_down(&"run")
	i.aim_held = _is_down(&"aim")
	i.fly_down_held = _is_down(&"fly_down")
	i.block_held = _is_down(&"block")
	i.jump_held = _is_down(&"jump")
	i.jump_pressed = i.jump_held and not _was_held.get(&"jump", false)
	i.jump_released = not i.jump_held and _was_held.get(&"jump", false)
	i.throw_held = _is_down(&"throw")
	i.throw_pressed = i.throw_held and not _was_held.get(&"throw", false)
	i.attack_pressed = _taps.get(&"attack", false)
	i.dash_pressed = _taps.get(&"dash", false)
	i.interact_pressed = _taps.get(&"interact", false)
	i.power_pressed = _taps.get(&"power", false)
	i.debug_hitbox_pressed = _taps.get(&"debug_hitbox", false)
	_was_held[&"jump"] = i.jump_held
	_was_held[&"throw"] = i.throw_held
	_taps.clear()
