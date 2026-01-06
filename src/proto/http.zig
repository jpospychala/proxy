const std = @import("std");
const net = std.net;
const log = std.log.scoped(.proxy);

const proxy = @import("../proxy.zig");

pub const Version = enum {
    Http1_0,
    Http1_1,
    Http2_0,
};

pub const Method = enum {
    Options,
    Get,
    Head,
    Post,
    Put,
    Delete,
    Trace,
    Connect,
};

pub const Request = struct {
    version: Version,
    method: Method,
    uri: []u8,
};

pub const Response = struct {
    code: usize,
};

const HTTP_BUF_SIZE = proxy.CONN_BUF_SIZE / 2;
const CRLF = "\r\n";

pub const ParseState = enum {
    RequestLine,
    RequestHeader,
    RequestBody,
};

pub const ParseError = error{
    UnsupportedMethod,
    UnsupportedVersion,
    InvalidRequest,
};

pub const HttpCtx = struct {
    req: Request,
    res: Response,
    state: ParseState,
    fba: std.heap.FixedBufferAllocator,
    buffer: []u8,
    bufidx: usize,
    parseidx: usize,
    mem: [proxy.CONN_BUF_SIZE]u8 = undefined,

    pub fn init(a: std.mem.Allocator) !*HttpCtx {
        var httpCtx = try a.create(HttpCtx);
        httpCtx.fba = std.heap.FixedBufferAllocator.init(&httpCtx.mem);
        httpCtx.buffer = try httpCtx.fba.allocator().alloc(u8, HTTP_BUF_SIZE);
        httpCtx.reset();
        return httpCtx;
    }

    pub fn reset(ctx: *HttpCtx) void {
        ctx.state = ParseState.RequestLine;
        ctx.bufidx = 0;
        ctx.parseidx = 0;
        ctx.fba.reset();
    }

    pub fn deinit(ctx: *HttpCtx, a: std.mem.Allocator) void {
        a.destroy(ctx);
    }
};

pub const Http = struct {
    pub fn handler(c: *Http) proxy.Handler(HttpCtx) {
        return .{
            .ptr = c,
            .vtable = &.{
                .downstream = downstream,
                .upstream = upstream,
            },
        };
    }

    fn downstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *HttpCtx) proxy.handlerError!bool {
        // const this: *Http = @ptrCast(@alignCast(h));
        const bytes_read = try src.read(ctx.buffer[ctx.bufidx..]);
        if (bytes_read == 0) {
            return false;
        }

        parseRequest(ctx) catch |ex| {
            var buf = [_]u8{0} ** 1024;
            const msg = std.fmt.bufPrint(&buf, "500 {any}\r\n", .{ex}) catch unreachable;
            _ = try src.writeAll(msg);
            return false;
        };

        _ = try dest.writeAll(ctx.buffer[ctx.bufidx .. ctx.bufidx + bytes_read]);
        ctx.bufidx += bytes_read;
        return true;
    }

    fn upstream(_: *anyopaque, src: net.Stream, dest: net.Stream, ctx: *HttpCtx) proxy.handlerError!bool {
        const bytes_read = try src.read(ctx.buffer);
        if (bytes_read > 0) {
            _ = try dest.writeAll(ctx.buffer[0..bytes_read]);
        }
        return bytes_read > 0;
    }
};

fn parseRequest(ctx: *HttpCtx) ParseError!void {
    if (ctx.state == .RequestLine) {
        var methodEndIdx: usize = 0;
        if (std.mem.startsWith(u8, ctx.buffer, "OPTIONS ")) {
            ctx.req.method = Method.Options;
            methodEndIdx = "OPTIONS ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "GET ")) {
            ctx.req.method = Method.Get;
            methodEndIdx = "GET ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "HEAD ")) {
            ctx.req.method = Method.Head;
            methodEndIdx = "HEAD ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "POST ")) {
            ctx.req.method = Method.Post;
            methodEndIdx = "POST ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "PUT ")) {
            ctx.req.method = Method.Put;
            methodEndIdx = "PUT ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "DELETE ")) {
            ctx.req.method = Method.Delete;
            methodEndIdx = "DELETE ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "TRACE ")) {
            ctx.req.method = Method.Trace;
            methodEndIdx = "TRACE ".len;
        } else if (std.mem.startsWith(u8, ctx.buffer, "CONNECT ")) {
            ctx.req.method = Method.Connect;
            methodEndIdx = "CONNECT ".len;
        } else {
            return ParseError.UnsupportedMethod;
        }

        const uriStartIdx = std.mem.indexOfNonePos(u8, ctx.buffer, methodEndIdx, " ") orelse {
            return ParseError.InvalidRequest;
        };
        const uriEndIdx = std.mem.indexOfPos(u8, ctx.buffer, uriStartIdx, " ") orelse {
            return ParseError.InvalidRequest;
        };

        ctx.req.uri = ctx.buffer[uriStartIdx..uriEndIdx];

        const httpVerStartIdx = std.mem.indexOfNonePos(u8, ctx.buffer, uriEndIdx, " ") orelse {
            return ParseError.InvalidRequest;
        };

        if (std.mem.startsWith(u8, ctx.buffer[httpVerStartIdx..], "HTTP/1.0\r\n")) {
            ctx.req.version = .Http1_0;
        } else if (std.mem.startsWith(u8, ctx.buffer[httpVerStartIdx..], "HTTP/1.1\r\n")) {
            ctx.req.version = .Http1_1;
        } else if (std.mem.startsWith(u8, ctx.buffer[httpVerStartIdx..], "HTTP/2.0\r\n")) {
            ctx.req.version = .Http2_0;
        } else {
            // unsupported HTTP version
            return ParseError.UnsupportedVersion;
        }

        ctx.state = .RequestHeader;
        ctx.parseidx = httpVerStartIdx + "HTTP/1.X\r\n".len;
    }

    while (ctx.state == .RequestHeader) {
        if (std.mem.startsWith(u8, ctx.buffer[ctx.parseidx..], "\r\n")) {
            ctx.state = .RequestBody;
            ctx.parseidx += "\r\n".len;
            break;
        }

        const headerKeyEndIdx = std.mem.indexOfPos(u8, ctx.buffer, ctx.parseidx, ": ") orelse {
            return ParseError.InvalidRequest;
        };
        const headerValueStartIdx = std.mem.indexOfNonePos(u8, ctx.buffer, headerKeyEndIdx + 1, " ") orelse {
            return ParseError.InvalidRequest;
        };

        const headerValueEndIdx = std.mem.indexOfPos(u8, ctx.buffer, headerValueStartIdx, "\r\n") orelse {
            return ParseError.InvalidRequest;
        };

        const key = ctx.buffer[ctx.parseidx..headerKeyEndIdx];
        const value = ctx.buffer[headerValueStartIdx..headerValueEndIdx];

        std.debug.print("Header {s}={s}\n", .{ key, value });

        ctx.parseidx = headerValueEndIdx + "\r\n".len;
    }

    // if (ctx.state == .RequestBody) {}
}
