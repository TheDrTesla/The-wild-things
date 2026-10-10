extends Control
## The launcher window: checks for updates on every start, shows patch notes,
## and starts the game.

const BG := Color("#14120f")
const PANEL := Color("#1f1b17")
const BORDER := Color("#3d342b")
const TEXT := Color("#ece0cb")
const MUTED := Color("#8f8574")
const ACCENT := Color("#e07a2f")
const GOOD := Color("#9bd13c")
const BAD := Color("#e0503c")

var updater: Updater
var _status: Label
var _bar: ProgressBar
var _play: Button
var _repair: Button
var _notes: RichTextLabel
var _version: Label
var _banner: Button
var _busy := false
var _indeterminate := false
var _t := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = _make_theme()
	draw.connect(_draw_bg)

	updater = Updater.new()
	add_child(updater)
	updater.status.connect(func(t): _status.text = t)
	updater.progress.connect(_on_progress)

	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 28)
	add_child(m)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	m.add_child(root)

	var head := HBoxContainer.new()
	root.add_child(head)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -4)
	titles.add_child(_label("CTRL+ALT+SALVAGE", 40, ACCENT))
	titles.add_child(_label("LAUNCHER", 14, MUTED))
	head.add_child(titles)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_version = _label("", 14, MUTED)
	_version.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_version)

	_banner = Button.new()
	_banner.visible = false
	_banner.pressed.connect(func(): OS.shell_open(str(updater.launcher_update.get("html_url", ""))))
	root.add_child(_banner)

	var notes_panel := PanelContainer.new()
	notes_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(notes_panel)
	var nv := VBoxContainer.new()
	notes_panel.add_child(nv)
	nv.add_child(_label("PATCH NOTES", 13, MUTED))
	_notes = RichTextLabel.new()
	_notes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_notes.add_theme_color_override("default_color", TEXT)
	_notes.add_theme_font_size_override("normal_font_size", 15)
	_notes.text = "Checking for news from the Dead Zone..."
	nv.add_child(_notes)

	_status = _label("Starting...", 15, TEXT)
	root.add_child(_status)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	root.add_child(bottom)
	_bar = ProgressBar.new()
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bar.custom_minimum_size.y = 14
	_bar.show_percentage = false
	_bar.max_value = 1.0
	bottom.add_child(_bar)
	_repair = Button.new()
	_repair.text = "Repair"
	_repair.tooltip_text = "Re-download and re-verify the game files"
	_repair.custom_minimum_size = Vector2(110, 52)
	_repair.pressed.connect(func(): _run_update(true))
	bottom.add_child(_repair)
	_play = Button.new()
	_play.text = "PLAY"
	_play.custom_minimum_size = Vector2(200, 52)
	_play.add_theme_font_size_override("font_size", 22)
	_play.pressed.connect(_on_play)
	bottom.add_child(_play)

	_run_update(false)

func _process(delta: float) -> void:
	_t += delta
	if _indeterminate:
		_bar.value = 0.5 + 0.5 * sin(_t * 4.0)
	queue_redraw()

func _on_progress(f: float) -> void:
	_indeterminate = f < 0.0
	if not _indeterminate:
		_bar.value = f

func _run_update(force: bool) -> void:
	if _busy:
		return
	_busy = true
	_play.disabled = true
	_repair.disabled = true
	var res: Dictionary = await updater.check_and_update(force)
	_busy = false
	_indeterminate = false
	_bar.value = 1.0 if res["ok"] else 0.0
	_status.text = res["message"]
	_status.add_theme_color_override("font_color", GOOD if res["ok"] else BAD)
	_play.disabled = not res["ok"]
	_repair.disabled = false
	var mine: String = ProjectSettings.get_setting("application/config/version")
	_version.text = "Game %s\nLauncher %s" % [updater.installed_version() if updater.installed_version() != "" else "—", mine]
	if updater.release_notes != "":
		_notes.text = updater.release_notes
	elif not res["ok"]:
		_notes.text = "Once a build is published it will be downloaded here automatically."
	else:
		_notes.text = "Patch notes are unavailable while offline."
	if not updater.launcher_update.is_empty():
		_banner.text = "A new launcher (%s) is available — click to download" % updater.launcher_update["tag_name"]
		_banner.visible = true

func _on_play() -> void:
	if not updater.installed_ok():
		_status.text = "Game files are damaged. Click Repair."
		_status.add_theme_color_override("font_color", BAD)
		return
	var pid := OS.create_process(updater.game_exe_path(), [])
	if pid <= 0:
		_status.text = "Could not start the game."
		return
	_status.text = "Launching..."
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()

func _label(t: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _box(bg: Color, border: Color, w: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(w)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(12)
	return s

func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("normal", "Button", _box(Color("#2a241e"), BORDER))
	t.set_stylebox("hover", "Button", _box(Color("#3a2f24"), ACCENT))
	t.set_stylebox("pressed", "Button", _box(Color("#9e4f18"), ACCENT))
	t.set_stylebox("disabled", "Button", _box(Color("#1a1714"), Color("#2a241e")))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", Color("#5c544a"))
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.12, 0.105, 0.09, 0.88), BORDER))
	t.set_stylebox("background", "ProgressBar", _box(Color("#0d0c0a"), BORDER))
	var fill := _box(ACCENT, ACCENT, 0)
	fill.set_content_margin_all(0)
	t.set_stylebox("fill", "ProgressBar", fill)
	return t

func _draw_bg() -> void:
	var sz := size
	for i in 20:
		var f := float(i) / 20.0
		draw_rect(Rect2(0, sz.y * f, sz.x, sz.y / 20.0 + 1), Color("#2e1d12").lerp(BG, f))
	var sun := Vector2(sz.x * 0.8, sz.y * 0.3)
	for i in range(5, 0, -1):
		draw_circle(sun, 26.0 * i, Color(0.9, 0.45, 0.15, 0.04))
	draw_circle(sun, 28.0, Color(0.95, 0.6, 0.3, 0.4))
