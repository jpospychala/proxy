const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const proxy = @import("../proxy.zig");

pub const Http = struct {

    pub fn handler(c: *Http) proxy.Handler {
        return .{
            .ptr = c,
            .vtable = &.{
                .downstream = downstream,
                .upstream = upstream,
            },
        };
    }

    fn upstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *proxy.ConnCtx) proxy.handlerError!usize {
        // const this: *Http = @ptrCast(@alignCast(h));
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read == 0) {
            return 0;
        }

        _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        return bytes_read;
    }

    fn downstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *proxy.ConnCtx) proxy.handlerError!usize {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read;
    }
};
