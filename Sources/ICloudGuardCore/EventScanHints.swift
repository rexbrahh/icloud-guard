import CoreServices
import Darwin
import Foundation
import os

public struct FileSystemEventFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let mustScanSubdirectories = Self(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    public static let userDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
    public static let kernelDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
    public static let eventIDsWrapped = Self(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
    public static let rootChanged = Self(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
    public static let mount = Self(rawValue: UInt32(kFSEventStreamEventFlagMount))
    public static let unmount = Self(rawValue: UInt32(kFSEventStreamEventFlagUnmount))
    public static let itemIsSymlink = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))

    fileprivate static let requiresFullReconciliation: Self = [
        .mustScanSubdirectories, .userDropped, .kernelDropped, .eventIDsWrapped,
        .rootChanged, .mount, .unmount,
    ]
}

public struct FileSystemEventHint: Equatable, Sendable {
    public var path: String
    public var flags: FileSystemEventFlags

    public init(path: String, flags: FileSystemEventFlags = []) {
        self.path = path
        self.flags = flags
    }
}

public struct EventScanTarget: Equatable, Sendable {
    /// Canonical path relative to the configured scope. It always names a
    /// directory; events directly below the scope require a full scan.
    public var relativePath: String
    public var identity: EvictionFileIdentity
    private var scopeComponentIdentities: [EvictionFileIdentity]

    init(
        relativePath: String,
        identity: EvictionFileIdentity,
        scopeComponentIdentities: [EvictionFileIdentity]
    ) {
        self.relativePath = relativePath
        self.identity = identity
        self.scopeComponentIdentities = scopeComponentIdentities
    }

    /// Revalidates the whole path immediately before a targeted scan. A
    /// replacement or symlink introduced after the event fails closed.
    public func validatedURL(under scopePath: String) -> URL? {
        EventHintPathValidator.resolve(
            relativePath: relativePath,
            expectedIdentity: identity,
            expectedScopeComponentIdentities: scopeComponentIdentities,
            under: scopePath
        )
    }
}

/// An advisory request only. Callers must retain their periodic authoritative
/// full reconciliation; event delivery can always be incomplete.
public struct EventScanHintBatch: Equatable, Sendable {
    public var targets: [EventScanTarget]
    public var requiresFullReconciliation: Bool

    public init(targets: [EventScanTarget], requiresFullReconciliation: Bool) {
        self.targets = targets
        self.requiresFullReconciliation = requiresFullReconciliation
    }
}

public struct FileSystemEventSubscription: Sendable {
    private let cancelHandler: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
    }
}

/// Small closure-backed seam: production uses FSEvents and tests inject a
/// hermetic event producer without touching a live iCloud scope.
public struct FileSystemEventSource: Sendable {
    public typealias Handler = @Sendable ([FileSystemEventHint]) -> Void
    public typealias Start = @Sendable (_ handler: @escaping Handler) throws -> FileSystemEventSubscription

    private let startHandler: Start

    public init(start: @escaping Start) {
        startHandler = start
    }

    public func start(handler: @escaping Handler) throws -> FileSystemEventSubscription {
        try startHandler(handler)
    }

    public static func native(scopePath: String, latency: TimeInterval = 0.5) -> Self {
        let boundedLatency = latency.isFinite ? min(60, max(0.05, latency)) : 0.5
        return Self { handler in
            try NativeFSEventSubscription.start(
                scopePath: scopePath,
                latency: boundedLatency,
                handler: handler
            )
        }
    }
}

public enum EventScanHintError: Error, Equatable {
    case invalidScope
    case eventSourceCreationFailed
    case eventSourceStartFailed
}

/// Converts a lossy native event stream into bounded scan hints. This type
/// neither scans nor mutates, so its callback can enter GuardService's actor
/// and reuse the existing single-flight scan and mutation lock.
public final class EventScanHintMonitor: Sendable {
    public typealias Handler = @Sendable (EventScanHintBatch) -> Void

    private struct State: Sendable {
        var active = false
        var generation: UInt64 = 0
        var subscription: FileSystemEventSubscription?
        var targets: [String: EventScanTarget] = [:]
        var requiresFullReconciliation = false
    }

    private let canonicalScopePath: String
    private let scopeIdentity: EvictionFileIdentity
    private let scopeComponentIdentities: [EvictionFileIdentity]
    private let maxPendingTargets: Int
    private let debounceSeconds: TimeInterval
    private let source: FileSystemEventSource
    private let handler: Handler
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer: DispatchSourceTimer

    public init(
        scopePath: String,
        maxPendingTargets: Int = 128,
        debounceSeconds: TimeInterval = 0.5,
        source: FileSystemEventSource? = nil,
        handler: @escaping Handler
    ) throws {
        guard let root = EventHintPathValidator.root(scopePath) else {
            throw EventScanHintError.invalidScope
        }
        canonicalScopePath = root.canonicalPath
        scopeIdentity = root.identity
        scopeComponentIdentities = root.componentIdentities
        self.maxPendingTargets = min(4_096, max(1, maxPendingTargets))
        let boundedDebounce = debounceSeconds.isFinite
            ? min(60, max(0.01, debounceSeconds))
            : 0.5
        self.debounceSeconds = boundedDebounce
        self.source = source ?? .native(scopePath: root.lexicalPath, latency: boundedDebounce)
        self.handler = handler

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    deinit {
        stop()
        timer.setEventHandler {}
        timer.cancel()
    }

    public func start() throws {
        let generation = state.withLock { state -> UInt64? in
            guard !state.active else { return nil }
            state.generation &+= 1
            state.active = true
            return state.generation
        }
        guard let generation else { return }

        let subscription: FileSystemEventSubscription
        do {
            subscription = try source.start { [weak self] events in
                self?.receive(events, generation: generation)
            }
        } catch {
            state.withLock {
                guard $0.generation == generation else { return }
                $0.generation &+= 1
                $0.active = false
                $0.targets.removeAll(keepingCapacity: false)
                $0.requiresFullReconciliation = false
            }
            timer.schedule(deadline: .distantFuture)
            throw error
        }

        let cancelImmediately = state.withLock { state in
            guard state.active, state.generation == generation else { return true }
            state.subscription = subscription
            return false
        }
        if cancelImmediately { subscription.cancel() }
    }

    public func stop() {
        let subscription = state.withLock { state -> FileSystemEventSubscription? in
            state.generation &+= 1
            state.active = false
            state.targets.removeAll(keepingCapacity: false)
            state.requiresFullReconciliation = false
            defer { state.subscription = nil }
            return state.subscription
        }
        timer.schedule(deadline: .distantFuture)
        subscription?.cancel()
    }

    private func receive(_ events: [FileSystemEventHint], generation: UInt64) {
        guard !events.isEmpty else { return }
        guard state.withLock({ $0.active && $0.generation == generation }) else { return }
        var shouldSchedule = false
        for event in events {
            let decision = EventHintPathValidator.decision(
                for: event,
                canonicalScopePath: canonicalScopePath,
                scopeIdentity: scopeIdentity,
                scopeComponentIdentities: scopeComponentIdentities
            )
            let update = state.withLock { state -> (accepted: Bool, requiresFull: Bool) in
                guard state.active, state.generation == generation else { return (false, true) }
                switch decision {
                case .full:
                    state.requiresFullReconciliation = true
                    state.targets.removeAll(keepingCapacity: false)
                case .target(let target):
                    if !state.requiresFullReconciliation {
                        Self.insert(target, into: &state.targets)
                        if state.targets.count > maxPendingTargets {
                            state.targets.removeAll(keepingCapacity: false)
                            state.requiresFullReconciliation = true
                        }
                    }
                }
                return (true, state.requiresFullReconciliation)
            }
            guard update.accepted else { break }
            shouldSchedule = true
            if update.requiresFull { break }
        }
        guard shouldSchedule else { return }
        timer.schedule(
            deadline: .now() + debounceSeconds,
            leeway: .milliseconds(max(1, Int(debounceSeconds * 100)))
        )
    }

    private func flush() {
        let batch = state.withLock { state -> EventScanHintBatch? in
            guard state.active else { return nil }
            let targets = state.targets.values.sorted { $0.relativePath < $1.relativePath }
            let requiresFull = state.requiresFullReconciliation
            guard requiresFull || !targets.isEmpty else { return nil }
            state.targets.removeAll(keepingCapacity: true)
            state.requiresFullReconciliation = false
            return EventScanHintBatch(targets: targets, requiresFullReconciliation: requiresFull)
        }
        if let batch { handler(batch) }
    }

    private static func insert(_ target: EventScanTarget, into targets: inout [String: EventScanTarget]) {
        if targets.keys.contains(where: { target.relativePath == $0 || target.relativePath.hasPrefix($0 + "/") }) {
            return
        }
        targets = targets.filter { !$0.key.hasPrefix(target.relativePath + "/") }
        targets[target.relativePath] = target
    }
}

private enum EventHintPathDecision {
    case target(EventScanTarget)
    case full
}

private enum EventHintPathValidator {
    struct Root {
        var lexicalPath: String
        var canonicalPath: String
        var identity: EvictionFileIdentity
        var componentIdentities: [EvictionFileIdentity]
    }

    static func root(_ scopePath: String) -> Root? {
        guard !scopePath.isEmpty, !scopePath.contains("\0"), scopePath.utf8.count < Int(PATH_MAX) else { return nil }
        let expanded = NSString(string: scopePath).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        let lexical = "/" + components.joined(separator: "/")
        guard lexical.utf8.count < Int(PATH_MAX) else { return nil }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard lexical.withCString({ realpath($0, &resolved) }) != nil else { return nil }
        let canonical = String(cString: resolved)
        guard canonical == lexical else { return nil }

        var current = ""
        var identities: [EvictionFileIdentity] = []
        for component in components {
            current += "/" + component
            guard let info = BulkScanner.lstatPath(current), info.st_mode & S_IFMT == S_IFDIR else { return nil }
            identities.append(EvictionFileIdentity.from(info))
        }
        guard let identity = identities.last else { return nil }
        return Root(
            lexicalPath: lexical,
            canonicalPath: canonical,
            identity: identity,
            componentIdentities: identities
        )
    }

    static func decision(
        for event: FileSystemEventHint,
        canonicalScopePath: String,
        scopeIdentity: EvictionFileIdentity,
        scopeComponentIdentities: [EvictionFileIdentity]
    ) -> EventHintPathDecision {
        if !event.flags.intersection(.requiresFullReconciliation).isEmpty
            || event.flags.contains(.itemIsSymlink) {
            return .full
        }
        guard let currentRoot = root(canonicalScopePath),
              currentRoot.identity == scopeIdentity,
              currentRoot.componentIdentities == scopeComponentIdentities,
              !event.path.isEmpty, !event.path.contains("\0"), event.path.hasPrefix("/"),
              event.path.utf8.count < Int(PATH_MAX) else {
            return .full
        }
        let rawComponents = event.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains(where: { $0 == "." || $0 == ".." }) else { return .full }

        let eventComponents = event.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let lexicalEventPath = "/" + eventComponents.joined(separator: "/")
        guard lexicalEventPath.hasPrefix(canonicalScopePath + "/") else { return .full }
        let relative = String(lexicalEventPath.dropFirst(canonicalScopePath.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return .full
        }

        var current = canonicalScopePath
        var lastDirectory: (relativePath: String, identity: EvictionFileIdentity)?
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard let info = BulkScanner.lstatPath(current) else { break }
            let identity = EvictionFileIdentity.from(info)
            if identity.kind == .symbolicLink || identity.kind == .other { return .full }
            if index < components.count - 1, identity.kind != .directory { return .full }
            if identity.kind == .directory {
                lastDirectory = (
                    components.prefix(index + 1).joined(separator: "/"),
                    identity
                )
            }
        }
        guard let lastDirectory else { return .full }
        return .target(EventScanTarget(
            relativePath: lastDirectory.relativePath,
            identity: lastDirectory.identity,
            scopeComponentIdentities: scopeComponentIdentities
        ))
    }

    static func resolve(
        relativePath: String,
        expectedIdentity: EvictionFileIdentity,
        expectedScopeComponentIdentities: [EvictionFileIdentity],
        under scopePath: String
    ) -> URL? {
        guard let root = root(scopePath),
              root.componentIdentities == expectedScopeComponentIdentities,
              !relativePath.isEmpty, !relativePath.contains("\0") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var current = root.canonicalPath
        for component in components {
            current += "/" + component
            guard let identity = EvictionFileIdentity.capture(path: current),
                  identity.kind == .directory else { return nil }
        }
        guard EvictionFileIdentity.capture(path: current) == expectedIdentity else { return nil }
        return URL(fileURLWithPath: current, isDirectory: true)
    }
}

private final class NativeFSEventCallbackBox: @unchecked Sendable {
    // FSEvents crosses a C callback boundary; this box is safe because its
    // only state is an immutable @Sendable closure.
    let handler: FileSystemEventSource.Handler

    init(handler: @escaping FileSystemEventSource.Handler) {
        self.handler = handler
    }
}

private final class NativeFSEventSubscription: @unchecked Sendable {
    // The opaque FSEventStreamRef is only read and cleared under `lock`.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let callbackBox: NativeFSEventCallbackBox

    private init(stream: FSEventStreamRef, callbackBox: NativeFSEventCallbackBox) {
        self.stream = stream
        self.callbackBox = callbackBox
    }

    deinit {
        cancel()
    }

    static func start(
        scopePath: String,
        latency: TimeInterval,
        handler: @escaping FileSystemEventSource.Handler
    ) throws -> FileSystemEventSubscription {
        let box = NativeFSEventCallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
                guard let callbackInfo else { return }
                let box = Unmanaged<NativeFSEventCallbackBox>
                    .fromOpaque(callbackInfo).takeUnretainedValue()
                guard eventCount <= 4_096 else {
                    box.handler([FileSystemEventHint(path: "", flags: .mustScanSubdirectories)])
                    return
                }
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)
                guard paths.count >= eventCount else {
                    box.handler([FileSystemEventHint(path: "", flags: .mustScanSubdirectories)])
                    return
                }
                var events: [FileSystemEventHint] = []
                events.reserveCapacity(eventCount)
                for index in 0..<eventCount {
                    guard let path = paths[index] as? String else {
                        box.handler([FileSystemEventHint(path: "", flags: .mustScanSubdirectories)])
                        return
                    }
                    events.append(FileSystemEventHint(
                        path: path,
                        flags: FileSystemEventFlags(rawValue: eventFlags[index])
                    ))
                }
                if !events.isEmpty { box.handler(events) }
            },
            &context,
            [scopePath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            createFlags
        ) else {
            throw EventScanHintError.eventSourceCreationFailed
        }

        let subscription = NativeFSEventSubscription(stream: stream, callbackBox: box)
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            subscription.cancel()
            throw EventScanHintError.eventSourceStartFailed
        }
        return FileSystemEventSubscription { subscription.cancel() }
    }

    func cancel() {
        let stream = lock.withLock { () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        withExtendedLifetime(callbackBox) {}
    }
}
