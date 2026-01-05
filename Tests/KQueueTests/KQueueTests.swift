// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import Testing
import Foundation
@testable import KQueue

@Suite("KQueue")
struct KQueueTests {

    // MARK: - Initialization

    @Test func initialization() {
        #expect(KQueue() != nil)
        #expect(KQueue { _ in } != nil)
    }

    // MARK: - Watch Management

    @Test func watch() throws {
        let queue = KQueue()!
        let file = try TempFile()

        #expect(!queue.isWatching(file.path))
        #expect(queue.paths.isEmpty)

        try queue.watch(file.path)

        #expect(queue.isWatching(file.path))
        #expect(queue.paths.contains(file.path))
    }

    @Test func watchURL() throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.url)

        #expect(queue.isWatching(file.url))
        #expect(queue.isWatching(file.path))
    }

    @Test func stopWatching() throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.path)
        queue.stopWatching(file.path)

        #expect(!queue.isWatching(file.path))
        #expect(queue.paths.isEmpty)
    }

    @Test func stopWatchingURL() throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.url)
        queue.stopWatching(file.url)

        #expect(!queue.isWatching(file.url))
    }

    @Test func stopWatchingAll() throws {
        let queue = KQueue()!
        let file1 = try TempFile()
        let file2 = try TempFile()

        try queue.watch(file1.path)
        try queue.watch(file2.path)
        #expect(queue.paths.count == 2)

        queue.stopWatchingAll()

        #expect(queue.paths.isEmpty)
    }

    @Test func watchDuplicateIgnored() throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.path)
        try queue.watch(file.path)

        #expect(queue.paths.count == 1)
    }

    @Test func fileDescriptor() throws {
        let queue = KQueue()!
        let file = try TempFile()

        #expect(queue.fileDescriptor(for: file.path) == nil)

        try queue.watch(file.path)

        let fd = queue.fileDescriptor(for: file.path)
        #expect(fd != nil)
        #expect(fd! >= 0)
    }

    // MARK: - Events

    @Test(.timeLimit(.minutes(1)))
    func writeEvent() async throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.path, for: .write)

        async let eventTask: Void = {
            for await event in queue.events {
                #expect(event.path == file.path)
                #expect(event.notification.contains(.write))
                return
            }
        }()

        try await Task.sleep(for: .milliseconds(50))
        try file.append("data")
        await eventTask
    }

    @Test(.timeLimit(.minutes(1)))
    func deleteEvent() async throws {
        let queue = KQueue()!
        let file = try TempFile()
        let path = file.path

        try queue.watch(path, for: .delete)

        async let eventTask: Void = {
            for await event in queue.events {
                #expect(event.path == path)
                #expect(event.notification.contains(.delete))
                return
            }
        }()

        try await Task.sleep(for: .milliseconds(50))
        try file.delete()
        await eventTask
    }

    @Test(.timeLimit(.minutes(1)))
    func renameEvent() async throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.path, for: .rename)

        async let eventTask: Void = {
            for await event in queue.events {
                #expect(event.notification.contains(.rename))
                return
            }
        }()

        try await Task.sleep(for: .milliseconds(50))
        try file.rename(to: file.path + ".renamed")
        await eventTask
    }

    @Test(.timeLimit(.minutes(1)))
    func attribEvent() async throws {
        let queue = KQueue()!
        let file = try TempFile()

        try queue.watch(file.path, for: .attrib)

        async let eventTask: Void = {
            for await event in queue.events {
                #expect(event.path == file.path)
                #expect(event.notification.contains(.attrib))
                return
            }
        }()

        try await Task.sleep(for: .milliseconds(50))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await eventTask
    }

    @Test(.timeLimit(.minutes(1)))
    func callbackHandler() async throws {
        try await confirmation { confirm in
            let queue = KQueue { _ in confirm() }!
            let file = try TempFile()

            try queue.watch(file.path, for: .write)
            try await Task.sleep(for: .milliseconds(50))
            try file.append("data")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Notification

    @Test func notificationDescription() {
        #expect(KQueue.Notification.write.description == "write")

        let multiple: KQueue.Notification = [.write, .delete]
        #expect(multiple.description.contains("write"))
        #expect(multiple.description.contains("delete"))
    }

    @Test func queueDescription() throws {
        let queue = KQueue()!
        #expect(queue.description == "KQueue(watching: none)")

        let file = try TempFile()
        try queue.watch(file.path)
        #expect(queue.description.contains("KQueue(watching:"))
        #expect(queue.description.contains(file.path))
    }

    @Test func notificationRawValues() {
        #expect(KQueue.Notification.delete.rawValue == UInt32(NOTE_DELETE))
        #expect(KQueue.Notification.write.rawValue == UInt32(NOTE_WRITE))
        #expect(KQueue.Notification.extend.rawValue == UInt32(NOTE_EXTEND))
        #expect(KQueue.Notification.attrib.rawValue == UInt32(NOTE_ATTRIB))
        #expect(KQueue.Notification.link.rawValue == UInt32(NOTE_LINK))
        #expect(KQueue.Notification.rename.rawValue == UInt32(NOTE_RENAME))
        #expect(KQueue.Notification.revoke.rawValue == UInt32(NOTE_REVOKE))
    }

    // MARK: - Errors

    @Test func watchNonexistentThrows() {
        let queue = KQueue()!

        #expect(throws: KQueue.Error.self) {
            try queue.watch("/nonexistent/\(UUID())")
        }
    }

    @Test func watchNonFileURLThrows() {
        let queue = KQueue()!

        #expect(throws: KQueue.Error.self) {
            try queue.watch(URL(string: "https://example.com")!)
        }
    }

    // MARK: - Event Type

    @Test func eventEquality() {
        let event1 = KQueue.Event(path: "/test", notification: .write)
        let event2 = KQueue.Event(path: "/test", notification: .write)
        let event3 = KQueue.Event(path: "/other", notification: .write)

        #expect(event1 == event2)
        #expect(event1 != event3)
        #expect(event1.hashValue == event2.hashValue)
    }
}

// MARK: - TempFile Helper

private final class TempFile: @unchecked Sendable {
    private(set) var path: String
    var url: URL { URL(fileURLWithPath: path) }

    init() throws {
        path = NSTemporaryDirectory() + "kqueue_test_\(UUID())"
        FileManager.default.createFile(atPath: path, contents: "test".data(using: .utf8))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func append(_ string: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: string.data(using: .utf8)!)
        try handle.close()
    }

    func delete() throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func rename(to newPath: String) throws {
        try FileManager.default.moveItem(atPath: path, toPath: newPath)
        path = newPath
    }
}
