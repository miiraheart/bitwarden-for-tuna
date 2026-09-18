import AppKit
import Foundation
import LocalAuthentication

enum BitwardenVaultState: Equatable, Sendable {
  case idle
  case working
  case unconfigured([String])
  case keychainDenied
  case cliMissing
  case loginFailed(String)
  case serveFailed(String)
  case locked
  case unlockFailed(String)
  case unlocked
}

enum BitwardenVaultError: LocalizedError, Equatable {
  case unconfigured([String])
  case keychainDenied
  case cliMissing
  case loginFailed(String)
  case serveFailed(String)
  case unlockCancelled
  case unlockFailed(String)
  case locked
  case request(String)

  var errorDescription: String? {
    switch self {
    case .unconfigured(let fields):
      return "Set up Bitwarden in Tuna Settings > Extensions > Bitwarden: \(fields.joined(separator: ", "))."
    case .keychainDenied: return BitwardenSettingsError.keychainAccessDenied.errorDescription
    case .cliMissing: return BitwardenCLIError.notInstalled.errorDescription
    case .loginFailed(let message): return "Login failed: \(message)"
    case .serveFailed(let message): return "Could not start the Bitwarden CLI: \(message)"
    case .unlockCancelled: return "Unlock cancelled."
    case .unlockFailed(let message): return "Unlock failed: \(message)"
    case .locked: return "The vault is locked."
    case .request(let message): return message
    }
  }
}

enum BitwardenSecretField: String, Sendable {
  case password
  case username
  case totp
  case notes
  case uri
}

protocol BitwardenCLIProviding: Sendable {
  func resolveExecutable(customPath: String?) throws -> String
  func status(executable: String, stateDirectory: URL) async throws -> BitwardenCLIStatus
  func configureServer(_ url: String, executable: String, stateDirectory: URL) async throws
  func login(clientID: String, clientSecret: String, executable: String, stateDirectory: URL) async throws
}

protocol BitwardenServeProviding: AnyObject, Sendable {
  func start(executable: String, stateDirectory: URL) async throws -> BitwardenServeClient
  func stop()
}

protocol BitwardenUnlockGating: Sendable {
  func confirmPresence() async -> Bool
}

struct SystemBitwardenCLI: BitwardenCLIProviding {
  func resolveExecutable(customPath: String?) throws -> String {
    try BitwardenCLI.resolveExecutable(customPath: customPath)
  }

  func status(executable: String, stateDirectory: URL) async throws -> BitwardenCLIStatus {
    try await BitwardenCLI(executable: executable, stateDirectory: stateDirectory).status()
  }

  func configureServer(_ url: String, executable: String, stateDirectory: URL) async throws {
    try await BitwardenCLI(executable: executable, stateDirectory: stateDirectory).configureServer(url)
  }

  func login(clientID: String, clientSecret: String, executable: String, stateDirectory: URL) async throws {
    try await BitwardenCLI(executable: executable, stateDirectory: stateDirectory)
      .login(clientID: clientID, clientSecret: clientSecret)
  }
}

final class SystemServeProvider: BitwardenServeProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var process: BitwardenServeProcess?

  func start(executable: String, stateDirectory: URL) async throws -> BitwardenServeClient {
    stop()
    let socketPath = try BitwardenPaths.socketPath()
    let process = BitwardenServeProcess(executable: executable, stateDirectory: stateDirectory, socketPath: socketPath)
    try await process.start()
    adopt(process)
    return BitwardenServeClient(transport: UnixSocketTransport(socketPath: socketPath))
  }

  func stop() {
    lock.lock()
    let running = process
    process = nil
    lock.unlock()
    running?.stop()
  }

  private func adopt(_ started: BitwardenServeProcess) {
    lock.lock()
    process = started
    lock.unlock()
  }
}

struct LocalAuthenticationGate: BitwardenUnlockGating {
  func confirmPresence() async -> Bool {
    let context = LAContext()
    context.localizedFallbackTitle = "Use Password"
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
    do {
      try await context.evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: "unlock your Bitwarden vault in Tuna")
      await restageBitwardenInTuna()
      return true
    } catch {
      await restageBitwardenInTuna()
      return false
    }
  }

  private func restageBitwardenInTuna() async {
    var components = URLComponents()
    components.scheme = "tuna"
    components.host = "stage"
    components.queryItems = [
      URLQueryItem(name: "subject", value: "\(BitwardenIdentifiers.catalog)/\(BitwardenIdentifiers.catalog)")
    ]
    guard let url = components.url else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try? await NSWorkspace.shared.open(url, configuration: configuration)
  }
}

final class BitwardenSystemEvents {
  private var tokens: [Any] = []

  init(onLock: @escaping @Sendable () -> Void, onTerminate: @escaping @Sendable () -> Void) {
    let workspace = NSWorkspace.shared.notificationCenter
    tokens.append(
      workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in onLock() })
    tokens.append(
      workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { _ in onLock() })
    tokens.append(
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in onLock() })
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in onTerminate() })
  }

  deinit {
    for token in tokens {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
      DistributedNotificationCenter.default().removeObserver(token)
      NotificationCenter.default.removeObserver(token)
    }
  }
}

extension BitwardenVault {
  func map(_ error: Error) -> BitwardenVaultError {
    if let vaultError = error as? BitwardenVaultError { return vaultError }
    if let serveError = error as? BitwardenServeError {
      switch serveError {
      case .vaultLocked:
        dropSession()
        setState(.locked)
        return .locked
      case .transport, .timedOut:
        dropSession()
        dropClient()
        setState(.locked)
        return .locked
      default:
        return .request(serveError.errorDescription ?? "Request failed")
      }
    }
    return .request(error.localizedDescription)
  }
}
