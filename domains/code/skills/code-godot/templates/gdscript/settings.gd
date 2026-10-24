# settings.gd — autoload owning the options a player expects to survive a
# restart: three volumes, fullscreen, vsync, and any key the player remapped.
# It is the only thing that touches user://settings.cfg, and it applies what it
# loaded in _ready(), so every scene boots with the player's choices already on.
#
# Expected scene tree: none. This is a script autoload, not a scene.
#
# Autoload: YES, as `Settings`. Create the audio buses FIRST — a volume written
#   to a bus that does not exist is silently lost:
#   setup_audio_buses '{"buses":[{"name":"Master","volume_db":0.0},
#     {"name":"Music","send":"Master","volume_db":-6.0},
#     {"name":"SFX","send":"Master","volume_db":-3.0}],
#     "save_path":"audio/default_bus_layout.tres","set_project_setting":true}'
#   project_batch '{"actions":[
#     {"type":"add_autoload","autoload_name":"Settings","path":"res://scripts/settings.gd"}]}'
#
# Input actions: none of its own. It re-applies whatever input_remap.gd saved.
#
# Attach with: nothing to attach. Use it as
#   Settings.set_music_volume(0.4)
#   Settings.save()
extends Node

## Emitted for each volume change with the linear 0.0-1.0 value the UI works in.
signal volume_changed(bus_name: String, linear: float)
signal display_changed
signal settings_loaded
signal settings_saved

const CONFIG_PATH: String = "user://settings.cfg"
const MASTER_BUS: StringName = &"Master"
const MUSIC_BUS: StringName = &"Music"
const SFX_BUS: StringName = &"SFX"
## Below this a bus is muted instead of being set to -inf dB, which is what
## linear_to_db(0.0) returns and what a slider dragged to 0 would otherwise write.
const SILENCE: float = 0.0005

var master_volume: float = 1.0
var music_volume: float = 0.8
var sfx_volume: float = 0.8
var fullscreen: bool = false
var vsync: bool = true

## action name -> Array of serialized events, written by input_remap.gd.
var _input_overrides: Dictionary = {}


func _ready() -> void:
	load_settings()
	apply_all()


# --- volumes ---------------------------------------------------------------

## `linear` is the 0.0-1.0 value a slider produces. The dB conversion happens
## here so no caller ever has to think in decibels.
func set_volume(bus_name: StringName, linear: float) -> void:
	var value: float = clampf(linear, 0.0, 1.0)
	match bus_name:
		MASTER_BUS:
			master_volume = value
		MUSIC_BUS:
			music_volume = value
		SFX_BUS:
			sfx_volume = value
		_:
			push_warning("Settings: unknown bus '%s' — known: Master, Music, SFX." % bus_name)
			return
	_apply_bus(bus_name, value)
	volume_changed.emit(String(bus_name), value)


func set_master_volume(linear: float) -> void:
	set_volume(MASTER_BUS, linear)


func set_music_volume(linear: float) -> void:
	set_volume(MUSIC_BUS, linear)


func set_sfx_volume(linear: float) -> void:
	set_volume(SFX_BUS, linear)


func volume_of(bus_name: StringName) -> float:
	match bus_name:
		MUSIC_BUS:
			return music_volume
		SFX_BUS:
			return sfx_volume
		_:
			return master_volume


# --- display ---------------------------------------------------------------

func set_fullscreen(value: bool) -> void:
	fullscreen = value
	_apply_display()
	display_changed.emit()


func set_vsync(value: bool) -> void:
	vsync = value
	_apply_display()
	display_changed.emit()


# --- input overrides -------------------------------------------------------

## Replaces the InputMap events of one action and remembers them for the next
## launch. An empty array records "deliberately unbound" — use
## clear_action_override() to go back to the project default instead.
func set_action_events(action: StringName, events: Array[InputEvent]) -> void:
	if not InputMap.has_action(action):
		push_error("Settings: no input action '%s' — create it with project_batch add_input_action." % action)
		return
	InputMap.action_erase_events(action)
	var rows: Array = []
	for event in events:
		if event == null:
			continue
		InputMap.action_add_event(action, event)
		var row: Dictionary = _event_to_dict(event)
		if not row.is_empty():
			rows.append(row)
	_input_overrides[String(action)] = rows


func clear_action_override(action: StringName) -> void:
	_input_overrides.erase(String(action))


## Every remapped action, as {action: [{type, ...}]}. Plain data — this is what
## lands in the [input] section of settings.cfg.
func action_overrides() -> Dictionary:
	return _input_overrides.duplicate(true)


## Pushes the saved overrides back into the InputMap. Called by _ready(); call
## it again after InputMap.load_from_project_settings().
func apply_input_overrides() -> void:
	for key in _input_overrides.keys():
		var action: StringName = StringName(str(key))
		if not InputMap.has_action(action):
			push_warning("Settings: saved binding for unknown action '%s' — ignored." % action)
			continue
		var raw: Variant = _input_overrides[key]
		if not (raw is Array):
			continue
		var rows: Array = raw
		var events: Array[InputEvent] = []
		for entry in rows:
			if not (entry is Dictionary):
				continue
			var event: InputEvent = _event_from_dict(entry)
			if event != null:
				events.append(event)
		# An empty list is a real state ("the player unbound this"), so the
		# erase happens either way.
		InputMap.action_erase_events(action)
		for event in events:
			InputMap.action_add_event(action, event)


# --- persistence -----------------------------------------------------------

func apply_all() -> void:
	_apply_bus(MASTER_BUS, master_volume)
	_apply_bus(MUSIC_BUS, music_volume)
	_apply_bus(SFX_BUS, sfx_volume)
	_apply_display()
	apply_input_overrides()


## Writes user://settings.cfg. Returns false and says why when it cannot.
func save() -> bool:
	var config := ConfigFile.new()
	config.set_value("audio", "master", master_volume)
	config.set_value("audio", "music", music_volume)
	config.set_value("audio", "sfx", sfx_volume)
	config.set_value("display", "fullscreen", fullscreen)
	config.set_value("display", "vsync", vsync)
	for key in _input_overrides.keys():
		config.set_value("input", str(key), _input_overrides[key])
	var error: Error = config.save(CONFIG_PATH)
	if error != OK:
		push_error("Settings: cannot write %s (%s)" % [CONFIG_PATH, error_string(error)])
		return false
	settings_saved.emit()
	return true


## Reads user://settings.cfg into memory. A missing file is not an error (first
## launch); a corrupt one is reported and the defaults stand.
func load_settings() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		return false
	var config := ConfigFile.new()
	var error: Error = config.load(CONFIG_PATH)
	if error != OK:
		push_error("Settings: %s is unreadable (%s) — using defaults." % [CONFIG_PATH, error_string(error)])
		return false

	master_volume = clampf(float(config.get_value("audio", "master", master_volume)), 0.0, 1.0)
	music_volume = clampf(float(config.get_value("audio", "music", music_volume)), 0.0, 1.0)
	sfx_volume = clampf(float(config.get_value("audio", "sfx", sfx_volume)), 0.0, 1.0)
	fullscreen = bool(config.get_value("display", "fullscreen", fullscreen))
	vsync = bool(config.get_value("display", "vsync", vsync))

	_input_overrides = {}
	if config.has_section("input"):
		for key in config.get_section_keys("input"):
			var raw: Variant = config.get_value("input", key, [])
			if raw is Array:
				_input_overrides[key] = raw
	settings_loaded.emit()
	return true


func reset_to_defaults() -> void:
	master_volume = 1.0
	music_volume = 0.8
	sfx_volume = 0.8
	fullscreen = false
	vsync = true
	_input_overrides = {}
	InputMap.load_from_project_settings()
	apply_all()


# --- internals -------------------------------------------------------------

func _apply_bus(bus_name: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index == -1:
		push_warning("Settings: no '%s' audio bus — run setup_audio_buses." % bus_name)
		return
	var silent: bool = linear <= SILENCE
	AudioServer.set_bus_mute(index, silent)
	if not silent:
		AudioServer.set_bus_volume_db(index, linear_to_db(linear))


# Headless has no window, so the calls below do nothing there — which is why a
# scenario verifies fullscreen through this object and the .cfg, not through
# DisplayServer.window_get_mode().
func _apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


# Events are stored as plain dictionaries, not as ConfigFile objects: the file
# stays readable, and a binding saved by an older build cannot fail to load.
func _event_to_dict(event: InputEvent) -> Dictionary:
	var key_event := event as InputEventKey
	if key_event != null:
		return {
			"type": "key",
			"physical_keycode": int(key_event.physical_keycode),
			"keycode": int(key_event.keycode),
		}
	var pad_event := event as InputEventJoypadButton
	if pad_event != null:
		return {"type": "joypad_button", "button_index": int(pad_event.button_index)}
	var mouse_event := event as InputEventMouseButton
	if mouse_event != null:
		return {"type": "mouse_button", "button_index": int(mouse_event.button_index)}
	push_warning("Settings: %s cannot be saved — only key, joypad button and mouse button are." % event.get_class())
	return {}


func _event_from_dict(data: Dictionary) -> InputEvent:
	match str(data.get("type", "")):
		"key":
			var key_event := InputEventKey.new()
			key_event.physical_keycode = int(data.get("physical_keycode", 0)) as Key
			key_event.keycode = int(data.get("keycode", 0)) as Key
			return key_event
		"joypad_button":
			var pad_event := InputEventJoypadButton.new()
			pad_event.button_index = int(data.get("button_index", 0)) as JoyButton
			return pad_event
		"mouse_button":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(data.get("button_index", 1)) as MouseButton
			return mouse_event
	push_warning("Settings: unknown saved event type '%s' — ignored." % str(data.get("type", "")))
	return null
