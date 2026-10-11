extends PlayerState
class_name BlockState
## Holding block: guard up (Guard decides what a hit does), slow walk, facing
## the opponent. Releasing block, attacking or dodging ends it.

const POSE_ANIM := "punch_hook" # its first frames are a fists-up guard; the rig has no block clip
const POSE_TIME := 0.05 # hold the clip here
const FREEZE_SPEED := 0.0001

var _timer: float = 0.0
var _frozen := false

func can_enter(_args: Dictionary) -> bool:
	return player.is_on_floor() and player.stun_timer <= 0.0 and not player.hand.blocks(&"block") \
		and player.animator.is_ready()

func enter(_args: Dictionary) -> void:
	_timer = 0.0
	_frozen = false
	player.guard.raise()
	player.animator.play_action(POSE_ANIM, 1.0, 0.06, 0.12, PlayerAnimator.Mask.UPPER)

func exit() -> void:
	player.guard.lower()
	player.animator.stop_action()

func handle_intent(i: PlayerInput.Intent) -> void:
	if not i.block_held:
		player.change_state(&"free")
		return
	if i.attack_pressed:
		player.change_state(&"free")
		player.start_attack_or_use() # strike straight out of the guard
		return
	if i.dash_pressed:
		player.try_change_state(&"dash") # dodge out of the guard

func physics_update(delta: float) -> void:
	_timer += delta
	if not _frozen and _timer >= POSE_TIME:
		player.animator.set_action_speed(FREEZE_SPEED)
		_frozen = true
	if not player.is_on_floor():
		player.change_state(&"free")

func update_facing(delta: float) -> bool:
	player.clear_upper_twist(delta)
	player.snap_facing_to_target(player.camera_forward(), delta) # keep the guard towards the opponent
	return true

func move_speed_scale() -> float:
	return 0.45

func allows_sprint() -> bool:
	return false

func allows_jump() -> bool:
	return false

func can_aim() -> bool:
	return false
