import CLua
import os.log

private let luaSkinCompatibilityScript = #"""
do
    local constantsStore = setmetatable({}, { __mode = "k" })
    local constantsMT = {}

    constantsMT.__index = function(obj, key)
        local constants = constantsStore[obj]
        if constants == nil then return nil end

        local value = constants[key]
        if value ~= nil then return value end

        for k, v in pairs(constants) do
            if v == key then return k end
        end
        return nil
    end

    constantsMT.__newindex = function()
        error("attempt to modify a table of constants", 2)
    end

    constantsMT.__pairs = function(obj)
        return pairs(constantsStore[obj] or {})
    end

    constantsMT.__len = function(obj)
        return #(constantsStore[obj] or {})
    end

    constantsMT.__tostring = function(obj)
        local constants = constantsStore[obj]
        if constants == nil then return "constants table missing" end

        local keys = {}
        for k in pairs(constants) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

        local result = {}
        for _, key in ipairs(keys) do result[#result + 1] = tostring(key) end
        return table.concat(result, "\n")
    end

    constantsMT.__metatable = constantsMT

    local function makeConstantsTable(value)
        if type(value) ~= "table" then return value end

        local constants = {}
        for k, v in pairs(value) do
            constants[k] = makeConstantsTable(v)
        end

        local proxy = setmetatable({}, constantsMT)
        constantsStore[proxy] = constants
        return proxy
    end

    local existing = rawget(_G, "ls")
    if type(existing) ~= "table" then existing = {} end
    existing.makeConstantsTable = existing.makeConstantsTable or makeConstantsTable
    _G.ls = existing
end
"""#

func installLuaSkinCompatibilityGlobals(_ L: UnsafeMutablePointer<lua_State>!) {
    guard let L else { return }

    if luaL_dostring(L, luaSkinCompatibilityScript) != LUA_OK {
        let errorMessage = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
        os_log(.error, "Unable to install LuaSkin compatibility globals: %{public}s", errorMessage)
        lua_pop(L, 1)
    }
}
