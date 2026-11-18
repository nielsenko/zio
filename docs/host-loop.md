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

A tick from inside one of the executor's own tasks fails with `error.AlreadyRunning`. A task gets there when it enters a modal loop that pumps the host's events, and with them the host's tick. The host skips that tick, and the other tasks run once the task in the modal loop yields.

### Waiting

Between ticks the host waits in its own way, here with `poll`:

```zig
--8<-- "examples/host_loop.zig:wait"
```

Three calls on the loop tell it how:

- `hostHandle()` is a descriptor that becomes readable when the loop has events. The host waits on it but must not read from it.
- `nextTimerDeadline()` is the longest the host may wait before it ticks again, or null when nothing is pending. A timer sets it, at most 10 seconds ahead for a boot or real one, whose deadline a suspend or a clock step moves. So does a canceled thread-pool operation that the loop still has to interrupt.
- `prepareHostWait()` announces the wait. The host calls it right before it waits, so that a wake from another thread, such as the `Event.set` in the example, makes the descriptor readable. It returns false when a wake came in since the tick, and the host ticks again instead of waiting.

A tick ends the announcement. A host that ticks while it is already waiting, for a reason of its own, announces again before it goes back to waiting.

### Backends Without a Descriptor

`hostHandle()` is null on the poll backend. It is also null on io_uring unless zio is built with `-Dio_uring_single_issuer=false`. A ring set up with `DEFER_TASKRUN` holds its completions until its own thread enters the kernel, so a wait elsewhere would not see them.

On IOCP it is the completion port, which `poll` can't wait on. A host that waits on the port dequeues each entry and posts it back for the loop. It also waits alertably, from the thread it gave `Loop.adoptWakeThread`, because a wake from another thread arrives there as an APC. A poll that waits on another thread, as a tick with a wait cap does, takes the wakes for that wait and gives them back afterwards. `Loop.hostHandle` has the details. The example treats Windows like a backend without a descriptor.

Without a descriptor, the host lets the tick wait in the loop's own poll, with a cap that suits it, as the example does with `tick(.fromMilliseconds(100))`.

### Threads

The host ticks on the thread that initialized the runtime. On that thread zio calls act for the executor's main task, so a blocking call such as a task handle's `cancel()` runs the loop there until it can return.

A wake from another thread, such as an `Event.set`, goes through a queue that every thread may push to, and it makes `hostHandle()` readable while the host waits. A wake from the host's own thread lands in the executor's own run queue instead and wakes nothing. After such a wake the host ticks before it waits.

What the host spawns on its thread waits for the next tick too, with one exception. When no other executor can take the new tasks, a spawner yields after 13 spawns in a row so that they get to start. For the host that yield is a pass of the loop, as `zio.yield()` is.

| Call | Where |
|------|-------|
| `Executor.tick` | The thread that initialized the runtime |
| `Loop.prepareHostWait` | Between ticks, never during one |
| `Loop.hostHandle`, `Loop.nextTimerDeadline` | Any thread |
| `Loop.wake`, `Event.set`, spawning a task | Any thread |

### Shutting Down

To stop, the host cancels its tasks and deinitializes the runtime on the thread it ticks on. A task handle's `cancel()` runs the loop until the task has unwound, so it needs no tick after it. In the example the `defer`s do this once the loop ends.
