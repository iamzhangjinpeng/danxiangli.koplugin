--[[
单向历 (DanXiangLi) — KOReader 插件
- 每日下载单向历（OWSPACE）当日壁纸，并自动接管 KOReader 锁屏屏保。
- 下载在后台子进程执行，网络等待期间不阻塞 KOReader 界面。
- 安装即自动配置屏保（随机图模式 + 专用目录 + 拉伸填充，避免两侧黑边）。
- 唤醒后自动更新；Wi-Fi 重连期间退避重试，连上立即下载。
- 仅保留当日图片，旧图自动清理。
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local util            = require("util")
local http            = require("socket.http")
local socketutil      = require("socketutil")
local ffiutil         = require("ffi/util")
local time            = require("ui/time")
local NetworkMgr      = require("ui/network/manager")
local gettext         = require("gettext")

local has_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not has_lfs then
    has_lfs, lfs = pcall(require, "lfs")
end

local DanXiangLi = WidgetContainer:extend{ name = "danxiangli" }
local active_instance
local active_download
local active_worker
local scheduler_callback
local schedule_next_check
local pending_download_check = false
local pending_download_opts
local http404_cooldown_date
local http404_cooldown_until

local BASE_URL = "https://img.owspace.com/Public/uploads/Download/"
local SAVE_DIR = "/mnt/us/koreader/screenshots/danxiangli/"

-- 单向历按北京时间发布；固定偏移，不依赖设备时区
local UTC_OFFSET = 8 * 3600

local INIT_DELAY       = 8        -- 启动后首次检查延迟（秒）
local RESUME_DELAY     = 2        -- 唤醒后检查延迟（秒）
local CHECK_INTERVAL   = 5 * 60   -- 周期兜底检查（秒）
local MAX_RETRIES      = 6        -- Wi-Fi 重连等待的最大轮数
local RETRY_BASE       = 10       -- 退避基数（秒）
local RETRY_MAX        = 120      -- 单次退避上限（秒）
local HTTP_TIMEOUT     = 20       -- 下载总时限（秒），由父进程强制执行
local WORKER_POLL_INTERVAL = 0.125
local HTTP404_COOLDOWN = 2 * 3600 -- 今日图未发布 (404) 后的冷却（秒）
local MIN_JPEG_SIZE    = 1024

local SETTING_AUTO_SCREENSAVER = "danxiangli_auto_screensaver"
local SETTING_SCREENSAVER_BACKUP = "danxiangli_screensaver_backup"

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------

local function build_url(y, m, d)
    return string.format("%s%d/%02d%02d.jpg", BASE_URL, y, m, d)
end

-- 按北京时间取“今日”，返回 {year,month,day}, 日期串, 目标路径
local function get_today_info()
    local t = os.date("!*t", os.time() + UTC_OFFSET)
    local date_str = string.format("%04d%02d%02d", t.year, t.month, t.day)
    return t, date_str, SAVE_DIR .. date_str .. ".jpg"
end

local function is_http404_cooling(date_str)
    return http404_cooldown_date == date_str
        and http404_cooldown_until ~= nil
        and os.time() < http404_cooldown_until
end

local function queue_download_check(opts)
    pending_download_check = true
    if opts then
        pending_download_opts = pending_download_opts or {}
        pending_download_opts.notify = pending_download_opts.notify or opts.notify
        pending_download_opts.ignore_cooldown = pending_download_opts.ignore_cooldown or opts.ignore_cooldown
    end
end

local function run_pending_download_check()
    if active_download or not pending_download_check then return end
    local instance = active_instance
    if not instance or instance._stopped then
        -- The UI that requested this follow-up was closed. A future instance
        -- has its own startup check, so do not carry stale manual options over.
        pending_download_check = false
        pending_download_opts = nil
        return
    end

    local opts = pending_download_opts
    pending_download_check = false
    pending_download_opts = nil
    instance:_run(opts)
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function is_valid_jpeg(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(2)
    local size = f:seek("end")
    if not size or size < MIN_JPEG_SIZE then
        f:close()
        return false
    end
    -- Require a complete JPEG end marker at EOF, not just a plausible header.
    f:seek("end", -2)
    local tail = f:read(2)
    f:close()
    return head == "\255\216" and tail == "\255\217"
end

local function is_network_available()
    if NetworkMgr and NetworkMgr.isConnected then
        local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
        if ok then return connected == true end
    end
    return false -- 无法确认时按未连接处理，避免无谓请求
end

-- 遍历 SAVE_DIR 中的 jpg 文件
local function each_jpg(callback)
    if not has_lfs then return end
    for f in lfs.dir(SAVE_DIR) do
        if f:match("%.jpg$") and lfs.attributes(SAVE_DIR .. f, "mode") == "file" then
            callback(f)
        end
    end
end

-- 只删除非今日图片（SAVE_DIR 由本插件独占，安全）
local function cleanup_old_images(keep_date_str)
    local keep_name = keep_date_str .. ".jpg"
    local removed = 0
    each_jpg(function(f)
        if f ~= keep_name then
            os.remove(SAVE_DIR .. f)
            removed = removed + 1
        end
    end)
    if removed > 0 then
        logger.info("单向历: 清理旧图", removed, "张")
    end
end

-- A previous KOReader process may have exited before its cleanup callback ran.
-- Never scan/delete temporary files while any downloader can still write them.
local function cleanup_temporary_files()
    if active_worker or not has_lfs or lfs.attributes(SAVE_DIR, "mode") ~= "directory" then return end
    for name in lfs.dir(SAVE_DIR) do
        if name:match("^%d%d%d%d%d%d%d%d%.jpg%.tmp$") then
            local path = SAVE_DIR .. name
            if lfs.attributes(path, "mode") == "file" then
                local ok, err = os.remove(path)
                if not ok then logger.warn("单向历: 清理临时文件失败", path, tostring(err)) end
            end
        end
    end
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function is_auto_screensaver_enabled()
    if not G_reader_settings then return true end
    local v = G_reader_settings:readSetting(SETTING_AUTO_SCREENSAVER)
    return v == nil or v == true -- 首次安装默认开启
end

local function set_auto_screensaver_enabled(enabled)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_AUTO_SCREENSAVER, enabled)
        G_reader_settings:flush()
    end
end

----------------------------------------------------------------------
-- 状态 -> 用户可读消息
----------------------------------------------------------------------

local function status_text(status)
    if status == "ok" then return gettext("单向历已更新")
    elseif status == "exists" then return gettext("今日单向历已存在")
    elseif status == "no_network" then return gettext("无网络连接")
    elseif status == "open_error" then return gettext("无法创建文件（权限或空间不足）")
    elseif status == "network_error" then return gettext("网络请求失败")
    elseif status == "timeout" then return gettext("下载超时")
    elseif status == "invalid_file" then return gettext("下载文件校验失败")
    elseif status == "rename_error" then return gettext("文件替换失败")
    elseif type(status) == "string" and status:match("^http_") then
        return gettext("HTTP 错误: ") .. status:sub(6)
    end
    return gettext("错误: ") .. tostring(status)
end

----------------------------------------------------------------------
-- 下载（后台子进程，tmp + 校验 + 替换）
----------------------------------------------------------------------

-- BOOTTIME includes time spent asleep, and is unaffected by clock changes.
local function worker_now()
    return time.to_s(time.boottime_or_monotonic())
end

-- Keep the worker alive only until its deadline or cancellation. Reaping is
-- nonblocking; the same scheduler services both the worker and normal checks.
local function run_request_in_subprocess(task, callback)
    local pid, read_fd
    local started, start_err = pcall(function()
        pid, read_fd = ffiutil.runInSubProcess(function(_, child_write_fd)
            local ok, status = pcall(task)
            if not ok then
                logger.warn("单向历: 子进程请求异常", tostring(status))
                status = "network_error"
            end
            if type(status) ~= "string" then
                status = "network_error"
            end
            ffiutil.writeToFD(child_write_fd, status, true)
        end, true)
    end)
    if not started or not pid then
        -- On failure the second return value is an error string, not an fd.
        logger.warn("单向历: 无法启动下载子进程", tostring(start_err or read_fd))
        callback("network_error")
        return nil
    end

    local now = worker_now()
    local worker = {
        pid = pid,
        read_fd = read_fd,
        deadline = now + HTTP_TIMEOUT,
        poll_at = now + WORKER_POLL_INTERVAL,
    }

    function worker:cancel(status)
        if self.completed or self.stop_status then return end
        self.stop_status = status or "stale_request"
        ffiutil.terminateSubProcess(self.pid)
        self.poll_at = worker_now() + WORKER_POLL_INTERVAL
        schedule_next_check()
    end

    function worker:poll()
        if self.completed then return end
        if not ffiutil.isSubProcessDone(self.pid) then
            if self.stop_status then
                -- Cancellation may race the child's initial setpgid(). Retry
                -- the nonblocking kill until its process group exists/exits.
                ffiutil.terminateSubProcess(self.pid)
            elseif worker_now() >= self.deadline then
                logger.warn("单向历: 下载超过总时限，终止子进程")
                self:cancel("timeout")
            end
            self.poll_at = worker_now() + WORKER_POLL_INTERVAL
            return
        end

        -- Read only after waitpid confirms exit, so this cannot wait on the
        -- still-running downloader. Release the request lock in the callback
        -- only after the old writer has gone away.
        self.completed = true
        active_worker = nil
        local read_ok, status = pcall(ffiutil.readAllFromFD, self.read_fd)
        self.read_fd = nil
        UIManager:allowStandby()
        if not read_ok or type(status) ~= "string" or status == "" then
            logger.warn("单向历: 无法读取下载子进程结果", tostring(status))
            status = "network_error"
        end
        -- Preserve a completed 404 across UI transitions, even if cancellation
        -- arrived just after the child wrote its result.
        if self.stop_status and not (self.stop_status == "stale_request" and status == "http_404") then
            status = self.stop_status
        end
        callback(status)
        cleanup_temporary_files()
    end

    active_worker = worker
    UIManager:preventStandby()
    schedule_next_check()
    return worker
end

local function download_image(year, month, day, date_str, is_active, callback)
    local url = build_url(year, month, day)
    local target = SAVE_DIR .. date_str .. ".jpg"
    local tmp = target .. ".tmp"

    logger.info("单向历: 下载", url)
    os.remove(tmp)

    local completed = false
    local function finish(success, status)
        if completed then return end
        completed = true
        callback(success, status)
    end

    local function process_result(status)
        if completed then return end
        if not is_active() then
            -- A 404 still applies to the current date even if its original UI
            -- instance was replaced while the request was in flight.
            local _, current_date = get_today_info()
            if current_date == date_str and status == "http_404" then
                finish(false, "http_404")
            else
                os.remove(tmp)
                finish(false, "stale_request")
            end
            return
        end
        local _, current_date = get_today_info()
        if current_date ~= date_str then
            os.remove(tmp)
            finish(false, "stale_date")
            return
        end
        if status ~= "downloaded" then
            os.remove(tmp)
            finish(false, status or "network_error")
            return
        end

        if not is_valid_jpeg(tmp) then
            logger.warn("单向历: 文件校验失败")
            os.remove(tmp)
            finish(false, "invalid_file")
            return
        end

        -- Avoid committing yesterday's response if midnight passed while the
        -- body was being written and validated.
        local _, date_before_replace = get_today_info()
        if not is_active() or date_before_replace ~= date_str then
            os.remove(tmp)
            finish(false, date_before_replace ~= date_str and "stale_date" or "stale_request")
            return
        end

        local renamed, rerr = os.rename(tmp, target)
        if not renamed then
            logger.warn("单向历: 重命名失败", tostring(rerr))
            os.remove(tmp)
            finish(false, "rename_error")
            return
        end

        logger.info("单向历: 完成", target)
        finish(true, "ok")
    end

    local function request_to_tmp()
        local file, err = io.open(tmp, "wb")
        if not file then
            logger.warn("单向历: 无法创建临时文件", tostring(err))
            return "open_error"
        end

        local write_error
        -- This sink never closes the file; request_to_tmp owns its one close.
        local function sink(chunk, err)
            if err then return nil, err end
            if chunk then
                local write_ok, wrote, write_err = pcall(file.write, file, chunk)
                if not write_ok then write_err = wrote end
                if not write_ok or not wrote then
                    write_error = write_err or "write failed"
                    return nil, write_error
                end
            end
            return 1
        end

        local request_ok, ok, code = pcall(function()
            -- These changes affect the forked child only. LuaSocket ignores
            -- request.timeout; socketutil configures both HTTP and HTTPS.
            socketutil:set_timeout(HTTP_TIMEOUT, HTTP_TIMEOUT)
            return http.request{
                url = url,
                headers = {
                    ["Referer"] = "https://img.owspace.com/",
                    ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader)",
                },
                sink = sink,
                redirect = true,
            }
        end)
        local close_ok, closed, close_err = pcall(file.close, file)
        if not close_ok then close_err = closed end
        if write_error or not close_ok or not closed then
            logger.warn("单向历: 写入或关闭临时文件失败", tostring(write_error or close_err))
            os.remove(tmp)
            return "open_error"
        end
        if not request_ok then
            logger.warn("单向历: 网络请求异常", tostring(ok))
            os.remove(tmp)
            return "network_error"
        end
        if not ok then
            logger.warn("单向历: 网络错误", tostring(code))
            os.remove(tmp)
            return "network_error"
        end
        if code ~= 200 then
            logger.warn("单向历: HTTP", tostring(code))
            os.remove(tmp)
            return "http_" .. tostring(code or "unknown")
        end
        return "downloaded"
    end

    return run_request_in_subprocess(request_to_tmp, function(status)
        local ok, err = pcall(process_result, status)
        if not ok then
            logger.warn("单向历: 处理下载结果失败", tostring(err))
            os.remove(tmp)
            finish(false, "network_error")
        end
    end)
end

----------------------------------------------------------------------
-- 插件主体
----------------------------------------------------------------------

function DanXiangLi:init()
    if active_instance then
        active_instance:_cancel_scheduled_work()
    end
    active_instance = self

    self.ui.menu:registerToMainMenu(self)
    self._busy = false
    self._stopped = false
    self._request_generation = (self._request_generation or 0) + 1
    self._last_status = nil

    util.makePath(SAVE_DIR)
    cleanup_temporary_files()
    if is_auto_screensaver_enabled() then
        self:_ensure_screensaver_settings()
    else
        -- Finish a disable operation interrupted after restoring values.
        self:_restore_screensaver_settings(false)
    end

    local now = os.time()
    self._startup_at = now + INIT_DELAY
    self._resume_at = nil
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self._loop_at = now + CHECK_INTERVAL
    self:_schedule_loop()
end

-- 请求完成回调：网络等待期间不占用 UI 事件循环。
function DanXiangLi:_download_today(t, today_str, opts, retry_attempt, notify_failure)
    self:_cancel_retry()
    if active_download then
        queue_download_check(opts)
        return
    end

    local request_token = {}
    active_download = request_token
    self._busy = true
    local generation = self._request_generation
    local worker = download_image(t.year, t.month, t.day, today_str, function()
        return not self._stopped and generation == self._request_generation
    end, function(success, status)
        if active_download == request_token then
            self._download_worker = nil
            active_download = nil
        end

        local _, current_date = get_today_info()
        if status == "http_404" and current_date == today_str then
            http404_cooldown_date = today_str
            http404_cooldown_until = os.time() + HTTP404_COOLDOWN
        end

        local instance_active = not self._stopped
            and generation == self._request_generation
            and active_instance == self
        if instance_active then
            self._busy = false
        end

        if status == "stale_date" or current_date ~= today_str then
            queue_download_check(nil)
            run_pending_download_check()
            return
        end

        if not instance_active then
            run_pending_download_check()
            return
        end

        self._last_status = status

        if success then
            cleanup_old_images(today_str)
            self:_cancel_retry()
            if opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("单向历已更新"), timeout = 2 })
            end
        elseif status == "http_404" then
            self:_cancel_retry()
            if notify_failure and opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("今日图片未发布 (404)"), timeout = 3 })
            end
        else
            self:_schedule_retry(retry_attempt, opts)
            if notify_failure and opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = status_text(status), timeout = 3 })
            end
        end
        run_pending_download_check()
    end)
    -- Startup failure can invoke the callback synchronously and start another
    -- request after a date change. Do not overwrite that newer worker handle.
    if active_download == request_token then self._download_worker = worker end
end

-- 自动配置屏保；首次配置前保存原值，关闭开关时恢复
function DanXiangLi:_ensure_screensaver_settings(force)
    if not G_reader_settings then return end
    if not force and not is_auto_screensaver_enabled() then return end

    local backup = G_reader_settings:readSetting(SETTING_SCREENSAVER_BACKUP)
    if type(backup) ~= "table" or backup.version ~= 1 then
        local function snapshot(key)
            local value = G_reader_settings:readSetting(key)
            return { is_set = value ~= nil, value = value }
        end
        backup = {
            version = 1,
            type = snapshot("screensaver_type"),
            dir = snapshot("screensaver_dir"),
            stretch = snapshot("screensaver_stretch_images"),
            show_msg = snapshot("screensaver_show_message"),
        }
        -- Persist the original values before changing any screensaver setting.
        G_reader_settings:saveSetting(SETTING_SCREENSAVER_BACKUP, backup)
        G_reader_settings:flush()
    end

    local changed = false
    if G_reader_settings:readSetting("screensaver_type") ~= "random_image" then
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        changed = true
    end
    if G_reader_settings:readSetting("screensaver_dir") ~= SAVE_DIR then
        G_reader_settings:saveSetting("screensaver_dir", SAVE_DIR)
        changed = true
    end
    -- 正确键名是 screensaver_stretch_images：不拉伸时图按比例缩放，
    -- 与屏幕宽高比不一致会留下两侧黑边，故必须开启
    if not G_reader_settings:isTrue("screensaver_stretch_images") then
        G_reader_settings:saveSetting("screensaver_stretch_images", true)
        changed = true
    end
    -- 壁纸上不覆盖 “Sleeping” 文字
    if G_reader_settings:isTrue("screensaver_show_message") then
        G_reader_settings:saveSetting("screensaver_show_message", false)
        changed = true
    end

    if changed then
        G_reader_settings:flush()
        logger.info("单向历: 屏保设置已自动配置")
    end
end

function DanXiangLi:_restore_screensaver_settings(disable_auto)
    if not G_reader_settings then return end
    local backup = G_reader_settings:readSetting(SETTING_SCREENSAVER_BACKUP)

    if type(backup) == "table" and backup.version == 1 then
        local function restore(key, saved)
            if type(saved) ~= "table" or not saved.is_set then
                G_reader_settings:delSetting(key)
            else
                G_reader_settings:saveSetting(key, saved.value)
            end
        end
        restore("screensaver_type", backup.type)
        restore("screensaver_dir", backup.dir)
        restore("screensaver_stretch_images", backup.stretch)
        restore("screensaver_show_message", backup.show_msg)
    end

    if disable_auto then
        G_reader_settings:saveSetting(SETTING_AUTO_SCREENSAVER, false)
    end
    -- Save restored values before removing the recovery snapshot.
    G_reader_settings:flush()
    if backup ~= nil then
        G_reader_settings:delSetting(SETTING_SCREENSAVER_BACKUP)
        G_reader_settings:flush()
    end
    logger.info("单向历: 屏保设置已恢复")
end

function DanXiangLi:deletePluginSettings()
    if not G_reader_settings then return end
    self:_restore_screensaver_settings(true)
    G_reader_settings:delSetting(SETTING_AUTO_SCREENSAVER)
    G_reader_settings:delSetting("danxiangli_last_date")
    G_reader_settings:flush()
end

-- Drop callbacks owned by this UI instance. Do not restore screensaver settings
-- here: closing the file manager or reader does not disable the plugin.
function DanXiangLi:_cancel_scheduled_work()
    self._stopped = true
    self._request_generation = self._request_generation + 1
    self._busy = false
    self._startup_at = nil
    self._resume_at = nil
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self._loop_at = nil
    if active_instance == self then
        active_instance = nil
        pending_download_check = false
        pending_download_opts = nil
    end
    if self._download_worker then
        self._download_worker:cancel()
    end
    -- The shared scheduler remains only long enough to reap a cancelled child.
    schedule_next_check()
end

function DanXiangLi:onCloseWidget()
    self:_cancel_scheduled_work()
end

function DanXiangLi:stopPlugin()
    self:_cancel_scheduled_work()
    -- Disabling the plugin should leave screensaver preferences as they were.
    self:_restore_screensaver_settings(false)
end

function DanXiangLi:onResume()
    if self._stopped or active_instance ~= self then return end
    self._resume_at = os.time() + RESUME_DELAY
    self:_schedule_next_check()
end

-- Wi-Fi 是否开启（与“是否已拿到 IP”分开判断）
function DanXiangLi:_wifi_on()
    if NetworkMgr and NetworkMgr.isWifiOn then
        local ok, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
        if ok then return on == true end
    end
    return true -- 无法确认时按开启处理，交给重试上限兜底
end

function DanXiangLi:_cancel_retry()
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self:_schedule_next_check()
end

-- All timed work, including worker polling/reaping across UI transitions,
-- shares one module-level UIManager callback.
schedule_next_check = function()
    if scheduler_callback then
        UIManager:unschedule(scheduler_callback)
        scheduler_callback = nil
    end
    local delay
    local function consider(wait)
        if wait and (not delay or wait < delay) then
            delay = wait
        end
    end
    local instance = active_instance
    if instance and not instance._stopped then
        local now = os.time()
        for _, key in ipairs({ "_startup_at", "_resume_at", "_retry_at", "_loop_at" }) do
            local deadline = instance[key]
            if deadline then consider(deadline - now) end
        end
    end
    if active_worker then consider(active_worker.poll_at - worker_now()) end
    if not delay then return end

    scheduler_callback = function()
        scheduler_callback = nil
        local worker = active_worker
        if worker and worker.poll_at <= worker_now() then worker:poll() end
        local current = active_instance
        if current and not current._stopped then
            current:_process_scheduled_work()
        end
        schedule_next_check()
    end
    UIManager:scheduleIn(math.max(0, delay), scheduler_callback)
end

function DanXiangLi:_schedule_next_check()
    schedule_next_check()
end

function DanXiangLi:_process_scheduled_work()
    local now = os.time()
    local should_run = false
    if self._startup_at and self._startup_at <= now then
        self._startup_at = nil
        should_run = true
    end
    if self._resume_at and self._resume_at <= now then
        self._resume_at = nil
        should_run = true
    end
    if self._loop_at and self._loop_at <= now then
        self._loop_at = now + CHECK_INTERVAL
        should_run = true
    end
    if self._retry_at and self._retry_at <= now then
        local attempt, opts = self._retry_attempt, self._retry_opts
        self._retry_at = nil
        self._retry_attempt = nil
        self._retry_opts = nil
        self:_retry_round(attempt, opts)
    end
    if should_run and not self._busy then self:_run() end
end

-- Periodic fallback shares the central timer with startup, resume and retries.
function DanXiangLi:_schedule_loop()
    if self._stopped or active_instance ~= self then return end
    if not self._loop_at then self._loop_at = os.time() + CHECK_INTERVAL end
    self:_schedule_next_check()
end

-- 失败后的退避重试：Wi-Fi 关闭即停；正在重连则等比退避等待
function DanXiangLi:_schedule_retry(attempt, opts)
    if self._stopped or active_instance ~= self or self._retry_at then return end
    if attempt >= MAX_RETRIES then
        self._last_status = self._last_status or "network_error"
        logger.warn("单向历: 重试耗尽，放弃")
        return
    end
    local delay = math.min(RETRY_BASE * 2 ^ attempt, RETRY_MAX)
    self._retry_at = os.time() + delay
    self._retry_attempt = attempt + 1
    self._retry_opts = opts
    self:_schedule_next_check()
end

function DanXiangLi:_retry_round(attempt, opts)
    if self._stopped or self._busy then return end
    local t, today_str, today_path = get_today_info()
    if not (opts and opts.ignore_cooldown) and is_http404_cooling(today_str) then return end
    if is_valid_jpeg(today_path) then
        cleanup_old_images(today_str)
        self:_cancel_retry()
        return
    end
    if not self:_wifi_on() then
        logger.dbg("单向历: Wi-Fi 关闭，停止重试")
        self._last_status = "no_network"
        return
    end
    if not is_network_available() then
        self:_schedule_retry(attempt, opts) -- 仍在重连，继续等
        return
    end

    self:_download_today(t, today_str, opts, attempt, false)
end

-- 主入口：图片已存在走快速路径；缺失则下载；失败自动进入重试链
function DanXiangLi:_run(opts)
    if self._stopped then return end
    if self._busy then
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("单向历任务进行中…"), timeout = 2 })
        end
        return
    end

    util.makePath(SAVE_DIR)
    local t, today_str, today_path = get_today_info()

    -- 自动和手动下载均复用有效今日图，避免不必要的重复请求。
    if is_valid_jpeg(today_path) then
        self:_cancel_retry()
        cleanup_old_images(today_str)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("今日单向历已存在"), timeout = 2 })
        end
        return
    end

    -- 今日图确认未发布后，冷却期内不再打服务器。
    if not (opts and opts.ignore_cooldown) and is_http404_cooling(today_str) then
        logger.dbg("单向历: 今日图未发布，冷却中，跳过")
        return
    end

    if not is_network_available() then
        if self:_wifi_on() then
            self:_schedule_retry(0, opts) -- Wi-Fi 开着但还没拿到 IP：等待重连
        else
            self._last_status = "no_network"
            if opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("无网络连接"), timeout = 3 })
            end
        end
        return
    end

    self:_download_today(t, today_str, opts, 0, true)
end

function DanXiangLi:download_today()
    if self._stopped then return end
    self:_cancel_retry()
    self:_run{ notify = true, ignore_cooldown = true }
end

----------------------------------------------------------------------
-- 诊断
----------------------------------------------------------------------

function DanXiangLi:_diagnostics()
    local _, today_str, today_path = get_today_info()
    local lines = {}
    lines[#lines + 1] = gettext("目录: ") .. SAVE_DIR
    if is_valid_jpeg(today_path) then
        lines[#lines + 1] = gettext("今日图片: 已就绪 (") .. today_str .. ")"
    elseif file_exists(today_path) then
        lines[#lines + 1] = gettext("今日图片: 文件损坏")
    else
        lines[#lines + 1] = gettext("今日图片: 未下载")
    end
    lines[#lines + 1] = gettext("最近状态: ") .. tostring(self._last_status or "-")
    lines[#lines + 1] = gettext("网络: ") .. (is_network_available() and gettext("已连接") or gettext("未连接"))
    if G_reader_settings then
        lines[#lines + 1] = gettext("屏保类型: ") .. tostring(G_reader_settings:readSetting("screensaver_type"))
        lines[#lines + 1] = gettext("屏保目录: ") .. tostring(G_reader_settings:readSetting("screensaver_dir"))
        lines[#lines + 1] = gettext("拉伸填充: ") .. tostring(G_reader_settings:isTrue("screensaver_stretch_images"))
    end
    lines[#lines + 1] = gettext("自动配置: ") .. (is_auto_screensaver_enabled() and gettext("开") or gettext("关"))
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- 菜单
----------------------------------------------------------------------

function DanXiangLi:addToMainMenu(menu_items)
    menu_items.danxiangli = {
        text = gettext("单向历"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = gettext("自动配置屏保"),
                checked_func = function() return is_auto_screensaver_enabled() end,
                callback = function()
                    local enabled = not is_auto_screensaver_enabled()
                    if enabled then
                        -- Save the original screensaver settings before enabling.
                        self:_ensure_screensaver_settings(true)
                        set_auto_screensaver_enabled(true)
                        UIManager:show(InfoMessage:new{
                            text = gettext("已启用自动配置屏保"),
                            timeout = 3,
                        })
                    else
                        self:_restore_screensaver_settings(true)
                        UIManager:show(InfoMessage:new{
                            text = gettext("已停用，屏保设置已恢复"),
                            timeout = 3,
                        })
                    end
                end,
            },
            {
                text = gettext("下载今日单向历"),
                callback = function() self:download_today() end,
            },
            {
                text = gettext("诊断"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self:_diagnostics(),
                        timeout = 12,
                    })
                end,
            },
        },
    }
    return menu_items
end

return DanXiangLi
