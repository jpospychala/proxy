const std = @import("std");
const net = std.net;
const print = std.debug.print;

const log = std.log.scoped(.echo);

pub const EchoServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    isUp: bool = true,
    thread: ?std.Thread = null,
    n_jobs: ?usize = null,

    pub fn run(ctx: *EchoServer) !void {
        var server = try ctx.address.listen(.{
            .reuse_address = true,
        });
        ctx.address = server.listen_address;
        defer server.deinit();

        log.info("Echo Server listening on {any}...\n", .{ctx.address});

        var fds = [_]std.posix.pollfd{
            .{ .fd = server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = ctx.allocator,
            .n_jobs = ctx.n_jobs,
        });
        defer pool.deinit();

        while (ctx.isUp) {
            _ = try std.posix.poll(&fds, 100); // 100 ms timeout
            if (fds[0].revents & std.posix.POLL.IN == 0) {
                continue; // no incoming connections
            }

            var client = server.accept() catch |err| {
                log.err("Echo Failed to accept connection: {any}\n", .{err});
                continue;
            };

            log.debug("Echo Client connected from: {any}\n", .{client.address});

            pool.spawn(handleClientThread, .{ ctx.allocator, &client.stream }) catch |err| {
                log.err("Echo Failed to spawn client handler: {any}\n", .{err});
                continue;
            };
        }
        log.info("Echo server shutting down...\n", .{});
    }

    pub fn spawn(ctx: *EchoServer) !void {
        if (ctx.thread != null) {
            return error.AlreadyRunning;
        }

        ctx.thread = try std.Thread.spawn(.{}, run, .{ctx});

        // Wait for the echo server to bind to a port
        while (ctx.address.getPort() == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    pub fn shutdown(ctx: *EchoServer) void {
        if (ctx.thread) |t| {
            ctx.isUp = false;
            t.join();
        }
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

fn handleClientThread(allocator: std.mem.Allocator, stream: *net.Stream) void {
    defer {
        log.debug("Echo Client disconnected\n", .{});
    }
    handleClient(allocator, stream) catch |ex| {
        log.err("Echo Error handling client: {any}\n", .{ex});
        if (@errorReturnTrace()) |err| {
            std.debug.dumpStackTrace(err.*);
        }
    };
}

fn handleClient(allocator: std.mem.Allocator, stream: *net.Stream) !void {
    var buffer: [1024]u8 = undefined;

    std.debug.print("FD {d}\n", .{stream.handle});

    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            log.info("Echo Client disconnected\n", .{});
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
