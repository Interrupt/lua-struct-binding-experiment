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

        pub fn hasIndexFunc(comptime T: type) bool {
            return std.meta.hasFn(T, "__index");
        }

        pub fn hasNewIndexFunc(comptime T: type) bool {
            return std.meta.hasFn(T, "__newindex");
        }

        pub fn bindTypes(luaState: *zlua.Lua) !void {
            inline for (registry) |entry| {
                try bindType(luaState, entry.T, entry.name);
            }
        }

        pub fn bindType(luaState: *zlua.Lua, comptime T: type, comptime metaTableName: [:0]const u8) !void {
            const startTop = luaState.getTop();

            // Make our new userData and metaTable
            _ = luaState.newUserdata(T, @sizeOf(T));
            _ = try luaState.newMetatable(metaTableName);

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

            if (comptime hasIndexFunc(T)) {
                // Wire to __index in lua
                const indexFunc = struct {
                    fn inner(L: *zlua.Lua) i32 {
                        const ptr = L.checkUserdata(T, 1, metaTableName);
                        return ptr.__index(L);
                    }
                }.inner;

                luaState.pushClosure(zlua.wrap(indexFunc), 0);
                luaState.setField(-2, "__index");
            } else {
                //If no index func was given, index to ourself
                //Metatable.__index = metatable
                //This lets us use 'obj:blah()' method call syntax
                luaState.pushValue(-1);
                luaState.setField(-2, "__index");
            }

            if (comptime hasNewIndexFunc(T)) {
                // Wire to __newindex in lua
                const newIndexFunc = struct {
                    fn inner(L: *zlua.Lua) i32 {
                        const ptr = L.checkUserdata(T, 1, metaTableName);
                        return ptr.__newindex(L);
                    }
                }.inner;

                luaState.pushClosure(zlua.wrap(newIndexFunc), 0);
                luaState.setField(-2, "__newindex");
            }

            // Now wire up our functions!
            const foundFns = comptime findLibraryFunctions(T);
            inline for (foundFns) |foundFunc| {
                luaState.pushClosure(foundFunc.func.?, 0);
                luaState.setField(-2, foundFunc.name);
            }

            // Make this usable with "require" and register our funcs in the library
            luaState.requireF(metaTableName, zlua.wrap(makeLuaOpenLibFn(foundFns)), true);
            luaState.pop(3);

            delve.debug.info("Added lua module: '{s}'", .{metaTableName});
            if (startTop != luaState.getTop()) {
                delve.debug.fatal("Lua binding: leaking stack!", .{});
            }
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

                    if (field_name.len > 0 and field_name[0] != '_') {
                        found = found ++ .{makeLuaBinding(field_name, @field(module, d.name))};
                    }

                    // found = found ++ .{ .name = field_name, .func = zlua.wrap(@field(module, d.name)) };
                }
                return found;
            }
        }

        fn bindStructFuncLua(comptime function: anytype) fn (lua: *Lua) i32 {
            return (opaque {
                pub fn lua_call(luaState: *Lua) i32 {
                    const FnType = @TypeOf(function);

                    // Can't bind types with anytype, so early out if we see one!
                    if (comptime hasAnytypeParam(FnType)) {
                        delve.debug.warning("Cannot call bound function with anytype param", .{});
                        return 0;
                    }

                    // Get a tuple of the various types of the arguments, and then create one
                    const ArgsTuple = std.meta.ArgsTuple(FnType);
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
                                    // Not a registered type, fallback to the default toAny
                                    args[i] = luaState.toAny(param_type, lua_idx) catch {
                                        delve.debug.fatal("Could not convert type {any} to Lua arg", .{param_type});
                                        return 0;
                                    };
                                }
                            },
                            else => {
                                args[i] = luaState.toAny(param_type, lua_idx) catch {
                                    delve.debug.fatal("Could not convert type {any} to Lua arg", .{param_type});
                                    return 0;
                                };
                            },
                        }
                    }

                    if (fn_info.return_type == null) {
                        @compileError("Function has no return type?! This should not be possible.");
                    }

                    const ReturnType = fn_info.return_type.?;

                    // Handle both error union and non-error union function calls
                    const ret_val = switch (@typeInfo(ReturnType)) {
                        .error_union => |_| blk: {
                            const val = @call(.auto, function, args) catch |err| {
                                delve.debug.warning("Error returned from bound Lua function: {any}", .{err});
                                return 0;
                            };

                            break :blk val;
                        },
                        else => @call(.auto, function, args),
                    };

                    const ret_type = @TypeOf(ret_val);

                    // handle registered auto-bound struct types
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

                    // Push the return value onto the stack
                    luaState.pushAny(ret_val) catch |err| {
                        delve.debug.fatal("Error pushing value onto Lua stack! {any}", .{err});
                        return 0;
                    };

                    // Should either be one item, or none
                    switch (ret_type) {
                        void => {
                            return 0;
                        },
                        else => {
                            return 1;
                        },
                    }

                    @compileError("LUA did not return number of return values correctly!");
                }
            }).lua_call;
        }
    };
}

pub fn isErrorUnionType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .error_union => true,
        else => false,
    };
}

fn hasAnytypeParam(comptime T: type) bool {
    const fn_info = @typeInfo(T).@"fn";

    inline for (fn_info.params) |p| {
        if (p.type == null) return true;
        if (@hasField(@TypeOf(p), "is_generic") and p.is_generic) return true;
    }
    return false;
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
            // Register our new library for this type, with all our funcs!
            luaState.newLib(libFuncs);

            return 1;
        }
    }.inner;
}
