const std = @import("std");
const context = @import("context");
const testing_api = @import("testing");
const net_mod = @import("net");
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed_std").std;

const raw_spec = @embedFile("spec.json");

fn files() openapi.Files {
    const spec = openapi.json.parse(raw_spec);
    return .{
        .items = &.{.{ .name = "spec.json", .spec = spec }},
    };
}

const ClientApi = codegen.client.make(embed, files());
const ServerApi = codegen.server.make(embed, files());

const net = @import("net").make(embed);

fn readAllReadCloser(allocator: embed.mem.Allocator, reader: net.http.ReadCloser) ![]u8 {
    defer reader.close();
    var list = try embed.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

const FixedBufferBody = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn read(self: *@This(), buffer: []u8) !usize {
        const remaining = self.bytes[self.offset..];
        const amount = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..amount], remaining[0..amount]);
        self.offset += amount;
        return amount;
    }

    pub fn close(_: *@This()) void {}
};

/// Yields `parts` across multiple `read` calls (streaming upload client).
const ChunkedPartsBody = struct {
    parts: []const []const u8,
    part: usize = 0,
    off: usize = 0,

    pub fn read(self: *@This(), buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            if (self.part >= self.parts.len) return total;
            const cur = self.parts[self.part][self.off..];
            if (cur.len == 0) {
                self.part += 1;
                self.off = 0;
                continue;
            }
            const need = buf.len - total;
            const take = @min(need, cur.len);
            @memcpy(buf[total..][0..take], cur[0..take]);
            total += take;
            self.off += take;
            if (self.off >= self.parts[self.part].len) {
                self.part += 1;
                self.off = 0;
            }
        }
        return total;
    }

    pub fn close(_: *@This()) void {}
};

/// Body returned by `streamDownload`; client must read in chunks via `ReadCloser`.
pub const download_len: usize = 8192;

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    _ = lib;
    return testing_api.TestRunner.fromFn(embed, runStreamExample);
}

fn runStreamExample(t: *testing_api.T, alloc: embed.mem.Allocator) !void {
    var app = AppContext{};
    app.initDownloadPattern();

    var server = try ServerApi.init(alloc, &app, .{
        .streamDownload = Handlers.streamDownload,
        .streamUpload = Handlers.streamUpload,
        .streamBidir = Handlers.streamBidir,
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

    // 1) Stream download — read body incrementally; do not buffer whole response in one slice.
    {
        const resp = try api.operations.streamDownload.send(t.context(), alloc, .{});
        defer resp.deinit();
        switch (resp.value) {
            .status_200 => |reader| {
                var buf: [512]u8 = undefined;
                var total: usize = 0;
                var expect_off: usize = 0;
                while (true) {
                    const n = try reader.read(&buf);
                    if (n == 0) break;
                    for (buf[0..n], 0..) |byte, j| {
                        const exp: u8 = @truncate(expect_off + j);
                        if (byte != exp) return error.StreamDownloadMismatch;
                    }
                    expect_off += n;
                    total += n;
                    if (total > download_len) return error.StreamDownloadTooLong;
                }
                if (total != download_len) return error.StreamDownloadShort;
            },
        }
    }

    // 2) Streaming upload — client body is a `ReadCloser`; server reads in chunks.
    {
        const upload_body = "hello-upload";
        var chunked = ChunkedPartsBody{ .parts = &.{ "hello-", "upload" } };
        const up = try api.operations.streamUpload.send(t.context(), alloc, .{
            .body = net.http.ReadCloser.init(&chunked),
        });
        defer up.deinit();
        switch (up.value) {
            .status_204 => {},
        }
        if (!std.mem.eql(u8, app.last_upload, upload_body)) return error.UploadNotSeen;
    }

    // 3) Bidirectional raw: request and response bodies are streams; echo reads then returns bytes.
    {
        const bidir_in = "echo-me";
        var bidir_body = FixedBufferBody{ .bytes = bidir_in };
        const bd = try api.operations.streamBidir.send(t.context(), alloc, .{
            .body = net.http.ReadCloser.init(&bidir_body),
        });
        defer bd.deinit();
        switch (bd.value) {
            .status_200 => |reader| {
                var buf: [64]u8 = undefined;
                var len: usize = 0;
                while (len < buf.len) {
                    const n = try reader.read(buf[len..]);
                    if (n == 0) break;
                    len += n;
                }
                if (!std.mem.eql(u8, buf[0..len], bidir_in)) return error.BidirMismatch;
            },
        }
    }
}

const AppContext = struct {
    download_body: [download_len]u8 = undefined,
    upload_scratch: [256]u8 = undefined,
    last_upload: []const u8 = "",

    fn initDownloadPattern(self: *@This()) void {
        for (&self.download_body, 0..) |*b, i| {
            b.* = @truncate(i);
        }
    }
};

const Handlers = struct {
    fn streamDownload(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: embed.mem.Allocator,
        args: ServerApi.operations.streamDownload.Args,
    ) !ServerApi.operations.streamDownload.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;
        _ = args;
        return .{ .status_200 = &app.download_body };
    }

    fn streamUpload(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: embed.mem.Allocator,
        args: ServerApi.operations.streamUpload.Args,
    ) !ServerApi.operations.streamUpload.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;
        const reader = args.body;
        defer reader.close();
        var len: usize = 0;
        while (len < app.upload_scratch.len) {
            const n = try reader.read(app.upload_scratch[len..]);
            if (n == 0) break;
            len += n;
        }
        app.last_upload = app.upload_scratch[0..len];
        return .{ .status_204 = {} };
    }

    fn streamBidir(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: embed.mem.Allocator,
        args: ServerApi.operations.streamBidir.Args,
    ) !ServerApi.operations.streamBidir.Response {
        _ = ptr;
        _ = ctx;
        const reader = args.body;
        const echoed = try readAllReadCloser(allocator, reader);
        return .{ .status_200 = echoed };
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
