extends RefCounted
class_name PlayerState
## One thing the fighter can be doing. Exactly one state is active at a time.
##
## A state answers "what is allowed right now?" through the queries below, so
## no action has to check every other action's flags. Transitions go through
## Player.change_state(); a target state can refuse via can_enter().

var player: Player
var name: StringName

func _init(p_player: Player, p_name: StringName) -> void:
	player = p_player
	name = p_name

## Can this state start right now? (checked by Player.try_change_state)
func can_enter(_args: Dictionary) -> bool:
	return true

func enter(_args: Dictionary) -> void:
	pass

## Called when leaving for any reason (finished, interrupted, died...). Clean up here.
func exit() -> void:
	pass

## React to this frame's input: start actions, queue combos, cancel...
func handle_intent(_intent: PlayerInput.Intent) -> void:
	pass

## Per-frame logic that runs before movement.
func physics_update(_delta: float) -> void:
	pass

# --- Movement hooks -----------------------------------------------------------

## True when the state moves the body itself (call move()) instead of locomotion.
func overrides_movement() -> bool:
	return false

func move(_delta: float) -> void:
	pass

## Return true after setting velocity.x/z yourself (else normal acceleration runs).
func set_horizontal_velocity(_delta: float, _target: Vector2) -> bool:
	return false

## Adjust velocity after locomotion (lunges, damping).
func after_velocity(_delta: float) -> void:
	pass

## Return true after rotating the mesh yourself (else the default facing runs).
func update_facing(_delta: float) -> bool:
	return false

func move_speed_scale() -> float:
	return 1.0

func allows_sprint() -> bool:
	return true

func allows_jump() -> bool:
	return true

func can_aim() -> bool:
	return true

## Jump/landing animations only play when nothing else owns the body's animation.
func allows_air_anims() -> bool:
	return false

func suppresses_footsteps() -> bool:
	return false

# --- Events ---------------------------------------------------------------------

func on_damaged(_hit: HitInfo) -> void:
	pass

func on_hit_landed(_target: Node3D, _hit: HitInfo) -> void:
	pass
