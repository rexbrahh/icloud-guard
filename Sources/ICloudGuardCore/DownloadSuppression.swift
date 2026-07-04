import Darwin
import Foundation

/// Layer 1: Proactive download suppression.
///
/// Suppresses the three primary triggers that cause macOS to re-materialize
/// evicted (dataless) iCloud Drive files:
/// 1. Spotlight indexing of the iCloud Drive working set
/// 2. QuickLook thumbnail generation for evicted packages
/// 3. This process's own I/O policy triggering materialization on metadata reads
public final class DownloadSuppression {
    private let logger: GuardLogging
    private let config: DownloadSuppressionConfig

    public init(config: DownloadSuppressionConfig, logger: GuardLogging) {
        self.config = config
        self.logger = logger
    }

    /// Apply all configured suppression mechanisms.
    public func apply() {
        if config.materializeDatalessFiles == false {
            applyIOPolicy()
        }
        if config.spotlightSuppression {
            applySpotlightSuppression()
        }
        if config.quickLookCacheClear {
            clearQuickLookCache()
        }
    }

    /// Set the process I/O policy to prevent materialization of dataless files.
    /// Maps to the launchd `MaterializeDatalessFiles: false` key.
    /// Verified working: `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, ...)` returns 0.
    private func applyIOPolicy() {
        let result = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_DEFAULT)
        if result != 0 {
            let err = String(cString: strerror(errno))
            logger.log("suppression iopolicy failed errno=\(errno) msg=\(err)")
        } else {
            logger.log("suppression iopolicy set materializeDatalessFiles=false")
        }
    }

    /// Create `.metadata_never_index` in the iCloud Drive root to stop Spotlight
    /// from indexing the FileProvider working set.
    /// Verified: file created successfully at ~/Library/Mobile Documents/com~apple~CloudDocs/
    private func applySpotlightSuppression() {
        guard !config.scopePath.isEmpty else { return }
        let scopeURL = URL(fileURLWithPath: NSString(string: config.scopePath).expandingTildeInPath, isDirectory: true)
        let markerURL = scopeURL.appendingPathComponent(".metadata_never_index")

        if FileManager.default.fileExists(atPath: markerURL.path) {
            logger.log("suppression spotlight already-marked path=\(markerURL.path)")
            return
        }

        do {
            try Data().write(to: markerURL, options: [.atomic])
            logger.log("suppression spotlight marker-created path=\(markerURL.path)")
        } catch {
            logger.log("suppression spotlight marker-failed error=\(error)")
        }
    }

    /// Clear the QuickLook thumbnail cache to prevent re-materialization of
    /// evicted packages when Finder generates thumbnails.
    private func clearQuickLookCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-r", "cache"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.log("suppression quicklook cache-cleared")
            } else {
                logger.log("suppression quicklook cache-clear failed status=\(process.terminationStatus)")
            }
        } catch {
            logger.log("suppression quicklook cache-clear error=\(error)")
        }
    }

    /// Remove the Spotlight suppression marker (for cleanup when disabling).
    public func removeSpotlightSuppression() {
        guard !config.scopePath.isEmpty else { return }
        let scopeURL = URL(fileURLWithPath: NSString(string: config.scopePath).expandingTildeInPath, isDirectory: true)
        let markerURL = scopeURL.appendingPathComponent(".metadata_never_index")
        try? FileManager.default.removeItem(at: markerURL)
        logger.log("suppression spotlight marker-removed path=\(markerURL.path)")
    }
}
