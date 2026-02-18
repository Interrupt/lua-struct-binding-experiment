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

        pub fn hasDestroyFunc(comptime T: type) bool {
            return std.meta.hasFn(T, "destroy");
        }

        pub fn bindTypes(luaState: *zlua.Lua) !void {
            inline for (registry) |entry| {
                try bindType(luaState, entry.T, entry.name);
            }
        }

        pub fn bindType(luaState: *zlua.Lua, comptime T: type, comptime metaTableName: [:0]const u8) !void {
            delve.debug.log("Registering user type: {s}", .{metaTableName});

            // Make our new userData and metaTable
            _ = luaState.newUserdata(T, @sizeOf(T));
            _ = try luaState.newMetatable(metaTableName);

            // Metatable.__index = metatable
            // This lets us use 'obj:blah()' method call syntax
            luaState.pushValue(-1);
            luaState.setField(-2, "__index");

            // GC func is required for memory management
            // Wire GC up to our destroy function if found!
            if (comptime hasDestroyFunc(T)) {
                // Make our GC function to wire to _gc in lua
                const gcFunc = struct {
                    fn inner(L: *zlua.Lua) i32 {
                        const ptr = L.checkUserdata(T, 1, metaTableName);
                        ptr.destroy();
                        return 0;
                    }
                }.inner;

                luaState.pushClosure(zlua.wrap(gcFunc), 0);
                luaState.setField(-2, "__gc");
            }

            // Now wire up our functions!
            const foundFns = comptime findLibraryFunctions(T);
            inline for (foundFns) |foundFunc| {
                luaState.pushClosure(foundFunc.func.?, 0);
                luaState.setField(-2, foundFunc.name);
            }

            // Make this usable with "require" and register our funcs in the library
            luaState.requireF(metaTableName, zlua.wrap(makeLuaOpenLibFn(foundFns)), true);

            delve.debug.log("Added lua module: '{s}'", .{metaTableName});
        }

        fn makeLuaBinding(name: [:0]const u8, comptime function: anytype) zlua.FnReg {
            return zlua.FnReg{ .name = name, .func = zlua.wrap(bindStructFuncLua(function)) };
        }

        fn findLibraryFunctions(comptime module: anytype) []const zlua.FnReg {
            comptime {
                // Get all the public declarations in this module
                const decls = @typeInfo(module).@"struct".decls;
                // filter out only the public functions
                var gen_fields: []const std.builtin.Type.Declaration = &[_]std.builtin.Type.Declaration{};
                for (decls) |d| {
                    if (@typeInfo(@TypeOf(@field(module, d.name))) == .@"fn") {
                        gen_fields = gen_fields ++ .{d};
                    }
                }

                var found: []const zlua.FnReg = &[_]zlua.FnReg{};
                for (gen_fields) |d| {
                    // convert the name string to be :0 terminated
                    const field_name: [:0]const u8 = d.name ++ "";
                    found = found ++ .{makeLuaBinding(field_name, @field(module, d.name))};

                    // found = found ++ .{ .name = field_name, .func = zlua.wrap(@field(module, d.name)) };
                }
                return found;
            }
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
                                        delve.debug.warning("Unimplemented LUA argument type! {s}", .{@typeName(param_type)});
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

fn makeFuncRg(funcs: []zlua.CFn) []zlua.FnReg {
    comptime {
        const registry = [_]zlua.FnReg{};

        for (funcs) |func| {
            const newRegFn = zlua.FnReg{ .name = "new", .func = func };
            registry ++ newRegFn;
        }

        return registry;
    }
}

fn makeLuaOpenLibFn(libFuncs: []const zlua.FnReg) fn (*Lua) i32 {
    return opaque {
        pub fn inner(luaState: *Lua) i32 {
            delve.debug.log("Lua require called!", .{});

            // Register our new library for this type, with all our funcs!
            luaState.newLib(libFuncs);

            return 1;
        }
    }.inner;
}
