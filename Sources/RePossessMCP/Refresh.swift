import Foundation
import RePossessCloud
import RePossessLibrary
import RePossessUSB

/// Refreshes the library from a source.
///
/// `auto` uses USB when the tablet's USB network is present.
/// If the USB refresh fails or stops early, for any reason, it says so and refreshes from the cloud,
/// so that one call still brings the mirror up to date when the tablet sleeps or the cable moves.
/// - Parameters:
///   - usb: Makes a USB client; each refresh gets a new one, which stops after its first timeout.
///   - usbPresent: Whether the Mac is on the tablet's USB network.
public func refreshLibrary(
    _ library: Library,
    _ source: RefreshSource,
    session: CloudSession,
    usb: @Sendable () -> USBClient = { USBClient() },
    usbPresent: @Sendable () -> Bool = USBNetwork.isPresent,
    progress: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> [RefreshReport] {
    switch source {
    case .usb:
        return [try await library.refreshUSB(client: usb(), progress: progress)]
    case .cloud:
        return [try await library.refreshCloud(session: session, progress: progress)]
    case .auto:
        var reports: [RefreshReport] = []
        if usbPresent() {
            do {
                let report = try await library.refreshUSB(client: usb(), progress: progress)
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
