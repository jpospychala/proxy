const std = @import("std");
const net = std.net;
const proxy = @import("proxy.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var proxyServer = proxy.ProxyServer{
        .allocator = gpa.allocator(),
        .address = try net.Address.parseIp("127.0.0.1", 8080),
        .dest = try net.Address.parseIp("127.0.0.1", 8081),
        .handler = proxy.Handler{
            .keyword = "bomb",
        },
    };

    try proxy.run(&proxyServer);
}
