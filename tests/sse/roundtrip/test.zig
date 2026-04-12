const context = @import("context");
const testing_api = @import("testing");
const net_mod = @import("net");
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed_std").std;
const sse = codegen.sse.make(embed);
const net = @import("net").make(embed);

const raw_spec = @embedFile("spec.json");

fn files() openapi.Files {
    const spec = openapi.json.parse(raw_spec);
    return .{
        .items = &.{.{ .name = "spec.json", .spec = spec }},
    };
}

const ClientApi = codegen.client.make(embed, files());
const ServerApi = codegen.server.make(embed, files());

fn runSseRoundtripTest(t: *testing_api.T, alloc: embed.mem.Allocator) !void {
    var app = AppContext{};

    var server = try ServerApi.init(alloc, &app, .{
        .watchEvents = Handlers.watchEvents,
    });
    defer server.deinit();

    var srv_run = try startServer(&server);
    defer srv_run.stop(&server) catch {};

    const base_url = try embed.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{srv_run.port});
    defer alloc.free(base_url);

    var transport = try net.http.Transport.init(alloc, .{});
    defer transport.deinit();
    var http_client = try net.http.Client.init(alloc, .{
        .round_tripper = transport.roundTripper(),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = alloc,
        .http_client = &http_client,
        .base_url = base_url,
    });
    defer api.deinit();

    const resp = try api.operations.watchEvents.send(t.context(), alloc, .{});
    defer resp.deinit();

    switch (resp.value) {
        .status_200 => |*stream| {
            defer stream.deinit();
            expectReaderType(stream.*);

            var index: usize = 0;
            while (try stream.next()) |evt| : (index += 1) {
                switch (index) {
                    0 => {
                        try embed.testing.expectEqualStrings("message", evt.event.?);
                        try embed.testing.expectEqualStrings("1", evt.id.?);
                        try embed.testing.expectEqualStrings("hello", evt.data.?);
                    },
                    1 => {
                        try embed.testing.expectEqualStrings("message", evt.event.?);
                        try embed.testing.expectEqualStrings("2", evt.id.?);
                        try embed.testing.expectEqualStrings("multi\nline", evt.data.?);
                    },
                    2 => {
                        try embed.testing.expectEqual(@as(?u64, 2500), evt.retry);
                        try embed.testing.expectEqual(@as(bool, true), evt.event == null);
                        try embed.testing.expectEqual(@as(bool, true), evt.id == null);
                        try embed.testing.expectEqual(@as(bool, true), evt.data == null);
                    },
                    else => return error.UnexpectedExtraEvent,
                }
            }

            try embed.testing.expectEqual(@as(usize, 3), index);
            try embed.testing.expectEqual(@as(usize, 3), app.sent_events);
        },
    }
}

fn expectReaderType(_: sse.Reader) void {}

const AppContext = struct {
    sent_events: usize = 0,
};

const Handlers = struct {
    fn watchEvents(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: embed.mem.Allocator,
        args: ServerApi.operations.watchEvents.Args,
    ) !ServerApi.operations.watchEvents.Response {
        _ = ctx;
        _ = allocator;
        _ = args;
        return .{
            .status_200 = .{
                .ptr = ptr,
                .send = streamEvents,
            },
        };
    }

    fn streamEvents(ptr: *anyopaque, writer: *sse.Writer) !void {
        const app: *AppContext = @ptrCast(@alignCast(ptr));

        try writer.event(.{
            .event = "message",
            .id = "1",
            .data = "hello",
        });
        try writer.flush();
        app.sent_events += 1;

        try writer.event(.{
            .event = "message",
            .id = "2",
            .data = "multi\nline",
        });
        try writer.flush();
        app.sent_events += 1;

        try writer.event(.{
            .retry = 2500,
        });
        try writer.flush();
        app.sent_events += 1;
    }
};

const ServerRun = struct {
    listener: net_mod.Listener,
    port: u16,
    server_err: ?anyerror = null,
    thread: embed.Thread,

    fn stop(self: *@This(), server: *ServerApi) !void {
        self.listener.close();
        server.close();
        self.thread.join();
        defer self.listener.deinit();
        if (self.server_err) |err| {
            if (err != error.ServerClosed) return err;
        }
    }
};

fn startServer(server: *ServerApi) !ServerRun {
    const listener = try net.listen(server.shared.allocator, .{
        .address = net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
    });
    const tcp_listener = try listener.as(net.TcpListener);
    const port = try tcp_listener.port();

    var srv_run = ServerRun{
        .listener = listener,
        .port = port,
        .thread = undefined,
    };
    srv_run.thread = try embed.Thread.spawn(.{}, struct {
        fn exec(s: *ServerApi, ln: net_mod.Listener, err: *?anyerror) void {
            s.serve(ln) catch |serve_err| {
                err.* = serve_err;
            };
        }
    }.exec, .{ server, listener, &srv_run.server_err });
    return srv_run;
}

pub fn TestRunner() testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(embed, 1024 * 1024, runSseRoundtripTest);
}
