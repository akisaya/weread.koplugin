-- Cookie expiry gate: a definitive renewal rejection is persisted, stops every
-- entry point, survives a restart, and is cleared only by new credentials.
--
-- Run from the repo root with: luajit spec/read_report_cookie_gate_spec.lua

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        is_success_response = function(result)
            return type(result) == "table"
                and (result.succ == 1 or result.succ == true)
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            local noop = function() end
            return { dbg = noop, info = noop, warn = noop, err = noop }
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function fixture(opts)
    opts = opts or {}
    local state = { expired = opts.expired == true }
    local clock = { now = 1000 }
    local counters = { send = 0, renew = 0, context = 0, notify = 0 }
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return { enabled = true, mode = "manual", book_id = "book-1",
                    interval_seconds = 30 }
            end
            if key == "books" then return { ["book-1"] = { title = "Book" } } end
            if key == "cookies" then return { wr_skey = "skey" } end
            return {}
        end,
        is_cookie_configured = function() return true end,
        is_cookie_expired = function() return state.expired end,
        mark_cookie_expired = function() state.expired = true end,
        mark_cookie_valid = function() state.expired = false end,
        update_auth = function() end,
        flush = function() end,
    }
    local client = {
        auth_error_code = function(result)
            return type(result) == "table" and result.errCode or nil
        end,
        is_auth_expired_code = function(code)
            return code == -2012 or code == -2010
        end,
        json_encode = function() return "{}" end,
        -- Mirrors the real client: a definitive rejection persists the marker.
        renew_cookie = function()
            counters.renew = counters.renew + 1
            if opts.renew_ok then return { succ = 1 } end
            state.expired = true
            error("Cookie renewal rejected; error_code=-2012")
        end,
    }
    local report = ReadReport:new {
        settings = settings,
        client = client,
        scheduler = { scheduleIn = function() end, unschedule = function() end },
        get_document = function() return {} end,
        detect_book = function() return "book-1" end,
        is_online = function() return true end,
        subprocess = false,
        now = function() return clock.now end,
        notify_cookie_expired = function()
            counters.notify = counters.notify + 1
        end,
    }
    report.ensure_context = function()
        counters.context = counters.context + 1
        return { book_id = "book-1" }
    end
    report._send = function()
        counters.send = counters.send + 1
        return { errCode = -2012 }, 200
    end
    return report, state, counters, clock
end

-- 1. A persisted marker blocks every entry point before any network work, and
--    a restart surfaces the state exactly once.
local blocked, blocked_state, blocked_c = fixture { expired = true }
expect(blocked:maybe_start("resume") == false and blocked.task == nil,
    "a persisted cookie expiry must not restart the loop")
expect(blocked_c.notify == 1, "the restart must surface the expired state once")
blocked:maybe_start("reader_ready")
expect(blocked_c.notify == 1, "the restart notification must not repeat")
expect(blocked:report_once() == false and blocked_c.send == 0,
    "report_once must honor the gate")
expect(blocked:upload_position("book-1", {}, 0) == false
    and blocked_c.send == 0 and blocked_c.renew == 0
    and blocked_c.context == 0,
    "a blocked credential must produce zero network requests")

-- 2. A rejected renewal inside the pipeline persists the marker, stops the
--    loop and notifies the UI exactly once.
local dead, dead_state, dead_c = fixture()
local dead_outcome = dead:_run_pipeline("book-1", { allow_renewal = true })
expect(dead_outcome.cookie_expired == true and dead_state.expired == true,
    "a rejected renewal must persist the marker")
dead.task = function() end
dead:_apply_outcome(dead_outcome)
expect(dead.task == nil and dead_c.notify == 1,
    "a rejected renewal must stop the loop and notify once")
expect(dead:status().stop_reason == "cookie_expired"
    and dead:status().last_error == "cookie expired",
    "the status page must expose the cookie expiry")
dead:_apply_outcome(dead_outcome)
expect(dead_c.notify == 1, "the notification must not repeat")

-- 3. A transient failure must keep the retry cadence and the loop armed.
local transient, transient_state, transient_c = fixture()
transient.client.renew_cookie = function()
    transient_c.renew = transient_c.renew + 1
    error("HTTP 500, content_type=text/html")
end
local transient_outcome = transient:_run_pipeline("book-1", { allow_renewal = true })
expect(transient_outcome.cookie_expired == false
    and transient_state.expired == false,
    "a transient failure must not persist the marker")
transient.task = function() end
transient:_apply_outcome(transient_outcome)
expect(transient.task ~= nil and transient_c.notify == 0,
    "a transient failure must not stop the loop")

-- 4. New credentials clear the marker and re-arm the loop.
expect(blocked:on_credentials_replaced() == true and blocked.task ~= nil,
    "new credentials must re-arm the loop")
expect(blocked_state.expired == false, "new credentials must clear the marker")

-- 5. A stale child outcome must not undo a fresh login.
local stale, stale_state, stale_c = fixture { expired = true }
stale.task = function() end
stale._auth_fingerprint = function() return "NEW-AFTER-LOGIN" end
stale:_apply_job_outcome({
    book_id = "book-1", auth_fingerprint = "OLD-AT-LAUNCH",
    context_fingerprint = "",
}, {
    accepted = false, cookie_expired = true, error = "x",
    error_kind = "authentication",
})
expect(stale_state.expired == true and stale.task ~= nil
    and stale_c.notify == 0,
    "a stale outcome must not stop the loop or notify")

-- 6. An uncaught pipeline error still carries the cookie state to the parent.
local child, child_state = fixture()
child_state.expired = true
child._run_pipeline = function() error("unexpected pipeline failure") end
local child_outcome = child:_child_report("book-1", false, nil)
expect(child_outcome.cookie_expired == true,
    "a failed child must still report the persisted state")

print("read_report_cookie_gate_spec: " .. checks .. " checks passed")
