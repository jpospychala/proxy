const std = @import("std");
const net = std.net;
const log = std.log;
const Thread = std.Thread;

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    dest: net.Address,
    keyword: []const u8,
    server: ?net.Server = undefined,
    isUp: bool = true,
};

pub fn run(config: *ProxyServer) !void {
    config.server = try config.address.listen(.{
        .reuse_address = true,
    });
    config.address = config.server.?.listen_address;
    defer config.server.?.deinit();

    log.info("Proxy listening on {}... Forwarding to {}...", .{ config.address, config.dest });

    while (config.isUp) {
        const client = config.server.?.accept() catch |err| {
            log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        log.info("Client connected from: {}", .{client.address});
        _ = try Thread.spawn(.{}, handleClientThread, .{ config.allocator, &client.stream, config });
    }

    log.info("Proxy server shutting down...", .{});
}

fn handleClientThread(_: std.mem.Allocator, stream: *const net.Stream, config: *const ProxyServer) !void {
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
                log.info("Stream disconnected", .{});
                break;
            }
            log.info("Forwarded {d} bytes to dest", .{bytes_read});
        }
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try forward(&buffer, &dest_stream, stream);
            if (bytes_read == 0) {
                log.info("Dest disconnected", .{});
                break;
            }
            log.info("Forwarded {d} bytes to src", .{bytes_read});
        }
    }
    log.info("Finished forwarding to dest", .{});
}

fn scanAndForward(buffer: *[1024]u8, src: *const net.Stream, dest: *const net.Stream, keyword: []const u8) !usize {
    const bytes_read = try src.read(buffer);
    if (bytes_read == 0) {
        return 0;
    }

    if (std.mem.indexOf(u8, buffer[0..bytes_read], keyword)) |_| {
        log.warn("Keyword '{s}' found in '{s}', dropping...", .{ keyword, buffer[0..bytes_read] });
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
