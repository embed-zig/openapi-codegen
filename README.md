# openapi-codegen

[中文说明](README.zh-CN.md)

`openapi-codegen` is a comptime-first OpenAPI code generator for Zig.
It does not emit a new `generated.zig` file. Instead, it turns an embedded OpenAPI document into Zig types directly during compilation.

## Table of Contents

1. [What This Project Is](#what-this-project-is)
2. [How To Use It](#how-to-use-it)
3. [Acknowledgements](#acknowledgements)

## What This Project Is

This project focuses on compile-time generation:

- Parse an OpenAPI document at comptime with `openapi.json.parse(@embedFile(...))`
- Build typed models with `codegen.models.make(...)`
- Build typed clients with `codegen.client.make(...)`
- Build typed servers with `codegen.server.make(...)`

The key idea is that the generated API lives in Zig's type system, not on disk.

- No extra codegen step that writes files
- No checked-in generated source
- No "run generator, then compile" workflow
- Just embed the spec, call `make(...)`, and use the resulting types

This fits projects that want code generation benefits while keeping everything inside a normal Zig build.

## How To Use It

Add this package and `embed_zig` to your `build.zig.zon` first, either with `zig fetch --save` or with local path dependencies during development.

The smallest integration is often to wrap the generated API in your own library module built with plain `std.Build`.

### `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openapi_codegen = b.dependency("openapi_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_zig = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "demo_api",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openapi", .module = openapi_codegen.module("openapi") },
                .{ .name = "codegen", .module = openapi_codegen.module("codegen") },
                .{ .name = "embed", .module = embed_zig.module("embed") },
                .{ .name = "net", .module = embed_zig.module("net") },
            },
        }),
    });

    b.installArtifact(lib);
}
```

### `src/root.zig`

```zig
const std = @import("std");
const openapi = @import("openapi");
const codegen = @import("codegen");

pub const embed = @import("embed").make(std);

const spec = openapi.json.parse(@embedFile("petstore.json"));
const files: openapi.Files = .{
    .items = &.{
        .{
            .name = "petstore.json",
            .spec = spec,
        },
    },
};

pub const Models = codegen.models.make(files);
pub const ClientApi = codegen.client.make(embed, files);
pub const ServerApi = codegen.server.make(embed, files);
```

This example uses `@import("embed").make(std)` so the generated code can run on top of the normal `std` runtime.

At this point nothing has been written to disk. `Models`, `ClientApi`, and `ServerApi` are compile-time generated Zig types you can re-export from your library.

The generated client keeps transport state inside `ClientApi`, but the public API you expose can absolutely look like `listPets(ctx, args)`.

If you prefer that style, wrap the generated operation handle once in your own module:

```zig
const std = @import("std");
const net = @import("net").make(embed);

pub const ClientContext = struct {
    api: ClientApi,

    pub fn init(
        allocator: std.mem.Allocator,
        http_client: *net.http.Client,
        base_url: []const u8,
    ) !ClientContext {
        return .{
            .api = try ClientApi.init(.{
                .allocator = allocator,
                .http_client = http_client,
                .base_url = base_url,
            }),
        };
    }

    pub fn deinit(self: *ClientContext) void {
        self.api.deinit();
    }
};

pub fn listPets(
    ctx: *ClientContext,
    args: ClientApi.operations.listPets.Args,
) !void {
    var response = try ctx.api.operations.listPets.send(args);
    defer ctx.api.operations.listPets.deinitResponse(&response);

    switch (response) {
        .status_200 => |parsed| {
            _ = parsed;
        },
        else => {},
    }
}
```

Here `listPets` is only an example operation name. In a real project, operation names, argument structs, response unions, and model types come from the OpenAPI document at comptime.

## Acknowledgements

This project is heavily informed by `[oapi-codegen](https://github.com/oapi-codegen/oapi-codegen)`.

- The fixture suite in `tests/oapi-codegen` is sourced from upstream `oapi-codegen`
- The project benefits from the shape of upstream scenarios and compatibility expectations

Thanks to the `oapi-codegen` maintainers and contributors for the excellent reference implementation and test corpus.