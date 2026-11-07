-- Run with LuaJIT and LuaFileSystem: luajit tests/update_spec.lua /path/to/empty/scratch-dir
local ffi = require("ffi")
local lfs = require("lfs")
ffi.cdef[[int getpid(void);]]

local scratch = assert(arg[1], "Provide an existing scratch directory")
local plugin = "danxiangli.koplugin"
local url_prefix = "https://github.com/iamzhangjinpeng/" .. plugin .. "/releases/download/"
local asset_api_prefix = "https://api.github.com/repos/iamzhangjinpeng/" .. plugin .. "/releases/assets/"
local asset_id = 1234567890
local digest = string.rep("a", 64)
local data = "PK\3\4fixture ZIP"
local cert_names, release, responses, entries
local synced = 0

package.loaded["libs/libkoreader-lfs"] = lfs
package.loaded["ffi/util"] = {
    fsyncOpenedFile = function(file) synced = synced + 1; return file:flush() end,
    fsyncDirectory = function() return true end,
}
package.loaded.logger = { warn = function() end, err = function() end }
package.loaded.socketutil = { set_timeout = function() end }
package.loaded.dkjson = { decode = function() return release end }
package.loaded["ffi/sha2"] = { sha256 = function(value) return value == data and digest or "invalid" end }
package.loaded["ssl.https"] = {
    tcp = function(opts)
        assert(opts.verify == "peer" and opts.cafile == "data/ca-bundle.crt")
        return function()
            local certificate = {
                extensions = function()
                    return { ["2.5.29.17"] = { dNSName = cert_names } }
                end,
            }
            return {
                connect = function() return 1 end,
                sock = { getpeercertificate = function() return certificate end },
            }
        end
    end,
}
package.loaded["socket.http"] = {
    request = function(request)
        assert(package.loaded["socket.http"].PROXY == nil, "updater must use direct HTTPS")
        assert(request.redirect == false)
        local host = assert(request.url:match("^https://([^/]+)/"))
        local ok, err = request.create():connect(host, 443)
        if not ok then return nil, err end
        local response = assert(table.remove(responses, 1), "unexpected request")
        if response.url then assert(response.url == request.url, request.url) end
        if not request.sink(response.body or "response") then return nil, "size limit" end
        return 1, response.code or 200, { location = response.location }
    end,
}
package.loaded["ffi/archiver"] = {
    Reader = { new = function()
        return {
            open = function() return true end,
            close = function() end,
            iterate = function(reader)
                local index = 0
                return function()
                    index = index + 1
                    local entry = entries[index]
                    reader.entry = entry
                    return entry
                end
            end,
            extractToMemory = function(reader, path)
                assert(reader.entry.path == path)
                return reader.entry.contents
            end,
        }
    end },
}

local Update = require("danxiangli_update")
local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture_release(version)
    local filename = plugin .. "-v" .. version .. ".zip"
    cert_names = { "api.github.com" }
    release = {
        tag_name = "v" .. version, draft = false, prerelease = false,
        body = string.rep("新", 200) .. "\n下一行",
        assets = { { name = filename, id = asset_id, url = asset_api_prefix .. asset_id,
            state = "uploaded", digest = "sha256:" .. digest,
            size = #data, browser_download_url = url_prefix .. "v" .. version .. "/" .. filename } },
    }
    responses = { { code = 200 } }
end

local function entry(path, content, mode)
    return { path = plugin .. "/" .. path, size = #content, mode = mode or "file", contents = content }
end

local function fixture_archive()
    entries = {
        entry("", "", "directory"),
        entry("_meta.lua", 'return {\n    version = "1.10.0",\n}\n'),
        entry("main.lua", "return {}"),
        entry("danxiangli_update.lua", "return {}"),
        entry("danxiangli_wallpaper.lua", "return {}"),
        entry("assets/card-background.png", "image"),
        entry("assets/", "", "directory"),
    }
end

local function fixture_download()
    fixture_archive()
    cert_names = { "api.github.com", "*.githubusercontent.com" }
    responses = {
        { url = asset_api_prefix .. asset_id, code = 302,
            location = "https://release-assets.githubusercontent.com/object?key=value" },
        { url = "https://release-assets.githubusercontent.com/object?key=value", body = data },
    }
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

local tests = 0
local function test(name, fn)
    fn()
    tests = tests + 1
    print("PASS " .. name)
end

test("compares version segments numerically and limits the metadata passed to the UI", function()
    fixture_release("1.10.0")
    local result = assert(Update.parse_result(Update.check("1.9.2")))
    eq(result.version, "1.10.0")
    eq(result.digest, digest)
    eq(result.size, #data)
    eq(result.asset_id, tostring(asset_id))
    eq(result.notes, string.rep("新", 160) .. "…")
    fixture_release("1.10.0")
    release.body = "第一行\n第二行"
    eq(assert(Update.parse_result(Update.check("1.9.2"))).notes, release.body)
    fixture_release("1.9.2")
    eq(Update.check("1.10.0"), "current")
    fixture_release("1.10.0")
    eq(Update.check("1.10.0"), "current")
end)

test("rejects drafts, malformed versions, missing assets, and invalid digests", function()
    fixture_release("1.10.0")
    release.prerelease = true
    eq(Update.check("1.5.0"), "bad_release")
    fixture_release("1.10.0-rc1")
    eq(Update.check("1.5.0"), "bad_release")
    fixture_release("1.10.0")
    release.assets[1].browser_download_url = "https://other.example/package.zip"
    eq(Update.check("1.5.0"), "missing_asset")
    fixture_release("1.10.0")
    release.assets[1].digest = nil
    eq(Update.check("1.5.0"), "bad_release")
    fixture_release("1.10.0")
    release.assets[1].id = 1.5
    eq(Update.check("1.5.0"), "bad_release")
    fixture_release("1.10.0")
    release.assets[1].url = asset_api_prefix .. "123"
    eq(Update.check("1.5.0"), "bad_release")
end)

test("separates TLS and HTTP failure from an up-to-date result", function()
    fixture_release("1.10.0")
    cert_names = { "*.com", "*.unrelated.github.com" }
    eq(Update.check("1.10.0"), "network_error")
    fixture_release("1.10.0")
    responses = { { code = 429 } }
    eq(Update.check("1.10.0"), "http_429")
    fixture_release("1.10.0")
    responses = { { body = string.rep("x", 256 * 1024 + 1) } }
    eq(Update.check("1.10.0"), "too_large")
end)

local function installed_fixture()
    local root = scratch .. "/case-" .. tests
    assert(lfs.mkdir(root))
    local paths = assert(Update.paths(root .. "/" .. plugin))
    assert(lfs.mkdir(paths.live))
    write(paths.live .. "/main.lua", "old version")
    local stage = assert(Update.make_stage(paths))
    local candidate = { version = "1.10.0", size = #data, digest = digest, asset_id = tostring(asset_id) }
    return paths, stage, candidate
end

test("clears the HTTP proxy and downloads release assets through the API", function()
    local http = require("socket.http")
    fixture_release("1.10.0")
    http.PROXY = "http://127.0.0.1:8080"
    assert(Update.parse_result(Update.check("1.5.0")))
    eq(http.PROXY, nil)

    local paths, stage = installed_fixture()
    http.PROXY = "http://127.0.0.1:8080"
    fixture_download()
    local candidate = { version = "1.10.0", size = #data, digest = digest, asset_id = tostring(asset_id) }
    eq(Update.prepare(stage, candidate), "prepared")
    eq(http.PROXY, nil)
    Update.remove_stage(paths, stage)
end)

test("validates, extracts, and replaces the directory while retaining the backup", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    synced = 0
    eq(Update.prepare(stage, candidate), "prepared")
    eq(synced, 5)
    eq(Update.has_backup(paths), false)
    eq(Update.install(paths, stage), "installed")
    eq(Update.has_backup(paths), true)
    eq(lfs.attributes(paths.live .. "/danxiangli_update.lua", "mode"), "file")
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
    Update.remove_stage(paths, stage)
    eq(lfs.attributes(paths.work), nil)
    Update.clean_after_start(paths, true)
    eq(lfs.attributes(paths.backup), nil)
    eq(Update.has_backup(paths), false)
    eq(lfs.attributes(paths.live, "mode"), "directory")
end)

test("rejects unexpected redirect hosts and hash mismatches before staging files", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    responses[1].location = "https://release-assets.githubusercontent.com.evil.example/asset"
    eq(Update.prepare(stage, candidate), "redirect_error")
    fixture_download()
    candidate.digest = string.rep("b", 64)
    eq(Update.prepare(stage, candidate), "bad_digest")
    eq(lfs.attributes(stage .. "/new"), nil)
    Update.remove_stage(paths, stage)
end)

test("rejects traversal, case collisions, symlinks, and invalid Lua", function()
    local paths, stage, candidate = installed_fixture()
    local invalid = {
        entry("../escape", "no"),
        entry("ASSETS/new", "no"),
        entry("bad-link", "target", "link"),
        entry("bad.lua", "return %"),
    }
    for i, invalid_entry in ipairs(invalid) do
        if i > 1 then stage = assert(Update.make_stage(paths)) end
        fixture_download()
        entries[#entries + 1] = invalid_entry
        eq(Update.prepare(stage, candidate), "bad_zip")
        eq(lfs.attributes(paths.live .. "/escape"), nil)
        eq(lfs.attributes(paths.backup), nil)
        Update.remove_stage(paths, stage)
    end
end)

test("rejects a missing required file, version mismatch, and expansion over the cap", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    table.remove(entries, 6)
    eq(Update.prepare(stage, candidate), "bad_zip")
    Update.remove_stage(paths, stage)
    stage = assert(Update.make_stage(paths))
    fixture_download()
    entries[2] = entry("_meta.lua", 'return {\n    version = "1.5.0",\n}\n')
    eq(Update.prepare(stage, candidate), "bad_zip")
    Update.remove_stage(paths, stage)
    stage = assert(Update.make_stage(paths))
    fixture_download()
    entries[3].size = 4 * 1024 * 1024 + 1
    eq(Update.prepare(stage, candidate), "bad_zip")
    Update.remove_stage(paths, stage)
end)

test("restores the previous directory if the second rename fails", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    eq(Update.prepare(stage, candidate), "prepared")
    local real_rename = os.rename
    os.rename = function(source, destination)
        if source == stage .. "/new" then return nil, "simulated rename error" end
        return real_rename(source, destination)
    end
    local ok, status = pcall(Update.install, paths, stage)
    os.rename = real_rename
    assert(ok, status)
    eq(status, "install_error")
    local old = assert(io.open(paths.live .. "/main.lua", "rb"))
    eq(old:read("*a"), "old version")
    old:close()
    eq(lfs.attributes(paths.backup), nil)
    Update.remove_stage(paths, stage)
end)

test("retains recovery directory if automatic rollback also fails", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    eq(Update.prepare(stage, candidate), "prepared")
    local real_rename = os.rename
    os.rename = function(source, destination)
        if destination == paths.live then return nil, "simulated rename error" end
        return real_rename(source, destination)
    end
    local ok, status = pcall(Update.install, paths, stage)
    os.rename = real_rename
    assert(ok, status)
    eq(status, "restore_error")
    eq(lfs.attributes(paths.live), nil)
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
    Update.remove_stage(paths, stage)
    Update.clean_after_start(paths, true)
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
end)

test("unhealthy startup only removes staging and blocks another replacement", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    eq(Update.prepare(stage, candidate), "prepared")
    eq(Update.install(paths, stage), "installed")
    Update.clean_after_start(paths, false)
    eq(lfs.attributes(paths.work), nil)
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
    local next_stage, err = Update.make_stage(paths)
    eq(next_stage, nil)
    eq(err, "backup_pending")
    Update.clean_after_start(paths, true)
    eq(lfs.attributes(paths.backup), nil)
end)

test("a sync error preserves the backup and stays distinct from installation success", function()
    local paths, stage, candidate = installed_fixture()
    fixture_download()
    eq(Update.prepare(stage, candidate), "prepared")
    local util = require("ffi/util")
    local sync_directory = util.fsyncDirectory
    util.fsyncDirectory = function() return false, "simulated I/O failure" end
    eq(Update.install(paths, stage), "sync_error")
    eq(lfs.attributes(paths.live .. "/main.lua", "mode"), "file")
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
    Update.clean_after_start(paths, true)
    eq(lfs.attributes(paths.backup .. "/main.lua", "mode"), "file")
    util.fsyncDirectory = sync_directory
    Update.clean_after_start(paths, true)
    eq(lfs.attributes(paths.backup), nil)
end)

print("All " .. tests .. " updater checks passed")
