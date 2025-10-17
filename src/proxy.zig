const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const linux = std.os.linux;
const Thread = std.Thread;

const CONN_BUF_SIZE = 8096; // size of connection buffer
const CONNS_LIMIT = 4064; // max numer of open connections

pub const Conn = struct {
    srcfd: i32 = 0,
    dstfd: i32 = 0,
};

pub const Link = union(enum) {
    server: i32,
    client: Conn,
};

pub const ConnCtx = struct {
    i: usize = 0,
    buffer: [CONN_BUF_SIZE]u8 = @splat(0),
};

const Dir = enum { upstream, downstream };

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    dest: net.Address,
    handler: Handler,
    isUp: bool = true,
    pool: Thread.Pool = undefined,

    pub fn runNoErr(ctx: *ProxyServer) void {
        ctx.run() catch |err| {
            log.err("Thread failed: {any}\n", .{err});
        };
    }

    pub fn run(config: *ProxyServer) !void {
        var server = config.address.listen(.{
            .reuse_address = true,
        }) catch |err| {
            log.err("Failed to start proxy server: {any}", .{err});
            return err;
        };
        config.address = server.listen_address;
        defer server.deinit();
        log.info("Proxy listening on {f}... Forwarding to {f}...", .{ config.address, config.dest });

        var links = try config.allocator.alloc(?Link, CONNS_LIMIT);
        defer config.allocator.free(links);
        @memset(links, null);
        var linkCtx: [CONNS_LIMIT]*ConnCtx = undefined;
        for (0..linkCtx.len) |i| {
            linkCtx[i] = try config.allocator.create(ConnCtx);
        }
        defer {
            for (0..linkCtx.len) |i| {
                config.allocator.destroy(linkCtx[i]);
            }
        }

        links[0] = .{ .server = server.stream.handle };

        const epfd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        {
            var e = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u32 = 0 } };
            try std.posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, server.stream.handle, &e);
        }

        var in_events: [1024]linux.epoll_event = @splat(.{ .events = 0, .data = .{ .u32 = 0 } });
        while (config.isUp) {
            const count = linux.epoll_wait(epfd, &in_events, in_events.len, 100); // 100 ms timeout
            if (count < 0) {
                std.debug.panic("epoll_wait returned -1\n", .{});
            }

            for (0..count) |i| {
                const in_event = in_events[i];
                log.debug("Event {any}\n", .{in_event});
                const absj = @mod(in_event.data.u32, links.len);
                const link = links[absj].?;

                switch (link) {
                    .server => |_| {
                        const client = server.accept() catch |err| {
                            log.err("Proxy Failed to accept connection: {any}\n", .{err});
                            continue;
                        };

                        if (nextIdx(links[0..])) |j| {
                            const dest_stream = net.tcpConnectToAddress(config.dest) catch |err| {
                                log.err("Proxy Failed to connect to upstream {any}\n", .{err});
                                std.posix.close(client.stream.handle);
                                continue;
                            };

                            links[j] = .{ .client = .{ .srcfd = client.stream.handle, .dstfd = dest_stream.handle } };
                            {
                                var e = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.HUP, .data = .{ .u32 = j } };
                                try std.posix.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, client.stream.handle, &e);
                            }
                            {
                                var e = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.HUP, .data = .{ .u32 = j + @as(u32, @intCast(links.len)) } };
                                try std.posix.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, dest_stream.handle, &e);
                            }

                            log.debug("Proxy Client connected from: {f}\n", .{client.address});
                        } else {
                            std.debug.panic("Whops no slot for connection", .{});
                        }
                    },
                    .client => |conn| {
                        const j = in_event.data.u32;

                        const src = net.Stream{ .handle = conn.srcfd };
                        const dst = net.Stream{ .handle = conn.dstfd };

                        const dir: Dir = if (j < links.len) Dir.downstream else Dir.upstream;

                        const bytes_read = switch (dir) {
                            //.downstream => try config.handler.copy(src, dst),
                            .downstream => try config.handler.copyHttp(src, dst, linkCtx[absj]),
                            .upstream => try config.handler.filter(dst, src, linkCtx[absj]),
                        };

                        if (bytes_read == 0) {
                            //log.info("Src disconnected", .{});
                            std.posix.close(conn.srcfd); // TODO is it possible that socket closed from the other end would cause some panic here?
                            std.posix.close(conn.dstfd);
                            links[absj] = null;
                        }
                    },
                }
            }
        }
        log.info("Proxy server shutting down...", .{});
    }

    pub fn spawn(config: *ProxyServer) !void {
        try config.pool.init(.{
            .allocator = config.allocator,
            .n_jobs = 2,
        });

        for (0..config.pool.threads.len) |_| {
            try config.pool.spawn(runNoErr, .{config});
        }

        // Wait for the proxy server to bind to a port
        while (config.address.getPort() == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    pub fn shutdown(config: *ProxyServer) void {
        config.isUp = false;
        config.pool.deinit();
    }
};

pub const Handler = struct {
    keyword: []const u8,

    fn filter(this: *@This(), src: net.Stream, dest: net.Stream, ctx: *ConnCtx) !usize {
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

    fn copy(_: *@This(), src: net.Stream, dest: net.Stream, ctx: *ConnCtx) !usize {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read;
    }

    fn copyHttp(_: *@This(), src: net.Stream, dest: net.Stream, ctx: *ConnCtx) !usize {
        const bytes_read = try src.read(&ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read;
    }
};

fn nextIdx(links: []?Link) ?u32 {
    for (0..links.len) |i| {
        if (links[i] == null) {
            return @intCast(i);
        }
    }
    return null;
}
