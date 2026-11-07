-- Run with LuaJIT and LuaFileSystem: luajit tests/wallpaper_spec.lua /path/to/empty/scratch-dir
-- Exercise the real cache and header checks with simulated KOReader decoders.
local dir = assert(arg and arg[1], "Provide an existing scratch directory") .. "/"
local repo = (arg and arg[2]) or "."
local fs = require("lfs")
local display = dir .. "display/"
local displayed = display .. "wallpaper.png"
local real_remove, real_rename = os.remove, os.rename
local files, clock = {}, 0
local renders, png_decodes = 0, 0
local write_failure, png_decoder_failure, png_open_failure
local blocked_rename
local unchanged_rename

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
    if from == blocked_rename then return nil, "rename blocked" end
    local ok, err = real_rename(from, to)
    if ok then
        if to ~= unchanged_rename then files[to] = files[from] end
        files[from] = nil
    end
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
        local attrs = files[path] or fs.attributes(path)
        if key then return attrs and attrs[key] end
        return attrs
    end,
    dir = fs.dir,
}
package.loaded.logger = { warn = function() end }
package.loaded.util = { makePath = function(path)
    assert(path == dir or path == display)
    return fs.attributes(path, "mode") == "directory" or fs.mkdir(path)
end }
package.loaded.ffi = { C = { free = function(data) assert(data == "pixels") end } }
package.loaded["ffi/png"] = { decodeFromFile = function(path, channels)
    assert(channels == 1)
    png_decodes = png_decodes + 1
    if png_open_failure == path then return false, "couldn't open PNG file" end
    if png_decoder_failure == true or png_decoder_failure == path then error("decoder unavailable") end
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
local function prepare(source, refresh, verify)
    return Wallpaper.prepare(dir, source, "fullscreen", refresh, verify, display)
end
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
assert(prepare(source))
local target
for path in pairs(files) do if path:match("%.png$") then target = path end end
assert(target and read(target) == good_png and read(displayed) == good_png)
Wallpaper = load_wallpaper()
local initial_png_decodes = png_decodes
assert(prepare(source))
assert(png_decodes == initial_png_decodes + 2)
assert(prepare(source))
assert(png_decodes == initial_png_decodes + 2, "unchanged PNG was decoded again")
write(target, bad_png, files[target].modification)
assert(prepare(source))
assert(png_decodes == initial_png_decodes + 5 and read(target) == good_png and read(displayed) == good_png)
print("PASS a changed corrupt PNG is rebuilt from the JPEG without decoding unchanged cache entries")

local saved_attrs = files[target]
write(target, bad_png)
files[target] = saved_attrs
assert(prepare(source, nil, true) and read(target) == good_png)
print("PASS an explicit cache check repairs corruption even when file attributes match")

unchanged_rename = target
local before_refresh = png_decodes
assert(prepare(source, true))
assert(png_decodes == before_refresh + 2, "freshly rendered data must also be published")
unchanged_rename = nil
print("PASS a fresh render is published even when cache file attributes are unchanged")

-- Post-update startup can force a rebuild even when the old PNG is valid.
write_failure = true
local render_count = renders
local available, failure = prepare(source, true)
assert(available and failure and renders == render_count + 1 and read(target) == good_png)
write_failure = false
print("PASS a forced rebuild reports failure while preserving a valid cached wallpaper")

-- Keep the usable PNG and remove the broken candidate if a rebuild fails.
local previous = dir .. "20261105-fullscreen-1-0x0-1-1.png"
write(previous, good_png)
write(target, bad_png, files[target].modification)
write_failure = true
available, failure = prepare(source)
assert(available and failure and read(previous) == good_png and not files[target])
print("PASS failed repair keeps the previous usable wallpaper")

-- A decoder exception alone does not establish that the file is corrupt.
Wallpaper = load_wallpaper()
png_decoder_failure = true
available, failure = prepare()
assert(not available and failure and read(previous) == good_png and read(displayed) == good_png)
print("PASS a temporary decoder failure preserves cached and previously verified display files")

local newer = dir .. "20261107-fullscreen-1-0x0-999-999.png.pending"
local corrupt = dir .. "20261107-fullscreen-1-0x0-999-999.png"
write(newer, good_png)
write(corrupt, bad_png)
Wallpaper = load_wallpaper()
png_decoder_failure = nil
png_open_failure = newer
available, failure = prepare()
assert(available and not failure and not files[corrupt])
assert(read(previous) == good_png and read(newer) == good_png and read(displayed) == good_png)
print("PASS fallback removes confirmed corruption and keeps a temporarily unreadable cache")

local oldest = dir .. "20261104-fullscreen-1-0x0-1-1.png"
write(oldest, bad_png)
blocked_rename = oldest
assert(prepare())
assert(read(oldest) == bad_png and read(displayed) == good_png)
for name in fs.dir(display) do assert(name == "." or name == ".." or name == "wallpaper.png") end
blocked_rename = nil
print("PASS an immovable corrupt cache file is outside KOReader's image list")

local older_source = dir .. "20261105.jpg"
write(older_source, jpeg(591, 868))
write_failure = false
assert(prepare(older_source))
assert(prepare(older_source) and read(newer) == good_png)
print("PASS generating and reusing an older wallpaper retains a newer unverified cache")

blocked_rename = displayed .. ".tmp"
png_open_failure = nil
available, failure = prepare(older_source)
assert(available and failure and read(newer) == good_png and read(displayed) == good_png)
assert(not fs.attributes(displayed .. ".tmp"))
blocked_rename = nil
local decoded_before = png_decodes
assert(prepare(older_source) and png_decodes > decoded_before)
assert(read(displayed) == good_png and read(newer) == good_png)
print("PASS a recovered newer cache can be displayed and a failed publish preserves the previous display")

local paths = {}
for path in pairs(files) do paths[#paths + 1] = path end
for _, path in ipairs(paths) do assert(real_remove(path)) end
assert(real_remove(displayed))
assert(fs.rmdir(display))
os.remove, os.rename = real_remove, real_rename
