// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import Foundation
import Synchronization

/// BSD kqueue wrapper.
public final class KQueue: Sendable {

    // MARK: - Types

    /// File system events to monitor.
    public struct Notification: OptionSet, Sendable, Hashable, CustomStringConvertible {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// File deleted.
        public static let delete = Notification(rawValue: UInt32(NOTE_DELETE))
        /// File written.
        public static let write = Notification(rawValue: UInt32(NOTE_WRITE))
        /// File size increased.
        public static let extend = Notification(rawValue: UInt32(NOTE_EXTEND))
        /// File attributes changed.
        public static let attrib = Notification(rawValue: UInt32(NOTE_ATTRIB))
        /// Link count changed.
        public static let link = Notification(rawValue: UInt32(NOTE_LINK))
        /// File renamed.
        public static let rename = Notification(rawValue: UInt32(NOTE_RENAME))
        /// Access revoked or filesystem unmounted.
        public static let revoke = Notification(rawValue: UInt32(NOTE_REVOKE))
        #if canImport(Darwin)
        /// File unlocked. (Darwin only)
        public static let funlock = Notification(rawValue: UInt32(NOTE_FUNLOCK))
        /// Lease downgrade requested. (Darwin only)
        public static let leaseDowngrade = Notification(rawValue: UInt32(NOTE_LEASE_DOWNGRADE))
        /// Lease release requested. (Darwin only)
        public static let leaseRelease = Notification(rawValue: UInt32(NOTE_LEASE_RELEASE))
        #endif

        #if canImport(Darwin)
        public static let all: Notification = [.delete, .write, .extend, .attrib, .link, .rename, .revoke, .funlock, .leaseDowngrade, .leaseRelease]
        #else
        public static let all: Notification = [.delete, .write, .extend, .attrib, .link, .rename, .revoke]
        #endif
        public static let `default`: Notification = [.delete, .write, .extend, .attrib, .rename, .revoke]

        public var description: String {
            var parts: [String] = []
            if contains(.delete) { parts.append("delete") }
            if contains(.write) { parts.append("write") }
            if contains(.extend) { parts.append("extend") }
            if contains(.attrib) { parts.append("attrib") }
            if contains(.link) { parts.append("link") }
            if contains(.rename) { parts.append("rename") }
            if contains(.revoke) { parts.append("revoke") }
            #if canImport(Darwin)
            if contains(.funlock) { parts.append("funlock") }
            if contains(.leaseDowngrade) { parts.append("leaseDowngrade") }
            if contains(.leaseRelease) { parts.append("leaseRelease") }
            #endif
            return parts.joined(separator: ", ")
        }
    }

    /// File system event.
    public struct Event: Sendable, Hashable {
        /// Path that triggered the event.
        public let path: String
        /// What changed. Multiple flags possible if coalesced.
        public let notification: Notification
    }

    public enum Error: Swift.Error, LocalizedError {
        case cannotOpen(path: String, errno: Int32)
        case cannotRegister(path: String, errno: Int32)
        case notFileURL(URL)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let errno):
                return "Cannot open '\(path)': \(String(cString: strerror(errno)))"
            case .cannotRegister(let path, let errno):
                return "Cannot register '\(path)': \(String(cString: strerror(errno)))"
            case .notFileURL(let url):
                return "Not a file URL: \(url)"
            }
        }
    }

    // MARK: - Properties

    private struct State {
        var pathToFD: [String: Int32] = [:]
        var fdToPath: [Int32: String] = [:]
        var monitorTask: Task<Void, Never>?
        var isPaused: Bool = false
    }

    private let kqueueFD: Int32
    private let state: Mutex<State> = Mutex(State())
    private let eventHandler: (@Sendable (Event) -> Void)?
    private let eventsContinuation: AsyncStream<Event>.Continuation

    /// Polling interval between kevent() calls.
    public let timeout: Duration

    /// Events from watched paths.
    public let events: AsyncStream<Event>

    /// Watched paths.
    public var paths: [String] {
        state.withLock { Array($0.pathToFD.keys) }
    }

    /// Whether event delivery is paused.
    public var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    // MARK: - Init

    /// Returns nil if kqueue creation fails.
    /// - Parameters:
    ///   - timeout: Polling interval between checks. Default is 10ms.
    ///   - eventHandler: Optional callback for each event.
    public init?(timeout: Duration = .milliseconds(10), eventHandler: (@Sendable (Event) -> Void)? = nil) {
        let fd = kqueue()
        guard fd >= 0 else { return nil }

        self.kqueueFD = fd
        self.timeout = timeout
        self.eventHandler = eventHandler

        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation
    }

    deinit {
        stopMonitoring()
        close(kqueueFD)
    }

    // MARK: - Watching

    /// Start watching path for events.
    public func watch(_ path: String, for notifications: Notification = .default) throws {
        let shouldStartMonitoring = try state.withLock { state -> Bool in
            guard state.pathToFD[path] == nil else { return false }

            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                throw Error.cannotOpen(path: path, errno: errno)
            }

            var event = kevent(
                ident: UInt(fd),
                filter: Int16(EVFILT_VNODE),
                flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: notifications.rawValue,
                data: 0,
                udata: nil
            )

            let result = kevent(kqueueFD, &event, 1, nil, 0, nil)
            if result < 0 {
                close(fd)
                throw Error.cannotRegister(path: path, errno: errno)
            }

            state.pathToFD[path] = fd
            state.fdToPath[fd] = path

            if state.monitorTask == nil {
                return true
            }
            return false
        }

        if shouldStartMonitoring {
            startMonitoring()
        }
    }

    /// Start watching URL for events.
    public func watch(_ url: URL, for notifications: Notification = .default) throws {
        guard url.isFileURL else { throw Error.notFileURL(url) }
        try watch(url.path(percentEncoded: false), for: notifications)
    }

    /// Stop watching path.
    public func stopWatching(_ path: String) {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard let fd = state.pathToFD.removeValue(forKey: path) else { return nil }
            state.fdToPath.removeValue(forKey: fd)
            close(fd)

            if state.pathToFD.isEmpty {
                let task = state.monitorTask
                state.monitorTask = nil
                return task
            }
            return nil
        }
        task?.cancel()
    }

    /// Stop watching URL.
    public func stopWatching(_ url: URL) {
        stopWatching(url.path(percentEncoded: false))
    }

    /// Stop watching all paths.
    public func stopWatchingAll() {
        let task = state.withLock { state -> Task<Void, Never>? in
            for fd in state.fdToPath.keys {
                close(fd)
            }
            state.pathToFD.removeAll()
            state.fdToPath.removeAll()
            let task = state.monitorTask
            state.monitorTask = nil
            return task
        }
        task?.cancel()
    }

    /// Pause event delivery. Events are discarded while paused.
    public func pause() {
        state.withLock { $0.isPaused = true }
    }

    /// Resume event delivery.
    public func resume() {
        state.withLock { $0.isPaused = false }
    }

    public func isWatching(_ path: String) -> Bool {
        state.withLock { $0.pathToFD[path] != nil }
    }

    public func isWatching(_ url: URL) -> Bool {
        isWatching(url.path(percentEncoded: false))
    }

    public func fileDescriptor(for path: String) -> Int32? {
        state.withLock { $0.pathToFD[path] }
    }

    // MARK: - Private

    private func startMonitoring() {
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.monitorLoop()
        }
        state.withLock { $0.monitorTask = task }
    }

    private func stopMonitoring() {
        let task = state.withLock { state -> Task<Void, Never>? in
            for fd in state.fdToPath.keys {
                close(fd)
            }
            state.pathToFD.removeAll()
            state.fdToPath.removeAll()
            let task = state.monitorTask
            state.monitorTask = nil
            return task
        }
        task?.cancel()
        eventsContinuation.finish()
    }

    private func monitorLoop() async {
        var events: [kevent] = Array(repeating: kevent(), count: 16)
        var immediateTimeout = timespec(tv_sec: 0, tv_nsec: 0)

        while !Task.isCancelled && state.withLock({ !$0.fdToPath.isEmpty }) {
            // Drain all pending events
            while true {
                let eventCount = events.withUnsafeMutableBufferPointer { buffer in
                    kevent(kqueueFD, nil, 0, buffer.baseAddress, Int32(buffer.count), &immediateTimeout)
                }

                if eventCount < 0 {
                    if errno == EINTR { continue }
                    return
                }

                if eventCount == 0 { break }

                let (fdToPath, isPaused) = state.withLock { ($0.fdToPath, $0.isPaused) }

                if !isPaused {
                    for i in 0..<Int(eventCount) {
                        let event = events[i]
                        guard event.filter == Int16(EVFILT_VNODE) else { continue }

                        let fd = Int32(event.ident)
                        if let path = fdToPath[fd] {
                            let evt = Event(path: path, notification: Notification(rawValue: event.fflags))
                            eventHandler?(evt)
                            eventsContinuation.yield(evt)
                        }
                    }
                }
            }

            try? await Task.sleep(for: timeout)
        }
    }
}

// MARK: - CustomStringConvertible

extension KQueue: CustomStringConvertible {
    public var description: String {
        let watchedPaths = paths
        if watchedPaths.isEmpty {
            return "KQueue(watching: none)"
        }
        return "KQueue(watching: \(watchedPaths.joined(separator: ", ")))"
    }
}
