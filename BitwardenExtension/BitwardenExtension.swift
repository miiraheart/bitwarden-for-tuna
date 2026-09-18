import Foundation
import TunaKit

@objc(BitwardenExtension)
public final class BitwardenExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Bitwarden",
        author: "miiraheart",
        description: "Search and browse your Bitwarden vault, copy passwords and codes, generate new ones.",
        iconName: "lock.shield"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: BitwardenSettings.definitions,
      catalogs: [
        CatalogDeclaration(
          id: BitwardenIdentifiers.catalog, type: BitwardenCatalog.self, name: "Bitwarden",
          presentation: .liveSearch,
          description: "Type to search your vault, or browse favorites, folders and collections. Items never enter global search.",
          enabledByDefault: true)
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: BitwardenIdentifiers.actionCatalog, type: BitwardenActionsCatalog.self,
          name: "Bitwarden Actions")
      ],
      typeRegistrations: BitwardenTypes.registrations,
      defaultActionRankings: BitwardenTypes.defaultActionRankings,
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: [BitwardenIdentifiers.bundleIdentifier],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: BitwardenIdentifiers.catalog)])
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: [BitwardenIdentifiers.bundleIdentifier],
          catalogIdentifiers: [BitwardenIdentifiers.actionCatalog])
      ]
    )
  }
}

enum BitwardenIdentifiers {
  static let bundleIdentifier = "com.bitwarden.desktop"
  static let catalog = "bitwarden"
  static let actionCatalog = "bitwarden.actions"
  static let copyPasswordAction = "copy-password"
  static let copyUsernameAction = "copy-username"
  static let copyTOTPAction = "copy-totp"
  static let copyURLAction = "copy-url"
  static let openWebsiteAction = "open-website"
  static let openInBitwardenAction = "open-in-bitwarden"
  static let copyNoteAction = "copy-note"
  static let runCommandAction = "run-command"
  static let copyGeneratedAction = "copy-generated"
  static let regenerateAction = "regenerate"
  static let lockVaultAppAction = "lock-vault-app"
  static let syncVaultAppAction = "sync-vault-app"
  static let searchBitwardenAction = "search-bitwarden"
}

enum BitwardenTypes {
  static let registrations: [TypeRegistrationDefinition] = [
    TypeRegistrationDefinition(typeID: .bitwardenItem, displayName: "Bitwarden Items", inheritsFrom: [.entity]),
    TypeRegistrationDefinition(typeID: .bitwardenLogin, displayName: "Bitwarden Logins", inheritsFrom: [.bitwardenItem]),
    TypeRegistrationDefinition(typeID: .bitwardenNote, displayName: "Bitwarden Notes", inheritsFrom: [.bitwardenItem]),
    TypeRegistrationDefinition(typeID: .bitwardenIdentity, displayName: "Bitwarden Identities", inheritsFrom: [.bitwardenItem, .searchCatalogEntry]),
    TypeRegistrationDefinition(typeID: .bitwardenIdentityField, displayName: "Bitwarden Identity Fields", inheritsFrom: [.textSnippet]),
    TypeRegistrationDefinition(typeID: .bitwardenGeneratedSecret, displayName: "Generated Secrets", inheritsFrom: [.textSnippet]),
    TypeRegistrationDefinition(typeID: .bitwardenFolder, displayName: "Bitwarden Folders", inheritsFrom: [.searchCatalogEntry]),
    TypeRegistrationDefinition(typeID: .bitwardenCollection, displayName: "Bitwarden Collections", inheritsFrom: [.searchCatalogEntry]),
    TypeRegistrationDefinition(typeID: .bitwardenGroup, displayName: "Bitwarden Groups", inheritsFrom: [.searchCatalogEntry]),
    TypeRegistrationDefinition(typeID: .bitwardenCommand, displayName: "Bitwarden Commands", inheritsFrom: [.entity]),
  ]

  static let defaultActionRankings: [DefaultActionRankingDefinition] = [
    ranking(.bitwardenLogin, [BitwardenIdentifiers.copyPasswordAction, BitwardenIdentifiers.copyUsernameAction]),
    ranking(.bitwardenNote, [BitwardenIdentifiers.copyNoteAction]),
    ranking(.bitwardenCommand, [BitwardenIdentifiers.runCommandAction]),
    ranking(.bitwardenGeneratedSecret, [BitwardenIdentifiers.copyGeneratedAction, BitwardenIdentifiers.regenerateAction]),
  ]

  private static func ranking(_ typeID: TypeID, _ actionIDs: [String]) -> DefaultActionRankingDefinition {
    DefaultActionRankingDefinition(
      typeID: typeID,
      actions: actionIDs.map {
        ActionReference(catalogIdentifier: BitwardenIdentifiers.actionCatalog, actionID: $0)
      })
  }
}

extension TypeID {
  static let bitwardenItem = TypeID("com.tuna.type.bitwarden-item")
  static let bitwardenLogin = TypeID("com.tuna.type.bitwarden-login")
  static let bitwardenNote = TypeID("com.tuna.type.bitwarden-note")
  static let bitwardenIdentity = TypeID("com.tuna.type.bitwarden-identity")
  static let bitwardenIdentityField = TypeID("com.tuna.type.bitwarden-identity-field")
  static let bitwardenGeneratedSecret = TypeID("com.tuna.type.bitwarden-generated-secret")
  static let bitwardenFolder = TypeID("com.tuna.type.bitwarden-folder")
  static let bitwardenCollection = TypeID("com.tuna.type.bitwarden-collection")
  static let bitwardenGroup = TypeID("com.tuna.type.bitwarden-group")
  static let bitwardenCommand = TypeID("com.tuna.type.bitwarden-command")
}
