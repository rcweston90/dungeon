extends Node3D

## App shell: orthographic iso camera, environment/fog, input (wheel zoom +
## drag pan), a code-built control panel, and the regenerate flow. Mirrors the
## main() IIFE from index.html.

var _renderer: DungeonRenderer = null
var _dungeon: Dictionary = {}
var _time := 0.0

# camera rig
var _cam: Camera3D
var _cam_target := Vector3.ZERO
var _cam_size := 40.0
var _cam_dist := 40.0
var _zoom := 1.0
var _dragging := false

# environment
var _env: Environment

# UI refs
var _ui := {}
var _lbl_name: Label
var _lbl_sub: Label
var _lbl_stats: Label
var _lbl_tests: RichTextLabel

const LEGEND := [
	["entrance", "3d8bff"], ["boss", "e03535"], ["elite", "ff8822"],
	["treasure", "e8c04a"], ["shrine", "3fe0c0"], ["combat", "8f7fd4"],
	["spawn", "b43a4a"], ["critical", "ff3344"],
]

func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()
	regenerate()

# ============================================================================
# Environment & camera
# ============================================================================
func _setup_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color("07070c")
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color("35426b")
	_env.ambient_light_energy = 0.55
	_env.fog_enabled = true
	_env.fog_light_color = Color("07070c")
	_env.fog_density = 0.03
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.glow_enabled = true
	_env.glow_intensity = 0.5
	_env.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	var dl := DirectionalLight3D.new()
	dl.light_color = Color("8899bb")
	dl.light_energy = 0.35
	dl.shadow_enabled = false
	dl.rotation_degrees = Vector3(-52, 40, 0)
	add_child(dl)

func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.current = true
	add_child(_cam)

func _frame_camera() -> void:
	_cam.size = _cam_size / _zoom
	var dir := Vector3(1, 1, 1).normalized()
	_cam.position = _cam_target + dir * _cam_dist
	_cam.look_at(_cam_target, Vector3.UP)
	_cam.near = 0.05
	_cam.far = _cam_dist * 4.0

# ============================================================================
# Regenerate flow
# ============================================================================
func regenerate() -> void:
	var params := {
		"seed": int(_ui.seed.text.to_int()) & 0xFFFFFFFF,
		"roomCount": int(_ui.roomCount.value),
		"loopChance": _ui.loopChance.value,
		"decorDensity": _ui.decorDensity.value,
		"theme": "crypt",
	}
	if _renderer != null:
		# free() (not queue_free) disposes synchronously so old lights/meshes
		# never overlap the new ones for a frame — matches the JS dispose().
		_renderer.free()
		_renderer = null

	_dungeon = DungeonGen.generate(params)
	_renderer = DungeonRenderer.new()
	add_child(_renderer)
	_renderer.build(_dungeon)

	# fog tuned to dungeon extent
	var max_dim: int = max(_dungeon.W, _dungeon.H)
	_env.fog_density = 0.55 / max_dim
	_cam_target = Vector3(_dungeon.W / 2.0, 0, _dungeon.H / 2.0)
	_cam_size = max_dim * 0.9
	_cam_dist = max_dim
	_frame_camera()

	# apply overlay/heatmap/animation state
	for pair in [["delaunay", "ovDelaunay"], ["mst", "ovMst"], ["loops", "ovLoops"], ["critical", "ovCritical"]]:
		_renderer.set_overlay(pair[0], _ui[pair[1]].button_pressed)
	if _ui.ovHeatmap.button_pressed:
		_renderer.set_heatmap(true)
	if _ui.animateBuild.button_pressed:
		_renderer.start_build_animation()

	_lbl_name.text = _dungeon.name
	_lbl_sub.text = "seed %d  ·  %d×%d  ·  %s" % [_dungeon.stats.seedUsed, _dungeon.W, _dungeon.H, _dungeon.params.theme]
	_render_stats()
	_render_tests(DungeonTests.run(_dungeon, _renderer.point_light_count))

func _overlay_state() -> Dictionary:
	return {
		"delaunay": _ui.ovDelaunay.button_pressed, "mst": _ui.ovMst.button_pressed,
		"loops": _ui.ovLoops.button_pressed, "critical": _ui.ovCritical.button_pressed,
	}

func _render_stats() -> void:
	var s: Dictionary = _dungeon.stats
	var rows := [
		["rooms / edges", "%d / %d" % [s.rooms, s.edges]],
		["loops (E-V+1)", str(s.loops)],
		["critical path", "%d rooms" % s.criticalLength],
		["floor / wall", "%d / %d" % [s.floorTiles, s.wallTiles]],
		["props / spawns", "%d / %d" % [s.props, _dungeon.spawns.size()]],
		["point lights", str(_renderer.point_light_count)],
		["draw calls (lvl)", str(_renderer.draw_calls)],
		["gen time", "%.1f ms (try %d)" % [s.genMs, s.attempt]],
		["boss depth", "%d%% of max" % roundi(s.bossRatio * 100)],
		["checksum", "%x" % DungeonTests.checksum(_dungeon)],
	]
	var out := ""
	for r in rows:
		out += "%-16s %s\n" % [r[0], r[1]]
	_lbl_stats.text = out

func _render_tests(T: Array) -> void:
	_lbl_tests.clear()
	for t in T:
		var col := "5fd67d" if t.pass else "f05a5a"
		var mark := "✔" if t.pass else "✘"
		_lbl_tests.append_text("[color=#%s]%s[/color] %s  [color=#7a7e94]%s[/color]\n" % [col, mark, t.name, t.info])

# ============================================================================
# Input: wheel zoom, drag pan
# ============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom = clampf(_zoom * 1.1, 0.35, 8.0)
			_frame_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom = clampf(_zoom / 1.1, 0.35, 8.0)
			_frame_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		var basis := _cam.global_transform.basis
		var right := Vector3(basis.x.x, 0, basis.x.z).normalized()
		var fwd := Vector3(-basis.z.x, 0, -basis.z.z).normalized()
		var k := (_cam_size / _zoom) / get_viewport().get_visible_rect().size.y
		_cam_target -= right * event.relative.x * k
		_cam_target += fwd * event.relative.y * k
		_frame_camera()

func _process(delta: float) -> void:
	_time += delta
	if _renderer != null:
		_renderer.update(_time, delta, _overlay_state())

# ============================================================================
# UI construction (built in code to keep the scene file trivial)
# ============================================================================
func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(300, 0)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	margin.add_child(vb)

	_lbl_name = _mk_label("…", 15, Color("e8a33d"))
	vb.add_child(_lbl_name)
	_lbl_sub = _mk_label("generating…", 10, Color("7a7e94"))
	vb.add_child(_lbl_sub)

	# seed row
	var seed_row := HBoxContainer.new()
	seed_row.add_child(_mk_label("seed", 12, Color("7a7e94"), 70))
	_ui.seed = LineEdit.new()
	_ui.seed.text = "42"
	_ui.seed.custom_minimum_size = Vector2(120, 0)
	_ui.seed.text_submitted.connect(func(_t): regenerate())
	seed_row.add_child(_ui.seed)
	var dice := Button.new()
	dice.text = "🎲"
	dice.pressed.connect(_on_dice)
	seed_row.add_child(dice)
	vb.add_child(seed_row)

	_ui.roomCount = _mk_slider(vb, "rooms", 10, 80, 1, 42, "%.0f")
	_ui.loopChance = _mk_slider(vb, "loop chance", 0.0, 0.5, 0.01, 0.15, "%.2f")
	_ui.decorDensity = _mk_slider(vb, "decor", 0.0, 1.0, 0.05, 0.6, "%.2f")

	var gen_btn := Button.new()
	gen_btn.text = "⟳  Generate"
	gen_btn.pressed.connect(regenerate)
	vb.add_child(gen_btn)

	# overlay checkboxes (two columns)
	var grid := GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)
	_ui.ovDelaunay = _mk_check(grid, "delaunay", func(on): _apply_overlay("delaunay", on))
	_ui.ovMst = _mk_check(grid, "mst", func(on): _apply_overlay("mst", on))
	_ui.ovLoops = _mk_check(grid, "loops", func(on): _apply_overlay("loops", on))
	_ui.ovCritical = _mk_check(grid, "critical", func(on): _apply_overlay("critical", on))
	_ui.ovHeatmap = _mk_check(grid, "heatmap", _on_heatmap)
	_ui.animateBuild = _mk_check(grid, "animate build", _on_noop)

	vb.add_child(_mk_sep())
	vb.add_child(_mk_label("STATS", 10, Color("7a7e94")))
	_lbl_stats = _mk_label("", 11, Color("cfd2e0"))
	_lbl_stats.add_theme_font_override("font", ThemeDB.fallback_font)
	vb.add_child(_lbl_stats)

	vb.add_child(_mk_sep())
	vb.add_child(_mk_label("ACCEPTANCE TESTS", 10, Color("7a7e94")))
	_lbl_tests = RichTextLabel.new()
	_lbl_tests.bbcode_enabled = true
	_lbl_tests.fit_content = true
	_lbl_tests.custom_minimum_size = Vector2(276, 0)
	_lbl_tests.scroll_active = false
	vb.add_child(_lbl_tests)

	vb.add_child(_mk_sep())
	vb.add_child(_mk_label("LEGEND", 10, Color("7a7e94")))
	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.custom_minimum_size = Vector2(276, 0)
	legend.scroll_active = false
	var lt := ""
	for i in range(LEGEND.size()):
		lt += "[color=#%s]■[/color] %-9s" % [LEGEND[i][1], LEGEND[i][0]]
		if i % 2 == 1:
			lt += "\n"
	legend.text = lt
	vb.add_child(legend)

	# hint
	var hint := _mk_label("drag to pan  ·  wheel to zoom", 11, Color("4a4d61"))
	var hint_layer := CanvasLayer.new()
	add_child(hint_layer)
	var hc := Control.new()
	hc.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hint_layer.add_child(hc)
	hc.add_child(hint)
	hint.position = Vector2(-230, -26)

func _apply_overlay(name_key: String, on: bool) -> void:
	if _renderer != null and not _renderer.is_animating():
		_renderer.set_overlay(name_key, on)

# --- named signal handlers (avoid multi-line-lambda parse pitfalls) ---
func _on_dice() -> void:
	_ui.seed.text = str(randi())
	regenerate()

func _on_slider_committed(changed: bool) -> void:
	if changed:
		regenerate()

func _on_heatmap(on: bool) -> void:
	if _renderer != null:
		_renderer.set_heatmap(on)

func _on_noop(_on: bool) -> void:
	pass

# --- widget factories ---
func _mk_label(text: String, size: int, color: Color, min_w: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, 0)
	return l

func _mk_sep() -> HSeparator:
	return HSeparator.new()

func _mk_slider(parent: Node, label: String, lo: float, hi: float, step: float, val: float, fmt: String) -> HSlider:
	var row := HBoxContainer.new()
	row.add_child(_mk_label(label, 12, Color("7a7e94"), 84))
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = val
	slider.custom_minimum_size = Vector2(120, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var vlabel := _mk_label(fmt % val, 12, Color("e8a33d"), 40)
	row.add_child(vlabel)
	slider.value_changed.connect(func(v): vlabel.text = fmt % v)
	slider.drag_ended.connect(_on_slider_committed)
	parent.add_child(row)
	return slider

func _mk_check(parent: Node, label: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = label
	c.add_theme_font_size_override("font_size", 11)
	c.toggled.connect(cb)
	parent.add_child(c)
	return c
