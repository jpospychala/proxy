const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);
const Thread = std.Thread;

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    dest: net.Address,
    handler: Handler,
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
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    pub fn shutdown(config: *ProxyServer) void {
        if (config.thread) |t| {
            config.isUp = false;
            t.join();
        }
    }
};

pub const Handler = struct {
    buffer: [1024]u8 = undefined,
    keyword: []const u8,

    fn downstream(this: *@This(), src: net.Stream, dest: net.Stream) !usize {
        const bytes_read = try src.read(&this.buffer);
        if (bytes_read == 0) {
            return 0;
        }

        if (std.mem.indexOf(u8, this.buffer[0..bytes_read], this.keyword)) |_| {
            log.warn("Keyword '{s}' found in '{s}', dropping...", .{ this.keyword, this.buffer[0..bytes_read] });
            return 0; // Drop the packet if keyword is found
        }

        _ = try dest.writeAll(this.buffer[0..bytes_read]);
        return bytes_read;
    }

    fn upstream(this: *@This(), src: net.Stream, dest: net.Stream) !usize {
        const bytes_read = try src.read(&this.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(this.buffer[0..bytes_read]);
        }
        return bytes_read;
    }
};

pub fn run(config: *ProxyServer) !void {
    config.server = config.address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        log.err("Failed to start proxy server: {any}", .{err});
        return err;
    };
    config.address = config.server.?.listen_address;
    defer config.server.?.deinit();

    log.info("Proxy listening on {any}... Forwarding to {any}...", .{ config.address, config.dest });

    var fds = [_]std.posix.pollfd{
        .{ .fd = config.server.?.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = config.allocator,
        .n_jobs = 2,
    });
    defer pool.deinit();

    var i: usize = 0;
    while (config.isUp) {
        _ = try std.posix.poll(&fds, 100); // 100 ms timeout
        if (fds[0].revents & std.posix.POLL.IN == 0) {
            continue; // no incoming connections
        }

        const client = config.server.?.accept() catch |err| {
            log.err("Failed to accept connection: {any}", .{err});
            continue;
        };
        log.debug("{d}, Client connected from: {any} fd {d}", .{ i, client.address, client.stream.handle });
        pool.spawn(handleClientThread, .{ client.stream, config }) catch |err| {
            log.err("Failed to spawn client thread: {any}", .{err});
            client.stream.close();
            continue;
        };
        //handleClientThread(config.allocator, client.stream, config, i);
        i += 1;
    }

    log.info("Proxy server shutting down...", .{});
}

fn handleClientThread(stream: net.Stream, config: *ProxyServer) void {
    defer _ = std.posix.system.close(stream.handle);
    handleClientThreadWithErrs(stream, config) catch |err| {
        log.err("Error handling client: {any}", .{err});
    };
}

fn handleClientThreadWithErrs(stream: net.Stream, config: *ProxyServer) !void {
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
        _ = try std.posix.poll(&fds, 100);

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try config.handler.downstream(stream, dest_stream);
            if (bytes_read == 0) {
                log.info("Stream disconnected", .{});
                break;
            }
            log.debug("Forwarded {d} bytes to dest", .{bytes_read});
        }
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try config.handler.upstream(dest_stream, stream);
            if (bytes_read == 0) {
                log.info("Dest disconnected", .{});
                break;
            }
            log.debug("Forwarded {d} bytes to src", .{bytes_read});
        }
    }
    log.info("Finished forwarding to dest", .{});
}
