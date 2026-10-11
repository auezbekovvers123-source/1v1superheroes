extends PlayerState
class_name ThrowChargeState
## Holding the throw button with an item in hand: power rises from 1% to 100%
## over throw_max_charge_time, the camera and hand shake harder, and the windup
## pose holds on its last frame. Releasing throws the item.

const HOLD_MARGIN: float = 0.06 # freeze the windup this long before it ends
const FREEZE_SPEED: float = 0.0001 # near-zero playback = held pose (the OneShot never auto-fades)

var power: float = 0.01
var _charge_time: float = 0.0
var _phase: float = 0.0
var _windup_len: float = 0.0
var _frozen: bool = false
var _released: bool = false

func can_enter(_args: Dictionary) -> bool:
	return player.hand.is_holding()

func enter(_args: Dictionary) -> void:
	power = 0.01
	_charge_time = 0.0
	_phase = 0.0
	_frozen = false
	_released = false
	player.hand.begin_jitter()
	_windup_len = player.animator.length(PlayerAnimator.THROWSTART_ANIM)
	# fadeout ~0: the hold must engage before the OneShot's end-of-clip fade starts
	player.animator.play_action(PlayerAnimator.THROWSTART_ANIM, 1.0, 0.08, 0.001, player.mask_for_movement(0.18))

func exit() -> void:
	if _released:
		return
	player.hand.end_jitter(true)
	player.animator.stop_action()

func handle_intent(i: PlayerInput.Intent) -> void:
	if not i.throw_held:
		_release()

func _release() -> void:
	_released = true
	player.hand.end_jitter(false) # the item spawns from the hand: put it back first
	if player.hand.throw_item(power):
		player.play_throw_release()
	player.change_state(&"free")

func physics_update(delta: float) -> void:
	if not player.hand.is_holding():
		player.change_state(&"free")
		return
	_charge_time += delta
	power = player.hand.charge_power(_charge_time)
	_phase += delta * lerpf(14.0, 28.0, power)
	if not _frozen and _windup_len > 0.0 and _charge_time >= _windup_len - maxf(HOLD_MARGIN, _windup_len * 0.05):
		player.animator.set_action_speed(FREEZE_SPEED)
		_frozen = true
	# Walking while charging keeps the legs free
	player.animator.set_action_mask(player.mask_for_movement(0.18))
	_shake(delta)
	player.hand.apply_jitter(power, _phase)

## Camera shake ramps with power and never decays below the current level while charging.
func _shake(delta: float) -> void:
	var cam := player.camera_rig
	var intensity: float = lerpf(player.hand.throw_shake_min, player.hand.throw_shake_max, power)
	var target: float = clampf(intensity * 0.95, 0.0, 1.0)
	var trauma: float = lerpf(cam.trauma, target, player.exp_weight(14.0, delta))
	cam.trauma = clampf(maxf(trauma, target * 0.85), 0.0, 1.0)
	if fmod(_phase, 0.28) < delta * 2.0:
		cam.kick_fov(intensity * 0.12)
	if fmod(_phase, 0.24) < delta * 2.0:
		cam.kick_fov(intensity * 0.18)

func move_speed_scale() -> float:
	return 0.72 # steadier aim

func allows_jump() -> bool:
	return false

func suppresses_footsteps() -> bool:
	return true
