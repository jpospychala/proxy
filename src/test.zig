const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const echo = @import("echo.zig");
const proxy = @import("proxy.zig");

test "proxy benchmark" {
    std.testing.log_level = .info;

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
        .handler = proxy.Handler{
            .keyword = "bomb",
        },
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();
    defer std.debug.print("shutting down proxy server\n", .{});

    var buffer: [1024]u8 = undefined;
    var recvBuf: [1024]u8 = undefined;
    var n: usize = undefined;

    const count = 10000;
    var errs: usize = 0;
    const start = std.time.milliTimestamp();

    for (0..count) |i| {
        const msg = try std.fmt.bufPrint(&buffer, "Msg {d}", .{i});
        n = proxyReq(&recvBuf, msg, proxyServer.address) catch |err| {
            errs += 1;
            std.debug.print("Error in proxy request: {}\n", .{err});
            continue;
        };
        //const expected = try std.fmt.bufPrint(&buffer, "Echo: Iteration {d}", .{i});
        //try std.testing.expectEqualStrings(expected, recvBuf[0..n]);
    }

    const elapsed = std.time.milliTimestamp() - start;
    const reqs_per_sec = @divTrunc(count * 1000, elapsed);
    std.debug.print("Processed {} requests in {} ms, {} rq/s, {} errors\n", .{
        count,
        elapsed,
        reqs_per_sec,
        errs,
    });
}

test "proxy blocking text" {
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
        .handler = proxy.Handler{
            .keyword = "bomb",
        },
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();

    var recvBuf: [1024]u8 = undefined;
    var n: usize = undefined;

    n = try proxyReq(&recvBuf, "bomb", proxyServer.address);
    try std.testing.expectEqual(0, n);
}

fn proxyReq(buffer: []u8, msg: []const u8, address: net.Address) !usize {
    const client = try net.tcpConnectToAddress(address);
    defer client.close();

    // Get the client's local address (IP + ephemeral port)
    var sockaddr: std.posix.sockaddr = undefined;
    var socklen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(client.handle, &sockaddr, &socklen);

    //const sa: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&sockaddr));
    //const port = std.mem.bigToNative(u16, sa.port);
    //std.debug.print("Test is sending {s} to {f} ephemeral port {d}\n", .{ msg, address, port });
    try client.writeAll(msg);

    return try client.read(buffer);
}
