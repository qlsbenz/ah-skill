# Unit Testing Godot Game Logic

Read this reference when the task is to write, run or fix unit tests for a Godot
project's own code — a damage formula, an inventory, a state machine, a
component's signals, a body that must land on the floor.

Godot has **no built-in project test runner**, and the two community frameworks
(GUT, GdUnit4) are addons that must be downloaded. So this skill ships a third
option that needs nothing: one base class copied into the project plus a bundled
runner. Everything here works offline and headless, with no addon, no download,
and no `--import` pass for the framework itself (the base class deliberately
declares no `class_name`, so nothing has to be in the global class cache).

| File | Role |
| --- | --- |
| `templates/tests/test_case.gd` | The base class. Copied to `res://tests/test_case.gd`; suites do `extends "res://tests/test_case.gd"`. |
| `templates/tests/test_example.gd` | The starter suite `--init-mini` copies in. Edit it, do not keep it. |
| `templates/tests/test_inventory_logic.gd` | Sample: pure logic (no nodes, no frames). |
| `templates/tests/test_scene_physics.gd` | Sample: live tree, physics frames, real input. |
| `templates/tests/test_health_signals.gd` | Sample: signals, including signals with arguments. |
| `scripts/test/mini_test_runner.gd` | The runner (`extends SceneTree`). Not called directly. |
| `scripts/test/run_tests.py` | The CLI: detection, JSON result, exit code. |

## Install (once per project)

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --init-mini
```

Writes `res://tests/test_case.gd` and `res://tests/test_example.gd` and prints
what it created. It **refuses to overwrite** an existing setup (exit 1) — delete
the files or pass `--tests-dir other_dir` to install alongside. `--tests-dir` is
honoured when copying: the example's `extends` line is rewritten to match.

Then run everything:

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
```

Detection order is **gut → gdunit4 → mini**, so a project that already has GUT
keeps using GUT. Force one with `--framework mini|gut|gdunit4`. With no framework
at all, the error tells you to run `--init-mini`.

## The TDD loop

This is the loop, verbatim. It was run start to finish on Godot 4.7.

1. **Write the test first**, as `res://tests/test_damage.gd`:

   ```bash
   cat > /absolute/path/to/project/tests/test_damage.gd <<'GDSCRIPT'
   extends "res://tests/test_case.gd"

   const Damage = preload("res://scripts/damage.gd")

   func test_base_damage_passes_through_without_armor() -> void:
   	assert_eq(Damage.resolve(10, 0, false), 10)

   func test_armor_subtracts_but_never_heals() -> void:
   	assert_eq(Damage.resolve(10, 4, false), 6)
   	assert_eq(Damage.resolve(3, 9, false), 1, "a hit always does at least 1")

   func test_a_critical_hit_doubles_the_damage_after_armor() -> void:
   	assert_eq(Damage.resolve(10, 4, true), 12)
   GDSCRIPT
   ```

2. **Run it.** The subject does not exist yet, so the suite cannot even load —
   and says exactly that, with the line:

   <!-- replay: fails -->
   ```bash
   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --select damage
   ```

   ```text
   error <script> | the script failed to load — fix the parse error the engine
   reported above: Preload file "res://scripts/damage.gd" does not exist.
   at res://tests/test_damage.gd:3
   ```

3. **Write the smallest wrong thing** (`res://scripts/damage.gd`):

   ```bash
   cat > /absolute/path/to/project/scripts/damage.gd <<'GDSCRIPT'
   extends RefCounted

   static func resolve(base: int, armor: int, _critical: bool) -> int:
   	return base - armor
   GDSCRIPT
   ```

   Run again — red, with both values, both types, and the failing line:

   <!-- replay: fails -->
   ```bash
   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --select damage
   ```

   ```text
   failed res://tests/test_damage.gd:10 | a hit always does at least 1 — assert_eq: expected 1 (int) but got -6 (int)
   failed res://tests/test_damage.gd:13 | assert_eq: expected 12 (int) but got 6 (int)
   ```

4. **Make it right.**

   ```bash
   cat > /absolute/path/to/project/scripts/damage.gd <<'GDSCRIPT'
   extends RefCounted

   ## Damage after armor, never below 1, doubled on a critical hit.
   static func resolve(base: int, armor: int, critical: bool) -> int:
   	var after_armor := maxi(base - armor, 1)
   	return after_armor * 2 if critical else after_armor
   GDSCRIPT
   ```

   Run again — `"ok": true`, exit 0, three passed:

   ```bash
   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --select damage --pretty
   ```

5. **Iterate one test at a time** while working on one behaviour:

   ```bash
   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --select critical
   ```

   `--select` matches a substring of the test name *or* of the script path.

Delete `tests/test_example.gd` once you have a real suite; otherwise its four
passing tests pad every report.

## Statuses — and the trap this framework exists to close

| Status | Meaning | Fails the run |
| --- | --- | --- |
| `passed` | Ran to the end, made at least one assertion, none failed. | no |
| `failed` | An assertion failed. `line` is the assert's line. | yes |
| `error` | The engine printed an error while the test ran (runtime error, `push_error`, a failed load). | yes |
| `timeout` | The test did not finish within `--test-timeout` (default 10 s). | yes |
| `skipped` | The test called `skip("why")`. | no |
| `pending` | The test called `pending("why")`. | no |
| `risky` | The test made **no assertion at all**. | only with `--strict` |

**`error` is the important one.** A GDScript runtime error does not raise: it
aborts the function it happens in and returns to the caller with no exception
and no return value. A test that dereferences null on its first line therefore
looks, to the calling runner, exactly like a test that passed. This runner
brackets every test with `[MINI_TEST] begin|end` markers and `run_tests.py`
attributes the engine's `SCRIPT ERROR:` lines between them to that test, so the
result is `error` with the engine's own message and line:

```
error test_player_movement | The InputMap action "Jump" doesn't exist. Did you mean "jump"? at res://scripts/player.gd:16
```

If the code under test is *supposed* to print an error (you are testing an error
path, or it calls `push_error` deliberately), call `allow_errors()` inside that
test and engine errors stop counting against it.

**`risky` is the second one.** A test with no assertion cannot fail, so it
proves nothing while still colouring the report green. Mark genuinely unwritten
tests `pending("…")`; pass `--strict` in CI to make `risky` fail.

## Assertions

Every assertion takes an optional trailing `message`, returns `true` on success
(so `if not assert_not_null(node): return` is a valid early-out), and prints both
values with their types on failure — `expected 3 (int) but got "3" (String)` —
plus the script and line it was called from.

| Assertion | Notes |
| --- | --- |
| `assert_true(v)` / `assert_false(v)` | A non-bool is a failure, not a truthiness test. |
| `assert_eq(actual, expected)` / `assert_ne(actual, other)` | GUT's argument order. Deep for Array/Dictionary. Mismatched types are unequal, never a crash. |
| `assert_almost_eq(actual, expected, tolerance)` | Use for every float. Also handles Vector2/Vector3/Color. |
| `assert_null(v)` / `assert_not_null(v)` | |
| `assert_gt(a, b)` / `assert_lt(a, b)` / `assert_between(v, low, high)` | `assert_between` is inclusive. Incomparable types fail with a clear message. |
| `assert_has(container, value)` / `assert_does_not_have(...)` | Array, Dictionary (keys), String (substring), packed arrays. |
| `assert_string_contains(text, substring)` | |
| `assert_is(object, type)` | `type` may be a native class (`Node2D`), a `preload`ed script, or a class-name String. |
| `fail(msg)` | Unconditional failure; counts as an assertion. |
| `skip(msg)` / `pending(msg)` | Only *mark* the result — `return` on the next line. |
| `allow_errors()` | Engine errors during this test are expected. |

## Lifecycle and isolation

`before_all` → (`before_each` → `test_x` → `after_each`)* → `after_all`. All four
are optional and may be coroutines.

- `add_child_autofree(node)` adds a node under the test (which is itself in the
  tree) and frees it after the test. `add_scene("res://scenes/level.tscn")`
  instantiates, adds and autofrees in one call. `autofree(object)` covers
  anything else.
- Nodes created in `before_all` live for the whole script, not just the first test.
- Input pressed with `press_action()` / `send_key()` is released after the test,
  so a held key cannot leak into the next one.
- Orphan nodes are counted per script; a leak is reported in `notes[]`.

## Autoloads and `class_name`

**Autoloads just work.** The runner starts deferred, after the first frame, so
the project's singletons are registered before any test script is loaded:

```gdscript
func before_each() -> void:
	GameState.score = 0

func test_the_autoload_singleton_is_available() -> void:
	GameState.add_score(7)
	assert_eq(GameState.score, 7)
```

Because there is one process for the whole suite, an autoload keeps whatever the
previous test left in it. Reset the parts you depend on in `before_each`.

**A project's own `class_name` needs one `--import` first.** A global class is
only visible to other scripts through
`.godot/global_script_class_cache.cfg`, and a `--script` run never rebuilds it.
A fresh clone therefore fails to even load the suite:

```
error <script> | the script failed to load — fix the parse error the engine
reported above: Identifier "Weapon" not declared in the current scope.
at res://tests/test_autoload.gd:12
```

`run_tests.py` recognises this and puts the fix in `hints[]`. Run it once:

```bash
godot --headless --path /absolute/path/to/project --import
```

`preload("res://scripts/weapon.gd")` needs no cache and works immediately, which
is why the samples use it.

## Testing a scene, with physics and input

Headless Godot runs physics normally, so "does the player fall through the
floor" is a unit test, not a screenshot.

```gdscript
extends "res://tests/test_case.gd"

var level: Node2D
var player: CharacterBody2D

func before_each() -> void:
	level = add_scene("res://scenes/level.tscn")
	player = level.get_node("Player")

func test_the_player_lands_on_the_tilemap_floor() -> void:
	await wait_physics_frames(45)
	assert_true(player.is_on_floor())

func test_jump_leaves_the_floor() -> void:
	await wait_physics_frames(45)
	assert_true(player.is_on_floor(), "precondition: standing")
	press_action(&"jump")
	await wait_physics_frames(3)
	release_action(&"jump")
	assert_false(player.is_on_floor())
	assert_lt(player.velocity.y, 0.0, "velocity should point up right after the jump")
```

- `press_action(&"jump")` sends a real `InputEventAction` through
  `Input.parse_input_event` and flushes the input buffer, so both polled checks
  (`Input.is_action_pressed`, `Input.get_axis`) and `_input()` / `_unhandled_input()`
  callbacks see it **immediately** — no frame wait needed. `send_key(KEY_SPACE)`
  does the same with a real key event.
- Waiting: `await wait_frames(n)`, `await wait_physics_frames(n)`,
  `await wait_seconds(s)`, `await wait_until(func(): return x > 3, 2.0)`.
  One physics frame is 1/60 s of simulated time; 45 of them is a 0.75 s fall.
- A test may `await` anything. If it never returns, the per-test timeout
  (`--test-timeout`, default 10 s) fails **that test** and the run continues.
- Headless opens a 64×64 viewport. Physics and logic do not care; UI anchors and
  container layout do — verify those with `run_scenario.py`'s `ui_report`
  instead (see `references/automation_api.md`).

## Signals, including signals with arguments

`watch_signals(object)` records **every** signal of that object from the moment
it is called, at any arity, with the emitted arguments. Call it before the code
that emits.

```gdscript
const Health = preload("res://scripts/health.gd")

func test_damage_emits_damaged_with_amount_and_remainder() -> void:
	var health: Node = add_child_autofree(Health.new())
	watch_signals(health)
	health.take_damage(1)
	assert_signal_emitted(health, "damaged")
	assert_signal_emit_count(health, "damaged", 1)
	assert_eq(get_signal_args(health, "damaged"), [1, 2])
	assert_signal_not_emitted(health, "died")
```

`assert_signal_emitted_with(obj, name, [2, 3])` asserts that *some* emission
carried exactly those arguments. `get_signal_args(obj, name, index := -1)`
returns one emission's arguments (`-1` = the latest), `get_signal_emit_count`
the count.

Forgetting `watch_signals` does not read as "never emitted" — the assertion
fails with *"…is not being watched — call watch_signals(object) before the code
that emits"*. A misspelled signal name fails with the list of signals that do
exist.

A signal emitted from a deferred call or a later frame is recorded too — `await
wait_frames(1)` first, then assert.

## Output and exit codes

`run_tests.py` prints one JSON document (`--pretty` to indent) and exits `0`
when `ok` is true, `1` otherwise.

```json
{
  "ok": false,
  "framework": "mini",
  "tests_dir": "res://tests",
  "counts": {"scripts": 1, "tests": 8, "passed": 2, "failed": 1, "errors": 1,
             "skipped": 1, "pending": 1, "risky": 1, "timed_out": 1,
             "non_test_failures": 0},
  "failures": [{"script": "res://tests/test_kitchen_sink.gd",
                "test": "test_fails_with_types", "line": 22,
                "message": "string vs int — assert_eq: expected 3 (int) but got \"3\" (String)",
                "status": "failed", "source": "res://tests/test_kitchen_sink.gd"}],
  "duration_s": 2.3
}
```

- Every `test_*` method lands in exactly one status bucket, so
  `passed + failed + errors + skipped + pending + risky + timed_out == tests`.
- `non_test_failures` counts the things that are not test functions but still
  went wrong: a `before_all`/`after_all` hook, or a script that failed to load
  (reported with `"test": "<script>"`).
- `results[]` carries every entry with `asserts`, `duration_ms` and `kind`
  (`test` / `hook` / `script`); `scripts[]` carries per-file `tests` and
  `orphans`; `notes[]` carries non-fatal complaints (a `test_*.gd` that does not
  extend the base class, a leak).
- An empty tests directory is **not** a pass: with no test script under the
  resolved directory the wrapper exits 1 and says so (the base class alone does
  not count). `--allow-empty` opts out.
- `--timeout` is the wall-clock budget for the whole run (default 600 s);
  `--test-timeout` is per test. `--log-file PATH` keeps the raw merged Godot log.
- `--dry-run` prints the exact command without running it.

## What belongs in a scenario instead

Use `scripts/debug/run_scenario.py` (see `references/automation_api.md`) when the
question is about the *running game* rather than a unit of code: screenshots,
`ui_report` layout checks, `dump_tree`, performance thresholds, log assertions,
driving a scene for hundreds of frames. Use a mini test when the question is
"does this function/component behave", which is faster, isolated, and names the
line that broke.

## Coming from GUT or GdUnit4

| GUT | GdUnit4 | mini |
| --- | --- | --- |
| `extends GutTest` | `extends GdUnitTestSuite` | `extends "res://tests/test_case.gd"` |
| `assert_eq(a, b)` | `assert_int(a).is_equal(b)` | `assert_eq(a, b)` |
| `assert_almost_eq(a, b, t)` | `assert_float(a).is_equal_approx(b, t)` | `assert_almost_eq(a, b, t)` |
| `assert_true/false` | `assert_bool(x).is_true()` | `assert_true/false` |
| `assert_null/not_null` | `assert_object(x).is_null()` | `assert_null/not_null` |
| `assert_has(c, v)` | `assert_array(c).contains([v])` | `assert_has(c, v)` |
| `assert_is(o, T)` | `assert_object(o).is_instanceof(T)` | `assert_is(o, T)` |
| `watch_signals(o)` + `assert_signal_emitted` | `await assert_signal(o).is_emitted("x")` | `watch_signals(o)` + `assert_signal_emitted` |
| `autofree`/`add_child_autofree` | `auto_free` | `autofree`/`add_child_autofree` |
| `before_all/before_each/after_each/after_all` | `before/before_test/after_test/after` | `before_all/before_each/after_each/after_all` |
| `pending("…")` | `skip=true` | `pending("…")` / `skip("…")` |
| `yield_frames` / `await get_tree()...` | `await await_idle_frame()` | `await wait_frames(n)` |

The mini framework is deliberately smaller: no doubles/mocks/spies, no
parameterised tests, no fuzzers, no HTML report. If you need those, install GUT —
`run_tests.py` will pick it up automatically and this file stops applying.

## Limits (be honest about these)

- **No mocking.** Inject collaborators through exported properties or
  constructor arguments instead.
- **A timed-out coroutine is abandoned, not killed.** GDScript cannot cancel a
  suspended function. If it was awaiting a signal that later fires, it resumes
  in the middle of a later test, and anything it prints is attributed to that
  test. Keep `await`s bounded.
- **One process for the whole suite.** Autoloads, project settings and static
  variables are shared state; a test that changes them must change them back.
- **Engine errors are attributed by position in the log**, not by a callback the
  engine offers, so an error printed by a background thread can land on the
  wrong test. `allow_errors()` is the escape hatch.
- **Warnings are not failures here.** Use `check_project` with
  `--debug --ignore-error-breaks` (`references/debugging.md`) or
  `scripts/debug/lint_project.py` for those.
- `get_stack()` — how a failure learns its line number — needs the debugger.
  `run_tests.py` always passes `--debug --ignore-error-breaks`; if you invoke
  `mini_test_runner.gd` by hand without them, failures still report, just
  without a line.
