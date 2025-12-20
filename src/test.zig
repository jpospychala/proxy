const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const echo = @import("echo.zig");
const proxy = @import("proxy.zig");
const tcp = @import("proto/tcp.zig");
const http = @import("proto/http.zig");

const TestCase = struct {
    req: []const []const u8,
    expected: []const u8,
};

test "proxy benchmark" {
    std.testing.log_level = .debug;

    var echoServer: echo.EchoServer = .{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0),
    };
    try echoServer.spawn();
    defer echoServer.shutdown();

    var tcpH = tcp.Tcp{
        .keyword = "bomb",
    };
    var proxyServer = proxy.ProxyServer(tcp.TcpCtx){
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0), // random port for proxy
        .dest = try net.Address.parseIp("127.0.0.1", echoServer.address.getPort()),
        .handler = tcpH.handler(),
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();
    defer std.debug.print("shutting down proxy server\n", .{});

    var buffer: [1024]u8 = undefined;
    var actual: [1024]u8 = undefined;

    const count = 10000;
    var errs: usize = 0;
    const start = std.time.milliTimestamp();

    for (0..count) |i| {
        const msg = try std.fmt.bufPrint(&buffer, "Msg {d}", .{i});
        const n = proxyReq(&actual, msg, proxyServer.address) catch |err| {
            errs += 1;
            std.debug.print("Error in proxy request: {}\n", .{err});
            continue;
        };
        const expected = try std.fmt.bufPrint(&buffer, "Echo: Msg {d}", .{i});
        try std.testing.expectEqualStrings(expected, actual[0..n]);
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

test "http parsing pub" {
    const cases = [_]TestCase{
        .{
            .req = &([_][]const u8{ "GET / HT", "TP/1.0\r\nHeader1", ": Value1\r\nH2: V2\r\n\r\n" }),
            .expected = "Echo: GET / HTTP/1.0\r\nHeader1: Value1\r\nH2: V2\r\n\r\n",
        },
    };

    var actual: [1024]u8 = undefined;
    for (cases) |tc| {
        const n = try proxyReq3(&actual, tc.req, "www.example.com", 80);
        try std.testing.expectEqualStrings(tc.expected, actual[0..n]);
    }
}

test "http parsing" {
    const cases = [_]TestCase{
        .{
            .req = &([_][]const u8{"GET / CRUMBLES\r\n\r\n"}),
            .expected = "500 error.UnsupportedVersion\r\n",
        },
        .{
            .req = &([_][]const u8{"GET / HTTP/1.0\r\n\r\n"}),
            .expected = "Echo: GET / HTTP/1.0\r\n\r\n",
        },
        .{
            .req = &([_][]const u8{ "GET / HT", "TP/1.0\r\nHeader1", ": Value1\r\nH2: V2\r\n\r\n" }),
            .expected = "Echo: GET / HTTP/1.0\r\nHeader1: Value1\r\nH2: V2\r\n\r\n",
        },
    };

    std.testing.log_level = .warn;

    var echoServer: echo.EchoServer = .{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0),
    };
    try echoServer.spawn();
    defer echoServer.shutdown();

    var httpH = http.Http{};
    var proxyServer = proxy.ProxyServer(http.HttpCtx){
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0), // random port for proxy
        .dest = try net.Address.parseIp("127.0.0.1", echoServer.address.getPort()),
        .handler = httpH.handler(),
    };
    try proxyServer.spawn();
    defer proxyServer.shutdown();

    var actual: [1024]u8 = undefined;
    for (cases) |tc| {
        const n = try proxyReq2(&actual, tc.req, proxyServer.address);
        try std.testing.expectEqualStrings(tc.expected, actual[0..n]);
    }
}

test "proxy blocking text" {
    std.testing.log_level = .warn;

    var echoServer: echo.EchoServer = .{
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0),
    };
    try echoServer.spawn();
    defer echoServer.shutdown();

    var tcpH = tcp.Tcp{
        .keyword = "bomb",
    };
    var proxyServer = proxy.ProxyServer(tcp.TcpCtx){
        .allocator = std.testing.allocator,
        .address = try net.Address.parseIp("127.0.0.1", 0), // random port for proxy
        .dest = try net.Address.parseIp("127.0.0.1", echoServer.address.getPort()),
        .handler = tcpH.handler(),
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

fn proxyReq2(buffer: []u8, msgs: []const []const u8, address: net.Address) !usize {
    const client = try net.tcpConnectToAddress(address);
    defer client.close();

    // Get the client's local address (IP + ephemeral port)
    var sockaddr: std.posix.sockaddr = undefined;
    var socklen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(client.handle, &sockaddr, &socklen);

    for (msgs) |msg| {
        try client.writeAll(msg);
    }

    return try client.read(buffer);
}

fn proxyReq3(buffer: []u8, msgs: []const []const u8, host: []const u8, port: u16) !usize {
    const client = try net.tcpConnectToHost(std.testing.allocator, host, port);
    defer client.close();

    // Get the client's local address (IP + ephemeral port)
    var sockaddr: std.posix.sockaddr = undefined;
    var socklen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(client.handle, &sockaddr, &socklen);

    for (msgs) |msg| {
        try client.writeAll(msg);
    }

    return try client.read(buffer);
}
