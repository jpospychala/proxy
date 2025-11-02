const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const proxy = @import("../proxy.zig");

pub const Http = struct {
    pub fn handler(c: *Http) proxy.Handler(HttpCtx) {
        return .{
            .ptr = c,
            .vtable = &.{
                .downstream = downstream,
                .upstream = upstream,
            },
        };
    }

    fn upstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *HttpCtx) proxy.handlerError!usize {
        // const this: *Http = @ptrCast(@alignCast(h));
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read == 0) {
            return 0;
        }

        _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        return bytes_read;
    }

    fn downstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *HttpCtx) proxy.handlerError!usize {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read;
    }
};

pub const HttpCtx = struct {
    buffer: [proxy.CONN_BUF_SIZE]u8 = undefined,

    pub fn init(a: std.mem.Allocator) !*HttpCtx {
        return try a.create(HttpCtx);
    }

    pub fn deinit(ctx: *HttpCtx, a: std.mem.Allocator) void {
        a.destroy(ctx);
    }
};
