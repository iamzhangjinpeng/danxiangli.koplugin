-- Build the displayed wallpaper from a cached original JPEG.
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Wallpaper = { MAX_JPEG_BYTES = 4 * 1024 * 1024 }
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)")
local CARD_BACKGROUND = plugin_dir .. "assets/card-background.png"
local CACHE_VERSION = 1
local MAX_JPEG_PIXELS = 4 * 1024 * 1024
local MAX_PNG_BYTES = 32 * 1024 * 1024
local MAX_PNG_PIXELS = 8 * 1024 * 1024
local MAX_IMAGE_EDGE = 4096
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local PNG_END = "\0\0\0\0IEND\174\66\96\130"
local verified_png

local function round(value)
    return math.floor(value + 0.5)
end

local function big_endian(data, offset, length)
    local value = 0
    for i = offset, offset + length - 1 do
        value = value * 256 + data:byte(i)
    end
    return value
end

local function dimensions_fit(width, height, max_pixels)
    return width > 0 and height > 0 and width <= MAX_IMAGE_EDGE and height <= MAX_IMAGE_EDGE
        and width * height <= max_pixels
end

local function valid_png(path, attrs)
    if not attrs or attrs.mode ~= "file" or attrs.size < 45 or attrs.size > MAX_PNG_BYTES then return false end
    local file = io.open(path, "rb")
    if not file then return nil end
    local head = file:read(24)
    local tail
    if file:seek("end", -12) then tail = file:read(12) end
    file:close()
    if not head or #head ~= 24 or head:sub(1, 16) ~= PNG_SIGNATURE .. "\0\0\0\13IHDR"
        or tail ~= PNG_END then return false end
    if not dimensions_fit(big_endian(head, 17, 4), big_endian(head, 21, 4), MAX_PNG_PIXELS) then return false end

    local ffi = require("ffi")
    local Png = require("ffi/png")
    local called, ok, image = pcall(Png.decodeFromFile, path, 1)
    if not called then return nil end
    if not ok then return false end
    ffi.C.free(image.data)
    return true
end

local function cached_png_is_valid(path)
    local attrs = lfs.attributes(path)
    if not attrs then return false end
    local saved = verified_png and verified_png.path == path and verified_png.attrs
    if saved and attrs.mode == saved.mode and attrs.size == saved.size and attrs.modification == saved.modification
        and attrs.change == saved.change and attrs.ino == saved.ino and attrs.dev == saved.dev then
        return true
    end
    local valid = valid_png(path, attrs)
    if not valid then return valid end
    verified_png = { path = path, attrs = attrs }
    return true
end

-- Scan JPEG segments up to the first frame header before allocating pixels.
-- Sequential and progressive DCT cover the daily images and their variants.
local function jpeg_dimensions(data)
    local pos = 3
    while pos <= #data and data:byte(pos) == 255 do
        repeat pos = pos + 1 until data:byte(pos) ~= 255
        local marker = data:byte(pos)
        pos = pos + 1
        if not marker or marker == 0 or marker == 218 or marker == 222
            or (marker >= 208 and marker <= 217) or pos + 1 > #data then return end
        local length = big_endian(data, pos, 2)
        if length < 2 or pos + length > #data then return end
        if marker == 192 or marker == 193 or marker == 194 then
            if length < 11 or length ~= 8 + 3 * data:byte(pos + 7) then return end
            return big_endian(data, pos + 5, 2), big_endian(data, pos + 3, 2)
        end
        -- Reject an unsupported SOF instead of trusting a later frame.
        if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 204 then return end
        pos = pos + length
    end
end

local function decode_source(RenderImage, path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local size = file:seek("end")
    if size and size > Wallpaper.MAX_JPEG_BYTES then
        file:close()
        return nil, "JPEG exceeds the download size limit"
    end
    local data
    if size and size >= 4 and file:seek("set", 0) then data = file:read(size) end
    file:close()
    if not data or #data ~= size or data:sub(1, 2) ~= "\255\216" or data:sub(-2) ~= "\255\217" then
        return nil, "Invalid JPEG"
    end
    local width, height = jpeg_dimensions(data)
    if not width then return nil, "Invalid or unsupported JPEG frame" end
    if not dimensions_fit(width, height, MAX_JPEG_PIXELS) then return nil, "JPEG dimensions exceed the limit" end
    local ok, image = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok then return nil, tostring(image) end
    if not image then return nil, "Cannot decode the daily image" end
    return image
end

function Wallpaper.validate_source(path)
    local image, err = decode_source(require("ui/renderimage"), path)
    if not image then return false, err end
    image:free()
    return true
end

-- OWSPACE prints thin crop marks about 29 px from the edges of a 591 × 868
-- page. Only cover a corner if it looks like paper with lines in those bands.
local function remove_corner_marks(image, white)
    local width, height = image:getWidth(), image:getHeight()
    local corner_w, corner_h = round(33 * width / 591), round(33 * height / 868)
    local line_x, line_y = round(29 * width / 591), round(29 * height / 868)
    local band_x, band_y = math.max(1, round(3 * width / 591)), math.max(1, round(3 * height / 868))
    local function clean_corner(x0, y0, dx, dy)
        local marks = 0
        for y = 0, corner_h - 1 do
            for x = 0, corner_w - 1 do
                local shade = image:getPixel(x0 + dx * x, y0 + dy * y):getColor8().a
                if shade < 242 then
                    if math.abs(x - line_x) > band_x and math.abs(y - line_y) > band_y then
                        return
                    end
                    marks = marks + 1
                end
            end
        end
        if marks >= math.max(3, math.min(corner_w, corner_h) / 2) then
            local left = dx == 1 and x0 or x0 - corner_w + 1
            local top = dy == 1 and y0 or y0 - corner_h + 1
            image:paintRect(left, top, corner_w, corner_h, white)
        end
    end
    clean_corner(0, 0, 1, 1)
    clean_corner(width - 1, 0, -1, 1)
    clean_corner(0, height - 1, 1, -1)
    clean_corner(width - 1, height - 1, -1, -1)
end

local function render(source, target, width, height)
    local original, photo, background, canvas
    local invalid_source
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local RenderImage = require("ui/renderimage")
        local decode_error
        original, decode_error = decode_source(RenderImage, source)
        if not original then
            invalid_source = true
            error(decode_error, 0)
        end
        remove_corner_marks(original, Blitbuffer.COLOR_WHITE)

        if width then
            assert(dimensions_fit(width, height, MAX_PNG_PIXELS), "Card dimensions exceed the limit")
            local function x(px) return round(px * width / 1072) end
            local function y(px) return round(px * height / 1448) end
            local card_x, card_y = x(72), y(128)
            local card_right, card_bottom = x(1000), y(1292)
            local rx, ry = math.max(1, x(73)), math.max(1, y(73))

            background = assert(RenderImage:renderImageFile(CARD_BACKGROUND, false), "Cannot load the card background")
            background = assert(RenderImage:scaleBlitBuffer(background, width, height), "Cannot scale the card background")
            canvas = Blitbuffer.new(width, height, original:getType())
            canvas:blitFrom(background, 0, 0, 0, 0, width, height)
            background:free()
            background = nil

            -- The reference template includes music icons and rules in this
            -- rectangle. Paint the card interior white before placing the image.
            canvas:paintRect(x(145), y(195), x(933) - x(145), y(1240) - y(195), Blitbuffer.COLOR_WHITE)

            local iw, ih = original:getWidth(), original:getHeight()
            local scale = math.min((card_right - card_x) / iw, (card_bottom - card_y) / ih)
            local pw, ph = math.max(1, round(iw * scale)), math.max(1, round(ih * scale))
            photo = assert(RenderImage:scaleBlitBuffer(original, pw, ph, false), "Cannot scale the daily image")
            local px = math.floor((card_x + card_right - pw) / 2)
            local py = math.floor((card_y + card_bottom - ph) / 2)
            for row = 0, ph - 1 do
                local dst_y = py + row
                local edge_distance = math.min(dst_y + 0.5 - card_y, card_bottom - dst_y - 0.5)
                local arc = math.max(0, 1 - edge_distance / ry)
                local inset = round(rx * (1 - math.sqrt(1 - arc * arc)))
                local left = math.max(px, card_x + inset)
                local right = math.min(px + pw, card_right - inset)
                if right > left then
                    canvas:blitFrom(photo, left, dst_y, left - px, row, right - left, 1)
                end
            end
        end

        local written, result, detail = (canvas or original):writeToFile(target, "png")
        assert(written and result ~= false, detail or result or "Cannot write the wallpaper PNG")
    end)
    if canvas then canvas:free() end
    if background then background:free() end
    if photo and photo ~= original then photo:free() end
    if original then original:free() end
    return ok, err, invalid_source
end

local function generated_images(dir)
    local paths = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return paths end
    for name in lfs.dir(dir) do
        local style = name:match("^%d%d%d%d%d%d%d%d%-(%a+)%-%d+%-%d+x%d+%-%-?%d+%-%d+%.png$")
        if (style == "fullscreen" or style == "card") and lfs.attributes(dir .. name, "mode") == "file" then
            paths[#paths + 1] = dir .. name
        end
    end
    return paths
end

local function keep_wallpaper(paths, keep)
    for _, path in ipairs(paths) do
        if path ~= keep then
            local removed, err = os.remove(path)
            if not removed then logger.warn("单向历: 无法清理壁纸", path, tostring(err)) end
        end
    end
end

-- Keep the last usable wallpaper until a complete replacement is available.
function Wallpaper.prepare(dir, source, style, refresh, verify_cache)
    if verify_cache then verified_png = nil end
    local previous = generated_images(dir)
    local tmp = dir .. "wallpaper.png.tmp"
    os.remove(tmp)
    local failure, invalid_source
    if source then
        local attrs = lfs.attributes(source)
        local date = source:match("(%d%d%d%d%d%d%d%d)%.jpg$")
        local width, height
        if style == "card" then
            local screen = require("device").screen
            local sw, sh = screen:getWidth(), screen:getHeight()
            width, height = math.min(sw, sh), math.max(sw, sh)
        end
        if attrs and date then
            local key = string.format("%s-%s-%d-%dx%d-%d-%d.png", date, style, CACHE_VERSION,
                width or 0, height or 0, attrs.modification, attrs.size)
            local target = dir .. key
            local ready = not refresh and cached_png_is_valid(target)
            if not ready then
                local made, mkdir_err = util.makePath(dir)
                if made then
                    ready, failure, invalid_source = render(source, tmp, width, height)
                    if ready then
                        if valid_png(tmp, lfs.attributes(tmp)) then
                            ready, failure = os.rename(tmp, target)
                            if ready then verified_png = { path = target, attrs = lfs.attributes(target) } end
                        else
                            ready, failure = false, "Invalid generated wallpaper PNG"
                        end
                    end
                    os.remove(tmp)
                else
                    failure = mkdir_err
                end
            end
            if ready then
                keep_wallpaper(previous, target)
                return true
            end
        end
        failure = failure or "Cannot prepare the wallpaper"
        logger.warn("单向历: 壁纸生成失败", tostring(failure))
    end
    table.sort(previous, function(a, b) return a > b end)
    local invalid = {}
    for _, path in ipairs(previous) do
        local valid = cached_png_is_valid(path)
        if valid then
            keep_wallpaper(previous, path)
            return true, failure, invalid_source
        end
        if valid == false then invalid[#invalid + 1] = path end
    end
    keep_wallpaper(invalid)
    return false, failure, invalid_source
end

return Wallpaper
