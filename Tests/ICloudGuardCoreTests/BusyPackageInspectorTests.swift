import Darwin
import Foundation
import XCTest
@testable import ICloudGuardCore

final class BusyPackageInspectorTests: XCTestCase {
    func testClearExcludesInspectorProcess() throws {
        let package = try makePackage()
        let provider = StubProvider(
            processList: BusyPackageProcessList(processIDs: [101], isComplete: true),
            names: [101: "icloud-guard"]
        )

        let result = BusyPackageInspector(provider: provider, currentProcessID: 101)
            .inspect(packagePath: package.path)

        XCTAssertEqual(result, .clear)
    }

    func testBusyReturnsOnlyBoundedDeduplicatedDisplayNames() throws {
        let package = try makePackage()
        let provider = StubProvider(
            processList: BusyPackageProcessList(processIDs: [10, 11, 12, 12], isComplete: true),
            names: [
                10: "/Users/alice/Private/Editor",
                11: "Editor",
                12: "Worker\nSecret",
            ]
        )

        let result = BusyPackageInspector(
            provider: provider,
            limits: .init(maximumProcesses: 4, maximumProcessNameBytes: 8),
            currentProcessID: 999
        ).inspect(packagePath: package.path)

        XCTAssertEqual(
            result,
            .busy(BusyPackageAssistance(processDisplayNames: ["Editor", "WorkerSe"]))
        )
        XCTAssertFalse(String(describing: result).contains("/Users/alice"))
        XCTAssertFalse(String(describing: result).contains(package.path))
    }

    func testTruncatedAndOversizedResponsesFailUnavailable() throws {
        let package = try makePackage()
        let truncated = StubProvider(
            processList: BusyPackageProcessList(processIDs: [10], isComplete: false),
            names: [10: "Editor"]
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: truncated).inspect(packagePath: package.path),
            .unavailable(.truncated)
        )

        let oversized = StubProvider(
            processList: BusyPackageProcessList(processIDs: [10, 11], isComplete: true),
            names: [10: "Editor", 11: "Worker"]
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: oversized, limits: .init(maximumProcesses: 1))
                .inspect(packagePath: package.path),
            .unavailable(.invalidResponse)
        )
    }

    func testPermissionAndProviderErrorsFailUnavailable() throws {
        let package = try makePackage()
        XCTAssertEqual(
            BusyPackageInspector(provider: StubProvider(listError: .permissionDenied))
                .inspect(packagePath: package.path),
            .unavailable(.permissionDenied)
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: StubProvider(listError: .unavailable))
                .inspect(packagePath: package.path),
            .unavailable(.providerError)
        )

        let nameFailure = StubProvider(
            processList: BusyPackageProcessList(processIDs: [10], isComplete: true),
            nameErrors: [10: .permissionDenied]
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: nameFailure).inspect(packagePath: package.path),
            .unavailable(.permissionDenied)
        )
    }

    func testDeadlineAndInvalidPackageFailUnavailable() throws {
        let package = try makePackage()
        let provider = StubProvider(
            processList: BusyPackageProcessList(processIDs: [], isComplete: true)
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: provider, limits: .init(deadlineNanoseconds: 0))
                .inspect(packagePath: package.path),
            .unavailable(.deadlineExceeded)
        )
        XCTAssertEqual(
            BusyPackageInspector(provider: provider).inspect(packagePath: "relative.app"),
            .unavailable(.invalidPackage)
        )
    }

    func testLibprocProviderFindsSelfHoldingDescendantOpen() throws {
        let package = try makePackage()
        let file = package.appendingPathComponent("open.dat")
        try Data("open".utf8).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        let processes = try LibprocBusyPackageProcessProvider()
            .processIDsReferencing(
                packagePath: package.resolvingSymlinksInPath().path,
                limits: .init(
                    maximumProcesses: 4_096,
                    maximumReferencePaths: 4_096,
                    maximumMatches: 64
                ),
                shouldStop: { false }
            )

        XCTAssertTrue(processes.isComplete)
        XCTAssertTrue(processes.processIDs.contains(getpid()))
    }

    private func makePackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("Document.package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return package
    }
}

private struct StubProvider: BusyPackageProcessProviding {
    var processList = BusyPackageProcessList(processIDs: [], isComplete: true)
    var names: [pid_t: String] = [:]
    var listError: BusyPackageProcessProviderError?
    var nameErrors: [pid_t: BusyPackageProcessProviderError] = [:]

    func processIDsReferencing(
        packagePath: String,
        limits: BusyPackageProcessInspectionLimits,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws -> BusyPackageProcessList {
        if let listError { throw listError }
        return processList
    }

    func processDisplayName(for processID: pid_t) throws -> String {
        if let error = nameErrors[processID] { throw error }
        guard let name = names[processID] else { throw BusyPackageProcessProviderError.unavailable }
        return name
    }
}
