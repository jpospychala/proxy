const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const proxy = @import("../proxy.zig");

pub const Copy = struct {
    keyword: []const u8,

    pub fn handler(c: *Copy) proxy.Handler(CopyCtx) {
        return .{
            .ptr = c,
            .vtable = &.{
                .downstream = downstream,
                .upstream = upstream,
            },
        };
    }

    fn upstream(h: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *CopyCtx) proxy.handlerError!usize {
        const this: *Copy = @ptrCast(@alignCast(h));
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read == 0) {
            return 0;
        }

        if (std.mem.indexOf(u8, ctx.buffer[0..bytes_read], this.keyword)) |_| {
            log.warn("Keyword '{s}' found in '{s}', dropping...", .{ this.keyword, ctx.buffer[0..bytes_read] });
            return 0; // Drop the packet if keyword is found
        }

        _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        return bytes_read;
    }

    fn downstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *CopyCtx) proxy.handlerError!usize {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read;
    }
};

pub const CopyCtx = struct {
    buffer: [proxy.CONN_BUF_SIZE]u8 = undefined,

    pub fn init(a: std.mem.Allocator) !*CopyCtx {
        return try a.create(CopyCtx);
    }

    pub fn deinit(ctx: *CopyCtx, a: std.mem.Allocator) void {
        a.destroy(ctx);
    }
};
