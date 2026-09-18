import Foundation
import Network

enum BitwardenServeError: LocalizedError, Equatable {
  case vaultLocked
  case notLoggedIn
  case requestFailed(String)
  case transport(String)
  case timedOut
  case malformed

  var errorDescription: String? {
    switch self {
    case .vaultLocked: return "The vault is locked."
    case .notLoggedIn: return "The Bitwarden CLI is not logged in."
    case .requestFailed(let message): return message
    case .transport(let message): return "Could not reach the Bitwarden CLI: \(message)"
    case .timedOut: return "The Bitwarden CLI did not answer in time."
    case .malformed: return "The Bitwarden CLI returned an unexpected answer."
    }
  }
}

struct ServeStatus: Equatable, Sendable {
  enum State: String, Sendable {
    case unauthenticated
    case locked
    case unlocked
  }

  let state: State
  let lastSync: Date?
  let serverURL: String?
  let userEmail: String?
}

enum BitwardenServeEnvelope {
  static func check(_ response: BitwardenHTTPResponse) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
      throw BitwardenServeError.malformed
    }
    if object["success"] as? Bool == true, response.statusCode < 400 { return object }
    let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch message {
    case "Vault is locked.": throw BitwardenServeError.vaultLocked
    case "You are not logged in.": throw BitwardenServeError.notLoggedIn
    default: throw BitwardenServeError.requestFailed(message.isEmpty ? "HTTP \(response.statusCode)" : message)
    }
  }

  static func string(from response: BitwardenHTTPResponse) throws -> String {
    let object = try check(response)
    guard let data = object["data"] as? [String: Any], let value = data["data"] as? String else {
      throw BitwardenServeError.malformed
    }
    return value
  }

  static func list(from response: BitwardenHTTPResponse) throws -> Data {
    let object = try check(response)
    guard let data = object["data"] as? [String: Any], let array = data["data"] as? [Any] else {
      throw BitwardenServeError.malformed
    }
    return try JSONSerialization.data(withJSONObject: array)
  }

  static func status(from response: BitwardenHTTPResponse) throws -> ServeStatus {
    let object = try check(response)
    guard let data = object["data"] as? [String: Any], let template = data["template"] as? [String: Any],
      let rawState = template["status"] as? String, let state = ServeStatus.State(rawValue: rawState)
    else { throw BitwardenServeError.malformed }
    return ServeStatus(
      state: state,
      lastSync: BitwardenDates.parse(template["lastSync"] as? String),
      serverURL: template["serverUrl"] as? String,
      userEmail: template["userEmail"] as? String)
  }
}

protocol BitwardenServeTransport: Sendable {
  func send(_ request: Data) async throws -> Data
}

struct UnixSocketTransport: BitwardenServeTransport {
  let socketPath: String
  var timeout: TimeInterval = 15

  func send(_ request: Data) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await exchange(request) }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw BitwardenServeError.timedOut
      }
      let result = try await group.next() ?? Data()
      group.cancelAll()
      return result
    }
  }

  private func exchange(_ request: Data) async throws -> Data {
    let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    let queue = DispatchQueue(label: "com.brnbw.tuna.plugins.bitwarden.socket")
    let resumed = LockedFlag()
    defer { connection.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            if resumed.set() { continuation.resume() }
          case .waiting(let error):
            if resumed.set() { continuation.resume(throwing: BitwardenServeError.transport(error.localizedDescription)) }
          case .failed(let error):
            if resumed.set() { continuation.resume(throwing: BitwardenServeError.transport(error.localizedDescription)) }
          case .cancelled:
            if resumed.set() { continuation.resume(throwing: BitwardenServeError.transport("cancelled")) }
          default:
            break
          }
        }
        connection.start(queue: queue)
        if Task.isCancelled, resumed.set() {
          connection.cancel()
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      connection.cancel()
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: request, completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: BitwardenServeError.transport(error.localizedDescription)) }
          else { continuation.resume() }
        })
      }
    } onCancel: {
      connection.cancel()
    }
    var received = Data()
    while true {
      let (chunk, complete): (Data?, Bool) = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
          connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let error { continuation.resume(throwing: BitwardenServeError.transport(error.localizedDescription)) }
            else { continuation.resume(returning: (data, isComplete)) }
          }
        }
      } onCancel: {
        connection.cancel()
      }
      if let chunk { received.append(chunk) }
      if complete || chunk == nil { break }
    }
    return received
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if value { return false }
    value = true
    return true
  }
}

struct BitwardenGeneratorOptions: Equatable, Sendable {
  let queryItems: [String: String]

  static let password = BitwardenGeneratorOptions(queryItems: [
    "length": "20", "uppercase": "true", "lowercase": "true", "number": "true", "special": "true",
  ])
  static let passphrase = BitwardenGeneratorOptions(queryItems: [
    "passphrase": "true", "words": "4", "separator": "-", "capitalize": "true", "includeNumber": "true",
  ])
}

actor BitwardenServeClient {
  private let transport: BitwardenServeTransport

  init(transport: BitwardenServeTransport) {
    self.transport = transport
  }

  func status() async throws -> ServeStatus {
    try BitwardenServeEnvelope.status(from: try await perform("GET", "/status"))
  }

  func unlock(password: String) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["password": password])
    _ = try BitwardenServeEnvelope.check(try await perform("POST", "/unlock", body: body))
  }

  func lock() async throws {
    _ = try BitwardenServeEnvelope.check(try await perform("POST", "/lock"))
  }

  func sync() async throws {
    _ = try BitwardenServeEnvelope.check(try await perform("POST", "/sync"))
  }

  func list(_ object: String) async throws -> Data {
    try BitwardenServeEnvelope.list(from: try await perform("GET", "/list/object/\(object)"))
  }

  func getString(_ object: String, id: String) async throws -> String {
    try BitwardenServeEnvelope.string(from: try await perform("GET", "/object/\(object)/\(BitwardenHTTP.percentEncode(id))"))
  }

  func generate(_ options: BitwardenGeneratorOptions) async throws -> String {
    try BitwardenServeEnvelope.string(from: try await perform("GET", "/generate", query: options.queryItems))
  }

  private func perform(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil)
    async throws -> BitwardenHTTPResponse
  {
    let request = BitwardenHTTP.request(method: method, path: path, query: query, body: body)
    let raw = try await transport.send(request)
    return try BitwardenHTTP.parseResponse(raw)
  }
}
