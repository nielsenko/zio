const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const net = os.net;

const Loop = ev.Loop;
const NetRecvMulti = ev.NetRecvMulti;

/// A NetRecvMulti that collects what it is handed.
const Collector = struct {
    recv: NetRecvMulti,
    buffer: [32]u8 = undefined,
    got: [4096]u8 = undefined,
    len: usize = 0,
    chunks: usize = 0,
    done: bool = false,

    fn start(self: *Collector, loop: *Loop, handle: net.fd_t) void {
        self.recv = .init(handle, &self.buffer, onData);
        self.recv.c.callback = onDone;
        loop.add(&self.recv.c);
    }

    fn onData(recv: *NetRecvMulti, bytes: []const u8) void {
        const self: *Collector = @fieldParentPtr("recv", recv);
        @memcpy(self.got[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.chunks += 1;
    }

    fn onDone(_: *Loop, c: *ev.Completion) void {
        const recv: *NetRecvMulti = @fieldParentPtr("c", c);
        const self: *Collector = @fieldParentPtr("recv", recv);
        self.done = true;
    }

    fn pollUntil(self: *Collector, loop: *Loop, len: usize) !void {
        var rounds: usize = 0;
        while (self.len < len and !self.done and rounds < 1000) : (rounds += 1) {
            try loop.poll(.fromMilliseconds(10));
        }
    }
};

fn send(fd: net.fd_t, bytes: []const u8) !void {
    var iov = [_]net.iovec_const{net.iovecConstFromSlice(bytes)};
    var sent: usize = 0;
    while (sent < bytes.len) {
        iov[0] = net.iovecConstFromSlice(bytes[sent..]);
        sent += try net.send(fd, &iov, .{});
    }
}

fn pair() ![2]net.fd_t {
    return net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
}

fn chunksUntilClose(options: Loop.Options) !void {
    var loop: Loop = undefined;
    try loop.init(options);
    defer loop.deinit();
    const fds = try pair();
    defer net.close(fds[0]);

    var collector: Collector = .{ .recv = undefined };
    collector.start(&loop, fds[0]);
    try loop.poll(.zero);
    try send(fds[1], "one");
    try collector.pollUntil(&loop, 3);
    try send(fds[1], "two");
    try collector.pollUntil(&loop, 6);
    try std.testing.expectEqualStrings("onetwo", collector.got[0..collector.len]);
    try std.testing.expect(!collector.done);

    net.close(fds[1]);
    try loop.run();
    try std.testing.expect(collector.done);
    try collector.recv.getResult();
    try std.testing.expect(collector.chunks >= 2);
}

test "NetRecvMulti hands over each chunk until the peer closes" {
    try chunksUntilClose(.{});
}

test "NetRecvMulti hands over each chunk until the peer closes, with recv_buffers" {
    try chunksUntilClose(.{ .recv_buffers = .{ .count = 4, .size = 64 } });
}

test "NetRecvMulti hands over bytes queued before it starts" {
    var loop: Loop = undefined;
    try loop.init(.{ .recv_buffers = .{ .count = 4, .size = 64 } });
    defer loop.deinit();
    const fds = try pair();
    defer net.close(fds[0]);

    try send(fds[1], "queued");
    var collector: Collector = .{ .recv = undefined };
    collector.start(&loop, fds[0]);
    try collector.pollUntil(&loop, 6);
    try std.testing.expectEqualStrings("queued", collector.got[0..collector.len]);
    net.close(fds[1]);
    try loop.run();
    try collector.recv.getResult();
}

test "NetRecvMulti takes more than its buffers hold at once, arming again as they run out" {
    var loop: Loop = undefined;
    try loop.init(.{ .recv_buffers = .{ .count = 4, .size = 64 } });
    defer loop.deinit();
    const fds = try pair();
    defer net.close(fds[0]);

    var collector: Collector = .{ .recv = undefined };
    collector.start(&loop, fds[0]);
    var payload: [2000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 251);
    try send(fds[1], &payload);
    try collector.pollUntil(&loop, payload.len);
    try std.testing.expectEqualSlices(u8, &payload, collector.got[0..collector.len]);
    net.close(fds[1]);
    try loop.run();
    try collector.recv.getResult();
}

test "NetRecvMulti ends with error.Canceled on a cancel" {
    var loop: Loop = undefined;
    try loop.init(.{ .recv_buffers = .{ .count = 4, .size = 64 } });
    defer loop.deinit();
    const fds = try pair();
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var collector: Collector = .{ .recv = undefined };
    collector.start(&loop, fds[0]);
    try loop.poll(.zero);
    try send(fds[1], "before");
    try collector.pollUntil(&loop, 6);
    loop.cancel(&collector.recv.c);
    try loop.run();
    try std.testing.expect(collector.done);
    try std.testing.expectError(error.Canceled, collector.recv.getResult());
    try std.testing.expectEqualStrings("before", collector.got[0..collector.len]);
}

test "NetRecvMulti is a multishot receive on io_uring with recv_buffers" {
    if (comptime ev.Backend.capability(.net_recv_multi) != .maybe) return error.SkipZigTest;
    var loop: Loop = undefined;
    try loop.init(.{ .recv_buffers = .{ .count = 4, .size = 64 } });
    defer loop.deinit();
    if (loop.backend.selectedEngine() != .io_uring) return error.SkipZigTest;
    const fds = try pair();
    defer net.close(fds[0]);

    var collector: Collector = .{ .recv = undefined };
    collector.start(&loop, fds[0]);
    try send(fds[1], "armed");
    try collector.pollUntil(&loop, 5);
    try std.testing.expectEqual(.backend, collector.recv.route);
    try std.testing.expect(loop.hasRecvBuffers());
    net.close(fds[1]);
    try loop.run();
    try collector.recv.getResult();
}
