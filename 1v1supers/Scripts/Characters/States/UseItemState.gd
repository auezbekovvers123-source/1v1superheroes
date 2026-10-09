extends PlayerState
class_name UseItemState
## Using the held usable item (e.g. the energy cell heals). Upper-body only.

var _timer: float = 0.0
var _total: float = 0.0

func can_enter(_args: Dictionary) -> bool:
	return player.hand.is_holding_usable() and _anim() != ""

func _anim() -> String:
	var item := player.hand.held_item
	return player.animator.find([PlayerAnimator.USE_ANIM, item.use_anim if item else ""])

func enter(_args: Dictionary) -> void:
	var anim := _anim()
	_timer = 0.0
	_total = player.animator.length(anim) + 0.14
	player.animator.play_action(anim, 1.0, 0.08, 0.14, PlayerAnimator.Mask.UPPER)
	player.hand.apply_use_effect()

func physics_update(delta: float) -> void:
	_timer += delta
	if _timer >= _total:
		player.change_state(&"free")

func allows_jump() -> bool:
	return false
