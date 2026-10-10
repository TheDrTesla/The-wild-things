extends Node
## Test helper: runs one update check and prints the result as JSON.
##   godot --headless --path . res://tools/run_update.tscn -- --api=http://127.0.0.1:8765 [--force]

func _ready() -> void:
	var u := Updater.new()
	add_child(u)
	await get_tree().process_frame
	var force := OS.get_cmdline_user_args().has("--force")
	var res: Dictionary = await u.check_and_update(force)
	res["installed_version"] = u.installed_version()
	res["installed_ok"] = u.installed_ok()
	res["launcher_update"] = u.launcher_update.get("tag_name", "")
	print("RESULT:" + JSON.stringify(res))
	get_tree().quit()
