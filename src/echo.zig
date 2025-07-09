const std = @import("std");
const net = std.net;
const print = std.debug.print;

// utility echo server for testing the proxy
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try net.Address.parseIp("127.0.0.1", 8081);

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    print("Server listening on {}...\n", .{address});

    while (true) {
        var client = server.accept() catch |err| {
            print("Failed to accept connection: {}\n", .{err});
            continue;
        };
        defer client.stream.close();

        print("Client connected from: {}\n", .{client.address});

        handleClient(allocator, &client.stream) catch |err| {
            print("Error handling client: {}\n", .{err});
        };
    }
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
