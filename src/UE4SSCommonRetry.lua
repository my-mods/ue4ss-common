-- Copyright (c) 2026 CamilleBC. MIT License; see LICENSE.
-- One-shot callbacks only. The caller supplies UE4SS game-thread APIs.
local M = {}
function M.new(o)
    assert(type(o.schedule)=='function' and type(o.cancel)=='function', 'Retry needs scheduling and cancellation APIs')
    assert(type(o.attempt)=='function' and type(o.limit)=='number' and o.limit>=1 and o.limit%1==0, 'Invalid retry options')
    assert(type(o.delay)=='number' and o.delay>=1 and o.delay%1==0, 'Retry delay must be positive integer milliseconds')
    local R, handle, generation, attempts, executing, wanted, terminal = {}, nil, 0, 0, false, false, false
    local arm
    local function finish(reason)
        terminal, wanted = true, false
        if o.onComplete then o.onComplete(reason, attempts) end
    end
    arm = function()
        if handle or executing or not wanted or terminal then return end
        local ticket = generation
        local ok, value = pcall(o.schedule, o.delay, function()
            if ticket ~= generation then return end
            handle = nil
            if terminal or not wanted then return end
            executing = true
            attempts = attempts + 1
            local success, result = pcall(o.attempt, attempts)
            executing = false
            if ticket ~= generation then arm(); return end
            if not success then
                terminal, wanted = true, false
                if o.onError then o.onError(result, attempts) end
                if ticket == generation then finish('error') else arm() end
                return
            end
            if result == 'done' or result == 'stop' then finish(result)
            elseif result ~= 'retry' then
                terminal, wanted = true, false
                if o.onError then o.onError('Invalid retry outcome: '..tostring(result), attempts) end
                if ticket == generation then finish('error') else arm() end
            elseif attempts >= o.limit then finish('exhausted')
            else arm() end
        end)
        if not ok or type(value) ~= 'number' then
            terminal, wanted = true, false
            if o.onError then o.onError(ok and 'Scheduler did not return an action handle' or value, attempts) end
            return
        end
        handle = value
    end
    function R.wake()
        if terminal then return false end
        wanted = true; arm(); return true
    end
    function R.cancel()
        generation = generation + 1
        wanted, terminal = false, true
        if handle then
            local ok, err = pcall(o.cancel, handle)
            if not ok then return nil, err end
            handle = nil -- false means the native action no longer exists.
        end
        return true
    end
    function R.reset()
        local ok, err = R.cancel(); if not ok then return nil, err end
        attempts, terminal = 0, false
        return true -- Explicit wake is required; reset itself schedules nothing.
    end
    function R.status() return {attempts=attempts,pending=handle~=nil,running=executing,terminal=terminal} end
    return R
end
return M
