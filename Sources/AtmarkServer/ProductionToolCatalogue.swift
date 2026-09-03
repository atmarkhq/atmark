/// The single catalogue shipped by Atmark.
///
/// Module tasks add their definitions here when they land. Keeping production
/// registration in one place ensures the app and the tool-surface budget test
/// cannot silently drift apart.
public enum ProductionToolCatalogue {
    public static let definitions: [ToolDefinition] = [
        StatusTool.definition,
    ]

    public static let registry = ToolRegistry(catalogue: definitions)
}
