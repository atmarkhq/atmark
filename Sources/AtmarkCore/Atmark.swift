/// Namespace for Atmark's transport- and UI-independent core.
///
/// Everything the safety model depends on — config, error model, mutation gate,
/// confirm-token store, audit log, backend routing — lives in this target so it
/// stays unit-testable without a GUI, a transport, or a TCC grant.
///
/// This target must not import SwiftUI, AppKit, or the MCP SDK. The package
/// dependency graph blocks the SDK and NIO; `ImportBoundaryTests` covers the
/// system frameworks, which are importable from anywhere.
public enum Atmark {}
