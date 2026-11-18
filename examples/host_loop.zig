const std = @import("std");
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

fn worker(event: *zio.Event) !void {
    try zio.sleep(.fromMilliseconds(100));
    std.log.info("Timer fired, waiting for the other thread", .{});
    try event.wait();
    std.log.info("Woken by the other thread", .{});
}

fn signal(event: *zio.Event) void {
    zio.os.time.sleep(.fromMilliseconds(300));
    event.set();
}

// --8<-- [start:wait]
/// The host's own wait: until the loop's descriptor is readable or its
/// next timer is due.
fn waitForLoop(fd: zio.os.net.fd_t, deadline: ?zio.Duration) !void {
    const timeout_ms: i32 = if (deadline) |d|
        @intCast(@min(d.toMilliseconds(), std.math.maxInt(i32)))
    else
        -1;
    var fds = [_]zio.os.net.pollfd{.{ .fd = fd, .events = zio.os.net.POLL.IN, .revents = 0 }};
    _ = try zio.os.net.poll(&fds, timeout_ms);
}
// --8<-- [end:wait]

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const executor = &rt.main_executor;
    const loop = &executor.loop;

    var event: zio.Event = .init;
    var task = try rt.spawn(worker, .{&event});
    defer task.cancel();
    const thread = try std.Thread.spawn(.{}, signal, .{&event});
    defer thread.join();

    // --8<-- [start:loop]
    while (true) {
        // Run what is ready. True means more is ready already.
        const more = try executor.tick(.zero);
        if (task.hasResult()) break;
        if (more) continue;

        const fd = loop.hostHandle() orelse {
            // No descriptor on this backend. Let the loop wait in its poll.
            _ = try executor.tick(.fromMilliseconds(100));
            continue;
        };
        // False means a wake came in since the tick. Tick again.
        if (!loop.prepareHostWait()) continue;
        try waitForLoop(fd, loop.nextTimerDeadline());
    }
    // --8<-- [end:loop]
    try task.getResult();
}
