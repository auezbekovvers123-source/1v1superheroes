extends PlayerState
class_name TurnState
## Turn-in-place when the camera swings far enough round an idle character.
## The clip turns the skeleton; during the clip's fade-out the mesh rotates by the
## same amount, so the visual heading stays continuous. Moving, attacking,
## jumping or dashing cancels the turn.

const BLEND_IN: float = 0.22
const BLEND_OUT: float = 0.24

var _tween: Tween = null
var _finished: bool = false

func enter(args: Dictionary) -> void:
	var anim: String = args["anim"]
	var dir: int = args["dir"]
	_finished = false
	var anim_len: float = player.animator.length(anim) / maxf(player.turn_anim_speed, 0.1)
	player.turn_cooldown_timer = anim_len + player.turn_cooldown + BLEND_OUT
	var step: float = player.turn_step(anim, dir)
	player.animator.play_action(anim, player.turn_anim_speed, BLEND_IN, BLEND_OUT, PlayerAnimator.Mask.FULL)
	# The OneShot fade-out is a crossfade that starts BLEND_OUT before the clip ends,
	# so the mesh rotation runs in exactly that window; linear matches the linear fade.
	_tween = player.create_tween()
	_tween.tween_interval(maxf(anim_len - BLEND_OUT, 0.0))
	_tween.tween_property(player.mesh, "rotation:y", player.mesh.rotation.y + step, BLEND_OUT)
	_tween.tween_callback(_on_turn_done)

func _on_turn_done() -> void:
	if player.state == self:
		_finished = true
		player.change_state(&"free")

func exit() -> void:
	if _finished:
		return
	# Interrupted: carry the skeleton's partial turn over to the mesh before
	# cutting the clip, or the model would pop back toward the old heading.
	if _tween and _tween.is_valid():
		_tween.kill()
	player.bake_turn_into_mesh()
	player.animator.stop_action(true)
	player.turn_cooldown_timer = player.turn_cooldown * 0.5

func handle_intent(i: PlayerInput.Intent) -> void:
	if i.has_move() or i.attack_pressed or i.jump_pressed or i.dash_pressed:
		player.change_state(&"free")
		player.state.handle_intent(i) # let the press that cancelled the turn act right away

func update_facing(delta: float) -> bool:
	player.clear_upper_twist(delta)
	return true # the tween owns the rotation
