import XCTest

@testable import TunaBitwarden

final class BitwardenModelTests: XCTestCase {
  static let items = """
    [
      {"object":"item","id":"11111111-1111-1111-1111-111111111111","type":1,"name":"GitHub",
       "folderId":"f1","organizationId":null,"collectionIds":[],"favorite":true,"reprompt":0,
       "notes":"SECRET-NOTE","revisionDate":"2026-09-01T10:00:00.000Z","deletedDate":null,
       "login":{"username":"miira","password":"SECRET-PASS","totp":"otpauth://totp/x?secret=SECRET-TOTP",
                "uris":[{"uri":"androidapp://com.github.android"},{"uri":"https://github.com/login","match":null}]}},
      {"object":"item","id":"22222222-2222-2222-2222-222222222222","type":1,"name":"Bank",
       "folderId":null,"organizationId":"o1","collectionIds":["c1","c2"],"favorite":false,"reprompt":1,
       "revisionDate":"2026-08-01T10:00:00Z","login":{"username":"miira@bank","password":"SECRET-BANK","totp":null,"uris":[]}},
      {"object":"item","id":"33333333-3333-3333-3333-333333333333","type":2,"name":"Wifi",
       "folderId":"f1","favorite":false,"reprompt":0,"notes":"SECRET-WIFI","secureNote":{"type":0}},
      {"object":"item","id":"44444444-4444-4444-4444-444444444444","type":4,"name":"Me",
       "favorite":false,"reprompt":0,
       "identity":{"firstName":"Miira","lastName":"Heart","email":"me@example.com","username":"miira",
                   "phone":"+33 6","company":"","address1":"1 rue","address2":null,"city":"Lyon","postalCode":"69000","country":"FR"}},
      {"object":"item","id":"55555555-5555-5555-5555-555555555555","type":3,"name":"Visa","card":{"number":"4111"}},
      {"object":"item","id":"66666666-6666-6666-6666-666666666666","type":9,"name":"Future"},
      {"object":"item","id":"77777777-7777-7777-7777-777777777777","type":1,"name":"Trashed",
       "deletedDate":"2026-09-02T10:00:00.000Z","login":{"username":"x","password":"SECRET-TRASH"}}
    ]
    """.data(using: .utf8)!

  func testEntriesKeepMetadataAndSkipUnsupportedOrDeletedItems() throws {
    let entries = try BitwardenModelDecoder.entries(from: Self.items)
    XCTAssertEqual(entries.map(\.name), ["GitHub", "Bank", "Wifi", "Me"])

    let github = entries[0]
    XCTAssertEqual(github.kind, .login)
    XCTAssertEqual(github.username, "miira")
    XCTAssertEqual(github.uriHosts, ["com.github.android", "github.com"])
    XCTAssertEqual(github.websiteHost, "github.com")
    XCTAssertEqual(github.folderID, "f1")
    XCTAssertTrue(github.isFavorite)
    XCTAssertFalse(github.requiresReprompt)
    XCTAssertTrue(github.hasTotp)
    XCTAssertNotNil(github.revisionDate)

    let bank = entries[1]
    XCTAssertTrue(bank.requiresReprompt)
    XCTAssertFalse(bank.hasTotp)
    XCTAssertEqual(bank.collectionIDs, ["c1", "c2"])
    XCTAssertEqual(bank.organizationID, "o1")
    XCTAssertNotNil(bank.revisionDate)

    XCTAssertEqual(entries[2].kind, .secureNote)
    let me = entries[3]
    XCTAssertEqual(me.kind, .identity)
    XCTAssertEqual(me.identity?.fullName, "Miira Heart")
    XCTAssertEqual(me.identity?.email, "me@example.com")
    XCTAssertEqual(me.identity?.address, "1 rue, 69000 Lyon, FR")
    XCTAssertNil(me.identity?.company)
    XCTAssertEqual(me.identity?.labeled.map(\.label), ["Full Name", "Email", "Username", "Phone", "Address"])
  }

  func testDecodedModelsNeverCarrySecrets() throws {
    let entries = try BitwardenModelDecoder.entries(from: Self.items)
    let dump = String(describing: entries)
    XCTAssertFalse(dump.contains("SECRET"))
  }

  func testFoldersCollectionsOrganizations() throws {
    let folders = try BitwardenModelDecoder.folders(
      from: #"[{"object":"folder","id":"f1","name":"Work"},{"object":"folder","id":null,"name":"No Folder"}]"#.data(using: .utf8)!)
    XCTAssertEqual(folders, [VaultFolder(id: "f1", name: "Work")])

    let collections = try BitwardenModelDecoder.collections(
      from: #"[{"object":"collection","id":"c1","organizationId":"o1","name":"Shared","externalId":null}]"#.data(using: .utf8)!)
    XCTAssertEqual(collections, [VaultCollection(id: "c1", name: "Shared", organizationID: "o1")])

    let orgs = try BitwardenModelDecoder.organizations(
      from: #"[{"object":"organization","id":"o1","name":"Family","status":2,"type":0,"enabled":true}]"#.data(using: .utf8)!)
    XCTAssertEqual(orgs, [VaultOrganization(id: "o1", name: "Family")])
  }

  func testHostExtraction() {
    XCTAssertEqual(BitwardenModelDecoder.host(from: "https://Accounts.Google.com/signin"), "accounts.google.com")
    XCTAssertEqual(BitwardenModelDecoder.host(from: "example.com"), "example.com")
    XCTAssertEqual(BitwardenModelDecoder.host(from: "androidapp://com.x.y"), "com.x.y")
    XCTAssertNil(BitwardenModelDecoder.host(from: "   "))
  }

  func testDateParsingAcceptsFractionalAndWholeSeconds() {
    XCTAssertNotNil(BitwardenDates.parse("2026-09-01T10:00:00.000Z"))
    XCTAssertNotNil(BitwardenDates.parse("2026-09-01T10:00:00Z"))
    XCTAssertNil(BitwardenDates.parse("yesterday"))
    XCTAssertNil(BitwardenDates.parse(nil))
  }

  func testSnapshotFolderLookup() {
    let snapshot = VaultSnapshot(
      entries: [], folders: [VaultFolder(id: "f1", name: "Work")], collections: [], organizations: [],
      lastSync: nil)
    XCTAssertEqual(snapshot.folderName(for: "f1"), "Work")
    XCTAssertNil(snapshot.folderName(for: nil))
    XCTAssertNil(snapshot.folderName(for: "missing"))
  }

  func testAppOnlyLoginHasNoWebsiteHost() throws {
    let json = #"[{"object":"item","id":"99999999-9999-9999-9999-999999999999","type":1,"name":"App only","login":{"username":"miira","uris":[{"uri":"androidapp://com.example.app"}]}}]"#
    let entries = try BitwardenModelDecoder.entries(from: json.data(using: .utf8)!)
    XCTAssertEqual(entries.count, 1)
    XCTAssertNil(entries[0].websiteHost)
  }

  func testUnknownRepromptTypeStaysGuarded() throws {
    let json = #"[{"object":"item","id":"88888888-8888-8888-8888-888888888888","type":1,"name":"Future Gate","reprompt":2,"login":{"username":"miira"}}]"#
    let entries = try BitwardenModelDecoder.entries(from: json.data(using: .utf8)!)
    XCTAssertEqual(entries.count, 1)
    XCTAssertTrue(entries[0].requiresReprompt)
  }
}

final class BitwardenSearchTests: XCTestCase {
  private func entry(
    _ name: String, kind: BitwardenItemKind = .login, username: String? = nil, hosts: [String] = [], folder: String? = nil,
    favorite: Bool = false, identity: BitwardenIdentityFields? = nil
  ) -> VaultEntry {
    VaultEntry(
      id: name, kind: kind, name: name, username: username, uriHosts: hosts, websiteHost: hosts.first,
      folderID: folder, collectionIDs: [], organizationID: nil, isFavorite: favorite,
      requiresReprompt: false, hasTotp: false, revisionDate: nil, identity: identity)
  }

  func testRankingPrefersNameMatchesThenFieldsThenFavorites() {
    let snapshot = VaultSnapshot(
      entries: [
        entry("Gitea", username: "miira"),
        entry("GitHub", username: "miira", hosts: ["github.com"]),
        entry("Work mail", username: "me@github.com"),
        entry("Old GitHub", favorite: true),
        entry("Netflix"),
      ], folders: [VaultFolder(id: "f1", name: "GitHub stuff")], collections: [], organizations: [], lastSync: nil)
    let names = BitwardenSearch.rank(snapshot.entries, query: "github", snapshot: snapshot).map(\.name)
    XCTAssertEqual(names, ["GitHub", "Old GitHub", "Work mail"])
  }

  func testLoginsOutrankOtherKindsOnEqualScore() {
    let snapshot = VaultSnapshot(
      entries: [
        entry("GitHub notes", kind: .secureNote), entry("GitHub identity", kind: .identity), entry("GitHub login"),
      ], folders: [], collections: [], organizations: [], lastSync: nil)
    XCTAssertEqual(
      BitwardenSearch.rank(snapshot.entries, query: "github", snapshot: snapshot).map(\.name),
      ["GitHub login", "GitHub identity", "GitHub notes"])
  }

  func testKindPrefixSearchesOneKind() {
    let snapshot = VaultSnapshot(
      entries: [entry("GitHub"), entry("GitHub token", kind: .secureNote), entry("Me", kind: .identity)],
      folders: [], collections: [], organizations: [], lastSync: nil)
    func names(_ query: String) -> [String] { BitwardenSearch.rank(snapshot.entries, query: query, snapshot: snapshot).map(\.name) }
    XCTAssertEqual(names("n:github"), ["GitHub token"])
    XCTAssertEqual(names("login: github"), ["GitHub"])
    XCTAssertEqual(names("i:"), ["Me"])
    XCTAssertEqual(names("l:"), ["GitHub"])
    XCTAssertTrue(BitwardenSearch.kindFilter("https://github.com").kind == nil)
    XCTAssertEqual(BitwardenSearch.kindFilter("https://github.com").text, "https://github.com")
  }

  func testEveryTokenMustMatchSomewhere() {
    let snapshot = VaultSnapshot(
      entries: [entry("GitHub", username: "miira"), entry("GitLab", username: "other")],
      folders: [], collections: [], organizations: [], lastSync: nil)
    XCTAssertEqual(BitwardenSearch.rank(snapshot.entries, query: "git miira", snapshot: snapshot).map(\.name), ["GitHub"])
    XCTAssertEqual(BitwardenSearch.rank(snapshot.entries, query: "  ", snapshot: snapshot), [])
  }

  func testFolderNameMatchesAndLimitApplies() {
    let entries = (1...80).map { entry("Item \($0)", folder: "f1") }
    let snapshot = VaultSnapshot(entries: entries, folders: [VaultFolder(id: "f1", name: "Banking")], collections: [], organizations: [], lastSync: nil)
    XCTAssertEqual(BitwardenSearch.rank(entries, query: "banking", snapshot: snapshot).count, 60)
    XCTAssertEqual(BitwardenSearch.rank(entries, query: "banking", snapshot: snapshot, limit: 5).count, 5)
  }

  func testScoreConstantsPerBranch() {
    let identityEmail = BitwardenIdentityFields(
      fullName: nil, email: "me@github.com", username: nil, phone: nil, company: nil, address: nil)

    XCTAssertEqual(BitwardenSearch.score(entry("GitHub"), tokens: ["github"], folderName: nil), 100)
    XCTAssertEqual(BitwardenSearch.score(entry("GitHub desktop"), tokens: ["github"], folderName: nil), 60)
    XCTAssertEqual(BitwardenSearch.score(entry("Old GitHub"), tokens: ["github"], folderName: nil), 40)
    XCTAssertEqual(
      BitwardenSearch.score(entry("Work mail", username: "me@github.com"), tokens: ["github"], folderName: nil), 20)
    XCTAssertEqual(
      BitwardenSearch.score(entry("Work mail", identity: identityEmail), tokens: ["github"], folderName: nil), 20)
    XCTAssertEqual(
      BitwardenSearch.score(entry("Work mail", hosts: ["github.com"]), tokens: ["github"], folderName: nil), 20)
    XCTAssertEqual(
      BitwardenSearch.score(entry("Work mail"), tokens: ["github"], folderName: "GitHub stuff"), 10)
    XCTAssertEqual(BitwardenSearch.score(entry("GitHub", favorite: true), tokens: ["github"], folderName: nil), 115)
    XCTAssertEqual(BitwardenSearch.score(entry("GitHub"), tokens: ["github", "missing"], folderName: nil), 0)
  }
}
