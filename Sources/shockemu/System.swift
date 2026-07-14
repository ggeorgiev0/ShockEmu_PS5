import CryptoKit
import Foundation
import Security

struct ProcessResult {
    let status: Int32
    let output: String
}

enum System {
    static func sha256(_ url: URL) throws -> String {
        try sha256(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func restrictPermissionsRecursively(_ root: URL) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        try restrict(root)
        for case let url as URL in enumerator { try restrict(url) }
    }

    private static func restrict(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return }
        let existing = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let permissions = values.isDirectory == true ? 0o700 : ((existing & 0o100) == 0 ? 0o600 : 0o700)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

enum LaunchEnvironment {
    static func make(
        base: [String: String],
        runtime: String,
        profile: String,
        profileHash: String,
        inputSource: InputSource,
        verbose: Bool
    ) -> [String: String] {
        var result = base.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("SHOCKEMU_")
        }
        result["DYLD_INSERT_LIBRARIES"] = runtime
        result["SHOCKEMU_PROFILE_PATH"] = profile
        result["SHOCKEMU_PROFILE_SHA256"] = profileHash
        result["SHOCKEMU_INPUT_SOURCE"] = inputSource.rawValue
        if verbose { result["SHOCKEMU_VERBOSE"] = "1" }
        return result
    }
}

struct RemotePlayIdentity {
    static let bundleID = "com.playstation.RemotePlay"
    static let version = "9.0.0"
    static let teamID = "8UT4NVUACP"
    static let executableSHA256 = "6e6e09495de366ae5a1264442cf3395c0f97ee7a03f493afa838cc9451401612"

    let executable: URL
    let hash: String
}

enum RemotePlayInspector {
    static func inspectSupportedApp(at app: URL) throws -> RemotePlayIdentity {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == RemotePlayIdentity.bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == RemotePlayIdentity.version,
              let executable = bundle.executableURL else {
            throw CLIError.failed("Remote Play 9.0.0 was not found at /Applications/RemotePlay.app.")
        }
        try verifySonySignature(app)
        let hash = try System.sha256(executable)
        guard hash == RemotePlayIdentity.executableSHA256 else {
            throw CLIError.failed("This Remote Play 9.0.0 executable hash is not supported; no override is available.")
        }
        return RemotePlayIdentity(executable: executable, hash: hash)
    }

    private static func verifySonySignature(_ app: URL) throws {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            throw CLIError.failed("Unable to inspect the Remote Play signature.")
        }
        let requirementText = "anchor apple generic and identifier \"\(RemotePlayIdentity.bundleID)\" and certificate leaf[subject.OU] = \"\(RemotePlayIdentity.teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw CLIError.failed("Remote Play does not have the expected valid Sony signature.")
        }
    }

    static func hasRequiredIOKitImports(_ executable: URL) throws -> Bool {
        let result = try System.run("/usr/bin/nm", ["-u", executable.path])
        let required = [
            "_IOHIDManagerCreate", "_IOHIDManagerSetDeviceMatchingMultiple",
            "_IOHIDManagerCopyDevices", "_IOHIDDeviceGetReport",
            "_IOHIDDeviceRegisterInputReportCallback",
        ]
        return result.status == 0 && required.allSatisfy(result.output.contains)
    }
}
