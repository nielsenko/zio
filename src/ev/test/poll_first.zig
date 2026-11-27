const std = @import("std");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const net = os.net;

const sockreg = @import("../sockreg.zig");

const Loop = ev.Loop;
const NetRecv = ev.NetRecv;

test "NetRecv with poll_first completes once the peer writes" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var buf: [16]u8 = undefined;
    var read_iov: [1]os.iovec = undefined;
    var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{ .poll_first = true });
    loop.add(&recv.c);
    try loop.poll(.zero);
    try std.testing.expectEqual(.running, recv.c.loadState().phase);

    var send_iov = [_]net.iovec_const{net.iovecConstFromSlice("hello")};
    _ = try net.send(fds[1], &send_iov, .{});
    try loop.run();
    try std.testing.expectEqualStrings("hello", buf[0..try recv.getResult()]);
}

test "NetRecv with poll_first after a short read takes bytes queued since" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var buf: [16]u8 = undefined;
    var read_iov: [1]os.iovec = undefined;
    var first: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{});
    loop.add(&first.c);
    try loop.poll(.zero);
    var send_iov = [_]net.iovec_const{net.iovecConstFromSlice("one")};
    _ = try net.send(fds[1], &send_iov, .{});
    try pollUntilDone(&loop, &first.c);
    try std.testing.expectEqualStrings("one", buf[0..try first.getResult()]);

    send_iov[0] = net.iovecConstFromSlice("two");
    _ = try net.send(fds[1], &send_iov, .{});
    var second: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{ .poll_first = true });
    loop.add(&second.c);
    try pollUntilDone(&loop, &second.c);
    try std.testing.expectEqualStrings("two", buf[0..try second.getResult()]);
}

test "poll_first receives try first while they find bytes waiting, and park first again once they do not" {
    // io_uring hands poll_first to the kernel.
    if (ev.backend != .epoll and ev.backend != .kqueue) return error.SkipZigTest;
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var buf: [16]u8 = undefined;
    var read_iov: [1]os.iovec = undefined;
    var send_iov = [_]net.iovec_const{net.iovecConstFromSlice("x")};
    try std.testing.expect(!loop.state.poll_first_try);

    for (0..sockreg.poll_first_sample * sockreg.poll_first_window) |_| {
        _ = try net.send(fds[1], &send_iov, .{});
        var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{ .poll_first = true });
        loop.add(&recv.c);
        try pollUntilDone(&loop, &recv.c);
        try std.testing.expectEqualStrings("x", buf[0..try recv.getResult()]);
    }
    try std.testing.expect(loop.state.poll_first_try);

    for (0..sockreg.poll_first_window) |_| {
        var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{ .poll_first = true });
        loop.add(&recv.c);
        _ = try net.send(fds[1], &send_iov, .{});
        try pollUntilDone(&loop, &recv.c);
        try std.testing.expectEqualStrings("x", buf[0..try recv.getResult()]);
    }
    try std.testing.expect(!loop.state.poll_first_try);
}

/// Polls until `c` is finished, for at most about 10 s.
fn pollUntilDone(loop: *Loop, c: *ev.Completion) !void {
    var rounds: usize = 0;
    while (c.loadState().phase != .dead and rounds < 1000) : (rounds += 1) {
        try loop.poll(.fromMilliseconds(10));
    }
}

test "NetRecv with poll_first takes bytes that are already queued" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var send_iov = [_]net.iovec_const{net.iovecConstFromSlice("queued")};
    _ = try net.send(fds[1], &send_iov, .{});

    var buf: [16]u8 = undefined;
    var read_iov: [1]os.iovec = undefined;
    var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &read_iov), .{ .poll_first = true });
    loop.add(&recv.c);
    try loop.run();
    try std.testing.expectEqualStrings("queued", buf[0..try recv.getResult()]);
}
