import Foundation

/// Describes how the RepoPrompt app process appears to have been launched.
///
/// This is intentionally narrower than a full process-environment builder: it is a
/// first-class signal that later launch code can use to decide whether inherited
/// environment variables are likely user-shell-rich or macOS app-launch-minimal.
enum ProcessLaunchSource: Equatable {
    case launchServices
    case xcode
    case terminalInherited
    case unknown
}

struct ProcessLaunchContext: Equatable {
    static let launchSourceEnvironmentKey = "REPOPROMPT_LAUNCH_SOURCE"
    static let launchServicesEnvironmentValue = "launchservices"

    let source: ProcessLaunchSource
    let inheritedEnvironmentPath: String?
    let shell: String?
    let home: String?

    static var current: ProcessLaunchContext {
        detect()
    }

    static func detect(from environment: [String: String] = ProcessInfo.processInfo.environment) -> ProcessLaunchContext {
        let source: ProcessLaunchSource = if environment[launchSourceEnvironmentKey] == launchServicesEnvironmentValue {
            .launchServices
        } else if isXcodeOrTestEnvironment(environment) {
            .xcode
        } else if isTerminalInheritedEnvironment(environment) {
            .terminalInherited
        } else {
            .unknown
        }

        return ProcessLaunchContext(
            source: source,
            inheritedEnvironmentPath: environment["PATH"],
            shell: environment["SHELL"],
            home: environment["HOME"]
        )
    }

    private static func isXcodeOrTestEnvironment(_ environment: [String: String]) -> Bool {
        let markerKeys = [
            "XCTestConfigurationFilePath",
            "XCTestSessionIdentifier",
            "XCODE_RUNNING_FOR_PREVIEWS",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS"
        ]
        return markerKeys.contains { environment[$0] != nil }
    }

    private static func isTerminalInheritedEnvironment(_ environment: [String: String]) -> Bool {
        let terminalMarkerKeys = [
            "TERM",
            "TERM_PROGRAM",
            "SSH_TTY",
            "SSH_CONNECTION"
        ]
        guard terminalMarkerKeys.contains(where: { environment[$0]?.isEmpty == false }) else {
            return false
        }
        return hasRichPath(environment["PATH"])
    }

    private static func hasRichPath(_ pathValue: String?) -> Bool {
        guard let pathValue, !pathValue.isEmpty else { return false }
        let components = pathValue.split(separator: ":").map(String.init)
        return components.contains { !standardSystemPaths.contains($0) }
    }

    private static let standardSystemPaths: Set<String> = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
}
