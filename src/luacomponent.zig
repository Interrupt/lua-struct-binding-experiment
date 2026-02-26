const std = @import("std");
const delve = @import("delve");
const app = delve.app;

const lua = delve.scripting.lua;
const scripting_manager = delve.scripting.manager;

const zlua = @import("zlua");
const Lua = zlua.Lua;

var nextIndex: i32 = 1000;

pub const LuaComponent = struct {
    script: [:0]const u8,
    scriptIndex: i32,

    pub fn new(luaScript: [:0]const u8) LuaComponent {
        delve.debug.log("LuaComponent new", .{});
        const ourIndex = nextIndex;
        nextIndex = nextIndex + 1;

        var newScript = LuaComponent{
            .script = luaScript,
            .scriptIndex = ourIndex,
        };

        // Load our script!
        newScript.runScript();

        return newScript;
    }

    pub fn runScript(self: *LuaComponent) void {
        const luaState = lua.getLua();
        defer luaState.setTop(0);

        luaState.doFile(self.script) catch {
            const lua_error = luaState.toString(-1) catch {
                delve.debug.log("Lua: could not get error string", .{});
                return;
            };

            delve.debug.log("Lua: error running file {s}: {s}", .{ self.script, lua_error });
            return;
        };

        if (!luaState.isTable(-1)) {
            delve.debug.fatal("Lua component run did not return a table!", .{});
        }

        // Use this as our new state table!
        delve.debug.log("LuaComponent creating state table", .{});

        // set the key
        luaState.pushInteger(self.scriptIndex);

        // Copy our new table to use as the value
        luaState.pushValue(-2);

        // registry[scriptIndex] = new table
        // also reset stack
        luaState.setTable(zlua.registry_index);
        luaState.pop(1);
    }

    // __index is called when Lua gets a value from a table
    pub fn __index(self: *LuaComponent, luaState: *Lua) i32 {
        _ = luaState.toAny([:0]const u8, -1) catch {
            delve.debug.log("LuaComponent __newindex could not get key!", .{});
            return 0;
        };

        if (!luaState.isTable(zlua.registry_index)) {
            delve.debug.log(" > Registry index is not a table!", .{});
            return 0;
        }

        // Get the table from the registry keyed by our scriptIndex
        _ = luaState.rawGetIndex(zlua.registry_index, self.scriptIndex);

        // Our table might not be created yet!
        if (!luaState.isTable(-1)) {
            return 0;
        }

        // Make a duplicate of the key to index
        luaState.pushValue(2);

        // return registry[scriptIndex][key]
        _ = luaState.getTable(-2);

        if (!luaState.isNil(-1)) {
            return 1;
        }

        // pop the nil value
        luaState.pop(1);

        // fallback to our own metatable so that we can still call bound functions like self:ourFunc()

        // get our own metatable
        luaState.getMetatable(1) catch {
            delve.debug.log("LuaComponent __index could not get metatable!", .{});
            return 0;
        };

        // push the key again
        luaState.pushValue(2);

        // return metatable[key]
        _ = luaState.getTable(-2);

        return 1;
    }

    // __newindex is called when Lua sets a value in a table
    pub fn __newindex(self: *LuaComponent, luaState: *Lua) i32 {
        _ = luaState.toAny([:0]const u8, -2) catch {
            delve.debug.log("LuaComponent __newindex could not get key!", .{});
            return 0;
        };

        _ = luaState.toAny([:0]const u8, -1) catch {
            delve.debug.log("LuaComponent __newindex could not get value!", .{});
            return 0;
        };

        const top = luaState.getTop();

        // Get the table from the registry keyed by our scriptIndex
        _ = luaState.rawGetIndex(zlua.registry_index, self.scriptIndex);

        if (!luaState.isTable(-1)) {
            delve.debug.fatal("LuaComponent __newindex has no state table!!!", .{});
        }

        // Make a duplicate of the key
        luaState.pushValue(2);

        // Make a duplicate of the value
        luaState.pushValue(3);

        // registry[scriptIndex][key] = value
        luaState.setTable(-3);

        // remove the table from the stack
        luaState.pop(1);

        if (top != luaState.getTop()) {
            delve.debug.fatal("Lua binding: leaking stack!", .{});
        }

        return 0;
    }

    pub fn destroy(self: *LuaComponent) void {
        _ = self;
        delve.debug.log("LuaComponent destroy!", .{});
    }

    pub fn debugPrint(self: *LuaComponent) void {
        delve.debug.log("LuaComponent script='{s}'", .{self.script});
    }
};
