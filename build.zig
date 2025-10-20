const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const skip_run = b.option(bool, "skip-run", "Skip running executables during build steps") orelse false;
    const render_max_frames = b.option(u32, "render-max-frames", "Maximum frames before render demo auto-exits (0 = infinite)") orelse 480;

    const exe = b.addExecutable(.{
        .name = "open-world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link system libraries
    exe.linkLibC();

    // Add macOS frameworks for Metal rendering
    if (target.result.os.tag == .macos) {
        exe.addCSourceFile(.{
            .file = b.path("src/rendering/metal_bridge.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });
        exe.linkFramework("Metal");
        exe.linkFramework("MetalKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Cocoa");
        exe.linkFramework("Foundation");

        // SDL2 for window management
        exe.linkSystemLibrary("SDL2");
        exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the open world game");
    run_step.dependOn(&run_cmd.step);

    // Render demo executable
    const render_demo = b.addExecutable(.{
        .name = "render-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    render_demo.linkLibC();
    if (target.result.os.tag == .macos) {
        // Add Objective-C Metal bridge
        render_demo.addCSourceFile(.{
            .file = b.path("src/rendering/metal_bridge.m"),
            .flags = &[_][]const u8{"-fobjc-arc"},
        });

        render_demo.linkFramework("Metal");
        render_demo.linkFramework("MetalKit");
        render_demo.linkFramework("QuartzCore");
        render_demo.linkFramework("Cocoa");
        render_demo.linkFramework("Foundation");
        render_demo.linkSystemLibrary("SDL2");
        render_demo.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        render_demo.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }

    b.installArtifact(render_demo);

    const render_run_cmd = b.addRunArtifact(render_demo);
    render_run_cmd.step.dependOn(b.getInstallStep());
    render_run_cmd.addArgs(&[_][]const u8{
        "--max-frames",
        b.fmt("{d}", .{render_max_frames}),
    });

    const render_step = b.step("render", "Run the rendering demo");
    if (skip_run) {
        render_step.dependOn(b.getInstallStep());
    } else {
        render_step.dependOn(&render_run_cmd.step);
    }

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
