import Foundation

enum InputSource: String, Codable, CaseIterable {
    case auto
    case local
    case eventTap = "event-tap"
}

enum Command: Equatable {
    case doctor
    case validateProfile(String)
    case prepare(force: Bool)
    case run(profile: String, inputSource: InputSource, verbose: Bool)
    case clean(logs: Bool)

    static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw CLIError.usage }
        var rest = Array(arguments.dropFirst())
        switch name {
        case "doctor":
            guard rest.isEmpty else { throw CLIError.usage }
            return .doctor
        case "profile":
            guard rest.count == 2, rest[0] == "validate" else { throw CLIError.usage }
            return .validateProfile(rest[1])
        case "prepare":
            if rest.isEmpty { return .prepare(force: false) }
            guard rest == ["--force"] else { throw CLIError.usage }
            return .prepare(force: true)
        case "clean":
            if rest.isEmpty { return .clean(logs: false) }
            guard rest == ["--logs"] else { throw CLIError.usage }
            return .clean(logs: true)
        case "run":
            var profile: String?
            var source = InputSource.auto
            var verbose = false
            while !rest.isEmpty {
                let option = rest.removeFirst()
                if option == "--verbose" {
                    verbose = true
                } else if option == "--profile", let value = rest.first {
                    profile = value
                    rest.removeFirst()
                } else if option == "--input-source", let value = rest.first,
                          let parsed = InputSource(rawValue: value) {
                    source = parsed
                    rest.removeFirst()
                } else {
                    throw CLIError.invalidArgument(option)
                }
            }
            guard let profile else { throw CLIError.missingProfile }
            return .run(profile: profile, inputSource: source, verbose: verbose)
        default:
            throw CLIError.invalidArgument(name)
        }
    }
}

enum CLIError: LocalizedError {
    case usage
    case invalidArgument(String)
    case missingProfile
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return Self.help
        case .invalidArgument(let value):
            return "Unknown or invalid argument: \(value)\n\n\(Self.help)"
        case .missingProfile:
            return "run requires --profile <file.se>"
        case .failed(let message):
            return message
        }
    }

    static let help = """
    Usage:
      shockemu doctor
      shockemu profile validate <file.se>
      shockemu prepare [--force]
      shockemu run --profile <file.se> [--input-source auto|local|event-tap] [--verbose]
      shockemu clean [--logs]
    """
}
