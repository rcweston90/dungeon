class_name DungeonGen
extends RefCounted

## Pure-data procedural dungeon generator. No rendering references.
## Faithful port of generateDungeon() from the Three.js prototype (index.html).
##
## Public API:
##   DungeonGen.generate(params: Dictionary) -> Dictionary   # the "dungeon"
##
## params keys: seed:int, roomCount:int, loopChance:float, decorDensity:float, theme:String
##
## The returned dungeon Dictionary matches the data contract:
##   params, name, W, H, grid(PackedByteArray), bfs(PackedInt32Array),
##   rooms(Array[Dictionary]), edges(Array[Dictionary]), doorways(Array[Vector2i]),
##   corridorCells(Array[Vector2i]), props(Array[Dictionary]), spawns(Array[Dictionary]),
##   roomIdGrid(PackedInt32Array), corridorMask(PackedByteArray), stats, debug

const VOID := 0
const FLOOR := 1
const WALL := 2

# --- instance state, reset per generation attempt ---------------------------
var _W: int = 0
var _H: int = 0
var _grid: PackedByteArray
var _corridor: PackedByteArray
var _roomid: PackedInt32Array
var _occ: PackedByteArray
var _doorway_set: PackedByteArray
var _props: Array = []
var _rng: DungeonRng

const NAME_TABLES := {
	"crypt": {
		"adj": ["Ashen", "Sunken", "Howling", "Blighted", "Silent", "Crimson", "Withered", "Umbral", "Forgotten", "Rotting", "Gilded", "Frozen"],
		"place": ["Vaults", "Crypts", "Halls", "Catacombs", "Depths", "Warrens", "Sanctum", "Barrows", "Galleries", "Ossuary", "Cells", "Reliquary"],
		"s1": ["Vor", "Mal", "Zar", "Kha", "Ul", "Thra", "Mor", "Bel", "Az", "Gor", "Nek", "Dra"],
		"s2": ["'gul", "gath", "zul", "mir", "doth", "krag", "noth", "'vek", "rim", "thul", "maw", "xis"],
	},
}

const TYPE_HUE := {"entrance": 0.58, "boss": 0.0, "elite": 0.06, "treasure": 0.115, "shrine": 0.46}

# ============================================================================
# Public entry: retry loop with derived seeds
# ============================================================================
static func generate(user_params: Dictionary) -> Dictionary:
	var params := {
		"seed": 1, "roomCount": 42, "loopChance": 0.15, "decorDensity": 0.6, "theme": "crypt",
	}
	for k in user_params:
		params[k] = user_params[k]

	var t0 := Time.get_ticks_usec()
	var best: Dictionary = {}
	var best_valid := false
	var best_score := -1.0
	for attempt in range(5):
		var seed_value := (int(params.seed) + attempt * 0x9E3779B9) & 0xFFFFFFFF
		var gen := DungeonGen.new()
		var res := gen._try_generate(params, seed_value, attempt)
		if res.is_empty() or res.dungeon == null:
			continue
		if best.is_empty() or res.score > best_score:
			best = res.dungeon
			best_score = res.score
			best_valid = res.valid
		if res.valid:
			best = res.dungeon
			best_valid = true
			break

	best.stats.genMs = float(Time.get_ticks_usec() - t0) / 1000.0
	best.stats.valid = best_valid
	return best

# ============================================================================
# One full generation attempt
# ============================================================================
func _try_generate(params: Dictionary, seed_value: int, attempt: int) -> Dictionary:
	_rng = DungeonRng.new(seed_value)
	var rng := _rng
	var room_count := int(params.roomCount)

	# --- Stage: room scatter ------------------------------------------------
	var cand_count := int(ceil(room_count * 1.4))
	var radius := sqrt(float(room_count)) * 5.2
	var rooms: Array = []
	for i in range(cand_count):
		var ang := rng.rf(0.0, TAU)
		var rad := sqrt(rng.next()) * radius
		var cx := cos(ang) * rad * 1.25
		var cy := sin(ang) * rad * 0.85
		var t := rng.next()
		var arch := "small"
		var lo := 5
		var hi := 7
		if t < 0.45:
			arch = "small"; lo = 5; hi = 7
		elif t < 0.85:
			arch = "medium"; lo = 8; hi = 12
		else:
			arch = "large"; lo = 13; hi = 18
		var w := rng.ri(lo, hi)
		var h := rng.ri(lo, hi)
		var t2 := rng.next()
		var shape := "rect" if t2 < 0.60 else ("ellipse" if t2 < 0.82 else "octagon")
		rooms.append({
			"id": i, "cx": cx, "cy": cy, "w": w, "h": h, "shape": shape, "arch": arch,
			"scatterX": cx, "scatterY": cy,
		})

	# Force >= 2 large rooms (promote biggest non-large candidates, deterministic).
	var large_n := 0
	for r in rooms:
		if r.arch == "large":
			large_n += 1
	if large_n < 2:
		var non_large: Array = []
		for r in rooms:
			if r.arch != "large":
				non_large.append(r)
		non_large.sort_custom(func(a, b):
			var aa: int = a.w * a.h
			var ba: int = b.w * b.h
			if aa != ba:
				return aa > ba
			return a.id < b.id)
		var k := 0
		while k < non_large.size() and large_n < 2:
			var r: Dictionary = non_large[k]
			r.arch = "large"; r.w = rng.ri(13, 18); r.h = rng.ri(13, 18)
			large_n += 1; k += 1

	# --- Stage: separation (AABB push-apart, pad 2, cap 300) ----------------
	# Hoist positions/sizes into flat packed arrays: this O(n^2 x iters) loop is
	# the hot path and Dictionary field access is ~10x slower than packed indexing.
	# Math and iteration order are identical, so the result is bit-for-bit the same.
	const PAD := 2.0
	var rn := rooms.size()
	var cxs := PackedFloat64Array(); cxs.resize(rn)
	var cys := PackedFloat64Array(); cys.resize(rn)
	var ws := PackedFloat64Array(); ws.resize(rn)
	var hs := PackedFloat64Array(); hs.resize(rn)
	for i in range(rn):
		cxs[i] = rooms[i].cx; cys[i] = rooms[i].cy
		ws[i] = rooms[i].w; hs[i] = rooms[i].h
	for iter in range(300):
		var moved := false
		for i in range(rn):
			for j in range(i + 1, rn):
				var ox: float = (ws[i] + ws[j]) / 2.0 + PAD - abs(cxs[i] - cxs[j])
				var oy: float = (hs[i] + hs[j]) / 2.0 + PAD - abs(cys[i] - cys[j])
				if ox > 0.0 and oy > 0.0:
					moved = true
					# 0.05 overshoot leaves slack so neighbor nudges don't re-trigger.
					if ox < oy:
						var s: float = (-1.0 if cxs[i] < cxs[j] else 1.0) * (ox / 2.0 + 0.05)
						cxs[i] += s; cxs[j] -= s
					else:
						var s: float = (-1.0 if cys[i] < cys[j] else 1.0) * (oy / 2.0 + 0.05)
						cys[i] += s; cys[j] -= s
		if not moved:
			break
	for i in range(rn):
		rooms[i].cx = float(roundi(cxs[i]))
		rooms[i].cy = float(roundi(cys[i]))

	# Cull smallest overflow down to room_count (tie-break by id).
	if rooms.size() > room_count:
		var order := rooms.duplicate()
		order.sort_custom(func(a, b):
			var aa: int = a.w * a.h
			var ba: int = b.w * b.h
			if aa != ba:
				return aa < ba
			return a.id < b.id)
		var drop := {}
		for di in range(rooms.size() - room_count):
			drop[order[di].id] = true
		var kept: Array = []
		for r in rooms:
			if not drop.has(r.id):
				kept.append(r)
		rooms = kept
	for i in range(rooms.size()):
		rooms[i].id = i
	var n := rooms.size()

	# --- Grid frame ---------------------------------------------------------
	const MARGIN := 4
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for r in rooms:
		var x0f: float = r.cx - (int(r.w) >> 1)
		var y0f: float = r.cy - (int(r.h) >> 1)
		min_x = min(min_x, x0f); min_y = min(min_y, y0f)
		max_x = max(max_x, x0f + r.w - 1); max_y = max(max_y, y0f + r.h - 1)
	var shift_x := MARGIN - int(min_x)
	var shift_y := MARGIN - int(min_y)
	_W = int(max_x - min_x + 1) + MARGIN * 2
	_H = int(max_y - min_y + 1) + MARGIN * 2
	for r in rooms:
		r.cx = int(r.cx) + shift_x
		r.cy = int(r.cy) + shift_y
		r.scatterX = r.scatterX + shift_x
		r.scatterY = r.scatterY + shift_y
		r.x0 = int(r.cx) - (int(r.w) >> 1)
		r.y0 = int(r.cy) - (int(r.h) >> 1)
		r.x1 = int(r.x0) + int(r.w) - 1
		r.y1 = int(r.y0) + int(r.h) - 1

	# --- Stage: Delaunay -> Prim MST -> loop edges --------------------------
	var pts: Array = []
	for i in range(n):
		var r: Dictionary = rooms[i]
		# tiny deterministic jitter kills cocircular degeneracy from integer centers
		pts.append(Vector2(r.cx + fmod(i * 0.618, 1.0) * 1e-3, r.cy + fmod(i * 0.414, 1.0) * 1e-3))
	var del := _delaunay_edges(pts)

	var E: Array = []
	for e in del:
		var a: int = e.x
		var b: int = e.y
		E.append({"a": a, "b": b, "w": _dist_rooms(rooms, a, b)})
	var mst_idx := _prim_mst(n, E)
	if mst_idx.is_empty() and n > 1:
		return {}
	var in_mst := PackedByteArray()
	in_mst.resize(E.size())
	var mean_sum := 0.0
	for idx in mst_idx:
		in_mst[idx] = 1
		mean_sum += E[idx].w
	var mean_mst: float = mean_sum / max(1, mst_idx.size())

	var mst_adj: Array = []
	for i in range(n):
		mst_adj.append([])
	for idx in mst_idx:
		mst_adj[E[idx].a].append(E[idx].b)
		mst_adj[E[idx].b].append(E[idx].a)

	# Boss = largest-area room (tie-break lower id).
	var boss := 0
	for i in range(1, n):
		if rooms[i].w * rooms[i].h > rooms[boss].w * rooms[boss].h:
			boss = i

	# Entrance = MST leaf maximizing graph distance from boss, prefer non-boss-adjacent.
	var from_boss := _bfs_room_graph(n, mst_adj, boss)
	var entrance := -1
	var ent_score := -1
	for i in range(n):
		if i == boss or mst_adj[i].size() != 1:
			continue
		var adj_boss: bool = mst_adj[i].has(boss)
		var score: int = from_boss.dist[i] * 2 + (0 if adj_boss else 1)
		if score > ent_score:
			ent_score = score; entrance = i
	if entrance < 0:
		return {}

	# Loop edges: re-add non-MST Delaunay edges with p = loopChance.
	var edges: Array = []
	for idx in mst_idx:
		edges.append({"a": E[idx].a, "b": E[idx].b, "w": E[idx].w, "isLoop": false, "isCritical": false})
	var loop_eligible: Array = []
	for i in range(E.size()):
		if in_mst[i] == 1:
			continue
		var e: Dictionary = E[i]
		if e.a == entrance or e.b == entrance:
			continue
		if e.w > 2.2 * mean_mst:
			continue
		loop_eligible.append(i)
		if rng.chance(float(params.loopChance)):
			edges.append({"a": e.a, "b": e.b, "w": e.w, "isLoop": true, "isCritical": false})
	# Loops mandatory: if none rolled, force-add shortest eligible edge.
	var has_loop := false
	for e in edges:
		if e.isLoop:
			has_loop = true; break
	if not has_loop and not loop_eligible.is_empty():
		var bi: int = loop_eligible[0]
		for i in loop_eligible:
			if E[i].w < E[bi].w:
				bi = i
		edges.append({"a": E[bi].a, "b": E[bi].b, "w": E[bi].w, "isLoop": true, "isCritical": false})
	var loops := edges.size() - (n - 1)  # cyclomatic number E - V + 1

	# --- Stage: semantics before carving ------------------------------------
	var adj: Array = []
	for i in range(n):
		adj.append([])
	for e in edges:
		adj[e.a].append(e.b)
		adj[e.b].append(e.a)
	for r in rooms:
		r.degree = adj[r.id].size()

	var from_ent := _bfs_room_graph(n, adj, entrance)
	var max_depth := 1
	for i in range(n):
		max_depth = max(max_depth, from_ent.dist[i])
	for r in rooms:
		r.depth = from_ent.dist[r.id]
		r.difficulty = snappedf(0.15 + 0.85 * (float(r.depth) / max_depth), 0.001)
		r.type = "combat"
	rooms[boss].type = "boss"; rooms[boss].difficulty = 1.0
	rooms[entrance].type = "entrance"; rooms[entrance].difficulty = 0.0

	# Critical path entrance -> boss.
	var critical: Array = []
	var u := boss
	while u != -1:
		critical.append(u)
		u = from_ent.parent[u]
	critical.reverse()
	var on_crit := PackedByteArray()
	on_crit.resize(n)
	for cu in critical:
		on_crit[cu] = 1
	for k in range(critical.size() - 1):
		var a: int = critical[k]
		var b: int = critical[k + 1]
		for e in edges:
			if (e.a == a and e.b == b) or (e.a == b and e.b == a):
				e.isCritical = true
				break

	# Treasure: deepest leaves first, cap 4.
	var leaves: Array = []
	for r in rooms:
		if r.degree == 1 and r.id != entrance and r.id != boss:
			leaves.append(r)
	leaves.sort_custom(func(a, b):
		if a.depth != b.depth:
			return a.depth > b.depth
		return a.id < b.id)
	for li in range(min(4, leaves.size())):
		leaves[li].type = "treasure"

	# Shrines: 1-2 off-path rooms nearest mid-depth (35-65%).
	var shrine_k := rng.ri(1, 2)
	var shrine_cand: Array = []
	for r in rooms:
		var dn: float = float(r.depth) / max_depth
		if r.type == "combat" and on_crit[r.id] == 0 and dn >= 0.35 and dn <= 0.65:
			shrine_cand.append(r)
	shrine_cand.sort_custom(func(a, b):
		var da: float = abs(float(a.depth) / max_depth - 0.5)
		var db: float = abs(float(b.depth) / max_depth - 0.5)
		if da != db:
			return da < db
		return a.id < b.id)
	for si in range(min(shrine_k, shrine_cand.size())):
		shrine_cand[si].type = "shrine"

	# Elites: 1-2 on critical path at 55-85% depth (relaxed fallback).
	var elite_k := rng.ri(1, 2)
	var elite_cand: Array = []
	for r in rooms:
		var dn: float = float(r.depth) / max_depth
		if r.type == "combat" and on_crit[r.id] == 1 and dn >= 0.55 and dn <= 0.85:
			elite_cand.append(r)
	if elite_cand.is_empty():
		for r in rooms:
			if r.type == "combat" and on_crit[r.id] == 1 and float(r.depth) / max_depth >= 0.4:
				elite_cand.append(r)
	elite_cand.sort_custom(func(a, b):
		if a.depth != b.depth:
			return a.depth < b.depth
		return a.id < b.id)
	if not elite_cand.is_empty():
		if elite_k == 1 or elite_cand.size() == 1:
			elite_cand[int(elite_cand.size() / 2)].type = "elite"
		else:
			elite_cand[int(elite_cand.size() / 3)].type = "elite"
			elite_cand[int(2 * elite_cand.size() / 3)].type = "elite"

	# Per-room tint.
	for r in rooms:
		if TYPE_HUE.has(r.type):
			var base: float = TYPE_HUE[r.type]
			var hue: float = base + rng.rf(-0.015, 0.015)
			r.tint = _hsl2rgb(hue, 0.65, 0.55)
		else:
			var hue: float = rng.rf(0.52, 0.78)
			r.tint = _hsl2rgb(hue, 0.35, 0.55)

	# --- Stage: carve -------------------------------------------------------
	_grid = PackedByteArray(); _grid.resize(_W * _H)
	_roomid = PackedInt32Array(); _roomid.resize(_W * _H); _roomid.fill(-1)
	_corridor = PackedByteArray(); _corridor.resize(_W * _H)

	for r in rooms:
		# Build into a local packed array (reliable in-place append), then assign
		# — appending to a packed array nested in a Dictionary is copy-on-write.
		var cells := PackedInt32Array()
		for y in range(r.y0, r.y1 + 1):
			for x in range(r.x0, r.x1 + 1):
				if not _cell_in_room(r, x, y):
					continue
				var idx := y * _W + x
				_grid[idx] = FLOOR
				if _roomid[idx] < 0:
					_roomid[idx] = r.id
				cells.append(idx)
		r.cells = cells
		r.area = cells.size()

	for e in edges:
		var ra: Dictionary = rooms[e.a]
		var rb: Dictionary = rooms[e.b]
		var leaf_end: Dictionary = {}
		if ra.degree == 1:
			leaf_end = ra
		elif rb.degree == 1:
			leaf_end = rb
		var wdt := 3 if e.isCritical else (1 if (not leaf_end.is_empty() and leaf_end.type == "treasure") else 2)
		# Straight run when spans overlap enough - else one seeded elbow.
		var lo_x: int = max(int(ra.x0) + 1, int(rb.x0) + 1)
		var hi_x: int = min(int(ra.x1) - 1, int(rb.x1) - 1)
		var lo_y: int = max(int(ra.y0) + 1, int(rb.y0) + 1)
		var hi_y: int = min(int(ra.y1) - 1, int(rb.y1) - 1)
		if hi_x - lo_x + 1 >= wdt:
			_carve_v(int((lo_x + hi_x) / 2), int(ra.cy), int(rb.cy), wdt)
		elif hi_y - lo_y + 1 >= wdt:
			_carve_h(int((lo_y + hi_y) / 2), int(ra.cx), int(rb.cx), wdt)
		elif rng.chance(0.5):
			_carve_h(int(ra.cy), int(ra.cx), int(rb.cx), wdt)
			_carve_v(int(rb.cx), int(ra.cy), int(rb.cy), wdt)
			for dy in range(wdt):
				for dx in range(wdt):
					_stamp_cell(int(rb.cx) - (wdt >> 1) + dx, int(ra.cy) - (wdt >> 1) + dy)
		else:
			_carve_v(int(ra.cx), int(ra.cy), int(rb.cy), wdt)
			_carve_h(int(rb.cy), int(ra.cx), int(rb.cx), wdt)
			for dy in range(wdt):
				for dx in range(wdt):
					_stamp_cell(int(ra.cx) - (wdt >> 1) + dx, int(rb.cy) - (wdt >> 1) + dy)

	# --- Stage: rasterize walls, doorways, BFS field ------------------------
	for y in range(_H):
		for x in range(_W):
			var idx := y * _W + x
			if _grid[idx] != VOID:
				continue
			var near := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and ny >= 0 and nx < _W and ny < _H and _grid[ny * _W + nx] == FLOOR:
						near = true
			if near:
				_grid[idx] = WALL

	var doorways: Array = []
	_doorway_set = PackedByteArray(); _doorway_set.resize(_W * _H)
	for y in range(1, _H - 1):
		for x in range(1, _W - 1):
			var idx := y * _W + x
			if _corridor[idx] == 0:
				continue
			if (_roomid[idx - 1] >= 0 and _corridor[idx - 1] == 0) \
			or (_roomid[idx + 1] >= 0 and _corridor[idx + 1] == 0) \
			or (_roomid[idx - _W] >= 0 and _corridor[idx - _W] == 0) \
			or (_roomid[idx + _W] >= 0 and _corridor[idx + _W] == 0):
				doorways.append(Vector2i(x, y))
				_doorway_set[idx] = 1

	var ent: Dictionary = rooms[entrance]
	var bfs := PackedInt32Array(); bfs.resize(_W * _H); bfs.fill(-1)
	var q := PackedInt32Array(); q.resize(_W * _H)
	var qh := 0
	var qt := 0
	var start := int(ent.cy) * _W + int(ent.cx)
	if _grid[start] == FLOOR:
		bfs[start] = 0; q[qt] = start; qt += 1
	while qh < qt:
		var idx := q[qh]; qh += 1
		var d := bfs[idx]
		var x := idx % _W
		if x > 0 and _grid[idx - 1] == FLOOR and bfs[idx - 1] < 0:
			bfs[idx - 1] = d + 1; q[qt] = idx - 1; qt += 1
		if x < _W - 1 and _grid[idx + 1] == FLOOR and bfs[idx + 1] < 0:
			bfs[idx + 1] = d + 1; q[qt] = idx + 1; qt += 1
		if idx - _W >= 0 and _grid[idx - _W] == FLOOR and bfs[idx - _W] < 0:
			bfs[idx - _W] = d + 1; q[qt] = idx - _W; qt += 1
		if idx + _W < _W * _H and _grid[idx + _W] == FLOOR and bfs[idx + _W] < 0:
			bfs[idx + _W] = d + 1; q[qt] = idx + _W; qt += 1

	var floor_tiles := 0
	var wall_tiles := 0
	var unreached := 0
	var max_bfs := 1
	for idx in range(_W * _H):
		if _grid[idx] == FLOOR:
			floor_tiles += 1
			if bfs[idx] < 0:
				unreached += 1
			elif bfs[idx] > max_bfs:
				max_bfs = bfs[idx]
		elif _grid[idx] == WALL:
			wall_tiles += 1
	var boss_cell := int(rooms[boss].cy) * _W + int(rooms[boss].cx)
	var boss_ratio: float = (float(bfs[boss_cell]) / max_bfs) if bfs[boss_cell] >= 0 else 0.0

	# --- Stage: decoration (data only) --------------------------------------
	_occ = PackedByteArray(); _occ.resize(_W * _H)
	for dcell in doorways:
		_occ[dcell.y * _W + dcell.x] = 1
	_props = []

	# Pillar grids in large rooms.
	for r in rooms:
		if r.arch != "large" or r.type == "boss":
			continue
		for idx: int in r.cells:
			var x := idx % _W
			var y := int(idx / _W)
			if (x - int(r.x0)) % 3 != 1 or (y - int(r.y0)) % 3 != 1:
				continue
			if _occ[idx] == 1 or not _all_floor8(x, y) or _door_dist(doorways, x, y) < 2:
				continue
			_add_prop("pillar", x, y, 0.0, rng.rf(0.9, 1.05), r.id)

	# Torches: floor cells hugging a wall, min Chebyshev spacing 4.
	var torches: Array = []
	for y in range(1, _H - 1):
		for x in range(1, _W - 1):
			var idx := y * _W + x
			if _grid[idx] != FLOOR or _occ[idx] == 1:
				continue
			var dir := Vector2i.ZERO
			var have_dir := false
			if _grid[idx - _W] == WALL:
				dir = Vector2i(0, -1); have_dir = true
			elif _grid[idx + _W] == WALL:
				dir = Vector2i(0, 1); have_dir = true
			elif _grid[idx - 1] == WALL:
				dir = Vector2i(-1, 0); have_dir = true
			elif _grid[idx + 1] == WALL:
				dir = Vector2i(1, 0); have_dir = true
			if not have_dir:
				continue
			var ok := true
			for tc in torches:
				if max(abs(tc.x - x), abs(tc.y - y)) < 4:
					ok = false; break
			if not ok:
				continue
			if not rng.chance(0.45 if _corridor[idx] == 1 else 0.8):
				continue
			var rot := atan2(float(dir.x), float(dir.y))
			torches.append(Vector2i(x, y))
			_add_prop("torch", x, y, rot, 1.0, _roomid[idx])

	# Braziers ringing the boss arena.
	var b: Dictionary = rooms[boss]
	var rr: int = max(2, int(min(b.w, b.h) / 2) - 2)
	for k in range(8):
		var ang := k * PI / 4.0
		var x := roundi(b.cx + cos(ang) * rr)
		var y := roundi(b.cy + sin(ang) * rr)
		var idx := y * _W + x
		if idx >= 0 and idx < _W * _H and _grid[idx] == FLOOR and _roomid[idx] == b.id and _occ[idx] == 0:
			_add_prop("brazier", x, y, 0.0, 1.0, b.id)

	# Chests, shrine crystals, entrance portal ring.
	for r in rooms:
		if r.type == "treasure":
			var c := _center_free(r)
			if c >= 0:
				_add_prop("chest", c % _W, int(c / _W), rng.rf(0.0, TAU), 1.0, r.id)
		elif r.type == "shrine":
			var c := _center_free(r)
			if c >= 0:
				_add_prop("crystal", c % _W, int(c / _W), rng.rf(0.0, TAU), 1.4, r.id)
	for k in range(8):
		_add_prop("portal", int(ent.cx), int(ent.cy), k * PI / 4.0, 0.55, entrance)

	# Debris proportional to decorDensity, denser in low-difficulty rooms.
	for r in rooms:
		var p: float = float(params.decorDensity) * 0.05 * (1.5 - r.difficulty)
		for idx: int in r.cells:
			if _occ[idx] == 1 or _doorway_set[idx] == 1:
				continue
			if rng.chance(p):
				_add_prop("debris", idx % _W, int(idx / _W), rng.rf(0.0, TAU), rng.rf(0.5, 1.4), r.id)

	# --- Stage: enemy spawns ------------------------------------------------
	var spawns: Array = []
	for r in rooms:
		if r.type == "boss":
			var c := _center_free(r)
			if c >= 0:
				spawns.append({"x": c % _W, "y": int(c / _W), "tier": "boss", "roomId": r.id})
				_occ[c] = 1
			continue
		if r.type != "combat" and r.type != "elite":
			continue
		var count := roundi(float(r.area) / 18.0 * (0.5 + r.difficulty))
		var cand: Array = []
		for idx: int in r.cells:
			if _occ[idx] == 0 and _doorway_set[idx] == 0:
				cand.append(idx)
		count = min(count, cand.size())
		for k in range(count):
			var pick_i := rng.ri(0, cand.size() - 1)
			var idx: int = cand[pick_i]
			cand[pick_i] = cand[cand.size() - 1]
			cand.pop_back()
			spawns.append({"x": idx % _W, "y": int(idx / _W), "tier": ("elite" if r.type == "elite" else "normal"), "roomId": r.id})
			_occ[idx] = 1

	# --- Stage: presentation metadata ---------------------------------------
	var dungeon_name := _roll_name(rng, str(params.theme))
	var leaf_count := 0
	for r in rooms:
		if r.degree == 1:
			leaf_count += 1
	var corridor_cells: Array = []
	for idx in range(_W * _H):
		if _corridor[idx] == 1:
			corridor_cells.append(Vector2i(idx % _W, int(idx / _W)))

	var out_rooms: Array = []
	for r in rooms:
		out_rooms.append({
			"id": r.id, "cx": int(r.cx), "cy": int(r.cy), "w": int(r.w), "h": int(r.h),
			"shape": r.shape, "type": r.type, "depth": r.depth, "difficulty": r.difficulty,
			"degree": r.degree, "area": r.area, "arch": r.arch, "tint": r.tint,
			"x0": int(r.x0), "y0": int(r.y0), "x1": int(r.x1), "y1": int(r.y1),
			"scatterX": float(r.scatterX), "scatterY": float(r.scatterY),
		})

	var dungeon := {
		"params": params.duplicate(), "name": dungeon_name, "W": _W, "H": _H,
		"grid": _grid, "bfs": bfs, "rooms": out_rooms, "edges": edges,
		"doorways": doorways, "corridorCells": corridor_cells,
		"props": _props, "spawns": spawns,
		"roomIdGrid": _roomid, "corridorMask": _corridor,
		"stats": {
			"rooms": n, "edges": edges.size(), "loops": loops,
			"criticalLength": critical.size(), "floorTiles": floor_tiles,
			"wallTiles": wall_tiles, "props": _props.size(), "genMs": 0.0,
			"seedUsed": seed_value, "attempt": attempt + 1, "maxBfs": max_bfs,
			"bossRatio": snappedf(boss_ratio, 0.001), "maxDepth": max_depth,
		},
		"debug": {
			"delaunay": del, "entrance": entrance, "boss": boss,
			"criticalRooms": critical, "meanMst": snappedf(mean_mst, 0.01),
		},
	}

	var boss_adjacent := false
	for e in edges:
		if (e.a == entrance and e.b == boss) or (e.a == boss and e.b == entrance):
			boss_adjacent = true; break
	var valid: bool = unreached == 0 and boss_ratio >= 0.6 and int(rooms[entrance].degree) == 1 \
		and not boss_adjacent and loops >= 1 and (room_count < 40 or leaf_count >= 3)
	var score: float = (10.0 if unreached == 0 else 0.0) + boss_ratio
	return {"valid": valid, "score": score, "dungeon": dungeon}

# ============================================================================
# Carving helpers (mutate instance grid state)
# ============================================================================
func _stamp_cell(x: int, y: int) -> void:
	if x < 1 or y < 1 or x >= _W - 1 or y >= _H - 1:
		return
	var idx := y * _W + x
	if _grid[idx] != FLOOR:
		_grid[idx] = FLOOR
		_corridor[idx] = 1

func _carve_h(y: int, xa: int, xb: int, wdt: int) -> void:
	var lo: int = min(xa, xb)
	var hi: int = max(xa, xb)
	var off := wdt >> 1
	for x in range(lo, hi + 1):
		for k in range(wdt):
			_stamp_cell(x, y - off + k)

func _carve_v(x: int, ya: int, yb: int, wdt: int) -> void:
	var lo: int = min(ya, yb)
	var hi: int = max(ya, yb)
	var off := wdt >> 1
	for y in range(lo, hi + 1):
		for k in range(wdt):
			_stamp_cell(x - off + k, y)

# ============================================================================
# Decoration helpers
# ============================================================================
func _add_prop(kind: String, x: int, y: int, rot: float, scale_v: float, room_id: int) -> void:
	_props.append({"kind": kind, "x": x, "y": y, "rot": snappedf(rot, 0.0001), "scale": snappedf(scale_v, 0.0001), "roomId": room_id})
	_occ[y * _W + x] = 1

func _all_floor8(x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if _grid[(y + dy) * _W + (x + dx)] != FLOOR:
				return false
	return true

func _door_dist(doorways: Array, x: int, y: int) -> int:
	var m := 1 << 30
	for dcell in doorways:
		m = min(m, max(abs(dcell.x - x), abs(dcell.y - y)))
	return m

func _center_free(r: Dictionary) -> int:
	var c := int(r.cy) * _W + int(r.cx)
	if _grid[c] == FLOOR and _occ[c] == 0:
		return c
	for idx: int in r.cells:
		if _occ[idx] == 0 and _doorway_set[idx] == 0:
			return idx
	return -1

# ============================================================================
# Static geometry / graph helpers
# ============================================================================
static func _dist_rooms(rooms: Array, a: int, b: int) -> float:
	return sqrt(pow(rooms[a].cx - rooms[b].cx, 2.0) + pow(rooms[a].cy - rooms[b].cy, 2.0))

static func _cell_in_room(r: Dictionary, x: int, y: int) -> bool:
	if x < r.x0 or x > r.x1 or y < r.y0 or y > r.y1:
		return false
	if r.shape == "rect":
		return true
	if r.shape == "ellipse":
		var dx: float = (x - (r.x0 + (r.w - 1) / 2.0)) / (r.w / 2.0)
		var dy: float = (y - (r.y0 + (r.h - 1) / 2.0)) / (r.h / 2.0)
		return dx * dx + dy * dy <= 1.05
	# chamfered octagon
	var c: int = max(2, roundi(min(r.w, r.h) * 0.29))
	var dxe: int = min(x - int(r.x0), int(r.x1) - x)
	var dye: int = min(y - int(r.y0), int(r.y1) - y)
	return dxe + dye >= c

static func _circumcircle(ax: float, ay: float, bx: float, by: float, cx: float, cy: float):
	var d := 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	if abs(d) < 1e-12:
		return null
	var a2 := ax * ax + ay * ay
	var b2 := bx * bx + by * by
	var c2 := cx * cx + cy * cy
	var ux := (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
	var uy := (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
	return {"x": ux, "y": uy, "r2": (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy)}

## Bowyer-Watson Delaunay triangulation. Returns Array[Vector2i] of unique edges (lo,hi).
static func _delaunay_edges(pts: Array) -> Array:
	var n := pts.size()
	if n < 2:
		return []
	if n == 2:
		return [Vector2i(0, 1)]
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for p in pts:
		min_x = min(min_x, p.x); max_x = max(max_x, p.x)
		min_y = min(min_y, p.y); max_y = max(max_y, p.y)
	var dmax: float = max(max_x - min_x, max_y - min_y) * 12.0 + 100.0
	var mx := (min_x + max_x) / 2.0
	var my := (min_y + max_y) / 2.0
	var P: Array = []
	for p in pts:
		P.append(Vector2(p.x, p.y))
	P.append(Vector2(mx - dmax, my - dmax))
	P.append(Vector2(mx, my + dmax))
	P.append(Vector2(mx + dmax, my - dmax))

	var tris: Array = [_mk_tri(P, n, n + 1, n + 2)]
	for i in range(n):
		var px: float = P[i].x
		var py: float = P[i].y
		var kept: Array = []
		var edge_count := {}
		for t in tris:
			var in_c := false
			if t.cc != null:
				in_c = (px - t.cc.x) * (px - t.cc.x) + (py - t.cc.y) * (py - t.cc.y) <= t.cc.r2
			if not in_c:
				kept.append(t)
				continue
			for pair in [[t.a, t.b], [t.b, t.c], [t.c, t.a]]:
				var uu: int = pair[0]
				var vv: int = pair[1]
				var kk := (uu * 100000 + vv) if uu < vv else (vv * 100000 + uu)
				edge_count[kk] = edge_count.get(kk, 0) + 1
		for kk in edge_count:
			if edge_count[kk] != 1:
				continue
			var uu := int(kk / 100000)
			var vv: int = kk % 100000
			kept.append(_mk_tri(P, uu, vv, i))
		tris = kept

	var seen := {}
	var edges: Array = []
	for t in tris:
		if t.a >= n or t.b >= n or t.c >= n:
			continue
		for pair in [[t.a, t.b], [t.b, t.c], [t.c, t.a]]:
			var lo: int = min(pair[0], pair[1])
			var hi: int = max(pair[0], pair[1])
			var kk := lo * 100000 + hi
			if not seen.has(kk):
				seen[kk] = true
				edges.append(Vector2i(lo, hi))
	edges.sort_custom(func(e, f):
		if e.x != f.x:
			return e.x < f.x
		return e.y < f.y)
	return edges

static func _mk_tri(P: Array, a: int, b: int, c: int) -> Dictionary:
	return {"a": a, "b": b, "c": c, "cc": _circumcircle(P[a].x, P[a].y, P[b].x, P[b].y, P[c].x, P[c].y)}

## Prim MST over candidate edges E (Array of {a,b,w}). Returns Array[int] of chosen indices.
static func _prim_mst(n: int, E: Array) -> Array:
	if n <= 1:
		return []
	var in_t := PackedByteArray(); in_t.resize(n)
	in_t[0] = 1
	var used := PackedByteArray(); used.resize(E.size())
	var out: Array = []
	for added in range(1, n):
		var bi := -1
		var bw := INF
		for i in range(E.size()):
			if used[i] == 1:
				continue
			var e: Dictionary = E[i]
			if (in_t[e.a] != in_t[e.b]) and e.w < bw:
				bw = e.w; bi = i
		if bi < 0:
			return []
		used[bi] = 1
		out.append(bi)
		in_t[E[bi].a] = 1
		in_t[E[bi].b] = 1
	return out

static func _bfs_room_graph(n: int, adj: Array, start: int) -> Dictionary:
	var dist := PackedInt32Array(); dist.resize(n); dist.fill(-1)
	var parent := PackedInt32Array(); parent.resize(n); parent.fill(-1)
	var q: Array = [start]
	dist[start] = 0
	var qi := 0
	while qi < q.size():
		var u: int = q[qi]; qi += 1
		for v in adj[u]:
			if dist[v] < 0:
				dist[v] = dist[u] + 1
				parent[v] = u
				q.append(v)
	return {"dist": dist, "parent": parent}

static func _hsl2rgb(h: float, s: float, l: float) -> Color:
	h = fposmod(h, 1.0)
	var a: float = s * min(l, 1.0 - l)
	return Color(_hsl_f(0.0, h, l, a), _hsl_f(8.0, h, l, a), _hsl_f(4.0, h, l, a))

static func _hsl_f(nn: float, h: float, l: float, a: float) -> float:
	var k := fmod(nn + h * 12.0, 12.0)
	return l - a * max(-1.0, min(k - 3.0, min(9.0 - k, 1.0)))

static func _roll_name(rng: DungeonRng, theme: String) -> String:
	var t: Dictionary = NAME_TABLES.get(theme, NAME_TABLES["crypt"])
	return "The %s %s of %s%s" % [rng.pick(t.adj), rng.pick(t.place), rng.pick(t.s1), rng.pick(t.s2)]
