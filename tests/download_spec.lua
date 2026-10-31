-- Run from the plugin directory: lua tests/download_spec.lua /path/to/empty/scratch-dir
-- Public-entry-point regression checks with virtual child processes and time.
-- IO uses temporary files; no requests are sent and no Kindle files are changed.
local real_open, real_time = io.open, os.time
local main_path = (arg and arg[2]) or "main.lua"
local tmp_root = assert(arg and arg[1], "Provide an existing scratch directory as the first argument")
local input = assert(real_open(main_path, "rb"))
local source = input:read("*a")
input:close()
local jpeg = "\255\216" .. string.rep("x", 2048) .. "\255\217"
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
        closes = 0, reads = 0, requests = 0, prefix = base .. "-", options = options }
    os.time = function(t) return t and real_time(t) or epoch + math.floor(f.now) + (f.wall_shift or 0) end
    local function path(suffix) return f.prefix .. os.date("!%Y%m%d", os.time() + 8 * 3600) .. suffix end
    function f:read(suffix)
        local h = real_open(path(suffix or ".jpg"), "rb")
        if not h then return nil end
        local body = h:read("*a")
        h:close()
        return body
    end
    function f:write(body, suffix)
        local h = assert(real_open(path(suffix or ".jpg"), "wb"))
        h:write(body)
        h:close()
    end
    io.open = function(name, mode)
        local h, err = real_open(name, mode)
        if not h or mode ~= "wb" or not name:find(f.prefix, 1, true) then return h, err end
        return {
            write = function(_, chunk)
                if f.options.write_fail then return nil, "disk full" end
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
    function ui:show() end
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
        local ok, err = request.sink(body)
        if not ok then return nil, err end
        ok, err = request.sink(nil)
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
    local modules = {
        ["ui/widget/container/widgetcontainer"] = { extend = function(_, t) return t end },
        ["ui/uimanager"] = ui,
        ["ui/widget/infomessage"] = { new = function(_, t) return t end },
        ["logger"] = { info = function() end, warn = function() end, dbg = function() end },
        ["util"] = { makePath = function() end },
        ["socket.http"] = http,
        ["socketutil"] = socketutil,
        ["ffi/util"] = ffiutil,
        ["ui/time"] = { to_s = function(v) return v end, boottime_or_monotonic = function() return f.now end },
        ["ui/network/manager"] = { isConnected = function() return true end, isWifiOn = function() return true end },
        ["gettext"] = function(v) return v end,
        ["libs/libkoreader-lfs"] = { dir = function() return function() end end },
    }
    for name, module in pairs(modules) do package.loaded[name] = module end
    local code = source:gsub('local SAVE_DIR = "[^"]+"', 'local SAVE_DIR = ' .. string.format("%q", f.prefix))
    local plugin = assert(loadstring(code, "@main.lua"))()
    function f:new_instance()
        local obj = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = plugin })
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
        os.remove(path(".jpg"))
        os.remove(path(".jpg.tmp"))
        io.open, os.time = real_open, real_time
    end
    f.instance = f:new_instance()
    return f
end

local function test(name, body)
    body()
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

test("404 enters cooldown and force download bypasses it", function()
    local f = fixture({ responses = { { code = 404 }, { code = 200 } } })
    f.instance:_run()
    f:complete(1)
    f:advance(0.125)
    eq(f.instance._last_status, "http_404")
    eq(f.instance._retry_at, nil)
    eq(f:read(".jpg.tmp"), nil)
    f.instance:_run()
    eq(f.count, 1)
    f.instance:force_redownload()
    eq(f.count, 2)
    f:complete(2)
    f:advance(0.125)
    eq(f.instance._last_status, "ok")
    f:cleanup()
end)

test("hard deadline kills worker; lock and old image survive until reaped", function()
    local f = fixture({ delay_kill = true })
    f:write(jpeg)
    f.instance:force_redownload()
    f:write("partial", ".jpg.tmp")
    f:advance(19.875)
    assert(not f.jobs[1].killed)
    f:advance(0.125)
    assert(f.jobs[1].killed)
    eq(f.reads, 0)
    assert(f.instance._busy)
    f.instance:force_redownload()
    eq(f.count, 1)
    f.jobs[1].done = true
    f:advance(0.125)
    eq(f.instance._last_status, "timeout")
    assert(not f.instance._busy)
    assert(f.instance._retry_at)
    eq(f:read(), jpeg)
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

test("late old success cannot replace existing image after UI transition", function()
    local f = fixture()
    local old_image = "\255\216" .. string.rep("o", 2048) .. "\255\217"
    f:write(old_image)
    f.instance:force_redownload()
    f:complete(1)
    local current = f:new_instance()
    f:advance(0.125)
    eq(f:read(), old_image)
    eq(f:read(".jpg.tmp"), nil)
    current:force_redownload()
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
    { name = "network failure", options = { responses = { { error = "connect failed" } } }, status = "network_error" },
    { name = "write failure", options = { write_fail = true }, status = "open_error" },
    { name = "close failure", options = { close_fail = true }, status = "open_error" },
}) do
    test(case.name .. " preserves previous image", function()
        local f = fixture(case.options)
        f:write(jpeg)
        f.instance:force_redownload()
        f:complete(1)
        f:advance(0.125)
        eq(f.instance._last_status, case.status)
        eq(f.closes, 1)
        eq(f:read(), jpeg)
        eq(f:read(".jpg.tmp"), nil)
        f:cleanup()
    end)
end

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

print("All 14 regression checks passed")
