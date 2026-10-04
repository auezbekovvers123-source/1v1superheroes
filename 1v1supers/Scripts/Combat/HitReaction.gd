extends RefCounted
class_name HitReaction
## Knockback + hitstop for a CharacterBody3D. Called by the body that was hit
## (the body owns its velocity; Health only keeps score).

## Fraction of the hit velocity a body gets back when its hitstop freeze ends.
## Combat knockback values are tuned with this factor in mind.
const KNOCKBACK_AFTER_HITSTOP: float = 0.4

static func knock(body: CharacterBody3D, hit: HitInfo) -> void:
	body.velocity += hit.knockback

## Holds the body's velocity back for `duration`, then ADDS it back scaled down,
## so whatever happened during the freeze (gravity, landing, another hit) is kept.
static func hitstop(body: CharacterBody3D, duration: float) -> void:
	if duration <= 0.0:
		return
	var held: Vector3 = body.velocity
	body.velocity = Vector3.ZERO
	await body.get_tree().create_timer(duration, true, false, true).timeout
	if is_instance_valid(body):
		body.velocity += held * KNOCKBACK_AFTER_HITSTOP
