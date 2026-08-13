import Foundation

/// Structured terminal result for the app-to-CLI protocol. Optional fields
/// preserve compatibility with older peers that only send text and an exit code.
public struct IPCCommandResult: Codable, Equatable, Sendable {
    public var output: String
    public var exitCode: Int
    public var runID: String?
    public var receipt: GuardRunReceipt?
    public var telemetry: GuardRunTelemetry?

    public init(
        output: String,
        exitCode: Int,
        runID: String? = nil,
        receipt: GuardRunReceipt? = nil,
        telemetry: GuardRunTelemetry? = nil
    ) {
        self.output = output
        self.exitCode = exitCode
        self.runID = runID
        self.receipt = receipt
        self.telemetry = telemetry
    }
}
