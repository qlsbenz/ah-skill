# Node Configuration Warnings And Physics Layers

Read this reference when a scene "looks right" but does nothing at runtime: the
player falls through the floor, an `AnimatedSprite2D` shows nothing, particles
sit still, a scroll view refuses to scroll, a 3D scene renders black.

In the Godot editor those are the **yellow triangles** in the scene tree, coming
from `Node::get_configuration_warnings()`. That method is **not bound outside the
editor** in 4.7 — verified:

```gdscript
CharacterBody2D.new().has_method("get_configuration_warnings")            # false
ClassDB.class_has_method("Node", "get_configuration_warnings", true)      # false
```

So no `--script` run, at any flag combination, can read a single one of them. A
headless agent therefore ships a player with no collision shape and gets a clean
`check_project`. `scripts/core/node_config_rules.gd` closes that hole: it
re-implements the high-signal subset as rules over the **instantiated** scene
tree, with the same trigger conditions and the same wording the engine uses.

## Running It

Node configuration warnings ride along on `check_project`'s instantiate pass, so
they cost nothing extra and are **on by default**:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  check_project '{"config_warnings": true, "physics_layers": true}'
```

```bash
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

One scene at a time, with its stored properties:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_scene '{"scene_path": "scenes/player.tscn", "include_properties": false, "config_warnings": true}'
```

Opting out: `check_project '{"config_warnings": false}'`,
`validate_project.py --no-config-warnings`, or `--no-physics-layers` for just the
layer survey. `{"instantiate": false}` / `--no-instantiate` turns both off
implicitly — the rules need a live tree — and says so with
`"config_warnings_enabled": false`.

## Two Severities, One Rule Table

| `severity` | Meaning | Where it shows up |
| --- | --- | --- |
| `warning` | Parity with an editor configuration warning. `message` is the engine's own wording. | Payload **and** one `WARNING:` line per finding, so `godot_log_parser.py` reports it (category `node_config`). Fails a run only under `--warnings-as-errors`. |
| `hint` | A heuristic this skill adds. | Payload only (`validate_project.py` → `node_config.hints`). Never printed as a `WARNING`, never fails a run. |

Each finding is `{scene, node_path, node_type, rule, severity, message, fix}`.
`node_path` uses the skill's convention — the scene root is always `root`, so
`root/Player/CollisionShape2D` pastes straight into the next `node_path`
parameter. **`fix` is a runnable dispatcher call**, not advice: copy it, run it,
re-run `check_project`, and the finding is gone. It is filled in against the
actual scene — a `*_wrong_parent` fix reparents onto a node of the right class
when the scene already has one and otherwise adds it in the same `scene_batch`,
and a `ScrollContainer` fix moves every current child into the new container.
The handful of fixes that need information only you have carry a visible
`<Placeholder>` (`joint_without_nodes`, `remote_transform_bad_path`,
`animation_tree_without_player`, and the hints that want one of your assets):
substitute before running. Everything without a `<` runs as printed.

### Payload

```json
{
  "config_warnings_enabled": true,
  "config_warning_count": 8,
  "config_hint_count": 2,
  "config_warnings": [
    {"scene": "res://scenes/level.tscn", "node_path": "root/Player", "node_type": "CharacterBody2D",
     "rule": "body_without_shape", "severity": "warning",
     "message": "This node has no shape, so it can't collide or interact with other objects.\nConsider adding a CollisionShape2D or CollisionPolygon2D as a child to define its shape.",
     "fix": "add_node '{\"scene_path\":\"res://scenes/level.tscn\",\"parent_node_path\":\"root/Player\",\"node_type\":\"CollisionShape2D\",\"node_name\":\"CollisionShape2D\",\"properties\":{\"shape\":{\"__resource_type\":\"RectangleShape2D\",\"properties\":{\"size\":{\"__type\":\"Vector2\",\"x\":32.0,\"y\":32.0}}}}}'"}
  ],
  "physics_layers": {"2d": {"layers": []}, "3d": {"layers": []},
                     "findings": [], "finding_count": 0, "truncated": false}
}
```

### The printed line

```
WARNING: [node_config:body_without_shape] res://scenes/level.tscn::root/Player: This node has no shape, so it can't collide or interact with other objects. Consider adding a CollisionShape2D or CollisionPolygon2D as a child to define its shape.
   fix: add_node '{"scene_path":"res://scenes/level.tscn", ...}'
```

`godot_log_parser.py` turns that into a diagnostic with `category` `node_config`,
`file` = the scene (there is no line number — the finding is about a node),
`rule`, `node_path`, and `suggested_fix` = the `fix:` continuation.

## Rule Table — warnings (editor parity)

| Rule | Fires when | Fix the finding hands you |
| --- | --- | --- |
| `body_without_shape` | A `CollisionObject2D/3D` (every `CharacterBody`, `RigidBody`, `StaticBody`, `Area`) whose **direct** children include no `CollisionShape*`/`CollisionPolygon*`. | `add_node` a `CollisionShape2D`/`CollisionShape3D` with an inline `RectangleShape2D`/`BoxShape3D` |
| `shape_without_resource` | A `CollisionShape2D/3D` with `shape == null` (the node exists, the shape resource was never made). | `configure_node` `shape` with an inline shape resource |
| `shape_wrong_parent` | A `CollisionShape*`/`CollisionPolygon*` whose parent is not a `CollisionObject`. Skipped when the node is a *scene root* — whoever instantiates it picks the parent. | `reparent_node` under a body/area |
| `collision_polygon_empty` | `CollisionPolygon2D/3D` with an empty `polygon`, or fewer than 3 points in `Solids` / 2 in `Segments`. | `configure_node` `polygon` |
| `shapecast_without_shape` | `ShapeCast2D/3D` with `shape == null`. | `configure_node` `shape` |
| `animated_sprite_without_frames` | `AnimatedSprite2D/3D` with no `SpriteFrames`, **or** whose `animation` names an animation the resource does not hold (the engine then raises `Animation 'x' doesn't exist.` and the node draws nothing). | `configure_node` an inline empty `SpriteFrames` (that is the warning's literal remedy and always runs); then `build_sprite_frames` with your real sheet to make it draw something. For the wrong-name case, `configure_node` `animation` to a name that exists — the message lists them |
| `particles_without_material` | `GPUParticles2D/3D` with `process_material == null`. | `configure_node` `process_material` with an inline `ParticleProcessMaterial` |
| `particles_without_draw_pass` | `GPUParticles3D` with no `draw_pass_*` mesh, `CPUParticles3D` with no `mesh`. | `configure_node` `draw_pass_1` / `mesh` |
| `path_follow_wrong_parent` | `PathFollow2D` not under a `Path2D` (same for 3D). Skipped on a scene root. | `reparent_node` |
| `parallax_layer_wrong_parent` | `ParallaxLayer` not under a `ParallaxBackground`. | `reparent_node` |
| `navigation_region_without_mesh` | `NavigationRegion2D` with no `NavigationPolygon` / `NavigationRegion3D` with no `NavigationMesh`. | `configure_node` an inline `NavigationPolygon`/`NavigationMesh`; bake real geometry into it with `resource_batch` `bake_navmesh` (see `automation_api.md`) |
| `navigation_agent_wrong_parent` | `NavigationAgent2D` not under a `Node2D` (3D: not under a `Node3D`). | `reparent_node` |
| `animation_tree_without_root` | `AnimationTree` with `tree_root == null`. | `build_animation_tree` |
| `world_environment_without_environment` | `WorldEnvironment` with neither `environment` nor `camera_attributes`. | `configure_node` `environment` |
| `world_environment_duplicate` | More than one `WorldEnvironment` in the scene's instantiated tree. | `remove_node` the extra one |
| `canvas_modulate_duplicate` | More than one **visible** `CanvasModulate` in the tree. | `configure_node` `visible: false` |
| `remote_transform_bad_path` | `RemoteTransform2D/3D` whose `remote_path` is empty or does not resolve to a `Node2D`/`Node3D`. Absolute `/root/...` paths are skipped (unverifiable statically). | `configure_node` `remote_path` |
| `light_occluder_without_polygon` | `LightOccluder2D` with no `occluder`, or one whose polygon is empty. | `configure_node` `occluder` / `indexed_properties` `occluder:polygon` |
| `point_light_without_texture` | `PointLight2D` with `texture == null`. | `configure_node` `texture` with an inline radial `GradientTexture2D` (swap in your own light cookie afterwards) |
| `scroll_container_child_count` | A `ScrollContainer` whose sortable child controls (non-internal, non-`top_level`, visible) are not exactly **one** — including zero. | one `scene_batch` that adds a `VBoxContainer` and reparents every current child into it |
| `subviewport_container_without_viewport` | `SubViewportContainer` with no `SubViewport` child. | `add_node` a `SubViewport` |
| `physics_body_scaled` | `RigidBody2D` with `scale != (1,1)`; `RigidBody3D` with `scale != (1,1,1)`; any `CollisionObject3D`, `CollisionShape3D` or `CollisionPolygon3D` with a **non-uniform** scale. | `configure_node` `scale` back to 1 and resize the shape resource instead |
| `joint_without_nodes` | `Joint2D/3D` whose `node_a`/`node_b` are empty, do not resolve to a `PhysicsBody`, or are the same body. The message is the engine's exact variant. | `configure_node` `node_a` / `node_b` |
| `vehicle_wheel_wrong_parent` | `VehicleWheel3D` not under a `VehicleBody3D`. | `reparent_node` |
| `multiplayer_synchronizer_without_config` | `MultiplayerSynchronizer` whose `root_path` is empty or unresolvable. | `configure_node` `root_path` |
| `multiplayer_spawner_bad_path` | `MultiplayerSpawner` whose `spawn_path` is empty or unresolvable. | `configure_node` `spawn_path` |

## Rule Table — hints (this skill's heuristics)

| Rule | Fires when | Why it is only a hint |
| --- | --- | --- |
| `sprite_without_texture` | `Sprite2D`/`Sprite3D` with no `texture`. | A placeholder whose art has not been drawn yet is a normal work-in-progress state. |
| `tilemap_layer_without_tileset` | `TileMapLayer` with no `TileSet`. | Same. |
| `gridmap_without_mesh_library` | `GridMap` with no `MeshLibrary`. | Same. |
| `audio_player_without_stream` | `AudioStreamPlayer`/`2D`/`3D` with no `stream`. | The stream is often assigned from a script. |
| `mesh_instance_without_mesh` | `MeshInstance3D` with `mesh == null`. Wording is the engine's. | The editor treats this as a real configuration warning; it ships as a hint here because assigning the mesh at runtime is common and a static pass cannot see it. |
| `animation_tree_without_player` | `AnimationTree` with no animation library of its own and an empty (deprecated) `anim_player`. | 4.7 removed the 4.0-era "Path to an AnimationPlayer …" editor warnings — `AnimationTree` is now an `AnimationMixer` — so there is no parity wording to mirror. |
| `scene_3d_without_camera` | The scene has visible `GeometryInstance3D` content and no `Camera3D`. | Suppressed for any scene another scene instantiates (a prop inherits the level's camera). |
| `scene_3d_without_light` | Visible 3D content, no visible `Light3D`, and no `WorldEnvironment` whose `Environment` provides ambient or sky light. | Same suppression. This is the "my 3D scene renders black" case. |
| `label_without_text` | `Label` or `Button` with empty `text` (a `Button` with an `icon` is fine). | A score label a script fills at runtime is normal; an empty button almost never is. |

`control_anchors_inside_container` is deliberately **not** implemented: the
engine's own trigger (`Control` with non-equal opposite anchors *and* a set size)
cannot be reproduced without the editor's size-tracking state, and every
approximation fires on ordinary container children. Use `ui_report` in a scenario
for layout questions instead.

## Instanced And Inherited Scenes

The pass walks the **instantiated** tree, so instanced sub-scenes are expanded
and the rules see exactly what the game sees. Each problem is reported **once**,
by the scene that defines it:

- A node is reported by the scene whose `SceneState` stores it. Nodes that only
  come from a base scene (an inherited `.tscn`) are left to the base.
- A node placed by `[node ... instance=ExtResource(...)]` is reported here only
  for the rules that depend on **where it was placed** (the `*_wrong_parent`
  family). Everything about its own state belongs to the sub-scene.
- A scene root is never reported by a `*_wrong_parent` rule: inside its own file
  it has no parent, and the scene that instantiates it is where that is decided.

The shape rules match the engine exactly, including the instanced case, because
they read `CollisionObject.get_shape_owners()` — the engine's own `shapes` map. A
`CollisionShape2D` registers itself there from `NOTIFICATION_PARENTED`, on its
**direct** parent only:

```
Body (CharacterBody2D)
└── ShapePart (instance of shape_part.tscn, root = CollisionShape2D)   -> counts, no warning
Body (CharacterBody2D)
└── Hitbox (instance of hitbox.tscn, root = Area2D)
    └── CollisionShape2D                                                -> does NOT count, warning
```

## Physics Layer / Mask Survey

`check_project '{"physics_layers": true}'` aggregates, across every instantiated
scene, who **occupies** each physics layer bit and who **scans** it:

- Occupants: `CollisionObject2D/3D` `collision_layer`; the `collision_layer` of
  every **TileSet physics layer** used by a `TileMapLayer` (so a tile floor is a
  real occupant); `GridMap.collision_layer` when it has a `MeshLibrary`;
  `CSGShape3D.collision_layer` when `use_collision` is on.
- Scanners: `collision_mask` of physics bodies (not `StaticBody`/`AnimatableBody`
  — they never query), of `Area`s with `monitoring` on, and of enabled
  `RayCast2D/3D` and `ShapeCast2D/3D`.

```json
"physics_layers": {
  "2d": {"layers": [
    {"bit": 1, "value": 1, "name": "world",
     "occupied_by": ["res://scenes/level.tscn::root/Ground"], "occupied_count": 1,
     "scanned_by": ["res://scenes/level.tscn::root/Player"], "scanned_count": 1}
  ]},
  "3d": {"layers": []},
  "findings": [], "finding_count": 0, "truncated": false
}
```

`name` comes from `layer_names/2d_physics/layer_N` in `project.godot` (set them
with `project_batch` `set_layer_name` — the report is far easier to read when
they exist). A bit appears only when something occupies it, scans it, or names
it. `occupied_by`/`scanned_by` hold up to 5 sample `scene::node_path` labels; the
counts are complete.

All four findings are **hints**, shaped
`{rule, severity, dimension, bit, layer_name, scene, node_path, message, fix}`:

| Finding | Meaning |
| --- | --- |
| `mask_targets_empty_layer` | A node's mask has a bit no object in the project occupies, so that query can never report a hit. The `fix` is the same `configure_node` call with the dead bits dropped. |
| `layer_never_scanned` | A bit has occupants but no scanners: those objects cannot be hit or detected by anything. Normal early on (nothing hunts the player yet) — information, not a defect. |
| `body_mask_zero` | A physics body / monitoring area / enabled cast with `collision_mask == 0`. A body with mask 0 falls through every floor. |
| `body_layer_zero` | A `PhysicsBody` with `collision_layer == 0`: nothing can collide with it or detect it. (Areas are exempt — layer 0 is a legitimate "detector only" pattern.) |

At most 25 findings per rule are listed; `finding_count` is the real total and
`truncated` says whether anything was dropped.

## Limits

- **Runtime changes are invisible.** A shape, texture, mesh, stream or
  `SpriteFrames` a script assigns in `_ready()` does not exist during a static
  instantiate pass, so the rule fires anyway. That is why every such rule that
  is not certain is a `hint`. Use a scenario run (`run_scenario.py`) to check the
  live tree.
- **`_ready()` never runs.** Instantiating executes the root script's `_init()`
  and the setters of stored properties, nothing else — exactly what the running
  game does when it instantiates the same scene.
- **Only the subset above.** The editor has many more warnings (skeletons, bones,
  `Camera3D` near/far sanity, importer notices). Anything not in the tables is
  not checked.
- **Wording is 4.7's.** Messages were taken from the 4.7 engine's own string
  table, so they match what the editor shows on this version; a different Godot
  version may word them differently.
- **A `.tscn` that cannot be instantiated is skipped.** `check_project` already
  fails it (`failed[]` + an `Invalid scene:` error); fix the hierarchy first.

## See Also

- `references/debugging.md` — the run → diagnose → fix loop and the log parser.
- `references/automation_api.md#check_project-and-the-instantiate-pass` — the
  operation's parameters.
- `references/tscn_format.md` — hierarchy mistakes the instantiate pass catches.
