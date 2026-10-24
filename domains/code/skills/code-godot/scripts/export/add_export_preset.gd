class_name GodotSkillAddExportPreset
extends RefCounted

# Creates or updates one entry in export_presets.cfg so a headless agent can
# ship a build. Godot has no CLI for this: the editor's Project > Export dialog
# is the only supported author, which is why references/export_targets.md used
# to say "create the baseline preset through Godot first".
#
# Why the file is edited as TEXT and not through ConfigFile:
# ConfigFile.load()/save() round-trips through the engine's variant writer and
# re-serialises every section, so a preset a human authored in the editor comes
# back reordered and reformatted. Presets carry signing identities, provisioning
# profiles and per-file customisation maps; rewriting them to add an unrelated
# target is not acceptable. This op therefore splits the file into raw section
# blocks, leaves every block it does not own byte-for-byte alone, and only
# rewrites (or appends) the two blocks of the requested preset.
#
# Verified on 4.7.stable: the default option block of every platform marked
# verified below was proven by a real --export-release of a scaffolded project
# on this machine (macOS arm64, export templates 4.7.stable).

var utils_script = preload("../core/utils.gd")

# Godot's exact platform strings (EditorExportPlatform::get_os_name()). "Linux"
# is NOT "Linux/X11" on 4.x — that name died with 3.x and a preset carrying it
# exports nothing.
const PLATFORM_TABLE := {
	"web": {
		"platform": "Web",
		"name": "Web",
		"subdir": "web",
		"artifact": "index.html",
		"artifact_style": "fixed",
		"verified": true,
		"prerequisites": []
	},
	"windows": {
		"platform": "Windows Desktop",
		"name": "Windows Desktop",
		"subdir": "windows",
		"artifact": ".exe",
		"artifact_style": "title",
		"verified": true,
		"prerequisites": []
	},
	"linux": {
		"platform": "Linux",
		"name": "Linux",
		"subdir": "linux",
		"artifact": ".x86_64",
		"artifact_style": "lower",
		"verified": true,
		"prerequisites": []
	},
	"macos": {
		"platform": "macOS",
		"name": "macOS",
		"subdir": "macos",
		"artifact": ".app",
		"artifact_style": "title",
		"verified": true,
		"prerequisites": [
			"Distribution outside your own machine needs an Apple Developer ID: set options codesign/identity and notarization/notarization. The default block ad-hoc signs, which runs locally but is blocked by Gatekeeper after a download."
		]
	},
	"android": {
		"platform": "Android",
		"name": "Android",
		"subdir": "android",
		"artifact": ".apk",
		"artifact_style": "lower",
		"verified": false,
		"prerequisites": [
			"Android SDK (platform-tools, build-tools, cmdline-tools) installed and set in the Godot editor setting export/android/android_sdk_path",
			"JDK 17 installed and set in the Godot editor setting export/android/java_sdk_path",
			"A debug keystore at the editor setting export/android/debug_keystore for --mode debug",
			"A release keystore in options keystore/release + keystore/release_user + keystore/release_password for --mode release",
			"Project setting rendering/textures/vram_compression/import_etc2_astc must be true",
			"Project setting application/config/icon must point at an existing image"
		]
	},
	"ios": {
		"platform": "iOS",
		"name": "iOS",
		"subdir": "ios",
		"artifact": ".ipa",
		"artifact_style": "title",
		"verified": false,
		"prerequisites": [
			"macOS host with Xcode installed",
			"An Apple Developer team id in options application/app_store_team_id (export fails with 'App Store Team ID not specified.' without it)",
			"A provisioning profile / signing identity for the bundle identifier",
			"Project setting rendering/textures/vram_compression/import_etc2_astc must be true",
			"The Godot export produces an Xcode project; archiving and delivery still happen in Xcode"
		]
	}
}

# Written in the order EditorExport::_save_presets() writes them, so a preset
# this op appends and one the editor appends differ only in whitespace.
# export_filter / include_filter / exclude_filter have no fallback in the
# engine: leaving any of them out makes every export print
# `ERROR: Couldn't find the given section "preset.N" and key "export_filter"`.
const PRESET_KEY_ORDER := [
	"name", "platform", "runnable", "advanced_options", "dedicated_server",
	"custom_features", "export_filter", "customized_files", "include_filter",
	"exclude_filter", "export_path", "patches", "encryption_include_filters",
	"encryption_exclude_filters", "seed", "encrypt_pck", "encrypt_directory",
	"script_export_mode"
]

# Files a dedicated-server build has no use for. Stripping them needs
# export_filter="customized" + a per-file "strip" map; `dedicated_server=true`
# on its own only adds the feature tag (measured: pck 36820 -> 36868 bytes,
# i.e. it grows). With the map: 36820 -> 2432 bytes.
const STRIPPABLE_EXTENSIONS := [
	"png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "exr", "hdr", "ktx", "dds"
]

func execute(params: Dictionary) -> void:
	var platform_key := str(params.get("platform", "")).strip_edges().to_lower()
	if platform_key.is_empty():
		utils_script.log_error(
			"add_export_preset requires platform (one of %s)" % ", ".join(PLATFORM_TABLE.keys()))
		return
	if not (platform_key in PLATFORM_TABLE):
		var nearest: PackedStringArray = utils_script.nearest_names(platform_key, PLATFORM_TABLE.keys())
		var message := "Unknown platform: %s. Supported: %s" % [platform_key, ", ".join(PLATFORM_TABLE.keys())]
		if not nearest.is_empty():
			message += " (did you mean " + ", ".join(nearest) + "?)"
		utils_script.log_error(message)
		return

	var spec: Dictionary = PLATFORM_TABLE[platform_key]
	var preset_name := str(params.get("name", spec["name"])).strip_edges()
	if preset_name.is_empty():
		utils_script.log_error("add_export_preset name must not be empty")
		return
	if preset_name.contains("\"") or preset_name.contains("\n"):
		utils_script.log_error("add_export_preset name must not contain quotes or newlines: " + preset_name)
		return

	var config_path := "res://export_presets.cfg"
	var existing_text := ""
	if FileAccess.file_exists(config_path):
		existing_text = FileAccess.get_file_as_string(config_path)
		if existing_text.is_empty() and FileAccess.get_open_error() != OK:
			utils_script.log_error("Failed to read %s: %s" % [config_path, error_string(FileAccess.get_open_error())])
			return

	var sections: Array = _parse_sections(existing_text)
	var presets: Array = _collect_presets(sections)

	var target_index := -1
	var existing_names := PackedStringArray()
	var runnable_taken := false
	for entry in presets:
		var entry_dict: Dictionary = entry
		existing_names.append(str(entry_dict["name"]))
		if str(entry_dict["name"]) == preset_name:
			target_index = int(entry_dict["index"])
		elif str(entry_dict["platform"]) == str(spec["platform"]) and bool(entry_dict["runnable"]):
			runnable_taken = true

	var overwrite := bool(params.get("overwrite", false))
	if target_index >= 0 and not overwrite:
		utils_script.log_error(
			("Export preset already exists: \"%s\" (preset.%d, platform %s). "
			+ "Pass \"overwrite\": true to replace it, or pick another \"name\". Existing presets: %s")
			% [preset_name, target_index, str(presets[_preset_slot(presets, target_index)]["platform"]),
			", ".join(existing_names)])
		return

	var dedicated_server := bool(params.get("dedicated_server", false))
	if dedicated_server and platform_key != "linux":
		utils_script.log_error(
			"dedicated_server is only supported for platform \"linux\" on 4.7 (requested: %s). "
			% platform_key
			+ "Run add_export_preset '{\"platform\":\"linux\",\"name\":\"Linux Server\",\"dedicated_server\":true}'")
		return

	# Everything the caller named explicitly wins over whatever the preset says
	# today; everything else keeps its current value on an update, so
	# "overwrite" to flip one option cannot silently reset custom_features, the
	# encryption filters, a hand-set export_filter or a signing identity.
	var authoritative := PackedStringArray(["name", "platform"])
	for key in ["runnable", "export_path", "custom_features", "export_filter",
			"include_filter", "exclude_filter", "dedicated_server"]:
		if params.has(str(key)):
			authoritative.append(str(key))

	var existing_values := {}
	var existing_options := {}
	if target_index >= 0:
		existing_values = _parse_keys(sections[_section_slot(sections, "preset.%d" % target_index)]["lines"])
		var options_slot := _section_slot(sections, "preset.%d.options" % target_index)
		if options_slot >= 0:
			existing_options = _parse_keys(sections[options_slot]["lines"])

	var base_name := _artifact_base_name(spec)
	var export_path := str(params.get("export_path", "")).strip_edges()
	if export_path.is_empty() and "export_path" in existing_values:
		export_path = _unquote(str(existing_values["export_path"]))
	if export_path.is_empty():
		# A custom preset name gets its own directory, or a second preset of the
		# same platform ("Linux" + "Linux Server") would overwrite the first
		# one's artifact on every "Export All".
		var subdir := str(spec["subdir"]) if preset_name == str(spec["name"]) else _slug(preset_name)
		export_path = "../build/%s/%s" % [subdir, base_name]

	var runnable_default := not runnable_taken
	var runnable := bool(params.get("runnable", runnable_default))

	var options: Dictionary = _default_options(platform_key)
	var raw_options: Variant = params.get("options", {})
	if not (raw_options is Dictionary):
		utils_script.log_error("add_export_preset options must be a JSON object of export option keys")
		return
	var user_options: Dictionary = raw_options
	for key in user_options.keys():
		options[str(key)] = user_options[key]

	var export_filter := str(params.get("export_filter", "")).strip_edges()
	var customized_files: Dictionary = {}
	if dedicated_server and export_filter.is_empty():
		customized_files = _strippable_files()
		if not customized_files.is_empty():
			export_filter = "customized"
			authoritative.append("export_filter")
			authoritative.append("customized_files")
	if export_filter.is_empty():
		export_filter = "all_resources"

	# macOS universal/arm64 and Android refuse to export while the project has
	# ETC2/ASTC import disabled ("Cannot export for universal or arm64 if ETC2
	# ASTC texture format is disabled"). It is a project setting, not a preset
	# option, so the preset alone cannot fix it — enable it and say so.
	var project_settings_changed := PackedStringArray()
	if _needs_etc2_astc(platform_key, options):
		var etc_key := "rendering/textures/vram_compression/import_etc2_astc"
		if not bool(ProjectSettings.get_setting(etc_key, false)):
			ProjectSettings.set_setting(etc_key, true)
			var settings_error := ProjectSettings.save()
			if settings_error != OK:
				utils_script.log_error("Failed to save project settings: " + error_string(settings_error))
				return
			project_settings_changed.append(etc_key + "=true")

	var preset_values: Dictionary = {
		"name": preset_name,
		"platform": str(spec["platform"]),
		"runnable": runnable,
		"advanced_options": false,
		"dedicated_server": dedicated_server,
		"custom_features": str(params.get("custom_features", "")),
		"export_filter": export_filter,
		"include_filter": str(params.get("include_filter", "")),
		"exclude_filter": str(params.get("exclude_filter", "")),
		"export_path": export_path,
		"patches": "__packed_string_array__",
		"encryption_include_filters": "",
		"encryption_exclude_filters": "",
		"seed": 0,
		"encrypt_pck": false,
		"encrypt_directory": false,
		"script_export_mode": 2
	}
	if not customized_files.is_empty():
		preset_values["customized_files"] = customized_files

	var created := target_index < 0
	if created:
		target_index = _next_free_index(sections)
		sections = _append_preset(sections, target_index, preset_values, options)
	else:
		sections = _rewrite_preset(sections, target_index, preset_values, options,
			authoritative, PackedStringArray(user_options.keys()))

	var rendered := _render_sections(sections)
	var handle := FileAccess.open(config_path, FileAccess.WRITE)
	if handle == null:
		utils_script.log_error("Failed to write %s: %s" % [config_path, error_string(FileAccess.get_open_error())])
		return
	handle.store_string(rendered)
	handle.close()

	var absolute_project := ProjectSettings.globalize_path("res://").rstrip("/")
	var absolute_output := _globalize_export_path(export_path)
	# Godot does not create the export directory: a missing one fails the export
	# with "Prepare Template: The given export path doesn't exist." Creating it
	# here is a convenience, never a gate — the preset itself is already valid,
	# and export_project.py makes the parent of its own output path anyway.
	var notes := PackedStringArray()
	var output_dir := absolute_output.get_base_dir()
	if not DirAccess.dir_exists_absolute(output_dir):
		var dir_error := DirAccess.make_dir_recursive_absolute(output_dir)
		if dir_error != OK:
			notes.append(
				("Could not create the export directory %s (%s). Godot fails an export into a "
				+ "missing directory with \"Prepare Template: The given export path doesn't exist.\" — "
				+ "create it, or pass a different export_path.") % [output_dir, error_string(dir_error)])
	if not bool(spec["verified"]):
		notes.append(
			("This preset block is the best known configuration for %s but was NOT proven by a real "
			+ "export while building this skill. Run export_project.py --preflight-only first.")
			% str(spec["platform"]))

	var wrapper := _skill_script_path("export_project.py")
	var mode := "debug" if platform_key == "android" else "release"
	var next_commands := PackedStringArray([
		"python3 %s %s \"%s\" %s --mode %s" % [wrapper, absolute_project, preset_name, absolute_output, mode],
		"python3 %s %s \"%s\" %s --preflight-only" % [wrapper, absolute_project, preset_name, absolute_output]
	])
	if platform_key == "web":
		next_commands.append("python3 %s %s --check" % [_skill_script_path("serve_web.py"), absolute_output.get_base_dir()])

	print(JSON.stringify({
		"ok": true,
		"preset_index": target_index,
		"name": preset_name,
		"platform": str(spec["platform"]),
		"export_path": export_path,
		"export_path_absolute": absolute_output,
		"created": created,
		"updated": not created,
		"verified": bool(spec["verified"]),
		"prerequisites": spec["prerequisites"],
		"notes": notes,
		"dedicated_server": dedicated_server,
		"stripped_files": customized_files.size(),
		"options": _effective_options(options, existing_options, PackedStringArray(user_options.keys())),
		"project_settings_changed": project_settings_changed,
		"config_path": config_path,
		"presets": _preset_name_list(_collect_presets(sections)),
		"next": next_commands
	}))

# --- platform defaults -----------------------------------------------------

func _default_options(platform_key: String) -> Dictionary:
	var identifier := _bundle_identifier()
	match platform_key:
		"web":
			# thread_support defaults to false in 4.7 (verified: an export with
			# the key absent and one with it false produce a byte-identical
			# index.js, 279815 bytes; true produces 314653). Keep it false: a
			# threaded build needs SharedArrayBuffer, which needs a
			# cross-origin-isolated host (COOP/COEP), so a threaded build is a
			# blank page on itch.io, GitHub Pages and every plain static host.
			# scripts/export/serve_web.py sends those headers, so flip it to
			# true only once the real host does too.
			return {
				"variant/extensions_support": false,
				"variant/thread_support": false,
				"html/export_icon": true
			}
		"windows":
			# No rcedit and no wine needed for a plain build (verified: the
			# exported .exe is a valid PE32+ x86-64 binary). rcedit is only
			# required to stamp the icon/version resources.
			return {"binary_format/architecture": "x86_64"}
		"linux":
			return {
				"binary_format/architecture": "x86_64",
				"binary_format/embed_pck": false
			}
		"macos":
			# The official 4.7 macos.zip ships ONLY godot_macos_{release,debug}
			# .universal — "x86_64" or "arm64" fail with `Requested template
			# binary "godot_macos_release.x86_64" not found`.
			# codesign 1 = built-in ad-hoc: it needs no Apple account, and the
			# resulting .app boots locally. notarization 0 = disabled; both are
			# warnings at export time, not errors.
			return {
				"binary_format/architecture": "universal",
				"application/bundle_identifier": identifier,
				"codesign/codesign": 1,
				"notarization/notarization": 0
			}
		"android":
			return {
				"gradle_build/use_gradle_build": false,
				"package/unique_name": identifier,
				"version/code": 1,
				"version/name": "1.0"
			}
		"ios":
			return {
				"application/bundle_identifier": identifier,
				"application/app_store_team_id": "",
				"application/short_version": "1.0",
				"application/version": "1.0"
			}
		_:
			return {}

func _needs_etc2_astc(platform_key: String, options: Dictionary) -> bool:
	if platform_key == "android" or platform_key == "ios":
		return true
	if platform_key != "macos":
		return false
	var arch_key := "binary_format/architecture"
	var architecture := "universal"
	if arch_key in options:
		architecture = str(options[arch_key])
	return architecture == "universal" or architecture == "arm64"

func _project_name() -> String:
	var raw: Variant = ProjectSettings.get_setting("application/config/name", "game")
	var name := str(raw).strip_edges()
	return name if not name.is_empty() else "game"

func _sanitize(name: String) -> String:
	var out := ""
	for index in range(name.length()):
		var glyph := name.substr(index, 1)
		if glyph.is_valid_identifier() or (glyph >= "0" and glyph <= "9"):
			out += glyph
	return out if not out.is_empty() else "game"

func _slug(text: String) -> String:
	var out := ""
	for glyph in text.to_lower():
		if (glyph >= "a" and glyph <= "z") or (glyph >= "0" and glyph <= "9"):
			out += glyph
		elif not out.ends_with("-") and not out.is_empty():
			out += "-"
	return out.trim_suffix("-") if not out.is_empty() else "custom"

func _artifact_base_name(spec: Dictionary) -> String:
	var suffix := str(spec["artifact"])
	if str(spec["artifact_style"]) == "fixed":
		return suffix
	var stem := _sanitize(_project_name())
	if str(spec["artifact_style"]) == "lower":
		stem = stem.to_lower()
	return stem + suffix

func _bundle_identifier() -> String:
	# Godot rejects an identifier without a dot, with an empty segment, with a
	# segment that starts with a digit, or with anything but letters, digits and
	# hyphens in a segment ("Invalid bundle identifier").
	var stem := ""
	for glyph in _sanitize(_project_name()).to_lower():
		if (glyph >= "a" and glyph <= "z") or (glyph >= "0" and glyph <= "9"):
			stem += glyph
	if stem.is_empty() or (stem[0] >= "0" and stem[0] <= "9"):
		stem = "app" + stem
	return "com.example." + stem

func _strippable_files() -> Dictionary:
	var found := {}
	_scan_strippable("res://", found)
	return found

func _scan_strippable(directory: String, found: Dictionary) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := directory.path_join(entry) if directory != "res://" else "res://" + entry
			if dir.current_is_dir():
				if not entry.begins_with("."):
					_scan_strippable(child, found)
			elif child.get_extension().to_lower() in STRIPPABLE_EXTENSIONS:
				found[child] = "strip"
		entry = dir.get_next()
	dir.list_dir_end()

func _skill_script_path(file_name: String) -> String:
	# The dispatcher loads op scripts by absolute path, so resource_path is the
	# on-disk location of this file and its siblings can be named absolutely.
	return str(get_script().resource_path).get_base_dir().path_join(file_name).simplify_path()

func _globalize_export_path(export_path: String) -> String:
	if export_path.begins_with("res://") or export_path.begins_with("user://"):
		return ProjectSettings.globalize_path(export_path)
	if export_path.begins_with("/"):
		return export_path
	return ProjectSettings.globalize_path("res://").path_join(export_path).simplify_path()

# --- export_presets.cfg text surgery ---------------------------------------

func _parse_sections(text: String) -> Array:
	# [{name, header, lines}]. `header` keeps the raw "[preset.0]" line so a
	# section this op does not touch is re-emitted byte-for-byte; the first
	# block (name "") holds anything before the first header, so a hand-written
	# banner comment survives too.
	var sections: Array = [{"name": "", "header": "", "lines": PackedStringArray()}]
	for line in text.split("\n"):
		var raw := str(line)
		var trimmed := raw.strip_edges()
		if trimmed.begins_with("[") and trimmed.ends_with("]") and trimmed.length() > 2:
			sections.append({
				"name": trimmed.substr(1, trimmed.length() - 2),
				"header": raw,
				"lines": PackedStringArray()
			})
		else:
			var block: Dictionary = sections[sections.size() - 1]
			var lines: PackedStringArray = block["lines"]
			lines.append(raw)
			block["lines"] = lines
	return sections

func _section_slot(sections: Array, name: String) -> int:
	for index in range(sections.size()):
		var block: Dictionary = sections[index]
		if str(block["name"]) == name:
			return index
	return -1

func _collect_presets(sections: Array) -> Array:
	var presets: Array = []
	var index := 0
	while true:
		var slot := _section_slot(sections, "preset.%d" % index)
		if slot < 0:
			break
		var keys: Dictionary = _parse_keys(sections[slot]["lines"])
		presets.append({
			"index": index,
			"name": _unquote(_key_or(keys, "name", "")),
			"platform": _unquote(_key_or(keys, "platform", "")),
			"runnable": _key_or(keys, "runnable", "false").strip_edges() == "true"
		})
		index += 1
	return presets

func _preset_slot(presets: Array, preset_index: int) -> int:
	for slot in range(presets.size()):
		var entry: Dictionary = presets[slot]
		if int(entry["index"]) == preset_index:
			return slot
	return 0

func _preset_name_list(presets: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for entry in presets:
		var entry_dict: Dictionary = entry
		names.append(str(entry_dict["name"]))
	return names

func _key_or(keys: Dictionary, key: String, fallback: String) -> String:
	if key in keys:
		return str(keys[key])
	return fallback

func _unquote(value: String) -> String:
	var trimmed := value.strip_edges()
	if trimmed.length() >= 2 and trimmed.begins_with("\"") and trimmed.ends_with("\""):
		return trimmed.substr(1, trimmed.length() - 2)
	return trimmed

func _next_free_index(sections: Array) -> int:
	# EditorExport::load_config() reads preset.0, preset.1, ... and stops at the
	# first gap, so the indices have to stay contiguous.
	var index := 0
	while _section_slot(sections, "preset.%d" % index) >= 0:
		index += 1
	return index

func _parse_keys(lines: PackedStringArray) -> Dictionary:
	# key -> raw value text. A value may span lines (Godot writes dictionaries
	# and arrays multi-line), so continuation lines are accumulated until the
	# brackets balance.
	var keys := {}
	var pending_key := ""
	var pending_value := ""
	var depth := 0
	for raw_line in lines:
		var line := str(raw_line)
		if not pending_key.is_empty():
			pending_value += "\n" + line
			depth += _bracket_delta(line)
			if depth <= 0:
				keys[pending_key] = pending_value
				pending_key = ""
				pending_value = ""
				depth = 0
			continue
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with(";") or trimmed.begins_with("#"):
			continue
		var split := line.find("=")
		if split <= 0:
			continue
		var key := line.substr(0, split).strip_edges()
		var value := line.substr(split + 1)
		depth = _bracket_delta(value)
		if depth > 0:
			pending_key = key
			pending_value = value
		else:
			keys[key] = value
			depth = 0
	if not pending_key.is_empty():
		keys[pending_key] = pending_value
	return keys

func _bracket_delta(text: String) -> int:
	var depth := 0
	var in_string := false
	for index in range(text.length()):
		var glyph := text[index]
		if glyph == "\"":
			in_string = not in_string
		elif not in_string:
			if glyph == "{" or glyph == "[" or glyph == "(":
				depth += 1
			elif glyph == "}" or glyph == "]" or glyph == ")":
				depth -= 1
	return depth

func _render_values(values: Dictionary, order: Array, preserved: Dictionary,
		authoritative: PackedStringArray) -> PackedStringArray:
	var lines := PackedStringArray([""])
	var written := {}
	for key in order:
		var name := str(key)
		var text := _merged_value(name, values, preserved, authoritative)
		if text.is_empty():
			continue
		lines.append("%s=%s" % [name, text])
		written[name] = true
	# Keys the editor (or a future Godot) wrote that this op knows nothing about
	# keep their exact text and follow the known block.
	for key in preserved.keys():
		var name := str(key)
		if not (name in written):
			lines.append("%s=%s" % [name, str(preserved[name]).strip_edges()])
	lines.append("")
	return lines

func _render_options(options: Dictionary, preserved: Dictionary,
		authoritative: PackedStringArray) -> PackedStringArray:
	var lines := PackedStringArray([""])
	var written := {}
	for key in options.keys():
		var name := str(key)
		lines.append("%s=%s" % [name, _merged_value(name, options, preserved, authoritative)])
		written[name] = true
	for key in preserved.keys():
		var name := str(key)
		if not (name in written):
			lines.append("%s=%s" % [name, str(preserved[name]).strip_edges()])
	if lines.size() == 1:
		# ConfigFile treats a section with no keys as absent:
		# `ERROR: Cannot get keys from nonexistent section "preset.0.options"`.
		lines.append("custom_template/debug=\"\"")
	lines.append("")
	return lines

func _effective_options(options: Dictionary, preserved: Dictionary,
		overrides: PackedStringArray) -> Dictionary:
	# What the options block now holds, so the payload never claims a default
	# the op deliberately did not overwrite.
	var effective := {}
	for key in options.keys():
		var name := str(key)
		if name in preserved and not (name in overrides):
			effective[name] = str_to_var(str(preserved[name]).strip_edges())
		else:
			effective[name] = _whole_floats_to_int(options[name])
	for key in preserved.keys():
		var name := str(key)
		if not (name in effective):
			effective[name] = str_to_var(str(preserved[name]).strip_edges())
	return effective

func _whole_floats_to_int(value: Variant) -> Variant:
	# JSON has one number type, so an option written to the file as `7` arrives
	# here as 7.0; report what the file says, not what JSON parsing did.
	if value is float:
		var number: float = value
		if is_equal_approx(number, floor(number)) and absf(number) < 9.0e15:
			return int(number)
	return value

func _merged_value(name: String, values: Dictionary, preserved: Dictionary,
		authoritative: PackedStringArray) -> String:
	if name in preserved and not (name in authoritative):
		return str(preserved[name]).strip_edges()
	if name in values:
		return _encode(values[name])
	return ""

func _encode(value: Variant) -> String:
	if value is String and str(value) == "__packed_string_array__":
		return "PackedStringArray()"
	if value is float:
		var number: float = value
		if is_equal_approx(number, floor(number)) and absf(number) < 9.0e15:
			return str(int(number))
	return var_to_str(value)

func _append_preset(sections: Array, index: int, values: Dictionary, options: Dictionary) -> Array:
	var tail: Dictionary = sections[sections.size() - 1]
	var tail_lines: PackedStringArray = tail["lines"]
	if tail_lines.is_empty() or not str(tail_lines[tail_lines.size() - 1]).strip_edges().is_empty():
		tail_lines.append("")
		tail["lines"] = tail_lines
	var everything := PackedStringArray(values.keys())
	everything.append_array(PackedStringArray(options.keys()))
	sections.append({
		"name": "preset.%d" % index,
		"header": "[preset.%d]" % index,
		"lines": _render_values(values, PRESET_KEY_ORDER, {}, everything)
	})
	sections.append({
		"name": "preset.%d.options" % index,
		"header": "[preset.%d.options]" % index,
		"lines": _render_options(options, {}, everything)
	})
	return sections

func _rewrite_preset(sections: Array, index: int, values: Dictionary, options: Dictionary,
		authoritative: PackedStringArray, option_overrides: PackedStringArray) -> Array:
	var preset_name := "preset.%d" % index
	var preset_slot := _section_slot(sections, preset_name)
	var preserved_values: Dictionary = _parse_keys(sections[preset_slot]["lines"])
	# A preset that used to be "customized" and is not any more must lose its
	# stale file map, or the export silently keeps the old strip decisions.
	if "customized_files" in authoritative and not ("customized_files" in values):
		preserved_values.erase("customized_files")
	sections[preset_slot] = {
		"name": preset_name,
		"header": "[%s]" % preset_name,
		"lines": _render_values(values, PRESET_KEY_ORDER, preserved_values, authoritative)
	}

	var options_name := preset_name + ".options"
	var options_slot := _section_slot(sections, options_name)
	var preserved_options := {}
	if options_slot >= 0:
		preserved_options = _parse_keys(sections[options_slot]["lines"])
		sections[options_slot] = {
			"name": options_name,
			"header": "[%s]" % options_name,
			"lines": _render_options(options, preserved_options, option_overrides)
		}
	else:
		sections.insert(preset_slot + 1, {
			"name": options_name,
			"header": "[%s]" % options_name,
			"lines": _render_options(options, preserved_options, option_overrides)
		})
	return sections

func _render_sections(sections: Array) -> String:
	# Split-then-join over the same "\n" separator, so every block this op did
	# not rewrite comes back exactly as it was read.
	var tokens := PackedStringArray()
	for entry in sections:
		var block: Dictionary = entry
		var header := str(block["header"])
		var lines: PackedStringArray = block["lines"]
		if header.is_empty() and "\n".join(lines).strip_edges().is_empty():
			continue
		if not header.is_empty():
			tokens.append(header)
		tokens.append_array(lines)
	return "\n".join(tokens)
