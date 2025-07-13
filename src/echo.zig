const std = @import("std");
const net = std.net;
const print = std.debug.print;

pub const EchoServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    isUp: bool = true,
    thread: ?std.Thread = null,

    pub fn run(ctx: *EchoServer) !void {
        var server = try ctx.address.listen(.{
            .reuse_address = true,
        });
        ctx.address = server.listen_address;
        defer server.deinit();

        print("Echo Server listening on {}...\n", .{ctx.address});

        var fds = [_]std.posix.pollfd{
            .{ .fd = server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        while (ctx.isUp) {
            _ = try std.posix.poll(&fds, 100); // 100 ms timeout
            if (fds[0].revents & std.posix.POLL.IN == 0) {
                continue; // no incoming connections
            }

            var client = server.accept() catch |err| {
                print("Echo Failed to accept connection: {}\n", .{err});
                continue;
            };
            defer client.stream.close();

            print("Echo Client connected from: {}\n", .{client.address});

            handleClient(ctx.allocator, &client.stream) catch |err| {
                print("Echo Error handling client: {}\n", .{err});
            };
        }
        print("Echo server shutting down...\n", .{});
    }

    pub fn spawn(ctx: *EchoServer) !void {
        if (ctx.thread != null) {
            return error.AlreadyRunning;
        }

        ctx.thread = try std.Thread.spawn(.{}, run, .{ctx});

        // Wait for the echo server to bind to a port
        while (ctx.address.getPort() == 0) {
            std.time.sleep(std.time.ns_per_ms);
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

fn handleClient(allocator: std.mem.Allocator, stream: *net.Stream) !void {
    var buffer: [1024]u8 = undefined;

    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            print("Client disconnected\n", .{});
            return;
        }

        const received_data = buffer[0..bytes_read];
        print("Received: {s}\n", .{received_data});

        if (std.mem.indexOf(u8, received_data, "quit")) |_| {
            print("Client requested to quit\n", .{});
            return;
        }

        const response = try std.fmt.allocPrint(allocator, "Echo: {s}", .{received_data});
        defer allocator.free(response);

        _ = try stream.writeAll(response);
        print("Sent response to client\n", .{});
    }
}
