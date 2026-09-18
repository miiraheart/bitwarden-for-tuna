import AppKit
import Foundation
import TunaKit

private final class BitwardenTextSearchAction: CatalogAction, ActionPredicateProviding,
  SubjectScopedSearchActionProviding, @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate?
  var targetPredicate: CatalogActionTargetPredicate?
  var subjectScopedSearchRootCatalogIdentifier: String? { BitwardenIdentifiers.catalog }

  init(id: String, title: String) {
    super.init(id: id, title: title) { _, _ in .success }
  }

  func subjectScopedSearchQuery(from subject: CatalogItem) -> String? {
    subject.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func subjectScopedSearchRoot(for _: CatalogItem) -> CatalogItem? {
    BitwardenCatalog.makeRootItem()
  }
}

private final class BitwardenAppLinkedAction: CatalogAction, ActionPredicateProviding, ActionAvailabilityProviding,
  @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate?
  var targetPredicate: CatalogActionTargetPredicate?
  private let appInstalled: @Sendable () -> Bool

  var isAvailable: Bool { appInstalled() }

  init(id: String, title: String, appInstalled: @escaping @Sendable () -> Bool, callback: @escaping ActionCallback) {
    self.appInstalled = appInstalled
    super.init(id: id, title: title, headlessEligibility: .guaranteed, callback: callback)
  }
}

public final class BitwardenActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = BitwardenActions.all()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
  }
}

enum BitwardenActions {
  static let bitwardenAppInstalled: @Sendable () -> Bool = {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: BitwardenIdentifiers.bundleIdentifier) != nil
  }

  static func all(appInstalled: @escaping @Sendable () -> Bool = bitwardenAppInstalled) -> [CatalogAction] {
    [
      secretCopy(id: BitwardenIdentifiers.copyPasswordAction, title: "Copy Password", symbol: "key.fill", field: .password),
      plainCopy(id: BitwardenIdentifiers.copyUsernameAction, title: "Copy Username", symbol: "person") { ($0 as? BitwardenLoginItem)?.entry.username },
      secretCopy(id: BitwardenIdentifiers.copyTOTPAction, title: "Copy TOTP", symbol: "clock", field: .totp) { $0.entry.hasTotp },
      plainCopy(id: BitwardenIdentifiers.copyURLAction, title: "Copy URL", symbol: "link") { websiteURL(for: $0)?.absoluteString },
      openWebsite(),
      openInBitwarden(appInstalled: appInstalled),
      secretCopy(id: BitwardenIdentifiers.copyNoteAction, title: "Copy Note", symbol: "note.text", field: .notes, subjectType: .bitwardenNote),
      runCommand(),
      copyGenerated(),
      regenerate(),
      appCommand(
        id: BitwardenIdentifiers.lockVaultAppAction, title: "Lock Vault", symbol: "lock.fill", command: .lockVault),
      appCommand(
        id: BitwardenIdentifiers.syncVaultAppAction, title: "Sync Vault",
        symbol: "arrow.triangle.2.circlepath", command: .syncVault),
      searchFromText(),
    ]
  }

  private static func searchFromText() -> CatalogAction {
    let action = BitwardenTextSearchAction(
      id: BitwardenIdentifiers.searchBitwardenAction, title: "Search Bitwarden")
    action.systemSymbolName = "lock.shield"
    action.supportedSubjectTypes = [.textSnippet]
    action.executionPolicy = .keepVisible
    action.subjectPredicate = { subject in
      guard let text = subject?.textInputValue() else { return false }
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return action
  }

  private static func secretCopy(
    id: String, title: String, symbol: String, field: BitwardenSecretField, subjectType: TypeID = .bitwardenLogin,
    extra: @escaping (BitwardenEntryItem) -> Bool = { _ in true }
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title, headlessEligibility: .guaranteed) { subject, _ in
      guard let item = subject as? BitwardenEntryItem, item.typeID == subjectType else {
        return .failure("Select a Bitwarden item")
      }
      guard !item.entry.requiresReprompt else {
        return .failure("This item needs your master password in Bitwarden")
      }
      return await copySecret(field, id: item.entry.id)
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [subjectType]
    action.subjectPredicate = { subject in
      guard let item = subject as? BitwardenEntryItem, item.typeID == subjectType else { return false }
      return !item.entry.requiresReprompt && extra(item)
    }
    return action
  }

  private static func plainCopy(
    id: String, title: String, symbol: String, value: @escaping (CatalogItem) -> String?
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title, headlessEligibility: .guaranteed) { subject, _ in
      guard let text = value(subject), !text.isEmpty else { return .failure("Nothing to copy") }
      return BitwardenClipboard.shared.copyText(text) ? .success : .failure("Could not copy")
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [.bitwardenLogin]
    action.subjectPredicate = { subject in
      guard let subject, subject is BitwardenLoginItem else { return false }
      return !(value(subject) ?? "").isEmpty
    }
    return action
  }

  private static func openWebsite() -> CatalogAction {
    let action = PredicateAwareAction(
      id: BitwardenIdentifiers.openWebsiteAction, title: "Open Website", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let url = websiteURL(for: subject) else { return .failure("This login has no website") }
      return NSWorkspace.shared.open(url) ? .success : .failure("Could not open \(url.absoluteString)")
    }
    action.systemSymbolName = "safari"
    action.supportedSubjectTypes = [.bitwardenLogin]
    action.subjectPredicate = { websiteURL(for: $0) != nil }
    return action
  }

  private static func openInBitwarden(appInstalled: @escaping @Sendable () -> Bool) -> CatalogAction {
    let action = BitwardenAppLinkedAction(
      id: BitwardenIdentifiers.openInBitwardenAction, title: "Open in Bitwarden", appInstalled: appInstalled
    ) { _, _ in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BitwardenIdentifiers.bundleIdentifier) else {
        return .failure("Bitwarden.app is not installed")
      }
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return .success
    }
    action.systemSymbolName = "arrow.up.right.square"
    action.supportedSubjectTypes = [.bitwardenLogin, .bitwardenNote, .bitwardenIdentity]
    action.subjectPredicate = { $0 is BitwardenEntryItem }
    return action
  }

  private static func runCommand() -> CatalogAction {
    let action = PredicateAwareAction(
      id: BitwardenIdentifiers.runCommandAction, title: "Run", executionPolicy: .keepVisible
    ) { subject, _ in
      guard let item = subject as? BitwardenCommandItem else { return .failure("Select a Bitwarden command") }
      return await run(item.command)
    }
    action.systemSymbolName = "return"
    action.supportedSubjectTypes = [.bitwardenCommand]
    action.subjectPredicate = { $0 is BitwardenCommandItem }
    return action
  }

  private static func copyGenerated() -> CatalogAction {
    let action = PredicateAwareAction(
      id: BitwardenIdentifiers.copyGeneratedAction, title: "Copy", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? BitwardenGeneratedSecretItem else { return .failure("Nothing generated") }
      let seconds = await BitwardenVault.shared.clipboardClearSeconds()
      return BitwardenClipboard.shared.copySecret(item.textValue, clearAfter: seconds) ? .success : .failure("Could not copy")
    }
    action.systemSymbolName = "doc.on.doc"
    action.supportedSubjectTypes = [.bitwardenGeneratedSecret]
    action.subjectPredicate = { $0 is BitwardenGeneratedSecretItem }
    return action
  }

  private static func regenerate() -> CatalogAction {
    let action = PredicateAwareAction(
      id: BitwardenIdentifiers.regenerateAction, title: "Regenerate", executionPolicy: .keepVisible
    ) { subject, _ in
      guard let item = subject as? BitwardenGeneratedSecretItem else { return .failure("Nothing generated") }
      return await generate(item.kind)
    }
    action.systemSymbolName = "arrow.clockwise"
    action.supportedSubjectTypes = [.bitwardenGeneratedSecret]
    action.subjectPredicate = { $0 is BitwardenGeneratedSecretItem }
    return action
  }

  private static func appCommand(id: String, title: String, symbol: String, command: BitwardenCommand) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title, headlessEligibility: .guaranteed) { _, _ in
      await run(command)
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [.application]
    action.subjectPredicate = isBitwardenApplication
    return action
  }

  static func isBitwardenApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity, let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == BitwardenIdentifiers.bundleIdentifier
  }

  static func copySecret(_ field: BitwardenSecretField, id: String) async -> ActionResult {
    do {
      let value = try await BitwardenVault.shared.secret(field, id: id)
      let seconds = await BitwardenVault.shared.clipboardClearSeconds()
      let copied = await BitwardenClipboard.shared.copySecret(value, clearAfter: seconds)
      return copied ? .success : .failure("Could not copy")
    } catch {
      if case BitwardenVaultError.unlockCancelled = error { return .cancelled }
      AppLog.error(.plugins, "[Bitwarden] copy \(field.rawValue) failed: \(error.localizedDescription)")
      return .failure(error.localizedDescription)
    }
  }

  static func run(_ command: BitwardenCommand) async -> ActionResult {
    switch command {
    case .generatePassword: return await generate(.password)
    case .generatePassphrase: return await generate(.passphrase)
    case .lockVault:
      await BitwardenVault.shared.lock()
      return .success
    case .unlockVault, .retry:
      return await refreshRoot()
    case .syncVault:
      return .background(
        CommandBackgroundTask(title: "Syncing Bitwarden vault") {
          do {
            try await BitwardenVault.shared.sync()
            return .successWithoutResult(standardOutput: nil)
          } catch {
            return .failure(message: error.localizedDescription)
          }
        })
    }
  }

  private static func generate(_ kind: BitwardenGeneratedKind) async -> ActionResult {
    do {
      let value = try await BitwardenVault.shared.generate(kind.options)
      return .results([BitwardenGeneratedSecretItem(value: value, kind: kind)])
    } catch {
      return result(for: error)
    }
  }

  static func result(for error: Error) -> ActionResult {
    if case BitwardenVaultError.unlockCancelled = error { return .cancelled }
    return .failure(error.localizedDescription)
  }

  private static func refreshRoot() async -> ActionResult {
    let rows = await BitwardenTree.rootChildren()
    return .results(rows)
  }

  private static func websiteURL(for subject: CatalogItem?) -> URL? {
    guard let item = subject as? BitwardenLoginItem, let host = item.entry.websiteHost else { return nil }
    return URL(string: "https://\(host)")
  }
}
