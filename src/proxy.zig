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
    thread: ?Thread = null,

    pub fn spawn(config: *ProxyServer) !void {
        if (config.thread) |_| {
            return error.AlreadyRunning;
        }

        config.thread = try std.Thread.spawn(.{}, run, .{config});
        // Wait for the proxy server to bind to a port
        while (config.address.getPort() == 0) {
            std.time.sleep(std.time.ns_per_ms);
        }
    }

    pub fn shutdown(config: *ProxyServer) void {
        if (config.thread) |t| {
            config.isUp = false;
            t.join();
        }
    }
};

pub fn run(config: *ProxyServer) !void {
    config.server = config.address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        log.err("Failed to start proxy server: {}", .{err});
        return err;
    };
    config.address = config.server.?.listen_address;
    defer config.server.?.deinit();

    log.info("Proxy listening on {}... Forwarding to {}...", .{ config.address, config.dest });

    var fds = [_]std.posix.pollfd{
        .{ .fd = config.server.?.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = config.allocator,
    });
    defer pool.deinit();

    while (config.isUp) {
        _ = try std.posix.poll(&fds, 100); // 100 ms timeout
        if (fds[0].revents & std.posix.POLL.IN == 0) {
            continue; // no incoming connections
        }

        const client = config.server.?.accept() catch |err| {
            log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        log.info("Client connected from: {}", .{client.address});
        try pool.spawn(handleClientThread, .{ config.allocator, &client.stream, config });
    }

    log.info("Proxy server shutting down...", .{});
}

fn handleClientThread(allocator: std.mem.Allocator, stream: *const net.Stream, config: *const ProxyServer) void {
    defer if (config.isUp) stream.close();
    handleClientThreadWithErrs(allocator, stream, config) catch |err| {
        log.err("Error handling client: {}", .{err});
    };
}

fn handleClientThreadWithErrs(_: std.mem.Allocator, stream: *const net.Stream, config: *const ProxyServer) !void {
    var buffer: [1024]u8 = undefined;
    const dest_stream = try net.tcpConnectToAddress(config.dest);
    defer dest_stream.close();
    if (!config.isUp) {
        log.info("Proxy server is shutting down, closing client thread", .{});
        return;
    }

    var fds = [_]std.posix.pollfd{
        .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = dest_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
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
