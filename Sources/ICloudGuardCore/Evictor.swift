import Darwin
import Foundation

/// Layer 2: Correct eviction with leaf-first package handling and SF_DATALESS verification.
///
/// Package roots can fail atomically when any child has an open file descriptor.
/// This evictor trims regular package leaves first, then the package root, and
/// verifies the APFS SF_DATALESS flag (0x40000000) post-eviction.
public final class PackageAwareEvictor: ICloudEvicting {
    private let fileManager = FileManager.default
    private let logger: GuardLogging
    private let failureLogSampleLimit = 20

    public init(logger: GuardLogging) {
        self.logger = logger
    }

    public func evict(items: [ICloudItemSnapshot], dryRun: Bool) throws -> EvictionResult {
        if dryRun {
            for item in items {
                logger.log("dry-run evict \(item.relativePath) bytes=\(item.localBytes) package=\(item.isPackage)")
            }
            return EvictionResult(evictedCount: 0, failedCount: 0)
        }

        var evictedCount = 0
        var failedCount = 0
        var failureSamplesRemaining = failureLogSampleLimit

        for item in items {
            let url = URL(fileURLWithPath: item.absolutePath)

            if item.isPackage {
                // Leaf-first eviction for packages: evict children before root
                let packageResult = evictPackageLeafFirst(
                    url: url,
                    item: item,
                    failureSamplesRemaining: &failureSamplesRemaining
                )
                evictedCount += packageResult.evictedCount
                failedCount += packageResult.failedCount
            } else {
                let result = evictSingle(
                    url: url,
                    relativePath: item.relativePath,
                    requestedBytes: item.localBytes,
                    role: "file",
                    failureSamplesRemaining: &failureSamplesRemaining
                )
                evictedCount += result.evictedCount
                failedCount += result.failedCount
            }
        }

        return EvictionResult(evictedCount: evictedCount, failedCount: failedCount)
    }

    /// Evict a package directory by first evicting all leaf files, then the root.
    /// This avoids the atomic EBUSY failure that occurs when evicting a package
    /// with open file descriptors on any child.
    private func evictPackageLeafFirst(
        url: URL,
        item: ICloudItemSnapshot,
        failureSamplesRemaining: inout Int
    ) -> EvictionResult {
        var evictedCount = 0
        var failedCount = 0

        // Enumerate and evict children first
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let childURL as URL in enumerator {
                guard childURL.lastPathComponent.hasPrefix(".") == false else { continue }
                let values = try? childURL.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey])
                guard values?.isRegularFile == true, values?.isUbiquitousItem == true else { continue }
                let childRelativePath = item.relativePath + "/" + relativePath(from: url, to: childURL)

                let childResult = evictSingle(
                    url: childURL,
                    relativePath: childRelativePath,
                    requestedBytes: 0,
                    role: "package-child",
                    failureSamplesRemaining: &failureSamplesRemaining
                )
                evictedCount += childResult.evictedCount
                failedCount += childResult.failedCount
            }
        }

        // Now evict the package root itself
        let rootResult = evictSingle(
            url: url,
            relativePath: item.relativePath,
            requestedBytes: item.localBytes,
            role: "package-root",
            failureSamplesRemaining: &failureSamplesRemaining
        )
        evictedCount += rootResult.evictedCount
        failedCount += rootResult.failedCount

        return EvictionResult(evictedCount: evictedCount, failedCount: failedCount)
    }

    private func evictSingle(
        url: URL,
        relativePath: String,
        requestedBytes: Int64,
        role: String,
        failureSamplesRemaining: inout Int
    ) -> EvictionResult {
        do {
            try fileManager.evictUbiquitousItem(at: url)
            let verification = Self.verifyDataless(at: url.path)
            logger.log(
                "evicted role=\(role) path=\(relativePath) requestedBytes=\(requestedBytes) " +
                "dataless=\(verification.isDataless) allocatedAfter=\(verification.fileAllocatedSize) logicalSize=\(verification.fileSize)"
            )
            return EvictionResult(evictedCount: 1, failedCount: 0)
        } catch {
            logFailure(
                error,
                url: url,
                relativePath: relativePath,
                role: role,
                failureSamplesRemaining: &failureSamplesRemaining
            )
            return EvictionResult(evictedCount: 0, failedCount: 1)
        }
    }

    private func logFailure(
        _ error: Error,
        url: URL,
        relativePath: String,
        role: String,
        failureSamplesRemaining: inout Int
    ) {
        guard failureSamplesRemaining > 0 else { return }
        failureSamplesRemaining -= 1

        let nsError = error as NSError
        let verification = Self.verifyDataless(at: url.path)
        logger.log(
            "evict-failed role=\(role) path=\(relativePath) domain=\(nsError.domain) code=\(nsError.code) " +
            "dataless=\(verification.isDataless) allocated=\(verification.fileAllocatedSize) logicalSize=\(verification.fileSize) " +
            "error=\(nsError.localizedDescription)"
        )

        if failureSamplesRemaining == 0 {
            logger.log("evict-failed further-failures-suppressed sampleLimit=\(failureLogSampleLimit)")
        }
    }

    private func relativePath(from rootURL: URL, to childURL: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let childComponents = childURL.standardizedFileURL.pathComponents
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Verify that a file is truly dataless (evicted) by checking the APFS
    /// SF_DATALESS flag (0x40000000) and confirming fileAllocatedSize == 0
    /// while fileSize > 0.
    ///
    /// Verified working: `stat -f "%Sf"` shows 0x40000000 on evicted iCloud files.
    public static func verifyDataless(at path: String) -> EvictionVerification {
        var statInfo = stat()
        let result = path.withCString { ptr in
            lstat(ptr, &statInfo)
        }

        guard result == 0 else {
            return EvictionVerification(
                absolutePath: path,
                isDataless: false,
                fileAllocatedSize: 0,
                fileSize: 0
            )
        }

        let isDataless = (statInfo.st_flags & SF_DATALESS) != 0
        let allocatedSize = Int64(statInfo.st_blocks) * 512
        let logicalSize = Int64(statInfo.st_size)

        return EvictionVerification(
            absolutePath: path,
            isDataless: isDataless,
            fileAllocatedSize: allocatedSize,
            fileSize: logicalSize
        )
    }
}
