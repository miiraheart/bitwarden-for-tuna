import Foundation
import TunaKit

enum BitwardenSettingsError: LocalizedError, Equatable {
  case keychainAccessDenied

  var errorDescription: String? {
    "Tuna could not read the Bitwarden secrets from your Keychain. Allow access when macOS asks, then try again."
  }
}

enum BitwardenSettings {
  static let clientID = CatalogSettingDefinition(
    key: "ClientID", type: .string, label: "API key client ID", defaultValue: "",
    description:
      "From the Bitwarden web vault: Settings > Security > Keys > View API key. Used once to log the Tuna copy of the Bitwarden CLI in.")

  static let clientSecret = CatalogSettingDefinition(
    key: "ClientSecret", type: .secret, label: "API key client secret", defaultValue: "",
    description: "Same page as the client ID. Stays in your Mac Keychain.")

  static let masterPassword = CatalogSettingDefinition(
    key: "MasterPassword", type: .secret, label: "Master password", defaultValue: "",
    description: "Unlocks the vault after Touch ID or your Mac password. Stays in your Mac Keychain.")

  static let serverURL = CatalogSettingDefinition(
    key: "ServerURL", type: .string, label: "Server URL (optional)", defaultValue: "",
    description: "Leave empty for bitwarden.com. Use https://vault.bitwarden.eu for the EU cloud or your self-hosted address.")

  static let idleLockMinutes = CatalogSettingDefinition(
    key: "IdleLockMinutes", type: .string, label: "Lock after idle minutes", defaultValue: "15",
    description: "The vault locks after this many minutes without use, and always on sleep or screen lock. 0 never locks on idle.")

  static let clipboardClearSeconds = CatalogSettingDefinition(
    key: "ClipboardClearSeconds", type: .string, label: "Clear clipboard after seconds", defaultValue: "30",
    description: "Copied passwords, codes and notes are removed from the clipboard after this delay if you copied nothing else. 0 keeps them.")

  static let cliPath = CatalogSettingDefinition(
    key: "CLIPath", type: .string, label: "Bitwarden CLI path (optional)", defaultValue: "",
    description: "Full path to bw when it is not in /opt/homebrew/bin or /usr/local/bin.")

  static let definitions = [
    clientID, clientSecret, masterPassword, serverURL, idleLockMinutes, clipboardClearSeconds, cliPath,
  ]

  struct Values: Equatable, Sendable {
    var clientID: String
    var clientSecret: String
    var masterPassword: String
    var serverURL: String?
    var idleLockMinutes: Int
    var clipboardClearSeconds: Int
    var cliPath: String?
  }

  static func current() throws -> Values {
    let store = currentStore
    return Values(
      clientID: trimmed(store.stringValue(for: clientID)),
      clientSecret: try secret(clientSecret, in: store),
      masterPassword: try secret(masterPassword, in: store),
      serverURL: optional(store.stringValue(for: serverURL)),
      idleLockMinutes: integer(store.stringValue(for: idleLockMinutes), default: 15),
      clipboardClearSeconds: integer(store.stringValue(for: clipboardClearSeconds), default: 30),
      cliPath: optional(store.stringValue(for: cliPath)))
  }

  static func missingCredentialFields(in values: Values) -> [String] {
    var missing: [String] = []
    if values.clientID.isEmpty { missing.append(clientID.label) }
    if values.clientSecret.isEmpty { missing.append(clientSecret.label) }
    if values.masterPassword.isEmpty { missing.append(masterPassword.label) }
    return missing
  }

  static func integer(_ raw: String, default fallback: Int) -> Int {
    guard let value = Int(trimmed(raw)), value >= 0 else { return fallback }
    return value
  }

  private static func secret(_ definition: CatalogSettingDefinition, in store: CatalogSettingStore) throws
    -> String
  {
    switch store.readSecretValue(for: definition) {
    case .found(let value): return trimmed(value)
    case .notFound: return ""
    case .failed: throw BitwardenSettingsError.keychainAccessDenied
    @unknown default: throw BitwardenSettingsError.keychainAccessDenied
    }
  }

  private static func optional(_ raw: String) -> String? {
    let value = trimmed(raw)
    return value.isEmpty ? nil : value
  }

  private static func trimmed(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static var currentStore: CatalogSettingStore {
    let bundle = Bundle(for: BitwardenExtension.self)
    let identifier =
      bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaBitwarden")
    return CatalogSettingStore(catalogIdentifier: identifier)
  }
}
