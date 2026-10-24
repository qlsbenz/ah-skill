class_name GodotSkillCreateScene
extends RefCounted

var scene_editor_script = preload("../core/scene_editor.gd")
var utils_script = preload("../core/utils.gd")

func execute(params: Dictionary) -> void:
    utils_script.log_info("Creating scene: " + str(params.get("scene_path", "")))

    # Re-running create_scene on a scene that already holds work used to replace
    # it with a bare root and report "created successfully".
    var existing := str(params.get("scene_path", "")).strip_edges().replace("\\", "/")
    if not existing.is_empty() and not existing.begins_with("res://"):
        existing = "res://" + existing.trim_prefix("/")
    if not bool(params.get("overwrite", false)) and not existing.is_empty() and FileAccess.file_exists(existing):
        utils_script.log_error("%s already exists; create_scene would replace it with an empty root. Edit it with scene_batch/add_node instead, or pass \"overwrite\": true to start it over" % existing)
        return

    var editor = scene_editor_script.new()
    var success = editor.create_new_scene(
        params.get("scene_path", ""),
        params.get("root_node_type", "Node2D"),
        params.get("root_node_name", "root")
    )
    if success:
        success = editor.configure_node({
            "node_path": "root",
            "properties": params.get("properties", {}),
            "indexed_properties": params.get("indexed_properties", {})
        })
    if success:
        success = editor.save_scene()
    if success:
        utils_script.log_info("Scene created successfully at: " + str(params.get("scene_path", "")))
    editor.cleanup()
