extends PlayerState
class_name DeadState
## Knocked out. RagdollController flops the body; after respawn_delay (and once
## nobody is carrying the ragdoll) the player respawns.

var _timer: float = 0.0

func enter(_args: Dictionary) -> void:
	_timer = 0.0
	player.grabber.release_grab()
	player.combat.close_window()

func physics_update(delta: float) -> void:
	_timer += delta
	if _timer >= player.respawn_delay and not player.ragdoll.is_held():
		player.respawn()

func overrides_movement() -> bool:
	return true

func move(delta: float) -> void:
	if player.ragdoll.is_ragdolled():
		player.velocity = Vector3.ZERO # the physical bones move the body now
		return
	player.velocity.x = player.smooth(player.velocity.x, 0.0, 6.0, delta)
	player.velocity.z = player.smooth(player.velocity.z, 0.0, 6.0, delta)
	player.velocity.y -= player.gravity * delta
	player.move_and_slide()

func can_aim() -> bool:
	return false

func suppresses_footsteps() -> bool:
	return true
