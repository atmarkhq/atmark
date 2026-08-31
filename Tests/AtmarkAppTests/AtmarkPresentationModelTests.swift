import Foundation
import AtmarkCore
import AtmarkServer
import Testing

@testable import AtmarkApp

@MainActor
@Suite("Atmark presentation model")
struct AtmarkPresentationModelTests {
    private struct TestPermissionProvider: PermissionProviding {
        let value: PermissionSnapshot

        func currentPermissions() async -> PermissionSnapshot { value }
    }

    private actor TestRuntime: ServerRuntimeServing {
        var value: AppRuntimeSnapshot
        var updateError: AtmarkError?
        var permissionActionError: PermissionActionError?
        var permissionActionValue: AppRuntimeSnapshot?
        var updates: [Config] = []
        var permissionActions: [PermissionAction] = []
        let permissionActionGate: ActionGate?

        init(
            value: AppRuntimeSnapshot,
            updateError: AtmarkError? = nil,
            permissionActionError: PermissionActionError? = nil,
            permissionActionValue: AppRuntimeSnapshot? = nil,
            permissionActionGate: ActionGate? = nil
        ) {
            self.value = value
            self.updateError = updateError
            self.permissionActionError = permissionActionError
            self.permissionActionValue = permissionActionValue
            self.permissionActionGate = permissionActionGate
        }

        func start() async throws -> AppRuntimeSnapshot { value }

        func snapshot() async -> AppRuntimeSnapshot { value }

        func updateConfig(_ config: Config) async throws -> AppRuntimeSnapshot {
            updates.append(config)
            if let updateError { throw updateError }
            let previous = value.server!
            value = AppRuntimeSnapshot(
                state: value.state,
                detail: value.detail,
                server: ServerSnapshot(
                    host: previous.host,
                    port: previous.port,
                    sessionCount: previous.sessionCount,
                    config: config,
                    permissions: previous.permissions
                )
            )
            return value
        }

        func performPermissionAction(
            _ action: PermissionAction
        ) async throws -> AppRuntimeSnapshot {
            permissionActions.append(action)
            if let permissionActionGate {
                await permissionActionGate.wait()
            }
            if let permissionActionValue {
                value = permissionActionValue
            }
            if let permissionActionError { throw permissionActionError }
            return value
        }

        func stop() async {}
    }

    private actor ActionGate {
        private var actionStarted = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func wait() async {
            actionStarted = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilStarted() async {
            guard actionStarted == false else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private actor TestPermissionService: PermissionProviding, PermissionActionPerforming {
        var value: PermissionSnapshot
        var valueAfterAction: PermissionSnapshot?
        var actionError: PermissionActionError?
        var actions: [PermissionAction] = []

        init(
            value: PermissionSnapshot,
            valueAfterAction: PermissionSnapshot? = nil,
            actionError: PermissionActionError? = nil
        ) {
            self.value = value
            self.valueAfterAction = valueAfterAction
            self.actionError = actionError
        }

        func currentPermissions() async -> PermissionSnapshot { value }

        func perform(_ action: PermissionAction) async throws {
            actions.append(action)
            if let valueAfterAction {
                value = valueAfterAction
            }
            if let actionError { throw actionError }
        }
    }

    @Test("successful module update advances the mirror")
    func successfulUpdate() async {
        let runtime = TestRuntime(value: snapshot())
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        await model.setModuleWrites(true, module: "reminders")

        #expect(model.config.modules["reminders"]?.writes == true)
        #expect(model.errorMessage == nil)
        #expect(await runtime.updates.count == 1)
    }

    @Test("failed module update leaves the mirror unchanged and surfaces the error")
    func failedUpdate() async {
        let runtime = TestRuntime(
            value: snapshot(),
            updateError: AtmarkError(
                .backendUnavailable,
                detail: "config.json",
                hint: "Could not save settings."
            )
        )
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        await model.setModuleEnabled(false, module: "reminders")

        #expect(model.config.modules["reminders"]?.enabled == true)
        #expect(model.errorMessage == "Could not save settings.")
        #expect(await runtime.updates.count == 1)
    }

    @Test("menu presentation is ready when an enabled integration is usable")
    func menuPresentationReady() async {
        let model = await model(
            permissions: .init(
                reminders: .granted,
                mailAutomation: .granted,
                fullDiskAccess: .granted
            )
        )

        #expect(model.menuBarPresentation.state == .ready)
        #expect(model.menuBarPresentation.statusText == "Ready")
        #expect(model.menuBarPresentation.symbolName == "apple.logo")
        #expect(model.menuBarPresentation.attentionItems.isEmpty)
        #expect(model.menuBarPresentation.accessibilityLabel == "Atmark, Ready")
    }

    @Test("menu presentation shows only actionable problems for enabled integrations")
    func menuPresentationNeedsAttention() async {
        var config = Config()
        config.modules["mail"]?.enabled = false
        let setupRequired = await model(
            config: config,
            permissions: .init(
                reminders: .notDetermined,
                mailAutomation: .denied,
                fullDiskAccess: .denied
            )
        )

        #expect(setupRequired.menuBarPresentation.state == .setupRequired)
        #expect(setupRequired.menuBarPresentation.attentionItems.map(\.id) == [.reminders])

        config.modules["mail"]?.enabled = true
        let partiallyUsable = await model(
            config: config,
            permissions: .init(
                reminders: .notDetermined,
                mailAutomation: .granted,
                fullDiskAccess: .denied
            )
        )

        #expect(partiallyUsable.menuBarPresentation.state == .needsAttention)
        #expect(partiallyUsable.menuBarPresentation.symbolName == "exclamationmark.triangle")
        #expect(
            partiallyUsable.menuBarPresentation.accessibilityLabel
                == "Atmark, Needs attention"
        )
        #expect(
            partiallyUsable.menuBarPresentation.attentionItems.map(\.id)
                == [.reminders, .mailData]
        )
    }

    @Test("menu presentation requires setup when no enabled integration is usable")
    func menuPresentationSetupRequired() async {
        var config = Config()
        config.modules["reminders"]?.enabled = false
        config.modules["mail"]?.enabled = false
        let model = await model(
            config: config,
            permissions: .init(
                reminders: .granted,
                mailAutomation: .granted,
                fullDiskAccess: .granted
            )
        )

        #expect(model.menuBarPresentation.state == .setupRequired)
        #expect(model.menuBarPresentation.statusText == "Setup required")
        #expect(model.menuBarPresentation.symbolName == "bolt.slash")
        #expect(model.menuBarPresentation.attentionItems.isEmpty)
    }

    @Test("non-running menu presentations use lifecycle semantics and hide permission actions")
    func nonRunningMenuPresentations() async {
        let startingRuntime = TestRuntime(
            value: AppRuntimeSnapshot(
                state: .starting,
                detail: nil,
                server: snapshot(
                    permissions: .init(
                        reminders: .notDetermined,
                        mailAutomation: .denied,
                        fullDiskAccess: .denied
                    )
                ).server
            )
        )
        let startingModel = AtmarkPresentationModel(runtime: startingRuntime)
        await startingModel.refresh()

        #expect(startingModel.menuBarPresentation.state == .starting)
        #expect(startingModel.menuBarPresentation.statusText == "Starting")
        #expect(startingModel.menuBarPresentation.symbolName == "clock")
        #expect(startingModel.menuBarPresentation.accessibilityLabel == "Atmark, Starting")
        #expect(startingModel.menuBarPresentation.attentionItems.isEmpty)

        let stoppedModel = AtmarkPresentationModel(
            runtime: TestRuntime(
                value: AppRuntimeSnapshot(state: .stopped, detail: nil, server: nil)
            )
        )
        await stoppedModel.refresh()

        #expect(stoppedModel.menuBarPresentation.state == .setupRequired)
        #expect(stoppedModel.menuBarPresentation.statusText == "Stopped")
        #expect(stoppedModel.menuBarPresentation.symbolName == "bolt.slash")
        #expect(stoppedModel.menuBarPresentation.accessibilityLabel == "Atmark, Stopped")
        #expect(stoppedModel.menuBarPresentation.attentionItems.isEmpty)
    }

    @Test("failed menu presentation hides stale permission actions")
    func failedMenuPresentationHidesPermissionActions() async {
        let runtime = TestRuntime(
            value: AppRuntimeSnapshot(
                state: .failed,
                detail: "The listener could not start.",
                server: nil
            )
        )
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        #expect(model.menuBarPresentation.state == .failed)
        #expect(model.menuBarPresentation.statusText == "Failed")
        #expect(model.menuBarPresentation.symbolName == "xmark.octagon")
        #expect(model.menuBarPresentation.accessibilityLabel == "Atmark, Failed")
        #expect(model.menuBarPresentation.detail == "The listener could not start.")
        #expect(model.menuBarPresentation.attentionItems.isEmpty)
    }

    @Test("permission states route to explicit user actions")
    func permissionActionRouting() async {
        let remindersUndetermined = await model(
            permissions: .init(
                reminders: .notDetermined,
                mailAutomation: .granted,
                fullDiskAccess: .granted
            )
        )
        #expect(
            remindersUndetermined.permissionAction(for: .reminders)
                == .init(action: .requestRemindersAccess, title: "Request Access…")
        )

        let remindersDenied = await model(
            permissions: .init(
                reminders: .denied,
                mailAutomation: .granted,
                fullDiskAccess: .granted
            )
        )
        #expect(
            remindersDenied.permissionAction(for: .reminders)
                == .init(action: .openRemindersSettings, title: "Open Reminders…")
        )

        let mailUnavailable = await model(
            permissions: .init(
                reminders: .granted,
                mailAutomation: .unavailable,
                fullDiskAccess: .granted
            )
        )
        #expect(
            mailUnavailable.permissionAction(for: .mailAutomation)
                == .init(action: .openMail, title: "Open Mail…")
        )

        let mailUndetermined = await model(
            permissions: .init(
                reminders: .granted,
                mailAutomation: .notDetermined,
                fullDiskAccess: .granted
            )
        )
        #expect(
            mailUndetermined.permissionAction(for: .mailAutomation)
                == .init(action: .requestMailAutomationAccess, title: "Request Access…")
        )

        let mailDenied = await model(
            permissions: .init(
                reminders: .granted,
                mailAutomation: .restricted,
                fullDiskAccess: .granted
            )
        )
        #expect(
            mailDenied.permissionAction(for: .mailAutomation)
                == .init(action: .openAutomationSettings, title: "Open Automation…")
        )
        #expect(
            mailDenied.permissionAction(for: .mailData)
                == .init(action: .openFullDiskAccessSettings, title: "Open Full Disk Access…")
        )
    }

    @Test("successful permission action advances the refreshed mirror")
    func successfulPermissionAction() async {
        let updated = snapshot(
            permissions: .init(
                reminders: .granted,
                mailAutomation: .unavailable,
                fullDiskAccess: .denied
            )
        )
        let runtime = TestRuntime(
            value: snapshot(),
            permissionActionValue: updated
        )
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        await model.performPermissionAction(.requestRemindersAccess)

        #expect(await runtime.permissionActions == [.requestRemindersAccess])
        #expect(model.permissions.reminders == .granted)
        #expect(model.permissionActionInProgress == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("failed permission action refreshes real state and surfaces an actionable error")
    func failedPermissionAction() async {
        let denied = snapshot(
            permissions: .init(
                reminders: .denied,
                mailAutomation: .unavailable,
                fullDiskAccess: .denied
            )
        )
        let runtime = TestRuntime(
            value: snapshot(),
            permissionActionError: .remindersAccessNotGranted,
            permissionActionValue: denied
        )
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        await model.performPermissionAction(.requestRemindersAccess)

        #expect(model.permissions.reminders == .denied)
        #expect(model.permissionActionInProgress == nil)
        #expect(model.errorMessage?.contains("Privacy & Security > Reminders") == true)
    }

    @Test("permission actions are single-flight across the shared model")
    func permissionActionIsSingleFlight() async {
        let gate = ActionGate()
        let runtime = TestRuntime(value: snapshot(), permissionActionGate: gate)
        let model = AtmarkPresentationModel(runtime: runtime)
        await model.refresh()

        let first = Task { await model.performPermissionAction(.requestRemindersAccess) }
        await gate.waitUntilStarted()
        #expect(model.permissionActionInProgress == .requestRemindersAccess)

        await model.performPermissionAction(.openMail)
        #expect(await runtime.permissionActions == [.requestRemindersAccess])

        await gate.release()
        await first.value
        #expect(model.permissionActionInProgress == nil)
    }

    @Test("passive runtime and model refresh never invoke the user-action dependency")
    func passiveRefreshDoesNotPerformActions() async {
        let service = TestPermissionService(value: permissions())
        let host = makeHost(permissionProvider: service)
        let runtime = ServerRuntime(
            configURL: temporaryConfigURL(),
            permissionProvider: service,
            permissionActionPerformer: service,
            runningHost: host
        )
        let model = AtmarkPresentationModel(runtime: runtime)

        _ = await runtime.snapshot()
        await model.refresh()

        #expect(await service.actions.isEmpty)
        #expect(model.permissions == permissions())
    }

    @Test("runtime routes a user action and returns a newly read permission snapshot")
    func runtimePerformsAndRefreshesPermissionAction() async throws {
        let granted = PermissionSnapshot(
            reminders: .granted,
            mailAutomation: .unavailable,
            fullDiskAccess: .denied
        )
        let service = TestPermissionService(
            value: permissions(),
            valueAfterAction: granted
        )
        let host = makeHost(permissionProvider: service)
        let runtime = ServerRuntime(
            configURL: temporaryConfigURL(),
            permissionProvider: service,
            permissionActionPerformer: service,
            runningHost: host
        )

        let result = try await runtime.performPermissionAction(.requestRemindersAccess)

        #expect(await service.actions == [.requestRemindersAccess])
        #expect(result.server?.permissions == granted)
    }

    @Test("runtime saves config before applying it to the host")
    func runtimePersistsThenApplies() async throws {
        let url = temporaryConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = TestPermissionProvider(value: permissions())
        let host = makeHost(permissionProvider: provider)
        let runtime = ServerRuntime(
            configURL: url,
            permissionProvider: provider,
            permissionActionPerformer: TestPermissionService(value: permissions()),
            runningHost: host
        )
        var updated = Config()
        updated.modules["mail"]?.enabled = false

        let result = try await runtime.updateConfig(updated)

        #expect(try Config.load(from: url) == updated)
        #expect(await host.currentConfig == updated)
        #expect(result.server?.config == updated)
    }

    @Test("runtime does not update the host when atomic persistence fails")
    func runtimeSaveFailureDoesNotApply() async throws {
        let url = temporaryConfigURL()
        // A directory at the destination makes the atomic file write fail.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = TestPermissionProvider(value: permissions())
        let host = makeHost(permissionProvider: provider)
        let runtime = ServerRuntime(
            configURL: url,
            permissionProvider: provider,
            permissionActionPerformer: TestPermissionService(value: permissions()),
            runningHost: host
        )
        let original = await host.currentConfig
        var updated = original
        updated.modules["mail"]?.enabled = false

        do {
            _ = try await runtime.updateConfig(updated)
            Issue.record("Expected persistence to fail")
        } catch {
            // The concrete Foundation error is platform-owned; the ordering is
            // what this regression verifies.
        }

        #expect(await host.currentConfig == original)
    }

    private func snapshot(
        config: Config = Config(),
        permissions: PermissionSnapshot? = nil
    ) -> AppRuntimeSnapshot {
        AppRuntimeSnapshot(
            state: .running,
            detail: nil,
            server: ServerSnapshot(
                host: "127.0.0.1",
                port: 8_080,
                sessionCount: 3,
                config: config,
                permissions: permissions ?? self.permissions()
            )
        )
    }

    private func model(
        config: Config = Config(),
        permissions: PermissionSnapshot
    ) async -> AtmarkPresentationModel {
        let model = AtmarkPresentationModel(
            runtime: TestRuntime(value: snapshot(config: config, permissions: permissions))
        )
        await model.refresh()
        return model
    }

    private func permissions() -> PermissionSnapshot {
        PermissionSnapshot(
            reminders: .granted,
            mailAutomation: .notDetermined,
            fullDiskAccess: .denied
        )
    }

    private func makeHost(
        permissionProvider: some PermissionProviding
    ) -> ServerHost {
        ServerHost(
            config: Config(),
            tokenStore: .local(token: "app-runtime-test"),
            registry: ProductionToolCatalogue.registry,
            permissionProvider: permissionProvider
        )
    }

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "atmark-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "config.json")
    }
}
