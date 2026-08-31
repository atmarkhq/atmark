import Carbon
import Darwin
import EventKit
import Foundation
import AtmarkCore
import Testing

@testable import AtmarkServer

@Suite("Permission status")
struct PermissionStatusTests {
    @Test("EventKit authorization maps to honest wire states")
    func remindersMapping() {
        #expect(SystemPermissionProvider.reminderState(for: .notDetermined) == .notDetermined)
        #expect(SystemPermissionProvider.reminderState(for: .restricted) == .restricted)
        #expect(SystemPermissionProvider.reminderState(for: .denied) == .denied)
        #expect(SystemPermissionProvider.reminderState(for: .fullAccess) == .granted)
        #expect(SystemPermissionProvider.reminderState(for: .writeOnly) == .writeOnly)
    }

    @Test("Apple Events OSStatus maps without collapsing not determined into denied")
    func mailAutomationMapping() {
        #expect(SystemPermissionProvider.mailAutomationState(for: noErr) == .granted)
        #expect(
            SystemPermissionProvider.mailAutomationState(
                for: OSStatus(errAEEventNotPermitted)
            ) == .denied
        )
        #expect(
            SystemPermissionProvider.mailAutomationState(
                for: OSStatus(errAEEventWouldRequireUserConsent)
            ) == .notDetermined
        )
        #expect(
            SystemPermissionProvider.mailAutomationState(
                for: OSStatus(procNotFound)
            ) == .unavailable
        )
        #expect(SystemPermissionProvider.mailAutomationState(for: -9_999) == .unknown)
    }

    @Test("permission request results map without claiming a grant")
    func permissionRequestResultMapping() {
        #expect(SystemPermissionProvider.remindersRequestError(granted: true) == nil)
        #expect(
            SystemPermissionProvider.remindersRequestError(granted: false)
                == .remindersAccessNotGranted
        )
        #expect(SystemPermissionProvider.mailAutomationRequestError(for: noErr) == nil)
        #expect(
            SystemPermissionProvider.mailAutomationRequestError(
                for: OSStatus(errAEEventNotPermitted)
            ) == .mailAutomationAccessNotGranted
        )
        #expect(
            SystemPermissionProvider.mailAutomationRequestError(
                for: OSStatus(errAEEventWouldRequireUserConsent)
            ) == .mailAutomationConsentNotCompleted
        )
        #expect(
            SystemPermissionProvider.mailAutomationRequestError(
                for: OSStatus(procNotFound)
            ) == .mailNotRunning
        )
        #expect(
            SystemPermissionProvider.mailAutomationRequestError(for: -9_999)
                == .mailAutomationRequestFailed(-9_999)
        )
    }

    @Test("Mail not running is unavailable without an Apple Events probe")
    func mailNotRunning() async {
        #expect(
            await SystemPermissionProvider.mailAutomationState(mailIsRunning: false)
                == .unavailable
        )
    }

    @Test("Mail data errno maps effective access failures")
    func mailDataMapping() {
        #expect(SystemPermissionProvider.mailDataState(forErrno: EACCES) == .denied)
        #expect(SystemPermissionProvider.mailDataState(forErrno: EPERM) == .denied)
        #expect(SystemPermissionProvider.mailDataState(forErrno: ENOENT) == .unavailable)
        #expect(SystemPermissionProvider.mailDataState(forErrno: EIO) == .unknown)
    }

    @Test("Mail data probe distinguishes an existing directory from a missing one")
    func mailDataProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "atmark-mail-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await SystemPermissionProvider.mailDataState(at: directory) == .granted)
        #expect(
            await SystemPermissionProvider.mailDataState(
                at: directory.appending(path: "missing", directoryHint: .isDirectory)
            ) == .unavailable
        )
    }

    @Test("permission snapshot serialization uses compact stable keys")
    func permissionSerialization() throws {
        let snapshot = PermissionSnapshot(
            reminders: .writeOnly,
            mailAutomation: .notDetermined,
            fullDiskAccess: .denied
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let text = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(
            text == #"{"full_disk_access":"denied","mail_automation":"not_determined","reminders":"write_only"}"#
        )
    }

    @Test("status structured output includes deterministic permissions")
    func statusSerialization() throws {
        let snapshot = StatusSnapshot(
            version: "1.2.3",
            host: "127.0.0.1",
            port: 4_321,
            modules: ["mail": .init(enabled: true, writes: false)],
            sessionCount: 2,
            capabilities: .readOnly,
            permissions: PermissionSnapshot(
                reminders: .granted,
                mailAutomation: .unavailable,
                fullDiskAccess: .unknown
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let text = String(decoding: try encoder.encode(snapshot.json), as: UTF8.self)
        #expect(text.contains(#""permissions":{"full_disk_access":"unknown","mail_automation":"unavailable","reminders":"granted"}"#))
        #expect(text.contains(#""endpoint":"http:\/\/127.0.0.1:4321\/mcp""#))
    }

    @Test("status output schema declares compact permission keys")
    func statusSchema() throws {
        let schema = try #require(StatusTool.definition.tool.outputSchema)
        guard case .object(let root) = schema,
              case .object(let properties) = root["properties"],
              case .object(let permissions) = properties["permissions"],
              case .object(let permissionProperties) = permissions["properties"]
        else {
            Issue.record("Expected an object permissions schema")
            return
        }

        #expect(permissionProperties["reminders"] != nil)
        #expect(permissionProperties["mail_automation"] != nil)
        #expect(permissionProperties["full_disk_access"] != nil)
    }
}
