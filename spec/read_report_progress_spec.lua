-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function fixture(provider)
    local records = {}
    local cookie = { expired = false, valid_events = 0 }
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
        is_cookie_expired = function() return cookie.expired end,
        mark_cookie_expired = function()
            cookie.expired = true
        end,
        mark_cookie_valid = function()
            cookie.expired = false
            cookie.valid_events = cookie.valid_events + 1
        end,
    }
    local client = {
        auth_error_code = function(result)
            return type(result) == "table" and result.errCode or nil
        end,
        is_auth_expired_code = function(code)
            return code == -2012 or code == -2010
        end,
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records, cookie
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

test("expired cookie stops reporting instead of looping", function()
    local report, _, cookie = fixture(function()
        return { chapter_uid = 1, chapter_offset = 0, percent = 1 }, nil, true
    end)
    cookie.expired = true
    report.last_renew_attempt = 100
    local proceed = report:_precheck()
    eq(proceed, false, "expired cookie blocks tick")
    local status = report:status()
    eq(status.state, "stopped", "expired cookie stops the loop")
    eq(status.stop_reason, "cookie_expired", "cookie expiry stop reason")
    eq(status.last_error_kind, "authentication", "authentication error kind")
    eq(status.last_error, "cookie expired", "authentication error surfaced")
end)

test("failed report keeps the cookie expired", function()
    local report, _, cookie = fixture()
    report:_apply_outcome{
        accepted = false,
        cookie_expired = true,
        error = "Cookie renewal rejected; error_code=-2012",
        error_kind = "authentication",
    }
    eq(cookie.expired, true, "cookie stays expired after failed final request")
    eq(cookie.valid_events, 0, "failed report must not write a valid state")
end)

test("auth rejection marks cookie expired and success clears it", function()
    local report, _, cookie = fixture()
    report:_apply_outcome{
        accepted = false,
        error = "Cookie renewal rejected; error_code=-2012",
        error_kind = "authentication",
        cookie_expired = true,
    }
    eq(cookie.expired, true, "cookie marked expired")
    eq(report:status().failure_count, 1, "failure recorded")
    report:_apply_outcome{ accepted = true }
    eq(cookie.expired, false, "cookie marked valid after success")
    eq(report:status().count, 1, "success recorded")
end)

local function context_book()
    return {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 0,
        progress = 1,
        chapters = { { chapterUid = 11, chapterIdx = 1 } },
    }
end

test("successful report clears the expired state", function()
    local report, _, cookie = fixture()
    cookie.expired = true
    report.ensure_context = context_book
    report._send = function() return { succ = 1 } end
    local ok = report:_apply_outcome(
        report:_run_pipeline("book", { allow_renewal = true }))
    eq(ok, true, "report accepted")
    eq(cookie.expired, false, "expired state cleared")
    eq(cookie.valid_events, 1, "cookie marked valid once")
end)

test("HTTP 401 is transport, not a cookie verdict", function()
    local report, _, cookie = fixture()
    report.ensure_context = context_book
    local renew_calls, sends = 0, 0
    report.client.renew_cookie = function()
        renew_calls = renew_calls + 1
        return { succ = 1 }
    end
    report._send = function()
        sends = sends + 1
        error("weread/lib/client.lua:528: HTTP 401, content_type=text/html")
    end
    local outcome = report:_run_pipeline("book", { allow_renewal = true })
    eq(sends, 1, "HTTP 401 is not retried")
    eq(renew_calls, 0, "HTTP 401 does not trigger renewal")
    eq(outcome.error_kind, "transport", "HTTP 401 remains transport")
    eq(cookie.expired, false, "HTTP 401 alone must not expire the cookie")
end)

test("auth payload without renewal is classified but not terminal", function()
    local report, _, cookie = fixture()
    report.ensure_context = context_book
    report._send = function()
        return { errCode = -2012 }, 200
    end
    local outcome = report:_run_pipeline("book", { allow_renewal = false })
    eq(outcome.error_kind, "authentication", "auth payload classified")
    eq(outcome.cookie_expired, false, "no marker without a definitive renewal")
    eq(cookie.expired, false, "cookie state unchanged")
end)

test("transport failures stay transport failures", function()
    local report = fixture()
    report.ensure_context = context_book
    report._send = function()
        error("culled: connection reset")
    end
    local outcome = report:_run_pipeline("book", { allow_renewal = true })
    eq(outcome.error_kind, "transport", "connection errors are not auth errors")
    eq(outcome.renew_attempted, false, "transport errors do not renew")
end)

test("sustained failures stop reporting without marking the cookie expired", function()
    local report, _, cookie = fixture()
    local clock = 1000
    report.now = function() return clock end
    report.task = function() end
    report:_apply_outcome{ accepted = false, error = "HTTP 500", error_kind = "transport" }
    eq(report.failure_streak_started_at, 1000, "failure streak started")
    clock = 1000 + 30 * 60 - 1
    report:_apply_outcome{ accepted = false, error = "HTTP 500", error_kind = "transport" }
    eq(report.task ~= nil, true, "loop still armed before the limit")
    clock = 1000 + 30 * 60
    report:_apply_outcome{ accepted = false, error = "HTTP 500", error_kind = "transport" }
    eq(report.task, nil, "loop stopped after the limit")
    eq(report.stop_reason, "report_stalled", "stalled stop reason")
    eq(cookie.expired, false, "stalled reporting must not mark the cookie expired")
end)

test("a success resets the failure streak", function()
    local report = fixture()
    local clock = 1000
    report.now = function() return clock end
    report.task = function() end
    report:_apply_outcome{ accepted = false, error = "HTTP 500", error_kind = "transport" }
    clock = 1000 + 29 * 60
    report:_apply_outcome{ accepted = true }
    eq(report.failure_streak_started_at, nil, "success cleared the streak start")
    clock = clock + 29 * 60
    report:_apply_outcome{ accepted = false, error = "HTTP 500", error_kind = "transport" }
    eq(report.task ~= nil, true, "a new streak uses a fresh window")
end)

test("offline ticks do not count toward the failure streak", function()
    local report = fixture()
    report.is_online = function() return false end
    report.failure_streak_started_at = 1000
    report:_precheck()
    eq(report.state, "offline", "offline state")
    eq(report.failure_streak_started_at, nil, "offline reset the streak start")
end)

test("watchdog stops a ticking loop when precheck keeps failing", function()
    local report = fixture()
    report.settings.is_cookie_configured = function() return false end
    report.now = function() return 3000 end
    report.failure_streak_started_at = 1000
    report.task = function() end
    local task = report.task
    report:_tick(1, task)
    eq(report.task, nil, "watchdog stopped the ticking loop")
    eq(report.stop_reason, "report_stalled", "stalled reason from precheck")
end)

test("starting a new session resets the failure streak", function()
    local report = fixture()
    report.failure_streak_started_at = 1
    report.consecutive_failures = 5
    eq(report:start("test"), true, "session started")
    eq(report.failure_streak_started_at, nil, "start cleared the streak start")
    eq(report.consecutive_failures, 0, "start cleared the streak count")
    report:stop("test_done")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
