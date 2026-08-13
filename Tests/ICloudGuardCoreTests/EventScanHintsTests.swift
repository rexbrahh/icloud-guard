import Darwin
import Foundation
import os
import XCTest
@testable import ICloudGuardCore

final class EventScanHintsTests: XCTestCase {
    func testDebouncesAndCollapsesNestedDirectoryHints() throws {
        let sandbox = try Sandbox()
        let projects = try sandbox.directory("Projects")
        let nested = try sandbox.directory("Projects/Active")
        let media = try sandbox.directory("Media")
        let projectsFile = nested.appendingPathComponent("work.bin")
        let mediaFile = media.appendingPathComponent("clip.bin")
        try Data([1]).write(to: projectsFile)
        try Data([2]).write(to: mediaFile)

        let source = InjectedEventSource()
        let received = OSAllocatedUnfairLock(initialState: [EventScanHintBatch]())
        let expectation = expectation(description: "debounced hint")
        let monitor = try EventScanHintMonitor(
            scopePath: sandbox.root.path,
            debounceSeconds: 0.03,
            source: source.source
        ) { batch in
            received.withLock { $0.append(batch) }
            expectation.fulfill()
        }
        try monitor.start()
        source.emit([
            FileSystemEventHint(path: projectsFile.path),
            FileSystemEventHint(path: nested.path),
        ])
        source.emit([FileSystemEventHint(path: mediaFile.path)])

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received.withLock { $0.count }, 1)
        XCTAssertEqual(
            received.withLock { $0[0].targets.map(\.relativePath) },
            ["Media", "Projects/Active"]
        )
        XCTAssertFalse(received.withLock { $0[0].requiresFullReconciliation })
        XCTAssertEqual(
            received.withLock { $0[0].targets[0].validatedURL(under: sandbox.root.path)?.path },
            media.path
        )
        withExtendedLifetime(projects) {}
        monitor.stop()
    }

    func testDroppedRootAndSymlinkEventsForceFullReconciliation() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.directory("Folder")
        let outside = try Sandbox()
        let link = sandbox.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.root)

        let cases: [[FileSystemEventHint]] = [
            [FileSystemEventHint(path: folder.path, flags: .mustScanSubdirectories)],
            [FileSystemEventHint(path: folder.path, flags: .userDropped)],
            [FileSystemEventHint(path: folder.path, flags: .kernelDropped)],
            [FileSystemEventHint(path: folder.path, flags: .eventIDsWrapped)],
            [FileSystemEventHint(path: sandbox.root.path, flags: .rootChanged)],
            [FileSystemEventHint(path: folder.path, flags: .mount)],
            [FileSystemEventHint(path: folder.path, flags: .unmount)],
            [FileSystemEventHint(path: outside.root.path)],
            [FileSystemEventHint(path: link.path)],
            [FileSystemEventHint(path: sandbox.root.path + "/../" + sandbox.root.lastPathComponent + "/Folder")],
        ]
        for events in cases {
            let source = InjectedEventSource()
            let expectation = expectation(description: "full reconciliation")
            let received = OSAllocatedUnfairLock<EventScanHintBatch?>(initialState: nil)
            let monitor = try EventScanHintMonitor(
                scopePath: sandbox.root.path,
                debounceSeconds: 0.01,
                source: source.source
            ) { batch in
                received.withLock { $0 = batch }
                expectation.fulfill()
            }
            try monitor.start()
            source.emit(events)
            wait(for: [expectation], timeout: 1)
            XCTAssertTrue(try XCTUnwrap(received.withLock { $0 }).requiresFullReconciliation)
            XCTAssertTrue(try XCTUnwrap(received.withLock { $0 }).targets.isEmpty)
            monitor.stop()
        }
    }

    func testQueueOverflowEscalatesInsteadOfGrowingPastBound() throws {
        let sandbox = try Sandbox()
        let folders = try (0..<3).map { try sandbox.directory("Folder\($0)") }
        let source = InjectedEventSource()
        let expectation = expectation(description: "overflow")
        let received = OSAllocatedUnfairLock<EventScanHintBatch?>(initialState: nil)
        let monitor = try EventScanHintMonitor(
            scopePath: sandbox.root.path,
            maxPendingTargets: 2,
            debounceSeconds: 0.01,
            source: source.source
        ) { batch in
            received.withLock { $0 = batch }
            expectation.fulfill()
        }
        try monitor.start()
        source.emit(folders.map { FileSystemEventHint(path: $0.path) })

        wait(for: [expectation], timeout: 1)
        let batch = try XCTUnwrap(received.withLock { $0 })
        XCTAssertTrue(batch.requiresFullReconciliation)
        XCTAssertTrue(batch.targets.isEmpty)
        monitor.stop()
    }

    func testStopCancelsSourceAndPendingDebounce() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.directory("Folder")
        let source = InjectedEventSource()
        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        let monitor = try EventScanHintMonitor(
            scopePath: sandbox.root.path,
            debounceSeconds: 0.05,
            source: source.source
        ) { _ in
            callbackCount.withLock { $0 += 1 }
        }
        try monitor.start()
        source.emit([FileSystemEventHint(path: folder.path)])
        monitor.stop()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(callbackCount.withLock { $0 }, 0)
        XCTAssertEqual(source.cancelCount, 1)
        source.emit([FileSystemEventHint(path: folder.path)])
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(callbackCount.withLock { $0 }, 0)
    }

    func testTargetRevalidationRejectsIdentityReplacementAndSymlink() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.directory("Folder")
        let file = folder.appendingPathComponent("file.bin")
        try Data([1]).write(to: file)
        let source = InjectedEventSource()
        let expectation = expectation(description: "target")
        let target = OSAllocatedUnfairLock<EventScanTarget?>(initialState: nil)
        let monitor = try EventScanHintMonitor(
            scopePath: sandbox.root.path,
            debounceSeconds: 0.01,
            source: source.source
        ) { batch in
            target.withLock { $0 = batch.targets.first }
            expectation.fulfill()
        }
        try monitor.start()
        source.emit([FileSystemEventHint(path: file.path)])
        wait(for: [expectation], timeout: 1)
        let captured = try XCTUnwrap(target.withLock { $0 })
        XCTAssertEqual(captured.validatedURL(under: sandbox.root.path)?.path, folder.path)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertNil(captured.validatedURL(under: sandbox.root.path))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: sandbox.root)
        XCTAssertNil(captured.validatedURL(under: sandbox.root.path))
        monitor.stop()
    }

    func testInvalidScopeFailsClosedBeforeStartingSource() throws {
        let sandbox = try Sandbox()
        let missing = sandbox.root.appendingPathComponent("missing")
        XCTAssertThrowsError(try EventScanHintMonitor(scopePath: missing.path) { _ in }) { error in
            XCTAssertEqual(error as? EventScanHintError, .invalidScope)
        }
    }

    func testSymlinkedScopeRootAndAncestorFailClosed() throws {
        let sandbox = try Sandbox()
        let realScope = try sandbox.directory("real/scope")
        let rootLink = sandbox.root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realScope)

        let realAncestor = try sandbox.directory("real-ancestor")
        _ = try sandbox.directory("real-ancestor/scope")
        let ancestorLink = sandbox.root.appendingPathComponent("ancestor-link")
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: realAncestor)

        for path in [rootLink.path, ancestorLink.appendingPathComponent("scope").path] {
            XCTAssertThrowsError(try EventScanHintMonitor(scopePath: path) { _ in }) { error in
                XCTAssertEqual(error as? EventScanHintError, .invalidScope)
            }
        }
    }

    func testTargetRevalidationRejectsRootAndAncestorReplacementEvenWhenTargetIdentitySurvives() throws {
        try assertReplacementInvalidatesTarget(replacingRoot: true)
        try assertReplacementInvalidatesTarget(replacingRoot: false)
    }

    func testCallbackFromStoppedGenerationCannotEnqueueAfterRestart() throws {
        let sandbox = try Sandbox()
        let oldFolder = try sandbox.directory("Old")
        let currentFolder = try sandbox.directory("Current")
        let source = InjectedEventSource()
        let expectation = expectation(description: "current generation")
        let received = OSAllocatedUnfairLock<EventScanHintBatch?>(initialState: nil)
        let monitor = try EventScanHintMonitor(
            scopePath: sandbox.root.path,
            debounceSeconds: 0.02,
            source: source.source
        ) { batch in
            received.withLock { $0 = batch }
            expectation.fulfill()
        }
        try monitor.start()
        XCTAssertEqual(source.handlerCount, 1)
        monitor.stop()
        try monitor.start()
        XCTAssertEqual(source.handlerCount, 2)

        source.emit([FileSystemEventHint(path: oldFolder.path)], handlerAt: 0)
        source.emit([FileSystemEventHint(path: currentFolder.path)], handlerAt: 1)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received.withLock { $0?.targets.map(\.relativePath) }, ["Current"])
        monitor.stop()
    }

    private func assertReplacementInvalidatesTarget(replacingRoot: Bool) throws {
        let sandbox = try Sandbox()
        let container = try sandbox.directory("Container")
        let scope = try sandbox.directory("Container/Scope")
        let folder = try sandbox.directory("Container/Scope/Folder")
        let file = folder.appendingPathComponent("file.bin")
        try Data([1]).write(to: file)
        let source = InjectedEventSource()
        let expectation = expectation(description: replacingRoot ? "root target" : "ancestor target")
        let captured = OSAllocatedUnfairLock<EventScanTarget?>(initialState: nil)
        let monitor = try EventScanHintMonitor(
            scopePath: scope.path,
            debounceSeconds: 0.01,
            source: source.source
        ) { batch in
            captured.withLock { $0 = batch.targets.first }
            expectation.fulfill()
        }
        try monitor.start()
        source.emit([FileSystemEventHint(path: file.path)])
        wait(for: [expectation], timeout: 1)
        let target = try XCTUnwrap(captured.withLock { $0 })
        XCTAssertNotNil(target.validatedURL(under: scope.path))

        if replacingRoot {
            let oldScope = sandbox.root.appendingPathComponent("OldScope")
            try FileManager.default.moveItem(at: scope, to: oldScope)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
            try FileManager.default.moveItem(
                at: oldScope.appendingPathComponent("Folder"),
                to: scope.appendingPathComponent("Folder")
            )
        } else {
            let movedContainer = sandbox.root.appendingPathComponent("MovedContainer")
            try FileManager.default.moveItem(at: container, to: movedContainer)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            try FileManager.default.moveItem(
                at: movedContainer.appendingPathComponent("Scope"),
                to: container.appendingPathComponent("Scope")
            )
        }
        XCTAssertNil(target.validatedURL(under: scope.path))
        monitor.stop()
    }
}

private final class InjectedEventSource: Sendable {
    private struct State: Sendable {
        var handlers: [FileSystemEventSource.Handler] = []
        var cancelCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var source: FileSystemEventSource {
        FileSystemEventSource { [state] handler in
            state.withLock { $0.handlers.append(handler) }
            return FileSystemEventSubscription { [state] in
                state.withLock {
                    $0.cancelCount += 1
                }
            }
        }
    }

    var cancelCount: Int { state.withLock { $0.cancelCount } }
    var handlerCount: Int { state.withLock { $0.handlers.count } }

    func emit(_ events: [FileSystemEventHint], handlerAt index: Int? = nil) {
        let handler = state.withLock { state -> FileSystemEventSource.Handler? in
            guard !state.handlers.isEmpty else { return nil }
            return state.handlers[index ?? state.handlers.count - 1]
        }
        handler?(events)
    }
}

private struct Sandbox {
    let root: URL

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-hints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard requested.path.withCString({ realpath($0, &resolved) }) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
