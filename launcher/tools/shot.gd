extends Node
## Dev helper: renders the launcher and saves a PNG.  -- <out.png> [--api=...]
func _ready() -> void:
	var l: Node = load("res://launcher.tscn").instantiate()
	get_tree().root.add_child.call_deferred(l)
	await get_tree().create_timer(4.0).timeout
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
	get_tree().quit()
