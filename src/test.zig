const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const echo = @import("echo.zig");
const proxy = @import("proxy.zig");

test "end-2-end test" {
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

    var buffer: [1024]u8 = undefined;
    var n = try proxyReq(&buffer, "How are you?", proxyServer.address);
    try std.testing.expectEqualStrings("Echo: How are you?", buffer[0..n]);

    n = try proxyReq(&buffer, "bombing news?", proxyServer.address);
    try std.testing.expectEqual(n, 0);
}

fn proxyReq(buffer: []u8, msg: []const u8, address: net.Address) !usize {
    const client = try net.tcpConnectToAddress(address);
    defer client.close();

    try client.writeAll(msg);

    return try client.read(buffer);
}
