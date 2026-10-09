extends AudioStreamPlayer3D
class_name Footsteps
## Procedural footsteps: accumulates horizontal distance and plays a step every
## stride. Strides shorten with speed, so sprinting has a faster cadence.

enum Gait { WALK, RUN, DASH }

const STREAMS: Array[AudioStream] = [
	preload("res://Assets/Sounds/Footsteps/JDSherbert - Footstep Foley SFX Pack - Footstep (Concrete - 1).mp3"),
	preload("res://Assets/Sounds/Footsteps/JDSherbert - Footstep Foley SFX Pack - Footstep (Concrete - 2).mp3"),
]

@export var stride_slow: float = 0.9 # m between steps below slow_speed_threshold * walk speed
@export var stride_walk: float = 1.3 # m between steps at walk speed (~1.6 steps/s, matches the Walk loop)
@export var stride_run: float = 1.7 # m between steps at run speed (~3 steps/s)
@export var stride_dash: float = 1.4 # m between steps during the dash burst
@export var slow_speed_threshold: float = 0.5
@export var min_speed: float = 0.6 # below this horizontal speed, no footsteps
@export var volume_walk_db: float = -13.0
@export var volume_run_db: float = -9.0
@export var volume_dash_db: float = -7.0
@export var volume_jitter_db: float = 1.5 # +/- random dB per step
@export var pitch_dash: float = 1.06
@export var pitch_jitter: float = 0.02 # keep tiny: pitch jitter on short transients sounds dull
@export var play_on_land: bool = true

var walk_speed: float = 2.1
var run_speed: float = 5.0
var dash_speed: float = 9.34

var _distance: float = 0.0
var _last_index: int = -1
var _land_played: bool = false
var _prev_on_floor: bool = true

func _init() -> void:
	max_distance = 32.0
	unit_size = 18.0
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	# Godot's default distance low-pass muffles steps even at camera distance: disable it
	attenuation_filter_db = 0.0
	attenuation_filter_cutoff_hz = 20500.0
	doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	emission_angle_enabled = false
	max_db = 3.0
	position = Vector3(0, 0.08, 0) # at the feet

## Call once per physics frame. suppressed = feet planted (attacks, throws, etc.).
func update_steps(delta: float, on_floor: bool, horiz_speed: float, gait: Gait, suppressed: bool) -> void:
	var just_landed: bool = on_floor and not _prev_on_floor
	_prev_on_floor = on_floor
	if not on_floor:
		_land_played = false
		_distance = 0.0
		return
	# Landing while moving: one heavier step
	if play_on_land and not _land_played and just_landed and horiz_speed > 1.0:
		_land_played = true
		_play_step(clampf(horiz_speed / run_speed, 0.4, 1.5), true, gait)
		_distance = 0.0
		return
	_land_played = true
	if suppressed or horiz_speed < min_speed:
		_distance = 0.0
		return
	_distance += horiz_speed * delta
	var stride: float
	var speed_norm: float
	match gait:
		Gait.DASH:
			stride = stride_dash
			speed_norm = clampf(horiz_speed / dash_speed, 0.0, 1.5)
		Gait.RUN:
			stride = stride_run
			speed_norm = clampf(horiz_speed / run_speed, 0.0, 1.5)
		_:
			# slow -> walk -> run ramp, monotonically shorter so cadence never thins out
			var slow_speed: float = walk_speed * slow_speed_threshold
			if horiz_speed <= slow_speed:
				stride = stride_slow
			elif horiz_speed <= walk_speed:
				var t1: float = (horiz_speed - slow_speed) / maxf(walk_speed - slow_speed, 0.01)
				stride = lerpf(maxf(stride_slow, stride_walk), minf(stride_slow, stride_walk), t1)
			else:
				var t2: float = clampf((horiz_speed - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0)
				stride = lerpf(maxf(stride_walk, stride_run), minf(stride_walk, stride_run), t2)
			speed_norm = clampf(horiz_speed / run_speed, 0.0, 1.0)
	if _distance >= stride:
		_distance = 0.0
		_play_step(speed_norm, false, gait)

## Keeps landing detection honest while another system moves the body (flight).
func sync_floor(on_floor: bool) -> void:
	_prev_on_floor = on_floor
	_distance = 0.0

func _play_step(speed_norm: float, is_landing: bool, gait: Gait) -> void:
	var idx: int = randi() % STREAMS.size()
	if STREAMS.size() > 1 and idx == _last_index:
		idx = (idx + 1) % STREAMS.size()
	_last_index = idx
	stream = STREAMS[idx]
	var base_pitch: float = pitch_dash if gait == Gait.DASH else 1.0
	if is_landing:
		base_pitch *= 0.94
	pitch_scale = clampf(base_pitch + randf_range(-pitch_jitter, pitch_jitter), 0.85, 1.25)
	var vol: float = lerpf(volume_walk_db, volume_run_db, clampf(speed_norm, 0.0, 1.0))
	if gait == Gait.DASH:
		vol = lerpf(vol, volume_dash_db, clampf((speed_norm - 0.8) / 0.4, 0.0, 1.0))
	if is_landing:
		vol += 2.0
	volume_db = vol + randf_range(-volume_jitter_db, volume_jitter_db)
	play() # no stop() first: that clicks
