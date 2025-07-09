const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Thread = std.Thread;

const Config = struct {
    address: net.Address,
    dest: net.Address,
    keyword: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config{
        .address = try net.Address.parseIp("127.0.0.1", 8080),
        .dest = try net.Address.parseIp("127.0.0.1", 8081),
        .keyword = "bomb",
    };

    try runServer(allocator, &config);
}

fn runServer(allocator: std.mem.Allocator, config: *const Config) !void {
    var server = try config.address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    print("Proxy listening on {}... Forwarding to {}...\n", .{ config.address, config.dest });

    while (true) {
        const client = server.accept() catch |err| {
            print("Failed to accept connection: {}\n", .{err});
            continue;
        };
        print("Client connected from: {}\n", .{client.address});
        _ = try Thread.spawn(.{}, handleClientThread, .{ allocator, &client.stream, config });
    }
}

fn handleClientThread(_: std.mem.Allocator, stream: *const net.Stream, config: *const Config) !void {
    defer stream.close();
    var buffer: [1024]u8 = undefined;
    const dest_stream = try net.tcpConnectToAddress(config.dest);
    defer dest_stream.close();

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = dest_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = try std.posix.poll(&fds, -1); // -1 means wait forever

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try scanAndForward(&buffer, stream, &dest_stream, config.keyword);
            if (bytes_read == 0) {
                print("Stream disconnected\n", .{});
                break;
            }
            print("Forwarded {d} bytes to dest\n", .{bytes_read});
        }
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try forward(&buffer, &dest_stream, stream);
            if (bytes_read == 0) {
                print("Dest disconnected\n", .{});
                break;
            }
            print("Forwarded {d} bytes to src\n", .{bytes_read});
        }
    }
    print("Finished forwarding to dest\n", .{});
}

fn scanAndForward(buffer: *[1024]u8, src: *const net.Stream, dest: *const net.Stream, keyword: []const u8) !usize {
    const bytes_read = try src.read(buffer);
    if (bytes_read == 0) {
        return 0;
    }

    if (std.mem.indexOf(u8, buffer[0..bytes_read], keyword)) |_| {
        print("Keyword '{s}' found in '{s}', dropping...\n", .{ keyword, buffer[0..bytes_read] });
        return 0; // Drop the packet if keyword is found
    }

    _ = try dest.writeAll(buffer[0..bytes_read]);
    return bytes_read;
}

fn forward(buffer: *[1024]u8, src: *const net.Stream, dest: *const net.Stream) !usize {
    const bytes_read = try src.read(buffer);
    if (bytes_read > 0) {
        _ = try dest.writeAll(buffer[0..bytes_read]);
    }
    return bytes_read;
}
