class_name GodotSkillProcessImage
extends RefCounted

# An ordered pipeline of pixel operations over one image, a list of images, or a
# directory of them. Written for the other half of the art problem: cleaning up
# art that came out of an image generator (soft edges, a baked background,
# thousands of colours, off-grid "pixels") until it is real pixel art, and
# packing or slicing frame sheets for build_sprite_frames.
#
# The pipeline is a list of images, not one image: most operations map over every
# image, `pack_frames` folds them into one sheet, and `split_sheet` expands one
# sheet into many frames. That is why a single call can take a directory and
# write one sheet, or take one sheet and write a directory.
#
# Nothing is written until every operation of every image has succeeded, so a
# failure halfway through leaves no partial outputs and no half-processed file.
#
# Operation entries ARE parameters (the dispatcher derives the accepted key set
# from every get/has call with a string literal in it), so their keys are spelled
# out the ordinary way. Result dictionaries go through _field() and direct
# indexing instead, so their keys never become parameters.

var utils_script = preload("../core/utils.gd")
var describe_script = preload("../core/image_describe.gd")
var palettes_script = preload("../core/palettes.gd")

const OPERATION_TYPES := ["trim", "crop", "resize", "pad", "flip_h", "flip_v", "rotate90",
    "alpha_threshold", "replace_color", "remove_background", "quantize", "pixelate", "outline",
    "pack_frames", "split_sheet", "tile", "nine_patch_margins"]
const INPUT_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "exr", "hdr"]
const OUTPUT_EXTENSIONS := ["png", "webp"]
const FILTERS := {
    "nearest": Image.INTERPOLATE_NEAREST,
    "bilinear": Image.INTERPOLATE_BILINEAR,
    "cubic": Image.INTERPOLATE_CUBIC,
    "trilinear": Image.INTERPOLATE_TRILINEAR,
    "lanczos": Image.INTERPOLATE_LANCZOS
}
const ANCHORS := ["center", "top_left", "top", "top_right", "left", "right", "bottom_left", "bottom", "bottom_right"]
const LAYOUTS := ["horizontal", "vertical", "grid"]
const PIXELATE_MODES := ["average", "mode", "nearest"]
# Colour counting is exact and therefore linear in pixels; skip it per step on
# images bigger than this so a 4K source does not pay for it on every operation.
const COUNT_COLORS_MAX_AREA := 262144
# Per-axis samples inside one pixelate cell. A cell bigger than this is sampled
# on a grid instead of averaged in full: the answer moves by less than a byte and
# a 4096x4096 source stops costing 16 million reads.
const PIXELATE_CELL_SAMPLES := 16


func execute(params: Dictionary) -> void:
    # image_describe.gd is preloaded for the final read-back, which makes its own
    # option keys look like parameters here. compare_to is the one that would
    # otherwise be accepted and silently ignored, so say where it lives instead.
    if params.has("compare_to"):
        utils_script.log_error(
            "process_image does not diff images. Write the file, then compare it: inspect_image '{\"image_path\": \"…\", \"compare_to\": \"…\", \"expect\": {\"max_diff_ratio\": 0}}'.")
        return

    var operations: Array = _collect_operations(params)
    if operations.is_empty():
        return

    var inputs: Array = _collect_inputs(params)
    if inputs.is_empty():
        return

    var frames: Array = []
    for path in inputs:
        var image := _load_image(str(path))
        if image == null:
            return
        frames.append({"name": str(path).get_file().get_basename(), "image": image})

    var steps: Array = []
    var grid: Variant = null
    for index in range(operations.size()):
        var operation: Dictionary = operations[index]
        var context := "process_image.operations[%d]" % index
        var outcome := _apply_operation(frames, operation, context)
        if outcome.is_empty():
            return
        frames = _field(outcome, "frames", [])
        var step := {
            "index": index,
            "type": str(operation.get("type", "")).strip_edges().to_lower(),
            "images": frames.size()
        }
        if not frames.is_empty():
            var first: Image = _field(frames[0], "image", null)
            step["width"] = first.get_width()
            step["height"] = first.get_height()
            if first.get_width() * first.get_height() <= COUNT_COLORS_MAX_AREA:
                step["unique_colors"] = (palettes_script.unique_colors(first) as Dictionary).size()
        var detail: Variant = _field(outcome, "detail", null)
        if detail is Dictionary:
            step["detail"] = detail
            var lifted: Variant = _field(detail, "grid", null)
            if lifted != null:
                grid = lifted
        steps.append(step)

    if frames.is_empty():
        utils_script.log_error("process_image ended with no images; the last operation consumed everything. Nothing was written.")
        return

    var targets := _resolve_targets(params, frames)
    if targets.is_empty():
        return
    if not _check_writable(params, targets):
        return

    var outputs: Array = []
    for index in range(targets.size()):
        var path := str(targets[index])
        var image: Image = _field(frames[index], "image", null)
        if not _write_image(image, path):
            return
        var entry := {"path": path, "width": image.get_width(), "height": image.get_height()}
        if image.get_width() * image.get_height() <= COUNT_COLORS_MAX_AREA:
            entry["unique_colors"] = (palettes_script.unique_colors(image) as Dictionary).size()
        outputs.append(entry)

    var payload := {
        "ok": true,
        "input_paths": inputs,
        "input_count": inputs.size(),
        "outputs": outputs,
        "output_count": outputs.size(),
        "output_path": str(targets[0]),
        "needs_import": true,
        "steps": steps
    }
    if grid != null:
        payload["grid"] = grid
    if bool(params.get("describe", true)):
        var final_image: Image = _field(frames[0], "image", null)
        var options := {
            "ascii": bool(params.get("ascii", true)),
            "ascii_color": bool(params.get("ascii_color", false)),
            "ascii_width": int(params.get("ascii_width", clampi(final_image.get_width(), 4, 120))),
            "max_unique": int(params.get("max_unique", 4096)),
            "background_tolerance": float(params.get("background_tolerance", 0.0))
        }
        var described: Dictionary = describe_script.describe(final_image, options)
        for moved in ["ascii", "ascii_color"]:
            if described.has(moved):
                payload[moved] = described[moved]
                described.erase(moved)
        payload["summary"] = described
        payload["described_path"] = str(targets[0])
    print(JSON.stringify(payload))


# --- inputs and outputs ------------------------------------------------------

func _collect_operations(params: Dictionary) -> Array:
    var raw: Variant = params.get("operations", null)
    if raw == null:
        utils_script.log_error(
            "process_image requires operations — an ordered array like [{\"type\": \"trim\"}, {\"type\": \"pixelate\", \"target_width\": 32}]. "
            + "Supported types: " + ", ".join(OPERATION_TYPES) + ". Run: help '{\"op\":\"process_image\"}'.")
        return []
    if not (raw is Array) or (raw as Array).is_empty():
        utils_script.log_error("process_image.operations must be a non-empty array of {\"type\": ...} objects; supported types: " + ", ".join(OPERATION_TYPES) + ".")
        return []
    var operations: Array = []
    var entries: Array = raw
    for index in range(entries.size()):
        if not (entries[index] is Dictionary):
            utils_script.log_error("process_image.operations[%d] must be an object with a \"type\" key (one of %s)." % [index, ", ".join(OPERATION_TYPES)])
            return []
        var entry: Dictionary = entries[index]
        var type_name := str(entry.get("type", "")).strip_edges().to_lower()
        if type_name.is_empty():
            utils_script.log_error("process_image.operations[%d] needs a \"type\": one of %s." % [index, ", ".join(OPERATION_TYPES)])
            return []
        if not (type_name in OPERATION_TYPES):
            var message := "process_image.operations[%d] has unknown type \"%s\"" % [index, type_name]
            var near: PackedStringArray = utils_script.nearest_names(type_name, OPERATION_TYPES)
            if not near.is_empty():
                message += " (did you mean " + ", ".join(near) + "?)"
            utils_script.log_error(message + ". Supported operation types: " + ", ".join(OPERATION_TYPES) + ".")
            return []
        operations.append(entry)
    return operations


func _collect_inputs(params: Dictionary) -> Array:
    if params.has("input_paths"):
        var raw: Variant = params.get("input_paths", [])
        if not (raw is Array) or (raw as Array).is_empty():
            utils_script.log_error("process_image.input_paths must be a non-empty array of image files or directories.")
            return []
        var found: Array = []
        for item in (raw as Array):
            var path := _resolve_path(item)
            if path.is_empty():
                utils_script.log_error("process_image.input_paths entries cannot be empty.")
                return []
            if _is_directory(path):
                var listed := _images_in_directory(path)
                if listed.is_empty():
                    utils_script.log_error("No images in directory %s (looked for %s)." % [path, ", ".join(INPUT_EXTENSIONS)])
                    return []
                found.append_array(listed)
            else:
                found.append(path)
        return found

    var single := _resolve_path(params.get("input_path", ""))
    if single.is_empty():
        utils_script.log_error(
            "process_image requires input_path (one image) or input_paths (a list of files, or a directory of frames).")
        return []
    if _is_directory(single):
        utils_script.log_error("input_path %s is a directory; pass it as input_paths: [\"%s\"] to process every image in it." % [single, single])
        return []
    return [single]


func _images_in_directory(path: String) -> Array:
    var directory := DirAccess.open(path)
    if directory == null:
        utils_script.log_error("Could not open directory: " + path)
        return []
    var files: Array = []
    for file_name in directory.get_files():
        if str(file_name).get_extension().to_lower() in INPUT_EXTENSIONS:
            files.append(path.path_join(str(file_name)))
    files.sort_custom(func(left: String, right: String) -> bool:
        return left.get_file().naturalnocasecmp_to(right.get_file()) < 0
    )
    return files


func _load_image(path: String) -> Image:
    var extension := path.get_extension().to_lower()
    if not (extension in INPUT_EXTENSIONS):
        utils_script.log_error("process_image cannot read \"%s\": unsupported extension \"%s\" (supported: %s)." % [
            path, extension, ", ".join(INPUT_EXTENSIONS)])
        return null
    var absolute := ProjectSettings.globalize_path(path)
    if not FileAccess.file_exists(absolute):
        utils_script.log_error("Image file does not exist: %s (project-relative paths resolve against res://; pass an absolute path for files outside the project)." % path)
        return null
    var image := Image.load_from_file(absolute)
    if image == null or image.is_empty():
        utils_script.log_error("Failed to read image data from %s; the file may be truncated or not an image." % path)
        return null
    var converted: Image = palettes_script.to_rgba8(image)
    if converted == null:
        utils_script.log_error("%s is VRAM-compressed and could not be decompressed; re-export it as a plain PNG." % path)
        return null
    return converted


func _resolve_targets(params: Dictionary, frames: Array) -> Array:
    var has_dir := params.has("output_dir")
    var has_path := params.has("output_path")
    if not has_dir and not has_path:
        utils_script.log_error(
            "process_image requires output_path (one image) or output_dir (one file per resulting image). The pipeline produced %d image(s)."
            % frames.size())
        return []
    if frames.size() > 1 and not has_dir:
        utils_script.log_error(
            ("process_image produced %d images but only output_path was given. Pass output_dir to write them all, "
            + "or end the pipeline with {\"type\": \"pack_frames\"} to fold them into one sheet.") % frames.size())
        return []

    var suffix := str(params.get("suffix", ""))
    if has_dir:
        var directory := _resolve_path(params.get("output_dir", ""))
        if directory.is_empty():
            utils_script.log_error("process_image.output_dir is empty; pass a project-relative or absolute directory.")
            return []
        var targets: Array = []
        var used := {}
        for frame in frames:
            var base := str(_field(frame, "name", "image")) + suffix + ".png"
            if used.has(base):
                utils_script.log_error(
                    "process_image would write %s twice (two inputs share the name \"%s\"). Rename one, or process them in separate calls."
                    % [base, str(_field(frame, "name", ""))])
                return []
            used[base] = true
            targets.append(directory.trim_suffix("/") + "/" + base)
        return targets

    var path := _resolve_path(params.get("output_path", ""))
    if path.is_empty():
        utils_script.log_error("process_image.output_path is empty; pass the .png to write.")
        return []
    var extension := path.get_extension().to_lower()
    if not (extension in OUTPUT_EXTENSIONS):
        utils_script.log_error("process_image output_path must end in .%s; got \"%s\" (%s)." % [
            "/.".join(PackedStringArray(OUTPUT_EXTENSIONS)), extension, path])
        return []
    return [path]


func _check_writable(params: Dictionary, targets: Array) -> bool:
    # Every target is checked before the first byte is written, so an existing
    # file at the end of a batch cannot leave half the batch on disk.
    if bool(params.get("overwrite", true)):
        return true
    for path in targets:
        if FileAccess.file_exists(ProjectSettings.globalize_path(str(path))):
            utils_script.log_error(
                "process_image refuses to replace %s because overwrite is false. Delete it, pick another output, or pass \"overwrite\": true — nothing was written."
                % str(path))
            return false
    return true


func _write_image(image: Image, path: String) -> bool:
    var absolute := ProjectSettings.globalize_path(path)
    var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
    if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
        utils_script.log_error("process_image could not create the output directory %s: %s" % [
            absolute.get_base_dir(), error_string(directory_error)])
        return false
    var save_error := OK
    if path.get_extension().to_lower() == "webp":
        save_error = image.save_webp(absolute, false)
    else:
        save_error = image.save_png(absolute)
    if save_error != OK:
        utils_script.log_error("process_image could not write %s: %s" % [path, error_string(save_error)])
        return false
    return true


# --- operation dispatch ------------------------------------------------------

func _apply_operation(frames: Array, operation: Dictionary, context: String) -> Dictionary:
    var type_name := str(operation.get("type", "")).strip_edges().to_lower()

    if type_name == "pack_frames":
        return _operation_pack(frames, operation, context)
    if type_name == "split_sheet":
        return _operation_split(frames, operation, context)

    var out_frames: Array = []
    var detail: Variant = null
    for frame in frames:
        var image: Image = _field(frame, "image", null)
        var result := _apply_single(image, operation, type_name, context)
        if result.is_empty():
            return {}
        out_frames.append({"name": str(_field(frame, "name", "image")), "image": _field(result, "image", null)})
        if detail == null and _field(result, "detail", null) != null:
            detail = _field(result, "detail", null)
    var outcome := {"frames": out_frames}
    if detail != null:
        outcome["detail"] = detail
    return outcome


func _apply_single(image: Image, operation: Dictionary, type_name: String, context: String) -> Dictionary:
    match type_name:
        "trim":
            return _operation_trim(image, operation, context)
        "crop":
            return _operation_crop(image, operation, context)
        "resize":
            return _operation_resize(image, operation, context)
        "pad":
            return _operation_pad(image, operation, context)
        "flip_h":
            var flipped_h := _copy(image)
            flipped_h.flip_x()
            return {"image": flipped_h}
        "flip_v":
            var flipped_v := _copy(image)
            flipped_v.flip_y()
            return {"image": flipped_v}
        "rotate90":
            return _operation_rotate90(image, operation, context)
        "alpha_threshold":
            return _operation_alpha_threshold(image, operation, context)
        "replace_color":
            return _operation_replace_color(image, operation, context)
        "remove_background":
            return _operation_remove_background(image, operation, context)
        "quantize":
            return _operation_quantize(image, operation, context)
        "pixelate":
            return _operation_pixelate(image, operation, context)
        "outline":
            return _operation_outline(image, operation, context)
        "tile":
            return _operation_tile(image, operation, context)
        "nine_patch_margins":
            return _operation_nine_patch(image, operation, context)
    utils_script.log_error("%s: operation \"%s\" is not implemented." % [context, type_name])
    return {}


# --- operations --------------------------------------------------------------

func _operation_trim(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var padding := int(operation.get("padding", 0))
    if padding < 0:
        utils_script.log_error("%s.padding must be 0 or more; got %d." % [context, padding])
        return {}
    var rect := Rect2i()
    if operation.has("color"):
        var background: Variant = palettes_script.parse_color(operation.get("color", null))
        if not (background is Color):
            utils_script.log_error("%s.color is not a colour: %s. Omit it to trim transparent edges, or pass the flat background colour." % [
                context, JSON.stringify(operation.get("color", null))])
            return {}
        rect = _content_rect(image, background, float(operation.get("tolerance", 0.0)))
    else:
        rect = image.get_used_rect()
    if rect.size.x <= 0 or rect.size.y <= 0:
        utils_script.log_error(
            "%s found nothing to keep: every pixel is transparent (or matches the background colour), so trimming would delete the image. Check the input."
            % context)
        return {}
    var trimmed := image.get_region(rect)
    if padding > 0:
        trimmed = _padded(trimmed, trimmed.get_width() + padding * 2, trimmed.get_height() + padding * 2,
            "center", Color(0, 0, 0, 0))
    return {"image": trimmed, "detail": {"content_rect": {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}}}


func _operation_crop(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var x := int(operation.get("x", 0))
    var y := int(operation.get("y", 0))
    var width := int(operation.get("width", image.get_width() - x))
    var height := int(operation.get("height", image.get_height() - y))
    if width <= 0 or height <= 0:
        utils_script.log_error("%s needs width and height greater than 0; got %dx%d." % [context, width, height])
        return {}
    var rect := Rect2i(x, y, width, height).intersection(Rect2i(0, 0, image.get_width(), image.get_height()))
    if rect.size.x <= 0 or rect.size.y <= 0:
        utils_script.log_error("%s: the crop rect (%d, %d) %dx%d does not overlap the %dx%d image." % [
            context, x, y, width, height, image.get_width(), image.get_height()])
        return {}
    return {"image": image.get_region(rect)}


func _operation_resize(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var filter_name := str(operation.get("filter", "nearest")).strip_edges().to_lower()
    if not FILTERS.has(filter_name):
        utils_script.log_error("%s.filter must be one of %s; got \"%s\". Pixel art wants \"nearest\"." % [
            context, ", ".join(PackedStringArray(FILTERS.keys())), filter_name])
        return {}
    var width := image.get_width()
    var height := image.get_height()
    if operation.has("scale"):
        var factor := float(operation.get("scale", 1.0))
        if factor <= 0.0:
            utils_script.log_error("%s.scale must be greater than 0; got %s." % [context, str(factor)])
            return {}
        width = maxi(1, int(round(float(width) * factor)))
        height = maxi(1, int(round(float(height) * factor)))
    else:
        var want_width := int(operation.get("width", 0))
        var want_height := int(operation.get("height", 0))
        if want_width <= 0 and want_height <= 0:
            utils_script.log_error("%s needs width, height, or scale." % context)
            return {}
        if want_width > 0 and want_height > 0:
            width = want_width
            height = want_height
        elif want_width > 0:
            width = want_width
            height = maxi(1, int(round(float(image.get_height()) * float(want_width) / float(image.get_width()))))
        else:
            height = want_height
            width = maxi(1, int(round(float(image.get_width()) * float(want_height) / float(image.get_height()))))
    var resized := _copy(image)
    resized.resize(width, height, FILTERS[filter_name])
    return {"image": resized}


func _operation_pad(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var anchor := str(operation.get("anchor", "center")).strip_edges().to_lower()
    if not (anchor in ANCHORS):
        utils_script.log_error("%s.anchor must be one of %s; got \"%s\"." % [context, ", ".join(ANCHORS), anchor])
        return {}
    var color: Variant = palettes_script.parse_color(operation.get("color", null))
    if not (color is Color):
        utils_script.log_error("%s.color is not a colour: %s. Omit it for transparent padding." % [
            context, JSON.stringify(operation.get("color", null))])
        return {}
    var width := image.get_width()
    var height := image.get_height()
    if operation.has("multiple"):
        var multiple := int(operation.get("multiple", 0))
        if multiple <= 0:
            utils_script.log_error("%s.multiple must be 1 or more (pad up to a multiple of N, e.g. 16); got %d." % [context, multiple])
            return {}
        width = int(ceil(float(width) / float(multiple))) * multiple
        height = int(ceil(float(height) / float(multiple))) * multiple
    else:
        width = int(operation.get("width", width))
        height = int(operation.get("height", height))
    if width < image.get_width() or height < image.get_height():
        utils_script.log_error(
            "%s cannot pad %dx%d down to %dx%d — padding only grows a canvas. Use crop or resize to make it smaller."
            % [context, image.get_width(), image.get_height(), width, height])
        return {}
    return {"image": _padded(image, width, height, anchor, color)}


func _operation_rotate90(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var turns := int(operation.get("turns", 1))
    if turns < 1 or turns > 3:
        utils_script.log_error("%s.turns must be 1, 2 or 3 quarter-turns clockwise; got %d." % [context, turns])
        return {}
    var rotated := _copy(image)
    for _step in range(turns):
        rotated.rotate_90(CLOCKWISE)
    return {"image": rotated}


func _operation_alpha_threshold(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var threshold := clampf(float(operation.get("threshold", 0.5)), 0.0, 1.0)
    var cutoff := int(round(threshold * 255.0))
    var data := image.get_data()
    var out := data.duplicate()
    var count := image.get_width() * image.get_height()
    var opaque := 0
    for index in range(count):
        var base := index * 4 + 3
        if data[base] >= cutoff and cutoff > 0:
            out[base] = 255
            opaque += 1
        elif cutoff == 0 and data[base] > 0:
            out[base] = 255
            opaque += 1
        else:
            out[base] = 0
    var _unused := context
    return {
        "image": palettes_script.image_from_bytes(image.get_width(), image.get_height(), out),
        "detail": {"opaque_pixels": opaque, "cutoff": cutoff}
    }


func _operation_replace_color(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var from_color: Variant = palettes_script.parse_color(operation.get("from", null))
    if not (from_color is Color) or not operation.has("from"):
        utils_script.log_error("%s.from must be the colour to replace, e.g. \"#00ff00\"." % context)
        return {}
    var to_color: Variant = palettes_script.parse_color(operation.get("to", null))
    if not (to_color is Color):
        utils_script.log_error("%s.to must be a colour (or null for transparent); got %s." % [
            context, JSON.stringify(operation.get("to", null))])
        return {}
    var tolerance := clampf(float(operation.get("tolerance", 0.0)), 0.0, 1.0)
    var cutoff := int(round(tolerance * 255.0))
    var source_bytes: PackedByteArray = palettes_script.color_bytes(from_color)
    var target_bytes: PackedByteArray = palettes_script.color_bytes(to_color)
    var data := image.get_data()
    var out := data.duplicate()
    var replaced := 0
    for index in range(image.get_width() * image.get_height()):
        var base := index * 4
        # All four channels, so "#ff0000" means opaque red and leaves a
        # half-transparent red edge alone; widen with tolerance to catch it.
        if not _within(data, base, source_bytes, cutoff):
            continue
        out[base] = target_bytes[0]
        out[base + 1] = target_bytes[1]
        out[base + 2] = target_bytes[2]
        out[base + 3] = target_bytes[3]
        replaced += 1
    return {
        "image": palettes_script.image_from_bytes(image.get_width(), image.get_height(), out),
        "detail": {"replaced_pixels": replaced}
    }


func _operation_remove_background(image: Image, operation: Dictionary, context: String) -> Dictionary:
    # Flood fill inwards from the corners, so a background colour that also
    # appears inside the subject (white eyes on a white background) survives.
    var tolerance := clampf(float(operation.get("tolerance", 0.08)), 0.0, 1.0)
    var cutoff := int(round(tolerance * 255.0))
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var out := data.duplicate()

    var seeds := PackedInt32Array()
    if operation.has("color"):
        var wanted: Variant = palettes_script.parse_color(operation.get("color", null))
        if not (wanted is Color):
            utils_script.log_error("%s.color is not a colour: %s. Omit it to sample the corners." % [
                context, JSON.stringify(operation.get("color", null))])
            return {}
        var wanted_bytes: PackedByteArray = palettes_script.color_bytes(wanted)
        for index in range(width * height):
            if _within(data, index * 4, wanted_bytes, cutoff):
                seeds.append(index)
    else:
        for corner in [0, width - 1, (height - 1) * width, height * width - 1]:
            seeds.append(corner)

    var visited := PackedByteArray()
    visited.resize(width * height)
    visited.fill(0)
    var stack := PackedInt32Array()
    var samples: Array = []
    for seed_index in seeds:
        if visited[seed_index] == 1:
            continue
        samples.append(_pixel_bytes(data, seed_index * 4))
        stack.append(seed_index)
        visited[seed_index] = 1
    var cleared := 0
    while not stack.is_empty():
        # Annotated rather than inferred: a PackedInt32Array read is an int and
        # Godot infers it fine, but lint_project.py's infer_subscript rule reads
        # it as an untyped Array (reported to WP3).
        var index: int = stack[stack.size() - 1]
        stack.remove_at(stack.size() - 1)
        var base := index * 4
        var matched := false
        for sample in samples:
            if _within(data, base, sample, cutoff):
                matched = true
                break
        if not matched:
            continue
        # A pixel that was already transparent is not "cleared": counting it
        # would let a call that changed nothing look like it worked.
        if data[base + 3] != 0:
            cleared += 1
        out[base + 3] = 0
        var x := index % width
        var y := int(float(index) / float(width))
        for offset in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
            var nx: int = x + int(offset[0])
            var ny: int = y + int(offset[1])
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            var neighbor := ny * width + nx
            if visited[neighbor] == 1:
                continue
            visited[neighbor] = 1
            stack.append(neighbor)
    if cleared == 0:
        utils_script.log_error(
            ("%s made nothing transparent: either the background is already transparent, or the corner pixels differ "
            + "from their neighbours by more than tolerance %s. Raise \"tolerance\", name the background with "
            + "\"color\": \"#rrggbb\", or drop this operation if the art already has alpha.") % [context, str(tolerance)])
        return {}
    return {
        "image": palettes_script.image_from_bytes(width, height, out),
        "detail": {"cleared_pixels": cleared, "cleared_ratio": float(cleared) / float(maxi(1, width * height))}
    }


func _operation_quantize(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var palette := PackedColorArray()
    if operation.has("palette_name"):
        var palette_name := str(operation.get("palette_name", "")).strip_edges().to_lower()
        if not palettes_script.has_palette(palette_name):
            utils_script.log_error(palettes_script.unknown_palette_message(context + ".palette_name", palette_name))
            return {}
        palette = palettes_script.color_list(palette_name)
    elif operation.has("palette"):
        var raw: Variant = operation.get("palette", [])
        if not (raw is Array) or (raw as Array).is_empty():
            utils_script.log_error("%s.palette must be a non-empty array of colours, e.g. [\"#000000\", \"#ffffff\"]." % context)
            return {}
        for entry in (raw as Array):
            var color: Variant = palettes_script.parse_color(entry)
            if not (color is Color):
                utils_script.log_error("%s.palette entry is not a colour: %s." % [context, JSON.stringify(entry)])
                return {}
            palette.append(color)
    elif not operation.has("max_colors"):
        utils_script.log_error(
            "%s needs palette_name (%s), palette (a list of hex colours), or max_colors (median cut)."
            % [context, palettes_script.catalog_line()])
        return {}

    # Counted by RGB, not RGBA: quantize maps colour and leaves alpha alone, so
    # one red at two alpha levels is one palette colour. (The per-step
    # unique_colors above is the exact RGBA count.)
    var counts: Dictionary = palettes_script.unique_rgb(image)
    var before := counts.size()
    if palette.is_empty():
        var max_colors := int(operation.get("max_colors", 16))
        if max_colors < 1:
            utils_script.log_error("%s.max_colors must be 1 or more; got %d." % [context, max_colors])
            return {}
        palette = _median_cut(counts, max_colors)
    var result := _map_to_palette(image, palette)
    var after: Dictionary = palettes_script.unique_rgb(result)
    var used: Array = after.keys()
    used.sort()
    return {
        "image": result,
        "detail": {
            "colors_before": before,
            "colors_after": after.size(),
            "palette_size": palette.size(),
            "colors_used": used.slice(0, 64)
        }
    }


func _operation_pixelate(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var mode := str(operation.get("mode", "average")).strip_edges().to_lower()
    if not (mode in PIXELATE_MODES):
        utils_script.log_error("%s.mode must be one of %s; got \"%s\"." % [context, ", ".join(PIXELATE_MODES), mode])
        return {}
    var width := image.get_width()
    var height := image.get_height()
    var columns := 0
    var rows := 0
    if operation.has("cell_size"):
        var cell := int(operation.get("cell_size", 0))
        if cell < 1:
            utils_script.log_error("%s.cell_size must be 1 or more (source pixels per output pixel); got %d." % [context, cell])
            return {}
        columns = maxi(1, int(round(float(width) / float(cell))))
        rows = maxi(1, int(round(float(height) / float(cell))))
    else:
        columns = int(operation.get("target_width", 0))
        rows = int(operation.get("target_height", 0))
        if columns <= 0 and rows <= 0:
            utils_script.log_error(
                "%s needs cell_size (how many source pixels make one art pixel) or target_width (how many art pixels across)." % context)
            return {}
        if columns <= 0:
            columns = maxi(1, int(round(float(width) * float(rows) / float(height))))
        if rows <= 0:
            rows = maxi(1, int(round(float(height) * float(columns) / float(width))))
    if columns > width or rows > height:
        utils_script.log_error(
            "%s would upscale (%dx%d source -> %dx%d grid). Pixelating only ever reduces; use resize with \"filter\": \"nearest\" to blow art up."
            % [context, width, height, columns, rows])
        return {}

    var reduced: Image = null
    if mode == "nearest":
        reduced = _copy(image)
        reduced.resize(columns, rows, Image.INTERPOLATE_NEAREST)
    else:
        reduced = _downsample(image, columns, rows, mode == "mode")

    var detail := {"cell_width": float(width) / float(columns), "cell_height": float(height) / float(rows),
        "grid": {"columns": columns, "rows": rows}, "mode": mode}

    if operation.has("palette_name") or operation.has("palette") or operation.has("max_colors"):
        var quantized := _operation_quantize(reduced, operation, context)
        if quantized.is_empty():
            return {}
        reduced = _field(quantized, "image", null)
        detail["quantize"] = _field(quantized, "detail", {})
    if operation.has("alpha_threshold"):
        var threshold := clampf(float(operation.get("alpha_threshold", 0.5)), 0.0, 1.0)
        var hardened := _operation_alpha_threshold(reduced, {"threshold": threshold}, context)
        if hardened.is_empty():
            return {}
        reduced = _field(hardened, "image", null)
        detail["alpha_threshold"] = threshold
    var scale := int(operation.get("scale", 1))
    if scale > 1:
        reduced.resize(columns * scale, rows * scale, Image.INTERPOLATE_NEAREST)
        detail["scale"] = scale
    return {"image": reduced, "detail": detail}


func _operation_outline(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var color: Variant = palettes_script.parse_color(operation.get("color", "#000000"))
    if not (color is Color):
        utils_script.log_error("%s.color is not a colour: %s." % [context, JSON.stringify(operation.get("color", null))])
        return {}
    var threshold := clampf(float(operation.get("threshold", 0.5)), 0.0, 1.0)
    var cutoff := maxi(1, int(round(threshold * 255.0)))
    var detail := {}
    if bool(palettes_script.touches_edge(image, cutoff)):
        # An outline cannot grow the canvas, so art that already fills it loses
        # that side. Silently returning a three-sided outline is exactly the kind
        # of quiet wrong result this skill exists to avoid.
        detail["note"] = ("The art touches the canvas edge, so the outline is clipped there. Run "
            + "{\"type\": \"pad\", \"width\": %d, \"height\": %d} (or trim with \"padding\": 1) before this step."
            ) % [image.get_width() + 2, image.get_height() + 2]
    return {
        "image": palettes_script.outline_image(image, color, bool(operation.get("corners", true)), cutoff),
        "detail": detail
    }


func _operation_tile(image: Image, operation: Dictionary, context: String) -> Dictionary:
    var columns := int(operation.get("columns", 2))
    var rows := int(operation.get("rows", 2))
    if columns < 1 or rows < 1:
        utils_script.log_error("%s.columns and rows must be 1 or more; got %dx%d." % [context, columns, rows])
        return {}
    var width := image.get_width()
    var height := image.get_height()
    var sheet: Image = palettes_script.image_from_bytes(width * columns, height * rows,
        palettes_script.blank_bytes(width * columns, height * rows, Color(0, 0, 0, 0)))
    for row in range(rows):
        for column in range(columns):
            sheet.blit_rect(image, Rect2i(0, 0, width, height), Vector2i(column * width, row * height))
    return {"image": sheet, "detail": {"repeat": {"columns": columns, "rows": rows}}}


func _operation_nine_patch(image: Image, operation: Dictionary, context: String) -> Dictionary:
    # A 9-patch stretches its middle band, so the margins are whatever sits
    # outside the longest run of identical neighbouring columns / rows.
    var minimum := maxi(2, int(operation.get("min_band", 2)))
    var horizontal := _constant_band(image, true)
    var vertical := _constant_band(image, false)
    var left := int(horizontal[0])
    var right := int(horizontal[1])
    var top := int(vertical[0])
    var bottom := int(vertical[1])
    var band_width := image.get_width() - left - right
    var band_height := image.get_height() - top - bottom
    var confident := band_width >= minimum and band_height >= minimum
    if not confident:
        utils_script.log_error(
            ("%s found no stretchable middle: the widest run of identical neighbouring columns/rows is %dx%d, under min_band %d. "
            + "A 9-patch needs a flat (or exactly repeating) centre — draw the panel with a plain middle, or set the margins by hand.")
            % [context, band_width, band_height, minimum])
        return {}
    var detail := {
        "margins": {"left": left, "top": top, "right": right, "bottom": bottom},
        "center": {"x": left, "y": top, "width": band_width, "height": band_height},
        "stylebox_texture": {
            "region_rect": {"x": 0, "y": 0, "width": image.get_width(), "height": image.get_height()},
            "texture_margin_left": left, "texture_margin_top": top,
            "texture_margin_right": right, "texture_margin_bottom": bottom
        },
        "nine_patch_rect": {
            "patch_margin_left": left, "patch_margin_top": top,
            "patch_margin_right": right, "patch_margin_bottom": bottom
        }
    }
    # Any two identical neighbouring columns make a "band", so a round blob can
    # answer with a 2px centre. Say so instead of pretending it is a panel.
    if band_width * 2 < image.get_width() or band_height * 2 < image.get_height():
        detail["note"] = ("The stretchable centre is %dx%d of %dx%d — under half the image, so the margins are "
            + "probably not a 9-patch border (a round or detailed sprite answers this way too). Check them before "
            + "wiring them up, or draw the panel with a flat middle.") % [
            band_width, band_height, image.get_width(), image.get_height()]
    return {"image": image, "detail": detail}


func _operation_pack(frames: Array, operation: Dictionary, context: String) -> Dictionary:
    var layout := str(operation.get("layout", "horizontal")).strip_edges().to_lower()
    if not (layout in LAYOUTS):
        utils_script.log_error("%s.layout must be one of %s; got \"%s\"." % [context, ", ".join(LAYOUTS), layout])
        return {}
    var separation := int(operation.get("separation", 0))
    if separation < 0:
        utils_script.log_error("%s.separation must be 0 or more; got %d." % [context, separation])
        return {}
    var cell_width := 0
    var cell_height := 0
    for index in range(frames.size()):
        var image: Image = _field(frames[index], "image", null)
        if index == 0:
            cell_width = image.get_width()
            cell_height = image.get_height()
        elif image.get_width() != cell_width or image.get_height() != cell_height:
            utils_script.log_error(
                ("%s: frame 0 (\"%s\") is %dx%d but frame %d (\"%s\") is %dx%d. A sheet needs one cell size — "
                + "run {\"type\": \"pad\", \"width\": %d, \"height\": %d} first, or trim them all the same way. Nothing was written.")
                % [context, str(_field(frames[0], "name", "")), cell_width, cell_height, index,
                   str(_field(frames[index], "name", "")), image.get_width(), image.get_height(),
                   maxi(cell_width, image.get_width()), maxi(cell_height, image.get_height())])
            return {}
    var count := frames.size()
    var columns := int(operation.get("columns", 0))
    match layout:
        "vertical":
            columns = 1
        "grid":
            columns = columns if columns > 0 else int(ceil(sqrt(float(count))))
        _:
            columns = columns if columns > 0 else count
    columns = clampi(columns, 1, count)
    var rows := int(ceil(float(count) / float(columns)))
    var sheet_width := columns * (cell_width + separation) - separation
    var sheet_height := rows * (cell_height + separation) - separation
    var sheet: Image = palettes_script.image_from_bytes(sheet_width, sheet_height,
        palettes_script.blank_bytes(sheet_width, sheet_height, Color(0, 0, 0, 0)))
    var regions: Array = []
    for index in range(count):
        var column := index % columns
        var row := int(float(index) / float(columns))
        var x := column * (cell_width + separation)
        var y := row * (cell_height + separation)
        sheet.blit_rect(_field(frames[index], "image", null), Rect2i(0, 0, cell_width, cell_height), Vector2i(x, y))
        regions.append({"name": str(_field(frames[index], "name", "")), "index": index,
            "x": x, "y": y, "width": cell_width, "height": cell_height, "row": row, "column": column})
    return {
        "frames": [{"name": str(operation.get("name", "sheet")), "image": sheet}],
        "detail": {
            "frame_count": count,
            "grid": {"cell_width": cell_width, "cell_height": cell_height,
                "separation_x": separation, "separation_y": separation, "margin_x": 0, "margin_y": 0},
            "columns": columns, "rows": rows, "frames": regions
        }
    }


func _operation_split(frames: Array, operation: Dictionary, context: String) -> Dictionary:
    if frames.size() != 1:
        utils_script.log_error("%s needs exactly one image to slice, but the pipeline is holding %d. Split one sheet per call." % [
            context, frames.size()])
        return {}
    var image: Image = _field(frames[0], "image", null)
    var width := image.get_width()
    var height := image.get_height()
    var margin_x := int(operation.get("margin_x", 0))
    var margin_y := int(operation.get("margin_y", 0))
    var separation_x := int(operation.get("separation_x", 0))
    var separation_y := int(operation.get("separation_y", 0))
    var cell_width := int(operation.get("cell_width", 0))
    var cell_height := int(operation.get("cell_height", 0))
    var columns := int(operation.get("columns", 0))
    var rows := int(operation.get("rows", 0))
    if cell_width <= 0 or cell_height <= 0:
        if columns <= 0 or rows <= 0:
            utils_script.log_error(
                "%s needs cell_width and cell_height (pixels per frame), or columns and rows (how the sheet is divided)." % context)
            return {}
        cell_width = int(float(width - margin_x + separation_x) / float(columns)) - separation_x
        cell_height = int(float(height - margin_y + separation_y) / float(rows)) - separation_y
    if cell_width <= 0 or cell_height <= 0:
        utils_script.log_error("%s computed a cell of %dx%d; check columns/rows/margins against the %dx%d sheet." % [
            context, cell_width, cell_height, width, height])
        return {}
    if columns <= 0:
        columns = int(float(width - margin_x + separation_x) / float(cell_width + separation_x))
    if rows <= 0:
        rows = int(float(height - margin_y + separation_y) / float(cell_height + separation_y))
    if columns <= 0 or rows <= 0:
        utils_script.log_error("%s: a %dx%d cell does not fit in the %dx%d sheet." % [context, cell_width, cell_height, width, height])
        return {}

    var prefix := str(operation.get("prefix", str(_field(frames[0], "name", "frame")) + "_"))
    var digits := int(operation.get("digits", 0))
    var start_index := int(operation.get("start_index", 0))
    var skip_empty := bool(operation.get("skip_empty", false))
    var out_frames: Array = []
    var kept: Array = []
    for row in range(rows):
        for column in range(columns):
            var x := margin_x + column * (cell_width + separation_x)
            var y := margin_y + row * (cell_height + separation_y)
            var cell := image.get_region(Rect2i(x, y, cell_width, cell_height))
            if skip_empty and cell.get_used_rect().size == Vector2i.ZERO:
                continue
            var number := start_index + out_frames.size()
            var label := str(number)
            if digits > 0:
                label = label.pad_zeros(digits)
            out_frames.append({"name": prefix + label, "image": cell})
            kept.append({"index": number, "x": x, "y": y, "row": row, "column": column})
    if out_frames.is_empty():
        utils_script.log_error("%s produced no frames (every cell was empty with skip_empty on)." % context)
        return {}
    return {
        "frames": out_frames,
        "detail": {"frame_count": out_frames.size(), "columns": columns, "rows": rows,
            "grid": {"cell_width": cell_width, "cell_height": cell_height,
                "separation_x": separation_x, "separation_y": separation_y,
                "margin_x": margin_x, "margin_y": margin_y},
            "frames": kept}
    }


# --- pixel helpers -----------------------------------------------------------

func _copy(image: Image) -> Image:
    var duplicate_image := Image.new()
    duplicate_image.copy_from(image)
    return duplicate_image


func _padded(image: Image, width: int, height: int, anchor: String, color: Color) -> Image:
    var canvas: Image = palettes_script.image_from_bytes(width, height, palettes_script.blank_bytes(width, height, color))
    var free_x := width - image.get_width()
    var free_y := height - image.get_height()
    var x := int(float(free_x) / 2.0)
    var y := int(float(free_y) / 2.0)
    if anchor.begins_with("top"):
        y = 0
    elif anchor.begins_with("bottom"):
        y = free_y
    if anchor.ends_with("left"):
        x = 0
    elif anchor.ends_with("right"):
        x = free_x
    canvas.blit_rect(image, Rect2i(0, 0, image.get_width(), image.get_height()), Vector2i(x, y))
    return canvas


func _content_rect(image: Image, background: Color, tolerance: float) -> Rect2i:
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var background_bytes: PackedByteArray = palettes_script.color_bytes(background)
    var cutoff := int(round(clampf(tolerance, 0.0, 1.0) * 255.0))
    var min_x := width
    var min_y := height
    var max_x := -1
    var max_y := -1
    for y in range(height):
        for x in range(width):
            var base := (y * width + x) * 4
            if data[base + 3] == 0:
                continue
            if _within(data, base, background_bytes, cutoff):
                continue
            min_x = mini(min_x, x)
            max_x = maxi(max_x, x)
            min_y = mini(min_y, y)
            max_y = maxi(max_y, y)
    if max_x < 0:
        return Rect2i(0, 0, 0, 0)
    return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _within(data: PackedByteArray, base: int, target: PackedByteArray, cutoff: int) -> bool:
    return absi(int(data[base]) - int(target[0])) <= cutoff \
        and absi(int(data[base + 1]) - int(target[1])) <= cutoff \
        and absi(int(data[base + 2]) - int(target[2])) <= cutoff \
        and absi(int(data[base + 3]) - int(target[3])) <= cutoff


func _pixel_bytes(data: PackedByteArray, base: int) -> PackedByteArray:
    var bytes := PackedByteArray()
    bytes.resize(4)
    for channel in range(4):
        bytes[channel] = data[base + channel]
    return bytes


func _downsample(image: Image, columns: int, rows: int, use_mode: bool) -> Image:
    # One output pixel per cell: the average of the cell (premultiplied, so a
    # transparent halo cannot darken the edge) or the cell's most common colour.
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var out := PackedByteArray()
    out.resize(columns * rows * 4)
    out.fill(0)
    for row in range(rows):
        var y0 := int(float(row) * height / rows)
        var y1 := maxi(y0 + 1, int(float(row + 1) * height / rows))
        var step_y := maxi(1, int(float(y1 - y0) / PIXELATE_CELL_SAMPLES))
        for column in range(columns):
            var x0 := int(float(column) * width / columns)
            var x1 := maxi(x0 + 1, int(float(column + 1) * width / columns))
            var step_x := maxi(1, int(float(x1 - x0) / PIXELATE_CELL_SAMPLES))
            var base := (row * columns + column) * 4
            if use_mode:
                var counts := {}
                var best_key := -1
                var best_count := 0
                var y := y0
                while y < y1:
                    var x := x0
                    while x < x1:
                        var source := (y * width + x) * 4
                        var key := (int(data[source]) << 24) | (int(data[source + 1]) << 16) \
                            | (int(data[source + 2]) << 8) | int(data[source + 3])
                        var seen := (int(counts[key]) + 1) if counts.has(key) else 1
                        counts[key] = seen
                        if seen > best_count or (seen == best_count and key < best_key):
                            best_count = seen
                            best_key = key
                        x += step_x
                    y += step_y
                out[base] = (best_key >> 24) & 0xFF
                out[base + 1] = (best_key >> 16) & 0xFF
                out[base + 2] = (best_key >> 8) & 0xFF
                out[base + 3] = best_key & 0xFF
                continue
            var alpha_sum := 0.0
            var red_sum := 0.0
            var green_sum := 0.0
            var blue_sum := 0.0
            var samples := 0
            var sample_y := y0
            while sample_y < y1:
                var sample_x := x0
                while sample_x < x1:
                    var source := (sample_y * width + sample_x) * 4
                    var alpha := float(data[source + 3])
                    alpha_sum += alpha
                    red_sum += float(data[source]) * alpha
                    green_sum += float(data[source + 1]) * alpha
                    blue_sum += float(data[source + 2]) * alpha
                    samples += 1
                    sample_x += step_x
                sample_y += step_y
            if alpha_sum <= 0.0:
                continue
            out[base] = clampi(int(round(red_sum / alpha_sum)), 0, 255)
            out[base + 1] = clampi(int(round(green_sum / alpha_sum)), 0, 255)
            out[base + 2] = clampi(int(round(blue_sum / alpha_sum)), 0, 255)
            out[base + 3] = clampi(int(round(alpha_sum / float(maxi(1, samples)))), 0, 255)
    return palettes_script.image_from_bytes(columns, rows, out)


func _map_to_palette(image: Image, palette: PackedColorArray) -> Image:
    var data := image.get_data()
    var out := data.duplicate()
    var cache := {}
    for index in range(image.get_width() * image.get_height()):
        var base := index * 4
        if data[base + 3] == 0:
            continue
        var key := (int(data[base]) << 16) | (int(data[base + 1]) << 8) | int(data[base + 2])
        var picked: PackedByteArray
        if cache.has(key):
            picked = cache[key]
        else:
            var color := Color8(data[base], data[base + 1], data[base + 2], 255)
            var nearest: int = palettes_script.nearest_color_index(color, palette)
            picked = palettes_script.color_bytes(palette[nearest])
            cache[key] = picked
        out[base] = picked[0]
        out[base + 1] = picked[1]
        out[base + 2] = picked[2]
    return palettes_script.image_from_bytes(image.get_width(), image.get_height(), out)


func _median_cut(counts: Dictionary, max_colors: int) -> PackedColorArray:
    # Deterministic median cut: buckets are always split on their widest channel
    # at the weighted median, and every sort has an explicit tie-break, so the
    # same image and the same max_colors always produce the same palette.
    var entries: Array = []
    for hex_value in counts.keys():
        var color := Color.html(str(hex_value))
        entries.append({"r": color.r8, "g": color.g8, "b": color.b8, "n": int(counts[hex_value])})
    entries.sort_custom(func(left: Variant, right: Variant) -> bool:
        return _entry_key(left) < _entry_key(right)
    )
    if entries.size() <= max_colors:
        var exact := PackedColorArray()
        for entry in entries:
            exact.append(Color8(int(entry["r"]), int(entry["g"]), int(entry["b"]), 255))
        return exact

    var buckets: Array = [entries]
    while buckets.size() < max_colors:
        var target := -1
        var widest := -1
        for index in range(buckets.size()):
            var bucket: Array = buckets[index]
            if bucket.size() < 2:
                continue
            var spread := _bucket_spread(bucket)
            if int(spread[1]) > widest:
                widest = int(spread[1])
                target = index
        if target < 0:
            break
        var bucket_to_split: Array = buckets[target]
        var channel := str(_bucket_spread(bucket_to_split)[0])
        bucket_to_split.sort_custom(func(left: Variant, right: Variant) -> bool:
            if int(left[channel]) != int(right[channel]):
                return int(left[channel]) < int(right[channel])
            return _entry_key(left) < _entry_key(right)
        )
        var middle := int(float(bucket_to_split.size()) / 2.0)
        buckets[target] = bucket_to_split.slice(0, middle)
        buckets.append(bucket_to_split.slice(middle))

    var palette := PackedColorArray()
    for bucket in buckets:
        var total := 0
        var sum_r := 0.0
        var sum_g := 0.0
        var sum_b := 0.0
        for entry in bucket:
            var weight := int(entry["n"])
            total += weight
            sum_r += float(int(entry["r"]) * weight)
            sum_g += float(int(entry["g"]) * weight)
            sum_b += float(int(entry["b"]) * weight)
        if total == 0:
            continue
        palette.append(Color8(int(round(sum_r / total)), int(round(sum_g / total)), int(round(sum_b / total)), 255))
    return palette


func _entry_key(entry: Variant) -> int:
    return (int(entry["r"]) << 16) | (int(entry["g"]) << 8) | int(entry["b"])


func _bucket_spread(bucket: Array) -> Array:
    var min_values := [255, 255, 255]
    var max_values := [0, 0, 0]
    var channels := ["r", "g", "b"]
    for entry in bucket:
        for index in range(3):
            var value := int(entry[channels[index]])
            min_values[index] = mini(int(min_values[index]), value)
            max_values[index] = maxi(int(max_values[index]), value)
    var best := 0
    var best_range := -1
    for index in range(3):
        var span := int(max_values[index]) - int(min_values[index])
        if span > best_range:
            best_range = span
            best = index
    return [channels[best], best_range]


func _constant_band(image: Image, horizontal: bool) -> Array:
    # Longest run of neighbouring identical columns (or rows) -> [before, after].
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var count := width if horizontal else height
    var best_start := 0
    var best_length := 0
    var run_start := 0
    var run_length := 0
    for index in range(count - 1):
        var same := _line_equal(data, width, height, index, index + 1, horizontal)
        if same:
            if run_length == 0:
                run_start = index
            run_length += 1
            if run_length > best_length:
                best_length = run_length
                best_start = run_start
        else:
            run_length = 0
    if best_length == 0:
        return [0, 0]
    return [best_start, count - (best_start + best_length + 1)]


func _line_equal(data: PackedByteArray, width: int, height: int, a: int, b: int, horizontal: bool) -> bool:
    if horizontal:
        for y in range(height):
            var base_a := (y * width + a) * 4
            var base_b := (y * width + b) * 4
            for channel in range(4):
                if data[base_a + channel] != data[base_b + channel]:
                    return false
        return true
    for x in range(width):
        var base_a := (a * width + x) * 4
        var base_b := (b * width + x) * 4
        for channel in range(4):
            if data[base_a + channel] != data[base_b + channel]:
                return false
    return true


func _field(source: Dictionary, key: String, fallback: Variant) -> Variant:
    return source[key] if source.has(key) else fallback


func _resolve_path(raw: Variant) -> String:
    var path := str(raw).strip_edges().replace("\\", "/")
    if path.is_empty():
        return ""
    if path.begins_with("res://") or path.begins_with("user://") or path.begins_with("/"):
        return path
    return "res://" + path


func _is_directory(path: String) -> bool:
    return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path))
