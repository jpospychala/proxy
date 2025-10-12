const std = @import("std");
const net = std.net;
const print = std.debug.print;
const linux = std.os.linux;
const log = std.log.scoped(.echo);

pub const EchoServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    isUp: bool = true,
    pool: std.Thread.Pool = undefined,
    n_jobs: usize = 1,

    pub fn runNoErr(ctx: *EchoServer) void {
        ctx.run() catch |err| {
            log.err("Thread failed: {any}\n", .{err});
        };
    }

    pub fn run(ctx: *EchoServer) !void {
        var server = try ctx.address.listen(.{
            .reuse_address = true,
        });
        ctx.address = server.listen_address;
        defer server.deinit();

        log.info("Echo Server listening on {f}...\n", .{ctx.address});

        const epfd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        {
            var e = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = 0 } };
            try std.posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, server.stream.handle, &e);
        }
        while (ctx.isUp) {
            var in_events = [_]linux.epoll_event{.{ .events = linux.EPOLL.IN, .data = .{ .fd = 0 } }};
            const count = linux.epoll_wait(epfd, &in_events, in_events.len, 100); // 100 ms timeout
            if (count < 1) { // TODO ignoring an error -1 here
                continue;
            }

            if (in_events[0].data.u32 == 0) { // server.accept
                const client = server.accept() catch |err| {
                    log.err("Echo Failed to accept connection: {any}\n", .{err});
                    continue;
                };

                {
                    var e = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = client.stream.handle } };
                    try std.posix.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, client.stream.handle, &e);
                }
                log.debug("Echo Client connected from: {f}\n", .{client.address});
            } else { // client socket
                var stream = net.Stream{ .handle = in_events[0].data.fd };
                handleClient(ctx.allocator, &stream) catch |ex| {
                    log.err("Echo Error handling client: {any}\n", .{ex});
                    if (@errorReturnTrace()) |err| {
                        std.debug.dumpStackTrace(err.*);
                    }
                };
            }
        }

        log.info("Echo server shutting down\n", .{});
    }

    pub fn spawn(ctx: *EchoServer) !void {
        try ctx.pool.init(.{
            .allocator = ctx.allocator,
            .n_jobs = ctx.n_jobs,
        });

        for (0..ctx.n_jobs) |_| {
            try ctx.pool.spawn(runNoErr, .{ctx});
        }

        // Wait for the echo server to bind to a port
        while (ctx.address.getPort() == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    pub fn shutdown(ctx: *EchoServer) void {
        ctx.isUp = false;
        ctx.pool.deinit();
    }
};

// utility echo server for testing the proxy
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = EchoServer{
        .allocator = allocator,
        .address = try net.Address.parseIp("127.0.0.1", 8081),
    };
    try context.run();
}

fn handleClient(allocator: std.mem.Allocator, stream: *net.Stream) !void {
    var buffer: [1024]u8 = undefined;

    //std.debug.print("FD {d}\n", .{stream.handle});

    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            log.debug("Echo Client disconnected\n", .{});
            _ = std.posix.system.close(stream.handle);
            return;
        }

        const received_data = buffer[0..bytes_read];
        log.debug("Echo Received: {s}\n", .{received_data});

        if (std.mem.indexOf(u8, received_data, "quit")) |_| {
            log.debug("Echo Client requested to quit\n", .{});
            _ = std.posix.system.close(stream.handle);
            return;
        }

        if (std.mem.indexOf(u8, received_data, "sleep")) |_| {
            log.debug("Echo Client requested to sleep\n", .{});
            std.Thread.sleep(2 * std.time.ns_per_s); // sleep for 2 seconds
        }

        const response = try std.fmt.allocPrint(allocator, "Echo: {s}", .{received_data});
        defer allocator.free(response);

        _ = try stream.writeAll(response);
    }
}
