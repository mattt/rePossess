import Foundation
import RePossessCloud
import RePossessLibrary
import RePossessUSB

/// Refreshes the library from a source.
///
/// `auto` uses USB when the tablet's USB network is present.
/// If the USB refresh fails or stops early, for any reason, it says so and refreshes from the cloud,
/// so that one call still brings the mirror up to date when the tablet sleeps or the cable moves.
///
/// After the refresh, it sends the pushes that wait in the queue, by the paths that `pushes` allows,
/// leaving out USB when the USB refresh did not finish. The last report lists them.
/// - Parameters:
///   - usb: Makes a USB client; each refresh gets a new one, which stops after its first timeout.
///   - usbPresent: Whether the Mac is on the tablet's USB network.
///   - usbByApp: Does the USB step in rePossess.app, or returns `nil` when the app is not running;
///     see ``AppLink/refreshUSB(library:timeout:progress:)``. The app also sends the queue,
///     so this process then sends it only through the cloud.
public func refreshLibrary(
    _ library: Library,
    _ source: RefreshSource,
    session: CloudSession,
    usb: @escaping @Sendable () -> USBClient = { USBClient() },
    usbPresent: @Sendable () -> Bool = USBNetwork.isPresent,
    usbByApp: (@Sendable () async throws -> RefreshReport?)? = nil,
    pushes: PushPaths? = nil,
    progress: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> [RefreshReport] {
    let usbStep: @Sendable () async throws -> RefreshReport = {
        if let usbByApp, let report = try await usbByApp() { return report }
        return try await library.refreshUSB(client: usb(), progress: progress)
    }
    var reports = try await refreshOnly(
        library,
        source,
        session: session,
        usbStep: usbStep,
        usbPresent: usbPresent,
        progress: progress
    )
    if var paths = pushes, !reports.isEmpty {
        if reports.contains(where: { $0.source == .usb && ($0.stoppedBy != nil || $0.byApp) }) { paths.usb = nil }
        do {
            reports[reports.count - 1].pushes = try await library.sendPushes(paths: paths, progress: progress)
        } catch {
            progress("The queued pushes were not sent: \(error)")
        }
    }
    return reports
}

private func refreshOnly(
    _ library: Library,
    _ source: RefreshSource,
    session: CloudSession,
    usbStep: @Sendable () async throws -> RefreshReport,
    usbPresent: @Sendable () -> Bool,
    progress: @escaping @Sendable (String) -> Void
) async throws -> [RefreshReport] {
    switch source {
    case .usb:
        return [try await usbStep()]
    case .cloud:
        return [try await library.refreshCloud(session: session, progress: progress)]
    case .auto:
        var reports: [RefreshReport] = []
        if usbPresent() {
            do {
                let report = try await usbStep()
                if report.stoppedBy == nil { return [report] }
                reports.append(report)
            } catch let error as RefreshError {
                throw error
            } catch {
                var failed = RefreshReport(source: .usb)
                failed.stoppedBy = "\(error)"
                reports.append(failed)
            }
            progress("USB did not finish; refreshing from the cloud.")
        }
        reports.append(try await library.refreshCloud(session: session, progress: progress))
        return reports
    }
}
