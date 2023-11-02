const std = @import("std");
const evio = @import("evio");

fn serving(lnaddrs: []const std.net.Address) void {
    std.debug.print("serving: {any}\n", .{lnaddrs});
}

fn opened(c: *evio.Conn) void {
    std.debug.print("opened: remote_addr={}, local_addr={}\n", .{ c.raddr, c.laddr });
}

fn data(c: *evio.Conn, in: []const u8) void {
    c.write(in);
}

fn closed(c: *evio.Conn) void {
    std.debug.print("closed: remote_addr={}, local_addr={}\n", .{ c.raddr, c.laddr });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try evio.serve(
        gpa.allocator(),
        .{
            .serving = serving,
            .opened = opened,
            .data = data,
            .closed = closed,
        },
        &[_]std.net.Address{
            try std.net.Address.parseIp4("127.0.0.1", 8081),
            try std.net.Address.parseIp4("127.0.0.1", 8082),
            try std.net.Address.initUnix("echo.sock"),
        },
    );
}
