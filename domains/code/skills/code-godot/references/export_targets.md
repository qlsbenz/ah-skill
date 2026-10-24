# Export Targets

Read this when the task is to package, run, or ship a build. Everything below
was executed on **Godot 4.7.stable** (macOS arm64, official export templates
4.7.stable) against a project created by `scripts/project/scaffold_project.py`.

The old advice in this file was "create the baseline preset through Godot
first" — i.e. in the editor's Project → Export dialog. A headless agent has no
dialog. `add_export_preset` replaces it.

## From Zero: Create A Preset Headlessly

Four commands take a project with no `export_presets.cfg` to a running build.
First make the project exportable: an export with no main scene builds fine and
then **hangs** when you run it, and on macOS the binary inside the bundle is
named after `application/config/name`, so both have to be right before anything
is packaged. The setting is `application/run/main_scene` — writing it as
`run/main_scene` puts a `[run]` section in `project.godot` that the engine
ignores, and the exported build then says `Can't run project: no main scene
defined in the project`:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[
    {"type":"set_setting","name":"application/run/main_scene","value":"res://scenes/main.tscn"},
    {"type":"set_setting","name":"application/config/name","value":"Game"}
  ]}'
```

Then write the preset — it also creates `../build/web/` beside the project:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_export_preset '{"platform": "web"}'
```

Then export it for real; preflight runs first and fails loudly:

<!-- replay: skip — export-templates (a real export needs the 4.7 web template installed) -->
```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "Web" /absolute/build/web/index.html
```

Then prove it serves with the headers a Godot build needs:

<!-- replay: skip — export-templates (reads the build the previous command writes) -->
```bash
python3 /absolute/path/to/godot/scripts/export/serve_web.py \
  /absolute/build/web --check --pretty
```

`add_export_preset` prints the exact command for the export step in its `next[]`.

| Param | Meaning |
| --- | --- |
| `platform` | **required** — `web`, `windows`, `linux`, `macos`, `android`, `ios`. Mapped to Godot's exact platform string (see the table below). |
| `name` | Preset name, and the name `export_project.py` takes. Default: the platform's conventional name. |
| `export_path` | Default `../build/<platform>/<artifact>` — *beside* the project, never inside it. A custom `name` gets its own `../build/<slug>/` so two presets of one platform cannot overwrite each other. Relative paths resolve from the project directory. |
| `runnable` | Default `true`, unless another preset of the same platform is already runnable. |
| `options` | Free-form export options merged over the verified default block. **Never key-checked** — anything Godot accepts goes through. |
| `overwrite` | Default `false`: an existing preset of that name is an error that lists every preset in the file. `true` rewrites it, keeping every key you did not name. |
| `dedicated_server` | `linux` only. See *Dedicated Server* below. |
| `export_filter` / `include_filter` / `exclude_filter` | `all_resources` (default) / `scenes` / `resources` / `customized` / `exclude`, plus comma-separated globs. |
| `custom_features` | Extra feature tags for `OS.has_feature`. |

Payload: `{ok, preset_index, name, platform, export_path, export_path_absolute,
created, updated, verified, prerequisites[], notes[], dedicated_server,
stripped_files, options{}, project_settings_changed[], presets[], next[]}`.

**The file is edited as text, not through `ConfigFile`.** Every other preset,
its index, its ordering and any key this skill does not know keep their exact
bytes. A preset a human authored in the editor — with a signing identity, a
provisioning profile, a per-file customisation map — survives untouched.

## Platform Strings And Verified Default Options

`platform=` in the file is not the word you pass to the op. On 4.x it is:

| `platform` param | `platform=` in the file | Default preset name | Default artifact | Proven by a real export here |
| --- | --- | --- | --- | --- |
| `web` | `Web` | `Web` | `../build/web/index.html` | yes |
| `windows` | `Windows Desktop` | `Windows Desktop` | `../build/windows/<Name>.exe` | yes |
| `linux` | `Linux` | `Linux` | `../build/linux/<name>.x86_64` | yes |
| `macos` | `macOS` | `macOS` | `../build/macos/<Name>.app` | yes |
| `android` | `Android` | `Android` | `../build/android/<name>.apk` | **no** — see below |
| `ios` | `iOS` | `iOS` | `../build/ios/<Name>.ipa` | **no** — see below |

`Linux/X11` is the **Godot 3** name. A 4.x preset carrying it exports nothing.

### Web — `variant/thread_support` defaults to **false**, on purpose

```
variant/extensions_support=false
variant/thread_support=false
html/export_icon=true
```

An export with the key absent and one with it explicitly `false` produce a
byte-identical `index.js` (279 815 bytes); `true` produces a different one
(314 653 bytes) and a different `.wasm`. So `false` is the engine default, and
this skill writes it explicitly because it is a decision, not an accident:

- A threaded build needs `SharedArrayBuffer`, which a browser only exposes to a
  **cross-origin isolated** document (`Cross-Origin-Opener-Policy: same-origin`
  **and** `Cross-Origin-Embedder-Policy: require-corp`).
- itch.io, GitHub Pages and most static hosts do not send those headers, so a
  threaded build is a blank page there. Single-threaded runs everywhere.
- Flip it to `true` only once the real host sends both headers.
  `serve_web.py` does, so a threaded build can still be tested locally.

Files a web export writes: `index.html`, `index.js`, `index.wasm`, `index.pck`,
`index.png`, `index.icon.png`, `index.apple-touch-icon.png`,
`index.audio.worklet.js`, `index.audio.position.worklet.js`. **All of them ship
together** — moving only the `.html` gives a blank page. A threaded build writes
*the same file names* on 4.7 (no separate `index.worker.js`), so the only way to
tell them apart from the outside is the loader: Emscripten's `PThread` runtime
appears in `index.js` of a threaded build and nowhere in a single-threaded one.
`serve_web.py` reports that as `threaded_build`.

Web does **not** need the ETC2/ASTC project setting (verified: exported clean
with it disabled).

### Windows — no rcedit, no wine needed

```
binary_format/architecture="x86_64"
```

A plain release export produced a valid `PE32+ executable (GUI) x86-64` plus a
sibling `.pck`, with zero warnings and no `rcedit` installed. `rcedit` is only
needed to stamp the icon and version resources into the `.exe`; without it the
build still runs, it just carries Godot's default icon. Set
`binary_format/embed_pck=true` for a single self-contained file.
`debug/export_console_wrapper` adds the `.console.exe` on debug builds.

### Linux — `Linux`, x86_64, pck beside the binary

```
binary_format/architecture="x86_64"
binary_format/embed_pck=false
```

Produced an `ELF 64-bit LSB executable, x86-64 ... for GNU/Linux 5.15.0` plus
`<name>.pck`. The templates directory also ships `arm64`, `arm32` and `x86_32`
variants, so `binary_format/architecture` can be any of those.

### macOS — universal only, ETC2/ASTC required, ad-hoc signing works

```
binary_format/architecture="universal"
application/bundle_identifier="com.example.<project>"
codesign/codesign=1
notarization/notarization=0
```

Four facts, each of which costs an hour to rediscover:

1. **The official 4.7 `macos.zip` contains only `godot_macos_release.universal`
   and `godot_macos_debug.universal`.** Asking for `x86_64` or `arm64` fails
   with `Requested template binary "godot_macos_release.x86_64" not found`.
2. **universal/arm64 needs `rendering/textures/vram_compression/import_etc2_astc
   = true`** (a *project* setting, not a preset option), or the export aborts
   with `Cannot export for universal or arm64 if ETC2 ASTC texture format is
   disabled`. Godot's default for that setting is `false`, so
   `add_export_preset` turns it on and reports it in `project_settings_changed`.
3. **`codesign/codesign=1` is built-in ad-hoc signing** — no Apple account, no
   certificate. The exported `.app` is `adhoc`-signed with the hardened runtime
   (`codesign -dv` → `flags=0x10002(adhoc,runtime)`) and runs on the machine
   that built it. Gatekeeper still blocks it after a download; that needs a
   Developer ID in `codesign/identity` plus notarization. Both the
   "notarization is disabled" and "using ad-hoc signature" lines are **warnings**
   at export time, not errors.
4. `application/bundle_identifier` is **required**: without it the export fails
   with `Invalid bundle identifier: Identifier is missing.` Segments may hold
   only letters, digits and hyphens, and may not start with a digit.

Output path `…/Name.app` writes an app *bundle directory*; `.zip` and `.dmg`
also work (`.dmg` only on a macOS host). Write the preset with that output path:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_export_preset '{"platform": "macos", "export_path": "../build/macos/Game.app"}'
```

Export it — cross-exporting from another OS works, only `.dmg` needs a macOS host:

<!-- replay: skip — export-templates (builds a real .app bundle) -->
```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "macOS" /absolute/build/macos/Game.app
```

The binary inside the bundle is `Contents/MacOS/<application/config/name>` — the
`Game` set at the top of this file, not the preset name or the `.app` name — and
it takes the normal engine flags:

<!-- replay: skip — export-templates host:darwin (runs the binary inside an exported .app) -->
```bash
/absolute/build/macos/Game.app/Contents/MacOS/Game --headless --quit-after 20
```

That is the cheapest possible "did the build actually run" check, and it is what
proved this preset block. It only returns because the project has an
`application/run/main_scene`: without one the exported binary never gets as far
as `--quit-after` and hangs until you kill it.

### Android — best known, NOT proven here

```
gradle_build/use_gradle_build=false
package/unique_name="com.example.<project>"
version/code=1
version/name="1.0"
```

`verified` is `false` in the payload and `prerequisites[]` lists what is missing:
an Android SDK and JDK 17 wired into the Godot **editor settings**
(`export/android/android_sdk_path`, `export/android/java_sdk_path`), a debug
keystore for `--mode debug`, a release keystore in the preset
(`keystore/release`, `keystore/release_user`, `keystore/release_password`) for
`--mode release`, `import_etc2_astc=true`, and a real
`application/config/icon` — a missing icon is an **error**
(`No project icon specified.`), not a warning, for this platform only.

What was actually observed on the reference machine, which happened to have all
of the above configured: `--mode debug` produced a signed 28 MB `.apk` (plus an
`.idsig`) straight from the prebuilt `android_debug.apk` template, with no
Gradle build; `--mode release` failed with
`WARNING: Code Signing: Could not find release keystore, unable to export.`
Both runs also errored on the missing project icon until one was set. That is
one machine's configuration, not a property of this skill — which is why the
payload says `verified: false`. Run `export_project.py --preflight-only` first.

### iOS — best known, NOT proven here

```
application/bundle_identifier="com.example.<project>"
application/app_store_team_id=""
application/short_version="1.0"
application/version="1.0"
```

Verified failure mode: with an empty team id the export aborts with
`App Store Team ID not specified.` before it reaches signing.
`export_project.py --preflight-only` reports that as an error with the
`add_export_preset … "options": {"application/app_store_team_id": "…"}` command
to fix it. The Godot export is only the first half — archiving and delivery
still happen in Xcode.

## Dedicated Server

`{"platform": "linux", "name": "Linux Server", "dedicated_server": true}`.

`dedicated_server=true` on its own **only adds the feature tag** — measured, the
`.pck` grew from 36 820 to 36 868 bytes. Texture stripping in 4.7 needs a
per-file map:

```
dedicated_server=true
export_filter="customized"
customized_files={
"res://art/big.png": "strip"
}
```

which took the same `.pck` from 36 820 to 2 432 bytes. `add_export_preset`
builds that map by scanning the project for `png jpg jpeg webp bmp tga svg exr
hdr ktx dds` and reports the count in `stripped_files`. Files not listed are
included normally. **The map is a snapshot**: art added later is not stripped
until the preset is regenerated with `"overwrite": true`.

There is no separate server template — run the normal Linux binary with
`--headless`, and branch on `OS.has_feature("dedicated_server")`.

## Running The Export (`export_project.py`)

```text
export_project.py PROJECT PRESET OUTPUT [--mode release|debug|pack|patch] [--preflight-only]
```

Validate the preset and the output path without exporting anything. In
`--mode pack` this needs no export templates at all — a `.pck` holds project
data, not an engine build — which makes it the one preflight that passes on a
bare CI runner:

```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "Web" /absolute/build/web/base.pck --mode pack --preflight-only
```

A release-mode preflight asks the stronger question — *would a real export work
here* — so it also requires the export templates for this exact engine build and
exits 1 with `Matching Godot export templates were not found` when they are
missing:

<!-- replay: skip — export-templates (a release preflight checks the installed templates) -->
```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "Web" /absolute/build/web/index.html --preflight-only
```

Write the base `.pck` a later patch is measured against:

```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "Web" /absolute/build/web/base.pck --mode pack
```

Then build a delta pack against it. Something must have changed since the base,
or the export fails with `Save PCK: No files or changes to export.` and exit 1:

<!-- replay: skip — export-templates (a patch export, verified only where the templates are installed) -->
```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{"output_path":"art/patch_marker.png","palette":{"w":"#ffffff"},"rows":["ww","ww"]}'
godot --headless --path /absolute/path/to/project --import
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project "Web" /absolute/build/web/update.pck \
  --mode patch --patches /absolute/build/web/base.pck
```

Preflight blocks the export and prints the fix on stderr as
`export preflight: …` / `export preflight fix: …`, and in the JSON under
`errors[]` / `fixes[]`. It catches:

- a preset that does not exist → lists every preset in the file **and** the
  `add_export_preset` command for the closest platform;
- no `export_presets.cfg` at all → the same command;
- missing export templates for this exact engine build → where to install them;
- macOS/Android/iOS with `import_etc2_astc` disabled → the `project_batch` call;
- iOS/visionOS with no `application/app_store_team_id`;
- patch mode without a base artifact, a base artifact that does not exist,
  an unusual output extension, an output path inside the project tree.

`--mode pack` writes only the `.pck` (13 532 bytes for the platformer used
here) and needs no export template. `--mode patch` needs a base artifact from
the same project and preset, and fails loudly — exit 1, `Save PCK: No files or
changes to export.` — when nothing changed since that base; with one changed
file it writes a delta pack (192 bytes).

Two behaviours worth knowing:

- **Godot does not create the output directory.** A missing one fails with
  `Prepare Template: The given export path doesn't exist.` `export_project.py`
  creates the parent of its own output path; `add_export_preset` creates the
  directory its `export_path` points at.
- **Godot has exited 0 while producing nothing.** The wrapper checks that the
  artifact exists and is non-empty (a non-empty *directory* counts, for `.app`)
  and turns a silent no-op into exit 1.

Run with no output argument (`godot --headless --path P --export-release "Web"`)
and Godot uses the preset's own `export_path`, resolved from the project
directory — but it still will not create the directory.

## Serving A Web Build (`serve_web.py`)

<!-- replay: skip — interactive (serves until the reader presses Ctrl+C) -->
```bash
python3 /absolute/path/to/godot/scripts/export/serve_web.py /absolute/build/web
```

<!-- replay: skip — export-templates (needs a real web export under /absolute/build/web) -->
```bash
python3 /absolute/path/to/godot/scripts/export/serve_web.py /absolute/build/web --check --pretty
```

`python3 -m http.server` is not enough: it sends no COOP/COEP and has no MIME
type for `.wasm` on most hosts, which the browser rejects with
*"Incorrect response MIME type. Expected 'application/wasm'"*. This sends

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: cross-origin
Cache-Control: no-store, no-cache, must-revalidate, max-age=0
```

plus `application/wasm` for `.wasm` and `application/octet-stream` for `.pck`,
and binds `127.0.0.1` by default.

`--check` is the headless-agent mode: it starts the server, requests
`index.html`, the `.wasm` and the `.pck` over loopback, asserts the status codes,
content types, isolation headers and that a missing file is a 404, then prints
one JSON document (`{ok, url, port, isolation, cross_origin_isolated,
threaded_build, files{}, checks[], failed[]}`) and exits 0/1. A directory that
is not a web export exits 2 and names the two commands that make one.
`--no-isolation` reproduces what a plain static host does; `--port 0` picks a
free port.

Verified in a real browser against the `--check`ed build: `crossOriginIsolated`
is `true`, the engine logs
`OpenGL API OpenGL ES 3.0 (WebGL 2.0 …) - Compatibility`, and the canvas renders
the game (checked for both a scaffolded `pixel2d` project and a real platformer).

**A web build always runs the Compatibility renderer, whatever the project
says.** 4.7 ships `rendering/renderer/rendering_method.web =
"gl_compatibility"` as a built-in per-platform override, so a `forward_plus`
project exports and renders in the browser without any change — it just
silently switches backend, and Forward+-only features (SDFGI, volumetric fog,
SSIL, SSR) are gone from that build. If the web build is the one that matters,
set `rendering/renderer/rendering_method = "gl_compatibility"` for the desktop
build too so what you test is what ships. `scaffold_project.py` does that for
the `pixel2d`, `hd2d` and `ui` presets and leaves `3d` on Forward+.

`http.server` does not answer Range requests; Godot's loader uses `fetch()` for
the whole file, so that is fine for a local check but is not a production host.

## Checklist Before Shipping

- Inspect `export_presets.cfg` first and reuse the preset names already there —
  `export_project.py PROJECT ANYNAME OUT --preflight-only` prints them all.
- Export templates must match the engine build exactly (`godot --version`).
  `--mode pack` / `--mode patch` need none.
- Prefer `--mode debug` for the first smoke test; the debug template keeps the
  error messages that the release template strips.
- Keep keystores, certificates, provisioning profiles and passwords out of git.
  On Godot 4 the **script encryption key lives in
  `res://.godot/export_credentials.cfg`**, not in `export_presets.cfg`, so the
  preset file itself is safe to commit — and `scaffold_project.py` deliberately
  does not `.gitignore` it.
- Verify app name, bundle/package identifier, icon, version, orientation and
  feature-tag overrides per target before exporting.

## Feature Tags To Audit

- Desktop/mobile: `android`, `ios`, `mobile`, `windows`, `macos`, `linux`,
  `linuxbsd`, `pc`
- Web: `web`, `web_android`, `web_ios`
- Server: `dedicated_server`
- Build kind: `editor`, `template`, `debug`, `release`
- Measured on this macOS host: `macos` → true, `pc` → true, `debug` → true,
  `editor` → true; `osx` (the Godot 3 name) and `desktop` are **not** tags.
  The platform tag is `OS.get_name().to_lower()`, so it is `macos`, not `osx`.
- Before changing platform-specific logic, search for `OS.has_feature`, the
  per-feature overrides in `project.godot` (`setting.windows=…`) and
  `custom_features` in `export_presets.cfg`.

## visionOS

Treat visionOS as the iOS path: macOS host, Xcode, Apple signing, bundle IDs,
capabilities, device/simulator architectures. Reuse an existing preset rather
than inferring signing assets from iOS. `add_export_preset` does not write one.
