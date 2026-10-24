#!/usr/bin/env -S godot --headless --script
# Boot ONE scene, run it for a bounded number of frames, and report what
# happened. Driven by smoke_scenes.py, which runs one process per scene:
#
#   godot --headless -d --ignore-error-breaks --fixed-fps 60 \
#     --path /abs/project --script /abs/smoke_runner.gd -- '<config json>'
#
# The config is passed after `--` so it lands in OS.get_cmdline_user_args() and
# the engine never mistakes it for a scene path to boot.
#
# Why a SceneTree script instead of `godot --path P res://scene.tscn`: this run
# must set the root viewport size, drive input, sample performance monitors,
# notice that the scene navigated away or quit, and still print a machine
# readable result when any of that goes wrong. `_finalize()` is a MainLoop
# virtual the engine calls even when the *scene* ended the run with
# `get_tree().quit()`, which is the only reliable way to report that case
# (overriding `quit()` is rejected by the GDScript analyser: "overrides a method
# from native class SceneTree").
extends SceneTree

const RESULT_MARKER := "[SMOKE_RESULT] "

# Built-in `ui_*` actions worth fuzzing. The engine registers ~95 of them and
# almost all are text-editing verbs that no gameplay scene listens for; these
# are the ones that open menus, move focus and confirm dialogs.
const FUZZ_UI_ACTIONS := [
    "ui_accept", "ui_select", "ui_cancel", "ui_left", "ui_right", "ui_up", "ui_down",
    "ui_focus_next", "ui_focus_prev", "ui_page_up", "ui_page_down", "ui_home", "ui_end",
    "ui_text_submit", "ui_menu"
]

var config: Dictionary = {}
var scene_path := ""
var scene_root: Node = null
var result_emitted := false

var findings: Array = []
var notes: Array = []
var samples: Array = []
var frame_ms: Array = []

var target_frames := 60
var frames_run := 0
var fps_rate := 60.0
var sample_interval := 6
var settle_frames := 2
var profile := false
var started_ms := 0
var run_started_ms := 0
var run_mode := "fixed_fps"
var run_seconds := 1.0
var budget_ms := 0
var ended := "completed"

var baseline_nodes := 0
var baseline_orphans := 0
var orphans_after_free := 0
var destination_scene := ""

var fuzz_enabled := false
var fuzz_mouse := false
var fuzz_seed := 0
var fuzz_interval := 6
var fuzz_log: Array = []
var rng := RandomNumberGenerator.new()
var fuzz_actions: Array = []
var fuzz_ui_actions: Array = []
var held: Array = []
var viewport_size := Vector2i(1152, 648)


func _init() -> void:
    var user_args := OS.get_cmdline_user_args()
    if user_args.is_empty():
        printerr("smoke_runner requires a JSON config after `--`")
        quit(2)
        return
    var parsed: Variant = JSON.parse_string(str(user_args[0]))
    if not (parsed is Dictionary):
        printerr("smoke_runner config must be a JSON object, got: " + str(user_args[0]))
        quit(2)
        return
    config = parsed
    scene_path = _normalize_res_path(_cfg_str("scene", ""))
    fps_rate = maxf(_cfg_float("fps", 60.0), 1.0)
    target_frames = maxi(int(round(_cfg_float("seconds", 1.0) * fps_rate)), 1)
    sample_interval = maxi(_cfg_int("sample_interval", int(max(1.0, fps_rate / 10.0))), 1)
    settle_frames = maxi(_cfg_int("settle_frames", 2), 0)
    profile = _cfg_bool("profile", false)
    run_mode = _cfg_str("mode", "fixed_fps")
    run_seconds = maxf(_cfg_float("seconds", 1.0), 0.001)
    budget_ms = maxi(_cfg_int("budget_ms", 0), 0)
    fuzz_enabled = _cfg_bool("fuzz", false)
    fuzz_mouse = _cfg_bool("fuzz_mouse", false)
    fuzz_seed = _cfg_int("fuzz_seed", 0)
    fuzz_interval = maxi(_cfg_int("fuzz_interval", int(max(1.0, fps_rate / 10.0))), 1)
    rng.seed = fuzz_seed
    call_deferred("_run")


# MainLoop virtual. Reached on every shutdown, including the one the *scene*
# triggers with get_tree().quit() — at that point the `await process_frame` in
# _run() is never resumed, so this is where that run gets reported.
func _finalize() -> void:
    if result_emitted:
        return
    _release_all_inputs()
    ended = "quit_called"
    findings.append({
        "type": "quit_called",
        "severity": "info",
        "message": (
            "The scene ended the run itself with get_tree().quit() after %d of %d frames (%.2f s of %.2f s). "
            + "Everything after that point was never exercised. This is expected for a quit button and for a "
            + "splash/boot scene; it is a bug when a gameplay scene does it."
        ) % [frames_run, target_frames, _elapsed_seconds(), target_frames / fps_rate]
    })
    _emit_result()


func _run() -> void:
    started_ms = Time.get_ticks_msec()
    baseline_nodes = _monitor(Performance.OBJECT_NODE_COUNT)
    baseline_orphans = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)

    if scene_path.is_empty():
        _fail_finding("bad_config", "smoke_runner config needs a \"scene\" key holding a res:// path.")
        _emit_result()
        quit(1)
        return

    if not ResourceLoader.exists(scene_path):
        _fail_finding(
            "scene_missing",
            "Scene does not exist: %s. Check the path, or run with --all to smoke every scene the project has."
                % scene_path
        )
        _emit_result()
        quit(1)
        return

    var packed: Variant = load(scene_path)
    if not (packed is PackedScene):
        _fail_finding(
            "load_failed",
            ("Failed to load %s as a PackedScene. The engine error above says why — usually a missing "
                + "[ext_resource] or a script that does not parse.") % scene_path
        )
        _emit_result()
        quit(1)
        return

    # A headless run opens a 64x64 window, so anchors, container layout and any
    # mouse coordinate would resolve against a viewport no player ever sees.
    viewport_size = Vector2i(
        int(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
        int(ProjectSettings.get_setting("display/window/size/viewport_height", 648))
    )
    root.size = viewport_size

    var packed_scene: PackedScene = packed
    scene_root = packed_scene.instantiate()
    if scene_root == null:
        _fail_finding(
            "instantiate_failed",
            ("PackedScene.instantiate() returned null for %s, so the scene is unusable. The engine's "
                + "\"Invalid scene\" error above names the node: the first [node] entry must have no parent= "
                + "key and every other one needs a parent= naming a node declared before it.") % scene_path
        )
        _emit_result()
        quit(1)
        return

    root.add_child(scene_root)
    current_scene = scene_root
    print("[SMOKE] scene=%s frames=%d fps=%d viewport=%dx%d" % [
        scene_path, target_frames, int(fps_rate), viewport_size.x, viewport_size.y])

    if fuzz_enabled:
        _prepare_fuzz()

    for _index in range(settle_frames):
        await process_frame
        if not _scene_alive():
            break

    _take_sample()
    run_started_ms = Time.get_ticks_msec()
    var last_ms := Time.get_ticks_usec()
    while not _run_complete():
        await process_frame
        frames_run += 1
        var now_us := Time.get_ticks_usec()
        frame_ms.append(float(now_us - last_ms) / 1000.0)
        last_ms = now_us

        if not _scene_alive():
            await process_frame
            _note_scene_changed()
            break
        if fuzz_enabled:
            _fuzz_tick()
        if frames_run % sample_interval == 0:
            _take_sample()
        if budget_ms > 0 and Time.get_ticks_msec() - started_ms > budget_ms:
            ended = "budget_exceeded"
            findings.append({
                "type": "timed_out",
                "severity": "error",
                "message": (
                    "The scene used more than %d ms of wall time for %d of %d frames and the run was stopped. "
                    + "Something in _process/_physics_process is far too slow (or blocking). Profile it with "
                    + "--profile, or raise --timeout if the scene is legitimately heavy."
                ) % [budget_ms, frames_run, target_frames]
            })
            break

    _release_all_inputs()
    if _scene_alive():
        await process_frame
        _take_sample()

    if _scene_alive():
        scene_root.queue_free()
        await process_frame
        await process_frame
    orphans_after_free = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)

    _analyse()
    _emit_result()
    quit(0)


# In fixed-fps mode one iteration is exactly 1/60 s of game time, so the run is
# bounded by a frame count and the result is bit-for-bit reproducible. In
# real-time mode the engine paces itself, so the bound is wall time instead.
func _run_complete() -> bool:
    if run_mode == "real_time":
        return float(Time.get_ticks_msec() - run_started_ms) >= run_seconds * 1000.0
    return frames_run >= target_frames


func _elapsed_seconds() -> float:
    if run_mode == "real_time":
        if run_started_ms == 0:
            return 0.0
        return float(Time.get_ticks_msec() - run_started_ms) / 1000.0
    return float(frames_run) / fps_rate


# --- sampling ---------------------------------------------------------------

func _monitor(monitor: int) -> int:
    return int(Performance.get_monitor(monitor))


func _take_sample() -> void:
    var sample := {
        "frame": frames_run,
        "node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
        "orphan_node_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
        "object_count": Performance.get_monitor(Performance.OBJECT_COUNT),
        "static_memory": Performance.get_monitor(Performance.MEMORY_STATIC)
    }
    if profile:
        sample["fps"] = Performance.get_monitor(Performance.TIME_FPS)
        sample["process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
        sample["physics_process_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
        sample["physics_2d_active_objects"] = Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
        sample["physics_2d_collision_pairs"] = Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
        sample["physics_3d_active_objects"] = Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
        sample["physics_3d_collision_pairs"] = Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)
    samples.append(sample)


func _series(key: String) -> Array:
    var out: Array = []
    for sample in samples:
        var entry := sample as Dictionary
        if entry.has(key):
            out.append(float(entry[key]))
    return out


func _stats(values: Array) -> Dictionary:
    if values.is_empty():
        return {}
    var sorted: Array = values.duplicate()
    sorted.sort()
    var total := 0.0
    for value in values:
        total += float(value)
    var p95_index := int(ceil(0.95 * sorted.size())) - 1
    p95_index = clampi(p95_index, 0, sorted.size() - 1)
    return {
        "avg": _round2(total / float(values.size())),
        "p95": _round2(float(sorted[p95_index])),
        "max": _round2(float(sorted[sorted.size() - 1])),
        "min": _round2(float(sorted[0])),
        "start": _round2(float(values[0])),
        "end": _round2(float(values[values.size() - 1])),
        "samples": values.size()
    }


func _round2(value: float) -> float:
    return snappedf(value, 0.01)


# --- findings ---------------------------------------------------------------

func _analyse() -> void:
    var nodes := _series("node_count")

    # Node growth: compare a point 40% into the run (startup spawning is done by
    # then) with the last sample, so "spawns 30 enemies at _ready" never trips
    # while "spawns a bullet every frame and never frees it" always does.
    if nodes.size() >= 4:
        var early_index := int(floor(float(nodes.size()) * 0.4))
        early_index = clampi(early_index, 0, nodes.size() - 2)
        var early := float(nodes[early_index])
        var late := float(nodes[nodes.size() - 1])
        var growth := late - early
        var min_growth: float = maxf(_cfg_float("node_growth_min", 24.0), 1.0)
        var ratio: float = _cfg_float("node_growth_ratio", 0.25)
        if growth >= maxf(min_growth, early * ratio):
            var window_seconds: float = maxf(_elapsed_seconds() * 0.6, 1.0 / fps_rate)
            var per_second: float = growth / window_seconds
            findings.append({
                "type": "node_growth",
                "severity": "warning",
                "message": (
                    "Node count climbed from %d to %d during the run (+%.0f nodes, about %.0f per second) and "
                    + "was still climbing at the end. Something spawns nodes and never frees them — bullets, "
                    + "particles, damage numbers, audio players. Free them (queue_free() on hit/on screen exit/"
                    + "on finished), or pool them. Re-run with --profile to see the curve."
                ) % [int(early), int(late), growth, per_second],
                "node_count_early": int(early),
                "node_count_end": int(late),
                "per_second": _round2(per_second)
            })

    if orphans_after_free > baseline_orphans and ended == "completed":
        var leaked := orphans_after_free - baseline_orphans
        findings.append({
            "type": "orphan_nodes",
            "severity": "warning",
            "message": (
                "%d node(s) were still alive outside the tree after the scene was freed. A node that is "
                + "`Node.new()`d and never added to the tree, or `remove_child()`ed and never freed, leaks "
                + "until the process exits. Add it to the tree, or free it with queue_free()/free()."
            ) % leaked,
            "orphan_nodes": leaked
        })

    if ended != "completed":
        notes.append(
            "The orphan-node check was skipped: it only means something when the smoke run is the thing that "
            + "frees the scene, and this run ended early (" + ended + ")."
        )

    var memory := _series("static_memory")
    if memory.size() >= 4:
        var mem_early := float(memory[int(floor(float(memory.size()) * 0.4))])
        var mem_late := float(memory[memory.size() - 1])
        var grow_mb := (mem_late - mem_early) / 1048576.0
        var min_mb: float = _cfg_float("memory_growth_mb", 8.0)
        var mem_ratio: float = _cfg_float("memory_growth_ratio", 0.25)
        if grow_mb >= min_mb and mem_late >= mem_early * (1.0 + mem_ratio):
            findings.append({
                "type": "static_memory_growth",
                "severity": "warning",
                "message": (
                    "Static memory grew %.1f MB (%.1f MB to %.1f MB) in %.2f s and was still growing. "
                    + "Look for resources loaded every frame (load() in _process), an array that is only ever "
                    + "appended to, or freed nodes still referenced by a dictionary."
                ) % [grow_mb, mem_early / 1048576.0, mem_late / 1048576.0, _elapsed_seconds()],
                "growth_mb": _round2(grow_mb)
            })

    if profile:
        notes.append(
            "Headless runs use the dummy renderer: draw calls, primitives and video memory are always 0 and "
            + "are not reported. Node/object/memory counts and process timings are real."
        )


func _note_scene_changed() -> void:
    ended = "scene_changed"
    destination_scene = ""
    if current_scene != null and is_instance_valid(current_scene) and current_scene != scene_root:
        destination_scene = str(current_scene.scene_file_path)
    var where := "freed itself"
    if not destination_scene.is_empty():
        where = "switched to " + destination_scene
    findings.append({
        "type": "scene_changed",
        "severity": "info",
        "message": (
            "The scene %s after %d of %d frames (%.2f s), so the rest of this run exercised nothing. "
            + "That is normal for a splash/loading scene; smoke-run the destination separately (it is covered "
            + "by --all)."
        ) % [where, frames_run, target_frames, _elapsed_seconds()],
        "destination": destination_scene
    })


func _fail_finding(type_name: String, message: String) -> void:
    findings.append({"type": type_name, "severity": "error", "message": message})
    ended = type_name


func _scene_alive() -> bool:
    return scene_root != null and is_instance_valid(scene_root) and scene_root.is_inside_tree()


# --- fuzzing ----------------------------------------------------------------

func _prepare_fuzz() -> void:
    var actions: Array = InputMap.get_actions()
    for action in actions:
        var name := str(action)
        if name.begins_with("ui_"):
            if FUZZ_UI_ACTIONS.has(name):
                fuzz_ui_actions.append(name)
        else:
            fuzz_actions.append(name)
    fuzz_actions.sort()
    fuzz_ui_actions.sort()
    print("[SMOKE] fuzz seed=%d project_actions=%d ui_actions=%d mouse=%s" % [
        fuzz_seed, fuzz_actions.size(), fuzz_ui_actions.size(), str(fuzz_mouse)])
    if fuzz_actions.is_empty() and fuzz_ui_actions.is_empty():
        notes.append(
            "--fuzz had nothing to press: the project defines no input actions. Add them with "
            + "project_batch set_input_action, or run with --fuzz-mouse only."
        )


func _fuzz_tick() -> void:
    var still_held: Array = []
    for entry in held:
        var record := entry as Dictionary
        if int(record["release_frame"]) <= frames_run:
            _release_held(record)
        else:
            still_held.append(record)
    held = still_held

    if frames_run % fuzz_interval != 0:
        return

    if fuzz_mouse and rng.randf() < 0.35:
        _fuzz_mouse_event()
        return

    var action := _pick_action()
    if action.is_empty():
        return
    for entry in held:
        var record := entry as Dictionary
        if str(record["action"]) == action:
            return
    # Hold length is drawn before the event so the RNG draw order does not
    # depend on whether the action turned out to have a usable event.
    var hold := rng.randi_range(1, 12)
    var event := _make_action_event(action, true)
    if event == null:
        return
    Input.parse_input_event(event)
    _log_input("+" + action)
    held.append({"action": action, "event": event, "release_frame": frames_run + hold})


func _pick_action() -> String:
    var use_ui := fuzz_actions.is_empty() or (not fuzz_ui_actions.is_empty() and rng.randf() < 0.2)
    var pool: Array = fuzz_ui_actions if use_ui else fuzz_actions
    if pool.is_empty():
        return ""
    return str(pool[rng.randi_range(0, pool.size() - 1)])


# Release the exact event that was pressed. Re-drawing one from the action's
# event list would both consume RNG (breaking --fuzz-seed reproducibility) and
# risk releasing a different key than the one held down.
func _release_held(record: Dictionary) -> void:
    var pressed_event := record["event"] as InputEvent
    var action := str(record["action"])
    if pressed_event != null:
        var release := _flip_event(pressed_event, false)
        if release != null:
            Input.parse_input_event(release)
    var action_name := StringName(action)
    if InputMap.has_action(action_name) and Input.is_action_pressed(action_name):
        Input.action_release(action_name)
    _log_input("-" + action)


func _make_action_event(action: String, pressed: bool) -> InputEvent:
    var events: Array[InputEvent] = InputMap.action_get_events(StringName(action))
    if events.is_empty():
        return null
    var source := events[rng.randi_range(0, events.size() - 1)]
    return _flip_event(source, pressed)


func _flip_event(source: InputEvent, pressed: bool) -> InputEvent:
    var copy := source.duplicate() as InputEvent
    if copy == null:
        return null
    var key_event := copy as InputEventKey
    if key_event != null:
        key_event.pressed = pressed
        key_event.echo = false
        return key_event
    var mouse_event := copy as InputEventMouseButton
    if mouse_event != null:
        mouse_event.pressed = pressed
        if mouse_event.position == Vector2.ZERO:
            mouse_event.position = Vector2(viewport_size) * 0.5
            mouse_event.global_position = mouse_event.position
        return mouse_event
    var pad_event := copy as InputEventJoypadButton
    if pad_event != null:
        pad_event.pressed = pressed
        return pad_event
    var motion_event := copy as InputEventJoypadMotion
    if motion_event != null:
        if not pressed:
            motion_event.axis_value = 0.0
        elif is_zero_approx(motion_event.axis_value):
            motion_event.axis_value = 1.0
        return motion_event
    var action_event := copy as InputEventAction
    if action_event != null:
        action_event.pressed = pressed
        return action_event
    return copy


func _fuzz_mouse_event() -> void:
    var buttons: Array = []
    if _scene_alive():
        _collect_buttons(scene_root, buttons)
    if not buttons.is_empty() and rng.randf() < 0.6:
        var target := buttons[rng.randi_range(0, buttons.size() - 1)] as Dictionary
        _click_at(target["position"] as Vector2, str(target["label"]))
        return
    var point := _random_point()
    if rng.randf() < 0.5:
        _click_at(point, "")
        return
    var motion := InputEventMouseMotion.new()
    motion.position = point
    motion.global_position = point
    motion.relative = Vector2(rng.randf_range(-16.0, 16.0), rng.randf_range(-16.0, 16.0))
    Input.parse_input_event(motion)
    _log_input("move %d,%d" % [int(point.x), int(point.y)])


func _click_at(point: Vector2, label: String) -> void:
    var motion := InputEventMouseMotion.new()
    motion.position = point
    motion.global_position = point
    Input.parse_input_event(motion)
    var press := InputEventMouseButton.new()
    press.button_index = MOUSE_BUTTON_LEFT
    press.pressed = true
    press.position = point
    press.global_position = point
    Input.parse_input_event(press)
    var release := InputEventMouseButton.new()
    release.button_index = MOUSE_BUTTON_LEFT
    release.pressed = false
    release.position = point
    release.global_position = point
    Input.parse_input_event(release)
    var suffix := "" if label.is_empty() else " [" + label + "]"
    _log_input("click %d,%d%s" % [int(point.x), int(point.y), suffix])


func _collect_buttons(node: Node, out: Array) -> void:
    var button := node as BaseButton
    if button != null and button.is_visible_in_tree() and button.size.x > 0.0 and button.size.y > 0.0:
        var rect := button.get_global_rect()
        out.append({"position": rect.get_center(), "label": str(button.name)})
    for child in node.get_children():
        _collect_buttons(child, out)


func _random_point() -> Vector2:
    return Vector2(
        float(rng.randi_range(0, maxi(viewport_size.x - 1, 1))),
        float(rng.randi_range(0, maxi(viewport_size.y - 1, 1)))
    )


func _release_all_inputs() -> void:
    for entry in held:
        _release_held(entry as Dictionary)
    held = []
    # Belt and braces: a fuzzed action whose event never reached the Input
    # singleton would otherwise stay "pressed" for anything polling it.
    for action in fuzz_actions:
        var name := StringName(str(action))
        if Input.is_action_pressed(name):
            Input.action_release(name)
    for action in fuzz_ui_actions:
        var ui_name := StringName(str(action))
        if Input.is_action_pressed(ui_name):
            Input.action_release(ui_name)


func _log_input(text: String) -> void:
    var entry := "f%d %s" % [frames_run, text]
    fuzz_log.append(entry)
    # Printed live so a scene that hard-crashes the engine still leaves the
    # input that killed it in the log, above the crash.
    print("[SMOKE_INPUT] " + entry)


# --- result -----------------------------------------------------------------

func _emit_result() -> void:
    if result_emitted:
        return
    result_emitted = true
    var result := {
        "scene": scene_path,
        "frames": frames_run,
        "target_frames": target_frames,
        "seconds_simulated": _round2(_elapsed_seconds()),
        "mode": run_mode,
        "ended": ended,
        "findings": findings,
        "notes": notes
    }
    if not destination_scene.is_empty():
        result["destination"] = destination_scene
    if fuzz_enabled:
        result["fuzz"] = {"seed": fuzz_seed, "events": fuzz_log, "event_count": fuzz_log.size()}
    result["perf"] = _perf_payload()
    # _perf_payload may add a note of its own, so notes are attached last.
    result["notes"] = notes
    print(RESULT_MARKER + JSON.stringify(result))


func _perf_payload() -> Dictionary:
    var nodes := _series("node_count")
    var node_start := baseline_nodes
    var node_end := baseline_nodes
    if not nodes.is_empty():
        node_start = int(nodes[0])
        node_end = int(nodes[nodes.size() - 1])
    var memory := _series("static_memory")
    var memory_mb := 0.0
    if not memory.is_empty():
        memory_mb = _round2(float(memory[memory.size() - 1]) / 1048576.0)

    # Only meaningful when this run is what freed the scene; null (never a
    # made-up 0) when the scene quit or navigated away first.
    var orphan_value: Variant = null
    if ended == "completed":
        orphan_value = maxi(orphans_after_free - baseline_orphans, 0)

    var payload := {
        "samples": samples.size(),
        "node_count_start": node_start,
        "node_count_end": node_end,
        "orphan_nodes": orphan_value,
        "static_memory_mb": memory_mb,
        "frame_ms": _stats(frame_ms)
    }
    if not profile:
        return payload

    var monitors := {
        "fps": _stats(_series("fps")),
        "process_ms": _stats(_series("process_ms")),
        "physics_process_ms": _stats(_series("physics_process_ms")),
        "object_count": _stats(_series("object_count")),
        "node_count": _stats(nodes),
        "orphan_node_count": _stats(_series("orphan_node_count")),
        "static_memory_mb": _stats(_mb(_series("static_memory"))),
        "physics_2d_active_objects": _stats(_series("physics_2d_active_objects")),
        "physics_2d_collision_pairs": _stats(_series("physics_2d_collision_pairs")),
        "physics_3d_active_objects": _stats(_series("physics_3d_active_objects")),
        "physics_3d_collision_pairs": _stats(_series("physics_3d_collision_pairs"))
    }
    payload["monitors"] = monitors
    var fps_stats := monitors["fps"] as Dictionary
    var process_stats := monitors["process_ms"] as Dictionary
    var physics_stats := monitors["physics_process_ms"] as Dictionary

    # TIME_FPS / TIME_PROCESS / TIME_PHYSICS_PROCESS are refreshed once per real
    # second. A --fixed-fps run of a light scene is over in milliseconds, so they
    # never move off their initial values (fps 1.0, times 0.0). Reporting those
    # as "your game runs at 1 fps" would be a lie, so they go out as null with an
    # explanation instead. A non-degenerate fps sample proves they did refresh.
    var engine_timings_valid := false
    for value in _series("fps"):
        if float(value) > 1.0:
            engine_timings_valid = true
            break
    if engine_timings_valid:
        payload["fps_avg"] = fps_stats.get("avg", 0.0)
        payload["process_ms_p95"] = process_stats.get("p95", 0.0)
        payload["physics_ms_p95"] = physics_stats.get("p95", 0.0)
    else:
        payload["fps_avg"] = null
        payload["process_ms_p95"] = null
        payload["physics_ms_p95"] = null
        notes.append(
            "fps_avg / process_ms_p95 / physics_ms_p95 are null: the engine refreshes those monitors once per "
            + "real second and this run finished sooner. frame_ms below is measured by the runner itself and is "
            + "always valid (wall time per frame, which is pure CPU cost because nothing throttles a headless "
            + "run). For engine-reported timings re-run that scene with --real-time --seconds 3."
        )
    return payload


func _mb(values: Array) -> Array:
    var out: Array = []
    for value in values:
        out.append(float(value) / 1048576.0)
    return out


# --- small helpers ----------------------------------------------------------

func _cfg_str(key: String, fallback: String) -> String:
    if config.has(key):
        return str(config[key])
    return fallback


func _cfg_float(key: String, fallback: float) -> float:
    if config.has(key):
        return float(config[key])
    return fallback


func _cfg_int(key: String, fallback: int) -> int:
    if config.has(key):
        return int(config[key])
    return fallback


func _cfg_bool(key: String, fallback: bool) -> bool:
    if config.has(key):
        return bool(config[key])
    return fallback


func _normalize_res_path(path_value: String) -> String:
    var path := path_value.strip_edges().replace("\\", "/")
    if path.is_empty():
        return ""
    if path.begins_with("res://"):
        return path
    return "res://" + path.trim_prefix("/")
