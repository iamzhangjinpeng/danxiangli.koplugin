-- Run from the plugin directory: lua tests/wallpaper_spec.lua /path/to/empty/scratch-dir
-- Exercise the real cache and header checks with simulated KOReader decoders.
local dir = assert(arg and arg[1], "Provide an existing scratch directory") .. "/"
local repo = (arg and arg[2]) or "."
local real_remove, real_rename = os.remove, os.rename
local files, clock = {}, 0
local renders, png_decodes = 0, 0
local write_failure, png_decoder_failure

local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = assert(file:read("*a"))
    file:close()
    return data
end

local function write(path, data, modification)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    assert(file:close())
    clock = clock + 1
    files[path] = { mode = "file", size = #data, modification = modification or clock, change = clock }
end

function os.remove(path)
    local ok, err = real_remove(path)
    if ok then files[path] = nil end
    return ok, err
end

function os.rename(from, to)
    local ok, err = real_rename(from, to)
    if ok then files[to], files[from] = files[from], nil end
    return ok, err
end

local good_png = read(repo .. "/assets/card-background.png")
local bad_png = good_png:sub(1, 32) .. string.char((good_png:byte(33) + 1) % 256) .. good_png:sub(34)
local function jpeg(width, height, marker)
    return "\255\216\255" .. string.char(marker or 192)
        .. string.char(0, 11, 8, math.floor(height / 256), height % 256,
            math.floor(width / 256), width % 256, 1, 1, 17, 0) .. "\255\217"
end

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        local attrs = path == dir and { mode = "directory" } or files[path]
        if key then return attrs and attrs[key] end
        return attrs
    end,
    dir = function(path)
        assert(path == dir)
        local names, i = {}, 0
        for name in pairs(files) do names[#names + 1] = name:sub(#dir + 1) end
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded.logger = { warn = function() end }
package.loaded.util = { makePath = function(path) assert(path == dir); return true end }
package.loaded.ffi = { C = { free = function(data) assert(data == "pixels") end } }
package.loaded["ffi/png"] = { decodeFromFile = function(path, channels)
    assert(channels == 1)
    png_decodes = png_decodes + 1
    if png_decoder_failure then error("decoder unavailable") end
    if read(path) ~= good_png then return false, "PNG checksum error" end
    return true, { data = "pixels" }
end }
package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 255 }
package.loaded["ui/renderimage"] = { renderImageData = function(_, data, size)
    assert(#data == size)
    renders = renders + 1
    return {
        getWidth = function() return 1 end,
        getHeight = function() return 1 end,
        free = function() end,
        writeToFile = function(_, path)
            if write_failure then return true, false, "disk full" end
            write(path, good_png)
            return true, true
        end,
    }
end }

local function load_wallpaper()
    return assert(loadfile(repo .. "/danxiangli_wallpaper.lua"))()
end

local Wallpaper = load_wallpaper()
local source = dir .. "20261106.jpg"
write(source, jpeg(591, 868, 194))
assert(Wallpaper.validate_source(source))
local initial_renders = renders
for _, oversized in ipairs({ jpeg(4097, 1), jpeg(3000, 3000), jpeg(0, 868) }) do
    write(source, oversized)
    assert(not Wallpaper.validate_source(source))
end
-- A small second frame must not hide an oversized unsupported first frame.
write(source, jpeg(6000, 6000, 195):sub(1, -3) .. jpeg(591, 868):sub(3))
assert(not Wallpaper.validate_source(source))
write(source, string.rep("x", Wallpaper.MAX_JPEG_BYTES + 1))
assert(not Wallpaper.validate_source(source))
assert(renders == initial_renders, "oversized input reached the decoder")
print("PASS JPEG byte and pixel limits are enforced before decoding")

write(source, jpeg(591, 868))
assert(Wallpaper.prepare(dir, source, "fullscreen"))
local target
for path in pairs(files) do if path:match("%.png$") then target = path end end
assert(target and read(target) == good_png)
Wallpaper = load_wallpaper()
local initial_png_decodes = png_decodes
assert(Wallpaper.prepare(dir, source, "fullscreen"))
assert(png_decodes == initial_png_decodes + 1)
assert(Wallpaper.prepare(dir, source, "fullscreen"))
assert(png_decodes == initial_png_decodes + 1, "unchanged PNG was decoded again")
write(target, bad_png, files[target].modification)
assert(Wallpaper.prepare(dir, source, "fullscreen"))
assert(png_decodes == initial_png_decodes + 3 and read(target) == good_png)
print("PASS a changed corrupt PNG is rebuilt from the JPEG without decoding unchanged cache entries")

local saved_attrs = files[target]
write(target, bad_png)
files[target] = saved_attrs
assert(Wallpaper.prepare(dir, source, "fullscreen", nil, true) and read(target) == good_png)
print("PASS an explicit cache check repairs corruption even when file attributes match")

-- Keep the usable PNG and remove the broken candidate if a rebuild fails.
local previous = dir .. "20261105-fullscreen-1-0x0-1-1.png"
write(previous, good_png)
write(target, bad_png, files[target].modification)
write_failure = true
local available, failure = Wallpaper.prepare(dir, source, "fullscreen")
assert(available and failure and read(previous) == good_png and not files[target])
print("PASS failed repair keeps the previous usable wallpaper")

-- A decoder exception alone does not establish that the file is corrupt.
Wallpaper = load_wallpaper()
png_decoder_failure = true
assert(not Wallpaper.prepare(dir, nil, "fullscreen") and read(previous) == good_png)
print("PASS a temporary decoder exception does not delete the prior PNG")

local paths = {}
for path in pairs(files) do paths[#paths + 1] = path end
for _, path in ipairs(paths) do assert(real_remove(path)) end
os.remove, os.rename = real_remove, real_rename
