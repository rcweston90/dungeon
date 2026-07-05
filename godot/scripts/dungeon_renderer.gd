class_name DungeonRenderer
extends Node3D

## Presentation layer. Consumes the pure-data dungeon Dictionary and owns all
## Godot render objects. Port of buildDungeonScene() from index.html.
##
## One MultiMeshInstance3D per kind (floor/wall/pillar/bracket/flame/debris/
## chest/marker/crystal) => ~9 draw calls for level geometry. <= 12 OmniLights,
## shadows disabled. Freeing the node (queue_free) disposes everything.

const VOID := 0
const FLOOR := 1
const WALL := 2

var point_light_count: int = 0
var draw_calls: int = 0

var _kinds := {}                 # name -> kind dict (see _make_kind)
var _point_lights: Array = []    # [{light, base, phase}]
var _flames: Array = []          # [{kind, i, phase}]
var _overlays := {}              # name -> MeshInstance3D
var _floor_colors: PackedColorArray = PackedColorArray()
var _heat_colors: PackedColorArray = PackedColorArray()
var _floor_meta: Array = []      # per floor instance {bfsN, dx, dy, isCorr}
var _heat_on := false

var _rooms: Array
var _room_by_id: Array
var _W: int
var _H: int
var _max_depth: int
var _seed: int

# --- build animation state ---
var _anim_active := false
var _anim_t := 0.0
const _PH := [0.7, 1.0, 1.3, 1.6, 1.1, 0.9]  # scatter, separate, graph, flood, walls, props
var _ph_end: Array = []

const TIER_COLOR := {"normal": Color("b43a4a"), "elite": Color("ff8822"), "boss": Color("aa33ff")}

# ============================================================================
func build(dungeon: Dictionary) -> void:
	_rooms = dungeon.rooms
	_room_by_id = dungeon.rooms  # rooms are id-indexed and contiguous
	_W = dungeon.W
	_H = dungeon.H
	_max_depth = dungeon.stats.maxDepth
	_seed = int(dungeon.params.seed)
	var acc := 0.0
	for v in _PH:
		acc += v
		_ph_end.append(acc)

	var grid: PackedByteArray = dungeon.grid
	var bfs: PackedInt32Array = dungeon.bfs
	var roomid: PackedInt32Array = dungeon.roomIdGrid
	var corridor: PackedByteArray = dungeon.corridorMask
	var max_bfs: int = dungeon.stats.maxBfs

	# --- count instances up front ---
	var n_floor := 0
	var n_wall := 0
	for i in range(grid.size()):
		if grid[i] == FLOOR:
			n_floor += 1
		elif grid[i] == WALL:
			n_wall += 1
	var by_kind := func(k):
		var out: Array = []
		for p in dungeon.props:
			if p.kind == k:
				out.append(p)
		return out
	var pillars: Array = by_kind.call("pillar")
	var torches: Array = by_kind.call("torch")
	var braziers: Array = by_kind.call("brazier")
	var debris: Array = by_kind.call("debris")
	var chests: Array = by_kind.call("chest")
	var crystals_p: Array = by_kind.call("crystal")
	var portals: Array = by_kind.call("portal")

	# --- the nine instanced meshes ---
	_kinds["floor"] = _make_kind(_box(Vector3(1, 0.14, 1)), _lambert(), n_floor, true)
	_kinds["wall"] = _make_kind(_box(Vector3(1, 1, 1)), _lambert(), n_wall, true)
	_kinds["pillar"] = _make_kind(_cyl(0.26, 0.34, 2.3, 6), _lambert(), pillars.size() + braziers.size(), true)
	_kinds["bracket"] = _make_kind(_box(Vector3(0.16, 0.5, 0.16)), _lambert(), torches.size(), true)
	_kinds["flame"] = _make_kind(_cyl(0.0, 0.15, 0.42, 6), _unlit(), torches.size() + braziers.size(), true)
	_kinds["debris"] = _make_kind(_box(Vector3(0.34, 0.22, 0.3)), _lambert(), debris.size(), true)
	_kinds["chest"] = _make_kind(_box(Vector3(0.85, 0.62, 0.55)), _lambert(), chests.size(), true)
	_kinds["marker"] = _make_kind(_cyl(0.0, 0.22, 0.55, 4), _unlit(), dungeon.spawns.size(), true)
	_kinds["crystal"] = _make_kind(_gem(0.34), _unlit(), crystals_p.size() + portals.size(), true)
	draw_calls = _kinds.size()

	# --- floors: baked AO + tint ---
	_floor_colors.resize(n_floor)
	_heat_colors.resize(n_floor)
	for y in range(_H):
		for x in range(_W):
			var i := y * _W + x
			if grid[i] != FLOOR:
				continue
			var adj_w := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and ny >= 0 and nx < _W and ny < _H and grid[ny * _W + nx] == WALL:
						adj_w += 1
			var ao: float = 1.0 - 0.09 * min(adj_w, 4)
			var noise := 1.0 + (_hash01(x, y, _seed) - 0.5) * 0.10
			var is_corr := corridor[i] == 1
			var r := 0.0
			var g := 0.0
			var b := 0.0
			if is_corr:
				r = 0.34; g = 0.34; b = 0.34
			else:
				r = 0.42; g = 0.41; b = 0.45
				if roomid[i] >= 0:
					var t: Color = _room_by_id[roomid[i]].tint
					r += (t.r - r) * 0.18; g += (t.g - g) * 0.18; b += (t.b - b) * 0.18
			r *= ao * noise; g *= ao * noise; b *= ao * noise
			var col := Color(min(1.0, r), min(1.0, g), min(1.0, b))
			var idx := _add_inst(_kinds.floor, x + 0.5, -0.07, y + 0.5, 0.0, 1, 1, 1,
				(float(bfs[i]) / max_bfs) if bfs[i] >= 0 else 1.0, col)
			_floor_colors[idx] = col
			var room = _room_by_id[roomid[i]] if (roomid[i] >= 0 and not is_corr) else null
			var heat: float = room.difficulty if room != null else ((0.15 + 0.85 * float(bfs[i]) / max_bfs) if bfs[i] >= 0 else 0.0)
			_heat_colors[idx] = DungeonGen._hsl2rgb(0.66 * (1.0 - heat), 0.85, 0.32 + 0.2 * heat)
			_floor_meta.append({
				"bfsN": (float(bfs[i]) / max_bfs) if bfs[i] >= 0 else 1.0,
				"dx": (room.scatterX - room.cx) if room != null else 0.0,
				"dy": (room.scatterY - room.cy) if room != null else 0.0,
				"isCorr": is_corr,
			})

	# --- walls: seeded height jitter ---
	for y in range(_H):
		for x in range(_W):
			var i := y * _W + x
			if grid[i] != WALL:
				continue
			var h := 2.0 + (_hash01(x, y, _seed + 7) - 0.5) * 0.5
			var min_n := 2.0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and ny >= 0 and nx < _W and ny < _H:
						var j := ny * _W + nx
						if grid[j] == FLOOR and bfs[j] >= 0:
							min_n = min(min_n, float(bfs[j]) / max_bfs)
			var shade := 0.62 + _hash01(x, y, _seed + 13) * 0.22
			_add_inst(_kinds.wall, x + 0.5, h / 2.0, y + 0.5, 0.0, 1, h, 1, min_n,
				Color(0.46 * shade, 0.47 * shade, 0.55 * shade))

	# --- props ---
	for p in pillars:
		_add_inst(_kinds.pillar, p.x + 0.5, 1.15 * p.scale, p.y + 0.5, p.rot, p.scale, p.scale, p.scale,
			_depth_n(p.roomId), Color("9aa0b4"))
	for p in braziers:
		_add_inst(_kinds.pillar, p.x + 0.5, 0.35, p.y + 0.5, 0.0, 1.1, 0.3, 1.1, _depth_n(p.roomId), Color("6a4a3a"))
		var fi := _add_inst(_kinds.flame, p.x + 0.5, 0.95, p.y + 0.5, 0.0, 1.5, 1.5, 1.5, _depth_n(p.roomId), Color("ff6a28"))
		_flames.append({"kind": "flame", "i": fi, "phase": fmod(p.x * 7 + p.y * 13, TAU)})
	for p in torches:
		var ox := sin(p.rot)
		var oz := cos(p.rot)
		_add_inst(_kinds.bracket, p.x + 0.5 + ox * 0.44, 1.3, p.y + 0.5 + oz * 0.44, p.rot, 1, 1, 1, _depth_n(p.roomId), Color("2c2620"))
		var fi := _add_inst(_kinds.flame, p.x + 0.5 + ox * 0.38, 1.72, p.y + 0.5 + oz * 0.38, 0.0, 1, 1, 1, _depth_n(p.roomId), Color("ffa544"))
		_flames.append({"kind": "flame", "i": fi, "phase": fmod(p.x * 11 + p.y * 5, TAU)})
	for p in debris:
		_add_inst(_kinds.debris, p.x + 0.5 + sin(p.rot) * 0.2, 0.1 * p.scale, p.y + 0.5 + cos(p.rot) * 0.2,
			p.rot, p.scale, p.scale, p.scale, _depth_n(p.roomId), Color("59524a"))
	for p in chests:
		_add_inst(_kinds.chest, p.x + 0.5, 0.31, p.y + 0.5, p.rot, 1, 1, 1, _depth_n(p.roomId), Color("c8942f"))
	for p in crystals_p:
		_add_inst(_kinds.crystal, p.x + 0.5, 1.0, p.y + 0.5, p.rot, p.scale, p.scale * 1.6, p.scale, _depth_n(p.roomId), Color("55ffdd"))
	for p in portals:
		var ox := sin(p.rot) * 1.5
		var oz := cos(p.rot) * 1.5
		_add_inst(_kinds.crystal, p.x + 0.5 + ox, 0.5, p.y + 0.5 + oz, p.rot, p.scale, p.scale * 1.4, p.scale, 0.0, Color("5c8cff"))
	for s in dungeon.spawns:
		var sc := 1.8 if s.tier == "boss" else (1.3 if s.tier == "elite" else 1.0)
		_add_inst(_kinds.marker, s.x + 0.5, 0.34, s.y + 0.5, 0.0, sc, sc, sc, _depth_n(s.roomId), TIER_COLOR[s.tier])

	for k in _kinds.values():
		_write_all(k)

	# --- lights: budgeted OmniLights (shadows off) ---
	var ent_r: Dictionary = _room_by_id[dungeon.debug.entrance]
	var boss_r: Dictionary = _room_by_id[dungeon.debug.boss]
	_add_point(Color("5588ff"), ent_r.cx + 0.5, 2.2, ent_r.cy + 0.5, 2.6, 11.0)
	_add_point(Color("ff4422"), boss_r.cx + 0.5, 2.6, boss_r.cy + 0.5, 3.0, 15.0)
	var shrine = null
	for r in _rooms:
		if r.type == "shrine":
			shrine = r; break
	if shrine != null:
		_add_point(Color("55ffcc"), shrine.cx + 0.5, 2.0, shrine.cy + 0.5, 2.4, 10.0)
	# Farthest-point sampling over torch/brazier positions for the remaining budget.
	var cand: Array = []
	for p in torches:
		cand.append(Vector2(p.x + 0.5, p.y + 0.5))
	for p in braziers:
		cand.append(Vector2(p.x + 0.5, p.y + 0.5))
	var budget := 12 - _point_lights.size()
	var chosen: Array = []
	for pl in _point_lights:
		chosen.append(Vector2(pl.light.position.x, pl.light.position.z))
	for k in range(budget):
		if cand.is_empty():
			break
		var bi := 0
		var bd := -1.0
		for i in range(cand.size()):
			var m := INF
			for c in chosen:
				m = min(m, (cand[i].x - c.x) * (cand[i].x - c.x) + (cand[i].y - c.y) * (cand[i].y - c.y))
			if m > bd:
				bd = m; bi = i
		var cc: Vector2 = cand[bi]
		cand.remove_at(bi)
		chosen.append(cc)
		_add_point(Color("ff8c3a"), cc.x, 1.9, cc.y, 2.5, 9.0)
	point_light_count = _point_lights.size()

	# --- debug overlays ---
	_overlays["delaunay"] = _make_lines(_edge_pairs(dungeon.debug.delaunay), Color("7a5faa"), 0.28, 2.6, false)
	var mst_pairs: Array = []
	var loop_pairs: Array = []
	for e in dungeon.edges:
		if e.isLoop:
			loop_pairs.append(Vector2i(e.a, e.b))
		else:
			mst_pairs.append(Vector2i(e.a, e.b))
	_overlays["mst"] = _make_lines(mst_pairs, Color("f0f0f8"), 0.85, 2.75, false)
	_overlays["loops"] = _make_lines(loop_pairs, Color("33e0ff"), 0.95, 2.85, false)
	_overlays["critical"] = _make_lines(_strip_pairs(dungeon.debug.criticalRooms), Color("ff3344"), 1.0, 2.95, true)

# ============================================================================
# Kind / instance helpers
# ============================================================================
func _make_kind(mesh: Mesh, mat: Material, capacity: int, _dynamic: bool) -> Dictionary:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = max(0, capacity)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	# Plain Arrays (reference type) rather than PackedFloat32Array so that
	# appending through the Dictionary field mutates in place (packed arrays are
	# copy-on-write and can silently no-op when nested in a container).
	return {
		"mmi": mmi, "mm": mm, "cap": max(0, capacity), "n": 0,
		"pos": [], "rot": [], "scl": [], "key": [],
	}

func _add_inst(kd: Dictionary, x: float, y: float, z: float, ry: float, sx: float, sy: float, sz: float, key: float, color: Color) -> int:
	var i: int = kd.n
	kd.n += 1
	kd.pos.append(x); kd.pos.append(y); kd.pos.append(z)
	kd.rot.append(ry)
	kd.scl.append(sx); kd.scl.append(sy); kd.scl.append(sz)
	kd.key.append(key)
	kd.mm.set_instance_color(i, color)
	return i

func _compose(kd: Dictionary, i: int, s_mul: float, y_off: float, sy_mul: float) -> Transform3D:
	var basis := Basis(Vector3.UP, kd.rot[i]).scaled(Vector3(
		max(1e-4, kd.scl[i * 3] * s_mul),
		max(1e-4, kd.scl[i * 3 + 1] * s_mul * sy_mul),
		max(1e-4, kd.scl[i * 3 + 2] * s_mul)))
	return Transform3D(basis, Vector3(kd.pos[i * 3], kd.pos[i * 3 + 1] + y_off, kd.pos[i * 3 + 2]))

func _write_inst(kd: Dictionary, i: int, s_mul: float, y_off: float, sy_mul: float) -> void:
	kd.mm.set_instance_transform(i, _compose(kd, i, s_mul, y_off, sy_mul))

func _write_all(kd: Dictionary) -> void:
	for i in range(kd.n):
		_write_inst(kd, i, 1.0, 0.0, 1.0)

# ============================================================================
# Mesh / material factories
# ============================================================================
func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m

func _cyl(top: float, bottom: float, height: float, seg: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = seg
	m.rings = 0
	return m

func _gem(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 4
	m.rings = 2
	return m

func _lambert() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m

func _unlit() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

# ============================================================================
# Lights
# ============================================================================
func _add_point(color: Color, x: float, y: float, z: float, energy: float, dist: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = dist
	l.shadow_enabled = false
	l.position = Vector3(x, y, z)
	add_child(l)
	_point_lights.append({"light": l, "base": energy, "phase": fmod(x * 3.1 + z * 1.7, TAU)})

# ============================================================================
# Overlays
# ============================================================================
func _edge_pairs(edges: Array) -> Array:
	var out: Array = []
	for e in edges:
		out.append(Vector2i(e.x, e.y))
	return out

func _strip_pairs(ids: Array) -> Array:
	var out: Array = []
	for k in range(ids.size() - 1):
		out.append(Vector2i(ids[k], ids[k + 1]))
	return out

func _make_lines(pairs: Array, color: Color, base_alpha: float, y_lift: float, _strip: bool) -> MeshInstance3D:
	var verts := PackedVector3Array()
	for pr in pairs:
		var a: Dictionary = _room_by_id[pr.x]
		var b: Dictionary = _room_by_id[pr.y]
		verts.append(Vector3(a.cx + 0.5, y_lift, a.cy + 0.5))
		verts.append(Vector3(b.cx + 0.5, y_lift, b.cy + 0.5))
	var mesh := ArrayMesh.new()
	if verts.size() >= 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(color.r, color.g, color.b, base_alpha)
	mat.render_priority = 10
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, mat)
	mi.visible = false
	mi.set_meta("base_alpha", base_alpha)
	mi.set_meta("mat", mat)
	add_child(mi)
	return mi

func set_overlay(name_key: String, on: bool) -> void:
	if _overlays.has(name_key):
		_overlays[name_key].visible = on

func set_heatmap(on: bool) -> void:
	_heat_on = on
	var kd: Dictionary = _kinds.floor
	var src := _heat_colors if on else _floor_colors
	for i in range(kd.n):
		kd.mm.set_instance_color(i, src[i])

# ============================================================================
# Build animation
# ============================================================================
func start_build_animation() -> void:
	_anim_active = true
	_anim_t = 0.0
	for name_key in ["pillar", "bracket", "flame", "debris", "chest", "marker", "crystal"]:
		var kd: Dictionary = _kinds[name_key]
		for i in range(kd.n):
			_write_inst(kd, i, 0.0, 0.0, 1.0)
	for pl in _point_lights:
		pl.light.light_energy = 0.0
	for o in _overlays.values():
		o.visible = true
		o.get_meta("mat").albedo_color.a = 0.0

func _finish_build_animation(overlay_state: Dictionary) -> void:
	_anim_active = false
	for kd in _kinds.values():
		_write_all(kd)
	for name_key in _overlays:
		var o: MeshInstance3D = _overlays[name_key]
		o.get_meta("mat").albedo_color.a = o.get_meta("base_alpha")
		o.visible = overlay_state.get(name_key, false)
	for pl in _point_lights:
		pl.light.light_energy = pl.base

func _step_build_animation(dt: float, overlay_state: Dictionary) -> void:
	_anim_t += dt
	var t := _anim_t
	if t >= _ph_end[5]:
		_finish_build_animation(overlay_state)
		return
	var fl: Dictionary = _kinds.floor
	var wl: Dictionary = _kinds.wall
	if t < _ph_end[1]:
		var k := 0.0 if t < _ph_end[0] else _smooth01((t - _ph_end[0]) / _PH[1])
		for i in range(fl.n):
			var m: Dictionary = _floor_meta[i]
			if m.isCorr:
				_write_inst(fl, i, 0.0, 0.0, 1.0)
				continue
			var basis := Basis().scaled(Vector3.ONE)
			fl.mm.set_instance_transform(i, Transform3D(basis, Vector3(
				fl.pos[i * 3] + m.dx * (1.0 - k), fl.pos[i * 3 + 1], fl.pos[i * 3 + 2] + m.dy * (1.0 - k))))
		for i in range(wl.n):
			_write_inst(wl, i, 1.0, 0.0, 1e-4)
	elif t < _ph_end[2]:
		var k: float = (t - _ph_end[1]) / _PH[2]
		_set_alpha("delaunay", 0.28 * _smooth01(k / 0.4))
		_set_alpha("mst", 0.85 * _smooth01((k - 0.35) / 0.4))
		_set_alpha("loops", 0.95 * _smooth01((k - 0.6) / 0.4))
		_set_alpha("critical", _smooth01((k - 0.6) / 0.4))
	elif t < _ph_end[3]:
		var k: float = (t - _ph_end[2]) / _PH[3]
		for i in range(fl.n):
			var m: Dictionary = _floor_meta[i]
			var s := _smooth01((k * 1.25 - m.bfsN) * 6.0) if m.isCorr else 1.0
			_write_inst(fl, i, max(1e-4, s), (1.0 - s) * -0.4, 1.0)
	elif t < _ph_end[4]:
		var k: float = (t - _ph_end[3]) / _PH[4]
		for i in range(wl.n):
			var s := _smooth01((k * 1.3 - wl.key[i]) * 5.0)
			_write_inst(wl, i, 1.0, -(1.0 - s) * wl.scl[i * 3 + 1] / 2.0, max(1e-4, s))
	else:
		var k: float = (t - _ph_end[4]) / _PH[5]
		for name_key in ["pillar", "bracket", "flame", "debris", "chest", "marker", "crystal"]:
			var kd: Dictionary = _kinds[name_key]
			for i in range(kd.n):
				var s := _smooth01((k * 1.35 - kd.key[i]) * 5.0)
				_write_inst(kd, i, s, 0.0, 1.0)
		for pl in _point_lights:
			pl.light.light_energy = pl.base * _smooth01(k)

func _set_alpha(name_key: String, a: float) -> void:
	if _overlays.has(name_key):
		_overlays[name_key].get_meta("mat").albedo_color.a = a

func is_animating() -> bool:
	return _anim_active

# ============================================================================
# Per-frame update: flicker + animation
# ============================================================================
func update(time: float, dt: float, overlay_state: Dictionary) -> void:
	if _anim_active:
		_step_build_animation(dt, overlay_state)
		if _anim_active:
			return
	for pl in _point_lights:
		pl.light.light_energy = pl.base * (0.86 + 0.10 * sin(time * 9.3 + pl.phase) + 0.06 * sin(time * 23.7 + pl.phase * 2.3))
	var fk: Dictionary = _kinds.flame
	for f in _flames:
		var jitter := 0.86 + 0.16 * sin(time * 11.0 + f.phase) + 0.08 * sin(time * 27.0 + f.phase * 1.7)
		fk.mm.set_instance_transform(f.i, _compose(fk, f.i, jitter, 0.03 * sin(time * 13.0 + f.phase), 1.1))

# ============================================================================
# Static helpers
# ============================================================================
func _depth_n(room_id: int) -> float:
	if room_id >= 0 and room_id < _room_by_id.size():
		return float(_room_by_id[room_id].depth) / _max_depth
	return 0.0

static func _hash01(x: int, y: int, seed_value: int) -> float:
	var v := sin(x * 127.1 + y * 311.7 + seed_value * 0.1731) * 43758.5453
	return v - floor(v)

static func _smooth01(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	return t * t * (3.0 - 2.0 * t)
