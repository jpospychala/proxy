const std = @import("std");
const net = std.net;
const proxy = @import("proxy.zig");
const http = @import("proto/http.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var httpH = http.Http{};
    var proxyServer = proxy.ProxyServer(http.HttpCtx){
        .allocator = gpa.allocator(),
        .listen_address = try net.Address.parseIp("127.0.0.1", 8080),
        .destination = try net.Address.parseIp("127.0.0.1", 8081),
        .handler = httpH.handler(),
    };

    try proxyServer.run();
}

test {
    _ = @import("./test.zig");
}
