import Foundation

enum BitwardenSearch {
  static func rank(_ entries: [VaultEntry], query: String, snapshot: VaultSnapshot, limit: Int = 60) -> [VaultEntry] {
    let filter = kindFilter(query)
    let pool = filter.kind.map { kind in entries.filter { $0.kind == kind } } ?? entries
    let tokens = filter.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else {
      guard filter.kind != nil else { return [] }
      return Array(pool.sorted { byName($0, $1) }.prefix(limit))
    }
    let scored = pool.compactMap { entry -> (VaultEntry, Int)? in
      let score = score(entry, tokens: tokens, folderName: snapshot.folderName(for: entry.folderID))
      return score > 0 ? (entry, score) : nil
    }
    return scored
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        if lhs.0.kind.searchOrder != rhs.0.kind.searchOrder { return lhs.0.kind.searchOrder < rhs.0.kind.searchOrder }
        return byName(lhs.0, rhs.0)
      }
      .prefix(limit)
      .map(\.0)
  }

  static func kindFilter(_ query: String) -> (kind: BitwardenItemKind?, text: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = trimmed.firstIndex(of: ":") else { return (nil, trimmed) }
    let kind: BitwardenItemKind
    switch trimmed[..<colon].lowercased() {
    case "l", "login", "logins": kind = .login
    case "n", "note", "notes": kind = .secureNote
    case "i", "id", "identity", "identities": kind = .identity
    default: return (nil, trimmed)
    }
    return (kind, trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
  }

  private static func byName(_ lhs: VaultEntry, _ rhs: VaultEntry) -> Bool {
    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  static func score(_ entry: VaultEntry, tokens: [String], folderName: String?) -> Int {
    let name = entry.name.lowercased()
    let username = entry.username?.lowercased() ?? ""
    let hosts = entry.uriHosts.map { $0.lowercased() }
    let folder = folderName?.lowercased() ?? ""
    let email = entry.identity?.email?.lowercased() ?? ""
    var total = 0
    for token in tokens {
      var best = 0
      if name == token { best = 100 }
      else if name.hasPrefix(token) { best = 60 }
      else if name.contains(token) { best = 40 }
      if best == 0, username.contains(token) || email.contains(token) || hosts.contains(where: { $0.contains(token) }) {
        best = 20
      }
      if best == 0, folder.contains(token) { best = 10 }
      guard best > 0 else { return 0 }
      total += best
    }
    return total + (entry.isFavorite ? 15 : 0)
  }
}

extension BitwardenItemKind {
  var searchOrder: Int {
    switch self {
    case .login: return 0
    case .identity: return 1
    case .secureNote: return 2
    }
  }
}
