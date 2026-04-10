const testing = @import("testing");
const embed = @import("embed_std").std;

const petstore = @import("examples/petstore/test.zig");
const stream = @import("examples/stream/test.zig");

test "examples/embed_std" {
    var t = testing.T.new(embed, .examples);
    defer t.deinit();

    t.run("petstore", petstore.TestRunner(embed));
    t.run("stream", stream.TestRunner(embed));
    if (!t.wait()) return error.TestFailed;
}
