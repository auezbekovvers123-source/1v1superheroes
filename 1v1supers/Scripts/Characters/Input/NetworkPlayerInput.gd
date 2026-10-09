extends PlayerInput
class_name NetworkPlayerInput
## Drives the copy of a fighter that someone controls on another machine.
##
## The owner sends one state packet per physics tick (NetCodec). Packets wait in
## a small jitter buffer and are replayed one per tick, so the copy runs exactly
## the code the owner ran, a few ticks behind. A lost packet's tick is replayed
## with the buttons still held (its presses arrive with the next packet's
## counters), so the copy keeps time with the owner. NetSync then nudges the
## copy toward where the owner really ended up.

const MIN_DELAY := 3 # ticks of packets kept in hand before replaying (grows with jitter)
const MAX_DELAY := 10
const CALM_TICKS := 300 # a run this long without running dry shrinks the delay by one tick
const TRIM_AFTER := 60 # ticks the buffer may stay over-full before one packet is dropped to cut lag
const MAX_GAP_FILL := 10 # longer holes (a freeze) are jumped over instead of filled

## The packet replayed this tick (empty before the first one).
var packet: Array = []
## Owner tick being replayed (-1 before the first). Runs on through lost packets.
var tick: int = -1
## Newest owner tick received.
var latest_tick: int = -1
## True when `packet` arrived for exactly this tick (not held over a hole or a dry buffer).
var fresh := false
## Ticks in a row without a fresh packet.
var starved_ticks: int = 0
## Current replay delay in ticks: grows each time the buffer runs dry.
var target_delay: int = MIN_DELAY
## Totals for the F1 panel: lost packets replayed from held buttons, times the buffer ran dry.
var holes_filled: int = 0
var ran_dry: int = 0

var _queue: Array = []
var _started := false
var _calm := 0
var _overfull_ticks := 0
var _seen := PackedByteArray() # last press counters replayed
var _was_jump := false

func _init() -> void:
	_seen.resize(NetCodec.PRESS_COUNT)

func is_remote() -> bool:
	return true

## Called by Net when a packet for this fighter arrives.
func push(p: Array) -> void:
	var t: int = p[NetCodec.TICK]
	if t <= latest_tick:
		return # duplicate or late
	if latest_tick < 0:
		# First packet: start counting presses from here, not from zero
		for k in NetCodec.PRESS_COUNT:
			_seen[k] = NetCodec.counter(p[NetCodec.PRESSES], k)
	latest_tick = t
	_queue.append(p)

func buffered() -> int:
	return _queue.size()

func _read(i: Intent) -> void:
	fresh = false
	if not _started and _queue.size() >= target_delay:
		_started = true
	if _started and not _queue.is_empty():
		_trim()
		var next_tick: int = _queue[0][NetCodec.TICK]
		if tick >= 0 and next_tick > tick + 1 and next_tick - tick <= MAX_GAP_FILL:
			tick += 1 # a lost packet: replay its tick with the buttons still held, keep time with the owner
			holes_filled += 1
		else:
			packet = _queue.pop_front()
			tick = next_tick
			fresh = true
		_calm += 1
		if _calm >= CALM_TICKS:
			_calm = 0
			target_delay = maxi(target_delay - 1, MIN_DELAY)
	elif _started:
		# Ran dry: keep moving on the last buttons and rebuild a bigger cushion
		_started = false
		_calm = 0
		ran_dry += 1
		target_delay = mini(target_delay + 1, MAX_DELAY)
	starved_ticks = 0 if fresh else starved_ticks + 1
	if not packet.is_empty():
		_fill(i, packet)

func _trim() -> void:
	while _queue.size() > MAX_DELAY + 4:
		_queue.pop_front()
	_overfull_ticks = _overfull_ticks + 1 if _queue.size() > target_delay + 3 else 0
	if _overfull_ticks >= TRIM_AFTER:
		_overfull_ticks = 0
		_queue.pop_front()

## Rebuilds the owner's intent. Re-reading the same packet (starved) repeats the
## held buttons but no presses.
func _fill(i: Intent, p: Array) -> void:
	i.move = p[NetCodec.MOVE]
	var held: int = p[NetCodec.HELD]
	i.run = (held & NetCodec.HELD_RUN) != 0
	i.jump_held = (held & NetCodec.HELD_JUMP) != 0
	i.aim_held = (held & NetCodec.HELD_AIM) != 0
	i.throw_held = (held & NetCodec.HELD_THROW) != 0
	i.fly_down_held = (held & NetCodec.HELD_FLY_DOWN) != 0
	i.block_held = (held & NetCodec.HELD_BLOCK) != 0
	i.jump_released = _was_jump and not i.jump_held
	_was_jump = i.jump_held
	var counters: int = p[NetCodec.PRESSES]
	var pressed: Array[bool] = []
	for k in NetCodec.PRESS_COUNT:
		var c := NetCodec.counter(counters, k)
		pressed.append(c != _seen[k])
		_seen[k] = c
	i.jump_pressed = pressed[NetCodec.Press.JUMP]
	i.attack_pressed = pressed[NetCodec.Press.ATTACK]
	i.dash_pressed = pressed[NetCodec.Press.DASH]
	i.interact_pressed = pressed[NetCodec.Press.INTERACT]
	i.throw_pressed = pressed[NetCodec.Press.THROW]
	i.power_pressed = pressed[NetCodec.Press.POWER]
	i.has_view = true
	i.view_yaw = p[NetCodec.VIEW_YAW]
	i.aim_point = p[NetCodec.AIM_POINT]
