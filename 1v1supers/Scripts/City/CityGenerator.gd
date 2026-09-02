@tool
class_name CityGenerator
extends Node3D

## Runtime + Editor city generator – deterministic, no overlaps, correct heights.
## Fixed vs. original: spacing defaults, global occupancy, mesh-aware scaling,
## reduced height_offset, proper clear, interval-based blocks.

# ============================================================================
# CONFIGURATION
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

@export_group("Decor")
@export_range(0.0, 1.0, 0.05) var decor_density: float = 0.35
@export var decor_spacing_tiles: int = 1
@export var decor_anchor_points_enabled: Array = ["center", "north", "south", "east", "west"]
## Extra gap from buildings for decor (prevents decor inside building walls)
@export var decor_min_dist_from_building: int = 0

@export_group("Generation")
@export var use_corner_pieces: bool = true
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

# ============================================================================
# Internal structures
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
# Global tile occupancy: Vector2i -> true (building footprint + spacing)
var _global_occupied_tiles: Dictionary = {}
# Cache mesh sizes per model path to clamp scale
var _model_footprints: Dictionary = {}

func _ready():
	if auto_generate_on_ready and not Engine.is_editor_hint():
		generate_city()

func _validate_property(property: Dictionary):
	if property.name == "building_max_size_tiles":
		# hint that max should be >= min
		pass

## Public API
func generate_city():
	clear_city()
	_global_occupied_tiles.clear()
	_model_footprints.clear()
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

	if not _validate_paths(ground_tile_path, road_straight_path, road_corner_path):
		return

	var loaded_models = _load_models(ground_tile_path, road_straight_path, road_corner_path)
	if loaded_models.is_empty():
		return

	_calculate_base_tile_height(loaded_models.ground)
	# Precompute footprints for scale clamping
	for m in loaded_models.buildings:
		_model_footprints[m.path] = _get_scene_aabb_size(m.scene)
	for m in loaded_models.decor:
		_model_footprints[m.path] = _get_scene_aabb_size(m.scene)

	var grid_data = _generate_base_grid()
	_add_lane_roads(grid_data)
	_add_boundary_outside_grid(grid_data)
	var sections = _create_sections_from_grid(grid_data)

	var building_instances = []
	if generate_buildings and not loaded_models.buildings.is_empty():
		building_instances = _place_buildings_in_sections(sections, loaded_models.buildings, grid_data)

	var decor_instances = []
	if generate_decor and not loaded_models.decor.is_empty():
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
# Height helpers
# ============================================================================
func _calculate_base_tile_height(ground_scene: PackedScene):
	if not ground_scene:
		base_tile_height = 0.0
		return
	var tmp = ground_scene.instantiate()
	var meshes: Array = []
	_get_all_mesh_instances(tmp, meshes)
	if meshes.is_empty():
		base_tile_height = 0.0
		tmp.free()
		return
	var combined_aabb = meshes[0].get_aabb()
	for i in range(1, meshes.size()):
		combined_aabb = combined_aabb.merge(meshes[i].get_aabb())
	base_tile_height = combined_aabb.position.y + combined_aabb.size.y
	tmp.free()

func _get_all_mesh_instances(node: Node, meshes: Array):
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		_get_all_mesh_instances(child, meshes)

func _get_scene_aabb_size(scene: PackedScene) -> Vector3:
	var tmp = scene.instantiate()
	var meshes: Array = []
	_get_all_mesh_instances(tmp, meshes)
	if meshes.is_empty():
		tmp.free()
		return Vector3(2, 1, 2)
	var aabb = meshes[0].get_aabb()
	for i in range(1, meshes.size()):
		aabb = aabb.merge(meshes[i].get_aabb())
	tmp.free()
	# Ensure non-zero
	var sz = aabb.size
	if sz.x < 0.01: sz.x = 2.0
	if sz.z < 0.01: sz.z = 2.0
	if sz.y < 0.01: sz.y = 1.0
	return sz

func _get_building_y() -> float:
	if align_to_tile_top:
		return base_tile_height + height_offset + city_offset.y
	return height_offset + city_offset.y

# ============================================================================
# Grid
# ============================================================================
func _generate_base_grid() -> Dictionary:
	var grid_data = {
		"tiles": {},
		"ground_positions": [],
		"road_positions": [],
		"corner_positions": [],
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
	# More accurate capacity: each building needs footprint + spacing ring
	var avg_w = (building_min_size_tiles.x + building_max_size_tiles.x) * 0.5
	var avg_h = (building_min_size_tiles.y + building_max_size_tiles.y) * 0.5
	var avg_footprint = avg_w * avg_h
	# spacing adds perimeter: (w+2s)*(h+2s) - w*h
	var spacing_area = (avg_w + 2 * building_spacing_tiles) * (avg_h + 2 * building_spacing_tiles) - avg_footprint
	var avg_with_spacing = avg_footprint + spacing_area * 0.5
	if avg_with_spacing < 1.0:
		avg_with_spacing = avg_footprint
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
		# Prefer tiles near roads (perimeter first) so buildings line streets and leave interior corridors
		var x0 = section.bounds.position.x
		var z0 = section.bounds.position.y
		var w = section.bounds.size.x
		var h = section.bounds.size.y
		available_tiles_array.sort_custom(func(a,b):
			var gap_a = min(min(a.x - x0, (x0 + w) - (a.x + 1)), min(a.y - z0, (z0 + h) - (a.y + 1)))
			var gap_b = min(min(b.x - x0, (x0 + w) - (b.x + 1)), min(b.y - z0, (z0 + h) - (b.y + 1)))
			if gap_a == gap_b:
				return (a.x + a.y) < (b.x + b.y) # tie-breaker deterministic
			return gap_a < gap_b
		)
		var placed_count = 0
		for _building_num in range(section.max_buildings):
			if available_tiles_array.size() == 0:
				break
			var placed = false
			# Try perimeter tiles first (sorted), with a few random size attempts per tile
			var tiles_to_try = min(available_tiles_array.size(), 12)
			for tile_idx in range(tiles_to_try):
				var try_pos = available_tiles_array[tile_idx]
				for _attempt in range(6):
					var model_info = building_models[randi() % building_models.size()]
					var width = randi_range(building_min_size_tiles.x, building_max_size_tiles.x)
					var depth = randi_range(building_min_size_tiles.y, building_max_size_tiles.y)
					if width + 2 * building_spacing_tiles > section.bounds.size.x: continue
					if depth + 2 * building_spacing_tiles > section.bounds.size.y: continue
					var rotation_degrees = _get_road_facing_rotation(try_pos, Vector2i(width, depth), section)
					var rotated_size = _get_rotated_size(Vector2i(width, depth), rotation_degrees)
					if _can_place_building_at(try_pos, rotated_size, section, grid_data):
						if _is_global_area_occupied(try_pos, rotated_size, building_spacing_tiles):
							continue
						var building = _create_building_instance(try_pos, Vector2i(width, depth), rotated_size, rotation_degrees, model_info)
						all_buildings.append(building)
						section.occupied_rects.append(building.occupied_rect)
						_mark_global_area_occupied(try_pos, rotated_size, building_spacing_tiles)
						var to_remove: Array = []
						for i in range(available_tiles_array.size()):
							var tp = available_tiles_array[i]
							if tp.x >= try_pos.x - building_spacing_tiles and tp.x < try_pos.x + rotated_size.x + building_spacing_tiles and tp.y >= try_pos.y - building_spacing_tiles and tp.y < try_pos.y + rotated_size.y + building_spacing_tiles:
								to_remove.append(i)
						to_remove.reverse()
						for idx in to_remove:
							available_tiles_array.remove_at(idx)
						placed_count += 1
						placed = true
						break
				if placed:
					break
			if not placed and available_tiles_array.size() > 0:
				# No fit on perimeter, discard closest tile and try next
				available_tiles_array.remove_at(0)
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

func _get_road_facing_rotation(pos: Vector2i, size: Vector2i, section: Section) -> float:
	if not orient_buildings_to_road:
		return float((randi() % 4) * 90)
	var x0 = section.bounds.position.x
	var z0 = section.bounds.position.y
	var w = section.bounds.size.x
	var h = section.bounds.size.y
	var gap_west = pos.x - x0
	var gap_east = (x0 + w) - (pos.x + size.x)
	var gap_north = pos.y - z0
	var gap_south = (z0 + h) - (pos.y + size.y)
	var min_gap = min(min(gap_west, gap_east), min(gap_north, gap_south))
	var candidates: Array = []
	if gap_west == min_gap:
		candidates.append(90.0) # west (-X)
	if gap_east == min_gap:
		candidates.append(270.0) # east (+X)
	if gap_north == min_gap:
		candidates.append(0.0) # north (-Z)
	if gap_south == min_gap:
		candidates.append(180.0) # south (+Z)
	var base = candidates[randi() % candidates.size()]
	return fmod(base + building_front_offset_degrees, 360.0)

func _can_place_building_at(pos: Vector2i, size: Vector2i, section: Section, grid_data: Dictionary) -> bool:
	# Inside section?
	if pos.x + size.x > section.bounds.position.x + section.bounds.size.x or pos.y + size.y > section.bounds.position.y + section.bounds.size.y:
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
			if tile_type == "road" or tile_type == "corner":
				return false
	# Check against already placed in this section (rect)
	var occupied_rect = Rect2(pos.x - building_spacing_tiles, pos.y - building_spacing_tiles, size.x + (building_spacing_tiles * 2), size.y + (building_spacing_tiles * 2))
	for existing_rect in section.occupied_rects:
		if occupied_rect.intersects(existing_rect):
			return false
	# Global check (cross-section) via tile set
	if _is_global_area_occupied(pos, size, building_spacing_tiles):
		return false
	return true

func _is_global_area_occupied(pos: Vector2i, size: Vector2i, spacing: int) -> bool:
	for dx in range(-spacing, size.x + spacing):
		for dz in range(-spacing, size.y + spacing):
			var p = pos + Vector2i(dx, dz)
			if _global_occupied_tiles.has(p):
				return true
	return false

func _mark_global_area_occupied(pos: Vector2i, size: Vector2i, spacing: int):
	for dx in range(-spacing, size.x + spacing):
		for dz in range(-spacing, size.y + spacing):
			var p = pos + Vector2i(dx, dz)
			_global_occupied_tiles[p] = true
	# Also mark interior footprint separately? spacing already covers it

func _create_building_instance(grid_pos: Vector2i, original_size: Vector2i, rotated_size: Vector2i, rotation: float, model_info: Dictionary) -> BuildingInfo:
	var building = BuildingInfo.new()
	building.model_path = model_info.path
	building.model_name = model_info.name
	building.size_tiles = original_size
	building.rotated_size = rotated_size
	building.grid_position = grid_pos
	building.rotation_y = rotation
	# GRID FIX: align building center to tile centers (tiles are centered at grid* tile_size)
	# Old formula (grid+size/2)*tile_size was off by +tile_size/2, causing buildings to straddle 4 tiles and overlap roads.
	var world_x = (grid_pos.x + (rotated_size.x - 1) / 2.0) * tile_size.x + city_offset.x
	var world_z = (grid_pos.y + (rotated_size.y - 1) / 2.0) * tile_size.z + city_offset.z
	building.position = Vector3(world_x, _get_building_y(), world_z)
	building.occupied_rect = Rect2(grid_pos.x - building_spacing_tiles, grid_pos.y - building_spacing_tiles, rotated_size.x + (building_spacing_tiles * 2), rotated_size.y + (building_spacing_tiles * 2))
	# Mesh-aware scale clamp: never let visual exceed logical tile footprint
	var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(2, 1, 2))
	var footprint_world_x = rotated_size.x * tile_size.x
	var footprint_world_z = rotated_size.y * tile_size.z
	# Add tiny margin 0.95 so buildings never touch
	var max_scale_x = (footprint_world_x * 0.96) / mesh_sz.x if mesh_sz.x > 0 else 1.0
	var max_scale_z = (footprint_world_z * 0.96) / mesh_sz.z if mesh_sz.z > 0 else 1.0
	var max_scale = minf(max_scale_x, max_scale_z)
	max_scale = clampf(max_scale, 0.85, 1.0)
	# For 1x1 tiles max ~0.96, for 2x2 ~1.0
	var min_scale = maxf(0.88, max_scale - 0.08)
	var scale_var = randf_range(min_scale, max_scale)
	building.scale = Vector3(scale_var, scale_var, scale_var)
	building.mesh_size = mesh_sz
	return building

func _place_decor_on_ground(grid_data: Dictionary, decor_models: Array, buildings: Array) -> Array:
	var all_decor: Array = []
	if decor_models.is_empty():
		return all_decor
	var placed_count = 0
	var target_decor = int(grid_data.ground_positions.size() * decor_density)
	# Cap at 50% of ground to avoid clutter
	target_decor = mini(target_decor, int(grid_data.ground_positions.size() * 0.5))
	var shuffled_ground = grid_data.ground_positions.duplicate()
	_shuffle_array(shuffled_ground)
	# Build fast building occupancy set (footprint only, not spacing, unless decor_min_dist)
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y):
				building_tiles[b.grid_position + Vector2i(dx, dz)] = true
		# Also add spacing ring if configured
		if decor_min_dist_from_building > 0:
			for dx in range(-decor_min_dist_from_building, b.rotated_size.x + decor_min_dist_from_building):
				for dz in range(-decor_min_dist_from_building, b.rotated_size.y + decor_min_dist_from_building):
					if dx >=0 and dx < b.rotated_size.x and dz >=0 and dz < b.rotated_size.y: continue
					building_tiles[b.grid_position + Vector2i(dx, dz)] = true

	for ground_pos in shuffled_ground:
		if placed_count >= target_decor:
			break
		if decor_density < 1.0 and randf() > decor_density:
			continue
		if not _is_valid_decor_position(ground_pos, grid_data, building_tiles, all_decor):
			continue
		var model_info = decor_models[randi() % decor_models.size()]
		var anchor = decor_anchor_points_enabled[randi() % decor_anchor_points_enabled.size()] if decor_anchor_points_enabled.size() > 0 else "center"
		var world_x = ground_pos.x * tile_size.x + city_offset.x
		var world_z = ground_pos.y * tile_size.z + city_offset.z
		var base_pos = Vector3(world_x, _get_building_y(), world_z)
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
		# Decor scale: clamp so streetlights etc don't spill hugely
		var mesh_sz: Vector3 = _model_footprints.get(model_info.path, Vector3(0.5, 0.5, 0.5))
		var max_decor_scale = 1.1
		# Large decor like trafficlight_C is 0.8 wide within 2 tile; allow up to 1.2
		if mesh_sz.x > 0.6 or mesh_sz.z > 0.6:
			max_decor_scale = minf(1.15, (tile_size.x * 0.85) / maxf(mesh_sz.x, mesh_sz.z))
		var scale_var = randf_range(0.85, max_decor_scale)
		decor.scale = Vector3(scale_var, scale_var, scale_var)
		all_decor.append(decor)
		# Mark global so future decor doesn't stack? Also mark building_tiles to prevent decor-decor overlap
		building_tiles[ground_pos] = true
		placed_count += 1
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
	# Also avoid immediate road adjacency if we care (optional) – keep decor next to road allowed
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

func _load_models(ground_path: String, road_straight_path: String, road_corner_path: String) -> Dictionary:
	var models = {"ground": null, "road_straight": null, "road_corner": null, "buildings": [], "decor": []}
	models.ground = load(ground_path)
	models.road_straight = load(road_straight_path)
	if use_corner_pieces:
		models.road_corner = load(road_corner_path)
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
	if generate_buildings and buildings.size() > 0:
		_create_building_instances(buildings, models.buildings, buildings_node)
	if generate_decor and decor.size() > 0:
		_create_decor_instances(decor, models.decor, decor_node)

func _create_tiles_from_grid(grid_data: Dictionary, tile_type: String, scene: PackedScene, parent_node: Node3D):
	var positions: Array = []
	match tile_type:
		"ground": positions = grid_data.ground_positions
		"road": positions = grid_data.road_positions
		"corner": positions = grid_data.corner_positions
	for grid_pos in positions:
		var world_x = grid_pos.x * tile_size.x + city_offset.x
		var world_z = grid_pos.y * tile_size.z + city_offset.z
		var world_pos = Vector3(world_x, city_offset.y, world_z)
		var instance = scene.instantiate()
		instance.position = world_pos
		if tile_type == "road":
			instance.rotation_degrees.y = _determine_road_rotation(grid_pos, tile_type, grid_data) + 90
		if tile_type == "corner":
			instance.rotation_degrees.y = _determine_road_rotation(grid_pos, tile_type, grid_data) + 180
		parent_node.add_child(instance)
		if generate_collisions:
			_ensure_collision(instance)

func _determine_road_rotation(grid_pos: Vector2i, tile_type: String, grid_data: Dictionary) -> float:
	if tile_type == "corner":
		var boundary_min = -1
		var boundary_max = grid_size_tiles.x
		if grid_pos == Vector2i(boundary_min, boundary_min): return 180
		if grid_pos == Vector2i(boundary_max, boundary_min): return 90
		if grid_pos == Vector2i(boundary_max, boundary_max): return 0
		if grid_pos == Vector2i(boundary_min, boundary_max): return 270
	var left_road = grid_data.tiles.get(Vector2i(grid_pos.x - 1, grid_pos.y)) in ["road", "corner"]
	var right_road = grid_data.tiles.get(Vector2i(grid_pos.x + 1, grid_pos.y)) in ["road", "corner"]
	var top_road = grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y - 1)) in ["road", "corner"]
	var bottom_road = grid_data.tiles.get(Vector2i(grid_pos.x, grid_pos.y + 1)) in ["road", "corner"]
	if (left_road or right_road) and not (top_road or bottom_road):
		return 0
	return 90

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
	var meshes: Array = []
	_get_all_mesh_instances(instance, meshes)
	if meshes.is_empty():
		return
	var combined_aabb: AABB = meshes[0].get_aabb()
	for i in range(1, meshes.size()):
		combined_aabb = combined_aabb.merge(meshes[i].get_aabb())
	var scaled_size: Vector3 = combined_aabb.size * instance.scale
	if scaled_size.x < 0.05: scaled_size.x = 0.05
	if scaled_size.y < 0.05: scaled_size.y = 0.1
	if scaled_size.z < 0.05: scaled_size.z = 0.05
	var body := StaticBody3D.new()
	body.name = "CityCollision"
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = scaled_size
	col.shape = shape
	var center: Vector3 = (combined_aabb.position + combined_aabb.size * 0.5) * instance.scale
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
