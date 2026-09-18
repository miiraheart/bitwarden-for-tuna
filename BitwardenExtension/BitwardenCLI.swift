import Foundation
import TunaKit

enum BitwardenCLIError: LocalizedError, Equatable {
  case notInstalled
  case invalidCustomPath(String)
  case commandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "Bitwarden CLI not found. Install it with Homebrew: brew install bitwarden-cli"
    case .invalidCustomPath(let path):
      return "The Bitwarden CLI path in Settings is not an executable: \(path)"
    case .commandFailed(let command, let message):
      return "bw \(command) failed: \(message)"
    }
  }
}

struct BitwardenCLIStatus: Equatable, Sendable {
  let state: ServeStatus.State
  let serverURL: String?
  let lastSync: Date?

  static func parse(_ json: Data) throws -> BitwardenCLIStatus {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let raw = object["status"] as? String, let state = ServeStatus.State(rawValue: raw)
    else { throw BitwardenServeError.malformed }
    return BitwardenCLIStatus(
      state: state, serverURL: object["serverUrl"] as? String,
      lastSync: BitwardenDates.parse(object["lastSync"] as? String))
  }
}

struct BitwardenCLI: Sendable {
  static let defaultCandidates = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]

  let executable: String
  let stateDirectory: URL

  static func resolveExecutable(
    customPath: String?, fileManager: FileManager = .default, candidates: [String] = defaultCandidates,
    which: (String) -> String? = whichLookup
  ) throws -> String {
    if let customPath, !customPath.isEmpty {
      guard fileManager.isExecutableFile(atPath: customPath) else {
        throw BitwardenCLIError.invalidCustomPath(customPath)
      }
      return customPath
    }
    if let match = candidates.first(where: fileManager.isExecutableFile(atPath:)) { return match }
    if let found = which("bw"), fileManager.isExecutableFile(atPath: found) { return found }
    throw BitwardenCLIError.notInstalled
  }

  static func whichLookup(_ name: String) -> String? {
    let request = CLIProcessRequest(executablePath: "/usr/bin/which", arguments: [name], timeout: 10)
    guard let result = try? CLIProcessRunner.runSync(request), result.succeeded else { return nil }
    let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  func status() async throws -> BitwardenCLIStatus {
    let result = try await run(["status"], command: "status")
    return try BitwardenCLIStatus.parse(Data(result.standardOutput.utf8))
  }

  func configureServer(_ url: String) async throws {
    _ = try await run(["config", "server", url], command: "config server")
  }

  func login(clientID: String, clientSecret: String) async throws {
    _ = try await run(
      ["login", "--apikey"], command: "login",
      extraEnvironment: ["BW_CLIENTID": clientID, "BW_CLIENTSECRET": clientSecret], timeout: 90)
  }

  private func run(
    _ arguments: [String], command: String, extraEnvironment: [String: String] = [:], timeout: TimeInterval = 30
  ) async throws -> CLIProcessResult {
    try BitwardenPaths.prepareDirectory(stateDirectory)
    var environment = ProcessInfo.processInfo.environment
    environment["BITWARDENCLI_APPDATA_DIR"] = stateDirectory.path
    environment["BW_NOINTERACTION"] = "true"
    environment.merge(extraEnvironment) { _, new in new }
    let request = CLIProcessRequest(
      executablePath: executable, arguments: arguments, environment: environment, timeout: timeout)
    let result: CLIProcessResult
    do {
      result = try await Task.detached(priority: .utility) { try CLIProcessRunner.runSync(request) }.value
    } catch {
      throw BitwardenCLIError.commandFailed(command: command, message: error.localizedDescription)
    }
    guard result.succeeded else {
      throw BitwardenCLIError.commandFailed(command: command, message: result.preferredErrorMessage)
    }
    return result
  }
}
