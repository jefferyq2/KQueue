# KQueue

Swift wrapper for BSD kqueue file system monitoring.

Monitors individual files and directories. Directory monitoring reports changes to the directory itself (e.g., `.write` when files are added/removed), not changes to files within. To monitor files inside a directory, watch each file individually. For recursive monitoring use FSEvents on Apple platforms.

## How It Works

`KQueue` creates a kernel event queue. `watch(_:for:)` opens the file with `O_EVTONLY` (monitoring without blocking deletion/unmount) and registers for specified events. Multiple changes coalesce into single `KQueue.Event`. Events delivered via `events` AsyncStream or callback. Cleanup is automatic.

## Requirements

- macOS 15.0+, iOS 18.0+, tvOS 18.0+, watchOS 11.0+, visionOS 2.0+, or FreeBSD with Swift 6.0+
- Swift 5.9+

## Usage

```swift
let queue = KQueue()
try queue.watch("/path/to/file", for: [.write, .delete])

for await event in queue.events {
    print("Changed: \(event.path), flags: \(event.notification)")
}
```

Callback style:

```swift
let queue = KQueue { event in
    print("Changed: \(event.path)")
}
try queue.watch("/path/to/file")
```

## API

- `watch(_:for:)` - start watching (String path or file URL)
- `stopWatching(_:)` - stop watching (String path or file URL)
- `stopWatchingAll()` - stop watching all
- `isWatching(_:)` - check if watched (String path or file URL)
- `paths` - currently watched paths
- `events` - AsyncStream of events

## Notifications

| Option | Description |
|--------|-------------|
| `.delete` | Deleted |
| `.write` | Written (or directory contents changed) |
| `.extend` | Size increased |
| `.attrib` | Attributes changed |
| `.link` | Link count changed |
| `.rename` | Renamed |
| `.revoke` | Access revoked |
| `.funlock` | File unlocked (Apple platforms only) |
| `.leaseDowngrade` | Lease downgrade requested (Apple platforms only) |
| `.leaseRelease` | Lease release requested (Apple platforms only) |
| `.default` | All except `.link` and lease events |
| `.all` | All |

## See Also

- [Apple: Kernel Queues](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html)
- [FreeBSD: kqueue](https://people.freebsd.org/~jmg/kq.html)

## License

MIT
