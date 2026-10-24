class_name GodotSkillAuditImports
extends RefCounted

var uid_utils_script = preload("../utils/uid_utils.gd")

const IMPORTED_EXTENSIONS = [
    "png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "dds", "exr", "hdr", "ktx",
    "wav", "ogg", "mp3", "mp4", "ogv",
    "gltf", "glb", "fbx", "obj", "dae", "blend",
    "ttf", "otf", "woff", "woff2",
    "csv", "po", "mo"
]

func execute(params: Dictionary) -> void:
    var root := _normalize_directory(params.get("project_path", "res://"))
    var include_entries := bool(params.get("include_entries", true))
    var all_files := uid_utils_script.find_all_files(root, true)
    var sources: Array[String] = []
    var sidecars: Array[String] = []
    for path in all_files:
        if path.ends_with(".import"):
            sidecars.append(path)
        elif path.get_extension().to_lower() in IMPORTED_EXTENSIONS:
            sources.append(path)

    var entries: Array = []
    var counts := {"sources": sources.size(), "ok": 0, "missing": 0, "invalid": 0, "stale": 0, "orphaned": 0}
    for source_path in sources:
        var entry := _inspect_source(source_path)
        counts[entry.status] = int(counts.get(entry.status, 0)) + 1
        entries.append(entry)

    for sidecar_path in sidecars:
        var source_path := sidecar_path.trim_suffix(".import")
        if not FileAccess.file_exists(source_path):
            counts.orphaned += 1
            entries.append({"source_path": source_path, "import_path": sidecar_path, "status": "orphaned", "issues": ["source file is missing"]})

    var issue_count: int = counts.missing + counts.invalid + counts.stale + counts.orphaned
    print(JSON.stringify({
        "ok": issue_count == 0,
        "project_path": root,
        "issue_count": issue_count,
        "counts": counts,
        "entries": entries if include_entries else []
    }))

func _inspect_source(source_path: String) -> Dictionary:
    var sidecar_path := source_path + ".import"
    if not FileAccess.file_exists(sidecar_path):
        return {"source_path": source_path, "import_path": sidecar_path, "status": "missing", "issues": ["import sidecar is missing"]}

    var config := ConfigFile.new()
    var load_error := config.load(sidecar_path)
    if load_error != OK:
        return {"source_path": source_path, "import_path": sidecar_path, "status": "invalid", "issues": ["cannot parse import sidecar: " + error_string(load_error)]}

    var issues: Array[String] = []
    if not bool(config.get_value("remap", "valid", true)):
        issues.append("remap is marked invalid")
    var destinations: Array = Array(config.get_value("deps", "dest_files", []))
    var remap_path := str(config.get_value("remap", "path", ""))
    if not remap_path.is_empty() and remap_path not in destinations:
        destinations.append(remap_path)
    if destinations.is_empty():
        issues.append("no imported destination is recorded")
    for destination in destinations:
        if not FileAccess.file_exists(str(destination)):
            issues.append("imported destination is missing: " + str(destination))

    var status := "invalid" if not issues.is_empty() else "ok"
    var stale_reason := _stale_reason(source_path, sidecar_path, destinations) if status == "ok" else ""
    if not stale_reason.is_empty():
        status = "stale"
        issues.append(stale_reason)
    return {
        "source_path": source_path,
        "import_path": sidecar_path,
        "status": status,
        "importer": str(config.get_value("remap", "importer", "")),
        "type": str(config.get_value("remap", "type", "")),
        "destinations": destinations,
        "issues": issues
    }

# Whether the imported data still matches the source. Decided the way the editor
# decides it: by the source md5 the importer recorded next to the destination
# (`.godot/imported/<name>-<hash>.md5`), never by timestamps. A rewrite that
# produces identical bytes (regenerating art from the same ASCII, `cp` over a
# file, a checkout) leaves the source newer than its `.import` sidecar forever,
# because a re-import that changes nothing rewrites neither the sidecar nor the
# destination — a timestamp rule reports such a project as broken until someone
# touches the sidecar by hand. Returns "" when the import is current.
func _stale_reason(source_path: String, sidecar_path: String, destinations: Array) -> String:
    var record_path := _md5_record_path(destinations)
    if record_path.is_empty() or not FileAccess.file_exists(record_path):
        # No record: this machine never imported the source (a fresh checkout that
        # carries `.import` files but no `.godot/`). Fall back to timestamps against
        # the destination — which does not exist either in that case, and that was
        # already reported above — so this only fires for a hand-made destination.
        if FileAccess.get_modified_time(source_path) > FileAccess.get_modified_time(sidecar_path):
            return "source is newer than import sidecar and no import record exists (run --import)"
        return ""
    var record := ConfigFile.new()
    if record.load(record_path) != OK:
        return "import record cannot be parsed: " + record_path
    var recorded := str(record.get_value("", "source_md5", ""))
    if recorded.is_empty():
        return "import record carries no source_md5: " + record_path
    var actual := FileAccess.get_md5(source_path)
    if actual != recorded:
        return "source changed since it was imported (md5 %s, import record %s); run --import" % [actual.substr(0, 8), recorded.substr(0, 8)]
    return ""

# `res://.godot/imported/hero.png-3f4a….ctex` -> `res://.godot/imported/hero.png-3f4a….md5`.
# Variant destinations (`…-<hash>.s3tc.ctex`) share the one record, so the name is
# cut right after the 32-hex hash rather than at the last extension.
func _md5_record_path(destinations: Array) -> String:
    var hash_pattern := RegEx.create_from_string("^(.*-[0-9a-f]{32})")
    for destination in destinations:
        var path := str(destination)
        var directory := path.get_base_dir()
        var found := hash_pattern.search(path.get_file())
        if found != null:
            return directory.path_join(found.get_string(1) + ".md5")
    return ""

func _normalize_directory(path_value: Variant) -> String:
    var path := str(path_value).strip_edges().replace("\\", "/")
    if path.is_empty() or path == "res://":
        return "res://"
    if not path.begins_with("res://"):
        path = "res://" + path.trim_prefix("/")
    return path.trim_suffix("/") + "/"
