extends Node
class_name PlayerInput
## Where a fighter's commands come from. The Player reads ONLY this node, never
## the global Input singleton, so two fighters never share a keyboard and a
## fighter can be driven by a keyboard, a gamepad, an AI, a test or the network
## just by swapping this child node.
##
## Subclasses override _read(intent). LocalPlayerInput reads the InputMap;
## ScriptedPlayerInput is driven from code.

## What the fighter wants to do this physics frame.
class Intent:
	## Movement stick: x = right (+) / left (-), y = backward (+) / forward (-),
	## same convention as Input.get_vector(left, right, forward, backward).
	var move := Vector2.ZERO
	var run := false
	var jump_held := false
	var jump_pressed := false
	var jump_released := false
	var attack_pressed := false
	var aim_held := false
	var dash_pressed := false
	var interact_pressed := false
	var throw_held := false
	var throw_pressed := false
	var power_pressed := false
	var fly_down_held := false
	var debug_hitbox_pressed := false

	func clear() -> void:
		move = Vector2.ZERO
		run = false
		jump_held = false
		jump_pressed = false
		jump_released = false
		attack_pressed = false
		aim_held = false
		dash_pressed = false
		interact_pressed = false
		throw_held = false
		throw_pressed = false
		power_pressed = false
		fly_down_held = false
		debug_hitbox_pressed = false

	func has_move() -> bool:
		return move.length() > 0.12

## When false every intent reads as idle (e.g. while the inventory owns the mouse).
var enabled: bool = true

var _intent := Intent.new()

## Called once at the start of the owner's physics frame.
func poll() -> Intent:
	_intent.clear()
	if enabled:
		_read(_intent)
	return _intent

## The intent read by the last poll().
func current() -> Intent:
	return _intent

## True when this source is a human on this machine (gets the camera and mouse).
func is_local_human() -> bool:
	return false

func _read(_i: Intent) -> void:
	pass
