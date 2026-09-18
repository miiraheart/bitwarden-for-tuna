import Network
import XCTest

@testable import TunaBitwarden

final class BitwardenHTTPTests: XCTestCase {
  func testGetRequestHasNoOriginAndClosesConnection() {
    let raw = BitwardenHTTP.request(method: "GET", path: "/generate", query: ["length": "20", "special": "true"])
    let text = String(decoding: raw, as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("GET /generate?length=20&special=true HTTP/1.1\r\n"))
    XCTAssertTrue(text.contains("\r\nHost: localhost\r\n"))
    XCTAssertTrue(text.contains("\r\nConnection: close\r\n"))
    XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    XCTAssertFalse(text.lowercased().contains("origin:"))
  }

  func testPostRequestCarriesJSONBodyWithLength() {
    let body = #"{"password":"p w"}"#.data(using: .utf8)!
    let raw = BitwardenHTTP.request(method: "POST", path: "/unlock", body: body)
    let text = String(decoding: raw, as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("POST /unlock HTTP/1.1\r\n"))
    XCTAssertTrue(text.contains("\r\nContent-Type: application/json\r\n"))
    XCTAssertTrue(text.contains("\r\nContent-Length: \(body.count)\r\n"))
    XCTAssertTrue(text.hasSuffix("\r\n\r\n" + #"{"password":"p w"}"#))
  }

  func testQueryValuesArePercentEncoded() {
    let raw = BitwardenHTTP.request(method: "GET", path: "/generate", query: ["separator": "a b&c"])
    XCTAssertTrue(String(decoding: raw, as: UTF8.self).hasPrefix("GET /generate?separator=a%20b%26c HTTP/1.1"))
  }

  func testParseContentLengthResponse() throws {
    let raw = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 46\r\nConnection: close\r\n\r\n{\"success\":false,\"message\":\"Vault is locked.\"}"
    let response = try BitwardenHTTP.parseResponse(raw.data(using: .utf8)!)
    XCTAssertEqual(response.statusCode, 400)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"success":false,"message":"Vault is locked."}"#)
  }

  func testParseChunkedResponse() throws {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n2\r\n1}\r\n0\r\n\r\n"
    let response = try BitwardenHTTP.parseResponse(raw.data(using: .utf8)!)
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"a":1}"#)
  }

  func testParseRejectsGarbage() {
    XCTAssertThrowsError(try BitwardenHTTP.parseResponse("nope".data(using: .utf8)!))
    XCTAssertThrowsError(try BitwardenHTTP.parseResponse("HTTP/1.1 abc\r\n\r\n".data(using: .utf8)!))
  }

  func testParseRejectsNegativeContentLength() {
    let raw = "HTTP/1.1 200 OK\r\nContent-Length: -1\r\nConnection: close\r\n\r\n{\"a\":1}"
    XCTAssertThrowsError(try BitwardenHTTP.parseResponse(raw.data(using: .utf8)!)) {
      XCTAssertEqual($0 as? BitwardenHTTPError, .malformedResponse)
    }
  }

  func testParseRejectsNegativeChunkSize() {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nAAAAA\r\n0\r\n\r\n"
    XCTAssertThrowsError(try BitwardenHTTP.parseResponse(raw.data(using: .utf8)!)) {
      XCTAssertEqual($0 as? BitwardenHTTPError, .malformedResponse)
    }
  }
}

final class BitwardenServeClientTests: XCTestCase {
  func testStatusDecodesTemplateEnvelope() async throws {
    let transport = FakeTransport()
    transport.respond("/status", body: ServeFixtures.unlockedStatus)
    let client = BitwardenServeClient(transport: transport)
    let status = try await client.status()
    XCTAssertEqual(status.state, .unlocked)
    XCTAssertEqual(status.serverURL, "https://vault.bitwarden.eu")
    XCTAssertEqual(status.userEmail, "me@example.com")
    XCTAssertNotNil(status.lastSync)
    XCTAssertEqual(transport.calls.first, FakeTransport.Call(method: "GET", target: "/status", body: ""))
  }

  func testLockedResponseBecomesVaultLockedError() async {
    let transport = FakeTransport()
    transport.respond("/list/object/items", status: 400, body: ServeFixtures.vaultLocked)
    let client = BitwardenServeClient(transport: transport)
    do {
      _ = try await client.list("items")
      XCTFail("expected vaultLocked")
    } catch let error as BitwardenServeError {
      XCTAssertEqual(error, .vaultLocked)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testUnlockPostsPasswordAsJSON() async throws {
    let transport = FakeTransport()
    transport.respond("/unlock", body: ServeFixtures.okMessage)
    let client = BitwardenServeClient(transport: transport)
    try await client.unlock(password: "hunter\"2")
    XCTAssertEqual(transport.calls.first?.method, "POST")
    XCTAssertEqual(transport.calls.first?.body, #"{"password":"hunter\"2"}"#)
  }

  func testGetStringAndGenerate() async throws {
    let transport = FakeTransport()
    transport.respond("/object/password/abc", body: ServeFixtures.string("s3cret"))
    transport.respond("/object/password/a%2Fb%20c", body: ServeFixtures.string("escaped"))
    transport.respond("/generate", body: ServeFixtures.string("Xy9!"))
    let client = BitwardenServeClient(transport: transport)
    let password = try await client.getString("password", id: "abc")
    XCTAssertEqual(password, "s3cret")
    let escaped = try await client.getString("password", id: "a/b c")
    XCTAssertEqual(escaped, "escaped")
    let generated = try await client.generate(.password)
    XCTAssertEqual(generated, "Xy9!")
    XCTAssertEqual(
      transport.calls.last?.target,
      "/generate?length=20&lowercase=true&number=true&special=true&uppercase=true")
  }

  func testPassphraseOptions() {
    XCTAssertEqual(
      BitwardenGeneratorOptions.passphrase.queryItems,
      ["passphrase": "true", "words": "4", "separator": "-", "capitalize": "true", "includeNumber": "true"])
  }

  func testFailureMessageSurfaces() async {
    let transport = FakeTransport()
    transport.respond("/object/totp/abc", status: 400, body: #"{"success":false,"message":"Premium status is required to use this feature."}"#)
    let client = BitwardenServeClient(transport: transport)
    do {
      _ = try await client.getString("totp", id: "abc")
      XCTFail("expected failure")
    } catch let error as BitwardenServeError {
      XCTAssertEqual(error, .requestFailed("Premium status is required to use this feature."))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testListReturnsInnerArray() async throws {
    let transport = FakeTransport()
    transport.respond("/list/object/folders", body: ServeFixtures.list(#"[{"object":"folder","id":"f1","name":"Work"}]"#))
    let client = BitwardenServeClient(transport: transport)
    let folders = try BitwardenModelDecoder.folders(from: try await client.list("folders"))
    XCTAssertEqual(folders, [VaultFolder(id: "f1", name: "Work")])
  }

  func testMissingSocketFailsFastWithTransportError() async {
    let transport = UnixSocketTransport(socketPath: ServeSocketPath.make(), timeout: 2)
    let clock = ContinuousClock()
    let started = clock.now
    do {
      _ = try await transport.send(Data("GET /status HTTP/1.1\r\n\r\n".utf8))
      XCTFail("expected a transport failure")
    } catch let error as BitwardenServeError {
      guard case .transport = error else { return XCTFail("unexpected \(error)") }
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(1500))
  }

  func testHungListenerSurfacesTimeout() async throws {
    let path = ServeSocketPath.make()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: path)
    let listener = try NWListener(using: parameters)
    let held = HeldConnections()
    listener.newConnectionHandler = { connection in
      held.hold(connection)
      connection.start(queue: .global())
    }
    listener.start(queue: .global())
    defer {
      listener.cancel()
      held.cancelAll()
      try? FileManager.default.removeItem(atPath: path)
    }
    try await waitForListener(listener, at: path)
    let transport = UnixSocketTransport(socketPath: path, timeout: 1)
    let clock = ContinuousClock()
    let started = clock.now
    do {
      _ = try await transport.send(Data("GET /status HTTP/1.1\r\n\r\n".utf8))
      XCTFail("expected timedOut")
    } catch let error as BitwardenServeError {
      XCTAssertEqual(error, .timedOut)
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
  }

  private func waitForListener(_ listener: NWListener, at path: String) async throws {
    for _ in 0..<200 {
      if case .ready = listener.state, FileManager.default.fileExists(atPath: path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw BitwardenServeError.transport("listener never bound \(path)")
  }
}

enum ServeSocketPath {
  static func make() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("bw-\(UUID().uuidString.prefix(8)).sock").path
  }
}

final class HeldConnections: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  func hold(_ connection: NWConnection) {
    lock.lock()
    connections.append(connection)
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    let all = connections
    connections = []
    lock.unlock()
    all.forEach { $0.cancel() }
  }
}

final class BitwardenPathsTests: XCTestCase {
  func testStateDirectoryLivesUnderApplicationSupportTuna() throws {
    let base = URL(fileURLWithPath: "/Users/x/Library/Application Support")
    let url = BitwardenPaths.stateDirectory(base: base)
    XCTAssertEqual(url.path, "/Users/x/Library/Application Support/Tuna/BitwardenExtension/cli-state")
  }

  func testSocketPathRejectsLongPaths() {
    let short = URL(fileURLWithPath: "/tmp")
    XCTAssertEqual(try BitwardenPaths.socketPath(temporaryDirectory: short), "/tmp/tuna-bitwarden/bw.sock")
    let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 120))
    XCTAssertThrowsError(try BitwardenPaths.socketPath(temporaryDirectory: long)) { error in
      guard case BitwardenServeProcessError.socketPathTooLong = error else { return XCTFail("wrong error \(error)") }
    }
  }

  func testPrepareDirectoryCreatesPrivateDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-paths-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("nested/dir")
    try BitwardenPaths.prepareDirectory(target)
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    XCTAssertEqual((attributes[.posixPermissions] as? Int), 0o700)
  }

  func testRemoveStaleSocketIgnoresMissingAndRemovesFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-sock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("bw.sock").path
    try BitwardenPaths.removeStaleSocket(at: path)
    FileManager.default.createFile(atPath: path, contents: Data())
    try BitwardenPaths.removeStaleSocket(at: path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testServeProcessFailsFastWhenExecutableExits() async {
    await expectExit(script: "echo 'You are not logged in.' >&2\nexit 1", message: "You are not logged in.")
  }

  func testServeProcessFailsWhenExecutableDiesAfterCreatingSocket() async {
    await expectExit(
      script: "touch \"$BW_FAKE_SOCKET\"\necho 'Socket opened then closed.' >&2\nexit 1",
      message: "Socket opened then closed.")
  }

  private func expectExit(
    script body: String, message: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-proc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let socketPath = root.appendingPathComponent("bw.sock").path
    let script = root.appendingPathComponent("fake-bw")
    try? "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    setenv("BW_FAKE_SOCKET", socketPath, 1)
    defer { unsetenv("BW_FAKE_SOCKET") }
    let process = BitwardenServeProcess(
      executable: script.path, stateDirectory: root.appendingPathComponent("state"), socketPath: socketPath)
    do {
      try await process.start()
      XCTFail("expected failure", file: file, line: line)
    } catch let error as BitwardenServeProcessError {
      guard case .exited(let text) = error else { return XCTFail("wrong error \(error)", file: file, line: line) }
      XCTAssertEqual(text, message, file: file, line: line)
    } catch {
      XCTFail("unexpected \(error)", file: file, line: line)
    }
    XCTAssertFalse(process.isRunning, file: file, line: line)
  }
}
