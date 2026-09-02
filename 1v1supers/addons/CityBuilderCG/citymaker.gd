@tool
extends EditorScript

# CityBuilderCG – fixed deterministic generator (bake to scene).
# Changes vs v1: interval-based blocks (no flood-leak), global occupancy,
# mesh-aware scale clamp, reduced height_offset, density math, spacing fixes.

var grid_size_tiles: Vector2i = Vector2i(30, 30)
var tile_size: Vector3 = Vector3(2.0, 0, 2.0)
var base_folder_path: String = "res://bases/"
var building_models_folder: String = "res://buildings/"
var decor_models_folder: String = "res://decors/"
var ground_tile_name: String = "base"
var road_straight_name: String = "road_straight"
var road_corner_name: String = "road_corner"
var lanes_x: int = 3
var lanes_y: int = 2
var lane_width: int = 1
var building_min_size_tiles: Vector2i = Vector2i(1, 1)
var building_max_size_tiles: Vector2i = Vector2i(2, 2)
var building_spacing_tiles: int = 1
var building_road_gap_tiles: int = 0
var building_density_multiplier: float = 1.4
var orient_buildings_to_road: bool = true
var building_front_offset_degrees: float = 180.0
var decor_density: float = 0.35
var decor_spacing_tiles: int = 1
var decor_anchor_points_enabled: Array = ["center", "north", "south", "east", "west"]
var output_scene_path: String = "res://Scenes/Levels/generated_city.tscn"
var use_corner_pieces: bool = true
var random_seed: int = 42
var generate_buildings: bool = true
var generate_decor: bool = true
var create_organization_nodes: bool = true
var base_tile_height: float = 0.0
var height_offset: float = 0.01
var _global_occupied: Dictionary = {}
var _model_footprints: Dictionary = {}

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
	var mesh_size: Vector3 = Vector3(2,1,2)

class DecorInfo:
	var model_path: String
	var position: Vector3
	var rotation_y: float
	var scale: Vector3 = Vector3.ONE
	var anchor_point: String
	var model_name: String
	var grid_position: Vector2i
	var occupied_rect: Rect2

func _run():
	print("🏙️  Starting CityBuilderCG (FIXED)...")
	_global_occupied.clear()
	_model_footprints.clear()
	if building_max_size_tiles.x < building_min_size_tiles.x or building_max_size_tiles.y < building_min_size_tiles.y:
		building_max_size_tiles.x = maxi(building_max_size_tiles.x, building_min_size_tiles.x)
		building_max_size_tiles.y = maxi(building_max_size_tiles.y, building_min_size_tiles.y)
	if random_seed == 0: randomize()
	else: seed(random_seed)
	var ground_tile_path = base_folder_path.path_join(ground_tile_name + ".glb")
	var road_straight_path = base_folder_path.path_join(road_straight_name + ".glb")
	var road_corner_path = base_folder_path.path_join(road_corner_name + ".glb")
	if not validate_paths(ground_tile_path, road_straight_path, road_corner_path):
		return
	var loaded_models = load_models(ground_tile_path, road_straight_path, road_corner_path)
	if loaded_models.is_empty(): return
	calculate_base_tile_height(loaded_models.ground)
	for m in loaded_models.buildings:
		_model_footprints[m.path] = get_scene_aabb_size(m.scene)
	for m in loaded_models.decor:
		_model_footprints[m.path] = get_scene_aabb_size(m.scene)
	print("\n=== STEP 1: BASE GRID %dx%d ===" % [grid_size_tiles.x, grid_size_tiles.y])
	var grid_data = generate_base_grid()
	print("\n=== STEP 2: LANES ===")
	add_lane_roads(grid_data)
	print("\n=== STEP 3: BOUNDARY ===")
	add_boundary_outside_grid(grid_data)
	print("\n=== STEP 4: SECTIONS ===")
	var sections = create_sections_from_grid(grid_data)
	print("Found %d blocks" % sections.size())
	var building_instances = []
	if generate_buildings and not loaded_models.buildings.is_empty():
		print("\n=== STEP 5: BUILDINGS density=%.1f spacing=%d ===" % [building_density_multiplier, building_spacing_tiles])
		building_instances = place_buildings_in_sections(sections, loaded_models.buildings, grid_data)
		print("✅ %d buildings" % building_instances.size())
	var decor_instances = []
	if generate_decor and not loaded_models.decor.is_empty():
		print("\n=== STEP 6: DECOR density=%.2f ===" % decor_density)
		decor_instances = place_decor_on_ground(grid_data, loaded_models.decor, building_instances)
		print("✅ %d decor" % decor_instances.size())
	print("\n=== SAVING ===")
	create_and_save_scene(grid_data, building_instances, decor_instances, loaded_models)
	print("\n✅ COMPLETE (height=%.3f)" % [base_tile_height + height_offset])

func calculate_base_tile_height(ground_scene: PackedScene):
	if not ground_scene:
		base_tile_height = 0.0; return
	var tmp = ground_scene.instantiate()
	var meshes = []
	get_all_mesh_instances(tmp, meshes)
	if meshes.is_empty():
		base_tile_height = 0.0; tmp.queue_free(); return
	var aabb = meshes[0].get_aabb()
	for i in range(1, meshes.size()): aabb = aabb.merge(meshes[i].get_aabb())
	base_tile_height = aabb.position.y + aabb.size.y
	print("📏 base tile height %.3f + offset %.3f = %.3f" % [base_tile_height, height_offset, base_tile_height+height_offset])
	tmp.queue_free()

func get_all_mesh_instances(node: Node, meshes: Array):
	if node is MeshInstance3D: meshes.append(node)
	for c in node.get_children(): get_all_mesh_instances(c, meshes)

func get_scene_aabb_size(scene: PackedScene) -> Vector3:
	var tmp = scene.instantiate()
	var meshes: Array = []
	get_all_mesh_instances(tmp, meshes)
	if meshes.is_empty():
		tmp.free(); return Vector3(2,1,2)
	var aabb = meshes[0].get_aabb()
	for i in range(1, meshes.size()): aabb = aabb.merge(meshes[i].get_aabb())
	tmp.free()
	var sz = aabb.size
	if sz.x < 0.01: sz.x = 2.0
	if sz.z < 0.01: sz.z = 2.0
	return sz

func get_building_y() -> float:
	return base_tile_height + height_offset

# GRID
func generate_base_grid() -> Dictionary:
	var grid_data = {"tiles": {}, "ground_positions": [], "road_positions": [], "corner_positions": [], "all_positions": []}
	for x in range(grid_size_tiles.x):
		for z in range(grid_size_tiles.y):
			var pos = Vector2i(x, z)
			grid_data.tiles[pos] = "ground"
			grid_data.ground_positions.append(pos)
			grid_data.all_positions.append(pos)
	print("✅ %d ground" % grid_data.ground_positions.size())
	return grid_data

func add_lane_roads(grid_data: Dictionary):
	if lanes_x <=0 and lanes_y <=0: print("⚠️ no lanes"); return
	var lx = calculate_lane_positions(lanes_x, grid_size_tiles.x)
	var lz = calculate_lane_positions(lanes_y, grid_size_tiles.y)
	print("lanes X %s Z %s" % [str(lx), str(lz)])
	var cnt=0
	for zp in lz:
		for w in range(lane_width):
			var lz2 = zp - int(floor(lane_width/2.0)) + w
			if lz2<0 or lz2>=grid_size_tiles.y: continue
			for x in range(grid_size_tiles.x):
				var p=Vector2i(x,lz2)
				if grid_data.tiles.get(p)=="ground":
					grid_data.tiles[p]="road"; grid_data.road_positions.append(p); grid_data.ground_positions.erase(p); cnt+=1
	for xp in lx:
		for w in range(lane_width):
			var lx2 = xp - int(floor(lane_width/2.0)) + w
			if lx2<0 or lx2>=grid_size_tiles.x: continue
			for z in range(grid_size_tiles.y):
				var p=Vector2i(lx2,z)
				if grid_data.tiles.get(p)=="ground":
					grid_data.tiles[p]="road"; grid_data.road_positions.append(p); grid_data.ground_positions.erase(p); cnt+=1
	print("✅ %d lane roads" % cnt)

func add_boundary_outside_grid(grid_data: Dictionary):
	var mn=-1; var mx=grid_size_tiles.x; var cnt=0
	for x in range(mn,mx+1):
		for p in [Vector2i(x,mn), Vector2i(x,mx)]:
			grid_data.tiles[p]="road"; grid_data.road_positions.append(p); grid_data.all_positions.append(p); cnt+=1
	for z in range(0,grid_size_tiles.y):
		for p in [Vector2i(mn,z), Vector2i(mx,z)]:
			grid_data.tiles[p]="road"; grid_data.road_positions.append(p); grid_data.all_positions.append(p); cnt+=1
	if use_corner_pieces:
		for c in [Vector2i(mn,mn),Vector2i(mx,mn),Vector2i(mx,mx),Vector2i(mn,mx)]:
			grid_data.tiles[c]="corner"; grid_data.corner_positions.append(c); grid_data.road_positions.erase(c)
		print("✅ boundary %d roads +4 corners" % (cnt-4))
	else: print("✅ boundary %d roads" % cnt)

# SECTIONS – interval based (fixed)
func create_sections_from_grid(grid_data: Dictionary) -> Array:
	var lpx = calculate_lane_positions(lanes_x, grid_size_tiles.x)
	var lpz = calculate_lane_positions(lanes_y, grid_size_tiles.y)
	var road_cols: Dictionary = {}
	for xp in lpx:
		for w in range(lane_width):
			var cx = xp - int(floor(lane_width/2.0)) + w
			if cx>=0 and cx<grid_size_tiles.x: road_cols[cx]=true
	var road_rows: Dictionary = {}
	for zp in lpz:
		for w in range(lane_width):
			var rz = zp - int(floor(lane_width/2.0)) + w
			if rz>=0 and rz<grid_size_tiles.y: road_rows[rz]=true
	var xi = split_free_intervals(0,grid_size_tiles.x-1,road_cols)
	var zi = split_free_intervals(0,grid_size_tiles.y-1,road_rows)
	var sections: Array = []
	var sid=0
	for xint in xi:
		for zint in zi:
			var w=xint[1]-xint[0]+1; var h=zint[1]-zint[0]+1
			if w < building_min_size_tiles.x or h < building_min_size_tiles.y: continue
			var sec=Section.new(); sec.id=sid; sec.bounds=Rect2i(xint[0],zint[0],w,h)
			calculate_section_properties(sec, grid_data)
			if sec.available_area>0:
				sections.append(sec); sid+=1
	return sections

func split_free_intervals(min_v:int, max_v:int, road_set:Dictionary) -> Array:
	var iv: Array = []; var start=-1
	for v in range(min_v, max_v+1):
		if road_set.has(v):
			if start!=-1: iv.append([start,v-1]); start=-1
		else:
			if start==-1: start=v
	if start!=-1: iv.append([start,max_v])
	if iv.is_empty(): iv.append([min_v,max_v])
	return iv

func calculate_section_properties(section: Section, grid_data: Dictionary):
	var cnt=0
	for x in range(section.bounds.position.x, section.bounds.position.x+section.bounds.size.x):
		for z in range(section.bounds.position.y, section.bounds.position.y+section.bounds.size.y):
			if grid_data.tiles.get(Vector2i(x,z))=="ground":
				cnt+=1; section.available_tiles.append(Vector2(x,z))
	section.available_area=cnt
	var avg_w=(building_min_size_tiles.x+building_max_size_tiles.x)*0.5
	var avg_h=(building_min_size_tiles.y+building_max_size_tiles.y)*0.5
	var avg_fp=avg_w*avg_h
	var sp_area=(avg_w+2*building_spacing_tiles)*(avg_h+2*building_spacing_tiles)-avg_fp
	var avg_sp=avg_fp+sp_area*0.5
	if avg_sp<1.0: avg_sp=avg_fp
	section.max_buildings=max(1,int(section.available_area/avg_sp*building_density_multiplier))
	print("  block %d %dx%d avail %d cap %d" % [section.id, section.bounds.size.x, section.bounds.size.y, cnt, section.max_buildings])

# BUILDINGS - perimeter-first, road-facing, 1-tile corridors
func place_buildings_in_sections(sections: Array, building_models: Array, grid_data: Dictionary) -> Array:
	var all: Array = []
	_global_occupied.clear()
	for sec in sections:
		var avail: Array = []
		for t in sec.available_tiles: avail.append(Vector2i(int(t.x),int(t.y)))
		var x0 = sec.bounds.position.x
		var z0 = sec.bounds.position.y
		var w = sec.bounds.size.x
		var h = sec.bounds.size.y
		avail.sort_custom(func(a,b):
			var gap_a = min(min(a.x - x0, (x0 + w) - (a.x + 1)), min(a.y - z0, (z0 + h) - (a.y + 1)))
			var gap_b = min(min(b.x - x0, (x0 + w) - (b.x + 1)), min(b.y - z0, (z0 + h) - (b.y + 1)))
			if gap_a == gap_b:
				return (a.x + a.y) < (b.x + b.y)
			return gap_a < gap_b
		)
		var placed=0
		for _b in range(sec.max_buildings):
			if avail.is_empty(): break
			var did=false
			var tiles_to_try = min(avail.size(), 12)
			for tile_idx in range(tiles_to_try):
				var try_pos = avail[tile_idx]
				for _a in range(6):
					var mi=building_models[randi()%building_models.size()]
					var ww=randi_range(building_min_size_tiles.x, building_max_size_tiles.x)
					var dd=randi_range(building_min_size_tiles.y, building_max_size_tiles.y)
					if ww+2*building_spacing_tiles>sec.bounds.size.x: continue
					if dd+2*building_spacing_tiles>sec.bounds.size.y: continue
					var rot=get_road_facing_rotation(try_pos, Vector2i(ww,dd), sec)
					var rsz=get_rotated_size(Vector2i(ww,dd), rot)
					if can_place_building_at(try_pos, rsz, sec, grid_data):
						if is_global_occupied(try_pos, rsz, building_spacing_tiles): continue
						var b=create_building_instance(try_pos, Vector2i(ww,dd), rsz, rot, mi)
						all.append(b); sec.occupied_rects.append(b.occupied_rect); mark_global(try_pos, rsz, building_spacing_tiles)
						var to_rm: Array = []
						for i in range(avail.size()):
							var tp=avail[i]
							if tp.x>=try_pos.x - building_spacing_tiles and tp.x<try_pos.x+rsz.x+building_spacing_tiles and tp.y>=try_pos.y - building_spacing_tiles and tp.y<try_pos.y+rsz.y+building_spacing_tiles:
								to_rm.append(i)
						to_rm.reverse()
						for i in to_rm: avail.remove_at(i)
						placed+=1; did=true; break
				if did: break
			if not did and not avail.is_empty(): avail.remove_at(0)
		print(" block %d placed %d/%d" % [sec.id, placed, sec.max_buildings])
	return all

func shuffle_array(a: Array):
	for i in range(a.size()-1,0,-1):
		var j=randi()%(i+1); var t=a[i]; a[i]=a[j]; a[j]=t

func get_rotated_size(s: Vector2i, rot: float) -> Vector2i:
	return Vector2i(s.y,s.x) if int(rot)%360 in [90,270] else s

func get_road_facing_rotation(pos: Vector2i, size: Vector2i, section: Section) -> float:
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
	if gap_west == min_gap: candidates.append(90.0)
	if gap_east == min_gap: candidates.append(270.0)
	if gap_north == min_gap: candidates.append(0.0)
	if gap_south == min_gap: candidates.append(180.0)
	var base = candidates[randi() % candidates.size()]
	return fmod(base + building_front_offset_degrees, 360.0)

func can_place_building_at(pos: Vector2i, size: Vector2i, section: Section, grid_data: Dictionary) -> bool:
	if pos.x+size.x>section.bounds.position.x+section.bounds.size.x or pos.y+size.y>section.bounds.position.y+section.bounds.size.y: return false
	for dx in range(size.x):
		for dz in range(size.y):
			if grid_data.tiles.get(pos+Vector2i(dx,dz))!="ground": return false
	for dx in range(-building_road_gap_tiles, size.x+building_road_gap_tiles):
		for dz in range(-building_road_gap_tiles, size.y+building_road_gap_tiles):
			if dx>=0 and dx<size.x and dz>=0 and dz<size.y: continue
			if grid_data.tiles.get(pos+Vector2i(dx,dz)) in ["road","corner"]: return false
	var rr=Rect2(pos.x-building_spacing_tiles, pos.y-building_spacing_tiles, size.x+building_spacing_tiles*2, size.y+building_spacing_tiles*2)
	for er in section.occupied_rects:
		if rr.intersects(er): return false
	if is_global_occupied(pos,size,building_spacing_tiles): return false
	return true

func is_global_occupied(pos: Vector2i, size: Vector2i, spacing:int) -> bool:
	for dx in range(-spacing,size.x+spacing):
		for dz in range(-spacing,size.y+spacing):
			if _global_occupied.has(pos+Vector2i(dx,dz)): return true
	return false

func mark_global(pos: Vector2i, size: Vector2i, spacing:int):
	for dx in range(-spacing,size.x+spacing):
		for dz in range(-spacing,size.y+spacing):
			_global_occupied[pos+Vector2i(dx,dz)]=true

func create_building_instance(grid_pos: Vector2i, orig: Vector2i, rsz: Vector2i, rot: float, mi: Dictionary) -> BuildingInfo:
	var b=BuildingInfo.new()
	b.model_path=mi.path; b.model_name=mi.name; b.size_tiles=orig; b.rotated_size=rsz; b.grid_position=grid_pos; b.rotation_y=rot
	# FIX grid alignment (same as CityGenerator): buildings centered on tile centers, not straddling
	var wx=(grid_pos.x + (rsz.x - 1)/2.0)*tile_size.x
	var wz=(grid_pos.y + (rsz.y - 1)/2.0)*tile_size.z
	b.position=Vector3(wx, get_building_y(), wz)
	b.occupied_rect=Rect2(grid_pos.x-building_spacing_tiles, grid_pos.y-building_spacing_tiles, rsz.x+building_spacing_tiles*2, rsz.y+building_spacing_tiles*2)
	var msz: Vector3=_model_footprints.get(mi.path, Vector3(2,1,2))
	var fx=rsz.x*tile_size.x; var fz=rsz.y*tile_size.z
	var mx=(fx*0.96)/msz.x if msz.x>0 else 1.0
	var mz=(fz*0.96)/msz.z if msz.z>0 else 1.0
	var maxs=clampf(minf(mx,mz),0.85,1.0)
	var mins=maxf(0.88, maxs-0.08)
	b.scale=Vector3(randf_range(mins,maxs), randf_range(mins,maxs), randf_range(mins,maxs))
	b.mesh_size=msz
	return b

# DECOR
func place_decor_on_ground(grid_data: Dictionary, decor_models:Array, buildings:Array) -> Array:
	var all: Array = []
	if decor_models.is_empty(): return all
	var target=int(grid_data.ground_positions.size()*decor_density)
	target=mini(target, int(grid_data.ground_positions.size()*0.5))
	print("target %d from %d ground" % [target, grid_data.ground_positions.size()])
	var shuf=grid_data.ground_positions.duplicate(); shuffle_array(shuf)
	var building_tiles: Dictionary = {}
	for b in buildings:
		for dx in range(b.rotated_size.x):
			for dz in range(b.rotated_size.y): building_tiles[b.grid_position+Vector2i(dx,dz)]=true
	var placed=0
	for gp in shuf:
		if placed>=target: break
		if decor_density<1.0 and randf()>decor_density: continue
		if not is_valid_decor_position(gp, grid_data, building_tiles, all): continue
		var mi=decor_models[randi()%decor_models.size()]
		var anchor=decor_anchor_points_enabled[randi()%decor_anchor_points_enabled.size()] if decor_anchor_points_enabled.size()>0 else "center"
		var base_pos=Vector3(gp.x*tile_size.x, get_building_y(), gp.y*tile_size.z)
		var off=get_anchor_offset(anchor, tile_size)
		var d=DecorInfo.new(); d.model_path=mi.path; d.model_name=mi.name; d.position=base_pos+off; d.anchor_point=anchor; d.grid_position=gp
		d.occupied_rect=Rect2(gp.x-decor_spacing_tiles, gp.y-decor_spacing_tiles, 1+decor_spacing_tiles*2, 1+decor_spacing_tiles*2)
		d.rotation_y=float((randi()%4)*90)
		var msz: Vector3=_model_footprints.get(mi.path, Vector3(0.5,0.5,0.5))
		var maxs=1.1
		if msz.x>0.6 or msz.z>0.6: maxs=minf(1.15,(tile_size.x*0.85)/maxf(msz.x,msz.z))
		d.scale=Vector3.ONE*randf_range(0.85,maxs)
		all.append(d); building_tiles[gp]=true; placed+=1
	return all

func is_valid_decor_position(pos: Vector2i, grid_data: Dictionary, building_tiles: Dictionary, existing: Array) -> bool:
	if grid_data.tiles.get(pos)!="ground": return false
	if building_tiles.has(pos): return false
	for d in existing:
		if abs(d.grid_position.x-pos.x)<=decor_spacing_tiles and abs(d.grid_position.y-pos.y)<=decor_spacing_tiles: return false
	return true

# HELPERS
func validate_paths(gp:String, rsp:String, rcp:String) -> bool:
	var errs: Array = []
	if not FileAccess.file_exists(gp): errs.append("Ground "+gp)
	if not FileAccess.file_exists(rsp): errs.append("Road "+rsp)
	if use_corner_pieces and not FileAccess.file_exists(rcp):
		push_warning("No corner "+rcp); use_corner_pieces=false
	if not DirAccess.dir_exists_absolute(base_folder_path): errs.append("Base folder "+base_folder_path)
	if generate_buildings and not DirAccess.dir_exists_absolute(building_models_folder): errs.append("Building folder")
	if generate_decor and not DirAccess.dir_exists_absolute(decor_models_folder): errs.append("Decor folder")
	if errs.size()>0:
		for e in errs: print("❌ "+e); push_error(e)
		return false
	return true

func load_models(gp:String, rsp:String, rcp:String) -> Dictionary:
	var m={"ground":null,"road_straight":null,"road_corner":null,"buildings":[],"decor":[]}
	m.ground=load(gp); m.road_straight=load(rsp)
	if use_corner_pieces: m.road_corner=load(rcp)
	if not m.ground or not m.road_straight: print("❌ load base"); return {}
	print(" base loaded")
	if generate_buildings:
		var d=DirAccess.open(building_models_folder)
		if d:
			d.list_dir_begin(); var f=d.get_next(); var c=0
			while f!="":
				if f.ends_with(".glb") and not d.current_is_dir():
					var fp=building_models_folder.path_join(f); var sc=load(fp)
					if sc: m.buildings.append({"path":fp,"scene":sc,"name":extract_model_name(f)}); c+=1
				f=d.get_next()
			print(" %d buildings" % c)
	if generate_decor:
		var d2=DirAccess.open(decor_models_folder)
		if d2:
			d2.list_dir_begin(); var f=d2.get_next(); var c2=0
			while f!="":
				if f.ends_with(".glb") and not d2.current_is_dir():
					var fp=decor_models_folder.path_join(f); var sc=load(fp)
					if sc: m.decor.append({"path":fp,"scene":sc,"name":extract_model_name(f)}); c2+=1
				f=d2.get_next()
			print(" %d decor" % c2)
	return m

func calculate_lane_positions(n:int, sz:int) -> PackedInt32Array:
	var p=PackedInt32Array()
	if n<=0: return p
	var s=float(sz)/(n+1)
	for i in range(1,n+1): p.append(int(round(s*i)))
	return p

func get_anchor_offset(a:String, t:Vector3) -> Vector3:
	match a:
		"north": return Vector3(0,0,-t.z/3)
		"south": return Vector3(0,0,t.z/3)
		"east": return Vector3(t.x/3,0,0)
		"west": return Vector3(-t.x/3,0,0)
		"northeast": return Vector3(t.x/3,0,-t.z/3)
		"northwest": return Vector3(-t.x/3,0,-t.z/3)
		"southeast": return Vector3(t.x/3,0,t.z/3)
		"southwest": return Vector3(-t.x/3,0,t.z/3)
		_: return Vector3.ZERO

# SCENE
func create_and_save_scene(grid_data:Dictionary, buildings:Array, decor:Array, models:Dictionary):
	var cnt={"ground":0,"roads":0,"corners":0,"buildings":0,"decor":0}
	var root=Node3D.new(); root.name="GeneratedCity"
	var gn=root; var rn=root; var bn=root; var dn=root
	if create_organization_nodes:
		gn=Node3D.new(); gn.name="Ground"; root.add_child(gn); gn.owner=root
		rn=Node3D.new(); rn.name="Roads"; root.add_child(rn); rn.owner=root
		bn=Node3D.new(); bn.name="Buildings"; root.add_child(bn); bn.owner=root
		dn=Node3D.new(); dn.name="Decor"; root.add_child(dn); dn.owner=root
	cnt.ground=create_tiles_from_grid(grid_data,"ground",models.ground,gn,root)
	cnt.roads=create_tiles_from_grid(grid_data,"road",models.road_straight,rn,root)
	if use_corner_pieces and models.road_corner: cnt.corners=create_tiles_from_grid(grid_data,"corner",models.road_corner,rn,root)
	if generate_buildings and buildings.size()>0: cnt.buildings=create_building_instances(buildings,models.buildings,bn,root)
	if generate_decor and decor.size()>0: cnt.decor=create_decor_instances(decor,models.decor,dn,root)
	save_scene_to_file(root,cnt)

func create_tiles_from_grid(grid_data:Dictionary, typ:String, scene:PackedScene, parent:Node3D, root:Node) -> int:
	var positions: Array = []
	match typ:
		"ground": positions=grid_data.ground_positions
		"road": positions=grid_data.road_positions
		"corner": positions=grid_data.corner_positions
	var c=0; var cc={}
	for gp in positions:
		var wp=Vector3(gp.x*tile_size.x,0,gp.y*tile_size.z)
		var inst=scene.instantiate(); inst.position=wp
		if typ=="road": inst.rotation_degrees.y=determine_road_rotation(gp,typ,grid_data)+90
		if typ=="corner": inst.rotation_degrees.y=determine_road_rotation(gp,typ,grid_data)+180
		var nm=extract_model_name(scene.resource_path.get_file())
		inst.name="%s_%d" % [nm, cc.get(nm,0)]; cc[nm]=cc.get(nm,0)+1
		parent.add_child(inst); inst.owner=root; c+=1
	return c

func determine_road_rotation(gp:Vector2i, typ:String, grid_data:Dictionary) -> float:
	if typ=="corner":
		var mn=-1; var mx=grid_size_tiles.x
		if gp==Vector2i(mn,mn): return 180
		if gp==Vector2i(mx,mn): return 90
		if gp==Vector2i(mx,mx): return 0
		if gp==Vector2i(mn,mx): return 270
	var l=grid_data.tiles.get(Vector2i(gp.x-1,gp.y)) in ["road","corner"]
	var r=grid_data.tiles.get(Vector2i(gp.x+1,gp.y)) in ["road","corner"]
	var t=grid_data.tiles.get(Vector2i(gp.x,gp.y-1)) in ["road","corner"]
	var b=grid_data.tiles.get(Vector2i(gp.x,gp.y+1)) in ["road","corner"]
	return 0 if (l or r) and not (t or b) else 90

func create_building_instances(buildings:Array, models:Array, parent:Node3D, root:Node) -> int:
	var by: Dictionary = {}
	for b in buildings:
		if not by.has(b.model_name): by[b.model_name]=[]
		by[b.model_name].append(b)
	var c=0
	for mn in by:
		var sc=null
		for mi in models:
			if mi.name==mn: sc=mi.scene; break
		if sc:
			for i in range(by[mn].size()):
				var b=by[mn][i]; var inst=sc.instantiate(); inst.position=b.position; inst.rotation_degrees.y=b.rotation_y; inst.scale=b.scale; inst.name="%s_%d" % [mn,i]; parent.add_child(inst); inst.owner=root; c+=1
	return c

func create_decor_instances(items:Array, models:Array, parent:Node3D, root:Node) -> int:
	var by: Dictionary = {}
	for d in items:
		if not by.has(d.model_name): by[d.model_name]=[]
		by[d.model_name].append(d)
	var c=0
	for mn in by:
		var sc=null
		for mi in models:
			if mi.name==mn: sc=mi.scene; break
		if sc:
			for i in range(by[mn].size()):
				var d=by[mn][i]; var inst=sc.instantiate(); inst.position=d.position; inst.rotation_degrees.y=d.rotation_y; inst.scale=d.scale; inst.name="%s_%d" % [mn,i]; parent.add_child(inst); inst.owner=root; c+=1
	return c

func save_scene_to_file(root:Node, cnt:Dictionary):
	print("\n💾 %s" % output_scene_path)
	var ps=PackedScene.new()
	if ps.pack(root)!=OK: print("❌ pack"); root.queue_free(); return
	if ResourceSaver.save(ps, output_scene_path)!=OK: print("❌ save"); root.queue_free(); return
	print("✅ Ground %d Roads %d Corners %d Buildings %d Decor %d TOTAL %d @ %.3f" % [cnt.ground,cnt.roads,cnt.corners,cnt.buildings,cnt.decor,cnt.ground+cnt.roads+cnt.corners+cnt.buildings+cnt.decor, base_tile_height+height_offset])
	get_editor_interface().open_scene_from_path(output_scene_path)
	root.queue_free()

func extract_model_name(f:String) -> String: return f.replace(".glb","").replace(".","_")
