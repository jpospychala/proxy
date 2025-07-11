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
    const echoT = try Thread.spawn(.{}, echo.run, .{&echoServer});
    defer echoT.join();
    defer echoServer.isUp = false;

    // Wait for the echo server to bind to a port
    while (echoServer.address.getPort() == 0) {
        std.time.sleep(std.time.ns_per_ms);
    }

    var config = proxy.ProxyServer{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0), // random port for proxy
        .dest = try net.Address.parseIp("127.0.0.1", echoServer.address.getPort()),
        .keyword = "bomb",
    };
    _ = try Thread.spawn(.{}, proxy.run, .{&config});
    defer config.isUp = false;

    // Wait for the echo server to bind to a port
    while (config.address.getPort() == 0) {
        std.time.sleep(std.time.ns_per_ms);
    }

    const client = try net.tcpConnectToAddress(try net.Address.parseIp("127.0.0.1", config.address.getPort()));
    try client.writeAll("How are you?");
    defer client.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try client.read(&buffer);

    try std.testing.expectEqualStrings("Echo: How are you?", buffer[0..bytes_read]);
}
