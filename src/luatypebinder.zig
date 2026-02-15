const std = @import("std");
const delve = @import("delve");
const app = delve.app;

const lua = delve.scripting.lua;
const scripting_manager = delve.scripting.manager;

const zlua = @import("zlua");
const Lua = zlua.Lua;

pub const BoundType = struct {
    T: type,
    name: [:0]const u8,
};

pub fn Registry(comptime entries: []const BoundType) type {
    return struct {
        pub const registry = entries;

        pub fn getMetaTableName(comptime T: type) [:0]const u8 {
            inline for (registry) |entry| {
                if (entry.T == T) return entry.name;
            }
            delve.debug.warning("Type not found in Lua registry! " ++ @typeName(T), .{});
            return "_notFound";
        }

        pub fn isRegistered(comptime T: type) bool {
            inline for (registry) |entry| {
                if (entry.T == T) return true;
            }
            return false;
        }

        pub fn bindTypes(luaState: *zlua.Lua) !void {
            inline for (registry) |entry| {
                try bindType(luaState, entry.T, entry.name);
            }
        }

        pub fn bindType(luaState: *zlua.Lua, comptime T: type, comptime metaTableName: [:0]const u8) !void {
            delve.debug.log("Registering user type: {s}", .{metaTableName});

            // Make our new and __gc funcs
            const newFunc = struct {
                fn inner(L: *zlua.Lua) i32 {
                    delve.debug.log("LuaType new called", .{});

                    // make a new ptr
                    const ptr: *T = @alignCast(L.newUserdata(T, @sizeOf(T)));

                    // set its metatable
                    _ = L.getMetatableRegistry(metaTableName);
                    _ = L.setMetatable(-2);

                    // init new object, copy values to our pointer
                    const res = T.init();
                    ptr.* = res;

                    return 1;
                }
            }.inner;

            const gcFunc = struct {
                fn inner(L: *zlua.Lua) i32 {
                    const ptr = L.checkUserdata(T, 1, metaTableName);
                    ptr.destroy();
                    return 0;
                }
            }.inner;

            // Make our new userData and metaTable
            _ = luaState.newUserdata(T, @sizeOf(T));
            _ = try luaState.newMetatable(metaTableName);

            // Metatable.__index = metatable
            // This lets us use 'obj:blah()' method call syntax
            luaState.pushValue(-1);
            luaState.setField(-2, "__index");

            // GC func is required for memory management
            luaState.pushClosure(zlua.wrap(gcFunc), 0);
            luaState.setField(-2, "__gc");

            // Now wire up our functions!
            switch (@typeInfo(T)) {
                .@"struct" => |S| {
                    const decls = S.decls;
                    inline for (decls) |decl| {
                        if (@typeInfo(@TypeOf(@field(T, decl.name))) == .@"fn") {
                            luaState.pushClosure(zlua.wrap(bindStructFuncLua(@field(T, decl.name))), 0);
                            luaState.setField(-2, decl.name);
                        }
                    }
                },
                else => {},
            }

            // Make this usable with "require" and register the 'new' func
            luaState.requireF(metaTableName, zlua.wrap(makeLuaOpenLibFn(newFunc)), true);

            delve.debug.log("Added lua module: '{s}'", .{metaTableName});
        }

        fn bindStructFuncLua(comptime function: anytype) fn (lua: *Lua) i32 {
            return (opaque {
                pub fn lua_call(luaState: *Lua) i32 {
                    // Get a tuple of the various types of the arguments, and then create one
                    const ArgsTuple = std.meta.ArgsTuple(@TypeOf(function));
                    var args: ArgsTuple = undefined;

                    const fn_info = @typeInfo(@TypeOf(function)).@"fn";
                    const params = fn_info.params;

                    inline for (params, 0..) |param, i| {
                        const param_type = param.type.?;
                        const lua_idx = i + 1;

                        switch (@typeInfo(param_type)) {
                            .pointer => |p| {
                                const Child = p.child;
                                if (p.size == .one and isRegistered(Child)) {
                                    args[i] = luaState.checkUserdata(Child, lua_idx, getMetaTableName(Child));
                                } else {
                                    delve.debug.fatal("Could not find user data type for arg: {any}", .{Child});
                                }
                            },
                            else => {
                                switch (param_type) {
                                    bool => {
                                        args[i] = luaState.toBool(lua_idx) catch false;
                                    },
                                    c_int, usize, i8, i16, i32, i64, u8, u16, u32, u64 => {
                                        // ints
                                        args[i] = std.math.lossyCast(param_type, luaState.toNumber(lua_idx) catch 0);
                                    },
                                    f16, f32, f64 => {
                                        // floats
                                        args[i] = std.math.lossyCast(param_type, luaState.toNumber(lua_idx) catch 0);
                                    },
                                    [*:0]const u8 => {
                                        // strings
                                        args[i] = luaState.toString(lua_idx) catch "";
                                    },
                                    else => {
                                        @compileError(std.fmt.comptimePrint("Unimplemented LUA argument type: {any}:{s} {any}", .{ i, @typeName(param_type), params }));
                                    },
                                }
                            },
                        }
                    }

                    if (fn_info.return_type == null) {
                        @compileError("Function has no return type?! This should not be possible.");
                    }

                    const ret_val = @call(.auto, function, args);
                    const ret_type = @TypeOf(ret_val);

                    // handle registered types
                    if (isRegistered(ret_type)) {
                        // make a new ptr
                        const ptr: *ret_type = @alignCast(luaState.newUserdata(ret_type, @sizeOf(ret_type)));

                        // set its metatable
                        _ = luaState.getMetatableRegistry(getMetaTableName(ret_type));
                        _ = luaState.setMetatable(-2);

                        // copy values to our pointer
                        ptr.* = ret_val;
                        return 1;
                    }

                    // everything else!
                    switch (ret_type) {
                        void => {
                            return 0;
                        },
                        bool => {
                            luaState.pushBoolean(ret_val);
                            return 1;
                        },
                        c_int, usize, i8, i16, i32, i64, u8, u16, u32, u64 => {
                            luaState.pushNumber(@floatFromInt(ret_val));
                            return 1;
                        },
                        f16, f32, f64 => {
                            luaState.pushNumber(ret_val);
                            return 1;
                        },
                        [*:0]const u8 => {
                            _ = luaState.pushString(ret_val);
                            return 1;
                        },
                        [:0]const u8 => {
                            _ = luaState.pushString(ret_val);
                            return 1;
                        },
                        std.meta.Tuple(&.{ f32, f32 }) => {
                            // probably is a way to handle any tuple types
                            luaState.pushNumber(ret_val[0]);
                            luaState.pushNumber(ret_val[1]);
                            return 2;
                        },
                        else => {
                            delve.debug.fatal("Could not find user data type to return: {s}", .{@typeName(ret_type)});
                            return 0;
                        },
                    }

                    @compileError("LUA did not return number of return values correctly!");
                }
            }).lua_call;
        }
    };
}

fn makeLuaOpenLibFn(comptime newFunc: anytype) fn (*Lua) i32 {
    return opaque {
        pub fn inner(luaState: *Lua) i32 {
            const newRegFn = zlua.FnReg{ .name = "new", .func = zlua.wrap(newFunc) };

            delve.debug.log("Lua require called!", .{});

            var lib_funcs: [1]zlua.FnReg = undefined;
            lib_funcs[0] = newRegFn;

            // Register our library, with a ".new()" function!
            luaState.newLib(&lib_funcs);
            return 1;
        }
    }.inner;
}
