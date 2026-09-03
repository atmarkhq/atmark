import AppKit
import Carbon
import Darwin
import EventKit
import Foundation

/// Reads permission state without requesting access or launching another app.
public struct SystemPermissionProvider: PermissionProviding {
    static let mailBundleIdentifier = "com.apple.mail"

    private let mailDataURL: URL

    public init(
        mailDataURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mail", directoryHint: .isDirectory)
    ) {
        self.mailDataURL = mailDataURL
    }

    public func currentPermissions() async -> PermissionSnapshot {
        let reminders = Self.reminderState(
            for: EKEventStore.authorizationStatus(for: .reminder)
        )
        let mailIsRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.mailBundleIdentifier
            ).isEmpty
        }

        async let mailAutomation = Self.mailAutomationState(mailIsRunning: mailIsRunning)
        async let mailData = Self.mailDataState(at: mailDataURL)
        return await PermissionSnapshot(
            reminders: reminders,
            mailAutomation: mailAutomation,
            fullDiskAccess: mailData
        )
    }

    /// Pure mapping kept separate from the EventKit query for deterministic tests.
    static func reminderState(for status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .fullAccess:
            .granted
        case .writeOnly:
            .writeOnly
        @unknown default:
            .unknown
        }
    }

    /// The Apple Events API can block, so this function explicitly leaves the
    /// caller's actor. It never asks for consent and is called only for running
    /// Mail instances, satisfying the API precondition without launching Mail.
    @concurrent
    static func mailAutomationState(mailIsRunning: Bool) async -> PermissionState {
        guard mailIsRunning else { return .unavailable }
        let target = NSAppleEventDescriptor(bundleIdentifier: mailBundleIdentifier)
        guard let descriptor = target.aeDesc else {
            return .unknown
        }
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor,
            typeWildCard,
            typeWildCard,
            false
        )
        return mailAutomationState(for: status)
    }

    /// Pure OSStatus mapping for the non-prompting Apple Events result.
    static func mailAutomationState(for status: OSStatus) -> PermissionState {
        switch status {
        case noErr:
            .granted
        case OSStatus(errAEEventNotPermitted):
            .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            .notDetermined
        case OSStatus(procNotFound):
            .unavailable
        default:
            .unknown
        }
    }

    /// A read-only effective-access probe. `opendir` distinguishes a missing
    /// Mail directory from TCC/POSIX denial without querying private TCC data.
    @concurrent
    static func mailDataState(at url: URL) async -> PermissionState {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .unknown }
            errno = 0
            guard let directory = opendir(path) else {
                return mailDataState(forErrno: errno)
            }
            errno = 0
            _ = readdir(directory)
            let readErrno = errno
            closedir(directory)
            return readErrno == 0 ? .granted : mailDataState(forErrno: readErrno)
        }
    }

    /// Pure errno mapping for the effective Mail data probe.
    static func mailDataState(forErrno value: Int32) -> PermissionState {
        switch value {
        case EACCES, EPERM:
            .denied
        case ENOENT:
            .unavailable
        default:
            .unknown
        }
    }
}
