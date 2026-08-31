import Foundation
import SwiftUI

struct AboutSettingsPane: View {
    private let bundle = Bundle.main

    var body: some View {
        Form {
            Section("Application") {
                if let name = bundleValue("CFBundleDisplayName") ?? bundleValue("CFBundleName") {
                    LabeledContent("Name", value: name)
                }
                if let version = bundleValue("CFBundleShortVersionString") {
                    LabeledContent("Version", value: version)
                }
                if let build = bundleValue("CFBundleVersion") {
                    LabeledContent("Build", value: build)
                }
                if let identifier = bundle.bundleIdentifier {
                    LabeledContent("Bundle Identifier", value: identifier)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private func bundleValue(_ key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}
