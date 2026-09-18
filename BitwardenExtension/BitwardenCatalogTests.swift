import TunaKit
import XCTest

@testable import TunaBitwarden

@MainActor
final class BitwardenItemTests: XCTestCase {
  static let snapshot: VaultSnapshot = {
    let items = try! BitwardenModelDecoder.entries(from: BitwardenModelTests.items)
    return VaultSnapshot(
      entries: items, folders: [VaultFolder(id: "f1", name: "Work")],
      collections: [VaultCollection(id: "c1", name: "Shared", organizationID: "o1")],
      organizations: [VaultOrganization(id: "o1", name: "Family")], lastSync: nil)
  }()

  func testLoginItemShowsUsernameAndHostNeverSecrets() throws {
    let github = try XCTUnwrap(Self.snapshot.entries.first { $0.name == "GitHub" })
    let item = try XCTUnwrap(BitwardenItems.item(for: github, snapshot: Self.snapshot) as? BitwardenLoginItem)
    XCTAssertEqual(item.id, github.id)
    XCTAssertEqual(item.typeID, .bitwardenLogin)
    XCTAssertEqual(item.detail, "miira \u{00B7} com.github.android")
    XCTAssertEqual(item.searchText, "GitHub miira com.github.android github.com Work")
    XCTAssertFalse(item is TextValueProviding)
  }

  func testNoteAndIdentityItems() throws {
    let wifi = try XCTUnwrap(Self.snapshot.entries.first { $0.name == "Wifi" })
    let note = try XCTUnwrap(BitwardenItems.item(for: wifi, snapshot: Self.snapshot) as? BitwardenNoteItem)
    XCTAssertEqual(note.typeID, .bitwardenNote)
    XCTAssertEqual(note.detail, "Work")

    let me = try XCTUnwrap(Self.snapshot.entries.first { $0.name == "Me" })
    let identity = try XCTUnwrap(BitwardenItems.item(for: me, snapshot: Self.snapshot) as? BitwardenIdentityItem)
    XCTAssertEqual(identity.typeID, .bitwardenIdentity)
    XCTAssertEqual(identity.detail, "me@example.com")
    let fields = identity.hierarchyChildren().compactMap { $0 as? BitwardenIdentityFieldItem }
    XCTAssertEqual(fields.map(\.title), ["Full Name", "Email", "Username", "Phone", "Address"])
    XCTAssertEqual(fields.first?.textValue, "Miira Heart")
    XCTAssertEqual(fields.first?.typeID, .bitwardenIdentityField)
    XCTAssertEqual(fields.first?.id, "\(me.id):Full Name")
  }

  func testGeneratedSecretAndCommandItems() {
    let generated = BitwardenGeneratedSecretItem(value: "Xy9!", kind: .password)
    XCTAssertEqual(generated.textValue, "Xy9!")
    XCTAssertEqual(generated.title, "Xy9!")
    XCTAssertEqual(generated.typeID, .bitwardenGeneratedSecret)
    XCTAssertEqual(generated.searchText, "")

    let lock = BitwardenCommandItem(command: .lockVault, detail: nil)
    XCTAssertEqual(lock.id, "bitwarden.command.lock")
    XCTAssertEqual(lock.title, "Lock Vault")
    XCTAssertEqual(lock.typeID, .bitwardenCommand)
    XCTAssertEqual(BitwardenCommandItem(command: .generatePassphrase, detail: nil).title, "Generate Passphrase")
  }

  func testGroupItemListsChildren() {
    let child = BitwardenCommandItem(command: .syncVault, detail: nil)
    let group = BitwardenGroupItem(
      title: "Favorites", id: "bitwarden.group.favorites", detail: "1 item", symbolName: "star.fill",
      color: .yellow, children: [child], typeID: .bitwardenGroup)
    XCTAssertEqual(group.hierarchyChildren().map(\.id), ["bitwarden.command.sync"])
    XCTAssertEqual(group.detail, "1 item")
  }
}

@MainActor
final class BitwardenTreeTests: XCTestCase {
  func testRootChildrenOrderAndCounts() {
    let children = BitwardenTree.rootChildren(snapshot: BitwardenItemTests.snapshot)
    XCTAssertEqual(
      children.map(\.title),
      ["Favorites", "Logins", "Secure Notes", "Identities", "Folders", "Collections",
       "Generate Password", "Generate Passphrase", "Sync Vault", "Lock Vault"])
    let favorites = children[0] as? BitwardenGroupItem
    XCTAssertEqual(favorites?.hierarchyChildren().map(\.title), ["GitHub"])
    XCTAssertEqual(favorites?.detail, "1 item")
    let folders = children[4] as? BitwardenGroupItem
    XCTAssertEqual(folders?.hierarchyChildren().map(\.title), ["Work", "No Folder"])
    XCTAssertEqual(folders?.detail, "2 folders")
    let work = folders?.hierarchyChildren().first as? BitwardenGroupItem
    XCTAssertEqual(work?.typeID, .bitwardenFolder)
    XCTAssertEqual(work?.hierarchyChildren().map(\.title), ["GitHub", "Wifi"])
    let noFolder = folders?.hierarchyChildren().last as? BitwardenGroupItem
    XCTAssertEqual(noFolder?.hierarchyChildren().map(\.title), ["Bank", "Me"])
    let collections = children[5] as? BitwardenGroupItem
    XCTAssertEqual(collections?.hierarchyChildren().map(\.title), ["Shared"])
    XCTAssertEqual(collections?.detail, "1 collection")
    XCTAssertEqual((collections?.hierarchyChildren().first as? BitwardenGroupItem)?.hierarchyChildren().map(\.title), ["Bank"])
  }

  func testCollectionsGroupByOrganizationWhenSeveral() {
    var snapshot = BitwardenItemTests.snapshot
    snapshot.organizations.append(VaultOrganization(id: "o2", name: "Club"))
    snapshot.collections.append(VaultCollection(id: "c9", name: "Club stuff", organizationID: "o2"))
    let children = BitwardenTree.rootChildren(snapshot: snapshot)
    let collections = children[5] as? BitwardenGroupItem
    let organizations = (collections?.hierarchyChildren() ?? []).compactMap { $0 as? BitwardenGroupItem }
    XCTAssertEqual(organizations.map(\.title), ["Club", "Family"])
    XCTAssertEqual(organizations.map(\.detail), ["1 collection", "1 collection"])
    XCTAssertEqual(organizations.first?.hierarchyChildren().map(\.title), ["Club stuff"])
    XCTAssertEqual(organizations.last?.hierarchyChildren().map(\.title), ["Shared"])
  }

  func testObserverIgnoresTransientVaultStates() {
    XCTAssertFalse(BitwardenCatalog.shouldRefresh(for: .idle, rootLoading: false))
    XCTAssertFalse(BitwardenCatalog.shouldRefresh(for: .working, rootLoading: false))
    XCTAssertTrue(BitwardenCatalog.shouldRefresh(for: .locked, rootLoading: false))
    XCTAssertTrue(BitwardenCatalog.shouldRefresh(for: .unlocked, rootLoading: false))
  }

  func testObserverSkipsRefreshWhileRootLoads() {
    XCTAssertFalse(BitwardenCatalog.shouldRefresh(for: .unlocked, rootLoading: true))
    XCTAssertFalse(BitwardenCatalog.shouldRefresh(for: .locked, rootLoading: true))
  }

  func testRootLoadTrackingCoversTheLoadOnly() async {
    XCTAssertFalse(BitwardenTree.isRootLoading)
    let rows = await BitwardenTree.trackingRootLoad {
      XCTAssertTrue(BitwardenTree.isRootLoading)
      return [BitwardenCommandItem(command: .retry, detail: nil)]
    }
    XCTAssertFalse(BitwardenTree.isRootLoading)
    XCTAssertEqual(rows.count, 1)
  }

  func testEmptyVaultShowsMessageBeforeCommands() {
    let children = BitwardenTree.rootChildren(snapshot: .empty)
    XCTAssertEqual(children.first?.title, "No items")
    XCTAssertEqual(children.last?.title, "Lock Vault")
  }

  func testTypedTextReachesRootRows() {
    XCTAssertEqual(BitwardenTree.rootMatches(query: "lock", snapshot: .empty).map(\.title), ["Lock Vault"])
    XCTAssertEqual(
      BitwardenTree.rootMatches(query: "gen", snapshot: .empty).map(\.title),
      ["Generate Password", "Generate Passphrase"])
    XCTAssertTrue(BitwardenTree.rootMatches(query: "no items", snapshot: .empty).isEmpty)
  }

  func testErrorRowsOfferUnlockOrRetry() {
    let locked = BitwardenTree.rows(for: BitwardenVaultError.unlockCancelled)
    XCTAssertEqual(locked.map(\.title), ["Vault is locked", "Unlock Vault"])
    let missing = BitwardenTree.rows(for: BitwardenVaultError.cliMissing)
    XCTAssertEqual(missing.map(\.title), ["Bitwarden CLI not found", "Try Again"])
    let unconfigured = BitwardenTree.rows(for: BitwardenVaultError.unconfigured(["Master password"]))
    XCTAssertEqual(unconfigured.map(\.title), ["Set up Bitwarden", "Try Again"])
    XCTAssertTrue((unconfigured.first as? CatalogMessageItem)?.detail?.contains("Master password") == true)
  }

  func testCatalogDeclaresOneScopedSearchRoot() throws {
    let definition = CatalogDefinition(
      identifier: "bitwarden", name: "Bitwarden", enabledByDefault: true, presentation: .liveSearch, settings: [])
    let catalog = BitwardenCatalog(definition: definition)
    let root = try XCTUnwrap(catalog.objects.first as? ScopedSearchBrowseCatalogItem)
    XCTAssertEqual(root.id, "bitwarden")
    XCTAssertEqual(catalog.objects.count, 1)
    XCTAssertFalse(catalog.scansOnStartup)
  }
}

@MainActor
final class BitwardenActionTests: XCTestCase {
  private let catalog = BitwardenActionsCatalog(
    definition: ActionCatalogDefinition(identifier: "bitwarden.actions", name: "Bitwarden Actions"))

  private func action(_ id: String) throws -> PredicateAwareAction {
    try XCTUnwrap(catalog.actions.first { $0.id == id } as? PredicateAwareAction)
  }

  private func login(
    reprompt: Bool, totp: Bool, hosts: [String] = ["github.com"], websiteHost: String? = "github.com"
  ) -> BitwardenLoginItem {
    BitwardenLoginItem(
      entry: VaultEntry(
        id: "i1", kind: .login, name: "GitHub", username: "miira", uriHosts: hosts, websiteHost: websiteHost,
        folderID: nil, collectionIDs: [], organizationID: nil, isFavorite: false, requiresReprompt: reprompt,
        hasTotp: totp, revisionDate: nil, identity: nil), folderName: nil)
  }

  func testActionOrderAndIDs() {
    XCTAssertEqual(
      catalog.actions.map(\.id),
      ["copy-password", "copy-username", "copy-totp", "copy-url", "open-website", "open-in-bitwarden",
       "copy-note", "run-command", "copy-generated", "regenerate", "lock-vault-app", "sync-vault-app",
       "search-bitwarden"])
    XCTAssertFalse(catalog.actions.contains { $0.title.hasSuffix("...") })
    XCTAssertTrue(catalog.actions.allSatisfy { $0.targetRequirement == .none })
  }

  func testTextSearchScopesTheVaultToTypedText() throws {
    let search = try XCTUnwrap(catalog.actions.first { $0.id == "search-bitwarden" })
    XCTAssertEqual(search.title, "Search Bitwarden")
    XCTAssertEqual(search.supportedSubjectTypes, [.textSnippet])

    let predicate = try XCTUnwrap((search as? ActionPredicateProviding)?.subjectPredicate)
    XCTAssertTrue(predicate(TextSnippetItem(text: "github")))
    XCTAssertFalse(predicate(TextSnippetItem(text: "")))

    let scoped = try XCTUnwrap(search as? SubjectScopedSearchActionProviding)
    XCTAssertEqual(scoped.subjectScopedSearchRootCatalogIdentifier, "bitwarden")
    XCTAssertEqual(scoped.subjectScopedSearchQuery(from: TextSnippetItem(text: " github ")), "github")
  }

  func testRepromptHidesSecretCopies() throws {
    let plain = login(reprompt: false, totp: true)
    let guarded = login(reprompt: true, totp: true)
    XCTAssertTrue(try action("copy-password").subjectPredicate?(plain) == true)
    XCTAssertFalse(try action("copy-password").subjectPredicate?(guarded) == true)
    XCTAssertTrue(try action("copy-totp").subjectPredicate?(plain) == true)
    XCTAssertFalse(try action("copy-totp").subjectPredicate?(guarded) == true)
    XCTAssertTrue(try action("copy-username").subjectPredicate?(guarded) == true)
    XCTAssertTrue(try action("open-in-bitwarden").subjectPredicate?(guarded) == true)
  }

  func testTotpAndURLActionsNeedData() throws {
    let noTotp = login(reprompt: false, totp: false, hosts: [], websiteHost: nil)
    XCTAssertFalse(try action("copy-totp").subjectPredicate?(noTotp) == true)
    XCTAssertFalse(try action("copy-url").subjectPredicate?(noTotp) == true)
    XCTAssertFalse(try action("open-website").subjectPredicate?(noTotp) == true)
  }

  func testNoteRepromptLeavesOnlyOpen() throws {
    let entry = VaultEntry(
      id: "n1", kind: .secureNote, name: "Wifi", username: nil, uriHosts: [], websiteHost: nil, folderID: nil,
      collectionIDs: [], organizationID: nil, isFavorite: false, requiresReprompt: true, hasTotp: false,
      revisionDate: nil, identity: nil)
    let note = BitwardenNoteItem(entry: entry, folderName: nil)
    XCTAssertFalse(try action("copy-note").subjectPredicate?(note) == true)
    XCTAssertTrue(try action("open-in-bitwarden").subjectPredicate?(note) == true)
  }

  func testCommandAndGeneratedPredicates() throws {
    let command = BitwardenCommandItem(command: .syncVault, detail: nil)
    let generated = BitwardenGeneratedSecretItem(value: "x", kind: .password)
    XCTAssertTrue(try action("run-command").subjectPredicate?(command) == true)
    XCTAssertFalse(try action("run-command").subjectPredicate?(generated) == true)
    XCTAssertTrue(try action("copy-generated").subjectPredicate?(generated) == true)
    XCTAssertTrue(try action("regenerate").subjectPredicate?(generated) == true)
    XCTAssertEqual(try action("run-command").executionPolicy, .keepVisible)
    XCTAssertEqual(try action("copy-password").executionPolicy, .dismiss)
  }

  func testRepromptLoginIsRefusedOnTheExecutePath() async throws {
    let guarded = login(reprompt: true, totp: true)
    let result = await (try action("copy-password")).callback(guarded, nil)
    guard case .failure(let message) = result else {
      XCTFail("expected a refusal before reaching the vault")
      return
    }
    XCTAssertEqual(message, "This item needs your master password in Bitwarden")
  }

  func testSecretCopyRefusesAMismatchedSubject() async throws {
    let command = BitwardenCommandItem(command: .syncVault, detail: nil)
    let result = await (try action("copy-password")).callback(command, nil)
    guard case .failure(let message) = result else {
      XCTFail("expected a refusal")
      return
    }
    XCTAssertEqual(message, "Select a Bitwarden item")
  }

  func testURLActionsUseTheWebsiteHostOnly() throws {
    let appOnly = login(reprompt: false, totp: false, hosts: ["com.example.app"], websiteHost: nil)
    XCTAssertFalse(try action("copy-url").subjectPredicate?(appOnly) == true)
    XCTAssertFalse(try action("open-website").subjectPredicate?(appOnly) == true)
    let web = login(reprompt: false, totp: false, hosts: ["com.example.app", "github.com"], websiteHost: "github.com")
    XCTAssertTrue(try action("copy-url").subjectPredicate?(web) == true)
    XCTAssertTrue(try action("open-website").subjectPredicate?(web) == true)
  }

  func testAppActionsTargetTheBitwardenApplicationOnly() throws {
    for id in ["lock-vault-app", "sync-vault-app"] {
      XCTAssertEqual(try action(id).supportedSubjectTypes, [.application])
      XCTAssertFalse(try action(id).subjectPredicate?(BitwardenCommandItem(command: .syncVault, detail: nil)) == true)
      XCTAssertFalse(try action(id).subjectPredicate?(login(reprompt: false, totp: false)) == true)
      XCTAssertFalse(try action(id).subjectPredicate?(nil) == true)
    }
  }

  func testSupportedSubjectTypesMatchItems() throws {
    XCTAssertEqual(try action("copy-password").supportedSubjectTypes, [.bitwardenLogin])
    XCTAssertEqual(try action("open-in-bitwarden").supportedSubjectTypes, [.bitwardenLogin, .bitwardenNote, .bitwardenIdentity])
    XCTAssertEqual(try action("run-command").supportedSubjectTypes, [.bitwardenCommand])
  }
}
