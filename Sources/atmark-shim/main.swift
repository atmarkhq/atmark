import Foundation
import AtmarkShim

@main
struct AtmarkShimMain {
    static func main() async {
        do {
            try await AtmarkShimRuntime().run()
        } catch let failure as ShimFailure {
            FileHandle.standardError.write(Data("\(failure.diagnostic)\n".utf8))
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(
                Data("atmark-shim: an unexpected transport failure occurred. Restart Atmark.app and reconnect the MCP client.\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
