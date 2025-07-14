const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const echo = @import("echo.zig");
const proxy = @import("proxy.zig");

test "end-2-end test" {
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
        .keyword = "bomb",
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();
    defer std.debug.print("shutting down proxy server\n", .{});

    var buffer: [1024]u8 = undefined;
    var n: usize = undefined;
    for (0..125) |_| {
        n = try proxyReq(&buffer, "How are you?", proxyServer.address);
        try std.testing.expectEqualStrings("Echo: How are you?", buffer[0..n]);
    }

    n = try proxyReq(&buffer, "bombing news?", proxyServer.address);
    try std.testing.expectEqual(n, 0);
}

fn proxyReq(buffer: []u8, msg: []const u8, address: net.Address) !usize {
    const client = try net.tcpConnectToAddress(address);
    defer client.close();

    try client.writeAll(msg);

    return try client.read(buffer);
}
