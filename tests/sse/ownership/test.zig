const testing = @import("testing");
const embed = @import("embed_std").std;
const context_mod = @import("context");
const openapi = @import("openapi");
const codegen = @import("codegen");
const net_mod = @import("net");

const net = net_mod.make(embed);

fn files() openapi.Files {
    const spec = openapi.json.parse(@embedFile("spec.json"));
    return .{
        .items = &.{.{ .name = "sse/ownership/spec.json", .spec = spec }},
    };
}

const ClientApi = codegen.client.make(embed, files());

const CountingBody = struct {
    bytes: []const u8,
    offset: usize = 0,
    close_calls: usize = 0,

    pub fn read(self: *@This(), buffer: []u8) !usize {
        const remaining = self.bytes[self.offset..];
        const amount = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..amount], remaining[0..amount]);
        self.offset += amount;
        return amount;
    }

    pub fn close(self: *@This()) void {
        self.close_calls += 1;
        if (self.close_calls > 1) @panic("body closed twice");
    }
};

const SingleResponseTransport = struct {
    body: *CountingBody,
    headers: [1]net.http.Header,

    pub fn init(body: *CountingBody, content_type: []const u8) @This() {
        return .{
            .body = body,
            .headers = .{net.http.Header.init(net.http.Header.content_type, content_type)},
        };
    }

    pub fn roundTrip(self: *@This(), req: *const net.http.Request) !net.http.Response {
        _ = req;
        return .{
            .status = "200 OK",
            .status_code = 200,
            .header = self.headers[0..],
            .body_reader = net.http.ReadCloser.init(self.body),
        };
    }
};

fn runOwnershipTests(_: *testing.T, allocator: embed.mem.Allocator) !void {
    try runRawOwnershipTest(allocator);
    try runSseOwnershipTest(allocator);
}

fn runRawOwnershipTest(allocator: embed.mem.Allocator) !void {
    var body = CountingBody{ .bytes = "raw-payload" };
    var transport = SingleResponseTransport.init(&body, "application/octet-stream");
    var http_client = try net.http.Client.init(allocator, .{
        .round_tripper = net.http.RoundTripper.init(&transport),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = allocator,
        .http_client = &http_client,
        .base_url = "http://unit.test",
    });
    defer api.deinit();

    var ctx_ns = try context_mod.make(embed).init(allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();
    const resp = try api.operations.streamDownload.send(bg, allocator, .{});
    switch (resp.value) {
        .status_200 => |reader| {
            var buf: [16]u8 = undefined;
            _ = try reader.read(&buf);
            reader.close();
        },
    }

    try embed.testing.expectEqual(@as(usize, 1), body.close_calls);
    resp.deinit();
    try embed.testing.expectEqual(@as(usize, 1), body.close_calls);
}

pub fn TestRunner() testing.TestRunner {
    return testing.TestRunner.fromFn(embed, 1024 * 1024, runOwnershipTests);
}

fn runSseOwnershipTest(allocator: embed.mem.Allocator) !void {
    var body = CountingBody{ .bytes = "event: message\nid: 1\ndata: hello\n\n" };
    var transport = SingleResponseTransport.init(&body, "text/event-stream");
    var http_client = try net.http.Client.init(allocator, .{
        .round_tripper = net.http.RoundTripper.init(&transport),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = allocator,
        .http_client = &http_client,
        .base_url = "http://unit.test",
    });
    defer api.deinit();

    var ctx_ns = try context_mod.make(embed).init(allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();
    const resp = try api.operations.watchEvents.send(bg, allocator, .{});
    switch (resp.value) {
        .status_200 => |*stream| {
            const evt = (try stream.next()) orelse return error.MissingEvent;
            try embed.testing.expectEqualStrings("message", evt.event.?);
            try embed.testing.expectEqualStrings("1", evt.id.?);
            try embed.testing.expectEqualStrings("hello", evt.data.?);
            stream.deinit();
        },
    }

    try embed.testing.expectEqual(@as(usize, 1), body.close_calls);
    resp.deinit();
    try embed.testing.expectEqual(@as(usize, 1), body.close_calls);
}
