import TunaKit
import XCTest

@testable import TunaBitwarden

@MainActor
final class BitwardenExtensionTests: XCTestCase {
  func testDeclarationKeepsVaultBehindOneLiveSearchRoot() throws {
    let instance = try BitwardenExtension(bundle: Bundle(for: BitwardenExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.catalogs.map(\.id), ["bitwarden"])
    XCTAssertEqual(declaration.catalogs.first?.presentation, .liveSearch)
    XCTAssertEqual(declaration.catalogs.first?.enabledByDefault, true)
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["bitwarden.actions"])
    let compatibility = try XCTUnwrap(declaration.compatibility)
    XCTAssertEqual(compatibility.minTuna, "0.96")
    XCTAssertEqual(compatibility.minTunaKit, "1.22.0")
    XCTAssertEqual(
      declaration.defaultActionRankings.map(\.typeID),
      [.bitwardenLogin, .bitwardenNote, .bitwardenCommand, .bitwardenGeneratedSecret])
    XCTAssertEqual(declaration.appBrowseEnrichments.first?.bundleIdentifiers, ["com.bitwarden.desktop"])
    XCTAssertEqual(declaration.appActionEnrichments.first?.bundleIdentifiers, ["com.bitwarden.desktop"])
    XCTAssertEqual(
      declaration.settings.map(\.key),
      ["ClientID", "ClientSecret", "MasterPassword", "ServerURL", "IdleLockMinutes", "ClipboardClearSeconds", "CLIPath"])
    XCTAssertEqual(declaration.settings.filter { $0.type == .secret }.map(\.key), ["ClientSecret", "MasterPassword"])
  }

  func testBrowsableTypesDescendFromSearchCatalogEntry() throws {
    let instance = try BitwardenExtension(bundle: Bundle(for: BitwardenExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    let parents = Dictionary(
      uniqueKeysWithValues: declaration.typeRegistrations.map { ($0.typeID, $0.inheritsFrom) })
    XCTAssertEqual(parents[.bitwardenGroup], [.searchCatalogEntry])
    XCTAssertEqual(parents[.bitwardenFolder], [.searchCatalogEntry])
    XCTAssertEqual(parents[.bitwardenCollection], [.searchCatalogEntry])
    XCTAssertEqual(parents[.bitwardenIdentity], [.bitwardenItem, .searchCatalogEntry])
    XCTAssertEqual(parents[.bitwardenItem], [.entity])
  }

  func testMissingCredentialFieldsNamesEveryEmptyCredential() {
    let empty = BitwardenSettings.Values(
      clientID: "", clientSecret: "", masterPassword: "", serverURL: nil, idleLockMinutes: 15,
      clipboardClearSeconds: 30, cliPath: nil)
    XCTAssertEqual(
      BitwardenSettings.missingCredentialFields(in: empty),
      ["API key client ID", "API key client secret", "Master password"])

    let complete = BitwardenSettings.Values(
      clientID: "user.abc", clientSecret: "s", masterPassword: "p", serverURL: nil, idleLockMinutes: 15,
      clipboardClearSeconds: 30, cliPath: nil)
    XCTAssertEqual(BitwardenSettings.missingCredentialFields(in: complete), [])
  }

  func testIntegerSettingFallsBackOnGarbage() {
    XCTAssertEqual(BitwardenSettings.integer("abc", default: 15), 15)
    XCTAssertEqual(BitwardenSettings.integer("-3", default: 15), 15)
    XCTAssertEqual(BitwardenSettings.integer(" 0 ", default: 15), 0)
    XCTAssertEqual(BitwardenSettings.integer("45", default: 15), 45)
  }
}
