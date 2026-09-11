-- Copyright (c) 2026 CamilleBC. MIT License; see LICENSE.
local M = {}
function M.new(api)
    assert(type(api.RegisterHook)=='function', 'RegisterHook unavailable')
    local H, entries = {}, {}
    function H.register(key, path, ...)
        assert(key ~= nil and type(path)=='string', 'Hook key and path required')
        local args, old = table.pack(...), entries[key]
        if old then
            local same = old.path == path and old.args.n == args.n
            for i=1,args.n do same = same and old.args[i] == args[i] end
            if not same then return nil, 'Conflicting hook key: '..tostring(key) end
            return old.pre, old.post
        end
        local ok, pre, post = pcall(api.RegisterHook, path, table.unpack(args,1,args.n))
        if not ok then return nil, pre end
        if type(pre)~='number' or type(post)~='number' then return nil, 'RegisterHook returned invalid IDs: '..path end
        entries[key] = {path=path,args=args,pre=pre,post=post}
        return pre, post
    end
    function H.remove(key)
        local entry = entries[key]; if not entry then return true end
        if type(api.UnregisterHook)~='function' then return nil, 'UnregisterHook unavailable' end
        local ok, result = pcall(api.UnregisterHook,entry.path,entry.pre,entry.post)
        if not ok or result == false then return nil, ok and 'UnregisterHook returned false' or result end
        entries[key] = nil; return true
    end
    function H.clear()
        local failures = {}
        for key in pairs(entries) do
            local ok, err = H.remove(key)
            if not ok then failures[#failures+1] = {key=key,error=err} end
        end
        if #failures>0 then return nil, failures end
        return true
    end
    return H
end
return M
