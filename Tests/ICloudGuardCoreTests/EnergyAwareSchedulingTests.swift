import XCTest
@testable import ICloudGuardCore

final class EnergyAwareSchedulingTests: XCTestCase {
    func testOnlyScheduledNonpanicWorkCanBeDeferred() {
        let providerCalls = LockedCounter()
        let scheduler = EnergyAwareScheduler(signalProvider: {
            providerCalls.increment()
            return .init(lowPowerModeEnabled: true, thermalState: .critical, powerSource: .battery)
        })

        XCTAssertEqual(scheduler.decision(for: .manual), .init(status: .run, reason: .manualRequest))
        XCTAssertEqual(scheduler.decision(for: .panic), .init(status: .run, reason: .panicRequest))
        XCTAssertEqual(
            scheduler.decision(for: .safetyReconciliation),
            .init(status: .run, reason: .safetyReconciliation)
        )
        XCTAssertEqual(providerCalls.value, 0, "exempt work must not even read energy signals")
        XCTAssertEqual(
            scheduler.decision(for: .scheduled),
            .init(status: .deferred, reason: .criticalThermalState)
        )
        XCTAssertEqual(providerCalls.value, 1)
    }

    func testScheduledWorkDefersForEachConfiguredAdverseCondition() {
        XCTAssertEqual(
            scheduler(.init(lowPowerModeEnabled: true, thermalState: .nominal, powerSource: .ac))
                .decision(for: .scheduled),
            .init(status: .deferred, reason: .lowPowerMode)
        )
        XCTAssertEqual(
            scheduler(.init(lowPowerModeEnabled: false, thermalState: .serious, powerSource: .ac))
                .decision(for: .scheduled),
            .init(status: .deferred, reason: .seriousThermalState)
        )
        XCTAssertEqual(
            scheduler(.init(lowPowerModeEnabled: false, thermalState: .nominal, powerSource: .battery))
                .decision(for: .scheduled),
            .init(status: .deferred, reason: .batteryPower)
        )
    }

    func testNominalFairACAndUPSSignalsRunScheduledWork() {
        for signals in [
            EnergySchedulingSignals(lowPowerModeEnabled: false, thermalState: .nominal, powerSource: .ac),
            EnergySchedulingSignals(lowPowerModeEnabled: false, thermalState: .fair, powerSource: .ups),
        ] {
            let decision = scheduler(signals).decision(for: .scheduled)
            XCTAssertTrue(decision.shouldRun)
            XCTAssertEqual(decision.reason, .conditionsSuitable)
        }
    }

    func testUnavailableSignalsFailOpenWithTruthfulTypedReason() {
        XCTAssertEqual(
            scheduler(.init(lowPowerModeEnabled: nil, thermalState: nil, powerSource: nil))
                .decision(for: .scheduled),
            .init(status: .run, reason: .signalsUnavailable)
        )
        XCTAssertEqual(
            scheduler(.init(lowPowerModeEnabled: false, thermalState: nil, powerSource: .ac))
                .decision(for: .scheduled),
            .init(status: .run, reason: .signalsPartiallyUnavailable)
        )
    }

    func testDisabledPolicyDoesNotReadSignalsAndIndividualControlsAreHonored() {
        let disabledCalls = LockedCounter()
        let disabled = EnergyAwareScheduler(policy: .init(enabled: false), signalProvider: {
            disabledCalls.increment()
            return .init(lowPowerModeEnabled: true, thermalState: .critical, powerSource: .battery)
        })
        XCTAssertEqual(
            disabled.decision(for: .scheduled),
            .init(status: .run, reason: .policyDisabled)
        )
        XCTAssertEqual(disabledCalls.value, 0)

        let ignored = EnergyAwareScheduler(
            policy: .init(
                deferOnLowPowerMode: false,
                deferOnSeriousThermalState: false,
                deferOnBatteryPower: false
            ),
            signalProvider: {
                .init(lowPowerModeEnabled: true, thermalState: .critical, powerSource: .battery)
            }
        )
        XCTAssertEqual(
            ignored.decision(for: .scheduled),
            .init(status: .run, reason: .conditionsSuitable)
        )
    }

    private func scheduler(_ signals: EnergySchedulingSignals) -> EnergyAwareScheduler {
        EnergyAwareScheduler(signalProvider: { signals })
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
