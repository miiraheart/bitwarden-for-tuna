import Foundation

enum BitwardenItemKind: Int, Sendable, Equatable {
  case login = 1
  case secureNote = 2
  case identity = 4
}

struct BitwardenIdentityFields: Sendable, Equatable {
  var fullName: String?
  var email: String?
  var username: String?
  var phone: String?
  var company: String?
  var address: String?

  var labeled: [(label: String, value: String)] {
    let pairs: [(String, String?)] = [
      ("Full Name", fullName), ("Email", email), ("Username", username), ("Phone", phone),
      ("Company", company), ("Address", address),
    ]
    return pairs.compactMap { label, value in value.map { (label: label, value: $0) } }
  }
}

struct VaultEntry: Sendable, Equatable, Identifiable {
  let id: String
  let kind: BitwardenItemKind
  let name: String
  let username: String?
  let uriHosts: [String]
  let websiteHost: String?
  let folderID: String?
  let collectionIDs: [String]
  let organizationID: String?
  let isFavorite: Bool
  let requiresReprompt: Bool
  let hasTotp: Bool
  let revisionDate: Date?
  let identity: BitwardenIdentityFields?
}

struct VaultFolder: Sendable, Equatable {
  let id: String
  let name: String
}

struct VaultCollection: Sendable, Equatable {
  let id: String
  let name: String
  let organizationID: String?
}

struct VaultOrganization: Sendable, Equatable {
  let id: String
  let name: String
}

struct VaultSnapshot: Sendable, Equatable {
  var entries: [VaultEntry]
  var folders: [VaultFolder]
  var collections: [VaultCollection]
  var organizations: [VaultOrganization]
  var lastSync: Date?

  static let empty = VaultSnapshot(entries: [], folders: [], collections: [], organizations: [], lastSync: nil)

  func folderName(for id: String?) -> String? {
    guard let id else { return nil }
    return folders.first { $0.id == id }?.name
  }
}

enum BitwardenDates {
  private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let whole: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func parse(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return fractional.date(from: raw) ?? whole.date(from: raw)
  }
}

struct CipherRecord: Decodable {
  struct Login: Decodable {
    struct URI: Decodable {
      let uri: String?
    }
    let username: String?
    let totp: String?
    let uris: [URI]?
  }

  struct Identity: Decodable {
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let email: String?
    let username: String?
    let phone: String?
    let company: String?
    let address1: String?
    let address2: String?
    let address3: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
  }

  let id: String
  let type: Int
  let name: String?
  let folderId: String?
  let organizationId: String?
  let collectionIds: [String]?
  let favorite: Bool?
  let reprompt: Int?
  let revisionDate: String?
  let deletedDate: String?
  let login: Login?
  let identity: Identity?
}

private struct FolderRecord: Decodable {
  let id: String?
  let name: String
}

private struct CollectionRecord: Decodable {
  let id: String
  let organizationId: String?
  let name: String
}

private struct OrganizationRecord: Decodable {
  let id: String
  let name: String
}

enum BitwardenModelDecoder {
  static func entries(from data: Data) throws -> [VaultEntry] {
    try JSONDecoder().decode([CipherRecord].self, from: data).compactMap(entry(from:))
  }

  static func folders(from data: Data) throws -> [VaultFolder] {
    try JSONDecoder().decode([FolderRecord].self, from: data).compactMap { record in
      record.id.map { VaultFolder(id: $0, name: record.name) }
    }
  }

  static func collections(from data: Data) throws -> [VaultCollection] {
    try JSONDecoder().decode([CollectionRecord].self, from: data).map {
      VaultCollection(id: $0.id, name: $0.name, organizationID: $0.organizationId)
    }
  }

  static func organizations(from data: Data) throws -> [VaultOrganization] {
    try JSONDecoder().decode([OrganizationRecord].self, from: data).map {
      VaultOrganization(id: $0.id, name: $0.name)
    }
  }

  static func entry(from record: CipherRecord) -> VaultEntry? {
    guard record.deletedDate == nil, let kind = BitwardenItemKind(rawValue: record.type) else { return nil }
    let hosts = (record.login?.uris ?? []).compactMap { $0.uri.flatMap(host(from:)) }
    var seen = Set<String>()
    let uniqueHosts = hosts.filter { seen.insert($0).inserted }
    return VaultEntry(
      id: record.id,
      kind: kind,
      name: clean(record.name) ?? "Untitled",
      username: kind == .login ? clean(record.login?.username) : clean(record.identity?.username),
      uriHosts: uniqueHosts,
      websiteHost: (record.login?.uris ?? []).lazy.compactMap { $0.uri.flatMap(webHost(from:)) }.first,
      folderID: record.folderId,
      collectionIDs: record.collectionIds ?? [],
      organizationID: record.organizationId,
      isFavorite: record.favorite ?? false,
      requiresReprompt: (record.reprompt ?? 0) != 0,
      hasTotp: clean(record.login?.totp) != nil,
      revisionDate: BitwardenDates.parse(record.revisionDate),
      identity: record.identity.map(identityFields(from:)))
  }

  static func host(from uri: String) -> String? {
    guard let trimmed = clean(uri) else { return nil }
    if let host = URL(string: trimmed)?.host, !host.isEmpty {
      return host.lowercased()
    }
    let withoutScheme = trimmed.components(separatedBy: "://").last ?? trimmed
    let hostPart = withoutScheme.split(separator: "/").first.map(String.init) ?? withoutScheme
    return hostPart.isEmpty ? nil : hostPart.lowercased()
  }

  static func webHost(from uri: String) -> String? {
    guard let trimmed = clean(uri) else { return nil }
    if let separator = trimmed.range(of: "://") {
      let scheme = trimmed[trimmed.startIndex..<separator.lowerBound].lowercased()
      guard scheme == "http" || scheme == "https" else { return nil }
    }
    return host(from: trimmed)
  }

  private static func identityFields(from identity: CipherRecord.Identity) -> BitwardenIdentityFields {
    let nameParts = [identity.firstName, identity.middleName, identity.lastName].compactMap(clean)
    let street = [identity.address1, identity.address2, identity.address3].compactMap(clean).joined(separator: " ")
    let locality = [identity.postalCode, identity.city].compactMap(clean).joined(separator: " ")
    let addressParts = [street, locality, clean(identity.state) ?? "", clean(identity.country) ?? ""].filter { !$0.isEmpty }
    return BitwardenIdentityFields(
      fullName: nameParts.isEmpty ? nil : nameParts.joined(separator: " "),
      email: clean(identity.email),
      username: clean(identity.username),
      phone: clean(identity.phone),
      company: clean(identity.company),
      address: addressParts.isEmpty ? nil : addressParts.joined(separator: ", "))
  }

  private static func clean(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
}
