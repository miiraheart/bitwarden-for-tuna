import Foundation

enum BitwardenServeProcessError: LocalizedError, Equatable {
  case socketPathTooLong(Int)
  case startFailed(String)
  case exited(String)
  case socketNeverAppeared

  var errorDescription: String? {
    switch self {
    case .socketPathTooLong(let length):
      return "The socket path is \(length) characters; macOS allows about 100."
    case .startFailed(let message): return "Could not start the Bitwarden CLI: \(message)"
    case .exited(let message): return message.isEmpty ? "The Bitwarden CLI stopped unexpectedly." : message
    case .socketNeverAppeared: return "The Bitwarden CLI started but never opened its socket."
    }
  }
}

enum BitwardenPaths {
  static let maxSocketPathLength = 100

  static func stateDirectory(
    base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  ) -> URL {
    base.appendingPathComponent("Tuna/BitwardenExtension/cli-state", isDirectory: true)
  }

  static func socketPath(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> String {
    let path = temporaryDirectory.appendingPathComponent("tuna-bitwarden/bw.sock").path
    guard path.utf8.count <= maxSocketPathLength else {
      throw BitwardenServeProcessError.socketPathTooLong(path.utf8.count)
    }
    return path
  }

  static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  static func removeStaleSocket(at path: String, fileManager: FileManager = .default) throws {
    guard fileManager.fileExists(atPath: path) else { return }
    try fileManager.removeItem(atPath: path)
  }

  static func restrictSocket(at path: String, fileManager: FileManager = .default) throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }
}

final class BitwardenServeProcess: @unchecked Sendable {
  private let executable: String
  private let stateDirectory: URL
  private let socketPath: String
  private let lock = NSLock()
  private var process: Process?
  private var stderrLine: String?

  init(executable: String, stateDirectory: URL, socketPath: String) {
    self.executable = executable
    self.stateDirectory = stateDirectory
    self.socketPath = socketPath
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return process?.isRunning ?? false
  }

  var lastStderrLine: String? {
    lock.lock()
    defer { lock.unlock() }
    return stderrLine
  }

  func start() async throws {
    stop()
    try BitwardenPaths.prepareDirectory(stateDirectory)
    try BitwardenPaths.prepareDirectory(URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    try BitwardenPaths.removeStaleSocket(at: socketPath)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = ["serve", "--hostname", "unix://\(socketPath)"]
    var environment = ProcessInfo.processInfo.environment
    environment["BITWARDENCLI_APPDATA_DIR"] = stateDirectory.path
    environment["BW_NOINTERACTION"] = "true"
    child.environment = environment
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    let stderr = Pipe()
    child.standardError = stderr
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      let text = String(decoding: data, as: UTF8.self)
      let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
      guard let last = lines.last, let self else { return }
      self.lock.lock()
      self.stderrLine = last
      self.lock.unlock()
    }
    adopt(child)
    do {
      try child.run()
    } catch {
      release(child)
      throw BitwardenServeProcessError.startFailed(error.localizedDescription)
    }
    guard isAdopted(child) else {
      if child.isRunning { child.terminate() }
      throw BitwardenServeProcessError.startFailed("stopped during start")
    }

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if !child.isRunning {
        throw await exitError(stderr)
      }
      if FileManager.default.fileExists(atPath: socketPath) {
        if !child.isRunning {
          throw await exitError(stderr)
        }
        try BitwardenPaths.restrictSocket(at: socketPath)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    stop()
    throw BitwardenServeProcessError.socketNeverAppeared
  }

  private func adopt(_ child: Process) {
    lock.lock()
    process = child
    stderrLine = nil
    lock.unlock()
  }

  private func release(_ child: Process) {
    lock.lock()
    if process === child { process = nil }
    lock.unlock()
  }

  private func isAdopted(_ child: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return process === child
  }

  private func exitError(_ stderr: Pipe) async -> BitwardenServeProcessError {
    try? await Task.sleep(for: .milliseconds(150))
    stderr.fileHandleForReading.readabilityHandler = nil
    return .exited(lastStderrLine ?? "")
  }

  func stop() {
    lock.lock()
    let child = process
    process = nil
    lock.unlock()
    guard let child, child.isRunning else { return }
    child.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    try? BitwardenPaths.removeStaleSocket(at: socketPath)
  }

  deinit {
    stop()
  }
}
