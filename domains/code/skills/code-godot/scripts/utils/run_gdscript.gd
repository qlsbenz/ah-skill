class_name GodotSkillRunGDScript
extends RefCounted

# The escape hatch: run a GDScript snippet, one Expression, or a function of a
# project script inside a live SceneTree with the project's autoloads registered,
# and get the value back as typed JSON.
#
# The hard part is not running the code, it is *not lying about it*. A GDScript
# runtime error aborts only the function it happens in and hands the caller a
# plain `null` (verified on 4.7), so a naive runner reports a crashed snippet as
# `{"ok": true, "result": null}`. This op installs an `OS.add_logger()` Logger
# around the compile and the call, so every parse error, runtime error and
# warning the engine emits becomes data: parse errors are re-numbered against the
# caller's own `code` lines, and any error at all means exit 1.

var utils_script = preload("../core/utils.gd")
var codec_script = preload("../core/variant_codec.gd")

# The generated wrapper is exactly one line long, so a reported wrapper line maps
# to the caller's snippet by subtracting PREAMBLE_LINES.
const WRAPPER_FUNCTION := "_godot_skill_run"
const PREAMBLE_LINES := 1
# Giving the compiled snippet a resource path makes the Logger entries
# attributable: anything reported against this path came from the snippet.
const SNIPPET_PATH := "res://__godot_skill_run_gdscript.gd"
const MAX_PRINTS := 200
const MAX_PRINT_CHARS := 8000

class CaptureLog extends Logger:
    # Everything the engine reports while the snippet compiles and runs.
    var errors: Array = []
    var messages: Array = []

    func _log_error(function: String, file: String, line: int, code: String, rationale: String,
            _editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
        var text := rationale.strip_edges()
        if text.is_empty():
            text = code.strip_edges()
        elif not code.strip_edges().is_empty():
            text = "%s: %s" % [code.strip_edges(), text]
        errors.append({
            "function": function,
            "file": file,
            "line": line,
            "message": text,
            "error_type": error_type
        })

    func _log_message(message: String, _error: bool) -> void:
        messages.append(message)

var _tree: SceneTree = null
var _logger: CaptureLog = null
var _scene_root: Node = null
var _instance: Object = null
var _mode := ""
var _capturing := false
var _finished := false
var _timed_out := false
var _timeout_seconds := 10.0
var _started_ms := 0

func execute(params: Dictionary) -> void:
    _tree = Engine.get_main_loop() as SceneTree
    if _tree == null:
        utils_script.log_error("run_gdscript needs a running SceneTree (run it through dispatcher.gd)")
        return

    var modes: Array = []
    if params.has("code"):
        modes.append("code")
    if params.has("expression"):
        modes.append("expression")
    if params.has("script_path"):
        modes.append("script_path")
    if modes.size() != 1:
        utils_script.log_error(_mode_error(modes))
        return
    _mode = modes[0]
    if _mode == "script_path" and str(params.get("method", "")).strip_edges().is_empty():
        utils_script.log_error("run_gdscript: script_path needs method — the function to call, "
            + "for example {\"script_path\":\"res://scripts/health.gd\",\"method\":\"damage\",\"args\":[3]}")
        return

    _timeout_seconds = float(params.get("timeout_seconds", 10.0))
    if _timeout_seconds <= 0.0:
        utils_script.log_error("run_gdscript: timeout_seconds must be greater than 0 (default 10)")
        return
    var max_depth := int(params.get("max_depth", 4))
    if max_depth < 0:
        utils_script.log_error("run_gdscript: max_depth must be 0 or more (default 4)")
        return

    if params.has("scene_path") and not _open_scene(str(params.get("scene_path", ""))):
        return

    var timer := _tree.create_timer(_timeout_seconds, true, false, true)
    timer.timeout.connect(_on_timeout)

    _logger = CaptureLog.new()
    OS.add_logger(_logger)
    _capturing = true
    _started_ms = Time.get_ticks_msec()

    var outcome := {}
    match _mode:
        "code":
            outcome = await _run_code(str(params.get("code", "")))
        "expression":
            outcome = _run_expression(str(params.get("expression", "")))
        _:
            # A coroutine: the called project function may itself await.
            outcome = await _run_script_method(params)

    var elapsed := Time.get_ticks_msec() - _started_ms
    if _timed_out:
        # _on_timeout already reported and quit; anything here is a late resume.
        return
    _finished = true
    _stop_capture()

    var captured := _split_captured()
    var failures: Array = captured["failures"]
    var ok := bool(outcome["ok"]) and failures.is_empty()

    var payload := {
        "ok": ok,
        "mode": _mode,
        "completed": bool(outcome["ok"]),
        "result": codec_script.new().encode(outcome["value"], max_depth),
        "result_type": _type_label(outcome["value"]),
        "elapsed_ms": elapsed
    }
    var print_lines: Array = captured["prints"]
    if not print_lines.is_empty():
        payload["prints"] = print_lines
        if bool(captured["prints_truncated"]):
            payload["prints_truncated"] = true
    var warnings: Array = captured["warnings"]
    if not warnings.is_empty():
        payload["warnings"] = warnings
    if not failures.is_empty():
        payload["errors"] = failures

    _free_result(outcome["value"])
    _cleanup()

    if not ok and bool(outcome["ok"]):
        # The call returned, but the engine reported errors while it ran: a
        # GDScript runtime error aborts its own function and hands the caller a
        # plain null, so a silent `"result": null` here would read as success.
        utils_script.log_error("run_gdscript: %s did not complete — %d error(s) while running:"
            % [_source_label(), failures.size()])
        for failure in failures:
            utils_script.log_error("  " + str(failure["text"]))
    print(JSON.stringify(payload))

# --- modes -----------------------------------------------------------------

func _run_code(code: String) -> Dictionary:
    if code.strip_edges().is_empty():
        return _fail("run_gdscript: code is empty. Pass the body of "
            + "`func run(tree: SceneTree) -> Variant`, for example "
            + "{\"code\":\"return tree.root.get_child_count()\"} or "
            + "{\"code\":\"var n = Node2D.new()\\nreturn n.get_class()\"}")

    var body := _dedent(code)
    var indent := _indent_unit(body)
    var lines: PackedStringArray = body.split("\n")
    var wrapped := "func %s(tree, scene):\n" % WRAPPER_FUNCTION
    for line in lines:
        wrapped += (indent + line if not line.strip_edges().is_empty() else "") + "\n"

    var script := GDScript.new()
    script.resource_path = SNIPPET_PATH
    script.source_code = wrapped
    var parse_result := script.reload()
    if parse_result != OK:
        _report_parse_errors(lines)
        return {"ok": false, "value": null}

    _instance = script.new()
    if _instance == null:
        return _fail("run_gdscript: the compiled snippet could not be instantiated")
    var value: Variant = await _instance.call(WRAPPER_FUNCTION, _tree, _scene_root)
    return {"ok": true, "value": value}

func _run_expression(text: String) -> Dictionary:
    if text.strip_edges().is_empty():
        return _fail("run_gdscript: expression is empty, for example "
            + "{\"expression\":\"Vector2(3, 4).length()\"}")

    # An Expression has no scope: an identifier it does not know becomes a
    # property of the (absent) base instance, which fails with "self can't be
    # used". Singletons and autoloads are therefore handed in by name.
    var named := {}
    var order: Array = []
    for singleton_name in Engine.get_singleton_list():
        named[str(singleton_name)] = Engine.get_singleton(singleton_name)
        order.append(str(singleton_name))
    for entry in _autoload_inputs():
        var autoload_name := str(entry["name"])
        if not named.has(autoload_name):
            order.append(autoload_name)
        named[autoload_name] = entry["node"]
    named["tree"] = _tree
    named["scene"] = _scene_root
    order.append("tree")
    order.append("scene")

    var input_names := PackedStringArray()
    var inputs: Array = []
    for key in order:
        input_names.append(str(key))
        inputs.append(named[key])

    var expression := Expression.new()
    if expression.parse(text, input_names) != OK:
        return _fail("run_gdscript: expression did not parse: %s. " % expression.get_error_text()
            + "An Expression is one expression — no statements, no `await`, no `var`; use `code` for those.")
    var value: Variant = expression.execute(inputs, null, true)
    if expression.has_execute_failed():
        return _fail("run_gdscript: expression failed at runtime: %s. Named values it can see: %s. "
            % [expression.get_error_text(), ", ".join(input_names)]
            + "Anything else (a class_name, a node path, a local variable) needs the `code` mode.")
    return {"ok": true, "value": value}

func _run_script_method(params: Dictionary) -> Dictionary:
    var script_path := _normalize_path(str(params.get("script_path", "")))
    if not ResourceLoader.exists(script_path):
        return _fail("run_gdscript: script not found: %s. Pass a res:// path to a .gd file that exists." % script_path)
    var loaded = load(script_path)
    if not (loaded is Script):
        return _fail("run_gdscript: %s is not a Script (loaded a %s)." % [script_path, type_string(typeof(loaded))])
    var script := loaded as Script
    if str(script.get_instance_base_type()).is_empty():
        return _fail("run_gdscript: %s failed to compile. Run check_project on the project to see the parse error." % script_path)

    var method_name := str(params.get("method", ""))
    var declared := _find_script_method(script, method_name)
    var wants_instance := not bool(declared["static"])
    if params.has("instantiate"):
        wants_instance = bool(params.get("instantiate", true))

    var raw_args = params.get("args", [])
    var codec = codec_script.new()
    var call_args = codec.decode(raw_args, "args")
    if not (call_args is Array):
        return _fail("run_gdscript: args must be a JSON array of typed values, for example "
            + "[3, {\"__type\":\"Vector2\",\"x\":1,\"y\":0}]")

    if not wants_instance:
        if not bool(declared["found"]):
            return _fail(_missing_method_message(script, script_path, method_name))
        if not bool(declared["static"]):
            return _fail(("run_gdscript: %s.%s is not static, so it cannot be called with "
                + "\"instantiate\": false. Drop the key (an instance is created automatically) "
                + "or declare the function `static func`.") % [script_path, method_name])
        return {"ok": true, "value": script.callv(method_name, call_args)}

    if not script.can_instantiate():
        return _fail("run_gdscript: %s cannot be instantiated (abstract, or it failed to compile). "
            % script_path + "Call a static function instead, or fix the script.")
    _instance = script.new()
    if _instance == null:
        return _fail("run_gdscript: %s.new() returned null" % script_path)
    if not _instance.has_method(method_name):
        return _fail(_missing_method_message(script, script_path, method_name))
    var value: Variant = await _instance.callv(method_name, call_args)
    return {"ok": true, "value": value}

# --- diagnostics -----------------------------------------------------------

func _report_parse_errors(lines: PackedStringArray) -> void:
    _stop_capture()
    var reported := 0
    for entry in _logger.errors:
        if str(entry["file"]) != SNIPPET_PATH:
            continue
        var wrapper_line := int(entry["line"])
        var code_line: int = maxi(1, wrapper_line - PREAMBLE_LINES)
        var source := ""
        if code_line >= 1 and code_line <= lines.size():
            source = str(lines[code_line - 1]).strip_edges()
        var message := "  code:%d: %s" % [code_line, str(entry["message"])]
        if not source.is_empty():
            message += "   [%s]" % source
        if reported == 0:
            utils_script.log_error("run_gdscript: code did not compile. Line numbers are 1-based in your `code`:")
        utils_script.log_error(message)
        reported += 1
    if reported == 0:
        utils_script.log_error("run_gdscript: code did not compile (the engine printed the parse error above). "
            + "Your snippet is wrapped in `func %s(tree, scene):`, so a reported line N is your line N-%d."
            % [WRAPPER_FUNCTION, PREAMBLE_LINES])

func _split_captured() -> Dictionary:
    var failures: Array = []
    var warnings: Array = []
    var print_lines: Array = []
    var characters := 0
    var truncated := false
    for entry in _logger.errors:
        var where := "%s:%d" % [str(entry["file"]), int(entry["line"])]
        if str(entry["file"]) == SNIPPET_PATH:
            where = "code:%d" % maxi(1, int(entry["line"]) - PREAMBLE_LINES)
        var described := {
            "where": where,
            "function": str(entry["function"]),
            "message": str(entry["message"]),
            "text": "%s: %s" % [where, str(entry["message"])]
        }
        if int(entry["error_type"]) == Logger.ERROR_TYPE_WARNING:
            warnings.append(described)
        else:
            failures.append(described)
    for message in _logger.messages:
        var text := str(message).strip_edges()
        if text.is_empty():
            continue
        if print_lines.size() >= MAX_PRINTS or characters + text.length() > MAX_PRINT_CHARS:
            truncated = true
            break
        characters += text.length()
        print_lines.append(text)
    return {"failures": failures, "warnings": warnings, "prints": print_lines,
            "prints_truncated": truncated}

func _on_timeout() -> void:
    if _finished or _timed_out:
        return
    _timed_out = true
    _stop_capture()
    var captured := _split_captured()
    utils_script.log_error(("run_gdscript: %s was still running after %.1fs (timeout_seconds). "
        + "An `await` that never resolves and an endless loop both look like this; raise timeout_seconds "
        + "or make the snippet finish.") % [_source_label(), _timeout_seconds])
    var payload := {
        "ok": false,
        "mode": _mode,
        "completed": false,
        "timed_out": true,
        "timeout_seconds": _timeout_seconds,
        "result": null,
        "result_type": "null",
        "elapsed_ms": Time.get_ticks_msec() - _started_ms
    }
    var print_lines: Array = captured["prints"]
    if not print_lines.is_empty():
        payload["prints"] = print_lines
    print(JSON.stringify(payload))
    _cleanup()
    _tree.quit(1)

# --- helpers ---------------------------------------------------------------

func _stop_capture() -> void:
    # Idempotent, and always called before this op prints anything itself: the
    # Logger sees every print() in the process, so our own diagnostics would
    # otherwise come back as the snippet's "prints".
    if _capturing:
        OS.remove_logger(_logger)
        _capturing = false

func _fail(message: String) -> Dictionary:
    _stop_capture()
    utils_script.log_error(message)
    return {"ok": false, "value": null}

func _free_result(value: Variant) -> void:
    # A Node the snippet created but never parented would be reported as an
    # ObjectDB leak at exit, which reads like a real error in the log.
    if value is Node and is_instance_valid(value) and value != _scene_root:
        var node := value as Node
        if node.get_parent() == null:
            node.free()

func _mode_error(modes: Array) -> String:
    if modes.is_empty():
        return ("run_gdscript needs exactly one of code, expression or script_path+method. "
            + "Examples: {\"code\":\"return 6 * 7\"}, {\"expression\":\"Vector2(3, 4).length()\"}, "
            + "{\"script_path\":\"res://scripts/health.gd\",\"method\":\"damage\",\"args\":[3]}")
    return ("run_gdscript got %s; pass exactly one of code, expression or script_path."
        % " and ".join(PackedStringArray(modes)))

func _open_scene(raw_path: String) -> bool:
    var scene_path := _normalize_path(raw_path)
    if not ResourceLoader.exists(scene_path):
        utils_script.log_error("run_gdscript: scene_path not found: %s. List the project's scenes with "
            % scene_path + "inspect_project '{\"include_files\":true}'.")
        return false
    var packed = load(scene_path)
    if not (packed is PackedScene):
        utils_script.log_error("run_gdscript: %s is not a PackedScene" % scene_path)
        return false
    _scene_root = (packed as PackedScene).instantiate()
    if _scene_root == null:
        utils_script.log_error("run_gdscript: %s failed to instantiate" % scene_path)
        return false
    _tree.root.add_child(_scene_root)
    return true

func _autoload_inputs() -> Array:
    # Autoloads are already global identifiers inside `code`; an Expression has no
    # scope of its own, so they are handed to it as named inputs instead.
    var found: Array = []
    for info in ProjectSettings.get_property_list():
        var setting := str(info["name"])
        if not setting.begins_with("autoload/"):
            continue
        var autoload_name := setting.substr("autoload/".length())
        var node: Node = _tree.root.get_node_or_null(NodePath(autoload_name))
        if node != null:
            found.append({"name": autoload_name, "node": node})
    return found

func _find_script_method(script: Script, method_name: String) -> Dictionary:
    var current := script
    while current != null:
        for info in current.get_script_method_list():
            if str(info["name"]) != method_name:
                continue
            return {"found": true, "static": (int(info["flags"]) & METHOD_FLAG_STATIC) != 0}
        current = current.get_base_script()
    return {"found": false, "static": false}

func _missing_method_message(script: Script, script_path: String, method_name: String) -> String:
    var names: Array = []
    var current := script
    while current != null:
        for info in current.get_script_method_list():
            names.append(str(info["name"]))
        current = current.get_base_script()
    var message := "run_gdscript: %s has no function %s" % [script_path, method_name]
    var near: PackedStringArray = utils_script.nearest_names(method_name, names)
    if not near.is_empty():
        message += " (did you mean " + ", ".join(near) + "?)"
    if names.is_empty():
        return message + ". The script declares no functions of its own."
    return message + ". It declares: " + ", ".join(PackedStringArray(names))

func _source_label() -> String:
    if _mode == "expression":
        return "expression"
    if _mode == "script_path":
        return "the script method"
    return "run()"

func _type_label(value: Variant) -> String:
    if value is Object and value != null:
        var object := value as Object
        var attached = object.get_script()
        if attached is Script:
            var global_name := str((attached as Script).get_global_name())
            if not global_name.is_empty():
                return global_name
        return object.get_class()
    if value == null:
        return "null"
    return type_string(typeof(value))

func _dedent(code: String) -> String:
    # Pasted code is often already indented; strip whatever every line shares so
    # the wrapper's own indent does not create a mixed-indentation parse error.
    var lines: PackedStringArray = code.replace("\r\n", "\n").split("\n")
    var common := ""
    var first := true
    for line in lines:
        if line.strip_edges().is_empty():
            continue
        var leading := line.substr(0, line.length() - line.lstrip(" \t").length())
        if first:
            common = leading
            first = false
            continue
        var shared := 0
        while shared < common.length() and shared < leading.length() and common[shared] == leading[shared]:
            shared += 1
        common = common.substr(0, shared)
    if common.is_empty():
        return code.replace("\r\n", "\n")
    var out := PackedStringArray()
    for line in lines:
        out.append(line.substr(common.length()) if line.begins_with(common) else line)
    return "\n".join(out)

func _indent_unit(code: String) -> String:
    # Match the snippet's own indentation character: GDScript refuses a file that
    # mixes tabs and spaces, so a tab prefix in front of space-indented code
    # would turn a valid snippet into a parse error.
    for line in code.split("\n"):
        if line.strip_edges().is_empty():
            continue
        if line.begins_with("\t"):
            return "\t"
        if line.begins_with(" "):
            var spaces := 0
            while spaces < line.length() and line[spaces] == " ":
                spaces += 1
            return " ".repeat(spaces)
    return "\t"

func _normalize_path(path: String) -> String:
    var cleaned := path.strip_edges().replace("\\", "/")
    if cleaned.begins_with("res://") or cleaned.begins_with("user://"):
        return cleaned
    return "res://" + cleaned.trim_prefix("/")

func _cleanup() -> void:
    if _scene_root != null and is_instance_valid(_scene_root):
        if _scene_root.get_parent() != null:
            _scene_root.get_parent().remove_child(_scene_root)
        _scene_root.free()
        _scene_root = null
    if _instance != null and is_instance_valid(_instance) and not (_instance is RefCounted):
        var object := _instance as Object
        if object is Node and (object as Node).get_parent() != null:
            (object as Node).get_parent().remove_child(object as Node)
        object.free()
    _instance = null
