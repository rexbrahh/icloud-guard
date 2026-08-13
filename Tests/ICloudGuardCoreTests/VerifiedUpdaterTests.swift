import CryptoKit
import Darwin
import XCTest
@testable import ICloudGuardCore

final class VerifiedUpdaterTests: XCTestCase {
    func testSemanticVersionImplementsSemVerPrecedenceAndStrictParsing() throws {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ].compactMap(SemanticVersion.init)
        XCTAssertEqual(ordered.count, 8)
        XCTAssertEqual(ordered.sorted(), ordered)
        XCTAssertEqual(SemanticVersion("1.0.0+build.1"), SemanticVersion("1.0.0+build.2"))
        XCTAssertNil(SemanticVersion("01.0.0"))
        XCTAssertNil(SemanticVersion("1.0"))
        XCTAssertNil(SemanticVersion("1.0.0-01"))
        XCTAssertNil(SemanticVersion("1.0.0+"))
        XCTAssertNil(SemanticVersion("1.0.0-α"))
    }

    func testAuthenticatedStableCheckIsMetadataOnlyAndThenUsesCache() async throws {
        let fixture = try Fixture()
        let artifact = Data("verified archive".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let feed = try fixture.feed([release])
        let transport = FakeUpdateTransport([
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let verifier = FakeArtifactVerifier()
        let updater = try fixture.updater(transport: transport, verifier: verifier)

        let first = try await updater.check()
        guard case .available(let candidate) = first.availability else {
            return XCTFail("Expected an available update.")
        }
        XCTAssertEqual(candidate.release, release)
        XCTAssertEqual(first.source, .network)
        let firstTransportCount = await transport.callCount()
        let firstVerifierCount = await verifier.callCount()
        XCTAssertEqual(firstTransportCount, 1)
        XCTAssertEqual(firstVerifierCount, 0)
        XCTAssertEqual(
            try permissions(fixture.root.appendingPathComponent(UpdaterContinuityFileStore.filename)),
            0o600
        )
        XCTAssertEqual(
            try permissions(fixture.root.appendingPathComponent(UpdaterContinuityFileStore.lockFilename)),
            0o600
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(release.artifactFilename).path))

        let cached = try await updater.check()
        XCTAssertEqual(cached.source, .cache)
        XCTAssertEqual(cached.availability, first.availability)
        let cachedTransportCount = await transport.callCount()
        XCTAssertEqual(cachedTransportCount, 1)
    }

    func testExplicitDownloadVerifiesExactArtifactAndReturnsManualHandoff() async throws {
        let fixture = try Fixture()
        let artifact = Data("release archive bytes".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let feed = try fixture.feed([release])
        let transport = FakeUpdateTransport([
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(artifact, status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: nil),
        ])
        let verifier = FakeArtifactVerifier()
        let updater = try fixture.updater(transport: transport, verifier: verifier)
        let check = try await updater.check()
        guard case .available(let candidate) = check.availability else {
            return XCTFail("Expected an available update.")
        }

        let handoff = try await updater.download(candidate)

        XCTAssertEqual(try Data(contentsOf: handoff.verifiedArchiveURL), artifact)
        XCTAssertEqual(try permissions(handoff.verifiedArchiveURL), 0o600)
        XCTAssertEqual(try permissions(handoff.verifiedArchiveURL.deletingLastPathComponent()), 0o700)
        XCTAssertTrue(handoff.instructions.contains("manually"))
        let verifierCount = await verifier.callCount()
        let transportCount = await transport.callCount()
        XCTAssertEqual(verifierCount, 1)
        XCTAssertEqual(transportCount, 2)
        try await updater.discard(handoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.verifiedArchiveURL.path))
    }

    func testTamperedArtifactIsDeletedBeforePlatformVerifierRuns() async throws {
        let fixture = try Fixture()
        let artifact = Data("expected".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(Data("tampered".utf8), status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: Int64(artifact.count)),
        ])
        let verifier = FakeArtifactVerifier()
        let updater = try fixture.updater(transport: transport, verifier: verifier)
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }

        await XCTAssertThrowsUpdaterError(.artifactIntegrityFailed) {
            _ = try await updater.download(candidate)
        }
        let verifierCount = await verifier.callCount()
        XCTAssertEqual(verifierCount, 0)
        XCTAssertTrue(try updaterTemporaryDirectories(fixture.root).isEmpty)
    }

    func testPlatformVerificationFailureDeletesArtifactAndUsesSafeError() async throws {
        let fixture = try Fixture()
        let artifact = Data("archive".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(artifact, status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(
            transport: transport,
            verifier: FakeArtifactVerifier(fails: true)
        )
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }

        await XCTAssertThrowsUpdaterError(.artifactVerificationFailed) {
            _ = try await updater.download(candidate)
        }
        XCTAssertEqual(UpdaterError.artifactVerificationFailed.localizedDescription, "The downloaded update failed platform verification.")
        XCTAssertFalse(UpdaterError.artifactVerificationFailed.localizedDescription.contains(fixture.root.path))
        XCTAssertTrue(try updaterTemporaryDirectories(fixture.root).isEmpty)
    }

    func testWrongSignatureAndNonCanonicalSignedPayloadAreRejected() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let payload = fixture.payload([release])
        let wrongKey = P256.Signing.PrivateKey()
        let canonical = try UpdateFeedCodec.canonicalPayloadData(payload)
        let wrongSignature = try wrongKey.signature(for: canonical).derRepresentation
        let wrongFeed = try UpdateFeedCodec.envelopeData(
            payload: payload,
            keyID: fixture.keyID,
            signatureDER: wrongSignature
        )
        let wrongUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(wrongFeed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.feedAuthenticationFailed) { _ = try await wrongUpdater.check() }

        let nonCanonicalPayload = canonical + Data([0x20])
        let signature = try fixture.privateKey.signature(for: nonCanonicalPayload).derRepresentation
        let envelope = try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "keyID": fixture.keyID,
            "payload": nonCanonicalPayload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ], options: [.sortedKeys])
        let nonCanonicalUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(envelope, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.feedMalformed) { _ = try await nonCanonicalUpdater.check() }
    }

    func testSignedMetadataStillRejectsStableReleaseLiesAndCrossOriginArtifacts() async throws {
        let fixture = try Fixture()
        var notStapled = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        notStapled.stapled = false
        let first = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([notStapled]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await first.check() }

        var crossOrigin = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        crossOrigin.artifactURL = URL(string: "https://cdn.example.test/\(crossOrigin.artifactFilename)")!
        let second = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([crossOrigin]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await second.check() }
    }

    func testBetaContractRequiresBetaNamesAndTrustedDeveloperIDProvenance() async throws {
        let fixture = try Fixture(channel: .beta)
        let artifact = Data("beta".utf8)
        let beta = fixture.release(channel: .beta, version: "0.5.0", artifact: artifact)
        let updater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([beta]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected a beta update.")
        }
        XCTAssertEqual(candidate.release.tag, "beta-0.5.0")
        XCTAssertEqual(candidate.release.artifactFilename, "ICloudGuard-beta-0.5.0.zip")

        var lie = beta
        lie.provenance = .unauthenticatedTip
        let rejected = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([lie]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await rejected.check() }
    }

    func testAuthenticatedFeedMissingSelectedChannelIsRejected() async throws {
        let fixture = try Fixture(channel: .beta)
        let stable = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("stable".utf8))
        let updater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([stable]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))

        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await updater.check() }
    }

    func testTipIsExplicitlyUnsupportedWithoutNetworkOrArtifactAccess() async throws {
        let fixture = try Fixture(channel: .tip)
        let transport = FakeUpdateTransport([.failure(.requestFailed)])
        let updater = try fixture.updater(transport: transport)

        let result = try await updater.check()

        XCTAssertEqual(
            result.availability,
            .unsupported(channel: .tip, reason: .tipRequiresIndependentAuthentication)
        )
        let transportCount = await transport.callCount()
        XCTAssertEqual(transportCount, 0)
    }

    func testExpiredFutureAndDuplicateFeedsAreRejected() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let expired = UpdateFeedPayload(
            generatedAtEpoch: 100,
            expiresAtEpoch: 900,
            releases: [release]
        )
        let expiredUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(expired), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.feedExpired) { _ = try await expiredUpdater.check() }

        let future = UpdateFeedPayload(
            generatedAtEpoch: 2_000,
            expiresAtEpoch: 2_100,
            releases: [release]
        )
        let futureUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(future), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.feedExpired) { _ = try await futureUpdater.check() }

        let duplicateUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed([release, release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await duplicateUpdater.check() }
    }

    func testCrossOriginRedirectAndNonHTTPSConfigurationAreRejected() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let feed = try fixture.feed([release])
        let evil = URL(string: "https://evil.example.test/feed.json")!
        let updater = try fixture.updater(transport: FakeUpdateTransport([
            .data(feed, status: 200, finalURL: evil, redirects: [evil], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.responseRejected) { _ = try await updater.check() }

        var configuration = fixture.configuration
        configuration.feedURL = URL(string: "http://updates.example.test/feed.json")!
        XCTAssertThrowsError(try VerifiedReleaseUpdater(configuration: configuration)) { error in
            XCTAssertEqual(error as? UpdaterError, .invalidConfiguration)
        }

        XCTAssertTrue(URLSessionUpdateTransport.sameOrigin(
            URL(string: "https://EXAMPLE.test/a")!,
            URL(string: "https://example.test:443/b")!
        ))
        XCTAssertFalse(URLSessionUpdateTransport.sameOrigin(
            URL(string: "https://example.test/a")!,
            URL(string: "https://example.test:444/b")!
        ))
        XCTAssertFalse(URLSessionUpdateTransport.sameOrigin(
            URL(string: "https://example.test/a")!,
            URL(string: "http://example.test/b")!
        ))
    }

    func testUpdaterCreatesAndHardensAbsentTemporaryRoot() async throws {
        let fixture = try Fixture()
        let absentRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let feed = try fixture.feed([release])
        var configuration = fixture.configuration
        configuration.temporaryRoot = absentRoot
        let clock = fixture.clock
        let firstTransport = FakeUpdateTransport([
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let firstUpdater = try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: firstTransport,
            artifactVerifier: FakeArtifactVerifier(),
            now: { clock.now() }
        )

        _ = try await firstUpdater.check()

        var metadata = stat()
        XCTAssertEqual(absentRoot.path.withCString { lstat($0, &metadata) }, 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(metadata.st_uid, geteuid())
        XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: absentRoot.path)), Set([
            UpdaterContinuityFileStore.filename,
            UpdaterContinuityFileStore.lockFilename,
        ]))

        XCTAssertEqual(chmod(absentRoot.path, mode_t(0o777)), 0)
        let secondTransport = FakeUpdateTransport([
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let secondUpdater = try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: secondTransport,
            artifactVerifier: FakeArtifactVerifier(),
            now: { clock.now() }
        )
        _ = try await secondUpdater.check()
        XCTAssertEqual(try permissions(absentRoot), 0o700)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: absentRoot.path)), Set([
            UpdaterContinuityFileStore.filename,
            UpdaterContinuityFileStore.lockFilename,
        ]))
    }

    func testUpdaterRejectsSymlinkTemporaryRootWithoutTouchingTargetOrTransport() async throws {
        let fixture = try Fixture()
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let symlinkRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: target)
        let marker = target.appendingPathComponent("marker")
        try Data("unchanged".utf8).write(to: marker)
        var configuration = fixture.configuration
        configuration.temporaryRoot = symlinkRoot
        let clock = fixture.clock
        let transport = FakeUpdateTransport([.failure(.requestFailed)])
        let updater = try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: transport,
            artifactVerifier: FakeArtifactVerifier(),
            now: { clock.now() }
        )

        await XCTAssertThrowsUpdaterError(.temporaryStorageUnavailable) {
            _ = try await updater.check()
        }

        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try Data(contentsOf: marker), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["marker"])
        var metadata = stat()
        XCTAssertEqual(symlinkRoot.path.withCString { lstat($0, &metadata) }, 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
    }

    func testFailureBackoffIsBoundedAndRetryUsesConfiguredTransportLimits() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let transport = FakeUpdateTransport([
            .failure(.requestFailed),
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)

        await XCTAssertThrowsUpdaterError(.transportFailed) { _ = try await updater.check() }
        await XCTAssertThrowsUpdaterError(.backoffActive(retryAfterSeconds: 10)) { _ = try await updater.check() }
        let failedCallCount = await transport.callCount()
        XCTAssertEqual(failedCallCount, 1)
        clock.advance(10)
        _ = try await updater.check()
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].maximumBytes, fixture.configuration.maximumFeedBytes)
        XCTAssertEqual(calls[1].timeout, fixture.configuration.feedTimeout)
    }

    func testCancellationDoesNotBecomeFailureBackoff() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let transport = FakeUpdateTransport([
            .waitForCancellation,
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let task = Task { try await updater.check() }
        await transport.waitForCalls(1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await updater.check()
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testCancellationWinsEvenWhenInjectedTransportReturnsSuccess() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let transport = FakeUpdateTransport([
            .returnAfterCancellation(try fixture.feed([release]), finalURL: fixture.feedURL),
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let task = Task { try await updater.check() }
        await transport.waitForCalls(1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await updater.check()
        let count = await transport.callCount()
        XCTAssertEqual(count, 2)
    }

    func testNativeProcessCancellationTerminatesAndReapsSubprocess() async throws {
        let launchedPID = LockedPID()
        let task = Task {
            try await UpdaterNativeProcess.run(
                "/bin/sleep",
                ["30"],
                timeoutSeconds: 60,
                onLaunch: { launchedPID.set($0) }
            )
        }
        while launchedPID.get() == nil { await Task.yield() }
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected native process cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let pid = try XCTUnwrap(launchedPID.get())
        var reaped = false
        for _ in 0..<100 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                reaped = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reaped, "Cancelled verifier subprocess must be reaped.")
    }

    func testAuthenticatedFeedRejectsRollbackAndSameVersionEquivocation() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let firstRelease = fixture.release(
            channel: .stable,
            version: "0.5.0",
            artifact: Data("first".utf8)
        )
        let equivocatedRelease = fixture.release(
            channel: .stable,
            version: "0.5.0",
            artifact: Data("different".utf8)
        )
        let firstPayload = UpdateFeedPayload(
            generatedAtEpoch: 900,
            expiresAtEpoch: 2_000,
            releases: [firstRelease]
        )
        let rollbackPayload = UpdateFeedPayload(
            generatedAtEpoch: 899,
            expiresAtEpoch: 2_500,
            releases: [firstRelease]
        )
        let equivocationPayload = UpdateFeedPayload(
            generatedAtEpoch: 901,
            expiresAtEpoch: 2_600,
            releases: [equivocatedRelease]
        )
        let transport = FakeUpdateTransport([
            .data(try fixture.feed(firstPayload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(try fixture.feed(rollbackPayload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(try fixture.feed(equivocationPayload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)

        _ = try await updater.check()
        clock.advance(901)
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await updater.check() }
        clock.advance(10)
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await updater.check() }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testPersistentContinuityRejectsRollbackAndSameGenerationMismatchAfterRestart() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let firstRelease = fixture.release(
            channel: .stable,
            version: "0.5.0",
            artifact: Data("first".utf8)
        )
        let firstPayload = UpdateFeedPayload(
            generatedAtEpoch: 900,
            expiresAtEpoch: 2_000,
            releases: [firstRelease]
        )
        let firstUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(firstPayload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        _ = try await firstUpdater.check()

        let rollbackPayload = UpdateFeedPayload(
            generatedAtEpoch: 899,
            expiresAtEpoch: 2_100,
            releases: [firstRelease]
        )
        let restartedForRollback = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(rollbackPayload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) {
            _ = try await restartedForRollback.check()
        }

        let changed = fixture.release(
            channel: .stable,
            version: "0.5.0",
            artifact: Data("changed".utf8)
        )
        let sameGenerationMismatch = UpdateFeedPayload(
            generatedAtEpoch: 900,
            expiresAtEpoch: 2_200,
            releases: [changed]
        )
        let restartedForMismatch = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(sameGenerationMismatch), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) {
            _ = try await restartedForMismatch.check()
        }
    }

    func testPersistentContinuityRejectsCorruptSymlinkFIFOAndOversizeState() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let feed = try fixture.feed([release])
        for kind in ["corrupt", "symlink", "fifo", "oversize"] {
            let root = fixture.root.appendingPathComponent("state-\(kind)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(root.path, 0o700), 0)
            let stateURL = root.appendingPathComponent(UpdaterContinuityFileStore.filename)
            switch kind {
            case "corrupt":
                try Data("not-json".utf8).write(to: stateURL)
                XCTAssertEqual(chmod(stateURL.path, 0o600), 0)
            case "symlink":
                let target = fixture.root.appendingPathComponent("state-target")
                try Data("unchanged".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)
            case "fifo":
                XCTAssertEqual(Darwin.mkfifo(stateURL.path, 0o600), 0)
            case "oversize":
                XCTAssertTrue(FileManager.default.createFile(atPath: stateURL.path, contents: Data()))
                let descriptor = Darwin.open(stateURL.path, O_WRONLY | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                XCTAssertEqual(Darwin.ftruncate(
                    descriptor,
                    off_t(UpdaterContinuityFileStore.maximumBytes + 1)
                ), 0)
                if descriptor >= 0 { Darwin.close(descriptor) }
                XCTAssertEqual(chmod(stateURL.path, 0o600), 0)
            default:
                XCTFail("Unknown continuity fixture.")
            }
            var configuration = fixture.configuration
            configuration.temporaryRoot = root
            let clock = fixture.clock
            let updater = try VerifiedReleaseUpdater(
                configuration: configuration,
                transport: FakeUpdateTransport([
                    .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
                ]),
                artifactVerifier: FakeArtifactVerifier(),
                now: { clock.now() },
                monotonicNow: { clock.monotonicNow() }
            )
            await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) {
                _ = try await updater.check()
            }
        }
    }

    func testContinuitySaveFailureDoesNotAdvanceAcceptedState() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let newer = UpdateFeedPayload(
            generatedAtEpoch: 900,
            expiresAtEpoch: 2_000,
            releases: [release]
        )
        let older = UpdateFeedPayload(
            generatedAtEpoch: 899,
            expiresAtEpoch: 2_100,
            releases: [release]
        )
        let transport = FakeUpdateTransport([
            .data(try fixture.feed(newer), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(try fixture.feed(older), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let store = FailingContinuityStore()
        await updater.setContinuityStoreForTesting(store)

        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await updater.check() }
        XCTAssertTrue(store.snapshot().entries.isEmpty)
        store.allowSaves()
        clock.advance(10)
        let accepted = try await updater.check()
        guard case .available = accepted.availability else {
            return XCTFail("Expected the older feed to be accepted after the failed save.")
        }
        XCTAssertEqual(store.snapshot().entries.first?.highestGeneratedAt, 899)
    }

    func testConcurrentStaleCheckCannotRegressDurableContinuity() async throws {
        let fixture = try Fixture()
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let older = UpdateFeedPayload(
            generatedAtEpoch: 900,
            expiresAtEpoch: 2_000,
            releases: [release]
        )
        let newer = UpdateFeedPayload(
            generatedAtEpoch: 901,
            expiresAtEpoch: 2_100,
            releases: [release]
        )
        let staleTransport = PausingUpdateTransport(
            data: try fixture.feed(older),
            finalURL: fixture.feedURL
        )
        let staleUpdater = try fixture.updater(transport: staleTransport)
        let newerUpdater = try fixture.updater(transport: FakeUpdateTransport([
            .data(try fixture.feed(newer), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ]))
        let staleTask = Task { try await staleUpdater.check() }
        await staleTransport.waitUntilStarted()

        _ = try await newerUpdater.check()
        await staleTransport.resume()
        await XCTAssertThrowsUpdaterError(.releaseMetadataRejected) { _ = try await staleTask.value }

        let durable = try UpdaterContinuityFileStore(root: fixture.root).load()
        XCTAssertEqual(durable.entries.first?.highestGeneratedAt, 901)
        XCTAssertEqual(durable.entries.first?.releases.count, 1)
    }

    func testMonotonicTTLAndWallClockRollbackFailClosed() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let feed = try fixture.feed([release])
        let transport = FakeUpdateTransport([
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(feed, status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        _ = try await updater.check()
        clock.advanceMonotonic(901)
        let refreshed = try await updater.check()
        XCTAssertEqual(refreshed.source, .network)
        let callsAfterMonotonicExpiry = await transport.callCount()
        XCTAssertEqual(callsAfterMonotonicExpiry, 2)
        clock.rewindWall(1)
        await XCTAssertThrowsUpdaterError(.feedExpired) { _ = try await updater.check() }
        let callsAfterRollback = await transport.callCount()
        XCTAssertEqual(callsAfterRollback, 2)
    }

    func testForwardWallClockJumpPastSignedExpiryRejectsCandidate() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let artifact = Data("artifact".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }
        clock.advanceWall(1_001)

        await XCTAssertThrowsUpdaterError(.candidateExpired) {
            _ = try await updater.download(candidate)
        }

        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testVerifierCannotChangeArchiveAfterIntegrityCheck() async throws {
        let fixture = try Fixture()
        let artifact = Data("archive".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(artifact, status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(
            transport: transport,
            verifier: MutatingArtifactVerifier()
        )
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }

        await XCTAssertThrowsUpdaterError(.artifactIntegrityFailed) {
            _ = try await updater.download(candidate)
        }
        XCTAssertTrue(try updaterTemporaryDirectories(fixture.root).isEmpty)
    }

    func testNativeVerifierRejectsArchiveForAnotherBundleBeforeHandoff() async throws {
        let fixture = try Fixture()
        let stage = fixture.root.appendingPathComponent("stage", isDirectory: true)
        let app = stage.appendingPathComponent("ICloudGuard.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/ICloudGuard")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("binary".utf8).write(to: executable)
        let info: [String: Any] = [
            "CFBundleExecutable": "ICloudGuard",
            "CFBundleIdentifier": "example.WrongProduct",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.5.0",
            "LSMinimumSystemVersion": "15.0",
        ]
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-wx", "com.apple.ResourceFork", "00010203", executable.path]
        try xattr.run()
        xattr.waitUntilExit()
        XCTAssertEqual(xattr.terminationStatus, 0)
        let archive = fixture.root.appendingPathComponent("wrong-product.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let release = fixture.release(
            channel: .stable,
            version: "0.5.0",
            artifact: try Data(contentsOf: archive)
        )
        XCTAssertGreaterThan(try MacOSReleaseArtifactVerifier.preflightArchive(
            archive,
            expectedArchiveBytes: release.artifactSize
        ), 0)

        do {
            try await MacOSReleaseArtifactVerifier().verify(artifactURL: archive, release: release)
            XCTFail("Expected native artifact verification to reject the wrong bundle.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
        }
    }

    func testNativeVerifierPreflightsHostileArchivesWithoutExtracting() async throws {
        let fixture = try Fixture()
        let canary = fixture.root.appendingPathComponent("canary")
        try Data("unchanged".utf8).write(to: canary)
        let regularMode = UInt32(S_IFREG | 0o644)
        let hostileCases: [(String, [RawZipEntry])] = [
            ("traversal", [.init(path: "ICloudGuard.app/../../canary", mode: regularMode)]),
            ("backslash", [.init(path: "ICloudGuard.app/..\\canary", mode: regularMode)]),
            ("control", [.init(path: "ICloudGuard.app/bad\u{0}name", mode: regularMode)]),
            ("unexpected-root", [.init(path: "Other.app/file", mode: regularMode)]),
            ("duplicate", [
                .init(path: "ICloudGuard.app/file", mode: regularMode),
                .init(path: "ICloudGuard.app/file", mode: regularMode),
            ]),
            ("case-collision", [
                .init(path: "ICloudGuard.app/File", mode: regularMode),
                .init(path: "ICloudGuard.app/file", mode: regularMode),
            ]),
            ("unicode-case-fold-collision", [
                .init(path: "ICloudGuard.app/Straße", mode: regularMode),
                .init(path: "ICloudGuard.app/STRASSE", mode: regularMode),
            ]),
            ("file-directory-collision", [
                .init(path: "ICloudGuard.app/item", mode: regularMode),
                .init(path: "ICloudGuard.app/item/", mode: UInt32(S_IFDIR | 0o755)),
            ]),
            ("symlink", [
                .init(
                    path: "ICloudGuard.app/link",
                    mode: UInt32(S_IFLNK | 0o777),
                    payload: Data("../../canary".utf8)
                ),
            ]),
            ("special", [
                .init(path: "ICloudGuard.app/pipe", mode: UInt32(S_IFIFO | 0o600)),
            ]),
            ("oversized", [
                .init(
                    path: "ICloudGuard.app/huge",
                    mode: regularMode,
                    compressedSize: 1,
                    uncompressedSize: UInt32(MacOSReleaseArtifactVerifier.maximumExpandedFileBytes + 1)
                ),
            ]),
            ("ratio", [
                .init(
                    path: "ICloudGuard.app/bomb",
                    mode: regularMode,
                    compressedSize: 1,
                    uncompressedSize: UInt32(MacOSReleaseArtifactVerifier.compressionRatioThresholdBytes)
                ),
            ]),
            ("aggregate-ratio", [
                .init(
                    path: "ICloudGuard.app/part-1",
                    mode: regularMode,
                    compressedSize: 1,
                    uncompressedSize: 600 * 1024
                ),
                .init(
                    path: "ICloudGuard.app/part-2",
                    mode: regularMode,
                    compressedSize: 1,
                    uncompressedSize: 600 * 1024
                ),
            ]),
            ("integrity", [
                .init(
                    path: "ICloudGuard.app/bad-crc",
                    mode: regularMode,
                    payload: Data("not-matching-the-zero-crc".utf8)
                ),
            ]),
            ("entry-count", (0..<MacOSReleaseArtifactVerifier.maximumArchiveEntries).map {
                .init(path: "ICloudGuard.app/file-\($0)", mode: regularMode)
            }),
        ]

        for (label, entries) in hostileCases {
            let archive = fixture.root.appendingPathComponent("hostile-\(label).zip")
            try writeRawZip(entries: entries, to: archive)
            let release = fixture.release(
                channel: .stable,
                version: "0.5.0",
                artifact: try Data(contentsOf: archive)
            )
            do {
                try await MacOSReleaseArtifactVerifier().verify(artifactURL: archive, release: release)
                XCTFail("Expected hostile archive rejection for \(label).")
            } catch {
                XCTAssertEqual(error as? UpdaterError, .artifactVerificationFailed, label)
            }
            XCTAssertEqual(try Data(contentsOf: canary), Data("unchanged".utf8), label)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                    .contains(where: { $0.hasPrefix("verification-") }),
                label
            )
        }
    }

    func testNativeVerifierBoundsAndDoesNotFollowInfoPlist() throws {
        let fixture = try Fixture()
        let oversized = fixture.root.appendingPathComponent("oversized-Info.plist")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let descriptor = Darwin.open(oversized.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(Darwin.ftruncate(
            descriptor,
            off_t(MacOSReleaseArtifactVerifier.maximumInfoPlistBytes + 1)
        ), 0)
        if descriptor >= 0 { Darwin.close(descriptor) }
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.readInfoPlist(oversized))

        let target = fixture.root.appendingPathComponent("target.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "dev.rexliu.ICloudGuard"],
            format: .xml,
            options: 0
        ).write(to: target)
        let link = fixture.root.appendingPathComponent("symlink-Info.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.readInfoPlist(link))
    }

    func testDiscardRejectsTemporaryRootSymlinkSwapWithoutTouchingCanary() async throws {
        let fixture = try Fixture()
        let temporaryRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        var configuration = fixture.configuration
        configuration.temporaryRoot = temporaryRoot
        let artifact = Data("verified archive".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(artifact, status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: nil),
        ])
        let clock = fixture.clock
        let updater = try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: transport,
            artifactVerifier: FakeArtifactVerifier(),
            now: { clock.now() }
        )
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }
        let handoff = try await updater.download(candidate)
        let originalRoot = fixture.root.appendingPathComponent("original-cache", isDirectory: true)
        try FileManager.default.moveItem(at: temporaryRoot, to: originalRoot)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let matchingChild = outside.appendingPathComponent(
            handoff.verifiedArchiveURL.deletingLastPathComponent().lastPathComponent,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: matchingChild, withIntermediateDirectories: true)
        let canary = matchingChild.appendingPathComponent(release.artifactFilename)
        try Data("unchanged".utf8).write(to: canary)
        XCTAssertEqual(chmod(matchingChild.path, 0o700), 0)
        XCTAssertEqual(chmod(canary.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: temporaryRoot, withDestinationURL: outside)

        do {
            try await updater.discard(handoff)
            XCTFail("Expected a swapped temporary root to be rejected.")
        } catch let error as UpdaterError {
            XCTAssertEqual(error, .temporaryStorageUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: canary), Data("unchanged".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoff.verifiedArchiveURL.path))
    }

    func testDiscardDoesNotRemoveSameNameReplacementDirectory() async throws {
        let fixture = try Fixture()
        let artifact = Data("verified archive".utf8)
        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: artifact)
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([release]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
            .data(artifact, status: 200, finalURL: release.artifactURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let result = try await updater.check()
        guard case .available(let candidate) = result.availability else {
            return XCTFail("Expected an available update.")
        }
        let handoff = try await updater.download(candidate)
        let originalDirectory = handoff.verifiedArchiveURL.deletingLastPathComponent()
        let movedDirectory = fixture.root.appendingPathComponent("moved-original", isDirectory: true)
        let canary = originalDirectory.appendingPathComponent("canary")
        let hookFailed = LockedFlag()
        await updater.setBeforeDirectoryUnlinkForTesting { directory in
            do {
                try FileManager.default.moveItem(at: directory, to: movedDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data("unchanged".utf8).write(to: canary)
                guard chmod(directory.path, 0o700) == 0,
                      chmod(canary.path, 0o600) == 0 else {
                    throw UpdateTransportError.destinationRejected
                }
            } catch {
                hookFailed.set()
            }
        }

        do {
            try await updater.discard(handoff)
            XCTFail("Expected replacement identity rejection.")
        } catch let error as UpdaterError {
            XCTAssertEqual(error, .temporaryStorageUnavailable)
        }
        XCTAssertFalse(hookFailed.get())
        XCTAssertEqual(try Data(contentsOf: canary), Data("unchanged".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDirectory.path))
    }

    func testStartupCleanupIsBoundedToOwnedOldUpdaterDirectories() async throws {
        let clock = LockedClock(Date())
        let fixture = try Fixture(clock: clock)
        let temporaryRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(temporaryRoot.path, 0o700), 0)
        let prefix = "icloud-guard-update-"
        let stale = temporaryRoot.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        let fresh = temporaryRoot.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(stale.path, 0o700), 0)
        XCTAssertEqual(chmod(fresh.path, 0o700), 0)
        let staleArtifact = stale.appendingPathComponent("feed.json")
        try Data("stale".utf8).write(to: staleArtifact)
        XCTAssertEqual(chmod(staleArtifact.path, 0o600), 0)
        var staleTimes = [
            timeval(tv_sec: Int(clock.now().timeIntervalSince1970) - 2 * 24 * 60 * 60, tv_usec: 0),
            timeval(tv_sec: Int(clock.now().timeIntervalSince1970) - 2 * 24 * 60 * 60, tv_usec: 0),
        ]
        XCTAssertEqual(stale.path.withCString { Darwin.utimes($0, &staleTimes) }, 0)

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let canary = outside.appendingPathComponent("canary")
        try Data("unchanged".utf8).write(to: canary)
        let symlink = temporaryRoot.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let release = fixture.release(channel: .stable, version: "0.5.0", artifact: Data("a".utf8))
        let currentEpoch = Int64(clock.now().timeIntervalSince1970)
        let payload = UpdateFeedPayload(
            generatedAtEpoch: currentEpoch - 60,
            expiresAtEpoch: currentEpoch + 900,
            releases: [release]
        )
        var configuration = fixture.configuration
        configuration.temporaryRoot = temporaryRoot
        let transport = FakeUpdateTransport([
            .data(try fixture.feed(payload), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: transport,
            artifactVerifier: FakeArtifactVerifier(),
            now: { clock.now() },
            monotonicNow: { clock.monotonicNow() }
        )

        _ = try await updater.check()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        var symlinkMetadata = stat()
        XCTAssertEqual(symlink.path.withCString { lstat($0, &symlinkMetadata) }, 0)
        XCTAssertEqual(symlinkMetadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: canary), Data("unchanged".utf8))
    }

    func testPostExtractionTreeBoundsCountSizeTotalAndSpecialFiles() throws {
        let fixture = try Fixture()
        let countRoot = fixture.root.appendingPathComponent("count/ICloudGuard.app", isDirectory: true)
        try FileManager.default.createDirectory(at: countRoot, withIntermediateDirectories: true)
        for index in 0..<MacOSReleaseArtifactVerifier.maximumArchiveEntries {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: countRoot.appendingPathComponent("file-\(index)").path,
                contents: Data()
            ))
        }
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.validateExtractedTree(countRoot))

        let sizeRoot = fixture.root.appendingPathComponent("size/ICloudGuard.app", isDirectory: true)
        try FileManager.default.createDirectory(at: sizeRoot, withIntermediateDirectories: true)
        let huge = sizeRoot.appendingPathComponent("huge")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let hugeFD = Darwin.open(huge.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(hugeFD, 0)
        defer { if hugeFD >= 0 { Darwin.close(hugeFD) } }
        XCTAssertEqual(Darwin.ftruncate(
            hugeFD,
            MacOSReleaseArtifactVerifier.maximumExpandedFileBytes + 1
        ), 0)
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.validateExtractedTree(sizeRoot))

        let totalRoot = fixture.root.appendingPathComponent("total/ICloudGuard.app", isDirectory: true)
        try FileManager.default.createDirectory(at: totalRoot, withIntermediateDirectories: true)
        for index in 0..<3 {
            let file = totalRoot.appendingPathComponent("sparse-\(index)")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
            let descriptor = Darwin.open(file.path, O_WRONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(Darwin.ftruncate(descriptor, 400 * 1024 * 1024), 0)
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.validateExtractedTree(totalRoot))

        let specialRoot = fixture.root.appendingPathComponent("special/ICloudGuard.app", isDirectory: true)
        try FileManager.default.createDirectory(at: specialRoot, withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.mkfifo(specialRoot.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try MacOSReleaseArtifactVerifier.validateExtractedTree(specialRoot))
    }

    func testOlderReleaseIsUpToDateAndStaleCandidateCannotBeDownloaded() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let fixture = try Fixture(clock: clock)
        let older = fixture.release(channel: .stable, version: "0.4.3", artifact: Data("old".utf8))
        let transport = FakeUpdateTransport([
            .data(try fixture.feed([older]), status: 200, finalURL: fixture.feedURL, redirects: [], reportedBytes: nil),
        ])
        let updater = try fixture.updater(transport: transport)
        let result = try await updater.check()
        XCTAssertEqual(result.availability, .upToDate(currentVersion: SemanticVersion("0.4.4")!))

        let availableFixture = try Fixture(clock: clock)
        let current = availableFixture.release(channel: .stable, version: "0.5.0", artifact: Data("new".utf8))
        let availableTransport = FakeUpdateTransport([
            .data(
                try availableFixture.feed([current]),
                status: 200,
                finalURL: availableFixture.feedURL,
                redirects: [],
                reportedBytes: nil
            ),
        ])
        let availableUpdater = try availableFixture.updater(transport: availableTransport)
        let available = try await availableUpdater.check()
        guard case .available(let candidate) = available.availability else {
            return XCTFail("Expected an available update.")
        }
        clock.advance(901)
        await XCTAssertThrowsUpdaterError(.candidateExpired) {
            _ = try await availableUpdater.download(candidate)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func updaterTemporaryDirectories(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix("icloud-guard-update-")
        }
    }
}

private final class Fixture {
    let root: URL
    let feedURL = URL(string: "https://updates.example.test/feed.json")!
    let keyID = "icloud-guard-release-1"
    let privateKey = P256.Signing.PrivateKey()
    let teamID = "ABCDE12345"
    let clock: LockedClock
    let channel: UpdateChannel

    init(channel: UpdateChannel = .stable, clock: LockedClock? = nil) throws {
        self.channel = channel
        self.clock = clock ?? LockedClock(Date(timeIntervalSince1970: 1_000))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var configuration: VerifiedUpdaterConfiguration {
        VerifiedUpdaterConfiguration(
            feedURL: feedURL,
            channel: channel,
            currentVersion: SemanticVersion("0.4.4")!,
            expectedKeyID: keyID,
            publicKeyX963: privateKey.publicKey.x963Representation,
            expectedTeamID: teamID,
            temporaryRoot: root,
            maximumFeedBytes: 64 * 1024,
            maximumArtifactBytes: 1024 * 1024,
            feedTimeout: 3,
            artifactTimeout: 5,
            cacheLifetime: 900,
            initialBackoff: 10,
            maximumBackoff: 40
        )
    }

    func updater(
        transport: any UpdateTransport,
        verifier: any ReleaseArtifactVerifying = FakeArtifactVerifier()
    ) throws -> VerifiedReleaseUpdater {
        let clock = clock
        return try VerifiedReleaseUpdater(
            configuration: configuration,
            transport: transport,
            artifactVerifier: verifier,
            now: { clock.now() },
            monotonicNow: { clock.monotonicNow() }
        )
    }

    func release(channel: UpdateChannel, version rawVersion: String, artifact: Data) -> UpdateRelease {
        let version = SemanticVersion(rawVersion)!
        let commit = String(repeating: "a", count: 40)
        let shortCommit = String(commit.prefix(12))
        let filename: String
        let tag: String
        let signingType: String
        let signingIdentity: String
        let releaseTeamID: String
        let notarized: Bool
        let stapled: Bool
        let provenance: UpdateProvenance
        switch channel {
        case .stable:
            filename = "ICloudGuard-\(version).zip"
            tag = "v\(version)"
            signingType = "developer-id"
            signingIdentity = "Developer ID Application: Example Corp (\(teamID))"
            releaseTeamID = teamID
            notarized = true
            stapled = true
            provenance = .trustedCI
        case .beta:
            filename = "ICloudGuard-beta-\(version).zip"
            tag = "beta-\(version)"
            signingType = "developer-id"
            signingIdentity = "Developer ID Application: Example Corp (\(teamID))"
            releaseTeamID = teamID
            notarized = true
            stapled = true
            provenance = .trustedCI
        case .tip:
            filename = "ICloudGuard-tip-\(version)-\(shortCommit).zip"
            tag = "tip-\(shortCommit)"
            signingType = "adhoc"
            signingIdentity = "-"
            releaseTeamID = ""
            notarized = false
            stapled = false
            provenance = .unauthenticatedTip
        }
        return UpdateRelease(
            channel: channel,
            version: version,
            tag: tag,
            commit: commit,
            artifactURL: feedURL.deletingLastPathComponent().appendingPathComponent(filename),
            artifactFilename: filename,
            artifactSHA256: SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined(),
            artifactSize: Int64(artifact.count),
            executableSHA256: String(repeating: "b", count: 64),
            executableUUID: "01234567-89AB-CDEF-0123-456789ABCDEF",
            signingIdentity: signingIdentity,
            signingType: signingType,
            teamID: releaseTeamID,
            notarized: notarized,
            stapled: stapled,
            buildToolchain: "Apple Swift 6",
            minimumMacOS: "15.0",
            sourceEpoch: 900,
            provenance: provenance
        )
    }

    func payload(_ releases: [UpdateRelease]) -> UpdateFeedPayload {
        UpdateFeedPayload(generatedAtEpoch: 900, expiresAtEpoch: 2_000, releases: releases)
    }

    func feed(_ releases: [UpdateRelease]) throws -> Data { try feed(payload(releases)) }

    func feed(_ payload: UpdateFeedPayload) throws -> Data {
        let canonical = try UpdateFeedCodec.canonicalPayloadData(payload)
        let signature = try privateKey.signature(for: canonical)
        return try UpdateFeedCodec.envelopeData(
            payload: payload,
            keyID: keyID,
            signatureDER: signature.derRepresentation
        )
    }
}

private actor FakeUpdateTransport: UpdateTransport {
    enum Behavior: Sendable {
        case data(Data, status: Int, finalURL: URL, redirects: [URL], reportedBytes: Int64?)
        case failure(UpdateTransportError)
        case waitForCancellation
        case returnAfterCancellation(Data, finalURL: URL)
    }

    struct Call: Sendable {
        var url: URL
        var timeout: TimeInterval
        var maximumBytes: Int64
    }

    private var behaviors: [Behavior]
    private var recordedCalls: [Call] = []

    init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

    func fetch(
        _ url: URL,
        to destination: URL,
        timeout: TimeInterval,
        maximumBytes: Int64
    ) async throws -> UpdateTransportResponse {
        recordedCalls.append(Call(url: url, timeout: timeout, maximumBytes: maximumBytes))
        guard !behaviors.isEmpty else { throw UpdateTransportError.requestFailed }
        let behavior = behaviors.removeFirst()
        switch behavior {
        case .failure(let error):
            throw error
        case .waitForCancellation:
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
            throw CancellationError()
        case .returnAfterCancellation(let data, let finalURL):
            while !Task.isCancelled { await Task.yield() }
            try data.write(to: destination, options: [.atomic])
            guard chmod(destination.path, 0o600) == 0 else { throw UpdateTransportError.destinationRejected }
            return UpdateTransportResponse(
                statusCode: 200,
                finalURL: finalURL,
                bytesWritten: Int64(data.count)
            )
        case .data(let data, let status, let finalURL, let redirects, let reportedBytes):
            guard Int64(data.count) <= maximumBytes else { throw UpdateTransportError.responseTooLarge }
            try data.write(to: destination, options: [.atomic])
            guard chmod(destination.path, 0o600) == 0 else { throw UpdateTransportError.destinationRejected }
            return UpdateTransportResponse(
                statusCode: status,
                finalURL: finalURL,
                redirects: redirects,
                bytesWritten: reportedBytes ?? Int64(data.count)
            )
        }
    }

    func callCount() -> Int { recordedCalls.count }
    func calls() -> [Call] { recordedCalls }

    func waitForCalls(_ count: Int) async {
        while recordedCalls.count < count { await Task.yield() }
    }
}

private actor PausingUpdateTransport: UpdateTransport {
    private let data: Data
    private let finalURL: URL
    private var started = false
    private var released = false

    init(data: Data, finalURL: URL) {
        self.data = data
        self.finalURL = finalURL
    }

    func fetch(
        _ url: URL,
        to destination: URL,
        timeout: TimeInterval,
        maximumBytes: Int64
    ) async throws -> UpdateTransportResponse {
        started = true
        while !released {
            try Task.checkCancellation()
            await Task.yield()
        }
        guard Int64(data.count) <= maximumBytes else { throw UpdateTransportError.responseTooLarge }
        try data.write(to: destination, options: [.atomic])
        guard chmod(destination.path, 0o600) == 0 else {
            throw UpdateTransportError.destinationRejected
        }
        return UpdateTransportResponse(
            statusCode: 200,
            finalURL: finalURL,
            bytesWritten: Int64(data.count)
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() { released = true }
}

private actor FakeArtifactVerifier: ReleaseArtifactVerifying {
    private let fails: Bool
    private var recorded: [UpdateRelease] = []

    init(fails: Bool = false) { self.fails = fails }

    func verify(artifactURL: URL, release: UpdateRelease) async throws {
        recorded.append(release)
        guard FileManager.default.fileExists(atPath: artifactURL.path), !fails else {
            throw UpdaterError.artifactVerificationFailed
        }
    }

    func callCount() -> Int { recorded.count }
}

private struct MutatingArtifactVerifier: ReleaseArtifactVerifying {
    func verify(artifactURL: URL, release: UpdateRelease) async throws {
        try Data("changed".utf8).write(to: artifactURL)
        guard chmod(artifactURL.path, 0o600) == 0 else { throw UpdateTransportError.destinationRejected }
    }
}

private struct RawZipEntry {
    var path: String
    var mode: UInt32
    var payload: Data = Data()
    var compressedSize: UInt32?
    var uncompressedSize: UInt32?
}

private func writeRawZip(entries requestedEntries: [RawZipEntry], to url: URL) throws {
    let root = RawZipEntry(path: "ICloudGuard.app/", mode: UInt32(S_IFDIR | 0o755))
    let entries = [root] + requestedEntries
    var archive = Data()
    var central = Data()
    var offsets: [UInt32] = []
    for entry in entries {
        offsets.append(UInt32(archive.count))
        let name = Data(entry.path.utf8)
        let compressed = entry.compressedSize ?? UInt32(entry.payload.count)
        let uncompressed = entry.uncompressedSize ?? UInt32(entry.payload.count)
        appendLittleEndian(UInt32(0x04034b50), to: &archive)
        appendLittleEndian(UInt16(20), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        appendLittleEndian(UInt32(0), to: &archive)
        appendLittleEndian(compressed, to: &archive)
        appendLittleEndian(uncompressed, to: &archive)
        appendLittleEndian(UInt16(name.count), to: &archive)
        appendLittleEndian(UInt16(0), to: &archive)
        archive.append(name)
        archive.append(entry.payload)
    }
    let centralOffset = UInt32(archive.count)
    for (entry, offset) in zip(entries, offsets) {
        let name = Data(entry.path.utf8)
        let compressed = entry.compressedSize ?? UInt32(entry.payload.count)
        let uncompressed = entry.uncompressedSize ?? UInt32(entry.payload.count)
        appendLittleEndian(UInt32(0x02014b50), to: &central)
        appendLittleEndian(UInt16(0x0314), to: &central)
        appendLittleEndian(UInt16(20), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt32(0), to: &central)
        appendLittleEndian(compressed, to: &central)
        appendLittleEndian(uncompressed, to: &central)
        appendLittleEndian(UInt16(name.count), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(UInt16(0), to: &central)
        appendLittleEndian(entry.mode << 16, to: &central)
        appendLittleEndian(offset, to: &central)
        central.append(name)
    }
    archive.append(central)
    appendLittleEndian(UInt32(0x06054b50), to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    appendLittleEndian(UInt16(entries.count), to: &archive)
    appendLittleEndian(UInt16(entries.count), to: &archive)
    appendLittleEndian(UInt32(central.count), to: &archive)
    appendLittleEndian(centralOffset, to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    try archive.write(to: url, options: [.atomic])
    guard chmod(url.path, 0o600) == 0 else { throw UpdateTransportError.destinationRejected }
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var monotonicValue: TimeInterval = 0

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func monotonicNow() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return monotonicValue
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        monotonicValue += seconds
        lock.unlock()
    }

    func advanceMonotonic(_ seconds: TimeInterval) {
        lock.lock()
        monotonicValue += seconds
        lock.unlock()
    }

    func advanceWall(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }

    func rewindWall(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(-seconds)
        lock.unlock()
    }
}

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    func set(_ value: pid_t) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class FailingContinuityStore: UpdateContinuityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = UpdateContinuityState()
    private var failsSave = true

    func update(
        _ body: @Sendable (UpdateContinuityState) throws -> UpdateContinuityState
    ) throws -> UpdateContinuityState {
        lock.lock()
        defer { lock.unlock() }
        let next = try body(state)
        if failsSave { throw UpdaterError.releaseMetadataRejected }
        state = next
        return next
    }

    func allowSaves() {
        lock.lock()
        failsSave = false
        lock.unlock()
    }

    func snapshot() -> UpdateContinuityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

private func XCTAssertThrowsUpdaterError<T>(
    _ expected: UpdaterError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as UpdaterError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(type(of: error)).", file: file, line: line)
    }
}
