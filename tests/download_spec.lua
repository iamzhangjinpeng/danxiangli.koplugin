-- Run from the plugin directory: lua tests/download_spec.lua /path/to/empty/scratch-dir
-- Public-entry-point regression checks with virtual child processes and time.
-- IO uses temporary files; no requests are sent and no Kindle files are changed.
local real_open, real_time, real_rename = io.open, os.time, os.rename
local main_path = (arg and arg[2]) or "main.lua"
local tmp_root = assert(arg and arg[1], "Provide an existing scratch directory as the first argument")
local input = assert(real_open(main_path, "rb"))
local source = input:read("*a")
input:close()
local jpeg = "\255\216" .. string.rep("x", 2048) .. "\255\217"
local broken_jpeg = "\255\216" .. string.rep("?", 2048) .. "\255\217"
local epoch = 1793404800
local fixture_count = 0
local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture(options)
    options = options or {}
    fixture_count = fixture_count + 1
    local base = tmp_root .. "/case-" .. fixture_count
    local f = { now = 0, queue = {}, jobs = {}, instances = {}, count = 0, locks = 0,
        closes = 0, bytes_written = 0, reads = 0, requests = 0, files = {}, messages = {}, prefix = base .. "-", options = options }
    os.time = function(t) return t and real_time(t) or epoch + math.floor(f.now) + (f.wall_shift or 0) end
    local function today_name(suffix) return os.date("!%Y%m%d", os.time() + 8 * 3600) .. (suffix or ".jpg") end
    function f:read_named(name)
        local h = real_open(self.prefix .. name, "rb")
        if not h then return nil end
        local body = h:read("*a")
        h:close()
        return body
    end
    function f:read(suffix) return self:read_named(today_name(suffix)) end
    function f:write_named(name, body)
        local h = assert(real_open(self.prefix .. name, "wb"))
        h:write(body)
        h:close()
        self.files[name] = true
    end
    function f:write(body, suffix) self:write_named(today_name(suffix), body) end
    io.open = function(name, mode)
        local h, err = real_open(name, mode)
        if not h or mode ~= "wb" or not name:find(f.prefix, 1, true) then return h, err end
        f.files[name:sub(#f.prefix + 1)] = true
        return {
            write = function(_, chunk)
                if f.options.write_fail then return nil, "disk full" end
                f.bytes_written = f.bytes_written + #chunk
                return h:write(chunk)
            end,
            close = function()
                f.closes = f.closes + 1
                local ok, close_err = h:close()
                if f.options.close_fail then return nil, "close failed" end
                return ok, close_err
            end,
        }
    end
    os.rename = function(from, to)
        local ok, err = real_rename(from, to)
        if ok and from:find(f.prefix, 1, true) and to:find(f.prefix, 1, true) then
            f.files[from:sub(#f.prefix + 1)] = nil
            f.files[to:sub(#f.prefix + 1)] = true
        end
        return ok, err
    end
    local ui = {}
    function ui:scheduleIn(delay, cb)
        table.insert(f.queue, { at = f.now + delay, cb = cb })
        assert(#f.queue <= 1, "more than one scheduled task")
    end
    function ui:unschedule(cb)
        for i = #f.queue, 1, -1 do
            if f.queue[i].cb == cb then table.remove(f.queue, i) end
        end
    end
    function ui:preventStandby() f.locks = f.locks + 1 end
    function ui:allowStandby() f.locks = f.locks - 1; assert(f.locks >= 0) end
    function ui:show(message)
        table.insert(f.messages, message.text)
        if message.ok_callback then f.confirmation = message end
    end
    function ui:close(widget)
        if f.confirmation == widget then f.confirmation = nil end
    end
    function ui:askForRestart(message) f.restart_message = message end
    function f:advance(seconds)
        local target, steps = self.now + seconds, 0
        while self.queue[1] and self.queue[1].at <= target + 0.000001 do
            local event = table.remove(self.queue, 1)
            self.now = event.at
            event.cb()
            steps = steps + 1
            assert(steps < 100000, "scheduler busy loop")
        end
        self.now = target
    end

    local ffiutil = {}
    function ffiutil.runInSubProcess(task)
        if options.fork_fail then
            if options.fail_midnight then
                options.fork_fail = false
                f.wall_shift = 86400
            end
            return false, "fork failed"
        end
        for _, job in pairs(f.jobs) do assert(job.done, "new writer started before old writer exited") end
        f.count = f.count + 1
        local pid = f.count
        f.jobs[pid] = { task = task, output = "", response = (options.responses or {})[pid] or { code = 200 } }
        return pid, pid
    end
    function ffiutil.writeToFD(fd, output) f.jobs[fd].output = output; return true end
    function ffiutil.isSubProcessDone(pid)
        local job = f.jobs[pid]
        if job.done then job.reaped = true end
        return job.done or false
    end
    function ffiutil.terminateSubProcess(pid)
        local job = f.jobs[pid]
        if not job.done then
            job.kill_attempts = (job.kill_attempts or 0) + 1
            if job.kill_attempts <= (options.kill_misses or 0) then return end
            job.killed = true
            if not options.delay_kill then job.done = true end
        end
    end
    function ffiutil.readAllFromFD(fd)
        local job = f.jobs[fd]
        assert(job.done, "blocking read before child exit")
        f.reads = f.reads + 1
        job.closed = true
        return job.output
    end
    function f:complete(pid)
        local job = assert(self.jobs[pid])
        assert(not job.done and not job.killed)
        self.response = job.response
        job.task(pid, pid)
        job.done = true
    end
    local socketutil = {}
    function socketutil:set_timeout(block, total)
        eq(block, 20, "HTTP block timeout")
        eq(total, 20, "HTTP total timeout")
        f.timeout_set = true
    end
    local http = {}
    function http.request(request)
        f.requests = f.requests + 1
        assert(f.timeout_set, "network timeout not configured")
        eq(request.headers.Referer, "https://img.owspace.com/", "Referer")
        assert(request.redirect)
        local response = f.response
        if response.error then return nil, response.error end
        local body = response.body or (response.code == 200 and jpeg or "not found")
        for _, chunk in ipairs(response.chunks or { body }) do
            local ok, err = request.sink(chunk)
            if not ok then return nil, err end
        end
        local ok, err = request.sink(nil)
        if not ok then return nil, err end
        return 1, response.code
    end
    local settings = { data = { danxiangli_auto_screensaver = false } }
    function settings:readSetting(k) return self.data[k] end
    function settings:saveSetting(k, v) self.data[k] = v end
    function settings:delSetting(k) self.data[k] = nil end
    function settings:flush() end
    function settings:isTrue(k) return self.data[k] == true end
    G_reader_settings = settings
    f.settings = settings
    local function validate_source(path)
        local file = assert(real_open(path, "rb"))
        local data = file:read("*a")
        file:close()
        return data == jpeg, "decoder rejected file"
    end
    local modules = {
        ["ui/widget/container/widgetcontainer"] = { extend = function(_, t) return t end },
        ["ui/uimanager"] = ui,
        ["ui/widget/infomessage"] = { new = function(_, t) return t end },
        ["ui/widget/confirmbox"] = { new = function(_, t) return t end },
        ["logger"] = { info = function() end, warn = function() end, dbg = function() end },
        ["util"] = { makePath = function() end },
        ["socket.http"] = http,
        ["socketutil"] = socketutil,
        ["ffi/util"] = ffiutil,
        ["ui/time"] = { to_s = function(v) return v end, boottime_or_monotonic = function() return f.now end },
        ["ui/network/manager"] = { isConnected = function() return true end, isWifiOn = function() return true end },
        ["gettext"] = function(v) return v end,
        ["danxiangli_wallpaper"] = {
            MAX_JPEG_BYTES = 4 * 1024 * 1024,
            validate_source = validate_source,
            prepare = function(dir, source_path, style, refresh)
                if options.prepare_wallpaper then return options.prepare_wallpaper(dir, source_path, style, refresh) end
                if source_path and not validate_source(source_path) then return false, "decoder rejected file", true end
                return false
            end,
        },
        ["libs/libkoreader-lfs"] = {
            dir = function(path)
                eq(path, f.prefix, "scan stays inside plugin directory")
                local names = {}
                for name in pairs(f.files) do names[#names + 1] = name end
                local i = 0
                return function() i = i + 1; return names[i] end
            end,
            attributes = function(path, attr)
                eq(attr, "mode")
                if path == f.prefix then return "directory" end
                local h = real_open(path, "rb")
                if h then h:close(); return "file" end
            end,
        },
    }
    package.loaded.danxiangli_update = options.update
    for name, module in pairs(modules) do package.loaded[name] = module end
    local code = source:gsub('local SAVE_DIR = "[^"]+"', 'local SAVE_DIR = ' .. string.format("%q", f.prefix))
    local plugin = assert(loadstring(code, "@main.lua"))()
    function f:new_instance()
        local obj = setmetatable({ ui = { menu = { registerToMainMenu = function() end } },
            path = options.update and "plugins/danxiangli.koplugin", version = "1.5.0" }, { __index = plugin })
        obj:init()
        table.insert(self.instances, obj)
        return obj
    end
    function f:cleanup()
        for _, instance in ipairs(self.instances) do instance:_cancel_scheduled_work() end
        for _, job in pairs(self.jobs) do job.done = true end
        self:advance(0.25)
        eq(#self.queue, 0, "timer cleanup")
        eq(self.locks, 0, "standby lock cleanup")
        for name in pairs(self.files) do os.remove(self.prefix .. name) end
        io.open, os.time, os.rename = real_open, real_time, real_rename
    end
    for name, body in pairs(options.files or {}) do f:write_named(name, body) end
    if options.today_image then f:write(options.today_image) end
    f.instance = f:new_instance()
    return f
end

local test_count = 0
local function test(name, body)
    body()
    test_count = test_count + 1
    print("PASS " .. name)
end

test("HTTP 200 succeeds, closes once, and skips repeat downloads", function()
    local f = fixture()
    f.instance:_run()
    eq(f.requests, 0, "background start returns before network")
    f:complete(1)
    f:advance(0.125)
    eq(f.instance._last_status, "ok")
    eq(f.closes, 1)
    eq(f:read(), jpeg)
    eq(f:read(".jpg.tmp"), nil)
    f:advance(610)
    eq(f.count, 1)
    f:cleanup()
end)

test("404 enters cooldown and manual download bypasses it", function()
    local f = fixture({ responses = { { code = 404 }, { code = 200 } } })
    f.instance:_run()
    f:complete(1)
    f:advance(0.125)
    eq(f.instance._last_status, "http_404")
    eq(f.instance._retry_at, nil)
    eq(f:read(".jpg.tmp"), nil)
    f.instance:_run()
    eq(f.count, 1)
    f.instance:download_today()
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(f.instance._last_status, "ok")
    f:cleanup()
end)

test("hard deadline kills worker; lock and old image survive until reaped", function()
    local f = fixture({ delay_kill = true })
    f:write_named("20000101.jpg", jpeg)
    f.instance:download_today()
    f:write("partial", ".jpg.tmp")
    f:advance(19.875)
    assert(not f.jobs[1].killed)
    f:advance(0.125)
    assert(f.jobs[1].killed)
    eq(f.reads, 0)
    assert(f.instance._busy)
    f.instance:download_today()
    eq(f.count, 1)
    f.jobs[1].done = true
    f:advance(0.125)
    eq(f.instance._last_status, "timeout")
    assert(not f.instance._busy)
    assert(f.instance._retry_at)
    eq(f:read_named("20000101.jpg"), jpeg)
    eq(f:read(".jpg.tmp"), nil)
    eq(f.locks, 0)
    f:cleanup()
end)

test("stopping cancels and reaps without leaving timers or temp files", function()
    local f = fixture({ delay_kill = true })
    f.instance:_run()
    f:write("partial", ".jpg.tmp")
    f.instance:stopPlugin()
    assert(f.jobs[1].killed)
    eq(f.reads, 0)
    eq(#f.queue, 1, "only reaping remains")
    f.jobs[1].done = true
    f:advance(0.125)
    assert(f.jobs[1].reaped and f.jobs[1].closed)
    eq(#f.queue, 0)
    eq(f:read(".jpg.tmp"), nil)
    eq(f.locks, 0)
    f:cleanup()
end)

test("UI transition waits for old writer exit before starting replacement", function()
    local f = fixture({ delay_kill = true })
    f.instance:_run()
    local current = f:new_instance()
    current:_run()
    eq(f.count, 1)
    f.jobs[1].done = true
    f:advance(0.125)
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(current._last_status, "ok")
    eq(f:read(), jpeg)
    f:cleanup()
end)

test("cancellation retries when initial kill races child startup", function()
    local f = fixture({ kill_misses = 1 })
    f.instance:_run()
    f.instance:stopPlugin()
    assert(not f.jobs[1].killed)
    f:advance(0.25)
    assert(f.jobs[1].killed and f.jobs[1].reaped)
    eq(f.jobs[1].kill_attempts, 2)
    eq(#f.queue, 0)
    eq(f.locks, 0)
    f:cleanup()
end)

test("late old success cannot replace current file after UI transition", function()
    local f = fixture()
    local old_image = "previous incomplete image"
    f:write(old_image)
    f.instance:download_today()
    f:complete(1)
    local current = f:new_instance()
    f:advance(0.125)
    eq(f:read(), old_image)
    eq(f:read(".jpg.tmp"), nil)
    current:download_today()
    f:complete(2)
    f:advance(0.125)
    eq(f:read(), jpeg)
    f:cleanup()
end)

test("completed 404 retains cooldown across UI transition", function()
    local f = fixture({ responses = { { code = 404 } } })
    f.instance:_run()
    f:complete(1)
    local current = f:new_instance()
    current:_run()
    f:advance(0.125)
    current:_run()
    eq(f.count, 1)
    f:cleanup()
end)

for _, case in ipairs({
    { name = "invalid JPEG", options = { responses = { { code = 200, body = "broken" } } }, status = "invalid_file" },
    { name = "undecodable JPEG with valid markers", options = { responses = { { code = 200, body = broken_jpeg } } }, status = "invalid_file" },
    { name = "network failure", options = { responses = { { error = "connect failed" } } }, status = "network_error" },
    { name = "write failure", options = { write_fail = true }, status = "open_error" },
    { name = "close failure", options = { close_fail = true }, status = "open_error" },
}) do
    test(case.name .. " preserves previous files", function()
        local f = fixture(case.options)
        local old_image = "previous incomplete image"
        f:write(old_image)
        f:write_named("20000101.jpg", jpeg)
        f.instance:download_today()
        f:complete(1)
        f:advance(0.125)
        eq(f.instance._last_status, case.status)
        eq(f.closes, 1)
        eq(f:read(), old_image)
        eq(f:read_named("20000101.jpg"), jpeg)
        eq(f:read(".jpg.tmp"), nil)
        f:cleanup()
    end)
end

test("an undecodable cached JPEG is replaced only after a valid retry", function()
    local f = fixture({ today_image = jpeg, responses = { { code = 200, body = broken_jpeg }, { code = 200 } } })
    f:advance(8)
    eq(f.count, 0)
    f:write(broken_jpeg)
    f:write_named("20000101.jpg", jpeg)
    f.instance:download_today()
    eq(f.count, 1)
    assert(f.instance:_diagnostics():find("今日图片: 文件损坏", 1, true))
    f:complete(1)
    f:advance(0.125)
    eq(f.instance._last_status, "invalid_file")
    eq(f:read(), broken_jpeg)
    eq(f:read_named("20000101.jpg"), jpeg)
    f:advance(10.25)
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(f:read(), jpeg)
    eq(f:read_named("20000101.jpg"), nil)
    assert(f.instance:_diagnostics():find("今日图片: 已就绪", 1, true))
    f:cleanup()
end)

test("a response over the byte limit is stopped before writing the excess chunk", function()
    local block = string.rep("x", 2 * 1024 * 1024)
    local f = fixture({ responses = { { code = 200, chunks = { block, block, "excess" } } } })
    f:write_named("20000101.jpg", jpeg)
    f.instance:download_today()
    f:complete(1)
    f:advance(0.125)
    eq(f.bytes_written, 4 * 1024 * 1024)
    eq(f.instance._last_status, "file_too_large")
    eq(f:read_named("20000101.jpg"), jpeg)
    eq(f:read(".jpg.tmp"), nil)
    f:cleanup()
end)

test("a wallpaper write failure does not trigger another download", function()
    local f = fixture({
        prepare_wallpaper = function(_, path)
            return false, path and "disk full"
        end,
    })
    f.instance:download_today()
    f:complete(1)
    f:advance(0.125)
    eq(f:read(), jpeg)
    f.instance:download_today()
    eq(f.count, 1)
    assert(f.messages[#f.messages]:find("壁纸生成失败", 1, true))
    f:cleanup()
end)

test("fork failure releases request without reading invalid fd", function()
    local f = fixture({ fork_fail = true })
    f.instance:_run()
    eq(f.instance._last_status, "network_error")
    assert(not f.instance._busy)
    eq(f.reads, 0)
    eq(f.locks, 0)
    f:cleanup()
end)

test("startup failure across date change keeps replacement worker cancellable", function()
    local f = fixture({ fork_fail = true, fail_midnight = true })
    f.instance:_run()
    eq(f.count, 1, "replacement started")
    assert(f.instance._busy, "replacement is busy")
    assert(f.instance._download_worker, "replacement worker handle was overwritten")
    f.instance:stopPlugin()
    assert(f.jobs[1].killed, "replacement was not cancelled")
    f:cleanup()
end)

test("one manual menu entry reuses valid current image", function()
    local f = fixture({ today_image = jpeg })
    local items = {}
    f.instance:addToMainMenu(items)
    eq(#items.danxiangli.sub_item_table, 5)
    eq(items.danxiangli.sub_item_table[2].text, "下载今日单向历")
    items.danxiangli.sub_item_table[2].callback()
    eq(f.count, 0)
    eq(f.messages[#f.messages], "今日单向历已存在")
    eq(f:read(), jpeg)
    eq(f.instance.force_redownload, nil)
    f:cleanup()
end)

test("switching wallpaper style uses the local JPEG and remembers the selection", function()
    local latest
    local f = fixture({
        files = { ["20000101.jpg"] = jpeg },
        prepare_wallpaper = function(dir, path, style)
            latest = { dir = dir, path = path, style = style }
            return path ~= nil
        end,
    })
    local items = {}
    f.instance:addToMainMenu(items)
    local menu = items.danxiangli.sub_item_table
    local fullscreen, card = unpack(menu[3].sub_item_table)
    assert(fullscreen.checked_func())
    eq(latest.path, f.prefix .. "20000101.jpg")
    card.callback()
    assert(card.checked_func())
    eq(latest.style, "card")
    eq(latest.path, f.prefix .. "20000101.jpg")
    eq(f.settings:readSetting("screensaver_dir"), nil)
    eq(f.count, 0)
    menu[1].callback()
    eq(f.settings:readSetting("screensaver_dir"), latest.dir)
    f:new_instance()
    eq(latest.style, "card")
    eq(f.count, 0)
    f:cleanup()
end)

test("screensaver uses only generated wallpapers even when rendering fails", function()
    local f = fixture({
        today_image = jpeg,
        prepare_wallpaper = function() return false, "rendering failed" end,
    })
    local items = {}
    f.instance:addToMainMenu(items)
    f.settings:saveSetting("screensaver_dir", "/original/")
    items.danxiangli.sub_item_table[1].callback()
    eq(f.settings:readSetting("screensaver_dir"), f.prefix .. "wallpaper/")
    f.instance:stopPlugin()
    eq(f.settings:readSetting("screensaver_dir"), "/original/")
    f:cleanup()
end)

test("manual retry bypasses cooldown while automatic checks respect it", function()
    local f = fixture({ responses = { { code = 404 }, { error = "connect failed" }, { code = 200 } } })
    f:write_named("20000101.jpg", jpeg)
    f.instance:_run()
    f:complete(1)
    f:advance(0.125)
    eq(f:read_named("20000101.jpg"), jpeg)
    f.instance:download_today()
    f:complete(2)
    f:advance(0.125)
    assert(f.instance._retry_at)
    f.instance:_run()
    eq(f.count, 2, "automatic check stays in cooldown")
    assert(f.instance._retry_at, "automatic check preserves manual retry")
    f:advance(10)
    eq(f.count, 3, "manual retry bypasses earlier 404 cooldown")
    f:complete(3)
    f:advance(0.125)
    eq(f.instance._last_status, "ok")
    eq(f:read(), jpeg)
    eq(f:read_named("20000101.jpg"), nil)
    f:cleanup()
end)

test("retry stops when a valid current image becomes available", function()
    local f = fixture({ responses = { { error = "connect failed" } } })
    f.instance:download_today()
    f:complete(1)
    f:advance(0.125)
    f:write(jpeg)
    f:advance(10)
    eq(f.count, 1)
    eq(f.instance._retry_at, nil)
    f:cleanup()
end)

test("startup removes only dated temporary files even with current image ready", function()
    local f = fixture({ today_image = jpeg, files = {
        ["20000101.jpg.tmp"] = "interrupted download",
        ["20000102.jpg.tmp"] = "another interrupted download",
        ["20000101.jpg"] = jpeg,
        ["notes.tmp"] = "keep",
        ["20000101.jpg.tmp.backup"] = "keep",
        ["123.jpg.tmp"] = "keep",
    } })
    eq(f:read_named("20000101.jpg.tmp"), nil)
    eq(f:read_named("20000102.jpg.tmp"), nil)
    eq(f:read_named("20000101.jpg"), jpeg)
    eq(f:read_named("notes.tmp"), "keep")
    eq(f:read_named("20000101.jpg.tmp.backup"), "keep")
    eq(f:read_named("123.jpg.tmp"), "keep")
    eq(f:read(), jpeg)
    f:advance(8)
    eq(f.count, 0)
    f:cleanup()
end)

test("startup also removes leftovers when today's image is missing", function()
    local f = fixture({ files = { ["20000101.jpg.tmp"] = "interrupted download" } })
    eq(f:read_named("20000101.jpg.tmp"), nil)
    f:advance(8)
    eq(f.count, 1)
    f:complete(1)
    f:advance(0.125)
    eq(f:read(), jpeg)
    f:cleanup()
end)

test("UI transition defers temporary-file cleanup until old writer exits", function()
    local f = fixture({ delay_kill = true })
    f.instance:download_today()
    f:write("active partial image", ".jpg.tmp")
    f:write_named("20000101.jpg.tmp", "stale")
    f:new_instance()
    eq(f:read(".jpg.tmp"), "active partial image")
    eq(f:read_named("20000101.jpg.tmp"), "stale")
    eq(f.reads, 0)
    f.jobs[1].done = true
    f:advance(0.125)
    eq(f:read(".jpg.tmp"), nil)
    eq(f:read_named("20000101.jpg.tmp"), nil)
    f:cleanup()
end)

local function update_fixture(options)
    local counts = { checks = 0, prepared = 0, installed = 0, cleaned = 0, started = 0 }
    options = options or {}
    options.update = {
        paths = function(path) return { live = path } end,
        clean_after_start = function() counts.started = counts.started + 1 end,
        check = function(version) eq(version, "1.5.0"); counts.checks = counts.checks + 1; return "available" end,
        parse_result = function(status)
            if status == "available" then return { version = "1.6.0", notes = "更新说明" } end
        end,
        make_stage = function() return "stage" end,
        prepare = function() counts.prepared = counts.prepared + 1; return "prepared" end,
        install = function() counts.installed = counts.installed + 1; return "installed" end,
        remove_stage = function() counts.cleaned = counts.cleaned + 1 end,
    }
    return fixture(options), counts
end

test("manual update waits for the image worker, confirms, and asks to restart", function()
    local f, counts = update_fixture()
    f.instance:download_today()
    local items = {}
    f.instance:addToMainMenu(items)
    local check = items.danxiangli.sub_item_table[4]
    eq(check.text, "检查插件更新")
    check.callback()
    check.callback()
    eq(f.count, 1)
    f:complete(1)
    f:advance(0.125)
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(counts.checks, 1)
    eq(counts.prepared, 0)
    assert(f.confirmation.text:find("1.6.0", 1, true))
    f.confirmation.ok_callback()
    eq(f.count, 3)
    f:complete(3)
    f:advance(0.125)
    eq(counts.installed, 1)
    eq(counts.cleaned, 1)
    assert(f.restart_message:find("1.6.0", 1, true))
    f:new_instance()
    eq(counts.started, 1, "same process must keep the backup")
    f:advance(600)
    eq(f.count, 3)
    f:cleanup()
end)

test("declining the update leaves the installation untouched", function()
    local f, counts = update_fixture({ today_image = jpeg })
    f.instance:_check_plugin_update()
    f:complete(1)
    f:advance(0.125)
    f.confirmation.cancel_callback()
    f:advance(600)
    eq(f.count, 1)
    eq(counts.prepared, 0)
    eq(counts.installed, 0)
    f:cleanup()
end)

test("a finished update from a closed interface cannot replace the plugin", function()
    local f, counts = update_fixture({ today_image = jpeg })
    f.instance:_check_plugin_update()
    f:complete(1)
    f:advance(0.125)
    f.confirmation.ok_callback()
    f:complete(2)
    f:new_instance()
    f:advance(0.125)
    eq(counts.prepared, 1)
    eq(counts.installed, 0)
    eq(counts.cleaned, 1)
    eq(f.restart_message, nil)
    f:cleanup()
end)

test("wallpaper checks arriving during update wait for its worker to exit", function()
    local f, counts = update_fixture()
    f.instance:_check_plugin_update()
    f.instance:download_today()
    eq(f.count, 1)
    f:complete(1)
    f:advance(0.125)
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(counts.checks, 1)
    eq(f:read(), jpeg)
    f:cleanup()
end)

test("an unresponsive version check times out and releases the shared worker", function()
    local f, counts = update_fixture({ today_image = jpeg })
    f.instance:_check_plugin_update()
    f:advance(60.125)
    eq(f.jobs[1].killed, true)
    eq(f.locks, 0)
    eq(f.messages[#f.messages], "检查更新失败：下载超时")
    eq(counts.installed, 0)
    f.instance:_check_plugin_update()
    eq(f.count, 2)
    f:cleanup()
end)

print("All " .. test_count .. " regression checks passed")
