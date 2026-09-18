import AppKit
import Foundation
import TunaKit
import os

public final class BitwardenCatalog: Catalog, StartupScanningCatalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private lazy var rootItem = BitwardenCatalog.makeRootItem(catalogIdentifier: identifier)

  nonisolated static func makeRootItem(catalogIdentifier: String = BitwardenIdentifiers.catalog)
    -> ScopedSearchBrowseCatalogItem
  {
    ScopedSearchBrowseCatalogItem(
      title: "Bitwarden",
      id: BitwardenIdentifiers.catalog,
      detail: "Search your vault, or browse favorites, folders and collections",
      catalogIcon: .init(symbolName: "lock.shield", color: .blue),
      configuration: ScopedSearchConfiguration(debounce: .milliseconds(250), searchOnChange: true),
      loadingItemProvider: { CatalogLoadingItem(title: "Opening vault", message: "Unlocking Bitwarden.") },
      errorItemProvider: { BitwardenTree.rows(for: $0).first ?? BitwardenTree.unknownRow($0) },
      didLoad: { BitwardenTree.postScanFinished(identifier: catalogIdentifier) },
      loadChildren: { await BitwardenTree.trackingRootLoad { await BitwardenTree.rootChildren() } },
      searchHandler: { query in await BitwardenTree.trackingRootLoad { await BitwardenTree.search(query: query) } }
    )
  }

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    let catalogIdentifier = definition.identifier
    let observer: @Sendable (BitwardenVaultState) -> Void = { [weak self] state in
      guard BitwardenCatalog.shouldRefresh(for: state, rootLoading: BitwardenTree.isRootLoading), let self else { return }
      Task { @MainActor in
        self.rootItem.reset()
        BitwardenTree.postScanFinished(identifier: catalogIdentifier)
      }
    }
    Task { await BitwardenVault.shared.setStateObserver(observer) }
  }

  public func scan() async {
    rootItem.reset()
    reportScanFinished()
  }

  public func releaseRetainedState() {
    rootItem.reset()
    Task { await BitwardenVault.shared.shutdown() }
  }

  nonisolated static func shouldRefresh(for state: BitwardenVaultState, rootLoading: Bool) -> Bool {
    guard !rootLoading else { return false }
    switch state {
    case .idle, .working: return false
    default: return true
    }
  }
}

enum BitwardenTree {
  private static let rootLoadsInFlight = OSAllocatedUnfairLock(initialState: 0)

  static var isRootLoading: Bool { rootLoadsInFlight.withLock { $0 > 0 } }

  static func trackingRootLoad(_ load: () async -> [CatalogItem]) async -> [CatalogItem] {
    rootLoadsInFlight.withLock { $0 += 1 }
    defer { rootLoadsInFlight.withLock { $0 -= 1 } }
    return await load()
  }

  static func rootChildren() async -> [CatalogItem] {
    do {
      return rootChildren(snapshot: try await BitwardenVault.shared.snapshot())
    } catch {
      return rows(for: error)
    }
  }

  static func search(query: String) async -> [CatalogItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let snapshot = try await BitwardenVault.shared.snapshot()
      guard !trimmed.isEmpty else { return rootChildren(snapshot: snapshot) }
      let rootRows = rootMatches(query: trimmed, snapshot: snapshot)
      let matches = BitwardenSearch.rank(snapshot.entries, query: trimmed, snapshot: snapshot)
      guard !rootRows.isEmpty || !matches.isEmpty else {
        return [
          BitwardenItems.message(
            title: "No matches", message: "Nothing in your vault matches \u{201C}\(trimmed)\u{201D}.",
            symbolName: "magnifyingglass", tint: .secondaryLabelColor)
        ]
      }
      return rootRows + matches.map { BitwardenItems.item(for: $0, snapshot: snapshot) }
    } catch {
      return rows(for: error)
    }
  }

  static func rootMatches(query: String, snapshot: VaultSnapshot) -> [CatalogItem] {
    rootChildren(snapshot: snapshot).filter { row in
      !(row is CatalogMessageItem) && row.title.localizedCaseInsensitiveContains(query)
    }
  }

  static func rootChildren(snapshot: VaultSnapshot) -> [CatalogItem] {
    var rows: [CatalogItem] = []
    if snapshot.entries.isEmpty {
      rows.append(
        BitwardenItems.message(
          title: "No items", message: "Your vault is empty or has not synced yet.", symbolName: "tray",
          tint: .secondaryLabelColor))
    } else {
      rows.append(contentsOf: vaultGroups(snapshot: snapshot))
    }
    rows.append(BitwardenCommandItem(command: .generatePassword, detail: "20 characters, letters, numbers, symbols"))
    rows.append(BitwardenCommandItem(command: .generatePassphrase, detail: "4 words, capitalized, with a number"))
    rows.append(BitwardenCommandItem(command: .syncVault, detail: syncDetail(snapshot.lastSync)))
    rows.append(BitwardenCommandItem(command: .lockVault, detail: "Requires Touch ID to open again"))
    return rows
  }

  static func rows(for error: Error) -> [CatalogItem] {
    let vaultError = error as? BitwardenVaultError
    let message = error.localizedDescription
    switch vaultError {
    case .unlockCancelled, .locked:
      return [
        BitwardenItems.message(title: "Vault is locked", message: "Unlock with Touch ID to see your items.", symbolName: "lock.fill", tint: .systemOrange),
        BitwardenCommandItem(command: .unlockVault, detail: "Touch ID or your Mac password"),
      ]
    case .unconfigured:
      return [
        BitwardenItems.message(title: "Set up Bitwarden", message: message, symbolName: "gearshape", tint: .systemOrange),
        BitwardenCommandItem(command: .retry, detail: "After filling in Settings"),
      ]
    case .cliMissing:
      return [
        BitwardenItems.message(title: "Bitwarden CLI not found", message: message, symbolName: "terminal", tint: .systemOrange),
        BitwardenCommandItem(command: .retry, detail: "After installing bw"),
      ]
    case .keychainDenied:
      return [
        BitwardenItems.message(title: "Keychain access denied", message: message, symbolName: "key.slash", tint: .systemOrange),
        BitwardenCommandItem(command: .retry, detail: nil),
      ]
    case .loginFailed, .serveFailed, .unlockFailed, .request:
      return [
        BitwardenItems.message(title: "Bitwarden request failed", message: message, symbolName: "exclamationmark.triangle", tint: .systemOrange),
        BitwardenCommandItem(command: .retry, detail: nil),
      ]
    case .none:
      return [unknownRow(error), BitwardenCommandItem(command: .retry, detail: nil)]
    }
  }

  static func unknownRow(_ error: Error) -> CatalogItem {
    BitwardenItems.message(
      title: "Bitwarden request failed", message: error.localizedDescription,
      symbolName: "exclamationmark.triangle", tint: .systemOrange)
  }

  static func count(_ n: Int) -> String { count(n, noun: "item") }

  static func count(_ n: Int, noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

  static func postScanFinished(identifier: String) {
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  private static func vaultGroups(snapshot: VaultSnapshot) -> [CatalogItem] {
    let sorted = snapshot.entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    func items(_ subset: [VaultEntry]) -> [CatalogItem] { subset.map { BitwardenItems.item(for: $0, snapshot: snapshot) } }
    func group(_ title: String, _ id: String, _ symbol: String, _ color: CatalogIconColor, _ subset: [VaultEntry], typeID: TypeID = .bitwardenGroup) -> BitwardenGroupItem {
      BitwardenGroupItem(title: title, id: id, detail: count(subset.count), symbolName: symbol, color: color, children: items(subset), typeID: typeID)
    }

    var rows: [CatalogItem] = [
      group("Favorites", "bitwarden.group.favorites", "star.fill", .yellow, sorted.filter(\.isFavorite)),
      group("Logins", "bitwarden.group.logins", "key.fill", .blue, sorted.filter { $0.kind == .login }),
      group("Secure Notes", "bitwarden.group.notes", "note.text", .yellow, sorted.filter { $0.kind == .secureNote }),
      group("Identities", "bitwarden.group.identities", "person.text.rectangle", .teal, sorted.filter { $0.kind == .identity }),
    ]

    var folderRows: [CatalogItem] = snapshot.folders
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .map { folder in group(folder.name, "bitwarden.folder.\(folder.id)", "folder", .gray, sorted.filter { $0.folderID == folder.id }, typeID: .bitwardenFolder) }
    let loose = sorted.filter { $0.folderID == nil }
    if !loose.isEmpty {
      folderRows.append(group("No Folder", "bitwarden.folder.none", "folder", .gray, loose, typeID: .bitwardenFolder))
    }
    rows.append(BitwardenGroupItem(title: "Folders", id: "bitwarden.group.folders", detail: count(folderRows.count, noun: "folder"), symbolName: "folder.fill", color: .gray, children: folderRows, typeID: .bitwardenGroup))

    func collectionRows(_ collections: [VaultCollection]) -> [CatalogItem] {
      collections
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .map { collection in group(collection.name, "bitwarden.collection.\(collection.id)", "person.2", .indigo, sorted.filter { $0.collectionIDs.contains(collection.id) }, typeID: .bitwardenCollection) }
    }
    let collectionChildren: [CatalogItem]
    if snapshot.organizations.count > 1 {
      collectionChildren = snapshot.organizations
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .map { org in
          let mine = collectionRows(snapshot.collections.filter { $0.organizationID == org.id })
          return BitwardenGroupItem(title: org.name, id: "bitwarden.org.\(org.id)", detail: count(mine.count, noun: "collection"), symbolName: "building.2", color: .indigo, children: mine, typeID: .bitwardenGroup)
        }
    } else {
      collectionChildren = collectionRows(snapshot.collections)
    }
    rows.append(BitwardenGroupItem(title: "Collections", id: "bitwarden.group.collections", detail: count(collectionChildren.count, noun: snapshot.organizations.count > 1 ? "organization" : "collection"), symbolName: "person.2.fill", color: .indigo, children: collectionChildren, typeID: .bitwardenGroup))
    return rows
  }

  private static func syncDetail(_ lastSync: Date?) -> String {
    guard let lastSync else { return "Never synced" }
    return "Synced \(lastSync.formatted(.relative(presentation: .named)))"
  }
}
