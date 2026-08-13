import Foundation
import IOKit.ps

public enum EnergyThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum EnergyPowerSource: String, Codable, Equatable, Sendable {
    case ac
    case battery
    case ups
}

/// A `nil` reading means that the native signal was unavailable. Unavailable
/// readings never cause work to be deferred.
public struct EnergySchedulingSignals: Codable, Equatable, Sendable {
    public var lowPowerModeEnabled: Bool?
    public var thermalState: EnergyThermalState?
    public var powerSource: EnergyPowerSource?

    public init(
        lowPowerModeEnabled: Bool?,
        thermalState: EnergyThermalState?,
        powerSource: EnergyPowerSource?
    ) {
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.powerSource = powerSource
    }
}

public enum EnergySchedulingIntent: String, Codable, Equatable, Sendable {
    case scheduled
    case manual
    case panic
    case safetyReconciliation = "safety-reconciliation"
}

public struct EnergySchedulingPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var deferOnLowPowerMode: Bool
    public var deferOnSeriousThermalState: Bool
    public var deferOnBatteryPower: Bool

    public init(
        enabled: Bool = true,
        deferOnLowPowerMode: Bool = true,
        deferOnSeriousThermalState: Bool = true,
        deferOnBatteryPower: Bool = true
    ) {
        self.enabled = enabled
        self.deferOnLowPowerMode = deferOnLowPowerMode
        self.deferOnSeriousThermalState = deferOnSeriousThermalState
        self.deferOnBatteryPower = deferOnBatteryPower
    }
}

public enum EnergySchedulingStatus: String, Codable, Equatable, Sendable {
    case run
    case deferred
}

public enum EnergySchedulingReason: String, Codable, Equatable, Sendable {
    case manualRequest = "manual-request"
    case panicRequest = "panic-request"
    case safetyReconciliation = "safety-reconciliation"
    case policyDisabled = "policy-disabled"
    case lowPowerMode = "low-power-mode"
    case seriousThermalState = "serious-thermal-state"
    case criticalThermalState = "critical-thermal-state"
    case batteryPower = "battery-power"
    case signalsUnavailable = "signals-unavailable"
    case signalsPartiallyUnavailable = "signals-partially-unavailable"
    case conditionsSuitable = "conditions-suitable"
}

public struct EnergySchedulingDecision: Codable, Equatable, Sendable {
    public var status: EnergySchedulingStatus
    public var reason: EnergySchedulingReason

    public init(status: EnergySchedulingStatus, reason: EnergySchedulingReason) {
        self.status = status
        self.reason = reason
    }

    public var shouldRun: Bool { status == .run }
}

/// Makes a bounded, synchronous scheduling decision from one signal snapshot.
/// The injected provider keeps policy tests hermetic and lets app integration
/// substitute another native reader without changing the decision logic.
public struct EnergyAwareScheduler: Sendable {
    public let policy: EnergySchedulingPolicy
    private let signalProvider: @Sendable () -> EnergySchedulingSignals

    public init(
        policy: EnergySchedulingPolicy = .init(),
        signalProvider: @escaping @Sendable () -> EnergySchedulingSignals = {
            NativeEnergySignals.current()
        }
    ) {
        self.policy = policy
        self.signalProvider = signalProvider
    }

    public func decision(for intent: EnergySchedulingIntent) -> EnergySchedulingDecision {
        switch intent {
        case .manual:
            return .init(status: .run, reason: .manualRequest)
        case .panic:
            return .init(status: .run, reason: .panicRequest)
        case .safetyReconciliation:
            return .init(status: .run, reason: .safetyReconciliation)
        case .scheduled:
            break
        }

        guard policy.enabled else {
            return .init(status: .run, reason: .policyDisabled)
        }

        let signals = signalProvider()
        if policy.deferOnSeriousThermalState {
            switch signals.thermalState {
            case .critical?:
                return .init(status: .deferred, reason: .criticalThermalState)
            case .serious?:
                return .init(status: .deferred, reason: .seriousThermalState)
            default:
                break
            }
        }
        if policy.deferOnLowPowerMode, signals.lowPowerModeEnabled == true {
            return .init(status: .deferred, reason: .lowPowerMode)
        }
        if policy.deferOnBatteryPower, signals.powerSource == .battery {
            return .init(status: .deferred, reason: .batteryPower)
        }

        let requiredReadings: [Bool] = [
            !policy.deferOnLowPowerMode || signals.lowPowerModeEnabled != nil,
            !policy.deferOnSeriousThermalState || signals.thermalState != nil,
            !policy.deferOnBatteryPower || signals.powerSource != nil,
        ]
        let unavailableCount = requiredReadings.filter { !$0 }.count
        let enabledReadingCount = [
            policy.deferOnLowPowerMode,
            policy.deferOnSeriousThermalState,
            policy.deferOnBatteryPower,
        ].filter { $0 }.count
        let reason: EnergySchedulingReason
        if enabledReadingCount > 0, unavailableCount == enabledReadingCount {
            reason = .signalsUnavailable
        } else if unavailableCount > 0 {
            reason = .signalsPartiallyUnavailable
        } else {
            reason = .conditionsSuitable
        }
        return .init(status: .run, reason: reason)
    }
}

public enum NativeEnergySignals {
    public static func current() -> EnergySchedulingSignals {
        EnergySchedulingSignals(
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalState(ProcessInfo.processInfo.thermalState),
            powerSource: powerSource()
        )
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> EnergyThermalState? {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    private static func powerSource() -> EnergyPowerSource? {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let value = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return nil
        }
        switch value {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return nil
        }
    }
}
