import XCTest

@testable import TunaBitwarden

final class BitwardenVaultTests: XCTestCase {
  func testUnconfiguredSettingsFailBeforeTouchingTheCLI() async {
    let cli = FakeCLI()
    let vault = VaultFixtures.makeVault(
      values: BitwardenSettings.Values(clientID: "", clientSecret: "s", masterPassword: "", serverURL: nil, idleLockMinutes: 15, clipboardClearSeconds: 30, cliPath: nil),
      cli: cli)
    await assertThrows(try await vault.snapshot(), .unconfigured(["API key client ID", "Master password"]))
    let state = await vault.state
    XCTAssertEqual(state, .unconfigured(["API key client ID", "Master password"]))
    XCTAssertTrue(cli.loginCalls.isEmpty)
  }

  func testKeychainDenialIsItsOwnState() async {
    let vault = VaultFixtures.makeVault(settingsError: BitwardenSettingsError.keychainAccessDenied)
    await assertThrows(try await vault.snapshot(), .keychainDenied)
  }

  func testMissingCLIIsReported() async {
    let cli = FakeCLI()
    cli.executable = nil
    let vault = VaultFixtures.makeVault(cli: cli)
    await assertThrows(try await vault.snapshot(), .cliMissing)
  }

  func testFirstRunLogsInThenUnlocksThenLoads() async throws {
    let cli = FakeCLI()
    cli.statusState = .unauthenticated
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let gate = FakeGate()
    var values = VaultFixtures.values
    values.serverURL = "https://vault.bitwarden.eu"
    let vault = VaultFixtures.makeVault(values: values, cli: cli, serve: serve, gate: gate)

    let snapshot = try await vault.snapshot()

    XCTAssertEqual(cli.serverCalls, ["https://vault.bitwarden.eu"])
    XCTAssertEqual(cli.loginCalls.map(\.0), ["user.id"])
    XCTAssertEqual(serve.startCount, 1)
    XCTAssertEqual(gate.prompts, 1)
    XCTAssertEqual(serve.transport.calls.map(\.target).filter { $0 == "/unlock" }.count, 1)
    XCTAssertTrue(serve.transport.calls.contains { $0.target == "/sync" })
    XCTAssertEqual(snapshot.entries.map(\.name), ["GitHub"])
    let state = await vault.state
    XCTAssertEqual(state, .unlocked)
  }

  func testSecondSnapshotUsesCacheWithoutPrompting() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let gate = FakeGate()
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate)
    _ = try await vault.snapshot()
    let listCalls = serve.transport.calls.filter { $0.target == "/list/object/items" }.count
    _ = try await vault.snapshot()
    XCTAssertEqual(gate.prompts, 1)
    XCTAssertEqual(serve.transport.calls.filter { $0.target == "/list/object/items" }.count, listCalls)
  }

  func testCancelledTouchIDLeavesVaultLockedWithoutSendingPassword() async {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let gate = FakeGate()
    gate.allow = false
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate)
    await assertThrows(try await vault.snapshot(), .unlockCancelled)
    XCTAssertFalse(serve.transport.calls.contains { $0.target == "/unlock" })
    let state = await vault.state
    XCTAssertEqual(state, .locked)
  }

  func testWrongMasterPasswordIsUnlockFailed() async {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    serve.transport.respond("/unlock", status: 400, body: #"{"success":false,"message":"Invalid master password."}"#)
    let vault = VaultFixtures.makeVault(serve: serve)
    await assertThrows(try await vault.snapshot(), .unlockFailed("Invalid master password."))
  }

  func testAlreadyUnlockedServeSkipsGateAndStaleSyncOnly() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport, status: ServeFixtures.unlockedStatus)
    let gate = FakeGate()
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate)
    _ = try await vault.snapshot()
    XCTAssertEqual(gate.prompts, 0)
    XCTAssertTrue(serve.transport.calls.contains { $0.target == "/sync" })
  }

  func testSecretIsFetchedOnDemand() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    serve.transport.respond("/object/password/i1", body: ServeFixtures.string("p4ss"))
    let vault = VaultFixtures.makeVault(serve: serve)
    let password = try await vault.secret(.password, id: "i1")
    XCTAssertEqual(password, "p4ss")
  }

  func testIdleTimerLocksAndDropsCache() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let vault = VaultFixtures.makeVault(serve: serve, idleSeconds: 0.2)
    _ = try await vault.snapshot()
    try await Task.sleep(for: .milliseconds(600))
    let state = await vault.state
    XCTAssertEqual(state, .locked)
    XCTAssertTrue(serve.transport.calls.contains { $0.target == "/lock" })
  }

  func testLockThenSnapshotPromptsAgain() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let gate = FakeGate()
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate)
    _ = try await vault.snapshot()
    await vault.lock()
    _ = try await vault.snapshot()
    XCTAssertEqual(gate.prompts, 2)
  }

  func testLoginFailureSurfacesMessage() async {
    let cli = FakeCLI()
    cli.statusState = .unauthenticated
    cli.loginError = BitwardenCLIError.commandFailed(command: "login", message: "Invalid client_secret.")
    let vault = VaultFixtures.makeVault(cli: cli)
    await assertThrows(try await vault.snapshot(), .loginFailed("bw login failed: Invalid client_secret."))
  }

  func testLockDuringUnlockNeverCommitsTheSnapshot() async {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    serve.transport.statefulStatus = true
    let gate = FakeGate()
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate)
    gate.onPrompt = { await vault.lock() }

    await assertThrows(try await vault.snapshot(), .locked)
    XCTAssertTrue(serve.transport.calls.filter { $0.target == "/unlock" }.isEmpty)
    let state = await vault.state
    XCTAssertEqual(state, .locked)

    gate.onPrompt = nil
    _ = try? await vault.snapshot()
    XCTAssertEqual(gate.prompts, 2)
  }

  func testPeriodicSyncLockDropsTheCacheAndRelocks() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let gate = FakeGate()
    let vault = VaultFixtures.makeVault(serve: serve, gate: gate, syncSeconds: 0.1)
    _ = try await vault.snapshot()
    serve.transport.respond("/sync", status: 400, body: ServeFixtures.vaultLocked)

    try await Task.sleep(for: .milliseconds(500))
    let state = await vault.state
    XCTAssertEqual(state, .locked)

    _ = try? await vault.snapshot()
    XCTAssertEqual(gate.prompts, 2)
  }

  func testTransportFailureLocksAndRestartsServeOnce() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let vault = VaultFixtures.makeVault(serve: serve)
    _ = try await vault.snapshot()
    serve.transport.fail("/object/password/i1", with: .transport("gone"))

    await assertThrows(try await vault.secret(.password, id: "i1"), .locked)
    XCTAssertEqual(serve.stopCount, 1)
    let state = await vault.state
    XCTAssertEqual(state, .locked)

    _ = try? await vault.snapshot()
    XCTAssertEqual(serve.startCount, 2)
  }

  func testFailedLockDropsTheServeSession() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let vault = VaultFixtures.makeVault(serve: serve)
    _ = try await vault.snapshot()
    serve.transport.respond("/lock", status: 400, body: #"{"success":false,"message":"boom"}"#)

    await vault.lock()
    XCTAssertEqual(serve.stopCount, 1)

    _ = try? await vault.snapshot()
    XCTAssertEqual(serve.startCount, 2)
  }

  func testStopServeNowStopsTheProcessWithoutAwaiting() async throws {
    let serve = FakeServe()
    VaultFixtures.primeUnlockedVault(serve.transport)
    let vault = VaultFixtures.makeVault(serve: serve)
    _ = try await vault.snapshot()
    vault.stopServeNow()
    XCTAssertEqual(serve.stopCount, 1)
  }

  private func assertThrows<T>(
    _ expression: @autoclosure () async throws -> T, _ expected: BitwardenVaultError,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await expression()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as BitwardenVaultError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("unexpected \(error)", file: file, line: line)
    }
  }
}
