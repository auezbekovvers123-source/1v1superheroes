@tool
class_name CityGenerator
extends Node3D

## Runtime + Editor city generator – deterministic, no overlaps, correct heights.
## Non-destructive v2: same public API + additive features.
## Fixes vs v1:
## - Buildings: true single-spacing gap (was double), perimeter-biased fill that
##   actually fills blocks (was capped, leaving empty plots), mesh-aware scale
##   that shrinks oversized meshes instead of clamping up (was overlap/weird).
## - Grounding: transform-aware AABB + per-model min_y compensation, so
##   foundations sit ON tile tops (cars with wheels below origin no longer sink,
##   buildings no longer float). Optional building_sink seats slabs.
## - Roads: proper intersection pieces (junction / tsplit / corner / straight)
##   instead of straight-only (was broken crossings). Corner orientation matches
##   the original outer-ring mapping, so existing cities keep their look.
## - Decor logic: vehicles (car*) go ON roads aligned to traffic with lane
##   offset; roadside (streetlight/trafficlight*) goes on sidewalk tiles next
##   to roads facing the street; small props go on free plots. No more cars
##   parked on grass. Old decor_density behaviour preserved for props.

# ============================================================================
# CONFIGURATION (all original exports kept – do not rename/remove)
# ============================================================================

@export_group("Grid")
@export var grid_size_tiles: Vector2i = Vector2i(28, 28)
@export var tile_size: Vector3 = Vector3(2.0, 0, 2.0)

@export_group("Models")
@export var base_folder_path: String = "res://bases/"
@export var building_models_folder: String = "res://buildings/"
@export var decor_models_folder: String = "res://decors/"
@export var ground_tile_name: String = "base"
@export var road_straight_name: String = "road_straight"
@export var road_corner_name: String = "road_corner"
# Additive: intersection pieces (optional – falls back to straight if missing).
@export var road_junction_name: String = "road_junction"
@export var road_tsplit_name: String = "road_tsplit"

@export_group("Lanes")
@export var lanes_x: int = 3
@export var lanes_y: int = 2
@export var lane_width: int = 1

@export_group("Buildings")
@export var building_min_size_tiles: Vector2i = Vector2i(1, 1)
@export var building_max_size_tiles: Vector2i = Vector2i(2, 2)
## Gap between buildings. 1 = 2m corridor, enough for player to pass.
@export var building_spacing_tiles: int = 1
@export var building_road_gap_tiles: int = 0
@export_range(0.2, 3.0, 0.1) var building_density_multiplier: float = 1.4
@export var orient_buildings_to_road: bool = true
@export_range(0, 360, 15) var building_front_offset_degrees: float = 180.0
## Seats foundation slab into the tile to hide the plinth step.
## Building meshes have a ~0.10m foundation slab at y 0..0.1; sink >=
## height_offset + 0.1 buries it flush so no step is visible.
## 0.12 = 12cm (flush + 1cm margin). Set 0 to restore exact v1 heights.
@export_range(0.0, 0.3, 0.005) var building_sink: float = 0.12

@export_group("Decor")
@export_range(0.0, 1.0, 0.05) var decor_density: float = 0.35
@export var decor_spacing_tiles: int = 1
@export var decor_anchor_points_enabled: Array = ["center", "north", "south", "east", "west"]
## Extra gap from buildings for decor (prevents decor inside building walls)
@export var decor_min_dist_from_building: int = 0
# Additive categorisation (substring match, case-insensitive).
@export var vehicle_keywords: Array = ["car"]
@export var roadside_keywords: Array = ["streetlight", "trafficlight"]

@export_group("Vehicles")
## Cars park/drive ON road tiles, aligned to street direction.
@export var place_vehicles_on_roads: bool = true
@export_range(0.0, 1.0, 0.01) var vehicle_density: float = 0.22
## Lateral lane offset in meters (right-hand traffic). 0 = center line.
@export_range(0.0, 0.9, 0.05) var vehicle_lane_offset: float = 0.45
## Keep intersections clear so crossings don't clog.
@export var keep_intersections_clear: bool = true

@export_group("Roadside")
## Street lamps go on ground tiles touching a road, facing it.
@export var place_roadside_on_sidewalk: bool = true
@export_range(0.0, 1.0, 0.05) var roadside_density: float = 0.55
## Traffic lights only make sense where streets cross. When true, models
## matching trafficlight_keywords are placed only on ground tiles next to
## junction/tsplit intersections instead of random sidewalks.
@export var place_trafficlights_at_intersections_only: bool = true
@export var trafficlight_keywords: Array = ["trafficlight"]
## Fraction of intersections that get a traffic light (1.0 = every crossing).
@export_range(0.0, 1.0, 0.05) var trafficlight_density: float = 1.0
## Max traffic lights per intersection (candidates are ground tiles around it).
@export_range(1, 4, 1) var trafficlights_per_intersection: int = 2

@export_group("Generation")
@export var use_corner_pieces: bool = true
@export var use_junction_pieces: bool = true
@export var use_tsplit_pieces: bool = true
@export var random_seed: int = 0
@export var generate_buildings: bool = true
@export var generate_decor: bool = true
@export var create_organization_nodes: bool = true
@export var auto_generate_on_ready: bool = true
@export var generate_collisions: bool = true
@export var collision_for_decor: bool = false

@export_group("Placement")
@export var city_offset: Vector3 = Vector3.ZERO
## Small lift above tile top to avoid z-fighting; 0.01 = 1cm (was 0.05 -> floated)
@export var height_offset: float = 0.01
var base_tile_height: float = 0.0
## If true, buildings/decor sit exactly on tile top (base_tile_height + height_offset)
## If false, they sit at city_offset.y + height_offset (useful if tiles are flat)
@export var align_to_tile_top: bool = true
# Additive fine-tuning if a custom road kit needs a twist (degrees).
@export var road_straight_rotation_offset: float = 0.0
@export var road_corner_rotation_offset: float = 0.0
@export var road_tsplit_rotation_offset: float = 0.0
@export var road_junction_rotation_offset: float = 0.0

# ============================================================================
# Internal structures (kept – fields only appended, never removed)
# ============================================================================

class Section:
	var id: int
	var bounds: Rect2i
	var available_area: int = 0
	var available_tiles: Array = []
	var occupied_rects: Array = []
	var max_buildings: int = 0

class BuildingInfo:
	var model_path: String
	var position: Vector3
	var rotation_y: float
	var scale: Vector3 = Vector3.ONE
	var size_tiles: Vector2i
	var rotated_size: Vector2i
	var grid_position: Vector2i
	var model_name: String
	var occupied_rect: Rect2
	var mesh_size: Vector3 = Vector3(2, 1, 2)

class DecorInfo:
	var model_path: String
	var position: Vector3
	var rotation_y: float
	var scale: Vector3 = Vector3.ONE
	var anchor_point: String
	var model_name: String
	var grid_position: Vector2i
	var occupied_rect: Rect2

var _generated_root: Node3D
# Global FOOTPRINT occupancy: Vector2i -> true (footprints only; spacing is
# enforced at query time so the gap equals building_spacing_tiles, not 2x).
var _global_occupied_tiles: Dictionary = {}
# Cache mesh sizes per model path to clamp scale
var _model_footprints: Dictionary = {}
# Cache lowest point (root-space min_y) per model for exact grounding.
var _model_min_y: Dictionary = {}

func _ready():
	if auto_generate_on_ready and not Engine.is_editor_hint():
		generate_city()

func _validate_property(property: Dictionary):
	if property.name == "building_max_size_tiles":
		# hint that max should be >= min
		pass

## Public API (signature unchanged)
func generate_city():
	clear_city()
	_global_occupied_tiles.clear()
	_model_footprints.clear()
	_model_min_y.clear()
	if building_max_size_tiles.x < building_min_size_tiles.x or building_max_size_tiles.y < building_min_size_tiles.y:
		push_warning("[CityGenerator] building_max_size_tiles < min – clamping")
		building_max_size_tiles.x = maxi(building_max_size_tiles.x, building_min_size_tiles.x)
		building_max_size_tiles.y = maxi(building_max_size_tiles.y, building_min_size_tiles.y)
	if random_seed == 0:
		randomize()
	else:
		seed(random_seed)

	var ground_tile_path = base_folder_path.path_join(ground_tile_name + ".glb")
	var road_straight_path = base_folder_path.path_join(road_straight_name + ".glb")
	var road_corner_path = base_folder_path.path_join(road_corner_name + ".glb")
	var road_junction_path = base_folder_path.path_join(road_junction_name + ".glb")
	var road_tsplit_path = base_folder_path.path_join(road_tsplit_name + ".glb")

	if not _validate_paths(ground_tile_path, road_straight_path, road_corner_path):
		return

	var loaded_models = _load_models(ground_tile_path, road_straight_path, road_corner_path, road_junction_path, road_tsplit_path)
	if loaded_models.is_empty():
		return

	_calculate_base_tile_height(loaded_models.ground)
	# Precompute footprints + min_y for scale clamping and exact grounding.
	for m in loaded_models.buildings:
		var aabb: AABB = _get_scene_aabb(m.scene)
		_model_footprints[m.path] = aabb.size
		_model_min_y[m.path] = aabb.position.y
	for m in loaded_models.decor:
		var aabb2: AABB = _get_scene_aabb(m.scene)
		_model_footprints[m.path] = aabb2.size
		_model_min_y[m.path] = aabb2.position.y

	var grid_data = _generate_base_grid()
	_add_lane_roads(grid_data)
	_add_boundary_outside_grid(grid_data)
	_classify_road_tiles(grid_data)
	_validate_and_fix_intersections(grid_data)
	var sections = _create_sections_from_grid(grid_data)

	var building_instances = []
	if generate_buildings and not loaded_models.buildings.is_empty():
		building_instances = _place_buildings_in_sections(sections, loaded_models.buildings, grid_data)
		_validate_buildings_on_grid(building_instances, grid_data)

	var decor_instances = []
	if generate_decor and not loaded_models.decor.is_empty():
		var split = _split_decor_models(loaded_models.decor)
		var vehicles: Array = []
		var roadside: Array = []
		var props: Array = []
		if place_vehicles_on_roads and not split.vehicles.is_empty():
			vehicles = _place_vehicles_on_roads(grid_data, split.vehicles)
		if place_roadside_on_sidewalk and (not split.roadside.is_empty() or not split.trafficlights.is_empty()):
			# Street lamps keep the old random-sidewalk behaviour. Traffic lights
			# get intersection placement unless explicitly set back to random.
			var lamp_models: Array = split.roadside
			if not place_trafficlights_at_intersections_only:
				lamp_models = lamp_models + split.trafficlights
			if not lamp_models.is_empty():
				roadside = _place_roadside_furniture(grid_data, lamp_models, building_instances)
			if place_trafficlights_at_intersections_only and not split.trafficlights.is_empty():
				var signals = _place_trafficlights_at_intersections(grid_data, split.trafficlights, building_instances, roadside)
				roadside = roadside + signals
		# Props avoid buildings + roadside tiles (vehicles live on roads, no conflict).
		props = _place_props_on_ground(grid_data, split.props, building_instances, roadside)
		decor_instances = vehicles + roadside + props
		# Legacy fallback: if categorisation ate everything (custom kits without
		# car/lamp names), old behaviour placed all decor as props.
		if decor_instances.is_empty() and not loaded_models.decor.is_empty():
			decor_instances = _place_decor_on_ground(grid_data, loaded_models.decor, building_instances)

	_create_city_nodes(grid_data, building_instances, decor_instances, loaded_models)

	print("[CityGenerator] Generated %dx%d = %d buildings, %d decor | spacing=%d density=%.1f seed=%d h=%.3f" % [grid_size_tiles.x, grid_size_tiles.y, building_instances.size(), decor_instances.size(), building_spacing_tiles, building_density_multiplier, random_seed, base_tile_height + height_offset])

func clear_city():
	# Immediate free in editor, queued in game
	for child in get_children():
		if child.name == "GeneratedCity":
			if Engine.is_editor_hint():
				child.free()
			else:
				child.queue_free()
	_generated_root = null
	_global_occupied_tiles.clear()

# ============================================================================
# Height helpers (transform-aware so wheels/foundations ground exactly)
# ============================================================================
func _calculate_base_tile_height(ground_scene: PackedScene):
	if not ground_scene:
		base_tile_height = 0.0
		return
	var aabb: AABB = _get_scene_aabb(ground_scene)
	# Top of tile in root space (tiles sit at city_offset.y).
	base_tile_height = aabb.position.y + aabb.size.y
	# Guard against kits whose origin is top-centered (negative heights).
	if base_tile_height < -0.5 or base_tile_height > 2.0:
		push_warning("[CityGenerator] Suspicious tile height %.3f – clamping to 0.10" % base_tile_height)
		base_tile_height = 0.10

func _collect_mesh_aabbs(node: Node, parent_xform: Transform3D, out: Array):
	var local_xform := Transform3D.IDENTITY
	if node is Node3D:
		local_xform = (node as Node3D).transform
	var global_xform: Transform3D = parent_xform * local_xform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var laabb: AABB = mi.get_aabb()
		out.append(global_xform * laabb)
	for child in node.get_children():
		_collect_mesh_aabbs(child, global_xform, out)

func _get_scene_aabb(scene: PackedScene) -> AABB:
	var tmp = scene.instantiate()
	var boxes: Array = []
	_collect_mesh_aabbs(tmp, Transform3D.IDENTITY, boxes)
	var result := AABB(Vector3.ZERO, Vector3(2, 1, 2))
	if boxes.is_empty():
		tmp.free()
		return result
	result = boxes[0]
	for i in range(1, boxes.size()):
		# Manual merge (AABB.merge exists but be explicit for clarity).
		var b: AABB = boxes[i]
		var mn: Vector3 = result.position.min(b.position)
		var mx: Vector3 = (result.position + result.size).max(b.position + b.size)
		result = AABB(mn, mx - mn)
	tmp.free()
	if result.size.x < 0.01: result.size.x = 2.0
	if result.size.z < 0.01: result.size.z = 2.0
	if result.size.y < 0.01: result.size.y = 0.1
	return result

func _get_all_mesh_instances(node: Node, meshes: Array):
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		_get_all_mesh_instances(child, meshes)

func _get_scene_aabb_size(scene: PackedScene) -> Vector3:
	# Kept for API compatibility – now transform-aware.
	return _get_scene_aabb(scene).size

func _tile_top_world_y() -> float:
	if align_to_tile_top:
		return city_offset.y + base_tile_height
	return city_offset.y

func _get_building_y() -> float:
	# Kept for API compatibility (legacy callers).
	if align_to_tile_top:
		return base_tile_height + height_offset + city_offset.y
	return height_offset + city_offset.y

## Exact ground Y for a model: tile top + lift - min_y*scale - sink.
func _ground_y_for_model(model_path: String, scale_y: float, sink: float = 0.0) -> float:
	var min_y: float = float(_model_min_y.get(model_path, 0.0))
	return _tile_top_world_y() + height_offset - min_y * scale_y - sink

# ============================================================================
# Grid
# ============================================================================
func _generate_base_grid() -> Dictionary:
	var grid_data = {
		"tiles": {},
		"ground_positions": [],
		"road_positions": [],
		"corner_positions": [],
		"junction_positions": [],
		"tsplit_positions": [],
		"all_positions": []
	}
	for x in range(grid_size_tiles.x):
		for z in range(grid_size_tiles.y):
			var pos = Vector2i(x, z)
			grid_data.tiles[pos] = "ground"
			grid_data.ground_positions.append(pos)
			grid_data.all_positions.append(pos)
	return grid_data

func _add_lane_roads(grid_data: Dictionary):
	if lanes_x <= 0 and lanes_y <= 0:
		return
	var lane_positions_x = _calculate_lane_positions(lanes_x, grid_size_tiles.x)
	var lane_positions_z = _calculate_lane_positions(lanes_y, grid_size_tiles.y)
	for z_pos in lane_positions_z:
		for w in range(lane_width):
			var lane_z = z_pos - int(floor(lane_width / 2.0)) + w
			if lane_z < 0 or lane_z >= grid_size_tiles.y:
				continue
			for x in range(grid_size_tiles.x):
				var pos = Vector2i(x, lane_z)
				if grid_data.tiles.get(pos) == "ground":
					grid_data.tiles[pos] = "road"
					grid_data.road_positions.append(pos)
					grid_data.ground_positions.erase(pos)
	for x_pos in lane_positions_x:
		for w in range(lane_width):
			var lane_x = x_pos - int(floor(lane_width / 2.0)) + w
			if lane_x < 0 or lane_x >= grid_size_tiles.x:
				continue
			for z in range(grid_size_tiles.y):
				var pos = Vector2i(lane_x, z)
				if grid_data.tiles.get(pos) == "ground":
					grid_data.tiles[pos] = "road"
					grid_data.road_positions.append(pos)
					grid_data.ground_positions.erase(pos)

func _add_boundary_outside_grid(grid_data: Dictionary):
	var boundary_min = -1
	var boundary_max = grid_size_tiles.x
	for x in range(boundary_min, boundary_max + 1):
		var pos_bottom = Vector2i(x, boundary_min)
		grid_data.tiles[pos_bottom] = "road"
		grid_data.road_positions.append(pos_bottom)
		grid_data.all_positions.append(pos_bottom)
		var pos_top = Vector2i(x, boundary_max)
		grid_data.tiles[pos_top] = "road"
		grid_data.road_positions.append(pos_top)
		grid_data.all_positions.append(pos_top)
	for z in range(0, grid_size_tiles.y):
		var pos_left = Vector2i(boundary_min, z)
		grid_data.tiles[pos_left] = "road"
		grid_data.road_positions.append(pos_left)
		grid_data.all_positions.append(pos_left)
		var pos_right = Vector2i(boundary_max, z)
		grid_data.tiles[pos_right] = "road"
		grid_data.road_positions.append(pos_right)
		grid_data.all_positions.append(pos_right)
	if use_corner_pieces:
		var corners = [
			Vector2i(boundary_min, boundary_min),
			Vector2i(boundary_max, boundary_min),
			Vector2i(boundary_max, boundary_max),
			Vector2i(boundary_min, boundary_max)
		]
		for corner_pos in corners:
			grid_data.tiles[corner_pos] = "corner"
			grid_data.corner_positions.append(corner_pos)
			grid_data.road_positions.erase(corner_pos)

func _is_road_like(tile_type) -> bool:
	return tile_type == "road" or tile_type == "corner" or tile_type == "junction" or tile_type == "tsplit"

## Re-label every road-like tile by its 4-neighbourhood so crossings use the
## right piece. Non-destructive: straight/corner finals match v1 exactly.
func _classify_road_tiles(grid_data: Dictionary):
	var road_like: Dictionary = {}
	for pos in grid_data.tiles.keys():
		if _is_road_like(grid_data.tiles.get(pos)):
			road_like[pos] = true
	if road_like.is_empty():
		return
	var new_roads: Array = []
	var new_corners: Array = []
	var new_junctions: Array = []
	var new_tsplits: Array = []
	for pos in road_like.keys():
		var n: bool = road_like.has(Vector2i(pos.x, pos.y - 1))
		var s: bool = road_like.has(Vector2i(pos.x, pos.y + 1))
		var w: bool = road_like.has(Vector2i(pos.x - 1, pos.y))
		var e: bool = road_like.has(Vector2i(pos.x + 1, pos.y))
		var count: int = int(n) + int(s) + int(w) + int(e)
		var label := "road"
		if count >= 4:
			label = "junction" if (use_junction_pieces) else "road"
		elif count == 3:
			label = "tsplit" if (use_tsplit_pieces) else "road"
		elif count == 2:
			var opposite: bool = (n and s) or (e and w)
			if opposite:
				label = "road"
			else:
				label = "corner" if use_corner_pieces else "road"
		else:
			label = "road"
		grid_data.tiles[pos] = label
		match label:
			"road":
				new_roads.append(pos)
			"corner":
				new_corners.append(pos)
			"junction":
				new_junctions.append(pos)
			"tsplit":
				new_tsplits.append(pos)
	grid_data.road_positions = new_roads
	grid_data.corner_positions = new_corners
	grid_data.junction_positions = new_junctions
	grid_data.tsplit_positions = new_tsplits
	# Keep all_positions in sync for boundary tiles.
	for pos in road_like.keys():
		if not grid_data.all_positions.has(pos):
			grid_data.all_positions.append(pos)

## Second pass: guarantee every intersection connects to all road neighbours.
## Catches any label/rotation drift (custom lane_width, boundary meets, toggled
## piece flags) so crossings are right on every seed, every time.
## Single source of truth for connectivity – must match _determine_road_rotation:
##   straight EW=90 (E+W), NS=180 (N+S)
##   corner E+S=0, E+N=90, W+N=180, W+S=270 (verified from road_corner.glb)
##   tsplit missing W=0 (N+S+E), missing S=90, missing E=180, missing N=270
##   (verified from road_tsplit.glb top-face: rot 0 has east arm only)
##   junction = N+S+E+W (rotation-invariant)
func _validate_and_fix_intersections(grid_data: Dictionary) -> int:
	var fixed := 0
	var road_like: Dictionary = {}
	for pos in grid_data.tiles.keys():
		if _is_road_like(grid_data.tiles.get(pos)):
			road_like[pos] = true
	if road_like.is_empty():
		return 0
	for pos in road_like.keys():
		var n: bool = road_like.has(Vector2i(pos.x, pos.y - 1))
		var s: bool = road_like.has(Vector2i(pos.x, pos.y + 1))
		var w: bool = road_like.has(Vector2i(pos.x - 1, pos.y))
		var e: bool = road_like.has(Vector2i(pos.x + 1, pos.y))
		var count: int = int(n) + int(s) + int(w) + int(e)
		var want := "road"
		if count >= 4:
			want = "junction" if use_junction_pieces else "road"
		elif count == 3:
			want = "tsplit" if use_tsplit_pieces else "road"
		elif count == 2:
			var opposite: bool = (n and s) or (e and w)
			if opposite:
				want = "road"
			else:
				want = "corner" if use_corner_pieces else "road"
		else:
			want = "road"
		var have: String = str(grid_data.tiles.get(pos))
		if have != want:
			grid_data.tiles[pos] = want
			fixed += 1
	if fixed > 0:
		# Rebuild position lists so spawners stay in sync.
		var r: Array = []
		var c: Array = []
		var j: Array = []
		var t: Array = []
		for pos in road_like.keys():
			match str(grid_data.tiles.get(pos)):
				"road":
					r.append(pos)
				"corner":
					c.append(pos)
				"junction":
					j.append(pos)
				"tsplit":
					t.append(pos)
		grid_data.road_positions = r
		grid_data.corner_positions = c
		grid_data.junction_positions = j
		grid_data.tsplit_positions = t
		push_warning("[CityGenerator] Fixed %d mislabelled intersection tiles" % fixed)
	# Rotation audit: every road tile must connect to every road neighbour.
	var bad := 0
	for pos in road_like.keys():
		if not _tile_connects_to_all_neighbours(pos, grid_data):
			bad += 1
			push_warning("[CityGenerator] Tile %s (%s) rotation mismatch" % [str(pos), str(grid_data.tiles.get(pos))])
	if bad > 0:
		push_warning("[CityGenerator] %d tiles fail connectivity audit (check offsets)" % bad)
	return fixed

## Returns true if the piece+rotation placed at pos connects toward every
## road-like neighbour. Used by the audit above and by editor validation.
func _tile_connects_to_all_neighbours(pos: Vector2i, grid_data: Dictionary) -> bool:
	var label: String = str(grid_data.tiles.get(pos))
	var n: bool = _is_road_like(grid_data.tiles.get(Vector2i(pos.x, pos.y - 1)))
	var s: bool = _is_road_like(grid_data.tiles.get(Vector2i(pos.x, pos.y + 1)))
	var w: bool = _is_road_like(grid_data.tiles.get(Vector2i(pos.x - 1, pos.y)))
	var e: bool = _is_road_like(grid_data.tiles.get(Vector2i(pos.x + 1, pos.y)))
	var yaw: float = _determine_road_rotation(pos, label, grid_data)
	# Strip user offsets so the audit checks base orientation, not custom twists.
	match label:
		"road":
			yaw -= road_straight_rotation_offset
		"corner":
			yaw -= road_corner_rotation_offset
		"tsplit":
			yaw -= road_tsplit_rotation_offset
		"junction":
			yaw -= road_junction_rotation_offset
	# Normalise to 0/90/180/270.
	var y: int = int(round(fmod(yaw, 360.0))) % 360
	if y < 0:
		y += 360
	var connects: Dictionary = {}
	match label:
		"junction":
			connects = {"n": true, "s": true, "e": true, "w": true}
		"road":
			if y == 90 or y == 270:
				connects = {"e": true, "w": true}
			else:
				connects = {"n": true, "s": true}
		"corner":
			if y == 0:
				connects = {"e": true, "s": true}
			elif y == 90:
				connects = {"e": true, "n": true}
			elif y == 180:
				connects = {"w": true, "n": true}
			else:
				connects = {"w": true, "s": true}
		"tsplit":
			if y == 0:
				connects = {"n": true, "s": true, "e": true}
			elif y == 90:
				connects = {"n": true, "e": true, "w": true}
			elif y == 180:
				connects = {"n": true, "s": true, "w": true}
			else:
				connects = {"s": true, "e": true, "w": true}
		_:
			return true
	if n and not connects.has("n"):
		return false
	if s and not connects.has("s"):
		return false
	if w and not connects.has("w"):
		return false
	if e and not connects.has("e"):
		return false
	return true

func _create_sections_from_grid(grid_data: Dictionary) -> Array:
	var lane_pos_x = _calculate_lane_positions(lanes_x, grid_size_tiles.x)
	var lane_pos_z = _calculate_lane_positions(lanes_y, grid_size_tiles.y)
	var road_cols: Dictionary = {}
	for xp in lane_pos_x:
		for w in range(lane_width):
			var cx = xp - int(floor(lane_width / 2.0)) + w
			if cx >= 0 and cx < grid_size_tiles.x:
				road_cols[cx] = true
	var road_rows: Dictionary = {}
	for zp in lane_pos_z:
		for w in range(lane_width):
			var rz = zp - int(floor(lane_width / 2.0)) + w
			if rz >= 0 and rz < grid_size_tiles.y:
				road_rows[rz] = true
	var x_intervals = _split_free_intervals(0, grid_size_tiles.x - 1, road_cols)
	var z_intervals = _split_free_intervals(0, grid_size_tiles.y - 1, road_rows)
	var sections: Array = []
	var section_id = 0
	for xi in x_intervals:
		for zi in z_intervals:
			var w = xi[1] - xi[0] + 1
			var h = zi[1] - zi[0] + 1
			if w <= 0 or h <= 0:
				continue
			if w < building_min_size_tiles.x or h < building_min_size_tiles.y:
				continue
			var section = Section.new()
			section.id = section_id
			section.bounds = Rect2i(xi[0], zi[0], w, h)
			_calculate_section_properties(section, grid_data)
			if section.available_area > 0:
				sections.append(section)
				section_id += 1
	return sections

func _split_free_intervals(min_v: int, max_v: int, road_set: Dictionary) -> Array:
	var intervals: Array = []
	var start = -1
	for v in range(min_v, max_v + 1):
		if road_set.has(v):
			if start != -1:
				intervals.append([start, v - 1])
				start = -1
		else:
			if start == -1:
				start = v
	if start != -1:
		intervals.append([start, max_v])
	if intervals.is_empty():
		intervals.append([min_v, max_v])
	return intervals

func _calculate_section_properties(section: Section, grid_data: Dictionary):
	var available_count = 0
	for x in range(section.bounds.position.x, section.bounds.position.x + section.bounds.size.x):
		for z in range(section.bounds.position.y, section.bounds.position.y + section.bounds.size.y):
			var pos = Vector2i(x, z)
			if grid_data.tiles.get(pos) == "ground":
				available_count += 1
				section.available_tiles.append(Vector2(x, z))
	section.available_area = available_count
	# Effective area per building: footprint + single gap ring (shared between
	# neighbours on average). Matches documented "1 = 2m corridor".
	var avg_w = (building_min_size_tiles.x + building_max_size_tiles.x) * 0.5
	var avg_h = (building_min_size_tiles.y + building_max_size_tiles.y) * 0.5
	var eff_w = avg_w + float(building_spacing_tiles)
	var eff_h = avg_h + float(building_spacing_tiles)
	var avg_with_spacing = eff_w * eff_h
	if avg_with_spacing < 1.0:
		avg_with_spacing = avg_w * avg_h
	section.max_buildings = max(1, int(section.available_area / avg_with_spacing * building_density_multiplier))

# ============================================================================
# Buildings / Decor
# ============================================================================
func _place_buildings_in_sections(sections: Array, building_models: Array, grid_data: Dictionary) -> Array:
	var all_buildings: Array = []
	_global_occupied_tiles.clear()
	for section in sections:
		var available_tiles_array: Array = []
		for tile in section.available_tiles:
			available_tiles_array.append(Vector2i(int(tile.x), int(tile.y)))
		# Prefer tiles near roads (perimeter first) so buildings line streets.
		var x0 = section.bounds.position.x
		var z0 = section.bounds.position.y
		var w = section.bounds.size.x
		var h = section.bounds.size.y
		available_tiles_array.sort_custom(func(a, b):
			var gap_a = min(min(a.x - x0, (x0 + w) - (a.x + 1)), min(a.y - z0, (z0 + h) - (a.y + 1)))
			var gap_b = min(min(b.x - x0, (x0 + w) - (b.x + 1)), min(b.y - z0, (z0 + h) - (b.y + 1)))
			if gap_a == gap_b:
				return (a.x + a.y) < (b.x + b.y) # tie-breaker deterministic
			return gap_a < gap_b
		)
		var placed_count = 0
		var attempts = 0
		var max_attempts = section.max_buildings * 30 + available_tiles_array.size()
		# Fill until block is full (v1 stopped after max_buildings tries with a
		# single discard per failure, leaving most plots empty).
		while not available_tiles_array.is_empty() and placed_count < section.max_buildings and attempts < max_attempts:
			attempts += 1
			var try_pos: Vector2i
			if available_tiles_array.size() <= 12:
				try_pos = available_tiles_array[randi() % available_tiles_array.size()]
			else:
				# 75% street wall, 25% interior fill for density + variety.
				if randf() < 0.75:
					try_pos = available_tiles_array[randi() % 12]
				else:
					try_pos = available_tiles_array[randi() % available_tiles_array.size()]
			var model_info = building_models[randi() % building_models.size()]
			var width = randi_range(building_min_size_tiles.x, building_max_size_tiles.x)
			var depth = randi_range(building_min_size_tiles.y, building_max_size_tiles.y)
			if width + building_spacing_tiles > section.bounds.size.x:
				continue
			if depth + building_spacing_tiles > section.bounds.size.y:
				continue
			# Facing is decided from the TILE's nearest street side (not the
			# unrotated footprint), so non-square footprints don't pick a side
			# they no longer touch after the 90/270 swap ("some line up").
			var street_side = _nearest_street_side(try_pos, section)
			var rotation_degrees = _rotation_for_street_side(street_side)
			var rotated_size = _get_rotated_size(Vector2i(width, depth), rotation_degrees)
			# Street wall: slide the road-facing edge flush to the block edge
			# so fronts share one line. Fall back to the sampled tile if the
			# flush spot is taken (keeps density, lines up when possible).
			var flush_pos = _flush_pos_to_street(try_pos, rotated_size, section, street_side)
			var place_pos = try_pos
			if _can_place_building_at(flush_pos, rotated_size, section, grid_data) and not _is_global_area_occupied(flush_pos, rotated_size, building_spacing_tiles):
				place_pos = flush_pos
			elif not _can_place_building_at(try_pos, rotated_size, section, grid_data):
				# Drop hopeless tiles occasionally so we don't spin forever on
				# a blocked corner, but don't nuke the whole frontier like v1.
				if attempts % 25 == 0:
					available_tiles_array.erase(try_pos)
				continue
			if _is_global_area_occupied(place_pos, rotated_size, building_spacing_tiles):
				continue
			var building = _create_building_instance(place_pos, Vector2i(width, depth), rotated_size, rotation_degrees, model_info)
			all_buildings.append(building)
			# Store FOOTPRINT rect (gap enforced at query time).
			section.occupied_rects.append(Rect2(place_pos.x, place_pos.y, rotated_size.x, rotated_size.y))
			_mark_global_area_occupied(place_pos, rotated_size)
			var to_remove: Array = []
			for i in range(available_tiles_array.size()):
				var tp = available_tiles_array[i]
				if tp.x >= place_pos.x - building_spacing_tiles and tp.x < place_pos.x + rotated_size.x + building_spacing_tiles and tp.y >= place_pos.y - building_spacing_tiles and tp.y < place_pos.y + rotated_size.y + building_spacing_tiles:
					to_remove.append(i)
			to_remove.reverse()
			for idx in to_remove:
				available_tiles_array.remove_at(idx)
			placed_count += 1
	return all_buildings

func _shuffle_array(array: Array):
	var n = array.size()
	for i in range(n - 1, 0, -1):
		var j = randi() % (i + 1)
		var temp = array[i]
		array[i] = array[j]
		array[j] = temp

func _get_rotated_size(original_size: Vector2i, rotation_degrees: float) -> Vector2i:
	var rot_normalized = int(rotation_degrees) % 360
	if rot_normalized == 90 or rot_normalized == 270:
		return Vector2i(original_size.y, original_size.x)
	return original_size

## Nearest block edge for a TILE (size-independent). Ties broken randomly so
## corner plots vary instead of always picking one street.
func _nearest_street_side(pos: Vector2i, section: Section) -> String:
	var x0 = section.bounds.position.x
	var z0 = section.bounds.position.y
	var w = section.bounds.size.x
	var h = section.bounds.size.y
	var gap_west = pos.x - x0
	var gap_east = (x0 + w) - (pos.x + 1)
	var gap_north = pos.y - z0
	var gap_south = (z0 + h) - (pos.y + 1)
	var min_gap = min(min(gap_west, gap_east), min(gap_north, gap_south))
	var options: Array = []
	if gap_west == min_gap:
		options.append("west")
	if gap_east == min_gap:
		options.append("east")
	if gap_north == min_gap:
		options.append("north")
	if gap_south == min_gap:
		options.append("south")
	if options.is_empty():
		options.append("south")
	return str(options[randi() % options.size()])

## Base yaw per street side (front faces the street), plus user offset.
## Kit front is +Z (south) at rot 0, so west=90 east=270 north=0 south=180.
func _rotation_for_street_side(side: String) -> float:
	if not orient_buildings_to_road:
		return float((randi() % 4) * 90)
	var base := 180.0
	match side:
		"west":
			base = 90.0
		"east":
			base = 270.0
		"north":
			base = 0.0
		"south":
			base = 180.0
	return fmod(base + building_front_offset_degrees, 360.0)

## Slide the footprint so its road-facing edge sits flush on the block edge.
## Only the facing axis snaps; the other axis keeps the sampled tile so plots
## still vary along the street instead of stacking on one corner.
func _flush_pos_to_street(pos: Vector2i, rotated_size: Vector2i, section: Section, side: String) -> Vector2i:
	var x0 = section.bounds.position.x
	var z0 = section.bounds.position.y
	var w = section.bounds.size.x
	var h = section.bounds.size.y
	match side:
		"west":
			return Vector2i(x0, pos.y)
		"east":
			return Vector2i(x0 + w - rotated_size.x, pos.y)
		"north":
			return Vector2i(pos.x, z0)
		"south":
			return Vector2i(pos.x, z0 + h - rotated_size.y)
	return pos

func _get_road_facing_rotation(pos: Vector2i, size: Vector2i, section: Section) -> float:
	# Kept for API compatibility – now size-independent so the picked side
	# stays valid after the 90/270 footprint swap.
	return _rotation_for_street_side(_nearest_street_side(pos, section))

## Audit: every building must sit centered on its footprint tiles, on ground,
## with a cardinal rotation. Re-snaps centers (idempotent) and warns on any
## footprint covering road / hanging off the grid, so misalignments surface
## immediately instead of "some do, some don't".
func _validate_buildings_on_grid(buildings: Array, grid_data: Dictionary) -> int:
	var bad := 0
	for b in buildings:
		var gp: Vector2i = b.grid_position
		var rs: Vector2i = b.rotated_size
		# 1) footprint tiles must all be ground (never road/corner/junction/tsplit)
		for dx in range(rs.x):
			for dz in range(rs.y):
				var t = grid_data.tiles.get(gp + Vector2i(dx, dz))
				if t != "ground":
					push_warning("[CityGenerator] Building %s footprint %s on '%s', want ground" % [str(b.model_name), str(gp + Vector2i(dx, dz)), str(t)])
					bad += 1
		# 2) center must equal footprint-center math (catches half-tile drift)
		var want_x = (gp.x + (rs.x - 1) / 2.0) * tile_size.x + city_offset.x
		var want_z = (gp.y + (rs.y - 1) / 2.0) * tile_size.z + city_offset.z
		if absf(b.position.x - want_x) > 0.001 or absf(b.position.z - want_z) > 0.001:
			push_warning("[CityGenerator] Building %s off-center (%.3f,%.3f vs %.3f,%.3f) – snapping" % [str(b.model_name), b.position.x, b.position.z, want_x, want_z])
			b.position.x = want_x
			b.position.z = want_z
			bad += 1
		# 3) rotation must be a multiple of 90 (modulo user front offset)
		var unwound = fmod(b.rotation_y - building_front_offset_degrees, 360.0)
		if unwound < 0.0:
			unwound += 360.0
		var snapped = roundf(unwound / 90.0) * 90.0
		if absf(unwound - snapped) > 0.01:
			push_warning("[CityGenerator] Building %s yaw %.1f not cardinal – snapping" % [str(b.model_name), b.rotation_y])
			b.rotation_y = fmod(snapped + building_front_offset_degrees, 360.0)
			bad += 1
	if bad > 0:
		push_warning("[CityGenerator] Grid audit: %d building issues (see above)" % bad)
	return bad

func _can_place_building_at(pos: Vector2i, size: Vector2i, section: Section, grid_data: Dictionary) -> bool:
	# Inside section?
	if pos.x + size.x > section.bounds.position.x + section.bounds.size.x or pos.y + size.y > section.bounds.position.y + section.bounds.size.y:
		return false
	if pos.x < section.bounds.position.x or pos.y < section.bounds.position.y:
		return false
	# All footprint tiles must be ground
	for dx in range(size.x):
		for dz in range(size.y):
			var check_pos = pos + Vector2i(dx, dz)
			if grid_data.tiles.get(check_pos) != "ground":
				return false
	# Road gap – keep buildings from overlapping roads (use separate gap)
	for dx in range(-building_road_gap_tiles, size.x + building_road_gap_tiles):
		for dz in range(-building_road_gap_tiles, size.y + building_road_gap_tiles):
			if dx >= 0 and dx < size.x and dz >= 0 and dz < size.y:
				continue
			var check_pos = pos + Vector2i(dx, dz)
			var tile_type = grid_data.tiles.get(check_pos)
			if tile_type == "road" or tile_type == "corner" or tile_type == "junction" or tile_type == "tsplit":
				return false
	# Gap vs already placed in this section: expanded new vs footprint existing.
	# This yields exactly building_spacing_tiles between walls (v1 compared
	# expanded-vs-expanded and demanded 2x the gap, starving density).
	var probe = Rect2(pos.x - building_spacing_tiles, pos.y - building_spacing_tiles, size.x + (building_spacing_tiles * 2), size.y + (building_spacing_tiles * 2))
	for existing_rect in section.occupied_rects:
		var ex: Rect2 = existing_rect
		# Normalise: older saves may hold expanded rects – shrink if needed.
		# Footprints are small (<= max size); expanded ones are bigger.
		if probe.intersects(ex):
			return false
	# Global check (cross-section) via tile set (footprints only).
	if _is_global_area_occupied(pos, size, building_spacing_tiles):
		return false
	return true

func _is_global_area_occupied(pos: Vector2i, size: Vector2i, spacing: int) -> bool:
	# Expanded candidate vs footprint occupancy => single-gap semantics.
	for dx in range(-spacing, size.x + spacing):
		for dz in range(-spacing, size.y + spacing):
			var p = pos + Vector2i(dx, dz)
			if _global_occupied_tiles.has(p):
				return true
	return false

func _mark_global_area_occupied(pos: Vector2i, size: Vector2i, spacing: int = -1):
	# Footprints only (spacing enforced at query). Extra spacing arg kept for
	# API compatibility but ignored – gap lives in the query, not the mark.
	for dx in range(size.x):
		for dz in range(size.y):
			var p = pos + Vector2i(dx, dz)
			_global_occupied_tiles[p] = true

func _create_building_instance(grid_pos: Vector2i, original_size: Vector2i, rotated_size: Vector2i, rotation: float, model_info: Dictionary) -> BuildingInfo:
	var building = BuildingInfo.new()
	building.model_path = model_info.path
	building.model_name = model_info.name
	building.size_tiles = original_size
	building.rotated_size = rotated_size
	building.grid_position = grid_pos
	building.rotation_y = rotation
	# Mesh-aware scale: fit visual inside logical footprint, never overflow.
	# v1 clamped the minimum UP to 0.85, so oversized meshes overlapped
	# neighbours and looked "weird". Now we shrink to fit when needed.
	var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(2, 1, 2))
	var footprint_world_x = rotated_size.x * tile_size.x
	var footprint_world_z = rotated_size.y * tile_size.z
	# Tiny 0.96 margin so neighbours never touch.
	var max_scale_x = (footprint_world_x * 0.96) / mesh_sz.x if mesh_sz.x > 0 else 1.0
	var max_scale_z = (footprint_world_z * 0.96) / mesh_sz.z if mesh_sz.z > 0 else 1.0
	var max_allowed = minf(max_scale_x, max_scale_z)
	max_allowed = minf(max_allowed, 1.0)
	var min_allowed: float
	var scale_var: float
	if max_allowed >= 0.85:
		# Normal Kenney 2m buildings: preserve v1 look (0.88–0.96).
		min_allowed = maxf(0.88, max_allowed - 0.08)
		scale_var = randf_range(min_allowed, max_allowed)
	else:
		# Oversized mesh: shrink to fit instead of overlapping.
		min_allowed = maxf(0.3, max_allowed - 0.1)
		max_allowed = maxf(0.3, max_allowed)
		scale_var = randf_range(min_allowed, max_allowed)
	building.scale = Vector3(scale_var, scale_var, scale_var)
	building.mesh_size = mesh_sz
	# GRID: align building center to tile centers + exact grounding with sink.
	var world_x = (grid_pos.x + (rotated_size.x - 1) / 2.0) * tile_size.x + city_offset.x
	var world_z = (grid_pos.y + (rotated_size.y - 1) / 2.0) * tile_size.z + city_offset.z
	building.position = Vector3(world_x, _ground_y_for_model(model_info.path, scale_var, building_sink), world_z)
	# Footprint rect (gap enforced at query time).
	building.occupied_rect = Rect2(grid_pos.x, grid_pos.y, rotated_size.x, rotated_size.y)
	return building

# ----------------------------------------------------------------------------
# Decor categorisation + logical placement
# ----------------------------------------------------------------------------
func _matches_keywords(model_name: String, keywords: Array) -> bool:
	var lower = model_name.to_lower()
	for k in keywords:
		var ks: String = str(k).to_lower()
		if ks != "" and lower.contains(ks):
			return true
	return false

func _split_decor_models(decor_models: Array) -> Dictionary:
	var vehicles: Array = []
	var roadside: Array = []
	var trafficlights: Array = []
	var props: Array = []
	for m in decor_models:
		var n: String = str(m.name)
		if _matches_keywords(n, vehicle_keywords):
			vehicles.append(m)
		elif _matches_keywords(n, trafficlight_keywords):
			trafficlights.append(m)
		elif _matches_keywords(n, roadside_keywords):
			roadside.append(m)
		else:
			props.append(m)
	# Backwards compat: kits where traffic lights are only covered by the
	# generic roadside_keywords still get intersection placement.
	if trafficlights.is_empty() and place_trafficlights_at_intersections_only:
		var lamps_only: Array = []
		for m in roadside:
			if _matches_keywords(str(m.name), ["trafficlight"]):
				trafficlights.append(m)
			else:
				lamps_only.append(m)
		roadside = lamps_only
	return {"vehicles": vehicles, "roadside": roadside, "trafficlights": trafficlights, "props": props}

func _road_direction_at(pos: Vector2i, grid_data: Dictionary) -> String:
	var left_road = _is_road_like(grid_data.tiles.get(Vector2i(pos.x - 1, pos.y)))
	var right_road = _is_road_like(grid_data.tiles.get(Vector2i(pos.x + 1, pos.y)))
	var top_road = _is_road_like(grid_data.tiles.get(Vector2i(pos.x, pos.y - 1)))
	var bottom_road = _is_road_like(grid_data.tiles.get(Vector2i(pos.x, pos.y + 1)))
	var horiz = (left_road or right_road)
	var vert = (top_road or bottom_road)
	if horiz and not vert:
		return "EW"
	if vert and not horiz:
		return "NS"
	# Intersection or dead-end: pick dominant axis (prefer through-axis).
	if horiz and vert:
		return "NS"
	if left_road or right_road:
		return "EW"
	if top_road or bottom_road:
		return "NS"
	return "NS"

func _place_vehicles_on_roads(grid_data: Dictionary, vehicle_models: Array) -> Array:
	var result: Array = []
	if vehicle_models.is_empty():
		return result
	var candidates: Array = []
	for pos in grid_data.road_positions:
		var t = grid_data.tiles.get(pos)
		if keep_intersections_clear and t != "road":
			continue
		# Only straight segments read clearly as lanes.
		if t != "road":
			continue
		candidates.append(pos)
	if candidates.is_empty():
		return result
	_shuffle_array(candidates)
	var target = int(float(candidates.size()) * vehicle_density)
	target = mini(target, candidates.size())
	var blocked: Dictionary = {}
	for pos in candidates:
		if result.size() >= target:
			break
		if blocked.has(pos):
			continue
		var model_info = vehicle_models[randi() % vehicle_models.size()]
		var axis = _road_direction_at(pos, grid_data)
		# Car mesh is long in Z at rot 0 (0.42 x 0.94). Align length to street.
		var rot_y: float
		var lane_sign = 1.0
		if axis == "EW":
			# East (90) or West (270).
			if randf() < 0.5:
				rot_y = 90.0
				lane_sign = -1.0 # eastbound hugs north side
			else:
				rot_y = 270.0
				lane_sign = 1.0 # westbound hugs south side
		else:
			if randf() < 0.5:
				rot_y = 0.0
				lane_sign = -1.0 # southbound hugs west side
			else:
				rot_y = 180.0
				lane_sign = 1.0 # northbound hugs east side
		var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(0.5, 0.5, 0.5))
		# Keep cars near full size so wheels meet the road; clamp only if a
		# custom car mesh is wider than its lane.
		var sc = randf_range(0.95, 1.05)
		if mesh_sz.x * sc > tile_size.x * 0.9 or mesh_sz.z * sc > tile_size.z * 1.4:
			sc = minf((tile_size.x * 0.9) / maxf(mesh_sz.x, 0.01), (tile_size.z * 1.4) / maxf(mesh_sz.z, 0.01))
		var base_x = pos.x * tile_size.x + city_offset.x
		var base_z = pos.y * tile_size.z + city_offset.z
		# Lane offset perpendicular to travel.
		if axis == "EW":
			base_z += lane_sign * vehicle_lane_offset
		else:
			base_x += lane_sign * vehicle_lane_offset
		var decor = DecorInfo.new()
		decor.model_path = model_info.path
		decor.model_name = model_info.name
		decor.position = Vector3(base_x, _ground_y_for_model(model_info.path, sc, 0.0), base_z)
		decor.anchor_point = "road"
		decor.grid_position = pos
		decor.occupied_rect = Rect2(pos.x, pos.y, 1, 1)
		decor.rotation_y = rot_y
		decor.scale = Vector3(sc, sc, sc)
		result.append(decor)
		# Keep one clear tile fore/aft along travel so cars don't tailgate.
		blocked[pos] = true
		if axis == "EW":
			blocked[Vector2i(pos.x - 1, pos.y)] = true
			blocked[Vector2i(pos.x + 1, pos.y)] = true
		else:
			blocked[Vector2i(pos.x, pos.y - 1)] = true
			blocked[Vector2i(pos.x, pos.y + 1)] = true
	return result

func _ground_neighbours_road(pos: Vector2i, grid_data: Dictionary) -> Array:
	var out: Array = []
	var dirs = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		if _is_road_like(grid_data.tiles.get(pos + d)):
			out.append(d)
	return out

func _place_roadside_furniture(grid_data: Dictionary, roadside_models: Array, buildings: Array) -> Array:
	var result: Array = []
	if roadside_models.is_empty():
		return result
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y):
				building_tiles[b.grid_position + Vector2i(dx, dz)] = true
	var eligible: Array = []
	for gp in grid_data.ground_positions:
		if building_tiles.has(gp):
			continue
		if not _ground_neighbours_road(gp, grid_data).is_empty():
			eligible.append(gp)
	if eligible.is_empty():
		return result
	_shuffle_array(eligible)
	var target = int(float(eligible.size()) * roadside_density)
	target = mini(target, eligible.size())
	var used: Dictionary = {}
	for gp in eligible:
		if result.size() >= target:
			break
		if used.has(gp):
			continue
		# Spacing vs other roadside.
		var ok = true
		for r in result:
			if abs(r.grid_position.x - gp.x) <= decor_spacing_tiles and abs(r.grid_position.y - gp.y) <= decor_spacing_tiles:
				ok = false
				break
		if not ok:
			continue
		var road_dirs = _ground_neighbours_road(gp, grid_data)
		var toward: Vector2i = road_dirs[randi() % road_dirs.size()]
		var model_info = roadside_models[randi() % roadside_models.size()]
		# Sit on the road-side third of the sidewalk tile.
		var off = Vector3(float(toward.x) * tile_size.x / 3.0, 0, float(toward.y) * tile_size.z / 3.0)
		var sc = randf_range(0.9, 1.05)
		var base = Vector3(gp.x * tile_size.x + city_offset.x, 0, gp.y * tile_size.z + city_offset.z)
		base.y = _ground_y_for_model(model_info.path, sc, 0.0)
		# Face the street (snap 90° so gantry arms stay axis-aligned).
		var yaw = rad_to_deg(atan2(float(toward.x), float(toward.y)))
		yaw = float(int(round(yaw / 90.0)) * 90)
		var decor = DecorInfo.new()
		decor.model_path = model_info.path
		decor.model_name = model_info.name
		decor.position = base + off
		decor.anchor_point = "sidewalk"
		decor.grid_position = gp
		decor.occupied_rect = Rect2(gp.x, gp.y, 1, 1)
		decor.rotation_y = yaw
		decor.scale = Vector3(sc, sc, sc)
		result.append(decor)
		used[gp] = true
	return result

## Traffic lights go on ground tiles touching a junction/tsplit crossing,
## one corner (or two) per intersection – never mid-block.
func _place_trafficlights_at_intersections(grid_data: Dictionary, signal_models: Array, buildings: Array, reserved: Array) -> Array:
	var result: Array = []
	if signal_models.is_empty():
		return result
	var intersections: Array = []
	intersections.append_array(grid_data.get("junction_positions", []))
	intersections.append_array(grid_data.get("tsplit_positions", []))
	if intersections.is_empty():
		return result
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y):
				building_tiles[b.grid_position + Vector2i(dx, dz)] = true
	var taken: Dictionary = {}
	for r in reserved:
		taken[r.grid_position] = true
	# Group candidate sidewalk corners per intersection.
	var by_crossing: Dictionary = {}
	for cross in intersections:
		var corners: Array = []
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var gp: Vector2i = cross + Vector2i(dx, dz)
				if grid_data.tiles.get(gp) != "ground":
					continue
				if building_tiles.has(gp) or taken.has(gp):
					continue
				corners.append(gp)
		if not corners.is_empty():
			by_crossing[cross] = corners
	if by_crossing.is_empty():
		return result
	var order: Array = by_crossing.keys()
	_shuffle_array(order)
	var target_crossings = int(float(order.size()) * trafficlight_density)
	target_crossings = clampi(target_crossings, 0, order.size())
	var placed_crossings = 0
	for cross in order:
		if placed_crossings >= target_crossings:
			break
		var corners: Array = (by_crossing[cross] as Array).duplicate()
		_shuffle_array(corners)
		var per_cross = mini(trafficlights_per_intersection, corners.size())
		var placed_here = 0
		for gp in corners:
			if placed_here >= per_cross:
				break
			if taken.has(gp):
				continue
			# Spacing vs other signals so two crossings don't stack lights.
			var ok = true
			for r in result:
				if abs(r.grid_position.x - gp.x) <= decor_spacing_tiles and abs(r.grid_position.y - gp.y) <= decor_spacing_tiles:
					ok = false
					break
			if not ok:
				continue
			var model_info = signal_models[randi() % signal_models.size()]
			# Stand on the corner of the tile nearest the crossing, face it.
			var to_cross: Vector2i = cross - gp
			var sx = clampi(to_cross.x, -1, 1)
			var sz = clampi(to_cross.y, -1, 1)
			var off = Vector3(float(sx) * tile_size.x / 3.0, 0, float(sz) * tile_size.z / 3.0)
			var sc = randf_range(0.9, 1.05)
			var base = Vector3(gp.x * tile_size.x + city_offset.x, 0, gp.y * tile_size.z + city_offset.z)
			base.y = _ground_y_for_model(model_info.path, sc, 0.0)
			var yaw = rad_to_deg(atan2(float(sx), float(sz)))
			yaw = float(int(round(yaw / 90.0)) * 90)
			var decor = DecorInfo.new()
			decor.model_path = model_info.path
			decor.model_name = model_info.name
			decor.position = base + off
			decor.anchor_point = "intersection"
			decor.grid_position = gp
			decor.occupied_rect = Rect2(gp.x, gp.y, 1, 1)
			decor.rotation_y = yaw
			decor.scale = Vector3(sc, sc, sc)
			result.append(decor)
			taken[gp] = true
			placed_here += 1
		if placed_here > 0:
			placed_crossings += 1
	return result

func _place_props_on_ground(grid_data: Dictionary, prop_models: Array, buildings: Array, roadside: Array) -> Array:
	var all_props: Array = []
	if prop_models.is_empty():
		return all_props
	# Free ground = ground minus building footprints (+ optional ring) minus roadside tiles.
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y):
				building_tiles[b.grid_position + Vector2i(dx, dz)] = true
		if decor_min_dist_from_building > 0:
			for dx in range(-decor_min_dist_from_building, b.rotated_size.x + decor_min_dist_from_building):
				for dz in range(-decor_min_dist_from_building, b.rotated_size.y + decor_min_dist_from_building):
					if dx >= 0 and dx < b.rotated_size.x and dz >= 0 and dz < b.rotated_size.y:
						continue
					building_tiles[b.grid_position + Vector2i(dx, dz)] = true
	for r in roadside:
		building_tiles[r.grid_position] = true
	var free: Array = []
	for gp in grid_data.ground_positions:
		if not building_tiles.has(gp):
			free.append(gp)
	if free.is_empty():
		return all_props
	_shuffle_array(free)
	# v1 double-dipped density (target *= density AND randf() > density skip),
	# yielding ~density^2 fill. Use single gate so 0.35 means 35%.
	var target_decor = int(float(free.size()) * decor_density)
	target_decor = mini(target_decor, int(float(free.size()) * 0.5))
	var placed: Array = []
	for ground_pos in free:
		if placed.size() >= target_decor:
			break
		if not _is_valid_decor_position(ground_pos, grid_data, building_tiles, placed):
			continue
		var model_info = prop_models[randi() % prop_models.size()]
		var anchor = decor_anchor_points_enabled[randi() % decor_anchor_points_enabled.size()] if decor_anchor_points_enabled.size() > 0 else "center"
		var world_x = ground_pos.x * tile_size.x + city_offset.x
		var world_z = ground_pos.y * tile_size.z + city_offset.z
		# Scale first so grounding can compensate min_y correctly.
		var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(0.5, 0.5, 0.5))
		var max_decor_scale = 1.1
		if mesh_sz.x > 0.6 or mesh_sz.z > 0.6:
			max_decor_scale = minf(1.15, (tile_size.x * 0.85) / maxf(mesh_sz.x, mesh_sz.z))
		max_decor_scale = maxf(max_decor_scale, 0.85)
		var scale_var = randf_range(0.85, max_decor_scale)
		var base_pos = Vector3(world_x, _ground_y_for_model(model_info.path, scale_var, 0.0), world_z)
		var offset = _get_anchor_offset(anchor, tile_size)
		var decor_pos = base_pos + offset
		var decor = DecorInfo.new()
		decor.model_path = model_info.path
		decor.model_name = model_info.name
		decor.position = decor_pos
		decor.anchor_point = anchor
		decor.grid_position = ground_pos
		decor.occupied_rect = Rect2(ground_pos.x - decor_spacing_tiles, ground_pos.y - decor_spacing_tiles, 1 + (decor_spacing_tiles * 2), 1 + (decor_spacing_tiles * 2))
		decor.rotation_y = float((randi() % 4) * 90)
		decor.scale = Vector3(scale_var, scale_var, scale_var)
		placed.append(decor)
		building_tiles[ground_pos] = true
		all_props.append(decor)
	return all_props

## Legacy entry kept for API compatibility (custom kits / fallback path).
func _place_decor_on_ground(grid_data: Dictionary, decor_models: Array, buildings: Array) -> Array:
	var all_decor: Array = []
	if decor_models.is_empty():
		return all_decor
	# Single density gate (v1 applied it twice, starving plots).
	var target_decor = int(grid_data.ground_positions.size() * decor_density)
	target_decor = mini(target_decor, int(grid_data.ground_positions.size() * 0.5))
	var shuffled_ground = grid_data.ground_positions.duplicate()
	_shuffle_array(shuffled_ground)
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y):
				building_tiles[b.grid_position + Vector2i(dx, dz)] = true
		if decor_min_dist_from_building > 0:
			for dx in range(-decor_min_dist_from_building, b.rotated_size.x + decor_min_dist_from_building):
				for dz in range(-decor_min_dist_from_building, b.rotated_size.y + decor_min_dist_from_building):
					if dx >= 0 and dx < b.rotated_size.x and dz >= 0 and dz < b.rotated_size.y:
						continue
					building_tiles[b.grid_position + Vector2i(dx, dz)] = true
	for ground_pos in shuffled_ground:
		if all_decor.size() >= target_decor:
			break
		if not _is_valid_decor_position(ground_pos, grid_data, building_tiles, all_decor):
			continue
		var model_info = decor_models[randi() % decor_models.size()]
		var anchor = decor_anchor_points_enabled[randi() % decor_anchor_points_enabled.size()] if decor_anchor_points_enabled.size() > 0 else "center"
		var world_x = ground_pos.x * tile_size.x + city_offset.x
		var world_z = ground_pos.y * tile_size.z + city_offset.z
		var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(0.5, 0.5, 0.5))
		var max_decor_scale = 1.1
		if mesh_sz.x > 0.6 or mesh_sz.z > 0.6:
			max_decor_scale = minf(1.15, (tile_size.x * 0.85) / maxf(mesh_sz.x, mesh_sz.z))
		max_decor_scale = maxf(max_decor_scale, 0.85)
		var scale_var = randf_range(0.85, max_decor_scale)
		var base_pos = Vector3(world_x, _ground_y_for_model(model_info.path, scale_var, 0.0), world_z)
		var offset = _get_anchor_offset(anchor, tile_size)
		var decor_pos = base_pos + offset
		var decor = DecorInfo.new()
		decor.model_path = model_info.path
		decor.model_name = model_info.name
		decor.position = decor_pos
		decor.anchor_point = anchor
		decor.grid_position = ground_pos
		decor.occupied_rect = Rect2(ground_pos.x - decor_spacing_tiles, ground_pos.y - decor_spacing_tiles, 1 + (decor_spacing_tiles * 2), 1 + (decor_spacing_tiles * 2))
		decor.rotation_y = float((randi() % 4) * 90)
		decor.scale = Vector3(scale_var, scale_var, scale_var)
		all_decor.append(decor)
		building_tiles[ground_pos] = true
	return all_decor

func _is_valid_decor_position(pos: Vector2i, grid_data: Dictionary, building_tiles: Dictionary, existing_decor: Array) -> bool:
	if grid_data.tiles.get(pos) != "ground":
		return false
	if building_tiles.has(pos):
		return false
	# Respect decor_spacing_tiles vs other decor (1-tile check)
	for decor in existing_decor:
		var dx = abs(decor.grid_position.x - pos.x)
		var dz = abs(decor.grid_position.y - pos.y)
		if dx <= decor_spacing_tiles and dz <= decor_spacing_tiles:
			return false
	return true

# ============================================================================
# Helpers
# ============================================================================
func _validate_paths(ground_path: String, road_straight_path: String, road_corner_path: String) -> bool:
	var errors: Array = []
	if not FileAccess.file_exists(ground_path):
		errors.append("Ground tile not found: " + ground_path)
	if not FileAccess.file_exists(road_straight_path):
		errors.append("Road straight not found: " + road_straight_path)
	if use_corner_pieces and not FileAccess.file_exists(road_corner_path):
		push_warning("[CityGenerator] Road corner not found, disabling corners: " + road_corner_path)
		use_corner_pieces = false
	if not DirAccess.dir_exists_absolute(base_folder_path):
		errors.append("Base folder not found: " + base_folder_path)
	if generate_buildings and not DirAccess.dir_exists_absolute(building_models_folder):
		errors.append("Building folder not found: " + building_models_folder)
	if generate_decor and not DirAccess.dir_exists_absolute(decor_models_folder):
		errors.append("Decor folder not found: " + decor_models_folder)
	if errors.size() > 0:
		for error in errors:
			push_error(error)
		return false
	return true

func _load_models(ground_path: String, road_straight_path: String, road_corner_path: String, road_junction_path: String = "", road_tsplit_path: String = "") -> Dictionary:
	var models = {"ground": null, "road_straight": null, "road_corner": null, "road_junction": null, "road_tsplit": null, "buildings": [], "decor": []}
	models.ground = load(ground_path)
	models.road_straight = load(road_straight_path)
	if use_corner_pieces:
		if FileAccess.file_exists(road_corner_path):
			models.road_corner = load(road_corner_path)
		else:
			use_corner_pieces = false
	if use_junction_pieces and road_junction_path != "":
		if FileAccess.file_exists(road_junction_path):
			models.road_junction = load(road_junction_path)
		else:
			push_warning("[CityGenerator] Junction not found, using straight: " + road_junction_path)
			use_junction_pieces = false
	if use_tsplit_pieces and road_tsplit_path != "":
		if FileAccess.file_exists(road_tsplit_path):
			models.road_tsplit = load(road_tsplit_path)
		else:
			push_warning("[CityGenerator] TSplit not found, using straight: " + road_tsplit_path)
			use_tsplit_pieces = false
	if not models.ground or not models.road_straight:
		push_error("[CityGenerator] Could not load base models")
		return {}
	if generate_buildings:
		var building_dir = DirAccess.open(building_models_folder)
		if building_dir:
			building_dir.list_dir_begin()
			var file_name = building_dir.get_next()
			while file_name != "":
				if file_name.ends_with(".glb") and not building_dir.current_is_dir():
					var full_path = building_models_folder.path_join(file_name)
					var model = load(full_path)
					if model:
						models.buildings.append({"path": full_path, "scene": model, "name": _extract_model_name(file_name)})
				file_name = building_dir.get_next()
	if generate_decor:
		var decor_dir = DirAccess.open(decor_models_folder)
		if decor_dir:
			decor_dir.list_dir_begin()
			var file_name = decor_dir.get_next()
			while file_name != "":
				if file_name.ends_with(".glb") and not decor_dir.current_is_dir():
					var full_path = decor_models_folder.path_join(file_name)
					var model = load(full_path)
					if model:
						models.decor.append({"path": full_path, "scene": model, "name": _extract_model_name(file_name)})
				file_name = decor_dir.get_next()
	return models

func _calculate_lane_positions(num_lanes: int, grid_size: int) -> PackedInt32Array:
	var positions = PackedInt32Array()
	if num_lanes <= 0:
		return positions
	var spacing = float(grid_size) / (num_lanes + 1)
	for i in range(1, num_lanes + 1):
		positions.append(int(round(spacing * i)))
	return positions

func _get_anchor_offset(anchor: String, t_size: Vector3) -> Vector3:
	match anchor:
		"north": return Vector3(0, 0, -t_size.z / 3)
		"south": return Vector3(0, 0, t_size.z / 3)
		"east": return Vector3(t_size.x / 3, 0, 0)
		"west": return Vector3(-t_size.x / 3, 0, 0)
		"northeast": return Vector3(t_size.x / 3, 0, -t_size.z / 3)
		"northwest": return Vector3(-t_size.x / 3, 0, -t_size.z / 3)
		"southeast": return Vector3(t_size.x / 3, 0, t_size.z / 3)
		"southwest": return Vector3(-t_size.x / 3, 0, t_size.z / 3)
		_: return Vector3.ZERO

# ============================================================================
# Scene creation – runtime (no save, just instantiate under self)
# ============================================================================
func _create_city_nodes(grid_data: Dictionary, buildings: Array, decor: Array, models: Dictionary):
	_generated_root = Node3D.new()
	_generated_root.name = "GeneratedCity"
	add_child(_generated_root)
	# Make visible in editor
	if Engine.is_editor_hint():
		_generated_root.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else self

	var ground_node = _generated_root
	var roads_node = _generated_root
	var buildings_node = _generated_root
	var decor_node = _generated_root

	if create_organization_nodes:
		ground_node = Node3D.new()
		ground_node.name = "Ground"
		_generated_root.add_child(ground_node)
		roads_node = Node3D.new()
		roads_node.name = "Roads"
		_generated_root.add_child(roads_node)
		buildings_node = Node3D.new()
		buildings_node.name = "Buildings"
		_generated_root.add_child(buildings_node)
		decor_node = Node3D.new()
		decor_node.name = "Decor"
		_generated_root.add_child(decor_node)

	_create_tiles_from_grid(grid_data, "ground", models.ground, ground_node)
	_create_tiles_from_grid(grid_data, "road", models.road_straight, roads_node)
	if use_corner_pieces and models.road_corner:
		_create_tiles_from_grid(grid_data, "corner", models.road_corner, roads_node)
	else:
		# No corner kit: draw L-corners as straight (v1 fallback look).
		_create_tiles_from_grid(grid_data, "corner", models.road_straight, roads_node)
	# Intersections: fall back to straight with correct straight yaw when the
	# kit lacks the piece (keeps v1 crossing look instead of a wrong axis).
	if models.get("road_junction") != null:
		_create_tiles_from_grid(grid_data, "junction", models.road_junction, roads_node)
	else:
		_create_tiles_from_grid(grid_data, "junction_as_road", models.road_straight, roads_node)
	if models.get("road_tsplit") != null:
		_create_tiles_from_grid(grid_data, "tsplit", models.road_tsplit, roads_node)
	else:
		_create_tiles_from_grid(grid_data, "tsplit_as_road", models.road_straight, roads_node)
	if generate_buildings and buildings.size() > 0:
		_create_building_instances(buildings, models.buildings, buildings_node)
	if generate_decor and decor.size() > 0:
		_create_decor_instances(decor, models.decor, decor_node)

func _create_tiles_from_grid(grid_data: Dictionary, tile_type: String, scene: PackedScene, parent_node: Node3D):
	if scene == null:
		return
	var positions: Array = []
	match tile_type:
		"ground": positions = grid_data.ground_positions
		"road": positions = grid_data.road_positions
		"corner": positions = grid_data.corner_positions
		"junction": positions = grid_data.get("junction_positions", [])
		"tsplit": positions = grid_data.get("tsplit_positions", [])
		"junction_as_road": positions = grid_data.get("junction_positions", [])
		"tsplit_as_road": positions = grid_data.get("tsplit_positions", [])
		_: positions = []
	for grid_pos in positions:
		var world_x = grid_pos.x * tile_size.x + city_offset.x
		var world_z = grid_pos.y * tile_size.z + city_offset.z
		var world_pos = Vector3(world_x, city_offset.y, world_z)
		var instance = scene.instantiate()
		instance.position = world_pos
		# Final yaw already includes the v1 +90/+180 convention.
		# Fallback types reuse straight yaw so a straight piece never sits sideways.
		var yaw_type = tile_type
		if tile_type == "junction_as_road" or tile_type == "tsplit_as_road":
			yaw_type = "road"
		instance.rotation_degrees.y = _determine_road_rotation(grid_pos, yaw_type, grid_data)
		parent_node.add_child(instance)
		if generate_collisions:
			_ensure_collision(instance)

## Final yaw in degrees. Straight/corner match v1 finals exactly
## (straight EW=90 NS=180/0, corner E+S=0 E+N=90 W+N=180 W+S=270).
func _determine_road_rotation(grid_pos: Vector2i, tile_type: String, grid_data: Dictionary) -> float:
	if tile_type == "junction":
		return fmod(0.0 + road_junction_rotation_offset, 360.0)
	if tile_type == "tsplit":
		var n = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y - 1)))
		var s = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y + 1)))
		var w = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x - 1, grid_pos.y)))
		var e = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x + 1, grid_pos.y)))
		# Verified from road_tsplit.glb top-face verts: at rot 0 the mesh has
		# full N+S center dashes + east arm only (opening faces WEST).
		# So rot 0 = missing W (has N+S+E). +90 Y turns S->E, E->N, N->W
		# (missing arm W->S), giving:
		#   missing W -> 0, missing S -> 90, missing E -> 180, missing N -> 270.
		var base = 0.0
		if not w and n and s and e:
			base = 0.0
		elif not s and n and e and w:
			base = 90.0
		elif not e and n and s and w:
			base = 180.0
		elif not n and s and e and w:
			base = 270.0
		else:
			# Degenerate (lane_width>1 thick junction labelled tsplit):
			# fall back to dominant axis. East arm is native, so EW -> 0.
			if (e or w) and not (n or s):
				base = 0.0
			elif (n or s) and not (e or w):
				base = 90.0
			else:
				base = 0.0
		return fmod(base + road_tsplit_rotation_offset, 360.0)
	if tile_type == "corner":
		# Outer-ring mapping preserved: NW(E+S)=0 NE(W+S)=270 SE(W+N)=180 SW(E+N)=90.
		# Interior L-corners reuse the same table.
		var boundary_min = -1
		var boundary_max = grid_size_tiles.x
		if grid_pos == Vector2i(boundary_min, boundary_min):
			return fmod(0.0 + road_corner_rotation_offset, 360.0)
		if grid_pos == Vector2i(boundary_max, boundary_min):
			return fmod(270.0 + road_corner_rotation_offset, 360.0)
		if grid_pos == Vector2i(boundary_max, boundary_max):
			return fmod(180.0 + road_corner_rotation_offset, 360.0)
		if grid_pos == Vector2i(boundary_min, boundary_max):
			return fmod(90.0 + road_corner_rotation_offset, 360.0)
		var n2 = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y - 1)))
		var s2 = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y + 1)))
		var w2 = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x - 1, grid_pos.y)))
		var e2 = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x + 1, grid_pos.y)))
		if e2 and s2:
			return fmod(0.0 + road_corner_rotation_offset, 360.0)
		if e2 and n2:
			return fmod(90.0 + road_corner_rotation_offset, 360.0)
		if w2 and n2:
			return fmod(180.0 + road_corner_rotation_offset, 360.0)
		if w2 and s2:
			return fmod(270.0 + road_corner_rotation_offset, 360.0)
		return fmod(0.0 + road_corner_rotation_offset, 360.0)
	# Straight (and fallback): v1 logic was (0 for EW else 90) + 90.
	var left_road = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x - 1, grid_pos.y)))
	var right_road = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x + 1, grid_pos.y)))
	var top_road = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y - 1)))
	var bottom_road = _is_road_like(grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y + 1)))
	var base_straight = 90.0
	if (left_road or right_road) and not (top_road or bottom_road):
		base_straight = 90.0
	else:
		# NS segments (and v1 intersections) used 90+90=180.
		base_straight = 180.0
	return fmod(base_straight + road_straight_rotation_offset, 360.0)

func _create_building_instances(buildings: Array, building_models: Array, parent_node: Node3D):
	var buildings_by_model: Dictionary = {}
	for building in buildings:
		if not buildings_by_model.has(building.model_name):
			buildings_by_model[building.model_name] = []
		buildings_by_model[building.model_name].append(building)
	for model_name in buildings_by_model:
		var scene: PackedScene = null
		for model_info in building_models:
			if model_info.name == model_name:
				scene = model_info.scene
				break
		if scene:
			for building in buildings_by_model[model_name]:
				var instance = scene.instantiate()
				instance.position = building.position
				instance.rotation_degrees.y = building.rotation_y
				instance.scale = building.scale
				parent_node.add_child(instance)
				if generate_collisions:
					_ensure_collision(instance)

func _create_decor_instances(decor_items: Array, decor_models: Array, parent_node: Node3D):
	var decor_by_model: Dictionary = {}
	for decor_item in decor_items:
		if not decor_by_model.has(decor_item.model_name):
			decor_by_model[decor_item.model_name] = []
		decor_by_model[decor_item.model_name].append(decor_item)
	for model_name in decor_by_model:
		var scene: PackedScene = null
		for model_info in decor_models:
			if model_info.name == model_name:
				scene = model_info.scene
				break
		if scene:
			for decor_item in decor_by_model[model_name]:
				var instance = scene.instantiate()
				instance.position = decor_item.position
				instance.rotation_degrees.y = decor_item.rotation_y
				instance.scale = decor_item.scale
				parent_node.add_child(instance)
				if generate_collisions and collision_for_decor:
					_ensure_collision(instance)

func _extract_model_name(file_name: String) -> String:
	return file_name.replace(".glb", "").replace(".", "_")

func _has_collision(node: Node) -> bool:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _has_collision(child):
			return true
	return false

func _ensure_collision(instance: Node3D):
	if _has_collision(instance):
		return
	var boxes: Array = []
	# Instance-LOCAL space: ignore instance's own position/rotation/scale.
	# The Body/Collision children inherit them, so baking them in again would
	# double-count position (tiles ended up at 2x pos -> fall-through) and
	# double-apply scale. _get_scene_aabb() is unaffected (tmp is at origin).
	if instance is MeshInstance3D:
		boxes.append((instance as MeshInstance3D).get_aabb())
	for child in instance.get_children():
		_collect_mesh_aabbs(child, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return
	var combined_aabb: AABB = boxes[0]
	for i in range(1, boxes.size()):
		var b: AABB = boxes[i]
		var mn: Vector3 = combined_aabb.position.min(b.position)
		var mx: Vector3 = (combined_aabb.position + combined_aabb.size).max(b.position + b.size)
		combined_aabb = AABB(mn, mx - mn)
	# Local size/center – instance scale/rotation apply via inheritance.
	var local_size: Vector3 = combined_aabb.size
	if local_size.x < 0.05: local_size.x = 0.05
	if local_size.y < 0.05: local_size.y = 0.1
	if local_size.z < 0.05: local_size.z = 0.05
	var body := StaticBody3D.new()
	body.name = "CityCollision"
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = local_size
	col.shape = shape
	var center: Vector3 = combined_aabb.position + combined_aabb.size * 0.5
	# If the mesh origin sits below zero (e.g. car wheels at -0.07), the box
	# would dip under the tile. Clamp bottom to 0 so it rests on the road.
	if center.y - local_size.y * 0.5 < 0.0:
		center.y = local_size.y * 0.5
	col.position = center
	body.add_child(col)
	instance.add_child(body)
	body.collision_layer = 1
	body.collision_mask = 1

## Editor button helpers – call from inspector (tool)
func regenerate_in_editor():
	if Engine.is_editor_hint():
		generate_city()

func clear_in_editor():
	if Engine.is_editor_hint():
		clear_city()
