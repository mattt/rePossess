import Foundation
import Testing

@testable import RePossessAppCore
@testable import RePossessCloud
@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

func temporaryLibrary(_ name: String = "app") throws -> Library {
    try Library(root: FileManager.default.temporaryDirectory.appending(path: "repossess-\(name)-\(UUID().uuidString)"))
}

/// A refresh that waits until the test lets it finish, and counts its calls.
final class GatedRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [RefreshSource] = []
    private var gates: [CheckedContinuation<Void, Never>] = []

    var sources: [RefreshSource] { lock.withLock { calls } }
    var waiting: Int { lock.withLock { gates.count } }

    func refresh(_ source: RefreshSource) async -> [RefreshReport] {
        lock.withLock { calls.append(source) }
        await withCheckedContinuation { continuation in lock.withLock { gates.append(continuation) } }
        return [RefreshReport(source: source == .cloud ? .cloud : .usb)]
    }

    func open() {
        let pending = lock.withLock {
            defer { gates.removeAll() }
            return gates
        }
        pending.forEach { $0.resume() }
    }
}

@Suite struct ScheduleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theDefaultIsFifteenMinutes() {
        let schedule = RefreshSchedule()
        #expect(schedule.intervalMinutes == 15 && schedule.interval == 900)
        #expect(schedule.nextDate(after: nil, failures: 0, now: start) == start)
        #expect(schedule.nextDate(after: start, failures: 0, now: start) == start.addingTimeInterval(900))
    }

    @Test func failuresDoubleTheWaitUpToEightTimes() {
        let schedule = RefreshSchedule(intervalMinutes: 15)
        let waits = (0 ... 5).map {
            schedule.nextDate(after: start, failures: $0, now: start)!.timeIntervalSince(start)
        }
        #expect(waits == [900, 1800, 3600, 7200, 7200, 7200])
    }

    @Test func aLongIntervalIsNotCutAndBackoffStopsAtSixHours() {
        let daily = RefreshSchedule(intervalMinutes: 1440)
        #expect(daily.nextDate(after: start, failures: 3, now: start)!.timeIntervalSince(start) == 86400)
        let hourly = RefreshSchedule(intervalMinutes: 60)
        #expect(hourly.nextDate(after: start, failures: 3, now: start)!.timeIntervalSince(start) == 6 * 3600)
    }

    @Test func zeroTurnsTheScheduleOffAndShortIntervalsAreRaised() {
        #expect(RefreshSchedule(intervalMinutes: 0).nextDate(after: nil, failures: 0, now: start) == nil)
        #expect(RefreshSchedule(intervalMinutes: 1).interval == 300)
        #expect(RefreshSchedule.label(minutes: 0) == "Only when the tablet connects or on request")
        #expect(RefreshSchedule.label(minutes: 120) == "Every 2 hours")
        #expect(RefreshSchedule.label(minutes: 15) == "Every 15 minutes")
    }

    @Test func usbAppearsOnceForEachConnection() {
        var usb = USBAppearance()
        #expect(usb.update(present: false) == false)
        #expect(usb.update(present: true) == true)
        #expect(usb.update(present: true) == false)
        #expect(usb.update(present: false) == false)
        #expect(usb.update(present: true) == true)
        var connectedAtLaunch = USBAppearance()
        #expect(connectedAtLaunch.update(present: true) == true)
    }

    @Test func eachTriggerChoosesItsSource() {
        let both = RefreshPaths(usbPresent: true, paired: true)
        #expect(both.source(for: .usbAppeared) == .usb)
        #expect(both.source(for: .schedule) == .auto && both.source(for: .manual) == .auto)
        let usbOnly = RefreshPaths(usbPresent: true, paired: false)
        #expect(usbOnly.source(for: .schedule) == .usb && usbOnly.source(for: .manual) == .usb)
        let cloudOnly = RefreshPaths(usbPresent: false, paired: true)
        #expect(cloudOnly.source(for: .schedule) == .cloud && cloudOnly.source(for: .usbAppeared) == nil)
        #expect(RefreshPaths(usbPresent: false, paired: false).source(for: .manual) == nil)
    }
}

@Suite struct CoordinatorTests {
    @Test func neverRunsTwoRefreshesAtOnce() async throws {
        let gate = GatedRefresh()
        let coordinator = RefreshCoordinator(
            paths: { RefreshPaths(usbPresent: true, paired: true) },
            refresh: { await gate.refresh($0) }
        )
        let first = Task { await coordinator.run(.schedule) }
        while gate.waiting == 0 { await Task.yield() }
        #expect(await coordinator.isRunning)
        let second = await coordinator.run(.usbAppeared)
        #expect(second.result == .alreadyRunning && !second.isFailure)
        gate.open()
        let outcome = await first.value
        #expect(gate.sources == [.auto])
        guard case .finished(let reports) = outcome.result else {
            Issue.record("not finished")
            return
        }
        #expect(reports.count == 1 && !outcome.isFailure && outcome.mayHaveChangedTheMirror)
        #expect(await !coordinator.isRunning)
    }

    @Test func anotherProcessHoldingTheLockIsNotAFailure() async throws {
        let library = try temporaryLibrary("lock")
        // A second Library on the same folder takes the lock on its own file descriptor,
        // as `repossess` in another process does.
        let other = try Library(root: library.root)
        let coordinator = RefreshCoordinator(
            paths: { RefreshPaths(usbPresent: true, paired: false) },
            refresh: RefreshCoordinator.libraryRefresh(
                library: library,
                session: CloudSession(transport: FakeCloud(), deviceToken: { FakeCloud.deviceToken }),
                paired: { false },
                usbPresent: { true },
                usb: { USBClient(transport: FakeTablet(), checkInterface: { true }) }
            )
        )
        let outcome = try await other.withRefreshLock { await coordinator.run(.manual) }
        #expect(outcome.result == .busyElsewhere && !outcome.isFailure && !outcome.mayHaveChangedTheMirror)
    }

    @Test func withoutAPathNothingRuns() async {
        let gate = GatedRefresh()
        let coordinator = RefreshCoordinator(
            paths: { RefreshPaths(usbPresent: false, paired: false) },
            refresh: { await gate.refresh($0) }
        )
        let outcome = await coordinator.run(.manual)
        #expect(outcome.result == .noPath && gate.sources.isEmpty)
        #expect(outcome.summary.contains("not on USB, and rePossess is not paired"))
    }

    @Test func anErrorIsAFailureForTheBackoff() async {
        struct Broken: Error, CustomStringConvertible { var description: String { "invented failure" } }
        let coordinator = RefreshCoordinator(
            paths: { RefreshPaths(usbPresent: false, paired: true) },
            refresh: { _ in throw Broken() }
        )
        let outcome = await coordinator.run(.schedule)
        #expect(outcome.result == .failed("invented failure") && outcome.isFailure)
    }

    @Test func theTabletConnectingSendsTheQueueOverUSB() async throws {
        let library = try temporaryLibrary("usb")
        let tablet = FakeTablet()
        let record = try library.enqueuePush(
            kind: .pdf,
            title: "rePossess test invented PDF",
            data: Data("%PDF-1.4\n%invented\n".utf8)
        )
        let cloud = FakeCloud()
        let coordinator = RefreshCoordinator(
            paths: { RefreshPaths(usbPresent: true, paired: false) },
            refresh: RefreshCoordinator.libraryRefresh(
                library: library,
                session: CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }),
                paired: { false },
                usbPresent: { true },
                usb: { USBClient(transport: tablet, checkInterface: { true }) }
            )
        )
        let outcome = await coordinator.run(.usbAppeared)
        guard case .finished(let reports) = outcome.result else {
            Issue.record("not finished: \(outcome.result)")
            return
        }
        #expect(reports.map(\.source) == [.usb])
        #expect(reports.last?.pushes.map(\.id) == [record.id])
        #expect(try library.push(id: record.id)?.status == .sent)
        #expect(await tablet.uploads.count == 1)
        #expect(await cloud.requests.isEmpty)
        #expect(outcome.summary.contains("1 of 1 pushes sent"))
    }
}
