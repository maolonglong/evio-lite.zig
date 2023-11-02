const std = @import("std");

const linux = os.linux;
const mem = std.mem;
const os = std.os;

const Self = @This();

epfd: os.fd_t,
events: [64]linux.epoll_event = undefined,
evfds: [64]os.fd_t = undefined,

pub fn init() !Self {
    return .{
        .epfd = try os.epoll_create1(0),
    };
}

pub fn deinit(self: *Self) void {
    os.close(self.epfd);
    self.* = undefined;
}

pub fn addRead(self: *Self, fd: os.fd_t) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = fd },
    };
    return os.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
}

pub fn modReadWrite(self: *Self, fd: os.fd_t) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.OUT,
        .data = .{ .fd = fd },
    };
    return os.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

pub fn modRead(self: *Self, fd: os.fd_t) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = fd },
    };
    return os.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

pub fn wait(self: *Self) []os.fd_t {
    const n = os.epoll_wait(self.epfd, &self.events, -1);
    for (0..n) |i| {
        self.evfds[i] = self.events[i].data.fd;
    }
    return self.evfds[0..n];
}
