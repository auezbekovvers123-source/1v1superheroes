extends PlayerState
class_name GestureState
## Short hand gestures that block other actions while they play:
##   PICKUP       - reach for a world item; it lands in the hand part-way through
##   GRAB         - lift a ragdoll that was just grabbed by the neck
##   EMPTY_THROW  - throwing motion with nothing in the hand
## Upper-body gestures let the legs keep walking; a full-body one plants the feet.

enum Kind { PICKUP, GRAB, EMPTY_THROW }

var kind: Kind = Kind.PICKUP
var fullbody: bool = false
var _target: Node3D = null
var _timer: float = 0.0
var _total: float = 0.0
var _action_time: float = -1.0

func can_enter(args: Dictionary) -> bool:
	match args.get("kind", Kind.PICKUP):
		Kind.PICKUP:
			return args.get("target") != null and not player.hand.blocks(&"pickup")
		Kind.EMPTY_THROW:
			return not player.hand.blocks(&"throw_empty")
	return true

func enter(args: Dictionary) -> void:
	kind = args.get("kind", Kind.PICKUP)
	_target = args.get("target")
	_timer = 0.0
	_action_time = -1.0
	fullbody = false
	var anim := ""
	var speed := 1.0
	match kind:
		Kind.PICKUP:
			anim = player.animator.find([PlayerAnimator.PICKUP_ANIM], "pick")
			speed = 1.25
			player.face_instant(_target.global_position - player.global_position)
		Kind.GRAB:
			anim = player.animator.find([PlayerAnimator.PICKUP_ANIM], "pick")
			speed = 1.35
			var body := player.grabber.get_grabbed_body()
			if body:
				player.face_instant(body.global_position - player.global_position)
		Kind.EMPTY_THROW:
			anim = player.throw_release_anim()
			speed = player.hand.throw_release_anim_speed
			fullbody = not player.is_moving(0.18)
	var clip_len: float = player.animator.length(anim) / speed
	_total = clip_len + 0.14
	if kind == Kind.PICKUP:
		_action_time = clampf(clip_len * 0.45, 0.15, 0.45) if anim != "" else 0.0
	if anim != "":
		player.animator.play_action(anim, speed, 0.08 if kind != Kind.PICKUP else 0.1, 0.16 if kind == Kind.EMPTY_THROW else 0.14,
			PlayerAnimator.Mask.FULL if fullbody else PlayerAnimator.Mask.UPPER)

func physics_update(delta: float) -> void:
	_timer += delta
	if _action_time >= 0.0 and _timer >= _action_time:
		_action_time = -1.0
		var got := false
		if not is_instance_valid(_target) or player.is_remote():
			pass # someone else got it first / a remote copy's owner reports what it picked up
		elif _target is ItemPickup:
			got = (_target as ItemPickup).try_interact(player)
		elif _target is ThrownItem:
			got = (_target as ThrownItem).try_interact(player)
		if got:
			player.picked_from_world.emit(_target)
	if _timer >= _total:
		player.change_state(&"free")

func handle_intent(i: PlayerInput.Intent) -> void:
	if i.interact_pressed and player.grabber.is_grabbing():
		player.grabber.release_grab()

func set_horizontal_velocity(delta: float, _target_xz: Vector2) -> bool:
	if not fullbody:
		return false
	player.velocity.x = player.smooth(player.velocity.x, 0.0, 14.0, delta)
	player.velocity.z = player.smooth(player.velocity.z, 0.0, 14.0, delta)
	return true

func update_facing(_delta: float) -> bool:
	return fullbody

func allows_jump() -> bool:
	return not fullbody

func can_aim() -> bool:
	return false

func suppresses_footsteps() -> bool:
	return fullbody
