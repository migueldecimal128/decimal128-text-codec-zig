const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `-Dverify` arms the compile-gated verify() assertions, the same switch the
    // full decimal128-zig port carries. Off by default: a consumer builds this
    // module into their own program and must not take a panic inside a library
    // on data they do not control. The test step below runs one armed pass.
    const verify_enabled = b.option(bool, "verify", "Arm verify() assertions") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "verify", verify_enabled);

    // The library: one file, no dependencies.
    const mod = b.addModule("decimal128_text_codec", .{
        .root_source_file = b.path("src/decimal128_text_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    // The conformance suite is a SEPARATE module that imports the library, so
    // it reaches only the public surface: the tests exercise the codec exactly
    // as a consumer would, with no reach into its internals.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/corpus_vectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("decimal128_text_codec", mod);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The corpus is read from resources/text_bid_dpd, relative to the project
    // root, so the test binary has to run there rather than in the cache dir.
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run the conformance suite over the shared corpus");
    test_step.dependOn(&run_tests.step);
}
