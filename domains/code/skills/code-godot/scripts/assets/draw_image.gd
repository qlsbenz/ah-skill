class_name GodotSkillDrawImage
extends RefCounted

# ASCII rows and drawing primitives -> a PNG. The inverse of inspect_image: a
# model with no image generator (and no eyes) authors a sprite as text, gets a
# real palette-limited PNG, and reads the same characters back out of the file it
# just wrote.
#
# Everything runs through Godot's Image class, so it needs no GPU, no rendering
# device and no import pass — and because Image.save_png writes the raw file,
# the result has no .import sidecar yet (payload says "needs_import": true).
#
# Failure policy: every frame is built and validated in memory first, so an error
# anywhere — a ragged row, an unknown palette character, mismatched frame sizes,
# a shape entirely off-canvas — exits 1 with nothing written. There is no partial
# output and no silently skipped shape.
#
# Result dictionaries are read through _field() and direct indexing, never with a
# quoted key: the dispatcher derives this op's accepted parameter list from every
# get/has call that has a string literal in it, so reading a result key that way
# would turn that key into a parameter. Shape entries ARE parameters, so those
# are read the ordinary way, with the key spelled out.

var utils_script = preload("../core/utils.gd")
var describe_script = preload("../core/image_describe.gd")
var palettes_script = preload("../core/palettes.gd")

# Characters the caller spelled out in `palette`. The read-back prefers them over
# the 0-9a-v characters a palette_name fills in, so a colour the caller named 'x'
# reads back as 'x' even when the named palette also holds it.
var _explicit_chars: Dictionary = {}
# Set when an outline ran against art that already touched the canvas edge.
var _outline_clipped: bool = false

const SHAPE_TYPES := ["rect", "rect_outline", "circle", "ellipse", "line", "polygon",
    "pixel", "pixels", "gradient_rect", "checker", "noise", "text"]
const LAYOUTS := ["horizontal", "vertical", "grid"]
const MIRROR_MODES := ["append", "append_odd", "fold"]
const OUTPUT_EXTENSIONS := ["png", "webp"]
const GRADIENT_DIRECTIONS := ["horizontal", "vertical", "diagonal"]
# Character-grid read-back: on by default while a frame is small enough that the
# rows cost less than the round trip of a second command, hard-capped so a
# 1024x1024 sheet can never dump a megabyte of JSON.
const DEFAULT_READBACK_AREA := 4096
const MAX_READBACK_AREA := 65536
const MAX_REPORTED_COLORS := 64
const MAX_UNKNOWN_REPORTS := 5
# Characters the read-back hands to colours that no palette character names.
const AUTO_LEGEND_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-*/=<>!?"
# A tile is called seamless when wrapping around the edge is no more of a jump
# than the average step between neighbouring interior lines, times this slack.
const SEAM_SLACK := 1.5

# 3x5 uppercase bitmap font for the `text` shape. Small enough to place a label
# on a 16px tile, big enough to stay legible when scaled.
const FONT_3X5 := {
    "A": [".#.", "#.#", "###", "#.#", "#.#"],
    "B": ["##.", "#.#", "##.", "#.#", "##."],
    "C": [".##", "#..", "#..", "#..", ".##"],
    "D": ["##.", "#.#", "#.#", "#.#", "##."],
    "E": ["###", "#..", "##.", "#..", "###"],
    "F": ["###", "#..", "##.", "#..", "#.."],
    "G": [".##", "#..", "#.#", "#.#", ".##"],
    "H": ["#.#", "#.#", "###", "#.#", "#.#"],
    "I": ["###", ".#.", ".#.", ".#.", "###"],
    "J": ["..#", "..#", "..#", "#.#", ".#."],
    "K": ["#.#", "#.#", "##.", "#.#", "#.#"],
    "L": ["#..", "#..", "#..", "#..", "###"],
    "M": ["#.#", "###", "###", "#.#", "#.#"],
    "N": ["#.#", "##.", "###", ".##", "#.#"],
    "O": [".#.", "#.#", "#.#", "#.#", ".#."],
    "P": ["##.", "#.#", "##.", "#..", "#.."],
    "Q": [".#.", "#.#", "#.#", "##.", ".##"],
    "R": ["##.", "#.#", "##.", "#.#", "#.#"],
    "S": [".##", "#..", ".#.", "..#", "##."],
    "T": ["###", ".#.", ".#.", ".#.", ".#."],
    "U": ["#.#", "#.#", "#.#", "#.#", ".#."],
    "V": ["#.#", "#.#", "#.#", ".#.", ".#."],
    "W": ["#.#", "#.#", "###", "###", "#.#"],
    "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
    "Z": ["###", "..#", ".#.", "#..", "###"],
    "0": ["###", "#.#", "#.#", "#.#", "###"],
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "2": ["##.", "..#", ".#.", "#..", "###"],
    "3": ["##.", "..#", ".#.", "..#", "##."],
    "4": ["#.#", "#.#", "###", "..#", "..#"],
    "5": ["###", "#..", "##.", "..#", "##."],
    "6": [".##", "#..", "###", "#.#", "###"],
    "7": ["###", "..#", ".#.", "#..", "#.."],
    "8": ["###", "#.#", "###", "#.#", "###"],
    "9": ["###", "#.#", "###", "..#", "##."],
    " ": ["...", "...", "...", "...", "..."],
    ".": ["...", "...", "...", "...", ".#."],
    ",": ["...", "...", "...", ".#.", "#.."],
    "!": [".#.", ".#.", ".#.", "...", ".#."],
    "?": ["##.", "..#", ".#.", "...", ".#."],
    "-": ["...", "...", "###", "...", "..."],
    "+": ["...", ".#.", "###", ".#.", "..."],
    ":": ["...", ".#.", "...", ".#.", "..."],
    "/": ["..#", "..#", ".#.", "#..", "#.."],
    "%": ["#.#", "..#", ".#.", "#..", "#.#"],
    "*": ["...", "#.#", ".#.", "#.#", "..."],
    "=": ["...", "###", "...", "###", "..."],
    "<": ["..#", ".#.", "#..", ".#.", "..#"],
    ">": ["#..", ".#.", "..#", ".#.", "#.."],
    "(": ["..#", ".#.", ".#.", ".#.", "..#"],
    ")": ["#..", ".#.", ".#.", ".#.", "#.."]
}


func execute(params: Dictionary) -> void:
    var output_path := _resolve_path(params.get("output_path", ""))
    if output_path.is_empty():
        utils_script.log_error(
            "draw_image requires output_path — the .png to write, project-relative or res:// (\"art/hero.png\"), or absolute. "
            + "Run: help '{\"op\":\"draw_image\"}' for a complete example.")
        return
    var extension := output_path.get_extension().to_lower()
    if not (extension in OUTPUT_EXTENSIONS):
        utils_script.log_error(
            "draw_image output_path must end in .%s; got \"%s\" (%s). Pixel art needs a lossless format with alpha."
            % ["/.".join(PackedStringArray(OUTPUT_EXTENSIONS)), extension, output_path])
        return

    # image_describe.gd is preloaded for the read-back, which makes its own option
    # keys look like parameters of this op. compare_to is the one that would
    # otherwise be accepted and silently ignored, so say where it lives instead.
    if params.has("compare_to"):
        utils_script.log_error(
            "draw_image does not diff images. Write the file, then compare it: inspect_image '{\"image_path\": \"…\", \"compare_to\": \"…\", \"expect\": {\"max_diff_ratio\": 0}}'.")
        return

    var palette := _build_palette(params)
    if palette.is_empty() and utils_script.had_errors:
        return

    var frame_specs := _collect_frame_specs(params)
    if frame_specs.is_empty():
        return

    var images: Array = []
    var frame_names: Array = []
    for index in range(frame_specs.size()):
        var spec: Dictionary = frame_specs[index]
        var label := str(_field(spec, "label", "draw_image"))
        var image := _build_frame(params, _field(spec, "rows", null), _field(spec, "shapes", null), palette, label)
        if image == null:
            return
        images.append(image)
        frame_names.append(str(_field(spec, "name", "frame_%d" % index)))

    var frame_width: int = (images[0] as Image).get_width()
    var frame_height: int = (images[0] as Image).get_height()
    for index in range(images.size()):
        var image: Image = images[index]
        if image.get_width() != frame_width or image.get_height() != frame_height:
            utils_script.log_error(
                ("draw_image frames must all be the same size: frame 0 (\"%s\") is %dx%d but frame %d (\"%s\") is %dx%d. "
                + "Pad the shorter rows with '.' so every frame has the same width and row count — nothing was written.")
                % [str(frame_names[0]), frame_width, frame_height, index, str(frame_names[index]),
                   image.get_width(), image.get_height()])
            return

    var layout := str(params.get("layout", "horizontal")).strip_edges().to_lower()
    if not (layout in LAYOUTS):
        utils_script.log_error("draw_image layout must be one of %s; got \"%s\"." % [", ".join(LAYOUTS), layout])
        return
    var separation := int(params.get("separation", 0))
    if separation < 0:
        utils_script.log_error("draw_image separation must be 0 or more; got %d." % separation)
        return
    var columns := int(params.get("columns", 0))
    if columns < 0:
        utils_script.log_error("draw_image columns must be 1 or more; got %d." % columns)
        return

    var sheet := _pack(images, layout, columns, separation)
    var sheet_image: Image = _field(sheet, "image", null)

    var tile_reports: Array = []
    var want_tile_check := bool(params.get("tile_check", false))
    if want_tile_check:
        for image in images:
            tile_reports.append(_tile_check(image))

    var absolute := ProjectSettings.globalize_path(output_path)
    if FileAccess.file_exists(absolute) and not bool(params.get("overwrite", true)):
        utils_script.log_error(
            "draw_image refuses to replace %s because overwrite is false. Delete it, pick another output_path, or pass \"overwrite\": true — nothing was written."
            % output_path)
        return
    var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
    if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
        utils_script.log_error("draw_image could not create the output directory %s: %s" % [
            absolute.get_base_dir(), error_string(directory_error)])
        return
    var save_error := OK
    if extension == "webp":
        save_error = sheet_image.save_webp(absolute, false)
    else:
        save_error = sheet_image.save_png(absolute)
    if save_error != OK:
        utils_script.log_error("draw_image could not write %s: %s" % [output_path, error_string(save_error)])
        return

    print(JSON.stringify(_payload(params, output_path, sheet, images, frame_names, palette, tile_reports, want_tile_check)))


# --- palette ----------------------------------------------------------------

func _build_palette(params: Dictionary) -> Dictionary:
    # char -> Color. A named palette fills 0-9a-v; an explicit `palette` is laid
    # on top, so a named palette can be extended or overridden per character.
    var palette := {}
    if params.has("palette_name"):
        var palette_name := str(params.get("palette_name", "")).strip_edges().to_lower()
        if not palettes_script.has_palette(palette_name):
            utils_script.log_error(palettes_script.unknown_palette_message("draw_image.palette_name", palette_name))
            return {}
        var hex_values: Array = palettes_script.hex_list(palette_name)
        for index in range(hex_values.size()):
            var symbol: String = palettes_script.index_char(index)
            if symbol.is_empty():
                break
            palette[symbol] = Color.html(str(hex_values[index]))

    if params.has("palette"):
        var raw_palette: Variant = params.get("palette", {})
        if not (raw_palette is Dictionary):
            utils_script.log_error(
                "draw_image.palette must be an object mapping one character to a colour, e.g. {\"#\": \"#2a2a2a\", \"o\": \"#ff004d\", \"-\": null}.")
            return {}
        var entries: Dictionary = raw_palette
        for raw_symbol in entries.keys():
            var symbol := str(raw_symbol)
            if symbol.length() != 1:
                utils_script.log_error(
                    "draw_image.palette keys must be exactly one character; \"%s\" is %d. One character is one pixel."
                    % [symbol, symbol.length()])
                return {}
            if palettes_script.is_transparent_char(symbol):
                utils_script.log_error(
                    "draw_image.palette cannot map \"%s\" to a colour: '.' and ' ' always mean a transparent pixel. Pick another character."
                    % symbol)
                return {}
            var value: Variant = entries[symbol]
            var color: Variant = palettes_script.parse_color(value)
            if not (color is Color):
                utils_script.log_error(
                    "draw_image.palette[\"%s\"] is not a colour: %s. Use \"#rrggbb\", \"#rrggbbaa\", \"#rgb\", or null for transparent."
                    % [symbol, JSON.stringify(value)])
                return {}
            palette[symbol] = color
            _explicit_chars[symbol] = true
    return palette


# --- frames -----------------------------------------------------------------

func _collect_frame_specs(params: Dictionary) -> Array:
    var has_rows := params.has("rows")
    var has_frames := params.has("frames")
    if has_rows and has_frames:
        utils_script.log_error(
            "draw_image takes either rows (one image) or frames (a spritesheet), not both. Move the single rows block into frames: [{\"rows\": [...]}].")
        return []

    if has_frames:
        var raw_frames: Variant = params.get("frames", [])
        if not (raw_frames is Array) or (raw_frames as Array).is_empty():
            utils_script.log_error(
                "draw_image.frames must be a non-empty array, e.g. [{\"name\": \"idle\", \"rows\": [\"..\", \"..\"]}, {\"name\": \"walk\", \"rows\": [...]}].")
            return []
        var specs: Array = []
        var frames: Array = raw_frames
        for index in range(frames.size()):
            var entry: Variant = frames[index]
            if not (entry is Dictionary):
                utils_script.log_error("draw_image.frames[%d] must be an object with \"rows\" (and optionally \"name\" and \"shapes\")." % index)
                return []
            var frame: Dictionary = entry
            var frame_name := str(frame.get("name", "frame_%d" % index))
            if not frame.has("rows") and not frame.has("shapes"):
                utils_script.log_error(
                    "draw_image.frames[%d] (\"%s\") has neither rows nor shapes; every frame needs something to draw." % [index, frame_name])
                return []
            specs.append({
                "rows": frame.get("rows", null),
                "shapes": frame.get("shapes", null),
                "name": frame_name,
                "label": "draw_image.frames[%d]" % index
            })
        return specs

    if has_rows or params.has("shapes") or params.has("width") or params.has("height"):
        return [{"rows": params.get("rows", null), "shapes": null, "name": "frame_0", "label": "draw_image"}]

    utils_script.log_error(
        "draw_image has nothing to draw: pass rows (ASCII pixels), frames (a spritesheet), or width/height plus shapes. "
        + "Run: help '{\"op\":\"draw_image\"}' for a complete example.")
    return []


func _build_frame(params: Dictionary, raw_rows: Variant, raw_frame_shapes: Variant, palette: Dictionary, context: String) -> Image:
    var image: Image = null
    if raw_rows != null:
        if params.has("width") or params.has("height"):
            utils_script.log_error(
                "%s: rows already fix the canvas size (one character is one pixel), so width/height must not be set. Remove them, or drop rows and draw with shapes only."
                % context)
            return null
        image = _image_from_rows(raw_rows, palette, context)
        if image == null:
            return null
    else:
        var width := int(params.get("width", 0))
        var height := int(params.get("height", 0))
        if width <= 0 or height <= 0:
            utils_script.log_error(
                "%s needs a canvas: pass width and height (both > 0) when drawing with shapes instead of rows; got %dx%d."
                % [context, width, height])
            return null
        if width * height > 16777216:
            utils_script.log_error("%s canvas %dx%d is larger than 16 megapixels; draw it smaller and scale it up." % [context, width, height])
            return null
        var background: Variant = palettes_script.parse_color(params.get("background", null))
        if not (background is Color):
            utils_script.log_error(
                "%s.background is not a colour: %s. Use \"#rrggbb\", \"#rrggbbaa\", or null/omit for transparent."
                % [context, JSON.stringify(params.get("background", null))])
            return null
        image = palettes_script.image_from_bytes(width, height, palettes_script.blank_bytes(width, height, background))

    if params.has("shapes"):
        if not _apply_shapes(image, params.get("shapes", []), palette, "draw_image.shapes"):
            return null
    if raw_frame_shapes != null:
        if not _apply_shapes(image, raw_frame_shapes, palette, context + ".shapes"):
            return null

    if params.has("mirror_x"):
        image = _mirror(image, params.get("mirror_x", false), true, context + ".mirror_x")
        if image == null:
            return null
    if params.has("mirror_y"):
        image = _mirror(image, params.get("mirror_y", false), false, context + ".mirror_y")
        if image == null:
            return null

    if params.has("outline"):
        var outline_color: Variant = _resolve_color(params.get("outline", null), palette, context + ".outline")
        if not (outline_color is Color):
            return null
        if (outline_color as Color).a > 0.0:
            # An outline never grows the canvas, so art drawn against the border
            # loses that side of it. Flagged in the payload rather than silently
            # returning a three-sided outline.
            if bool(palettes_script.touches_edge(image, 1)):
                _outline_clipped = true
            image = palettes_script.outline_image(image, outline_color, bool(params.get("outline_corners", true)), 1)

    if params.has("shadow"):
        image = _apply_shadow(image, params.get("shadow", null), palette, context + ".shadow")
        if image == null:
            return null

    var scale := int(params.get("scale", 1))
    if scale < 1:
        utils_script.log_error("%s.scale must be 1 or more (integer nearest-neighbour zoom); got %d." % [context, scale])
        return null
    if scale > 1:
        image.resize(image.get_width() * scale, image.get_height() * scale, Image.INTERPOLATE_NEAREST)
    return image


func _image_from_rows(raw_rows: Variant, palette: Dictionary, context: String) -> Image:
    var rows := _coerce_rows(raw_rows, context + ".rows")
    if rows.is_empty():
        return null
    var width: int = rows[0].length()
    for index in range(rows.size()):
        var row: String = rows[index]
        if row.length() != width:
            utils_script.log_error(
                ("%s.rows are ragged: row 0 is %d characters but row %d is %d (\"%s\"). "
                + "An image is a rectangle — pad the short rows with '.' (transparent). Nothing was written.")
                % [context, width, index, row.length(), row])
            return null
    if width <= 0:
        utils_script.log_error("%s.rows are empty; every row needs at least one character." % context)
        return null

    var height := rows.size()
    var data := PackedByteArray()
    data.resize(width * height * 4)
    data.fill(0)
    var cache := {}
    var unknown: Array = []
    var unknown_chars := {}
    for y in range(height):
        var row: String = rows[y]
        for x in range(width):
            var symbol := row.substr(x, 1)
            if palettes_script.is_transparent_char(symbol):
                continue
            if not palette.has(symbol):
                if not unknown_chars.has(symbol):
                    unknown_chars[symbol] = true
                if unknown.size() < MAX_UNKNOWN_REPORTS:
                    unknown.append("'%s' at row %d, column %d" % [symbol, y, x])
                continue
            var bytes: PackedByteArray
            if cache.has(symbol):
                bytes = cache[symbol]
            else:
                bytes = palettes_script.color_bytes(palette[symbol])
                cache[symbol] = bytes
            var base := (y * width + x) * 4
            data[base] = bytes[0]
            data[base + 1] = bytes[1]
            data[base + 2] = bytes[2]
            data[base + 3] = bytes[3]

    if not unknown.is_empty():
        var legal := PackedStringArray()
        var keys: Array = palette.keys()
        keys.sort()
        for key in keys:
            legal.append("'%s'" % str(key))
        var legal_text := "(the palette is empty)"
        if not legal.is_empty():
            legal_text = ", ".join(legal)
        utils_script.log_error(
            ("%s.rows use characters that are not in the palette: %s%s. Palette characters: %s. "
            + "'.' and ' ' always mean a transparent pixel. Add the missing characters to \"palette\", or use palette_name and the characters 0-9a-v — nothing was written.")
            % [context, ", ".join(PackedStringArray(unknown)),
               (" (+%d more)" % (unknown_chars.size() - unknown.size()) if unknown_chars.size() > unknown.size() else ""),
               legal_text])
        return null
    return palettes_script.image_from_bytes(width, height, data)


func _coerce_rows(raw_rows: Variant, context: String) -> PackedStringArray:
    var rows := PackedStringArray()
    if raw_rows is String:
        for line in (raw_rows as String).split("\n"):
            rows.append(str(line).trim_suffix("\r"))
    elif raw_rows is Array:
        for raw_row in (raw_rows as Array):
            if not (raw_row is String):
                utils_script.log_error(context + " entries must be strings, e.g. [\"..##..\", \".####.\"]")
                return PackedStringArray()
            rows.append((raw_row as String).trim_suffix("\r"))
    else:
        utils_script.log_error(context + " must be an array of strings or one \\n-separated string, e.g. [\"..##..\", \".####.\"]")
        return PackedStringArray()
    while rows.size() > 0 and rows[0].is_empty():
        rows.remove_at(0)
    while rows.size() > 0 and rows[rows.size() - 1].is_empty():
        rows.remove_at(rows.size() - 1)
    if rows.is_empty():
        utils_script.log_error(context + " must contain at least one non-empty row, e.g. [\"..##..\", \".####.\"]")
        return PackedStringArray()
    return rows


# --- shapes -----------------------------------------------------------------

func _apply_shapes(image: Image, raw_shapes: Variant, palette: Dictionary, context: String) -> bool:
    if not (raw_shapes is Array):
        utils_script.log_error(
            context + " must be an ordered array of shape objects, e.g. [{\"type\": \"rect\", \"x\": 0, \"y\": 0, \"width\": 16, \"height\": 4, \"color\": \"#3e8948\"}]")
        return false
    var shapes: Array = raw_shapes
    for index in range(shapes.size()):
        if not (shapes[index] is Dictionary):
            utils_script.log_error("%s[%d] must be an object with a \"type\" key (one of %s)." % [context, index, ", ".join(SHAPE_TYPES)])
            return false
        if not _apply_shape(image, shapes[index], palette, "%s[%d]" % [context, index]):
            return false
    return true


func _apply_shape(image: Image, shape: Dictionary, palette: Dictionary, context: String) -> bool:
    var type_name := str(shape.get("type", "")).strip_edges().to_lower()
    if type_name.is_empty():
        utils_script.log_error("%s needs a \"type\": one of %s." % [context, ", ".join(SHAPE_TYPES)])
        return false
    if not (type_name in SHAPE_TYPES):
        var message := "%s has unknown type \"%s\"" % [context, type_name]
        var near: PackedStringArray = utils_script.nearest_names(type_name, SHAPE_TYPES)
        if not near.is_empty():
            message += " (did you mean " + ", ".join(near) + "?)"
        utils_script.log_error(message + ". Supported shape types: " + ", ".join(SHAPE_TYPES) + ".")
        return false

    var canvas_width := image.get_width()
    var canvas_height := image.get_height()
    var x := int(shape.get("x", 0))
    var y := int(shape.get("y", 0))
    var width := int(shape.get("width", canvas_width - x))
    var height := int(shape.get("height", canvas_height - y))
    var filled := bool(shape.get("filled", true))
    var thickness := int(shape.get("thickness", 1))
    if thickness < 1:
        utils_script.log_error("%s.thickness must be 1 or more; got %d." % [context, thickness])
        return false

    var color := Color(0, 0, 0, 0)
    if type_name != "gradient_rect" and type_name != "checker" and type_name != "noise":
        var resolved: Variant = _resolve_color(shape.get("color", null), palette, context + ".color")
        if not (resolved is Color):
            return false
        color = resolved

    match type_name:
        "rect", "rect_outline", "gradient_rect", "checker", "noise", "ellipse":
            if width <= 0 or height <= 0:
                utils_script.log_error("%s needs width and height greater than 0; got %dx%d." % [context, width, height])
                return false
            if x >= canvas_width or y >= canvas_height or x + width <= 0 or y + height <= 0:
                utils_script.log_error(
                    "%s at (%d, %d) %dx%d lies entirely outside the %dx%d canvas — nothing would be drawn."
                    % [context, x, y, width, height, canvas_width, canvas_height])
                return false

    match type_name:
        "rect":
            image.fill_rect(_clip(Rect2i(x, y, width, height), image), color)
        "rect_outline":
            var thick := mini(thickness, mini(width, height))
            image.fill_rect(_clip(Rect2i(x, y, width, thick), image), color)
            image.fill_rect(_clip(Rect2i(x, y + height - thick, width, thick), image), color)
            image.fill_rect(_clip(Rect2i(x, y, thick, height), image), color)
            image.fill_rect(_clip(Rect2i(x + width - thick, y, thick, height), image), color)
        "circle":
            var radius := int(shape.get("radius", 0))
            if radius <= 0:
                utils_script.log_error("%s needs a radius greater than 0 (x/y are the centre pixel); got %d." % [context, radius])
                return false
            if x + radius < 0 or y + radius < 0 or x - radius >= canvas_width or y - radius >= canvas_height:
                utils_script.log_error(
                    "%s centred at (%d, %d) with radius %d lies entirely outside the %dx%d canvas."
                    % [context, x, y, radius, canvas_width, canvas_height])
                return false
            _draw_ellipse(image, float(x), float(y), float(radius), float(radius), color, filled, thickness)
        "ellipse":
            _draw_ellipse(image, x + (width - 1) / 2.0, y + (height - 1) / 2.0,
                (width - 1) / 2.0, (height - 1) / 2.0, color, filled, thickness)
        "line":
            var from_point: Variant = _point(shape.get("from", null), context + ".from")
            var to_point: Variant = _point(shape.get("to", null), context + ".to")
            if not (from_point is Vector2i) or not (to_point is Vector2i):
                return false
            _draw_line(image, from_point, to_point, color, thickness)
        "polygon":
            var points := _points(shape.get("points", null), context + ".points")
            if points.is_empty():
                return false
            if points.size() < 3:
                utils_script.log_error("%s.points needs at least 3 points for a polygon; got %d." % [context, points.size()])
                return false
            if filled:
                _fill_polygon(image, points, color)
            else:
                for index in range(points.size()):
                    _draw_line(image, points[index], points[(index + 1) % points.size()], color, thickness)
        "pixel":
            if x < 0 or y < 0 or x >= canvas_width or y >= canvas_height:
                utils_script.log_error("%s at (%d, %d) is outside the %dx%d canvas." % [context, x, y, canvas_width, canvas_height])
                return false
            image.set_pixel(x, y, color)
        "pixels":
            var pixels := _points(shape.get("points", null), context + ".points")
            if pixels.is_empty():
                return false
            for point in pixels:
                if point.x < 0 or point.y < 0 or point.x >= canvas_width or point.y >= canvas_height:
                    utils_script.log_error("%s point (%d, %d) is outside the %dx%d canvas." % [context, point.x, point.y, canvas_width, canvas_height])
                    return false
                image.set_pixel(point.x, point.y, color)
        "gradient_rect":
            var stops := _color_list(shape.get("colors", null), palette, context + ".colors", 2)
            if stops.is_empty():
                return false
            var direction := str(shape.get("direction", "vertical")).strip_edges().to_lower()
            if not (direction in GRADIENT_DIRECTIONS):
                utils_script.log_error("%s.direction must be one of %s; got \"%s\"." % [context, ", ".join(GRADIENT_DIRECTIONS), direction])
                return false
            _draw_gradient(image, Rect2i(x, y, width, height), stops, direction, int(shape.get("steps", 0)))
        "checker":
            var pair := _color_list(shape.get("colors", null), palette, context + ".colors", 2)
            if pair.is_empty():
                return false
            var cell := int(shape.get("cell", 1))
            if cell < 1:
                utils_script.log_error("%s.cell must be 1 or more; got %d." % [context, cell])
                return false
            _draw_checker(image, Rect2i(x, y, width, height), pair, cell)
        "noise":
            var choices := _color_list(shape.get("colors", null), palette, context + ".colors", 1)
            if choices.is_empty():
                return false
            var density := clampf(float(shape.get("density", 1.0)), 0.0, 1.0)
            _draw_noise(image, Rect2i(x, y, width, height), choices, int(shape.get("seed", 0)), density)
        "text":
            var text := str(shape.get("text", ""))
            if text.is_empty():
                utils_script.log_error("%s.text is empty; pass the string to draw." % context)
                return false
            var glyph_scale := int(shape.get("scale", 1))
            if glyph_scale < 1:
                utils_script.log_error("%s.scale must be 1 or more; got %d." % [context, glyph_scale])
                return false
            return _draw_text(image, text, x, y, color, glyph_scale, int(shape.get("spacing", 1)), context)
    return true


func _clip(rect: Rect2i, image: Image) -> Rect2i:
    return rect.intersection(Rect2i(0, 0, image.get_width(), image.get_height()))


func _draw_ellipse(image: Image, center_x: float, center_y: float, radius_x: float, radius_y: float,
        color: Color, filled: bool, thickness: int) -> void:
    # Pixels are unit squares, so the outer edge of the shape sits half a pixel
    # past the radius: that half-pixel is what makes a radius-3 circle the round
    # 3/5/7/7/7/5/3 pixel-art disc instead of a diamond with single-pixel tips.
    if radius_x < 0.0 or radius_y < 0.0:
        return
    var outer_x := radius_x + 0.5
    var outer_y := radius_y + 0.5
    var inner_x := radius_x - float(thickness) + 0.5
    var inner_y := radius_y - float(thickness) + 0.5
    var top := int(floor(center_y - outer_y))
    var bottom := int(ceil(center_y + outer_y))
    for y in range(top, bottom + 1):
        var dy := float(y) - center_y
        var outer_span := _ellipse_span(dy, outer_x, outer_y)
        if outer_span < 0.0:
            continue
        var left := int(ceil(center_x - outer_span))
        var right := int(floor(center_x + outer_span))
        var inner_span := -1.0
        if not filled and inner_x > 0.0 and inner_y > 0.0:
            inner_span = _ellipse_span(dy, inner_x, inner_y)
        if inner_span < 0.0:
            image.fill_rect(_clip(Rect2i(left, y, right - left + 1, 1), image), color)
            continue
        var inner_left := int(ceil(center_x - inner_span))
        var inner_right := int(floor(center_x + inner_span))
        image.fill_rect(_clip(Rect2i(left, y, inner_left - left, 1), image), color)
        image.fill_rect(_clip(Rect2i(inner_right + 1, y, right - inner_right, 1), image), color)


func _ellipse_span(dy: float, outer_x: float, outer_y: float) -> float:
    # Half-width of the ellipse at this row, or -1 when the row is outside it.
    var ratio := 1.0 - (dy * dy) / (outer_y * outer_y)
    if ratio < 0.0:
        return -1.0
    return sqrt(ratio * outer_x * outer_x)


func _draw_line(image: Image, from_point: Vector2i, to_point: Vector2i, color: Color, thickness: int) -> void:
    # Bresenham, so a 1px line has no gaps and no anti-aliasing.
    var x0 := from_point.x
    var y0 := from_point.y
    var x1 := to_point.x
    var y1 := to_point.y
    var delta_x := absi(x1 - x0)
    var delta_y := -absi(y1 - y0)
    var step_x := 1 if x0 < x1 else -1
    var step_y := 1 if y0 < y1 else -1
    var error := delta_x + delta_y
    var half := int(float(thickness - 1) / 2.0)
    while true:
        if thickness <= 1:
            if x0 >= 0 and y0 >= 0 and x0 < image.get_width() and y0 < image.get_height():
                image.set_pixel(x0, y0, color)
        else:
            image.fill_rect(_clip(Rect2i(x0 - half, y0 - half, thickness, thickness), image), color)
        if x0 == x1 and y0 == y1:
            break
        var double_error := error * 2
        if double_error >= delta_y:
            error += delta_y
            x0 += step_x
        if double_error <= delta_x:
            error += delta_x
            y0 += step_y


func _fill_polygon(image: Image, points: Array, color: Color) -> void:
    var min_y: int = points[0].y
    var max_y: int = points[0].y
    for point in points:
        min_y = mini(min_y, point.y)
        max_y = maxi(max_y, point.y)
    min_y = maxi(min_y, 0)
    max_y = mini(max_y, image.get_height() - 1)
    for y in range(min_y, max_y + 1):
        var crossings: Array = []
        for index in range(points.size()):
            var a: Vector2i = points[index]
            var b: Vector2i = points[(index + 1) % points.size()]
            if a.y == b.y:
                continue
            var low: Vector2i = a if a.y < b.y else b
            var high: Vector2i = b if a.y < b.y else a
            if y < low.y or y >= high.y:
                continue
            var t := float(y - low.y) / float(high.y - low.y)
            crossings.append(float(low.x) + t * float(high.x - low.x))
        crossings.sort()
        var index := 0
        while index + 1 < crossings.size():
            var left := int(round(float(crossings[index])))
            var right := int(round(float(crossings[index + 1])))
            image.fill_rect(_clip(Rect2i(left, y, right - left + 1, 1), image), color)
            index += 2


func _draw_gradient(image: Image, rect: Rect2i, stops: PackedColorArray, direction: String, steps: int) -> void:
    var clipped := _clip(rect, image)
    if clipped.size.x <= 0 or clipped.size.y <= 0:
        return
    var span_x := maxi(1, rect.size.x - 1)
    var span_y := maxi(1, rect.size.y - 1)
    for y in range(clipped.position.y, clipped.position.y + clipped.size.y):
        for x in range(clipped.position.x, clipped.position.x + clipped.size.x):
            var t := 0.0
            match direction:
                "horizontal":
                    t = float(x - rect.position.x) / float(span_x)
                "vertical":
                    t = float(y - rect.position.y) / float(span_y)
                _:
                    t = (float(x - rect.position.x) / float(span_x) + float(y - rect.position.y) / float(span_y)) / 2.0
            if steps > 1:
                t = float(int(clampf(t, 0.0, 0.9999) * steps)) / float(steps - 1)
            image.set_pixel(x, y, _gradient_color(stops, clampf(t, 0.0, 1.0)))


func _gradient_color(stops: PackedColorArray, t: float) -> Color:
    if stops.size() == 1:
        return stops[0]
    var scaled := t * float(stops.size() - 1)
    var index := clampi(int(floor(scaled)), 0, stops.size() - 2)
    return stops[index].lerp(stops[index + 1], clampf(scaled - float(index), 0.0, 1.0))


func _draw_checker(image: Image, rect: Rect2i, pair: PackedColorArray, cell: int) -> void:
    var clipped := _clip(rect, image)
    for y in range(clipped.position.y, clipped.position.y + clipped.size.y):
        var row_index := int(float(y - rect.position.y) / float(cell))
        for x in range(clipped.position.x, clipped.position.x + clipped.size.x):
            var column_index := int(float(x - rect.position.x) / float(cell))
            image.set_pixel(x, y, pair[(row_index + column_index) % pair.size()])


func _draw_noise(image: Image, rect: Rect2i, choices: PackedColorArray, noise_seed: int, density: float) -> void:
    # Seeded and row-major, so the same seed always paints the same pixels.
    var rng := RandomNumberGenerator.new()
    rng.seed = noise_seed
    var clipped := _clip(rect, image)
    for y in range(rect.position.y, rect.position.y + rect.size.y):
        for x in range(rect.position.x, rect.position.x + rect.size.x):
            var roll := rng.randf()
            var pick := rng.randi_range(0, choices.size() - 1)
            if roll > density:
                continue
            if not clipped.has_point(Vector2i(x, y)):
                continue
            image.set_pixel(x, y, choices[pick])


func _draw_text(image: Image, text: String, x: int, y: int, color: Color, glyph_scale: int, spacing: int, context: String) -> bool:
    var upper := text.to_upper()
    for index in range(upper.length()):
        var symbol := upper.substr(index, 1)
        if not FONT_3X5.has(symbol):
            utils_script.log_error(
                "%s.text cannot draw \"%s\": the built-in 3x5 font covers A-Z 0-9 and . , ! ? - + : / %% * = < > ( ) and space."
                % [context, symbol])
            return false
        var glyph: Array = FONT_3X5[symbol]
        var origin_x := x + index * (3 + spacing) * glyph_scale
        for row in range(glyph.size()):
            var line: String = glyph[row]
            for column in range(line.length()):
                if line[column] != "#":
                    continue
                image.fill_rect(_clip(Rect2i(
                    origin_x + column * glyph_scale,
                    y + row * glyph_scale,
                    glyph_scale, glyph_scale), image), color)
    return true


# --- colours, points --------------------------------------------------------

func _resolve_color(raw: Variant, palette: Dictionary, context: String) -> Variant:
    # A colour is "#rrggbb"/"#rrggbbaa"/"#rgb", null for transparent, or a single
    # palette character so shapes can reuse the characters the rows are drawn in.
    if raw is String and (raw as String).length() == 1 and palette.has(raw):
        return palette[raw]
    var color: Variant = palettes_script.parse_color(raw)
    if color is Color:
        return color
    utils_script.log_error(
        "%s is not a colour: %s. Use \"#rrggbb\", \"#rrggbbaa\", \"#rgb\", null for transparent, or one palette character."
        % [context, JSON.stringify(raw)])
    return null


func _color_list(raw: Variant, palette: Dictionary, context: String, minimum: int) -> PackedColorArray:
    if not (raw is Array) or (raw as Array).size() < minimum:
        utils_script.log_error("%s must be an array of at least %d colours, e.g. [\"#3e8948\", \"#265c42\"]." % [context, minimum])
        return PackedColorArray()
    var colors := PackedColorArray()
    var entries: Array = raw
    for index in range(entries.size()):
        var color: Variant = _resolve_color(entries[index], palette, "%s[%d]" % [context, index])
        if not (color is Color):
            return PackedColorArray()
        colors.append(color)
    return colors


func _point(raw: Variant, context: String) -> Variant:
    if raw is Array and (raw as Array).size() == 2:
        var pair: Array = raw
        return Vector2i(int(pair[0]), int(pair[1]))
    if raw is Dictionary:
        var entry: Dictionary = raw
        if entry.has("x") and entry.has("y"):
            return Vector2i(int(entry["x"]), int(entry["y"]))
    utils_script.log_error("%s must be a point, either [x, y] or {\"x\": 0, \"y\": 0}; got %s." % [context, JSON.stringify(raw)])
    return null


func _points(raw: Variant, context: String) -> Array:
    if not (raw is Array) or (raw as Array).is_empty():
        utils_script.log_error("%s must be a non-empty array of points, e.g. [[0, 0], [7, 0], [3, 7]]." % context)
        return []
    var points: Array = []
    var entries: Array = raw
    for index in range(entries.size()):
        var point: Variant = _point(entries[index], "%s[%d]" % [context, index])
        if not (point is Vector2i):
            return []
        points.append(point)
    return points


# --- mirror, shadow ---------------------------------------------------------

func _mirror(image: Image, raw_mode: Variant, horizontal: bool, context: String) -> Image:
    var mode := ""
    if raw_mode is bool:
        if not (raw_mode as bool):
            return image
        mode = "append"
    else:
        mode = str(raw_mode).strip_edges().to_lower()
        if mode == "true":
            mode = "append"
        elif mode == "false" or mode.is_empty():
            return image
    if not (mode in MIRROR_MODES):
        utils_script.log_error(
            ("%s must be true (same as \"append\"), false, or one of %s. "
            + "\"append\" doubles the size (author the left half / top half), \"append_odd\" shares the centre line (2*n-1), "
            + "\"fold\" keeps the size and mirrors the first half over the second.")
            % [context, ", ".join(MIRROR_MODES)])
        return null

    var width := image.get_width()
    var height := image.get_height()
    var flipped := Image.new()
    flipped.copy_from(image)
    if horizontal:
        flipped.flip_x()
    else:
        flipped.flip_y()

    if mode == "fold":
        var half := int(float((width if horizontal else height)) / 2.0)
        if half <= 0:
            return image
        if horizontal:
            var region := flipped.get_region(Rect2i(width - half, 0, half, height))
            image.blit_rect(region, Rect2i(0, 0, half, height), Vector2i(width - half, 0))
        else:
            var region := flipped.get_region(Rect2i(0, height - half, width, half))
            image.blit_rect(region, Rect2i(0, 0, width, half), Vector2i(0, height - half))
        return image

    var overlap := 1 if mode == "append_odd" else 0
    var new_width := (width * 2 - overlap) if horizontal else width
    var new_height := height if horizontal else (height * 2 - overlap)
    var result := palettes_script.image_from_bytes(new_width, new_height,
        palettes_script.blank_bytes(new_width, new_height, Color(0, 0, 0, 0)))
    result.blit_rect(image, Rect2i(0, 0, width, height), Vector2i(0, 0))
    if horizontal:
        result.blit_rect(flipped, Rect2i(0, 0, width, height), Vector2i(width - overlap, 0))
    else:
        result.blit_rect(flipped, Rect2i(0, 0, width, height), Vector2i(0, height - overlap))
    return result


func _apply_shadow(image: Image, raw_shadow: Variant, palette: Dictionary, context: String) -> Image:
    var offset_x := 1
    var offset_y := 1
    var raw_color: Variant = raw_shadow
    if raw_shadow is Dictionary:
        var entry: Dictionary = raw_shadow
        raw_color = entry.get("color", null)
        offset_x = int(entry.get("x", 1))
        offset_y = int(entry.get("y", 1))
    var color: Variant = _resolve_color(raw_color, palette, context + ".color")
    if not (color is Color):
        return null
    if (color as Color).a <= 0.0:
        return image
    return palettes_script.shadow_image(image, color, offset_x, offset_y)


# --- sheet, checks, read-back -----------------------------------------------

func _pack(images: Array, layout: String, columns: int, separation: int) -> Dictionary:
    var count := images.size()
    var cell_width: int = (images[0] as Image).get_width()
    var cell_height: int = (images[0] as Image).get_height()
    var grid_columns := count
    match layout:
        "vertical":
            grid_columns = 1
        "grid":
            grid_columns = columns if columns > 0 else int(ceil(sqrt(float(count))))
        _:
            grid_columns = columns if columns > 0 else count
    grid_columns = clampi(grid_columns, 1, count)
    var grid_rows := int(ceil(float(count) / float(grid_columns)))

    if count == 1:
        return {
            "image": images[0], "columns": 1, "rows": 1,
            "cell_width": cell_width, "cell_height": cell_height, "separation": separation
        }

    var sheet_width := grid_columns * (cell_width + separation) - separation
    var sheet_height := grid_rows * (cell_height + separation) - separation
    var sheet := palettes_script.image_from_bytes(sheet_width, sheet_height,
        palettes_script.blank_bytes(sheet_width, sheet_height, Color(0, 0, 0, 0)))
    for index in range(count):
        var column := index % grid_columns
        var row := int(float(index) / float(grid_columns))
        sheet.blit_rect(images[index], Rect2i(0, 0, cell_width, cell_height),
            Vector2i(column * (cell_width + separation), row * (cell_height + separation)))
    return {
        "image": sheet, "columns": grid_columns, "rows": grid_rows,
        "cell_width": cell_width, "cell_height": cell_height, "separation": separation
    }


func _tile_check(image: Image) -> Dictionary:
    # "Would this tile sit next to a copy of itself without a visible seam?"
    # Measured as: how big is the colour step across the wrap, compared with the
    # average step between neighbouring interior lines.
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var left_right_same := 0
    var top_bottom_same := 0
    for y in range(height):
        if _same_pixel(data, (y * width) * 4, (y * width + width - 1) * 4):
            left_right_same += 1
    for x in range(width):
        if _same_pixel(data, x * 4, ((height - 1) * width + x) * 4):
            top_bottom_same += 1
    var wrap_x := _column_delta(data, width, height, width - 1, 0)
    var wrap_y := _row_delta(data, width, height, height - 1, 0)
    var interior_x := 0.0
    var interior_max_x := 0.0
    for x in range(width - 1):
        var step := _column_delta(data, width, height, x, x + 1)
        interior_x += step
        interior_max_x = maxf(interior_max_x, step)
    interior_x /= float(maxi(1, width - 1))
    var interior_y := 0.0
    var interior_max_y := 0.0
    for y in range(height - 1):
        var step := _row_delta(data, width, height, y, y + 1)
        interior_y += step
        interior_max_y = maxf(interior_max_y, step)
    interior_y /= float(maxi(1, height - 1))
    # "Seamless" = wrapping around the edge is no bigger a colour step than the
    # steps the tile already contains. The maximum interior step is what makes a
    # checkerboard pass (its wrap is one more check boundary) while a left-to-right
    # gradient fails (nothing inside it jumps like its wrap does). It is a
    # heuristic: the definitive check is process_image {"type": "tile"} plus the
    # ASCII read-back.
    var limit_x := maxf(interior_max_x, interior_x * SEAM_SLACK)
    var limit_y := maxf(interior_max_y, interior_y * SEAM_SLACK)
    return {
        "left_right_match": float(left_right_same) / float(maxi(1, height)),
        "top_bottom_match": float(top_bottom_same) / float(maxi(1, width)),
        "wrap_delta_x": wrap_x,
        "interior_delta_x": interior_x,
        "interior_max_x": interior_max_x,
        "wrap_delta_y": wrap_y,
        "interior_delta_y": interior_y,
        "interior_max_y": interior_max_y,
        "seamless": wrap_x <= limit_x and wrap_y <= limit_y
    }


func _same_pixel(data: PackedByteArray, base_a: int, base_b: int) -> bool:
    return data[base_a] == data[base_b] and data[base_a + 1] == data[base_b + 1] \
        and data[base_a + 2] == data[base_b + 2] and data[base_a + 3] == data[base_b + 3]


func _column_delta(data: PackedByteArray, width: int, height: int, column_a: int, column_b: int) -> float:
    var total := 0.0
    for y in range(height):
        total += _pixel_delta(data, (y * width + column_a) * 4, (y * width + column_b) * 4)
    return total / float(maxi(1, height))


func _row_delta(data: PackedByteArray, width: int, _height: int, row_a: int, row_b: int) -> float:
    var total := 0.0
    for x in range(width):
        total += _pixel_delta(data, (row_a * width + x) * 4, (row_b * width + x) * 4)
    return total / float(maxi(1, width))


func _pixel_delta(data: PackedByteArray, base_a: int, base_b: int) -> float:
    var total := 0
    for channel in range(4):
        total += absi(int(data[base_a + channel]) - int(data[base_b + channel]))
    return float(total) / (4.0 * 255.0)


func _read_back(image: Image, palette: Dictionary) -> Dictionary:
    # The inverse of `rows`: one character per pixel, using the palette's own
    # characters wherever a colour came from the palette. This is the round-trip
    # that proves the PNG on disk holds what was authored.
    var hex_to_char := {}
    var used := {}
    var keys: Array = palette.keys()
    keys.sort()
    var ordered: Array = []
    for key in keys:
        if _explicit_chars.has(str(key)):
            ordered.append(key)
    for key in keys:
        if not _explicit_chars.has(str(key)):
            ordered.append(key)
    for key in ordered:
        var symbol := str(key)
        # Every palette character is spoken for, even one whose colour another
        # character already claimed: the auto-assigner must never hand a palette
        # character to a different colour.
        used[symbol] = true
        var hex_value: String = palettes_script.color_hex(palette[symbol])
        if not hex_to_char.has(hex_value):
            hex_to_char[hex_value] = symbol
    var legend := {}
    var width := image.get_width()
    var height := image.get_height()
    var data := image.get_data()
    var rows: Array = []
    var next_auto := 0
    for y in range(height):
        var line := ""
        for x in range(width):
            var base := (y * width + x) * 4
            if data[base + 3] == 0:
                line += "."
                continue
            var hex_value: String = palettes_script.color_hex(
                Color8(data[base], data[base + 1], data[base + 2], data[base + 3]))
            var symbol := ""
            if hex_to_char.has(hex_value):
                symbol = hex_to_char[hex_value]
            else:
                while next_auto < AUTO_LEGEND_CHARS.length() and used.has(AUTO_LEGEND_CHARS[next_auto]):
                    next_auto += 1
                if next_auto >= AUTO_LEGEND_CHARS.length():
                    symbol = "?"
                else:
                    symbol = AUTO_LEGEND_CHARS[next_auto]
                    used[symbol] = true
                hex_to_char[hex_value] = symbol
            legend[symbol] = hex_value
            line += symbol
        rows.append(line)
    legend["."] = null
    return {"legend": legend, "rows": rows}


# --- payload ----------------------------------------------------------------

func _payload(params: Dictionary, output_path: String, sheet: Dictionary, images: Array,
        frame_names: Array, palette: Dictionary, tile_reports: Array, want_tile_check: bool) -> Dictionary:
    var sheet_image: Image = _field(sheet, "image", null)
    var width := sheet_image.get_width()
    var height := sheet_image.get_height()
    var cell_width := int(_field(sheet, "cell_width", width))
    var cell_height := int(_field(sheet, "cell_height", height))
    var separation := int(_field(sheet, "separation", 0))
    var grid_columns := int(_field(sheet, "columns", 1))

    var counts: Dictionary = palettes_script.unique_colors(sheet_image)
    var swatches: Array = []
    var sorted_hexes: Array = counts.keys()
    sorted_hexes.sort_custom(func(left: Variant, right: Variant) -> bool:
        var left_count := int(counts[left])
        var right_count := int(counts[right])
        if left_count != right_count:
            return left_count > right_count
        return str(left) < str(right)
    )
    for hex_value in sorted_hexes.slice(0, MAX_REPORTED_COLORS):
        swatches.append({"hex": str(hex_value), "pixels": int(counts[hex_value])})

    var payload := {
        "ok": true,
        "output_path": output_path,
        "written": true,
        "needs_import": true,
        "width": width,
        "height": height,
        "frames": images.size(),
        "frame_size": {"width": cell_width, "height": cell_height},
        "frame_names": frame_names,
        "unique_colors": counts.size(),
        "colors": swatches
    }
    if images.size() > 1:
        payload["layout"] = str(params.get("layout", "horizontal")).strip_edges().to_lower()
        payload["grid"] = {
            "cell_width": cell_width, "cell_height": cell_height,
            "separation_x": separation, "separation_y": separation,
            "margin_x": 0, "margin_y": 0
        }
        payload["grid_columns"] = grid_columns
        payload["grid_rows"] = int(_field(sheet, "rows", 1))

    var readback := _readback_wanted(params, cell_width * cell_height)
    var reports: Array = []
    for index in range(images.size()):
        var column := index % grid_columns
        var row := int(float(index) / float(grid_columns))
        var report := {
            "index": index,
            "name": str(frame_names[index]),
            "region": {
                "x": column * (cell_width + separation), "y": row * (cell_height + separation),
                "width": cell_width, "height": cell_height
            }
        }
        if readback:
            var back: Dictionary = _read_back(images[index], palette)
            report["legend"] = _field(back, "legend", {})
            report["rows"] = _field(back, "rows", [])
        if want_tile_check:
            report["tile_check"] = tile_reports[index]
        reports.append(report)
    payload["frame_reports"] = reports
    if _outline_clipped:
        payload["outline_clipped"] = true
        payload["outline_note"] = ("The art touches the canvas edge, so the outline is clipped there. "
            + "Add a transparent row and column around the rows (or draw it one pixel smaller) to get all four sides.")
    if not readback:
        payload["read_back"] = false
        payload["read_back_note"] = _readback_note(params, cell_width, cell_height)

    if bool(params.get("describe", true)):
        var options := {
            "ascii": bool(params.get("ascii", true)),
            "ascii_color": bool(params.get("ascii_color", false)),
            "ascii_width": int(params.get("ascii_width", clampi(width, 4, 120))),
            "max_unique": int(params.get("max_unique", 4096)),
            "background_tolerance": float(params.get("background_tolerance", 0.0))
        }
        var described: Dictionary = describe_script.describe(sheet_image, options)
        for moved in ["ascii", "ascii_color"]:
            if described.has(moved):
                payload[moved] = described[moved]
                described.erase(moved)
        payload["summary"] = described
    return payload


func _readback_wanted(params: Dictionary, area: int) -> bool:
    var requested: Variant = params.get("read_back", null)
    if requested is bool:
        return (requested as bool) and area <= MAX_READBACK_AREA
    return area <= DEFAULT_READBACK_AREA


func _readback_note(params: Dictionary, cell_width: int, cell_height: int) -> String:
    # Three different reasons, three different answers: a caller that turned the
    # read-back off should not be told the image is too big.
    var requested: Variant = params.get("read_back", null)
    var area := cell_width * cell_height
    if requested is bool and not (requested as bool):
        return "Character read-back is off because read_back is false. Drop it (or pass true) to get frame_reports[*].rows."
    if area > MAX_READBACK_AREA:
        return ("Character read-back skipped: a %dx%d frame is over the %d-pixel hard cap, which would be a "
            + "megabyte of JSON. Read the file with inspect_image instead, or draw it smaller and scale it up.") % [
            cell_width, cell_height, MAX_READBACK_AREA]
    return ("Character read-back skipped: a %dx%d frame is over the %d-pixel default. Pass \"read_back\": true "
        + "to force it, or read the file back with inspect_image.") % [cell_width, cell_height, DEFAULT_READBACK_AREA]


func _field(source: Dictionary, key: String, fallback: Variant) -> Variant:
    return source[key] if source.has(key) else fallback


func _resolve_path(raw: Variant) -> String:
    var path := str(raw).strip_edges().replace("\\", "/")
    if path.is_empty():
        return ""
    if path.begins_with("res://") or path.begins_with("user://") or path.begins_with("/"):
        return path
    return "res://" + path
