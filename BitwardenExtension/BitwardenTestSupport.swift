import Foundation
import XCTest

@testable import TunaBitwarden

final class FakeTransport: BitwardenServeTransport, @unchecked Sendable {
  struct Call: Equatable {
    let method: String
    let target: String
    let body: String
  }

  private let lock = NSLock()
  private var responses: [String: (Int, String)] = [:]
  private var failures: [String: BitwardenServeError] = [:]
  private var recorded: [Call] = []
  private var statefulStatusEnabled = false
  private var serveUnlocked = false

  var calls: [Call] { recordedCalls() }

  var statefulStatus: Bool {
    get { statefulStatusFlag() }
    set { setStatefulStatus(newValue) }
  }

  func respond(_ target: String, status: Int = 200, body: String) {
    lock.lock()
    responses[target] = (status, body)
    lock.unlock()
  }

  func fail(_ target: String, with error: BitwardenServeError) {
    lock.lock()
    failures[target] = error
    lock.unlock()
  }

  func send(_ request: Data) async throws -> Data {
    let text = String(decoding: request, as: UTF8.self)
    let requestLine = text.components(separatedBy: "\r\n").first ?? ""
    let parts = requestLine.split(separator: " ")
    let method = parts.count > 0 ? String(parts[0]) : ""
    let target = parts.count > 1 ? String(parts[1]) : ""
    let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    switch record(Call(method: method, target: target, body: body)) {
    case .thrown(let error):
      throw error
    case .response(let status, let payload):
      let reason = status == 200 ? "OK" : "Bad Request"
      return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)".utf8)
    }
  }

  private enum Outcome {
    case response(Int, String)
    case thrown(BitwardenServeError)
  }

  private func record(_ call: Call) -> Outcome {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(call)
    if let error = failures[call.target] { return .thrown(error) }
    if statefulStatusEnabled {
      switch call.target {
      case "/unlock": serveUnlocked = true
      case "/lock": serveUnlocked = false
      case "/status": return .response(200, serveUnlocked ? ServeFixtures.unlockedStatus : ServeFixtures.lockedStatus)
      default: break
      }
    }
    guard let found = responses[call.target] ?? responses[call.target.components(separatedBy: "?").first ?? call.target]
    else { return .thrown(.transport("no fake response for \(call.target)")) }
    return .response(found.0, found.1)
  }

  private func statefulStatusFlag() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return statefulStatusEnabled
  }

  private func setStatefulStatus(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    statefulStatusEnabled = enabled
  }

  private func recordedCalls() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

enum ServeFixtures {
  static let lockedStatus = #"{"success":true,"data":{"object":"template","template":{"serverUrl":null,"lastSync":"2026-09-18T10:00:00.000Z","userEmail":"me@example.com","userId":"u1","status":"locked"}}}"#
  static let unlockedStatus = #"{"success":true,"data":{"object":"template","template":{"serverUrl":"https://vault.bitwarden.eu","lastSync":"2026-09-18T10:00:00.000Z","userEmail":"me@example.com","userId":"u1","status":"unlocked"}}}"#
  static let vaultLocked = #"{"success":false,"message":"Vault is locked."}"#
  static let okMessage = #"{"success":true,"data":{"object":"message","noColor":false,"title":"done","message":null}}"#
  static func string(_ value: String) -> String {
    #"{"success":true,"data":{"object":"string","data":"\#(value)"}}"#
  }
  static func list(_ arrayJSON: String) -> String {
    #"{"success":true,"data":{"object":"list","data":\#(arrayJSON)}}"#
  }
}

final class FakePasteboard: BitwardenPasteboard {
  var changeCount = 0
  var contents: String?
  var concealed = false

  func write(_ string: String, concealed: Bool) -> Bool {
    changeCount += 1
    contents = string
    self.concealed = concealed
    return true
  }

  func clear() {
    changeCount += 1
    contents = nil
    concealed = false
  }
}

final class FakeCLI: BitwardenCLIProviding, @unchecked Sendable {
  var executable: String? = "/fake/bw"
  var statusState: ServeStatus.State = .locked
  var loginError: Error?
  private(set) var loginCalls: [(String, String)] = []
  private(set) var serverCalls: [String] = []

  func resolveExecutable(customPath: String?) throws -> String {
    guard let executable else { throw BitwardenCLIError.notInstalled }
    return executable
  }

  func status(executable: String, stateDirectory: URL) async throws -> BitwardenCLIStatus {
    BitwardenCLIStatus(state: statusState, serverURL: nil, lastSync: nil)
  }

  func configureServer(_ url: String, executable: String, stateDirectory: URL) async throws {
    serverCalls.append(url)
  }

  func login(clientID: String, clientSecret: String, executable: String, stateDirectory: URL) async throws {
    loginCalls.append((clientID, clientSecret))
    if let loginError { throw loginError }
    statusState = .locked
  }
}

final class FakeServe: BitwardenServeProviding, @unchecked Sendable {
  let transport = FakeTransport()
  var startError: Error?
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func start(executable: String, stateDirectory: URL) async throws -> BitwardenServeClient {
    startCount += 1
    if let startError { throw startError }
    return BitwardenServeClient(transport: transport)
  }

  func stop() {
    stopCount += 1
  }
}

final class FakeGate: BitwardenUnlockGating, @unchecked Sendable {
  var allow = true
  var onPrompt: (@Sendable () async -> Void)?
  private(set) var prompts = 0

  func confirmPresence() async -> Bool {
    prompts += 1
    await onPrompt?()
    return allow
  }
}

enum VaultFixtures {
  static let values = BitwardenSettings.Values(
    clientID: "user.id", clientSecret: "secret", masterPassword: "master", serverURL: nil,
    idleLockMinutes: 15, clipboardClearSeconds: 30, cliPath: nil)

  static let itemsJSON = #"[{"object":"item","id":"i1","type":1,"name":"GitHub","favorite":true,"reprompt":0,"login":{"username":"miira","password":"x","totp":"otpauth://x","uris":[{"uri":"https://github.com"}]}}]"#

  static func primeUnlockedVault(_ transport: FakeTransport, status: String = ServeFixtures.lockedStatus) {
    transport.respond("/status", body: status)
    transport.respond("/unlock", body: ServeFixtures.okMessage)
    transport.respond("/lock", body: ServeFixtures.okMessage)
    transport.respond("/sync", body: ServeFixtures.okMessage)
    transport.respond("/list/object/items", body: ServeFixtures.list(itemsJSON))
    transport.respond("/list/object/folders", body: ServeFixtures.list("[]"))
    transport.respond("/list/object/collections", body: ServeFixtures.list("[]"))
    transport.respond("/list/object/organizations", body: ServeFixtures.list("[]"))
  }

  static func makeVault(
    values: BitwardenSettings.Values = values, settingsError: Error? = nil, cli: FakeCLI = FakeCLI(),
    serve: FakeServe = FakeServe(), gate: FakeGate = FakeGate(), idleSeconds: TimeInterval? = nil,
    syncSeconds: TimeInterval? = nil
  ) -> BitwardenVault {
    BitwardenVault(
      settings: { if let settingsError { throw settingsError }; return values },
      cli: cli, serve: serve, gate: gate,
      stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("bw-vault-tests"),
      idleInterval: { minutes in idleSeconds ?? TimeInterval(minutes * 60) },
      periodicSyncInterval: syncSeconds ?? BitwardenVault.defaultPeriodicSyncInterval,
      installSystemEvents: false)
  }
}
