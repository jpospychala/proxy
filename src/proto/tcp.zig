const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const proxy = @import("../proxy.zig");

pub const TcpCtx = struct {
    buffer: [proxy.CONN_BUF_SIZE]u8 = undefined,

    pub fn init(a: std.mem.Allocator) !*TcpCtx {
        return try a.create(TcpCtx);
    }

    pub fn reset(_: *TcpCtx) void {
        return;
    }

    pub fn deinit(ctx: *TcpCtx, a: std.mem.Allocator) void {
        a.destroy(ctx);
    }
};

pub const Tcp = struct {
    keyword: []const u8,

    pub fn handler(c: *Tcp) proxy.Handler(TcpCtx) {
        return .{
            .ptr = c,
            .vtable = &.{
                .downstream = downstream,
                .upstream = upstream,
            },
        };
    }

    fn upstream(h: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *TcpCtx) proxy.handlerError!bool {
        const this: *Tcp = @ptrCast(@alignCast(h));
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read == 0) {
            return false;
        }

        if (std.mem.indexOf(u8, ctx.buffer[0..bytes_read], this.keyword)) |_| {
            log.warn("Keyword '{s}' found in '{s}', dropping...", .{ this.keyword, ctx.buffer[0..bytes_read] });
            return false; // Drop the packet if keyword is found
        }

        _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        return true;
    }

    fn downstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *TcpCtx) proxy.handlerError!bool {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read > 0;
    }
};
