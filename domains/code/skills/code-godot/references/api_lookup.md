# API Lookup And Running Code

Read this reference before calling an engine method you have not just read, and
whenever a question about the engine is cheaper to answer by running it than by
reasoning about it.

Two tools, one problem — not remembering the API of the engine that is actually
installed:

| Tool | Answers |
| --- | --- |
| `scripts/docs/api_lookup.py` | "Does `CharacterBody2D.move_and_slide` exist, what does it take, what does it return, and which class declares `position`?" |
| `run_gdscript` (dispatcher op) | "What does this snippet actually evaluate to in *this* project, with its autoloads loaded?" |

Both read the installed engine, not a remembered one. A signature that came out
of `api_lookup.py` is the signature 4.7 has; a signature from memory is a guess
that costs a failed run to disprove.

## api_lookup.py

### Where the data comes from

`godot --headless --doctool <dir>` makes the engine dump its own class reference
as XML — 1076 classes in about half a second, including the Variant types
(`String`, `Array`, `Vector2`, `Callable`, the packed arrays), `@GlobalScope`
(every global function, `KEY_*`, `MOUSE_BUTTON_*`, `TYPE_*`), `@GDScript`
(`preload`, `assert`, `range`, the annotations), and every `theme_item`.

The dump carries **full signatures and no prose**: parameter names, types and
defaults, return types, qualifiers, property defaults, enum values. It is an
existence-and-shape check, not the manual.

### Invocation

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py CharacterBody2D.move_and_slide
```

The first call builds the cache (~0.6 s); every call after that is ~0.08 s.

### Queries

Positional arguments; as many as you like in one call.

```bash
# a class card: chain, own members, one line per ancestor
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py Timer
```

```
Timer < Node < Object
properties (7)
  autostart: bool = false
  ignore_time_scale: bool = false
  one_shot: bool = false
  paused: bool
  process_callback: Timer.TimerProcessCallback = 1 (TIMER_PROCESS_IDLE)
  time_left: float
  wait_time: float = 1.0
methods (3)
  is_stopped() -> bool [const]
  start(time_sec: float = -1) -> void
  stop() -> void
signals (1)
  timeout()
enums (1)
  TimerProcessCallback: TIMER_PROCESS_PHYSICS = 0, TIMER_PROCESS_IDLE = 1
inherited (add --inherited to expand, or look one member up directly):
  Node                   14 properties, 106 methods, 11 signals, 7 enums, 49 constants api_lookup.py Node
  Object                 62 methods, 2 signals, 1 enum, 3 constants     api_lookup.py Object
```

`Class.member` resolves **through the inheritance chain** and says who declares it:

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py CharacterBody2D.position
```

```
Node2D.position  (property)
  position: Vector2 = Vector2(0, 0)
  inherited: CharacterBody2D < PhysicsBody2D < CollisionObject2D < Node2D
  setter set_position / getter get_position
```

A signal also prints the two lines you are about to write:

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py Area2D.body_entered
```

```
Area2D.body_entered  (signal)
  body_entered(body: Node2D)
  connect: node.body_entered.connect(_on_body_entered)
  handler: func _on_body_entered(body: Node2D) -> void:
```

Other query shapes, all of which work:

| Query | Resolves to |
| --- | --- |
| `String.begins_with`, `Array.map`, `Vector2.slide` | Variant-type members |
| `lerp`, `preload`, `is_instance_valid` | `@GlobalScope` / `@GDScript` functions |
| `KEY_SPACE`, `MOUSE_BUTTON_LEFT`, `TYPE_VECTOR2` | `@GlobalScope` constants, with their enum |
| `Control.SIZE_EXPAND_FILL` | the constant plus every other value of `SizeFlags` |
| `Control.SizeFlags` | the whole enum, in full |
| `Node2D.move_local_x()` | trailing `()` is stripped |
| `Button --kind theme_items` | just the theme items |

`--kind` takes a comma-separated list of `methods`, `properties` (alias
`members`), `signals`, `constants`, `enums`, `theme_items`, `operators`,
`constructors`, `annotations`. `--inherited` expands every ancestor inline
instead of summarising it.

### Search

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py --search move_and --limit 6
```

```
4 matches for 'move_and':
  methods      CharacterBody2D.move_and_slide() -> bool
  methods      CharacterBody3D.move_and_slide() -> bool
  methods      PhysicsBody2D.move_and_collide(motion: Vector2, test_only: bool = false, safe_margin: float = 0.08, recovery_as_collision: bool = false) -> KinematicCollision2D
  methods      PhysicsBody3D.move_and_collide(motion: Vector3, test_only: bool = false, safe_margin: float = 0.001, recovery_as_collision: bool = false, max_collisions: int = 1) -> KinematicCollision3D
```

Ranking is exact > whole word > prefix > substring, then shortest name.
`--limit` defaults to 25.

### Wrong names fail loudly

A name that does not exist is exit `1`, never an empty result. When the name is
a Godot 3 name, the 4.x replacement is the answer (the rename table is shared
with `scripts/debug/lint_project.py`):

<!-- replay: fails -->
```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py KinematicBody2D
```

```text
KinematicBody2D: no such class in Godot 4.7.stable.official.5b4e0cb0f.
  `KinematicBody2D` is a Godot 3 name. In Godot 4.x use `CharacterBody2D`.
  run: api_lookup.py CharacterBody2D
```

A misspelling gets the nearest real names (`CharcterBody2D` → `CharacterBody2D,
CharacterBody3D`), and an unknown member lists the nearest members **on that
class's chain** (`Vector2.lenght` → `length`). Queries that did resolve still
print on stdout; the failures go to stderr and set the exit code.

### Project classes

Given a script in the project that declares a `class_name`:

```bash
cat > /absolute/path/to/project/scripts/pickup.gd <<'GDSCRIPT'
class_name Pickup
extends Area2D

## A coin the player walks into.
@export var value: int = 10

signal collected(by: Node2D)


func collect(by: Node2D) -> void:
	collected.emit(by)
	queue_free()
GDSCRIPT
```

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py --project /absolute/path/to/project Pickup Pickup.monitoring
```

```text
Pickup < Area2D < CollisionObject2D < Node2D < CanvasItem < Node < Object   [project class_name]
properties (1)
  value: int = 10
methods (1)
  collect(by: Node2D) -> void
signals (1)
  collected(by: Node2D)
inherited (add --inherited to expand, or look one member up directly):
  Area2D                 15 properties, 6 methods, 8 signals, 1 enum    api_lookup.py Area2D
  ...

Area2D.monitoring  (property)
  monitoring: bool = true
  inherited: Pickup < Area2D
  setter set_monitoring / getter is_monitoring
```

`--project` runs `--doctool … --gdscript-docs res://` over the project, so every
script that compiles joins the table with its exported properties, signals,
methods and `##` doc comments, and inherits the engine chain (so
`Pickup.monitoring` resolves to `Area2D.monitoring`). Project docs are
regenerated on every call — they change far more often than the engine does.

A script **without** `class_name` is indexed under its path and answers to
`res://scripts/player.gd`, `scripts/player.gd` or `player.gd`, with
`res://scripts/player.gd.jump` for one of its functions:

```
res://scripts/player.gd < CharacterBody2D < PhysicsBody2D < CollisionObject2D < Node2D < CanvasItem < Node < Object   [project script]
properties (5)
  move_speed: float = 120.0
  ...
```

`--project DIR --search .gd` lists every script the project has, one line each,
with the class each one extends.

If some scripts do not compile, the ones that do are still indexed and a note
naming the parse errors goes to stderr. A `class_name` that another script
refers to may need `godot --headless --path <project> --import` once before it
is visible (the global class cache is what makes `class_name` resolvable).

### Cache, engine selection, exit codes

- Cache: `$GODOT_SKILL_CACHE/api/<version>/` else `~/.cache/godot-skill/api/<version>/`,
  holding `xml/` and `index.json`. `--cache-dir DIR` overrides the base.
- Keyed by the engine's own version string, so two installed Godot versions
  never share an answer. `--refresh` rebuilds.
- A read-only cache directory is read, not rebuilt; when a rebuild is needed and
  the directory cannot be written, it falls back to the system temp directory
  and says so on stderr.
- `--godot BIN` (else `$GODOT_BIN`, else `godot`). A binary you *named* that
  cannot be run is exit `2`. With no binary at all and a populated cache, the
  cached version answers with a note on stderr; with no binary and no cache it
  is exit `2` with the fix.
- Exit codes: `0` everything found, `1` something was not found, `2` usage error
  or the engine could not be run.
- `--json` prints one document `{ok, godot_version, counts, notes, results[]}`;
  `--pretty` indents it.

### Limits

- **No descriptions.** `--doctool` emits empty `<description>` elements. This
  tool answers "what is the exact signature", not "what does it do".
- **Version-specific by design.** Everything is the API of the binary on this
  machine. That is the point: it cannot tell you about a method 4.7 does not have.
- The cached XML is ~7 MB per engine version.

## run_gdscript

The escape hatch. Reach for a dedicated op first — `configure_node`,
`resource_batch`, `run_scenario`, `check_project` — because those record what
they did. Use `run_gdscript` when the question is "what does the engine actually
return here", or when nothing else can express the call.

### Modes

Exactly one of `code`, `expression`, or `script_path` + `method`.

**`code`** — statements forming the body of `func run(tree: SceneTree) -> Variant`.
It may `await`, it may `return`, and the project's autoloads are registered as
global identifiers:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"var body := CharacterBody2D.new()\nbody.velocity = Vector2(120, 0)\nvar report := {\"speed\": body.velocity.length(), \"on_floor\": body.is_on_floor()}\nbody.free()\nreturn report"}'
```

```json
{"completed":true,"elapsed_ms":1,"mode":"code","ok":true,"result":{"on_floor":false,"speed":120.0},"result_type":"Dictionary"}
```

`await` works, and the SceneTree is live while it is suspended:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"await tree.create_timer(0.1).timeout\nreturn \"one tenth of a second later\""}'
```

```json
{"completed":true,"elapsed_ms":8,"mode":"code","ok":true,"result":"one tenth of a second later","result_type":"String"}
```

**`expression`** — one `Expression` string. No statements, no `var`, no `await`.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"expression":"Vector2(3, 4).length()"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"expression":"ProjectSettings.get_setting(\"physics/2d/default_gravity\")"}'
```

```json
{"completed":true,"elapsed_ms":1,"mode":"expression","ok":true,"result":5.0,"result_type":"float"}
{"completed":true,"elapsed_ms":1,"mode":"expression","ok":true,"result":980.0,"result_type":"float"}
```

An `Expression` has no scope of its own: an identifier it does not know is
treated as a property of a base instance that is not there, and fails with
`self can't be used`. Every engine singleton (`OS`, `Input`, `InputMap`,
`ProjectSettings`, `Time`, `ClassDB`, `RenderingServer`, …), every project
autoload, plus `tree` and `scene`, are therefore handed in by name. Anything
else — a `class_name`, a node path, a local variable — needs `code`, and the
failure message says so and lists what was available.

**`script_path` + `method`** — call one function of a project script.
`args` is a typed-JSON array (the same `{"__type": …}` values every other op
takes). `instantiate` defaults to auto: a `static func` is called on the script,
anything else on `script.new()`.

```bash
cat > /absolute/path/to/project/scripts/inventory.gd <<'GDSCRIPT'
extends Node

var slots: Dictionary = {}


static func stack_label(item: String, count: int) -> String:
	return "%s x%d" % [item, count]


func add(item: String, count: int) -> int:
	slots[item] = slots.get(item, 0) + count
	return slots[item]
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"script_path":"res://scripts/inventory.gd","method":"stack_label","args":["potion", 3]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"script_path":"res://scripts/inventory.gd","method":"add","args":["rock", 4]}'
```

```json
{"completed":true,"elapsed_ms":0,"mode":"script_path","ok":true,"result":"potion x3","result_type":"String"}
{"completed":true,"elapsed_ms":0,"mode":"script_path","ok":true,"result":4,"result_type":"int"}
```

`script.new()` on a Node script produces an **orphan node**: `_ready()` has not
run and `@onready` variables are `null`. When the node has to be alive, pass
`scene_path` and use `code` instead.

**`scene_path`** (optional, any mode) instantiates that scene under the root
first and hands it to `code` as `scene`, to `expression` as the input `scene`:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"scene_path":"scenes/existing_ui.tscn","code":"var label := scene.get_node(\"StatusLabel\") as Label\nreturn {\"text\": label.text, \"size\": label.size}"}'
```

```json
{"completed":true,"elapsed_ms":0,"mode":"code","ok":true,"result":{"size":{"__type":"Vector2","x":96.0,"y":23.0},"text":"Pending"},"result_type":"Dictionary"}
```

### Output

One JSON line: `{ok, mode, completed, result, result_type, elapsed_ms}`, plus
`prints` (everything the snippet printed), `warnings` (`push_warning`), and
`errors` when something went wrong. `result` is encoded by
`scripts/core/variant_codec.gd`, so a `Vector2` comes back as
`{"__type":"Vector2","x":…,"y":…}` — exactly the shape the other ops accept as
input. `max_depth` (default 4) caps how deep nested resources are encoded.

### It cannot report a crash as a success

A GDScript runtime error aborts only the function it happens in and hands the
caller a plain `null`. A naive runner therefore reports a crashed snippet as
`{"ok": true, "result": null}`. This op installs a `Logger` (`OS.add_logger`)
around the compile and the call, so every engine error becomes data:

<!-- replay: fails -->
```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"var hp = null\nhp.take_damage(5)\nreturn hp"}'
```

```text
[ERROR] run_gdscript: run() did not complete — 1 error(s) while running:
[ERROR]   code:2: Invalid call. Nonexistent function 'take_damage' in base 'Nil'.
{"completed":true,"elapsed_ms":0,"errors":[{"function":"_godot_skill_run","message":"Invalid call. Nonexistent function 'take_damage' in base 'Nil'.","text":"code:2: Invalid call. Nonexistent function 'take_damage' in base 'Nil'.","where":"code:2"}],"mode":"code","ok":false,"result":null,"result_type":"null"}
```

Exit code `1`. A parse error is reported the same way, numbered against **your**
snippet rather than the generated wrapper:

<!-- replay: fails -->
```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"var speed := 100\nspeed = speed.no_such_method()\nreturn speed"}'
```

```text
[ERROR] run_gdscript: code did not compile. Line numbers are 1-based in your `code`:
[ERROR]   code:2: Parse Error: Cannot find member "no_such_method" in base "int".   [speed = speed.no_such_method()]
[ERROR]   code:2: Parse Error: Function "no_such_method()" not found in base int.   [speed = speed.no_such_method()]
```

Note that GDScript catches a mistake on a *statically typed* value at compile
time (`var speed := 100` makes `speed` an `int`) and a mistake on an untyped
value only at runtime. Both come back as `code:<line>`.

`timeout_seconds` (default 10) aborts with exit `1` and
`"timed_out": true`. The watchdog is a SceneTree timer, so it fires even while
the snippet is suspended on an `await` — but a snippet spinning in a
`while true:` loop never yields to it, and that run has to be killed from
outside.

### Notes

- **Not a sandbox.** The project's autoloads run, the code can write files,
  delete things and call `OS`. It is a shell inside the engine.
- Indentation is copied from the snippet: tabs or spaces both work, and code
  that was pasted already indented is dedented before it is wrapped.
- A `Node` the snippet returns without parenting it is freed after the value is
  encoded, so the run does not end with "ObjectDB instances were leaked".
- Look the API up first: `scripts/docs/api_lookup.py CharacterBody2D.move_and_slide`
  costs 0.08 s and removes the reason most snippets fail.
