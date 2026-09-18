import Foundation
import TunaKit
import os

actor BitwardenVault {
  static let shared = BitwardenVault(
    settings: { try BitwardenSettings.current() }, cli: SystemBitwardenCLI(), serve: SystemServeProvider(),
    gate: LocalAuthenticationGate(), stateDirectory: BitwardenPaths.stateDirectory(),
    idleInterval: { TimeInterval($0 * 60) }, installSystemEvents: true)

  static let staleSyncInterval: TimeInterval = 5 * 60
  static let defaultPeriodicSyncInterval: TimeInterval = 30 * 60

  private let settings: @Sendable () throws -> BitwardenSettings.Values
  private let cli: BitwardenCLIProviding
  private let serve: BitwardenServeProviding
  private let gate: BitwardenUnlockGating
  private let stateDirectory: URL
  private let idleInterval: @Sendable (Int) -> TimeInterval
  private let periodicSyncInterval: TimeInterval

  private(set) var state: BitwardenVaultState = .idle
  private var observer: (@Sendable (BitwardenVaultState) -> Void)?
  private var client: BitwardenServeClient?
  private var cache: VaultSnapshot?
  private var prefs: Prefs?
  private var unlockTask: Task<VaultSnapshot, Error>?
  private var idleTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?
  private var systemEvents: BitwardenSystemEvents?
  private var generation: UInt64 = 0
  nonisolated let diagnostics = OSAllocatedUnfairLock(initialState: BitwardenVaultDiagnostics())

  init(
    settings: @escaping @Sendable () throws -> BitwardenSettings.Values, cli: BitwardenCLIProviding,
    serve: BitwardenServeProviding, gate: BitwardenUnlockGating, stateDirectory: URL,
    idleInterval: @escaping @Sendable (Int) -> TimeInterval,
    periodicSyncInterval: TimeInterval = BitwardenVault.defaultPeriodicSyncInterval,
    installSystemEvents: Bool
  ) {
    self.settings = settings
    self.cli = cli
    self.serve = serve
    self.gate = gate
    self.stateDirectory = stateDirectory
    self.idleInterval = idleInterval
    self.periodicSyncInterval = periodicSyncInterval
    if installSystemEvents {
      Task { await self.installEvents() }
    }
  }

  func setStateObserver(_ observer: @escaping @Sendable (BitwardenVaultState) -> Void) {
    self.observer = observer
  }

  func snapshot() async throws -> VaultSnapshot {
    if let cache, state == .unlocked {
      scheduleIdleLock()
      return cache
    }
    if let unlockTask { return try await unlockTask.value }
    let epoch = generation
    let task = Task { try await performUnlock(epoch: epoch) }
    unlockTask = task
    defer { unlockTask = nil }
    return try await task.value
  }

  func secret(_ field: BitwardenSecretField, id: String) async throws -> String {
    _ = try await snapshot()
    guard let client else { throw BitwardenVaultError.locked }
    do {
      return try await client.getString(field.rawValue, id: id)
    } catch {
      throw map(error)
    }
  }

  func generate(_ options: BitwardenGeneratorOptions) async throws -> String {
    _ = try await snapshot()
    guard let client else { throw BitwardenVaultError.locked }
    do {
      return try await client.generate(options)
    } catch {
      throw map(error)
    }
  }

  func sync() async throws {
    _ = try await snapshot()
    guard let client else { throw BitwardenVaultError.locked }
    let epoch = generation
    do {
      try await client.sync()
      let loaded = try await load(client)
      guard generation == epoch else { throw BitwardenVaultError.locked }
      cache = loaded
      publishDiagnostics(state: state, snapshot: loaded)
      setState(.unlocked)
    } catch {
      throw map(error)
    }
  }

  func lock() async {
    dropSession()
    if let client { await lockClient(client) }
    if state == .unlocked || state == .working { setState(.locked) }
  }

  func clipboardClearSeconds() -> Int {
    prefs?.clipboardClearSeconds ?? 30
  }

  nonisolated func stopServeNow() {
    serve.stop()
  }

  func shutdown() {
    dropSession()
    dropClient()
    setState(.locked)
  }

  private func performUnlock(epoch: UInt64) async throws -> VaultSnapshot {
    setState(.working)
    let values: BitwardenSettings.Values
    do {
      values = try settings()
    } catch {
      return try fail(.keychainDenied, .keychainDenied)
    }
    prefs = Prefs(idleLockMinutes: values.idleLockMinutes, clipboardClearSeconds: values.clipboardClearSeconds)
    let missing = BitwardenSettings.missingCredentialFields(in: values)
    guard missing.isEmpty else { return try fail(.unconfigured(missing), .unconfigured(missing)) }

    let executable: String
    do {
      executable = try cli.resolveExecutable(customPath: values.cliPath)
    } catch {
      return try fail(.cliMissing, .cliMissing)
    }

    if client == nil {
      do {
        let status = try await cli.status(executable: executable, stateDirectory: stateDirectory)
        if status.state == .unauthenticated {
          if let url = values.serverURL {
            try await cli.configureServer(url, executable: executable, stateDirectory: stateDirectory)
          }
          try await cli.login(
            clientID: values.clientID, clientSecret: values.clientSecret, executable: executable,
            stateDirectory: stateDirectory)
        }
      } catch {
        return try fail(.loginFailed(error.localizedDescription), .loginFailed(error.localizedDescription))
      }
      do {
        client = try await serve.start(executable: executable, stateDirectory: stateDirectory)
      } catch {
        return try fail(.serveFailed(error.localizedDescription), .serveFailed(error.localizedDescription))
      }
    }
    guard let client else { return try fail(.serveFailed("no client"), .serveFailed("no client")) }

    let status: ServeStatus
    do {
      status = try await client.status()
    } catch {
      dropClient()
      return try fail(.serveFailed(error.localizedDescription), .serveFailed(error.localizedDescription))
    }
    if status.state != .unlocked {
      guard await gate.confirmPresence() else { return try fail(.locked, .unlockCancelled) }
      guard generation == epoch else { throw BitwardenVaultError.locked }
      do {
        try await client.unlock(password: values.masterPassword)
      } catch {
        let message = (error as? BitwardenServeError)?.errorDescription ?? error.localizedDescription
        return try fail(.unlockFailed(message), .unlockFailed(message))
      }
    }
    if status.lastSync.map({ Date().timeIntervalSince($0) > Self.staleSyncInterval }) ?? true {
      try? await client.sync()
    }
    let snapshot: VaultSnapshot
    do {
      snapshot = try await load(client)
    } catch {
      let mapped = map(error)
      return try fail(mapped == .locked ? .locked : .serveFailed(mapped.localizedDescription), mapped)
    }
    guard generation == epoch else {
      await lockClient(client)
      throw BitwardenVaultError.locked
    }
    cache = snapshot
    setState(.unlocked)
    scheduleIdleLock()
    schedulePeriodicSync()
    return snapshot
  }

  private func load(_ client: BitwardenServeClient) async throws -> VaultSnapshot {
    let entries = try BitwardenModelDecoder.entries(from: try await client.list("items"))
    let folders = try BitwardenModelDecoder.folders(from: try await client.list("folders"))
    let collections = try BitwardenModelDecoder.collections(from: try await client.list("collections"))
    let organizations = try BitwardenModelDecoder.organizations(from: try await client.list("organizations"))
    let status = try? await client.status()
    return VaultSnapshot(
      entries: entries, folders: folders, collections: collections, organizations: organizations,
      lastSync: status?.lastSync ?? Date())
  }

  private func scheduleIdleLock() {
    idleTask?.cancel()
    let minutes = prefs?.idleLockMinutes ?? 15
    guard minutes > 0 else { return }
    let interval = idleInterval(minutes)
    idleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(interval))
      guard !Task.isCancelled else { return }
      await self?.lock()
    }
  }

  private func schedulePeriodicSync() {
    syncTask?.cancel()
    let interval = periodicSyncInterval
    syncTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self else { return }
        await self.refreshIfUnlocked()
      }
    }
  }

  private func refreshIfUnlocked() async {
    guard state == .unlocked, let client else { return }
    let epoch = generation
    do {
      try await client.sync()
      let loaded = try await load(client)
      guard generation == epoch else { return }
      cache = loaded
      publishDiagnostics(state: state, snapshot: loaded)
    } catch {
      _ = map(error)
    }
  }

  private func installEvents() {
    systemEvents = BitwardenSystemEvents(
      onLock: { Task { await BitwardenVault.shared.lock() } },
      onTerminate: {
        BitwardenVault.shared.stopServeNow()
        Task { await BitwardenVault.shared.shutdown() }
      })
  }

  func dropSession() {
    generation &+= 1
    idleTask?.cancel()
    syncTask?.cancel()
    cache = nil
  }

  func dropClient() {
    client = nil
    serve.stop()
  }

  private func lockClient(_ client: BitwardenServeClient) async {
    do {
      try await client.lock()
    } catch {
      dropClient()
    }
  }

  private func fail(_ newState: BitwardenVaultState, _ error: BitwardenVaultError) throws -> VaultSnapshot {
    setState(newState)
    throw error
  }

  func setState(_ newState: BitwardenVaultState) {
    guard state != newState else { return }
    state = newState
    publishDiagnostics(state: newState, snapshot: newState == .unlocked ? cache : nil)
    observer?(newState)
  }
}

private struct Prefs: Sendable {
  let idleLockMinutes: Int
  let clipboardClearSeconds: Int
}
