class_name Updater
extends Node
## Keeps the installed game in sync with the latest signed release.
##
## Security model:
##  * The launcher holds NO secrets. It only knows the PUBLIC half of the release key.
##  * Each game release ships manifest.json + manifest.json.sig. The signature is made
##    in CI with the private key (a GitHub secret). We verify it before trusting anything.
##  * The manifest pins the SHA-256 of the zip and of every file inside it, so a
##    modified or corrupted download is rejected.
##  * Older builds are never installed over newer ones (no rollback attacks).

signal status(text: String)
signal progress(fraction: float)   # 0..1, or -1 when unknown

const REPO := "TheDrTesla/The-wild-things"
const GAME_TAG_PREFIX := "game-v"
const LAUNCHER_TAG_PREFIX := "launcher-v"
# Each game release carries one signed manifest per platform. Windows keeps the
# original name so launchers already out there keep working.
var platform := "linux" if OS.get_name() == "Linux" else "windows"
var manifest_name := "manifest-linux.json" if platform == "linux" else "manifest.json"
var signature_name := manifest_name + ".sig"

const INSTALL_DIR := "user://game"
const STAGING_DIR := "user://game_staging"
const DOWNLOAD_PATH := "user://download.zip"
const STATE_PATH := "user://installed.json"

const PUBLIC_KEY := """-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA7V38qKtPopGWUTTFRVsb
krCzB6mwFKHjU2F2TZLgctdYOh6rIzGzt80OZ8CZxz2mVCy8YtwUEfIDaE0UleHr
O0k+tO0TMcy0u3SMp99dp0BlvvnNc3Nlbxl5PaiAHCX49PkkjwOBWvJTTvn85z3o
WF+FfRphyFMgBuTbQzNFV0ztj7wi3blFDAVJfxzKrS/PoZZoA0xpftjxk8H3VM1m
+ilF+LKHuHWUGoW+ggvGTBPnhD+Tbw6EfiamzEw4gfFiZCTq87kfnc/y7I3QVNja
VRt/fIPLI3aBl29mgCmpa3T/P24M/yaNDFYYApCOqER9NG/h1fXlif7nm07i1t9q
QPCJIMumxCTvEQupa78GQ7R/TtemWXsDwkGswhi3fXW5msC3kp4AKoIKZ8LLpxQi
m05DMuyDFzz+WotJ7NzKBiNoJUn89DRsosy/fmJfFQPPBP429CRU2w3HC4rgXJDE
7GpZ7HY77ZLLGnwJiBQOea9bV6SehiAQ7HQqkTA5zVxlAgMBAAE=
-----END PUBLIC KEY-----"""

var api_base := "https://api.github.com"
var installed: Dictionary = {}       # manifest of the installed build
var release_notes := ""
var launcher_update: Dictionary = {} # newer launcher release, if any
var _downloading: HTTPRequest
var _download_total := 0

func _ready() -> void:
	# Debug builds can point at a local test server: --api=http://127.0.0.1:8765
	if OS.is_debug_build():
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--api="):
				api_base = a.substr(6)

func _process(_delta: float) -> void:
	if _downloading and _download_total > 0:
		progress.emit(clampf(float(_downloading.get_downloaded_bytes()) / _download_total, 0.0, 1.0))

# --- Public API -------------------------------------------------------------------
func load_installed() -> void:
	installed = {}
	if FileAccess.file_exists(STATE_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
		if typeof(data) == TYPE_DICTIONARY:
			installed = data

## True when a build is installed and every file still matches its signed hash
func installed_ok() -> bool:
	if installed.is_empty() or not installed.has("files"):
		return false
	for f in installed["files"]:
		var p: String = INSTALL_DIR + "/" + f
		if not FileAccess.file_exists(p) or FileAccess.get_sha256(p) != installed["files"][f]:
			return false
	return true

func installed_version() -> String:
	return str(installed.get("version", ""))

func game_exe_path() -> String:
	return ProjectSettings.globalize_path(INSTALL_DIR + "/" + str(installed.get("exe", "")))

## Checks for a new release and installs it. Returns {"ok": bool, "message": String}.
## ok = true means a verified build is installed and ready to play.
func check_and_update(force_reinstall := false) -> Dictionary:
	load_installed()
	status.emit("Verifying installed files...")
	progress.emit(-1)
	var local_ok := installed_ok() and not force_reinstall

	status.emit("Checking for updates...")
	var res := await _fetch("%s/repos/%s/releases?per_page=30" % [api_base, REPO])
	if not res["ok"]:
		return _fallback(local_ok, "Could not reach the update server (%s)." % res["error"])
	var releases = JSON.parse_string(res["body"].get_string_from_utf8())
	if typeof(releases) != TYPE_ARRAY:
		return _fallback(local_ok, "Update server sent an unexpected reply.")

	var game_rel := _newest(releases, GAME_TAG_PREFIX)
	_check_launcher(releases)
	if game_rel.is_empty():
		return _fallback(local_ok, "No game build has been published yet.")
	release_notes = str(game_rel.get("body", ""))

	# 1. Download and verify the signed manifest
	var manifest_asset := _asset(game_rel, manifest_name)
	var sig_asset := _asset(game_rel, signature_name)
	if manifest_asset.is_empty() or sig_asset.is_empty():
		return _fallback(local_ok, "Latest release is missing its signature files.")
	var m_res := await _fetch(manifest_asset["browser_download_url"])
	var s_res := await _fetch(sig_asset["browser_download_url"])
	if not m_res["ok"] or not s_res["ok"]:
		return _fallback(local_ok, "Could not download release information.")
	if not verify_signature(m_res["body"], s_res["body"]):
		return _fallback(local_ok, "SECURITY: the latest release failed signature verification and was ignored.")
	var manifest = JSON.parse_string(m_res["body"].get_string_from_utf8())
	if not _manifest_valid(manifest, game_rel):
		return _fallback(local_ok, "Release manifest is invalid.")

	# 2. Already up to date? (also refuses to "update" to an older build)
	if local_ok and int(manifest["build"]) <= int(installed.get("build", 0)):
		return {"ok": true, "message": "Up to date — version %s" % installed_version()}

	# 3. Download the game archive
	var zip_asset := _asset(game_rel, manifest["file"])
	if zip_asset.is_empty() or int(zip_asset.get("size", -1)) != int(manifest["size"]):
		return _fallback(local_ok, "Release archive is missing or the wrong size.")
	status.emit("Downloading version %s..." % manifest["version"])
	var dl := await _download(zip_asset["browser_download_url"], DOWNLOAD_PATH, int(manifest["size"]))
	if not dl["ok"]:
		return _fallback(local_ok, "Download failed (%s)." % dl["error"])
	status.emit("Verifying download...")
	progress.emit(-1)
	if FileAccess.get_sha256(DOWNLOAD_PATH) != manifest["sha256"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DOWNLOAD_PATH))
		return _fallback(local_ok, "SECURITY: downloaded file does not match the signed checksum.")

	# 4. Extract to a staging folder, verify every file, then swap it in
	status.emit("Installing...")
	var err := _extract(DOWNLOAD_PATH, STAGING_DIR, manifest["files"])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DOWNLOAD_PATH))
	if err != "":
		_remove_dir(STAGING_DIR)
		return _fallback(local_ok, err)
	if platform == "linux":
		# Zip extraction doesn't keep the executable bit
		FileAccess.set_unix_permissions(ProjectSettings.globalize_path(STAGING_DIR + "/" + str(manifest["exe"])),
			FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER \
			| FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_EXECUTE_GROUP \
			| FileAccess.UNIX_READ_OTHER | FileAccess.UNIX_EXECUTE_OTHER)
	_remove_dir(INSTALL_DIR)
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(STAGING_DIR), ProjectSettings.globalize_path(INSTALL_DIR)) != OK:
		return {"ok": false, "message": "Could not move the game into place. Is the game still running?"}
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, "\t"))
	f.close()
	load_installed()
	progress.emit(1.0)
	return {"ok": true, "message": "Updated to version %s" % installed_version()}

## RSA-SHA256 check of `data` against `signature` using the embedded public key
func verify_signature(data: PackedByteArray, signature: PackedByteArray) -> bool:
	var key := CryptoKey.new()
	if key.load_from_string(PUBLIC_KEY, true) != OK:
		push_error("Embedded public key is invalid")
		return false
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return Crypto.new().verify(HashingContext.HASH_SHA256, ctx.finish(), signature, key)

# --- Internals ----------------------------------------------------------------------
func _fallback(local_ok: bool, why: String) -> Dictionary:
	if local_ok:
		return {"ok": true, "message": why + " Playing installed version %s." % installed_version()}
	return {"ok": false, "message": why}

func _newest(releases: Array, prefix: String) -> Dictionary:
	# GitHub lists newest first; skip drafts and pre-releases
	for r in releases:
		if typeof(r) == TYPE_DICTIONARY and str(r.get("tag_name", "")).begins_with(prefix) \
				and not r.get("draft", false) and not r.get("prerelease", false):
			return r
	return {}

func _check_launcher(releases: Array) -> void:
	launcher_update = {}
	var rel := _newest(releases, LAUNCHER_TAG_PREFIX)
	if rel.is_empty():
		return
	var remote: String = str(rel["tag_name"]).substr(LAUNCHER_TAG_PREFIX.length())
	var mine: String = ProjectSettings.get_setting("application/config/version")
	if _version_greater(remote, mine):
		launcher_update = rel

static func _version_greater(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false

func _asset(release: Dictionary, name: String) -> Dictionary:
	for a in release.get("assets", []):
		if a.get("name", "") == name:
			return a
	return {}

func _manifest_valid(m, release: Dictionary) -> bool:
	if typeof(m) != TYPE_DICTIONARY:
		return false
	for k in ["version", "build", "file", "size", "sha256", "exe", "files", "tag"]:
		if not m.has(k):
			return false
	if str(m["tag"]) != str(release.get("tag_name", "")):
		return false  # manifest must belong to this exact release
	if str(m.get("platform", "windows")) != platform:
		return false  # older manifests have no platform and are Windows builds
	if typeof(m["files"]) != TYPE_DICTIONARY or not m["files"].has(m["exe"]):
		return false
	for path in m["files"]:
		if not _safe_path(path):
			return false
	return _safe_path(m["file"])

## Rejects absolute paths and "../" tricks so a release can only write inside the game folder
static func _safe_path(p: String) -> bool:
	if p == "" or p.begins_with("/") or p.begins_with("\\") or p.contains(":") or p.contains("\\"):
		return false
	for part in p.split("/"):
		if part == ".." or part == ".":
			return false
	return true

func _extract(zip_path: String, dest: String, expected: Dictionary) -> String:
	_remove_dir(dest)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest))
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "Downloaded archive is damaged."
	var seen := {}
	for entry in zip.get_files():
		if entry.ends_with("/"):
			continue
		if not expected.has(entry):
			zip.close()
			return "SECURITY: archive contains an unexpected file (%s)." % entry
		var data := zip.read_file(entry)
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(data)
		if ctx.finish().hex_encode() != expected[entry]:
			zip.close()
			return "SECURITY: %s does not match the signed checksum." % entry
		var out_path := dest + "/" + entry
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			zip.close()
			return "Could not write %s." % entry
		f.store_buffer(data)
		f.close()
		seen[entry] = true
	zip.close()
	if seen.size() != expected.size():
		return "Archive is missing files."
	return ""

func _remove_dir(path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var d := DirAccess.open(abs_path)
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_dir(path + "/" + sub)
	for file in d.get_files():
		DirAccess.remove_absolute(abs_path + "/" + file)
	DirAccess.remove_absolute(abs_path)

func _headers() -> PackedStringArray:
	var v: String = ProjectSettings.get_setting("application/config/version")
	return PackedStringArray(["User-Agent: CtrlAltSalvage-Launcher/" + v, "Accept: application/vnd.github+json"])

func _fetch(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = 30.0
	add_child(http)
	var err := http.request(url, _headers())
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request error %d" % err}
	var r: Array = await http.request_completed
	http.queue_free()
	return _result(r)

func _download(url: String, path: String, total: int) -> Dictionary:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.download_file = path
	http.download_chunk_size = 262144
	add_child(http)
	_downloading = http
	_download_total = total
	var err := http.request(url, _headers())
	if err != OK:
		_downloading = null
		http.queue_free()
		return {"ok": false, "error": "request error %d" % err}
	var r: Array = await http.request_completed
	_downloading = null
	http.queue_free()
	return _result(r)

func _result(r: Array) -> Dictionary:
	var result: int = r[0]
	var code: int = r[1]
	if result in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_TIMEOUT]:
		return {"ok": false, "error": "no internet connection"}
	if result == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
		return {"ok": false, "error": "secure connection failed"}
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "network error %d" % result}
	if code == 403 or code == 429:
		return {"ok": false, "error": "rate limited, try again in a few minutes"}
	if code < 200 or code >= 300:
		return {"ok": false, "error": "HTTP %d" % code}
	return {"ok": true, "body": r[3]}
