extends RefCounted
class_name HitInfo
## Everything about one hit, passed from the attacker to Health and the target.
## Replaces reading the attacker's internals (e.g. its current animation name).

enum Kind { PUNCH, KICK, THROWN, OTHER }

const CRITICAL_DAMAGE: float = 18.0

var damage: float = 0.0
var knockback: Vector3 = Vector3.ZERO
var hitstop: float = 0.0 # seconds the target is frozen before the knockback lands
var shake: float = 0.0 # camera trauma for the attacker's camera
var attacker: Node3D = null
var kind: Kind = Kind.OTHER
# Set by the target's Guard when the hit meets a raised guard
var blocked: bool = false ## caught on the guard: chip damage, little knockback
var parried: bool = false ## guard raised just in time: no damage, the attacker staggers
var guard_broken: bool = false ## guard out of stamina: full hit, the target staggers

static func make(p_damage: float, p_attacker: Node3D = null, p_knockback := Vector3.ZERO, p_kind := Kind.OTHER, p_hitstop := 0.0, p_shake := 0.0) -> HitInfo:
	var h := HitInfo.new()
	h.damage = p_damage
	h.attacker = p_attacker
	h.knockback = p_knockback
	h.kind = p_kind
	h.hitstop = p_hitstop
	h.shake = p_shake
	return h

func is_critical() -> bool:
	return damage >= CRITICAL_DAMAGE
