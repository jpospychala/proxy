const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const linux = std.os.linux;
const Thread = std.Thread;

pub const CONN_BUF_SIZE = 8096; // size of connection buffer
const CONNS_LIMIT = 4064; // max numer of open connections

pub const Conn = struct {
    srcfd: i32 = 0,
    dstfd: i32 = 0,
};

pub const Link = union(enum) {
    server: i32,
    client: Conn,
};

const Dir = enum { upstream, downstream };

pub fn ProxyServer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        listen_address: net.Address,
        destination: net.Address,
        handler: Handler(T),
        isUp: bool = true,
        pool: Thread.Pool = undefined,

        pub fn run(config: *ProxyServer(T)) !void {
            var server = try config.listen_address.listen(.{
                .reuse_address = true,
            });
            defer server.deinit();
            config.listen_address = server.listen_address;
            log.info("Proxy listening on {f}... Forwarding to {f}...", .{ config.listen_address, config.destination });

            var links = try config.allocator.alloc(?Link, CONNS_LIMIT);
            defer config.allocator.free(links);
            @memset(links, null);
            var linkCtx: [CONNS_LIMIT]*T = undefined;
            for (0..linkCtx.len) |i| {
                linkCtx[i] = try T.init(config.allocator);
            }
            defer {
                for (0..linkCtx.len) |i| {
                    linkCtx[i].deinit(config.allocator);
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
                                const dest_stream = net.tcpConnectToAddress(config.destination) catch |err| {
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

                            const keep = switch (dir) {
                                .downstream => try config.handler.downstream(src, dst, linkCtx[absj]),
                                .upstream => try config.handler.upstream(dst, src, linkCtx[absj]),
                            };

                            if (!keep) {
                                //log.info("Src disconnected", .{});
                                std.posix.close(conn.srcfd); // TODO is it possible that socket closed from the other end would cause some panic here?
                                std.posix.close(conn.dstfd);
                                links[absj] = null;
                                linkCtx[absj].reset();
                            }
                        },
                    }
                }
            }
            log.info("Proxy server shutting down...", .{});
        }

        pub fn spawn(config: *ProxyServer(T)) !void {
            try config.pool.init(.{
                .allocator = config.allocator,
                .n_jobs = 2,
            });

            for (0..config.pool.threads.len) |_| {
                try config.pool.spawn(runNoErr, .{config});
            }

            // Wait for the proxy server to bind to a port
            while (config.listen_address.getPort() == 0) {
                std.Thread.sleep(std.time.ns_per_ms);
            }
        }

        pub fn runNoErr(ctx: *ProxyServer(T)) void {
            ctx.run() catch |err| {
                log.err("Thread failed: {any}\n", .{err});
            };
        }

        pub fn shutdown(config: *ProxyServer(T)) void {
            config.isUp = false;
            config.pool.deinit();
        }
    };
}

pub fn Handler(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            downstream: *const fn (*anyopaque, net.Stream, net.Stream, *T) handlerError!bool,
            upstream: *const fn (*anyopaque, net.Stream, net.Stream, *T) handlerError!bool,
        };

        // returns true = conitnue, false = terminate
        fn downstream(h: *Handler(T), src: net.Stream, dest: net.Stream, ctx: *T) handlerError!bool {
            return h.vtable.downstream(h.ptr, src, dest, ctx);
        }

        // returns true = conitnue, false = terminate
        fn upstream(h: *Handler(T), src: net.Stream, dest: net.Stream, ctx: *T) handlerError!bool {
            return h.vtable.upstream(h.ptr, src, dest, ctx);
        }
    };
}

pub const handlerError = net.Stream.ReadError || net.Stream.WriteError;

fn nextIdx(links: []?Link) ?u32 {
    for (0..links.len) |i| {
        if (links[i] == null) {
            return @intCast(i);
        }
    }
    return null;
}
