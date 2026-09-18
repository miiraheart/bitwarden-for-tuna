import XCTest

@testable import TunaBitwarden

final class BitwardenCLITests: XCTestCase {
  func testStatusParsingHandlesNullServer() throws {
    let json = #"{"serverUrl":null,"lastSync":"2026-02-04T14:53:27.986Z","userEmail":"x@y","userId":"u","status":"locked"}"#
    let status = try BitwardenCLIStatus.parse(json.data(using: .utf8)!)
    XCTAssertEqual(status.state, .locked)
    XCTAssertNil(status.serverURL)
    XCTAssertNotNil(status.lastSync)
  }

  func testStatusParsingRejectsUnknownState() {
    XCTAssertThrowsError(try BitwardenCLIStatus.parse(#"{"status":"weird"}"#.data(using: .utf8)!))
  }

  func testResolveExecutablePrefersValidCustomPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("bw").path
    FileManager.default.createFile(atPath: custom, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    XCTAssertEqual(try BitwardenCLI.resolveExecutable(customPath: custom, candidates: [], which: { _ in nil }), custom)
    XCTAssertThrowsError(try BitwardenCLI.resolveExecutable(customPath: root.appendingPathComponent("missing").path, candidates: [custom], which: { _ in nil })) { error in
      guard case BitwardenCLIError.invalidCustomPath = error else { return XCTFail("wrong error \(error)") }
    }
    XCTAssertEqual(try BitwardenCLI.resolveExecutable(customPath: nil, candidates: ["/nope/bw", custom], which: { _ in nil }), custom)
    XCTAssertEqual(try BitwardenCLI.resolveExecutable(customPath: nil, candidates: [], which: { _ in custom }), custom)
    XCTAssertThrowsError(try BitwardenCLI.resolveExecutable(customPath: nil, candidates: [], which: { _ in nil })) { error in
      guard case BitwardenCLIError.notInstalled = error else { return XCTFail("wrong error \(error)") }
    }
  }

  func testLoginPreparesPrivateStateDirectoryAndKeepsSecretsOffArgv() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dump = root.appendingPathComponent("dump.txt").path
    let script = root.appendingPathComponent("fake-bw")
    let body = """
      #!/bin/sh
      {
        echo "argv=$*"
        echo "dir=$BITWARDENCLI_APPDATA_DIR"
        echo "nointeraction=$BW_NOINTERACTION"
        echo "id=$BW_CLIENTID"
        echo "secret=$BW_CLIENTSECRET"
      } > "\(dump)"
      exit 0
      """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let state = root.appendingPathComponent("state")
    try await BitwardenCLI(executable: script.path, stateDirectory: state).login(clientID: "id", clientSecret: "sec")

    let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
    XCTAssertEqual((attributes[.posixPermissions] as? Int), 0o700)
    let lines = try String(contentsOfFile: dump, encoding: .utf8).split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "argv=login --apikey")
    XCTAssertFalse(lines.first?.contains("sec") ?? true)
    XCTAssertTrue(lines.contains("dir=\(state.path)"))
    XCTAssertTrue(lines.contains("nointeraction=true"))
    XCTAssertTrue(lines.contains("id=id"))
    XCTAssertTrue(lines.contains("secret=sec"))
  }
}

@MainActor
final class BitwardenClipboardTests: XCTestCase {
  func testSecretIsConcealedAndClearedOnlyIfUntouched() {
    let pasteboard = FakePasteboard()
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    let clipboard = BitwardenClipboard(pasteboard: pasteboard) { delay, work in scheduled.append((delay, work)) }

    XCTAssertTrue(clipboard.copySecret("s3cret", clearAfter: 30))
    XCTAssertEqual(pasteboard.contents, "s3cret")
    XCTAssertTrue(pasteboard.concealed)
    XCTAssertEqual(scheduled.first?.0, 30)

    scheduled.first?.1()
    XCTAssertNil(pasteboard.contents)
  }

  func testClearSkipsWhenSomethingElseWasCopied() {
    let pasteboard = FakePasteboard()
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    let clipboard = BitwardenClipboard(pasteboard: pasteboard) { delay, work in scheduled.append((delay, work)) }

    _ = clipboard.copySecret("s3cret", clearAfter: 30)
    _ = pasteboard.write("something else", concealed: false)
    scheduled.first?.1()
    XCTAssertEqual(pasteboard.contents, "something else")
  }

  func testZeroDelayNeverSchedulesAndPlainTextIsNotConcealed() {
    let pasteboard = FakePasteboard()
    var scheduled = 0
    let clipboard = BitwardenClipboard(pasteboard: pasteboard) { _, _ in scheduled += 1 }
    _ = clipboard.copySecret("s3cret", clearAfter: 0)
    _ = clipboard.copyText("plain")
    XCTAssertEqual(scheduled, 0)
    XCTAssertEqual(pasteboard.contents, "plain")
    XCTAssertFalse(pasteboard.concealed)
  }
}
