extends RefCounted
class_name NetCodec
## What goes over the wire, in one place.
##
## A state packet is sent by a fighter's owner every physics tick (unreliable):
## the intent it simulated that tick plus where the fighter ended up. Presses
## travel as 8-bit counters instead of one-frame flags, so a lost or skipped
## packet never loses a punch.

# State packet layout (an Array)
const TICK := 0
const MOVE := 1 # Vector2
const HELD := 2 # bit field, HELD_* below
const PRESSES := 3 # one byte per PRESS_* counter, packed into an int
const VIEW_YAW := 4
const AIM_POINT := 5 # Vector3
const POS := 6
const VEL := 7
const MESH_YAW := 8
const STAMINA := 9
const SIZE := 10

const HELD_RUN := 1
const HELD_JUMP := 2
const HELD_AIM := 4
const HELD_THROW := 8
const HELD_FLY_DOWN := 16

enum Press { JUMP, ATTACK, DASH, INTERACT, THROW, POWER }
const PRESS_COUNT := 6

static func held_bits(i: PlayerInput.Intent) -> int:
	var b := 0
	if i.run: b |= HELD_RUN
	if i.jump_held: b |= HELD_JUMP
	if i.aim_held: b |= HELD_AIM
	if i.throw_held: b |= HELD_THROW
	if i.fly_down_held: b |= HELD_FLY_DOWN
	return b

## The presses of this intent, in Press order.
static func presses(i: PlayerInput.Intent) -> Array[bool]:
	return [i.jump_pressed, i.attack_pressed, i.dash_pressed, i.interact_pressed, i.throw_pressed, i.power_pressed]

static func pack_counters(c: PackedByteArray) -> int:
	var v := 0
	for k in PRESS_COUNT:
		v |= int(c[k]) << (8 * k)
	return v

static func counter(packed: int, k: int) -> int:
	return (packed >> (8 * k)) & 0xFF

# --- Hits -------------------------------------------------------------------------

## A hit as plain values. The attacker travels as its peer id (0 = none).
static func encode_hit(hit: HitInfo, attacker_peer: int) -> Array:
	return [hit.damage, hit.knockback, hit.hitstop, hit.shake, int(hit.kind), attacker_peer]

static func decode_hit(a: Array, attacker: Node3D) -> HitInfo:
	return HitInfo.make(float(a[0]), attacker, a[1] as Vector3, int(a[4]) as HitInfo.Kind, float(a[2]), float(a[3]))

static func hit_attacker_peer(a: Array) -> int:
	return int(a[5])

# --- Items --------------------------------------------------------------------------

## Items travel as their resource path ("" = none).
static func item_path(item: ItemData) -> String:
	return item.resource_path if item else ""

static func load_item(path: String) -> ItemData:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as ItemData

## Hand item + worn items: [hand_path, {slot: path}].
static func encode_loadout(p: Player) -> Array:
	var worn := {}
	var items := p.equipment.list_items()
	for slot in items:
		worn[slot] = item_path(items[slot])
	return [item_path(p.held_item), worn]

## Packet sanity check: drops anything that is not a well-formed state packet.
static func is_valid_packet(p: Array) -> bool:
	return p.size() == SIZE and typeof(p[TICK]) == TYPE_INT and typeof(p[MOVE]) == TYPE_VECTOR2 \
		and typeof(p[POS]) == TYPE_VECTOR3 and typeof(p[VEL]) == TYPE_VECTOR3 and typeof(p[AIM_POINT]) == TYPE_VECTOR3
