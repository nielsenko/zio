# Host Event Loop

Some programs already have an event loop that owns the thread: a language runtime that zio is embedded in, a GUI toolkit, a game engine. zio can run inside such a host. Instead of handing the thread to the runtime, the host calls into zio whenever the loop has work, and waits on its own terms in between.

You'll learn about:

- **Ticking** - running one pass of an executor from the host
- **Waiting** - telling the host when to tick again, without spinning
- **Threads** - which calls are safe from where
- **Backends** - what to do where the loop has no descriptor to wait on

## The Code

```zig
--8<-- "examples/host_loop.zig"
```

A task sleeps, then waits for an event that another thread sets. The host drives it to completion on the main thread, with zio running only while the host ticks it.

## How It Works

### Ticking

The host loop runs until the task is done:

```zig
--8<-- "examples/host_loop.zig:loop"
```

`Executor.tick(wait_cap)` makes one pass of the run loop. The ready tasks run, the loop polls for at most `wait_cap`, and the tasks that the poll readied run. Then control returns to the host. With `.zero` the tick never blocks.

It returns true when work is left that does not need a wait, such as tasks that outran the tick's budget. The host then ticks again before it waits on anything.

The host checks whatever it is waiting for right after the tick. The last piece of work can finish inside the tick, and nothing would wake the host after it.

### Waiting

Between ticks the host waits in its own way, here with `poll`:

```zig
--8<-- "examples/host_loop.zig:wait"
```

Three calls on the loop tell it how:

- `hostHandle()` is a descriptor that becomes readable when the loop has events. The host waits on it but must not read from it.
- `nextTimerDeadline()` is the longest the host may wait before a timer is due, or null without a timer.
- `prepareHostWait()` announces the wait. The host calls it right before it waits, so that a wake from another thread, such as the `Event.set` in the example, makes the descriptor readable. It returns false when a wake came in since the tick, and the host ticks again instead of waiting.

A tick ends the announcement. A host that ticks while it is already waiting, for a reason of its own, announces again before it goes back to waiting.

### Backends Without a Descriptor

`hostHandle()` is null on the poll and IOCP backends. It is also null on io_uring unless zio is built with `-Dio_uring_single_issuer=false`. A ring set up with `DEFER_TASKRUN` holds its completions until its own thread enters the kernel, so a wait elsewhere would not see them.

Without a descriptor, the host lets the tick wait in the loop's own poll, with a cap that suits it, as the example does with `tick(.fromMilliseconds(100))`.

### Threads

The host drives an executor from one thread at a time. That need not be the same thread on every call: `tick` binds the executor to the calling thread each time, which a Dart isolate needs, since the VM moves it between threads. On io_uring this needs `-Dio_uring_single_issuer=false` too, because a `SINGLE_ISSUER` ring refuses every thread but the one that created it.

| Call | Where |
|------|-------|
| `Executor.tick` | The host's thread, never two at once |
| `Loop.prepareHostWait` | Between ticks, never during one |
| `Loop.hostHandle`, `Loop.nextTimerDeadline` | Any thread |
| `Loop.wake`, `Event.set`, spawning a task | Any thread |

### Shutting Down

To stop, the host cancels its tasks and deinitializes the runtime on a thread the executor is bound to. That is the thread that ticked last. A host that shuts down from another thread ticks once with `.zero` there first. A task handle's `cancel()` runs the loop until the task has unwound, so it needs no tick after it. In the example the `defer`s do this once the loop ends.
