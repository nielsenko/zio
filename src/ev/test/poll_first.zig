const std = @import("std");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const net = os.net;

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
