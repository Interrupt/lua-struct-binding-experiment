const std = @import("std");
const delve = @import("delve");
const app = delve.app;

const lua = delve.scripting.lua;
const scripting_manager = delve.scripting.manager;
const lua_module = delve.module.lua_simple;

const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaComponent = @import("luacomponent.zig").LuaComponent;

const luaTypeBinder = @import("luatypebinder.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const TestStructTwo = struct {};

const MyTestStruct = struct {
    val: i32,

    pub fn init() MyTestStruct {
        delve.debug.log("MyTestStruct init!", .{});
        return MyTestStruct{
            .val = 0,
        };
    }

    pub fn set(self: *MyTestStruct, newVal: i32) void {
        self.val = newVal;
    }

    pub fn add(self: *MyTestStruct, other: *MyTestStruct) i32 {
        self.val = self.val + other.val;
        return self.val;
    }

    pub fn getVal(self: *MyTestStruct) i32 {
        return self.val;
    }

    pub fn destroy(self: *MyTestStruct) void {
        _ = self;
        delve.debug.log("MyTestStruct destroy!", .{});
    }

    pub fn copy(self: *MyTestStruct) MyTestStruct {
        return self.*;
    }

    pub fn getTitle(self: *MyTestStruct) Title {
        _ = self;
        return .{ .title = "This is a new Title, returned from MyTestStruct!" };
    }

    pub fn getString(self: *MyTestStruct) [:0]const u8 {
        _ = self;
        return "Hello World String";
    }
};

const Title = struct {
    title: [:0]const u8,

    pub fn init() Title {
        delve.debug.log("Title init!", .{});
        return Title{ .title = "This is a title from Lua!" };
    }

    pub fn destroy(self: *Title) void {
        _ = self;
        delve.debug.log("Title destroy!", .{});
    }

    pub fn getTitle(self: *Title) [:0]const u8 {
        return self.title;
    }
};

pub fn main() !void {
    // Pick the allocator to use depending on platform
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) {
        // Web builds hack: use the C allocator to avoid OOM errors
        // See https://github.com/ziglang/zig/issues/19072
        try delve.init(std.heap.c_allocator);
    } else {
        try delve.init(gpa.allocator());
    }

    // create our module
    const example_module = delve.modules.Module{
        .name = "lua-example",
        .init_fn = on_init,
        .draw_fn = on_draw,
    };

    try delve.modules.registerModule(example_module);
    try lua_module.registerModule("assets/main.lua");

    // Note: Delve Framework expects there to be an assets directory
    try app.start(app.AppConfig{ .title = "Delve Framework Lua Example" });
}

pub fn on_init() !void {
    delve.debug.log("Initializing example!", .{});
    try scripting_manager.init();

    // Manually interact with Lua
    const lua_state = lua.getLua();

    const luaTypeRegistry = luaTypeBinder.Registry(&[_]luaTypeBinder.BoundType{
        .{ .T = MyTestStruct, .name = "MyTestStruct" },
        .{ .T = Title, .name = "Title" },
        .{ .T = delve.math.Vec3, .name = "Vec3" },
        .{ .T = delve.math.Vec3, .name = "Vec4" },
        .{ .T = delve.math.Vec3, .name = "Vec5" },
        .{ .T = delve.math.Vec3, .name = "Vec6" },
        .{ .T = delve.math.Vec3, .name = "Vec7" },
        .{ .T = LuaComponent, .name = "LuaComponent" },
    });

    try luaTypeRegistry.bindTypes(lua_state);

    // Manually run the lua file
    // lua_state.doFile("assets/main.lua") catch |err| {
    //     const lua_error = lua_state.toString(-1) catch {
    //         delve.debug.log("Lua: could not get error string", .{});
    //         return err;
    //     };
    //
    //     delve.debug.log("Lua: error running file! {s}", .{lua_error});
    //     return err;
    // };
}

pub fn on_draw() void {
    delve.platform.graphics.setClearColor(delve.colors.Color.new(0.1, 0.1, 0.15, 1));
    // delve.platform.graphics.drawDebugText(44, 40, "Hello Delve Framework!");
}
