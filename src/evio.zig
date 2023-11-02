const std = @import("std");
const builtin = @import("builtin");

const mem = std.mem;
const net = std.net;
const os = std.os;

const Allocator = mem.Allocator;

const Server = struct {
    faulty: ?*Conn = null,
    conns: std.AutoHashMap(os.fd_t, *Conn),
    events: Events,
};

pub const Conn = struct {
    const Self = @This();

    fd: os.fd_t,
    laddr: net.Address,
    raddr: net.Address,
    out: std.ArrayList(u8),
    oidx: usize,
    poller: *Poller,
    allocator: Allocator,
    closed: bool,
    writing: bool,
    faulty: bool,
    next_faulty: ?*Conn,
    server: *Server,
    udata: *anyopaque,

    pub fn close(self: *Self) void {
        if (self.faulty or self.closed) {
            return;
        }
        self.closed = true;
        if (!self.writing) {
            self.writing = true;
            self.poller.modReadWrite(self.fd) catch {
                self.setFault();
            };
        }
    }

    pub fn write(self: *Self, bytes: []const u8) void {
        if (self.faulty or self.closed) {
            return;
        }
        self.out.appendSlice(bytes) catch unreachable;
        if (!self.writing) {
            self.writing = true;
            self.poller.modReadWrite(self.fd) catch {
                self.setFault();
            };
        }
    }

    fn setFault(self: *Self) void {
        self.faulty = true;
        self.next_faulty = self.server.faulty;
        self.server.faulty = self;
    }

    fn destroy(self: *Self) void {
        os.close(self.fd);
        _ = self.server.conns.remove(self.fd);
        if (self.server.events.closed) |closed| {
            closed(self);
        }
        self.out.deinit();
        self.allocator.destroy(self);
    }
};

pub const Events = struct {
    serving: ?*const fn ([]const net.Address) void = null,
    opened: ?*const fn (*Conn) void = null,
    closed: ?*const fn (*Conn) void = null,
    data: ?*const fn (*Conn, []const u8) void = null,
};

pub fn serve(allocator: Allocator, events: Events, addrs: []const net.Address) !void {
    var p = try Poller.init();
    defer p.deinit();

    var lnfds = std.ArrayList(os.fd_t).init(allocator);
    defer {
        for (lnfds.items) |lnfd| {
            os.close(lnfd);
        }
        lnfds.deinit();
    }
    var lnaddrs = std.ArrayList(net.Address).init(allocator);
    defer lnaddrs.deinit();
    for (addrs) |addr| {
        var listen_address = addr;
        const lnfd = try os.socket(listen_address.any.family, os.SOCK.STREAM, 0);
        lnfds.append(lnfd) catch unreachable;

        os.setsockopt(
            lnfd,
            os.SOL.SOCKET,
            os.SO.REUSEADDR,
            &mem.toBytes(@as(c_int, 1)),
        ) catch {};

        var socklen = listen_address.getOsSockLen();
        try os.bind(lnfd, &listen_address.any, socklen);
        try os.listen(lnfd, 128);
        try os.getsockname(lnfd, &listen_address.any, &socklen);
        try setNonblock(lnfd);
        try p.addRead(lnfd);
        try lnaddrs.append(listen_address);
    }

    var server = Server{
        .conns = std.AutoHashMap(os.fd_t, *Conn).init(allocator),
        .events = events,
    };

    if (events.serving) |serving| {
        serving(lnaddrs.items);
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const fds = p.wait();

        while (server.faulty) |faulty| {
            const tmp = faulty.next_faulty;
            faulty.destroy();
            server.faulty = tmp;
        }

        nextfd: for (fds) |fd| {
            for (lnfds.items, 0..) |lnfd, i| {
                if (fd == lnfd) {
                    var accepted_addr: net.Address = undefined;
                    var adr_len: os.socklen_t = @sizeOf(net.Address);
                    const connfd = os.accept(lnfd, &accepted_addr.any, &adr_len, 0) catch |err| switch (err) {
                        error.WouldBlock => continue :nextfd,
                        else => unreachable,
                    };
                    setNonblock(connfd) catch {
                        os.close(connfd);
                        continue :nextfd;
                    };
                    if (lnaddrs.items[i].any.family != os.AF.UNIX) {
                        setKeepalive(connfd) catch {};
                    }
                    p.addRead(connfd) catch {
                        os.close(connfd);
                        continue :nextfd;
                    };
                    const c = allocator.create(Conn) catch unreachable;
                    c.fd = connfd;
                    c.laddr = lnaddrs.items[i];
                    c.raddr = accepted_addr;
                    c.poller = &p;
                    c.out = std.ArrayList(u8).init(allocator);
                    c.allocator = allocator;
                    c.oidx = 0;
                    c.closed = false;
                    c.writing = false;
                    c.faulty = false;
                    c.next_faulty = null;
                    c.server = &server;
                    server.conns.put(connfd, c) catch unreachable;
                    if (events.opened) |opened| {
                        opened(c);
                    }
                    continue :nextfd;
                }
            }

            var conn_opt = server.conns.get(fd);
            if (conn_opt == null) {
                continue;
            }

            var c = conn_opt.?;
            if (c.out.items.len - c.oidx > 0) {
                while (true) {
                    const n = os.write(c.fd, c.out.items[c.oidx..]) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => {
                            c.destroy();
                            break;
                        },
                    };
                    c.oidx += n;
                    if (c.oidx < c.out.items.len) {
                        continue;
                    }
                    break;
                }
                c.oidx = 0;
                if (c.out.capacity > 4096) {
                    c.out.clearAndFree();
                } else {
                    c.out.clearRetainingCapacity();
                }
                if (!c.closed) {
                    c.writing = false;
                    p.modRead(c.fd) catch {};
                }
            } else if (c.closed) {
                c.destroy();
            } else {
                const n = os.read(c.fd, &buf) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        c.destroy();
                        continue;
                    },
                };
                if (n == 0) {
                    c.destroy();
                    continue;
                }
                if (events.data) |data| {
                    data(c, buf[0..n]);
                }
            }
        }
    }
}

const Poller = switch (builtin.os.tag) {
    .linux => @import("./Epoll.zig"),
    .macos => @import("./Kqueue.zig"),
    else => @compileError("unsupported"),
};

fn setNonblock(fd: os.fd_t) !void {
    const flags = try os.fcntl(fd, os.F.GETFL, 0);
    _ = try os.fcntl(fd, os.F.SETFL, flags | os.O.NONBLOCK);
}

fn setKeepalive(fd: os.fd_t) !void {
    try os.setsockopt(fd, os.SOL.SOCKET, os.SO.KEEPALIVE, &mem.toBytes(@as(c_int, 1)));
    if (builtin.os.tag == .linux) {
        try os.setsockopt(fd, os.IPPROTO.TCP, os.TCP.KEEPIDLE, &mem.toBytes(@as(c_int, 600)));
        try os.setsockopt(fd, os.IPPROTO.TCP, os.TCP.KEEPINTVL, &mem.toBytes(@as(c_int, 60)));
        try os.setsockopt(fd, os.IPPROTO.TCP, os.TCP.KEEPCNT, &mem.toBytes(@as(c_int, 6)));
    }
}
