#!/usr/bin/env -S godot --headless --script
extends SceneTree

# Zero-install unit-test runner for the skill's mini test framework.
#
# Usage (run_tests.py --framework mini builds this command for you):
#
#   godot --headless --debug --ignore-error-breaks --path /abs/project \
#     --script /abs/godot/scripts/test/mini_test_runner.gd \
#     '{"tests_dir":"tests","select":"","test_timeout_seconds":10}'
#
# --script must be an ABSOLUTE path (a relative one resolves under res://).
#
# What it does: discovers res://<tests_dir>/**/test_*.gd whose base-script chain
# reaches templates/tests/test_case.gd (detected by the `_mini_report` method,
# so the base can live anywhere and be subclassed), runs every `test_*` method
# in declaration order, awaits coroutines with a per-test timeout, and prints
# one JSON document on the last line prefixed with [MINI_TEST_RESULT].
#
# Why the marker lines matter: a GDScript runtime error does NOT raise. It
# aborts the running function and returns to the caller, so a runner that only
# looks at the call's return value reports the dead test as a pass. The engine
# does print `SCRIPT ERROR:` for it, so every test is bracketed by
#   [MINI_TEST] begin <script>::<test>   /   [MINI_TEST] end <script>::<test> {…}
# and run_tests.py attributes the error lines between the markers to that test
# (via godot_log_parser.py) and downgrades it to `error`.
#
# Everything runs deferred, after the first frame, so the project's autoload
# singletons are registered before any test script is loaded — the same reason
# scripts/core/dispatcher.gd defers its operations.

const MARKER := "[MINI_TEST]"
const RESULT_MARKER := "[MINI_TEST_RESULT]"
const DEFAULT_TEST_TIMEOUT := 10.0
# Statuses that make a run fail, for a test as well as for a hook or a script.
const BAD_STATUSES := ["failed", "error", "timeout"]

var config: Dictionary = {}
var results: Array[Dictionary] = []
var script_reports: Array[Dictionary] = []
var notes: Array[String] = []
## Every test_* method found, before --select narrowed it down.
var discovered: Array[String] = []
var fatal: String = ""


func _init() -> void:
    var args := OS.get_cmdline_args()
    var script_index := args.find("--script")
    var config_index := script_index + 2
    if script_index >= 0 and config_index < args.size():
        var parsed: Variant = JSON.parse_string(args[config_index])
        if not (parsed is Dictionary):
            printerr("mini_test_runner: the argument after the script path must be a JSON object, got: " + args[config_index])
            quit(2)
            return
        config = parsed
    # Deferred: the SceneTree finishes initialising (registering the project's
    # autoload singletons) before any test script is loaded.
    _run.call_deferred()


func _run() -> void:
    var started := Time.get_ticks_msec()
    var tests_dir := str(config.get("tests_dir", "tests")).trim_prefix("res://").trim_suffix("/")
    var select := str(config.get("select", ""))
    var timeout_ms := int(maxf(float(config.get("test_timeout_seconds", DEFAULT_TEST_TIMEOUT)), 0.1) * 1000.0)
    var strict := bool(config.get("strict", false))

    var root_path := "res://" + tests_dir
    if not DirAccess.dir_exists_absolute(root_path):
        fatal = "Tests directory does not exist: %s. Create it, or pass a different tests_dir." % root_path
        _finish(started, strict, tests_dir)
        return

    var loaded: Array[Dictionary] = []
    var base_paths := {}
    for path in _discover(root_path):
        # Marker first: a parse error is printed by load() itself, and this is
        # what lets run_tests.py attribute it to the file instead of the run.
        print("%s script %s" % [MARKER, path])
        var script: Variant = load(path)
        # A script with a parse error still loads as a GDScript object — it just
        # cannot be instantiated and knows no base type. Without this check it
        # would be silently written off as "does not extend the base class".
        if not (script is GDScript) or (not (script as GDScript).can_instantiate() and (script as GDScript).get_instance_base_type().is_empty()):
            script_reports.append({"script": path, "tests": 0, "orphans": 0, "error": "failed to load"})
            results.append(_script_level_error(path, "the script failed to load — fix the parse error the engine reported above"))
            continue
        var current: Variant = (script as GDScript).get_base_script()
        while current is Script:
            var base_path := str((current as Script).resource_path)
            if not base_path.is_empty():
                base_paths[base_path] = true
            current = (current as Script).get_base_script()
        loaded.append({"path": path, "script": script})

    for entry in loaded:
        var path: String = entry["path"]
        # The base class file itself matches test_*.gd, and so does any
        # intermediate base a project writes. Skip whatever is extended.
        if base_paths.has(path):
            continue
        var script: GDScript = entry["script"]
        if not _is_test_case(script):
            notes.append("%s does not extend the test-case base class and was skipped — use `extends \"res://%s/test_case.gd\"`." % [path, tests_dir])
            continue
        # The base class matches test_*.gd too. It is the one test-case script
        # whose own base is not a test case, so it is recognised even when no
        # suite extends it yet (a freshly initialised project).
        var base: Variant = script.get_base_script()
        if not (base is GDScript) or not _is_test_case(base):
            continue
        await _run_script(path, script, select, timeout_ms)

    _finish(started, strict, tests_dir)


func _discover(root_path: String) -> Array[String]:
    var found: Array[String] = []
    var pending: Array[String] = [root_path]
    while not pending.is_empty():
        var directory: String = pending.pop_front()
        for file_name in DirAccess.get_files_at(directory):
            if file_name.begins_with("test_") and file_name.ends_with(".gd"):
                found.append(directory.path_join(file_name))
        for sub_directory in DirAccess.get_directories_at(directory):
            if sub_directory.begins_with("."):
                continue
            pending.append(directory.path_join(sub_directory))
    found.sort()
    return found


func _is_test_case(script: GDScript) -> bool:
    # Structural check rather than a path comparison, so the base class can be
    # copied anywhere and subclassed by a project-specific base.
    for method in script.get_script_method_list():
        if str(method["name"]) == "_mini_report":
            return true
    return false


func _test_methods(script: GDScript) -> Array[String]:
    var names: Array[String] = []
    for method in script.get_script_method_list():
        var method_name := str(method["name"])
        if method_name.begins_with("test_") and not names.has(method_name):
            names.append(method_name)
    return names


func _run_script(path: String, script: GDScript, select: String, timeout_ms: int) -> void:
    print("%s script %s" % [MARKER, path])
    var method_names := _test_methods(script)
    if method_names.is_empty():
        notes.append("%s extends the test-case base class but declares no test_* methods." % path)
    var selected: Array[String] = []
    for method_name in method_names:
        discovered.append("%s::%s" % [path, method_name])
        if select.is_empty() or method_name.contains(select) or path.contains(select):
            selected.append(method_name)
    if selected.is_empty():
        print("%s script_end %s %s" % [MARKER, path, JSON.stringify({"tests": 0, "orphans": 0})])
        return

    var instance: Variant = script.new()
    if not (instance is Node):
        results.append(_script_level_error(path, "the script could not be instantiated as a Node"))
        print("%s script_end %s %s" % [MARKER, path, JSON.stringify({"tests": 0, "orphans": 0, "error": "not instantiable"})])
        return
    var test_node: Node = instance
    test_node.name = path.get_file().get_basename()
    root.add_child(test_node)
    await process_frame
    var orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

    await _run_hook(path, test_node, "before_all", timeout_ms)
    # Nodes created in before_all belong to the whole script, not to the first test.
    test_node.call("_mini_scope_to_script")
    for method_name in selected:
        await _run_test(path, test_node, method_name, timeout_ms)
    await _run_hook(path, test_node, "after_all", timeout_ms)
    await _invoke(test_node, "_mini_cleanup", Time.get_ticks_msec(), timeout_ms)
    await _invoke(test_node, "_mini_cleanup_script", Time.get_ticks_msec(), timeout_ms)

    test_node.queue_free()
    await process_frame
    await process_frame
    var leaked := maxi(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) - orphans_before, 0)
    script_reports.append({"script": path, "tests": selected.size(), "orphans": leaked, "error": null})
    if leaked > 0:
        notes.append("%s left %d orphan node(s) behind — free what you create with add_child_autofree()/autofree()." % [path, leaked])
    print("%s script_end %s %s" % [MARKER, path, JSON.stringify({"tests": selected.size(), "orphans": leaked})])


func _run_hook(path: String, test_node: Node, method_name: String, timeout_ms: int) -> void:
    if not test_node.has_method(method_name):
        return
    test_node.call("_mini_reset")
    print("%s begin %s::%s" % [MARKER, path, method_name])
    var started := Time.get_ticks_msec()
    var outcome := await _invoke(test_node, method_name, started, timeout_ms)
    outcome["elapsed_ms"] = Time.get_ticks_msec() - started
    var entry := _build_entry(path, method_name, outcome, test_node.call("_mini_report"), "hook")
    results.append(entry)
    print("%s end %s::%s %s" % [MARKER, path, method_name, JSON.stringify(entry)])


func _run_test(path: String, test_node: Node, method_name: String, timeout_ms: int) -> void:
    test_node.call("_mini_reset")
    print("%s begin %s::%s" % [MARKER, path, method_name])
    var started := Time.get_ticks_msec()
    var timed_out := false
    if test_node.has_method("before_each"):
        var setup := await _invoke(test_node, "before_each", started, timeout_ms)
        timed_out = bool(setup["timed_out"])
    if not timed_out:
        var outcome := await _invoke(test_node, method_name, started, timeout_ms)
        timed_out = bool(outcome["timed_out"])
    if not timed_out and test_node.has_method("after_each"):
        var teardown := await _invoke(test_node, "after_each", started, timeout_ms)
        timed_out = bool(teardown["timed_out"])
    var report: Dictionary = test_node.call("_mini_report")
    await _invoke(test_node, "_mini_cleanup", Time.get_ticks_msec(), timeout_ms)
    var entry := _build_entry(path, method_name,
        {"timed_out": timed_out, "elapsed_ms": Time.get_ticks_msec() - started}, report, "test")
    results.append(entry)
    print("%s end %s::%s %s" % [MARKER, path, method_name, JSON.stringify(entry)])


## Invoke one method and, when it suspends, wait for it with a wall-clock budget
## measured from `started_ms` so before_each + test + after_each share one deadline.
func _invoke(test_node: Node, method_name: String, started_ms: int, timeout_ms: int) -> Dictionary:
    if not test_node.has_method(method_name):
        return {"timed_out": false, "coroutine": false}
    var outcome: Variant = test_node.call(method_name)
    # A suspended GDScript coroutine returns a GDScriptFunctionState object —
    # NOT a Signal (verified on 4.7). It carries `completed` and is_valid().
    if not (outcome is Object) or not is_instance_valid(outcome as Object):
        return {"timed_out": false, "coroutine": false}
    var state: Object = outcome
    if state.get_class() != "GDScriptFunctionState":
        return {"timed_out": false, "coroutine": false}
    if not bool(state.call("is_valid", true)):
        return {"timed_out": false, "coroutine": true}
    var finished := [false]
    state.connect("completed", func(_value = null) -> void: finished[0] = true, CONNECT_ONE_SHOT)
    while not bool(finished[0]):
        if Time.get_ticks_msec() - started_ms >= timeout_ms:
            return {"timed_out": true, "coroutine": true}
        await process_frame
    return {"timed_out": false, "coroutine": true}


## `kind` is "test" for a test_* method, "hook" for before_all/after_all and
## "script" for a whole file that could not even be loaded.
func _build_entry(path: String, method_name: String, outcome: Dictionary, report: Dictionary, kind: String) -> Dictionary:
    var failures: Array = report["failures"]
    var status := "passed"
    var message := ""
    var source := ""
    var line := 0
    if bool(outcome["timed_out"]):
        status = "timeout"
        message = "did not finish within the per-test timeout — raise test_timeout_seconds, or fix the await that never resolves"
    elif not failures.is_empty():
        status = "failed"
        var first: Dictionary = failures[0]
        message = str(first["message"])
        source = str(first["source"])
        line = int(first["line"])
        if failures.size() > 1:
            message += " (+%d more assertion failure(s))" % (failures.size() - 1)
    elif bool(report["skipped"]):
        status = "skipped"
        message = str(report["skip_reason"])
    elif bool(report["pending"]):
        status = "pending"
        message = str(report["pending_reason"])
    elif int(report["asserts"]) == 0 and kind == "test":
        status = "risky"
        message = "made no assertion, so it cannot fail and proves nothing — add an assert, or mark it pending(\"…\")"
    return {
        "script": path,
        "test": method_name,
        "status": status,
        "asserts": int(report["asserts"]),
        "message": message,
        "source": source if not source.is_empty() else path,
        "line": line,
        "duration_ms": int(outcome["elapsed_ms"]),
        "allow_errors": bool(report["allow_errors"]),
        "kind": kind,
        "failures": failures,
    }


func _script_level_error(path: String, message: String) -> Dictionary:
    return {
        "script": path,
        "test": "<script>",
        "status": "error",
        "asserts": 0,
        "message": message,
        "source": path,
        "line": 0,
        "duration_ms": 0,
        "allow_errors": false,
        "kind": "script",
        "failures": [],
    }


## Same rules as run_tests.py's summarize(): a test is always counted, a hook or
## a failed-to-load script only when it went wrong.
func _finish(started_ms: int, strict: bool, tests_dir: String) -> void:
    var counts := {
        "scripts": script_reports.size(), "tests": 0, "passed": 0, "failed": 0, "errors": 0,
        "skipped": 0, "pending": 0, "risky": 0, "timed_out": 0, "non_test_failures": 0,
    }
    var bucket := {"passed": "passed", "failed": "failed", "error": "errors",
        "skipped": "skipped", "pending": "pending", "risky": "risky", "timeout": "timed_out"}
    var failures: Array[Dictionary] = []
    for entry in results:
        var status := str(entry["status"])
        var is_test := str(entry["kind"]) == "test"
        if not is_test and not BAD_STATUSES.has(status):
            continue
        if is_test:
            counts["tests"] = int(counts["tests"]) + 1
        else:
            counts["non_test_failures"] = int(counts["non_test_failures"]) + 1
        var key: String = bucket[status]
        counts[key] = int(counts[key]) + 1
        if BAD_STATUSES.has(status):
            failures.append({
                "script": entry["script"], "test": entry["test"], "line": entry["line"],
                "message": entry["message"], "status": status, "source": entry["source"],
            })

    var ok := fatal.is_empty() and failures.is_empty() and not (strict and int(counts["risky"]) > 0)
    var payload := {
        "ok": ok,
        "framework": "mini",
        "tests_dir": "res://" + tests_dir,
        "counts": counts,
        "failures": failures,
        "results": results,
        "scripts": script_reports,
        "notes": notes,
        "discovered_tests": discovered,
        "duration_s": float(Time.get_ticks_msec() - started_ms) / 1000.0,
    }
    if not fatal.is_empty():
        payload["errors"] = [fatal]
        printerr("mini_test_runner: " + fatal)
    print(RESULT_MARKER + " " + JSON.stringify(payload))
    quit(0 if ok else 1)
