const testing = @import("testing");
const embed = @import("embed_std").std;
const codegen = @import("codegen");

const sse = codegen.sse.make(embed);
const ownership = @import("sse/ownership/test.zig");
const selection = @import("sse/selection/test.zig");

test "sse" {
    var t = testing.T.new(embed, .unit);
    defer t.deinit();

    t.run("sse/Reader", sse.ReaderTestRunner(embed, testing));
    t.run("sse/Writer", sse.WriterTestRunner(embed, testing));
    t.run("sse/ownership", ownership.TestRunner());
    t.run("sse/selection", selection.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
