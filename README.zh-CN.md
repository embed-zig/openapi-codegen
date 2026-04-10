# openapi-codegen

[English](README.md)

`openapi-codegen` 是一个以 comptime 为核心的 Zig OpenAPI 代码生成库。
它不会额外产出一个新的 `generated.zig` 文件，而是在编译期把嵌入进来的 OpenAPI 文档直接转成 Zig 类型。

## 目录

1. [这是什么项目](#这是什么项目)
2. [如何使用](#如何使用)
3. [致谢](#致谢)

## 这是什么项目

这个项目的重点是编译期生成：

- 用 `openapi.json.parse(@embedFile(...))` 在 comptime 解析 OpenAPI 文档
- 用 `codegen.models.make(...)` 生成强类型 models
- 用 `codegen.client.make(...)` 生成强类型 client
- 用 `codegen.server.make(...)` 生成强类型 server

最重要的一点是：生成结果存在于 Zig 的类型系统里，而不是磁盘上的新文件里。

- 不需要额外跑一个会写文件的 codegen 步骤
- 不需要提交生成产物
- 不需要维护“先生成、再编译”的工作流
- 只需要嵌入 spec、调用 `make(...)`，然后直接使用返回的类型

这很适合希望享受代码生成的收益，但又想把整个流程保持在标准 Zig 构建里的项目。

## 如何使用

先在你的 `build.zig.zon` 里加入本项目和 `embed_zig`，可以用 `zig fetch --save`，也可以在本地开发时直接配 path dependency。

最简单的接入方式，是用最普通的 `std.Build` 做一个自己的库模块，然后在这个模块里把 comptime 生成出来的 API 暴露出去。

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

这个示例通过 `@import("embed").make(std)` 把生成出来的代码接到普通的 `std` 运行时上。

到这里为止，磁盘上依然不会多出任何生成文件。`Models`、`ClientApi`、`ServerApi` 都是编译期生成出来的 Zig 类型，你可以直接从自己的库里 re-export。

生成出来的 client 会把 transport state 放在 `ClientApi` 里，但你对外暴露的接口完全可以写成 `listPets(ctx, args)` 这种风格。

如果你更喜欢这种写法，可以在自己的模块里很薄地包一层：

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

这里的 `listPets` 只是示例 operation 名。实际项目里的 operation 名、参数结构、响应 union、model 类型，都会在 comptime 根据 OpenAPI 文档推导出来。

## 致谢

这个项目在设计思路和测试覆盖上，明显受到了 [`oapi-codegen`](https://github.com/oapi-codegen/oapi-codegen) 的启发。

- `tests/oapi-codegen` 里的 fixtures 来自上游 `oapi-codegen`
- 许多兼容性场景和行为预期也参考了上游测试体系

感谢 `oapi-codegen` 的维护者和贡献者，提供了非常好的参考实现与测试语料。
