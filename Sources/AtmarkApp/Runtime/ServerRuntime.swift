import Foundation
import AtmarkCore
import AtmarkServer

enum AppRuntimeState: String, Sendable {
    case starting
    case running
    case stopped
    case failed
}

struct AppRuntimeSnapshot: Equatable, Sendable {
    let state: AppRuntimeState
    let detail: String?
    let server: ServerSnapshot?
}

protocol ServerRuntimeServing: Sendable {
    func start() async throws -> AppRuntimeSnapshot
    func snapshot() async -> AppRuntimeSnapshot
    func updateConfig(_ config: Config) async throws -> AppRuntimeSnapshot
    func performPermissionAction(_ action: PermissionAction) async throws -> AppRuntimeSnapshot
    func stop() async
}

/// Owns the process's server objects and remains the source of lifecycle state.
actor ServerRuntime: ServerRuntimeServing {
    private let configURL: URL
    private let permissionProvider: any PermissionProviding
    private let permissionActionPerformer: any PermissionActionPerforming

    private var state: AppRuntimeState = .starting
    private var failureDetail: String?
    private var host: ServerHost?
    private var listener: HTTPListener?

    init(configURL: URL = Config.defaultURL) {
        let permissions = SystemPermissionProvider()
        self.configURL = configURL
        self.permissionProvider = permissions
        self.permissionActionPerformer = permissions
    }

    init(
        configURL: URL,
        permissionProvider: any PermissionProviding,
        permissionActionPerformer: any PermissionActionPerforming,
        runningHost: ServerHost
    ) {
        self.configURL = configURL
        self.permissionProvider = permissionProvider
        self.permissionActionPerformer = permissionActionPerformer
        self.state = .running
        self.host = runningHost
    }

    func start() async throws -> AppRuntimeSnapshot {
        if state == .running {
            return await snapshot()
        }

        state = .starting
        failureDetail = nil

        do {
            let config = try Config.load(from: configURL)
            let token = Token.generate()
            let host = ServerHost(
                config: config,
                tokenStore: .local(token: token),
                registry: ProductionToolCatalogue.registry,
                permissionProvider: permissionProvider
            )
            self.host = host

            let listener = HTTPListener(
                host: config.http.bind,
                port: config.http.port,
                serverHost: host
            )
            self.listener = listener

            let port = try await listener.start()
            await host.startSweeping()

            // Publish only after the listener accepts connections.
            try Endpoint(port: port, host: config.http.bind, token: token).write()
            state = .running
            return await snapshot()
        } catch {
            await tearDownServer()
            state = .failed
            failureDetail = Self.userFacingDescription(for: error)
            throw error
        }
    }

    func snapshot() async -> AppRuntimeSnapshot {
        AppRuntimeSnapshot(
            state: state,
            detail: failureDetail,
            server: await host?.snapshot()
        )
    }

    /// Applies Settings changes in the required order: validate and atomically
    /// save first, then update the resident host. Callers advance their mirror
    /// only when this method returns successfully.
    func updateConfig(_ config: Config) async throws -> AppRuntimeSnapshot {
        guard state == .running, let host else {
            throw AtmarkError(
                .backendUnavailable,
                detail: "server",
                hint: "Start Atmark before changing module settings."
            )
        }
        try config.validate()
        try config.save(to: configURL)
        try await host.updateConfig(config)
        return await snapshot()
    }

    func performPermissionAction(
        _ action: PermissionAction
    ) async throws -> AppRuntimeSnapshot {
        try await permissionActionPerformer.perform(action)
        return await snapshot()
    }

    func stop() async {
        await tearDownServer()
        state = .stopped
        failureDetail = nil
    }

    private func tearDownServer() async {
        await listener?.stop()
        await host?.shutdown()
        listener = nil
        host = nil
        Endpoint.remove()
    }

    private static func userFacingDescription(for error: any Error) -> String {
        if let error = error as? AtmarkError {
            return error.hint
        }
        return error.localizedDescription
    }
}
