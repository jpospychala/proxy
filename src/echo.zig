const std = @import("std");
const net = std.net;
const print = std.debug.print;

pub const EchoServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    isUp: bool = true,
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
    try run(&context);
}

pub fn run(ctx: *EchoServer) !void {
    var server = try ctx.address.listen(.{
        .reuse_address = true,
    });
    ctx.address = server.listen_address;
    defer server.deinit();

    print("Server listening on {}...\n", .{ctx.address});

    while (ctx.isUp) {
        var client = server.accept() catch |err| {
            print("Failed to accept connection: {}\n", .{err});
            continue;
        };
        defer client.stream.close();

        print("Client connected from: {}\n", .{client.address});

        handleClient(ctx.allocator, &client.stream) catch |err| {
            print("Error handling client: {}\n", .{err});
        };
    }
    print("Server shutting down...\n", .{});
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
