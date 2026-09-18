import AppKit
import Foundation
import TunaKit

class BitwardenEntryItem: CatalogEntity, @unchecked Sendable {
  let entry: VaultEntry
  let folderName: String?

  init(entry: VaultEntry, folderName: String?, typeID: TypeID) {
    self.entry = entry
    self.folderName = folderName
    super.init(id: entry.id, title: entry.name, path: nil)
    self.typeID = typeID
  }

  override var searchText: String {
    ([entry.name, entry.username] + entry.uriHosts + [folderName]).compactMap { $0 }.joined(separator: " ")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class BitwardenLoginItem: BitwardenEntryItem, @unchecked Sendable {
  init(entry: VaultEntry, folderName: String?) {
    super.init(entry: entry, folderName: folderName, typeID: .bitwardenLogin)
  }

  override var detail: String? {
    [entry.username, entry.uriHosts.first].compactMap { $0 }.joined(separator: " \u{00B7} ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("key.fill", tintColor: entry.requiresReprompt ? .systemOrange : .systemBlue)
  }
}

final class BitwardenNoteItem: BitwardenEntryItem, @unchecked Sendable {
  init(entry: VaultEntry, folderName: String?) {
    super.init(entry: entry, folderName: folderName, typeID: .bitwardenNote)
  }

  override var detail: String? { folderName }
  override var searchText: String { [entry.name, folderName].compactMap { $0 }.joined(separator: " ") }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("note.text", tintColor: .systemYellow)
  }
}

final class BitwardenIdentityItem: BitwardenEntryItem, CatalogHierarchyNode, @unchecked Sendable {
  init(entry: VaultEntry, folderName: String?) {
    super.init(entry: entry, folderName: folderName, typeID: .bitwardenIdentity)
  }

  override var detail: String? { entry.identity?.email ?? entry.username }

  override var searchText: String {
    [entry.name, entry.identity?.fullName, entry.identity?.email, entry.username, folderName]
      .compactMap { $0 }.joined(separator: " ")
  }

  func hierarchyChildren() -> [CatalogItem] {
    (entry.identity?.labeled ?? []).map {
      BitwardenIdentityFieldItem(parentID: entry.id, label: $0.label, value: $0.value)
    }
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("person.text.rectangle", tintColor: .systemTeal)
  }
}

final class BitwardenIdentityFieldItem: CatalogEntity, TextValueProviding, @unchecked Sendable {
  let textValue: String

  init(parentID: String, label: String, value: String) {
    textValue = value
    super.init(id: "\(parentID):\(label)", title: label, path: nil)
    typeID = .bitwardenIdentityField
  }

  override var detail: String? { textValue }
  override var searchText: String { "\(title) \(textValue)" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("textformat", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

enum BitwardenGeneratedKind: Sendable {
  case password
  case passphrase

  var options: BitwardenGeneratorOptions {
    self == .password ? .password : .passphrase
  }

  var label: String { self == .password ? "Generated password" : "Generated passphrase" }
}

final class BitwardenGeneratedSecretItem: CatalogEntity, TextValueProviding, @unchecked Sendable {
  let textValue: String
  let kind: BitwardenGeneratedKind

  init(value: String, kind: BitwardenGeneratedKind) {
    textValue = value
    self.kind = kind
    super.init(id: "bitwarden.generated.\(UUID().uuidString)", title: value, path: nil)
    typeID = .bitwardenGeneratedSecret
  }

  override var detail: String? { "\(kind.label), Enter copies it" }
  override var searchText: String { "" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("key.horizontal", tintColor: .systemGreen)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class BitwardenGroupItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  private let children: [CatalogItem]
  private let symbolName: String
  private let color: CatalogIconColor
  private let detailText: String?

  init(
    title: String, id: String, detail: String?, symbolName: String, color: CatalogIconColor,
    children: [CatalogItem], typeID: TypeID
  ) {
    self.children = children
    self.symbolName = symbolName
    self.color = color
    self.detailText = detail
    super.init(id: id, title: title, path: nil)
    self.typeID = typeID
  }

  override var detail: String? { detailText }

  func hierarchyChildren() -> [CatalogItem] { children }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: symbolName, color: color, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

enum BitwardenCommand: String, Sendable, CaseIterable {
  case syncVault = "sync"
  case lockVault = "lock"
  case unlockVault = "unlock"
  case generatePassword = "generate-password"
  case generatePassphrase = "generate-passphrase"
  case retry = "retry"

  var title: String {
    switch self {
    case .syncVault: return "Sync Vault"
    case .lockVault: return "Lock Vault"
    case .unlockVault: return "Unlock Vault"
    case .generatePassword: return "Generate Password"
    case .generatePassphrase: return "Generate Passphrase"
    case .retry: return "Try Again"
    }
  }

  var symbolName: String {
    switch self {
    case .syncVault: return "arrow.triangle.2.circlepath"
    case .lockVault: return "lock.fill"
    case .unlockVault: return "lock.open.fill"
    case .generatePassword, .generatePassphrase: return "wand.and.stars"
    case .retry: return "arrow.clockwise"
    }
  }
}

final class BitwardenCommandItem: CatalogEntity, @unchecked Sendable {
  let command: BitwardenCommand
  private let detailText: String?

  init(command: BitwardenCommand, detail: String?) {
    self.command = command
    self.detailText = detail
    super.init(id: "bitwarden.command.\(command.rawValue)", title: command.title, path: nil)
    typeID = .bitwardenCommand
  }

  override var detail: String? { detailText }
  override var searchText: String { "Bitwarden \(title)" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(command.symbolName, tintColor: .systemBlue)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

enum BitwardenItems {
  static func item(for entry: VaultEntry, snapshot: VaultSnapshot) -> CatalogItem {
    let folderName = snapshot.folderName(for: entry.folderID)
    switch entry.kind {
    case .login: return BitwardenLoginItem(entry: entry, folderName: folderName)
    case .secureNote: return BitwardenNoteItem(entry: entry, folderName: folderName)
    case .identity: return BitwardenIdentityItem(entry: entry, folderName: folderName)
    }
  }

  static func message(title: String, message: String, symbolName: String, tint: NSColor) -> CatalogItem {
    CatalogMessageItem(title: title, message: message, symbolName: symbolName, tintColor: tint)
  }
}
