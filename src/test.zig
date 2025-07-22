const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const echo = @import("echo.zig");
const proxy = @import("proxy.zig");

test "echo test" {
    if (true) return error.skipZigTest;
    std.testing.log_level = .warn;

    var echoServer: echo.EchoServer = .{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0),
    };
    try echoServer.spawn();
    defer echoServer.shutdown();

    var buffer: [1024]u8 = undefined;
    var recvBuf: [1024]u8 = undefined;
    var n: usize = undefined;
    for (0..10000) |i| {
        const msg = try std.fmt.bufPrint(&buffer, "Iteration {d}", .{i});
        n = proxyReq(&recvBuf, msg, echoServer.address) catch |err| {
            std.debug.print("Error in proxy request: {}\n", .{err});
            continue;
        };
        const expected = try std.fmt.bufPrint(&buffer, "Echo: Iteration {d}", .{i});
        try std.testing.expectEqualStrings(expected, recvBuf[0..n]);
    }
    //n = try proxyReq(&buffer, "bombing news?", proxyServer.address);
    //try std.testing.expectEqual(n, 0);
}

test "end-2-end test" {
    std.testing.log_level = .warn;

    var echoServer: echo.EchoServer = .{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0),
    };
    try echoServer.spawn();
    defer echoServer.shutdown();

    var proxyServer = proxy.ProxyServer{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0), // random port for proxy
        .dest = try net.Address.parseIp("127.0.0.1", echoServer.address.getPort()),
        .keyword = "bomb",
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();
    defer std.debug.print("shutting down proxy server\n", .{});

    var buffer: [1024]u8 = undefined;
    var recvBuf: [1024]u8 = undefined;
    var n: usize = undefined;
    for (0..1000) |i| {
        const msg = try std.fmt.bufPrint(&buffer, "Msg {d}", .{i});
        n = proxyReq(&recvBuf, msg, proxyServer.address) catch |err| {
            std.debug.print("Error in proxy request: {}\n", .{err});
            continue;
        };
        //const expected = try std.fmt.bufPrint(&buffer, "Echo: Iteration {d}", .{i});
        //try std.testing.expectEqualStrings(expected, recvBuf[0..n]);
    }
    //n = try proxyReq(&buffer, "bombing news?", proxyServer.address);
    //try std.testing.expectEqual(n, 0);
}

fn proxyReq(buffer: []u8, msg: []const u8, address: net.Address) !usize {
    const client = try net.tcpConnectToAddress(address);
    defer client.close();

    // Get the client's local address (IP + ephemeral port)
    var sockaddr: std.posix.sockaddr = undefined;
    var socklen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(client.handle, &sockaddr, &socklen);

    const sa: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&sockaddr));
    _ = std.mem.bigToNative(u16, sa.port);
    // std.debug.print("Test is sending {s} to {any} ephemeral port {d}\n", .{ msg, address, port });
    try client.writeAll(msg);

    return try client.read(buffer);
}
