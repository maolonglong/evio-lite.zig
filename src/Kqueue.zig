const std = @import("std");
const os = std.os;
const darwin = os.darwin;

const Self = @This();

kq: os.fd_t,
events: [64]os.Kevent = undefined,
evfds: [64]os.fd_t = undefined,

pub fn init() !Self {
    return .{
        .kq = try os.kqueue(),
    };
}

pub fn deinit(self: *Self) void {
    os.close(self.kq);
    self.* = undefined;
}

pub fn addRead(self: *Self, fd: os.fd_t) !void {
    var ev = os.Kevent{
        .ident = @intCast(fd),
        .filter = darwin.EVFILT_READ,
        .flags = darwin.EV_ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = try os.kevent(self.kq, &[_]os.Kevent{ev}, &[_]os.Kevent{}, null);
}

pub fn modReadWrite(self: *Self, fd: os.fd_t) !void {
    var ev = os.Kevent{
        .ident = @intCast(fd),
        .filter = darwin.EVFILT_WRITE,
        .flags = darwin.EV_ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = try os.kevent(self.kq, &[_]os.Kevent{ev}, &[_]os.Kevent{}, null);
}

pub fn modRead(self: *Self, fd: os.fd_t) !void {
    var ev = os.Kevent{
        .ident = @intCast(fd),
        .filter = darwin.EVFILT_WRITE,
        .flags = darwin.EV_DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = try os.kevent(self.kq, &[_]os.Kevent{ev}, &[_]os.Kevent{}, null);
}

pub fn wait(self: *Self) []os.fd_t {
    const n = os.kevent(self.kq, &[_]os.Kevent{}, &self.events, null) catch unreachable;
    for (0..n) |i| {
        self.evfds[i] = @intCast(self.events[i].ident);
    }
    return self.evfds[0..n];
}
