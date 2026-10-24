class_name GodotSkillPalettes
extends RefCounted

# Named pixel-art palettes plus the colour and pixel helpers that draw_image and
# process_image share.
#
# Every hex value below is the published palette, copied as published — a palette
# whose exact values could not be confirmed is left out rather than approximated,
# because "close enough" defeats the point of asking for a named palette.
# `source(name)` says where each one comes from.
#
# Deliberately free of dictionary reads with a quoted key: the dispatcher derives
# an operation's accepted parameter keys from every get/has call with a string
# literal in the op AND in everything it preloads (utils.gd::allowed_param_keys),
# so one such read here would invent a parameter for both operations that preload
# this file. Dictionaries are indexed directly or probed with a variable instead.

# Characters that address a named palette in `rows`: '0'-'9' then 'a'-'v', so the
# first 32 entries of a palette are drawable. Longer palettes (nes) are still
# usable for quantize, which matches colours instead of characters.
const INDEX_CHARS := "0123456789abcdefghijklmnopqrstuv"

# Characters that always mean "transparent" in a row, whatever the palette says.
const TRANSPARENT_CHARS := [".", " "]

const PALETTES := {
    "pico8": [
        "#000000", "#1d2b53", "#7e2553", "#008751", "#ab5236", "#5f574f", "#c2c3c7", "#fff1e8",
        "#ff004d", "#ffa300", "#ffec27", "#00e436", "#29adff", "#83769c", "#ff77a8", "#ffccaa"
    ],
    "sweetie16": [
        "#1a1c2c", "#5d275d", "#b13e53", "#ef7d57", "#ffcd75", "#a7f070", "#38b764", "#257179",
        "#29366f", "#3b5dc9", "#41a6f6", "#73eff7", "#f4f4f4", "#94b0c2", "#566c86", "#333c57"
    ],
    "db16": [
        "#140c1c", "#442434", "#30346d", "#4e4a4e", "#854c30", "#346524", "#d04648", "#757161",
        "#597dce", "#d27d2c", "#8595a1", "#6daa2c", "#d2aa99", "#6dc2ca", "#dad45e", "#deeed6"
    ],
    "db32": [
        "#000000", "#222034", "#45283c", "#663931", "#8f563b", "#df7126", "#d9a066", "#eec39a",
        "#fbf236", "#99e550", "#6abe30", "#37946e", "#4b692f", "#524b24", "#323c39", "#3f3f74",
        "#306082", "#5b6ee1", "#639bff", "#5fcde4", "#cbdbfc", "#ffffff", "#9badb7", "#847e87",
        "#696a6a", "#595652", "#76428a", "#ac3232", "#d95763", "#d77bba", "#8f974a", "#8a6f30"
    ],
    "endesga32": [
        "#be4a2f", "#d77643", "#ead4aa", "#e4a672", "#b86f50", "#733e39", "#3e2731", "#a22633",
        "#e43b44", "#f77622", "#feae34", "#fee761", "#63c74d", "#3e8948", "#265c42", "#193c3e",
        "#124e89", "#0099db", "#2ce8f5", "#ffffff", "#c0cbdc", "#8b9bb4", "#5a6988", "#3a4466",
        "#262b44", "#181425", "#ff0044", "#68386c", "#b55088", "#f6757a", "#e8b796", "#c28569"
    ],
    "gameboy": ["#0f380f", "#306230", "#8bac0f", "#9bbc0f"],
    "cga": [
        "#000000", "#0000aa", "#00aa00", "#00aaaa", "#aa0000", "#aa00aa", "#aa5500", "#aaaaaa",
        "#555555", "#5555ff", "#55ff55", "#55ffff", "#ff5555", "#ff55ff", "#ffff55", "#ffffff"
    ],
    "c64": [
        "#000000", "#ffffff", "#880000", "#aaffee", "#cc44cc", "#00cc55", "#0000aa", "#eeee77",
        "#dd8855", "#664400", "#ff7777", "#333333", "#777777", "#aaff66", "#0088ff", "#bbbbbb"
    ],
    "grayscale4": ["#000000", "#555555", "#aaaaaa", "#ffffff"],
    "nes": [
        "#000000",
        "#7c7c7c", "#0000fc", "#0000bc", "#4428bc", "#940084", "#a80020", "#a81000",
        "#881400", "#503000", "#007800", "#006800", "#005800", "#004058",
        "#bcbcbc", "#0078f8", "#0058f8", "#6844fc", "#d800cc", "#e40058", "#f83800",
        "#e45c10", "#ac7c00", "#00b800", "#00a800", "#00a844", "#008888",
        "#f8f8f8", "#3cbcfc", "#6888fc", "#9878f8", "#f878f8", "#f85898", "#f87858",
        "#fca044", "#f8b800", "#b8f818", "#58d854", "#58f898", "#00e8d8", "#787878",
        "#fcfcfc", "#a4e4fc", "#b8b8f8", "#d8b8f8", "#f8b8f8", "#f8a4c0", "#f0d0b0",
        "#fce0a8", "#f8d878", "#d8f878", "#b8f8b8", "#b8f8d8", "#00fcfc", "#f8d8f8"
    ]
}

const PALETTE_SOURCES := {
    "pico8": "PICO-8 system palette (Lexaloffle), 16 colours",
    "sweetie16": "Sweetie 16 by GrafxKid, 16 colours",
    "db16": "DawnBringer 16 (Pixeljoint), 16 colours",
    "db32": "DawnBringer 32 (Pixeljoint), 32 colours",
    "endesga32": "Endesga 32 (EDG32) by Endesga, 32 colours",
    "gameboy": "Game Boy DMG 4-shade green LCD ramp, darkest first",
    "cga": "IBM CGA/EGA 16-colour text palette (5153 monitor RGBI values)",
    "c64": "Commodore 64 (Pepto RGB rendering), 16 colours",
    "grayscale4": "Even 4-step grayscale ramp (0x00/0x55/0xaa/0xff)",
    "nes": "NES 2C02 as rendered by the FCEUX/Nintendulator default RGB table, duplicate blacks dropped (the NES has no single true RGB palette; every emulator and TV differs). Every channel is a multiple of 4."
}


static func names() -> Array:
    var list: Array = PALETTES.keys()
    list.sort()
    return list


static func has_palette(palette_name: String) -> bool:
    return PALETTES.has(palette_name)


static func hex_list(palette_name: String) -> Array:
    if not PALETTES.has(palette_name):
        return []
    return PALETTES[palette_name]


static func source(palette_name: String) -> String:
    if not PALETTE_SOURCES.has(palette_name):
        return ""
    return PALETTE_SOURCES[palette_name]


static func color_list(palette_name: String) -> PackedColorArray:
    var colors := PackedColorArray()
    for hex_value in hex_list(palette_name):
        colors.append(Color.html(str(hex_value)))
    return colors


static func catalog_line() -> String:
    # One line naming every palette and its size, for error messages: a caller
    # that guessed a name gets the real list instead of "unknown palette".
    var parts: PackedStringArray = []
    for palette_name in names():
        parts.append("%s (%d)" % [str(palette_name), (PALETTES[palette_name] as Array).size()])
    return ", ".join(parts)


static func unknown_palette_message(context: String, palette_name: String) -> String:
    return "%s: unknown palette \"%s\". Known palettes and their sizes: %s." % [
        context, palette_name, catalog_line()]


static func parse_color(raw: Variant) -> Variant:
    # "#rgb" / "#rgba" / "#rrggbb" / "#rrggbbaa", with or without the "#".
    # Returns a Color, or null when the text is not a colour (the caller owns the
    # error message, which is why nothing is logged here).
    if raw == null:
        return Color(0, 0, 0, 0)
    if raw is Color:
        return raw
    if not (raw is String or raw is StringName):
        return null
    var text := str(raw).strip_edges()
    if text.is_empty():
        return null
    if text.to_lower() == "transparent" or text.to_lower() == "none":
        return Color(0, 0, 0, 0)
    var body := text.trim_prefix("#")
    if not Color.html_is_valid(body):
        return null
    return Color.html(body)


static func color_hex(color: Color) -> String:
    # "#rrggbb" for an opaque colour, "#rrggbbaa" when alpha is not full, so the
    # text round-trips straight back into parse_color.
    if color.a >= 1.0:
        return "#" + color.to_html(false)
    return "#" + color.to_html(true)


static func index_char(index: int) -> String:
    if index < 0 or index >= INDEX_CHARS.length():
        return ""
    return INDEX_CHARS[index]


static func is_transparent_char(symbol: String) -> bool:
    return symbol in TRANSPARENT_CHARS


static func nearest_color_index(color: Color, palette: PackedColorArray) -> int:
    # Plain squared RGB distance. Perceptual weighting would change which colour
    # a quantize picks between runs of different palettes for no measurable gain
    # on flat pixel art, and this stays exactly reproducible.
    var best := -1
    var best_distance := INF
    for index in range(palette.size()):
        var candidate := palette[index]
        var delta_r := color.r - candidate.r
        var delta_g := color.g - candidate.g
        var delta_b := color.b - candidate.b
        var distance := delta_r * delta_r + delta_g * delta_g + delta_b * delta_b
        if distance < best_distance:
            best_distance = distance
            best = index
    return best


# --- pixel helpers shared by draw_image and process_image --------------------
# All of them go through get_data()/PackedByteArray instead of per-pixel
# get_pixel/set_pixel: a 1024x1024 image is a million calls either way, and the
# byte form runs it in well under a second.

static func to_rgba8(source_image: Image) -> Image:
    var copy := Image.new()
    copy.copy_from(source_image)
    if copy.is_compressed() and copy.decompress() != OK:
        return null
    if copy.get_format() != Image.FORMAT_RGBA8:
        copy.convert(Image.FORMAT_RGBA8)
    return copy


static func image_from_bytes(width: int, height: int, data: PackedByteArray) -> Image:
    return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)


static func blank_bytes(width: int, height: int, color: Color) -> PackedByteArray:
    var data := PackedByteArray()
    data.resize(width * height * 4)
    if color.a <= 0.0 and color.r <= 0.0 and color.g <= 0.0 and color.b <= 0.0:
        data.fill(0)
        return data
    var pixel := color_bytes(color)
    for index in range(width * height):
        var base := index * 4
        data[base] = pixel[0]
        data[base + 1] = pixel[1]
        data[base + 2] = pixel[2]
        data[base + 3] = pixel[3]
    return data


static func color_bytes(color: Color) -> PackedByteArray:
    var bytes := PackedByteArray()
    bytes.resize(4)
    bytes[0] = color.r8
    bytes[1] = color.g8
    bytes[2] = color.b8
    bytes[3] = int(round(clampf(color.a, 0.0, 1.0) * 255.0))
    return bytes


static func outline_image(source_image: Image, color: Color, corners: bool, threshold: int) -> Image:
    # One pixel of `color` in every transparent pixel that touches an opaque one.
    # The canvas never grows, so art drawn against the border loses that side of
    # its outline — leave a transparent margin in the rows.
    var width := source_image.get_width()
    var height := source_image.get_height()
    var data := source_image.get_data()
    var out := data.duplicate()
    var ink := color_bytes(color)
    for y in range(height):
        for x in range(width):
            var base := (y * width + x) * 4
            if data[base + 3] >= threshold:
                continue
            if not _touches_opaque(data, width, height, x, y, corners, threshold):
                continue
            out[base] = ink[0]
            out[base + 1] = ink[1]
            out[base + 2] = ink[2]
            out[base + 3] = ink[3]
    return image_from_bytes(width, height, out)


static func touches_edge(source_image: Image, threshold: int) -> bool:
    # True when opaque pixels sit on the border, which is exactly when an outline
    # has nowhere to go and is silently clipped.
    var width := source_image.get_width()
    var height := source_image.get_height()
    var data := source_image.get_data()
    for x in range(width):
        if data[(x) * 4 + 3] >= threshold:
            return true
        if data[((height - 1) * width + x) * 4 + 3] >= threshold:
            return true
    for y in range(height):
        if data[(y * width) * 4 + 3] >= threshold:
            return true
        if data[(y * width + width - 1) * 4 + 3] >= threshold:
            return true
    return false


static func _touches_opaque(data: PackedByteArray, width: int, height: int, x: int, y: int, corners: bool, threshold: int) -> bool:
    for offset in (NEIGHBORS_8 if corners else NEIGHBORS_4):
        var nx: int = x + int(offset[0])
        var ny: int = y + int(offset[1])
        if nx < 0 or ny < 0 or nx >= width or ny >= height:
            continue
        if data[(ny * width + nx) * 4 + 3] >= threshold:
            return true
    return false


const NEIGHBORS_4 := [[-1, 0], [1, 0], [0, -1], [0, 1]]
const NEIGHBORS_8 := [[-1, 0], [1, 0], [0, -1], [0, 1], [-1, -1], [1, -1], [-1, 1], [1, 1]]


static func shadow_image(source_image: Image, color: Color, offset_x: int, offset_y: int) -> Image:
    # The silhouette, offset and flattened to one colour, painted underneath.
    var width := source_image.get_width()
    var height := source_image.get_height()
    var data := source_image.get_data()
    var shadow := PackedByteArray()
    shadow.resize(width * height * 4)
    shadow.fill(0)
    var ink := color_bytes(color)
    for y in range(height):
        var ty := y + offset_y
        if ty < 0 or ty >= height:
            continue
        for x in range(width):
            if data[(y * width + x) * 4 + 3] <= 0:
                continue
            var tx := x + offset_x
            if tx < 0 or tx >= width:
                continue
            var base := (ty * width + tx) * 4
            shadow[base] = ink[0]
            shadow[base + 1] = ink[1]
            shadow[base + 2] = ink[2]
            shadow[base + 3] = ink[3]
    var result := image_from_bytes(width, height, shadow)
    result.blend_rect(source_image, Rect2i(0, 0, width, height), Vector2i(0, 0))
    return result


static func unique_colors(source_image: Image) -> Dictionary:
    # hex -> pixel count over the WHOLE image (never a downscaled sample, unlike
    # image_describe: a palette claim has to be exact). Fully transparent pixels
    # are not a colour — same rule image_describe uses — so a 4-colour sprite on
    # a transparent canvas counts 4.
    var width := source_image.get_width()
    var height := source_image.get_height()
    var data := source_image.get_data()
    var counts := {}
    for index in range(width * height):
        var base := index * 4
        if data[base + 3] == 0:
            continue
        var key := (int(data[base]) << 24) | (int(data[base + 1]) << 16) | (int(data[base + 2]) << 8) | int(data[base + 3])
        if counts.has(key):
            counts[key] = int(counts[key]) + 1
        else:
            counts[key] = 1
    var out := {}
    for key in counts.keys():
        var packed := int(key)
        var color := Color8((packed >> 24) & 0xFF, (packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
        out[color_hex(color)] = int(counts[key])
    return out


static func unique_rgb(source_image: Image) -> Dictionary:
    # "#rrggbb" -> pixel count, ignoring alpha, over every pixel that is not
    # fully transparent. This is the count a palette claim is about: the same
    # red at two alpha levels is one palette colour, not two.
    var width := source_image.get_width()
    var height := source_image.get_height()
    var data := source_image.get_data()
    var counts := {}
    for index in range(width * height):
        var base := index * 4
        if data[base + 3] == 0:
            continue
        var key := (int(data[base]) << 16) | (int(data[base + 1]) << 8) | int(data[base + 2])
        if counts.has(key):
            counts[key] = int(counts[key]) + 1
        else:
            counts[key] = 1
    var out := {}
    for key in counts.keys():
        var packed := int(key)
        out["#%02x%02x%02x" % [(packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF]] = int(counts[key])
    return out
