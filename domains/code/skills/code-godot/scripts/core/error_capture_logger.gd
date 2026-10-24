extends Logger

# Collects engine errors as data (OS.add_logger, Godot 4.5+) for operations that
# have to know an error happened rather than find it in stderr afterwards.
#
# check_project uses it for shaders: a .gdshader that fails to compile prints
# "SHADER ERROR:" and nothing else — load() succeeds, the material assignment
# succeeds, and at draw time the engine silently falls back to the default
# material — so without this the op counted a broken shader as ok and exited 0.
#
# `extends Logger` does not parse before Godot 4.5, so nothing may preload this
# file: load() it only after ClassDB.class_exists("Logger").

var shader_errors: Array[Dictionary] = []

func _log_error(_function: String, _file: String, line: int, code: String, rationale: String,
        _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
    # The rendering server reports the compile failure twice: the ERROR_TYPE_SHADER
    # entry carries the message and the shader line; the generic follow-up
    # ("Shader compilation failed.") carries neither and is skipped.
    if error_type == ERROR_TYPE_SHADER:
        shader_errors.append({"line": line, "message": rationale if not rationale.is_empty() else code})

func _log_message(_message: String, _error: bool) -> void:
    pass
