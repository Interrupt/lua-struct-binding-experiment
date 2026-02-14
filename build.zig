const std = @import("std");
const delve_import = @import("delve");

const appName = "delve-framework-example"; // Determines the name of the generated executable

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const delve = b.dependency("delve", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var app: *std.Build.Step.Compile = undefined;
    if (target.result.cpu.arch.isWasm()) {
        app = b.addLibrary(.{
            .root_module = root_module,
            .name = appName,
            .linkage = .static,
        });
    } else {
        app = b.addExecutable(.{
            .name = appName,
            .root_module = root_module,
        });
    }

    app.root_module.addImport("delve", delve.module("delve"));
    app.linkLibrary(delve.artifact("delve"));

    app.root_module.addImport("sokol", delve.module("sokol"));
    app.root_module.addImport("zlua", delve.module("zlua"));

    if (target.result.cpu.arch.isWasm()) {
        const sokol_dep = delve.builder.dependency("sokol", .{});

        // link with emscripten
        const link_step = try delve_import.emscriptenLinkStep(b, app, sokol_dep);

        // and add a run step
        const run = delve_import.emscriptenRunStep(b, appName, sokol_dep);
        run.step.dependOn(&link_step.step);

        b.step("run", "Run for Web").dependOn(&run.step);
    } else {
        b.installArtifact(app);
        const run = b.addRunArtifact(app);
        b.step("run", "Run").dependOn(&run.step);
    }

    const exe_tests = b.addTest(.{
        .root_module = root_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);

    // Enable ZLS build-on-save (see https://zigtools.org/zls/guides/build-on-save)
    const check = b.step("check", "Check if app compiles");
    check.dependOn(&app.step);
}
