# settings_menu.gd — the options screen: three volume sliders, fullscreen and
# vsync toggles, all bound to the `Settings` autoload. It stores nothing of its
# own; Settings owns the values and the file they are written to.
#
# It works in both places a settings screen is reached from:
#   * its own scene, opened by main_menu.gd's Settings button — set
#     `return_scene` and Back changes scene through SceneTransition;
#   * a panel inside the pause menu — leave `return_scene` empty, call open(),
#     and Back hides the panel and emits `closed`.
#
# Expected scene tree (node name : type) — containers first, per
# references/game_ui.md "Pause And Settings Panel":
#   SettingsMenu : Control            <- attach this script here
#     Frame : MarginContainer         layout_preset FULL_RECT
#       Column : VBoxContainer
#         Title : Label
#         Rule : HSeparator
#         Grid : GridContainer        columns = 2
#           MasterLabel : Label
#           MasterSlider : HSlider    unique_name_in_owner = true  (%MasterSlider)
#           MusicLabel : Label
#           MusicSlider : HSlider     unique_name_in_owner = true  (%MusicSlider)
#           SfxLabel : Label
#           SfxSlider : HSlider       unique_name_in_owner = true  (%SfxSlider)
#           FullscreenLabel : Label
#           FullscreenCheck : CheckButton  unique_name_in_owner = true  (%FullscreenCheck)
#           VsyncLabel : Label
#           VsyncCheck : CheckButton  unique_name_in_owner = true  (%VsyncCheck)
#         Actions : HBoxContainer
#           BackButton : Button       unique_name_in_owner = true  (%BackButton)
#   The six %-nodes MUST have unique_name_in_owner set, or `%Name` is null.
#   The three sliders run 0-100 (min_value 0, max_value 100, step 1); this
#   script divides by 100 so Settings always sees a 0.0-1.0 linear volume.
#   Give both CheckButtons a text of ON/OFF in the scene: this script keeps it
#   in sync, and an empty switch is invisible to dump_tree and ui_report.
#
# Autoload: needs `Settings` registered, and `SceneTransition` when
#   `return_scene` is set.
#
# Input actions: none beyond the built-in ui_* set.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/settings_menu.tscn","actions":[
#     {"type":"configure_node","node_path":"root/Frame/Column/Grid/MasterSlider","unique_name_in_owner":true},
#     {"type":"attach_script","node_path":"root","script_path":"scripts/settings_menu.gd",
#      "script_properties":{"return_scene":"res://scenes/main_menu.tscn"}}]}'
extends Control

signal closed

## Non-empty: Back changes to this scene. Empty: Back hides this node and emits
## `closed`, which is what the pause menu wants.
@export_file("*.tscn") var return_scene: String = ""
## Write settings.cfg on every change. Turn it off to save only on Back.
@export var save_on_change: bool = true

@onready var _master_slider: HSlider = %MasterSlider
@onready var _music_slider: HSlider = %MusicSlider
@onready var _sfx_slider: HSlider = %SfxSlider
@onready var _fullscreen_check: CheckButton = %FullscreenCheck
@onready var _vsync_check: CheckButton = %VsyncCheck
@onready var _back_button: Button = %BackButton

## Set while the widgets are being filled from Settings, so writing a slider's
## value does not bounce straight back into Settings as a "change".
var _syncing: bool = false


## A CheckButton with no text is invisible in a dump_tree and in a ui_report —
## the label lives in the grid cell next to it. Writing ON/OFF into the button
## makes the state readable without a screenshot.
static func _switch_text(value: bool) -> String:
	return "ON" if value else "OFF"


func _ready() -> void:
	_master_slider.value_changed.connect(_on_master_changed)
	_music_slider.value_changed.connect(_on_music_changed)
	_sfx_slider.value_changed.connect(_on_sfx_changed)
	_fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	_vsync_check.toggled.connect(_on_vsync_toggled)
	_back_button.pressed.connect(_on_back_pressed)
	sync_from_settings()
	_master_slider.grab_focus()


## Pull every widget from the autoload. Call it whenever the panel is shown:
## another screen may have changed a volume in the meantime.
func sync_from_settings() -> void:
	_syncing = true
	_master_slider.value = Settings.master_volume * 100.0
	_music_slider.value = Settings.music_volume * 100.0
	_sfx_slider.value = Settings.sfx_volume * 100.0
	_fullscreen_check.button_pressed = Settings.fullscreen
	_fullscreen_check.text = _switch_text(Settings.fullscreen)
	_vsync_check.button_pressed = Settings.vsync
	_vsync_check.text = _switch_text(Settings.vsync)
	_syncing = false


func open() -> void:
	sync_from_settings()
	visible = true
	_master_slider.grab_focus()


func close() -> void:
	Settings.save()
	visible = false
	closed.emit()


func _on_master_changed(value: float) -> void:
	if _syncing:
		return
	Settings.set_master_volume(value / 100.0)
	_autosave()


func _on_music_changed(value: float) -> void:
	if _syncing:
		return
	Settings.set_music_volume(value / 100.0)
	_autosave()


func _on_sfx_changed(value: float) -> void:
	if _syncing:
		return
	Settings.set_sfx_volume(value / 100.0)
	_autosave()


func _on_fullscreen_toggled(pressed: bool) -> void:
	_fullscreen_check.text = _switch_text(pressed)
	if _syncing:
		return
	Settings.set_fullscreen(pressed)
	_autosave()


func _on_vsync_toggled(pressed: bool) -> void:
	_vsync_check.text = _switch_text(pressed)
	if _syncing:
		return
	Settings.set_vsync(pressed)
	_autosave()


func _on_back_pressed() -> void:
	Settings.save()
	if return_scene.is_empty():
		visible = false
		closed.emit()
		return
	closed.emit()
	await SceneTransition.change_scene(return_scene)


func _autosave() -> void:
	if save_on_change:
		Settings.save()
