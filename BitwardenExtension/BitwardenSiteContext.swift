import AppKit
import ApplicationServices
import TunaKit

enum BitwardenSiteContext {
  private static let webAreaRole = "AXWebArea"

  @MainActor static func currentHost() -> String? {
    guard AccessibilityPermission.isTrusted(prompt: false), let pid = targetProcessIdentifier() else { return nil }
    let application = AXUIElementCreateApplication(pid)
    let url = focusedWebAreaURL(in: application) ?? firstWebAreaURL(in: application)
    return url.flatMap(BitwardenSiteMatch.host(from:))
  }

  @MainActor private static func targetProcessIdentifier() -> pid_t? {
    let own = ProcessInfo.processInfo.processIdentifier
    if let pid = AccessibilityEventTarget.targetProcessIdentifier(), pid != own { return pid }
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own else { return nil }
    return app.processIdentifier
  }

  private static func focusedWebAreaURL(in application: AXUIElement) -> String? {
    guard var element = element(application, kAXFocusedUIElementAttribute) else { return nil }
    for _ in 0..<40 {
      if role(of: element) == webAreaRole { return url(of: element) }
      guard let parent = self.element(element, kAXParentAttribute) else { return nil }
      element = parent
    }
    return nil
  }

  private static func firstWebAreaURL(in application: AXUIElement) -> String? {
    guard let window = element(application, kAXFocusedWindowAttribute) else { return nil }
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 400 {
      let current = queue.removeFirst()
      visited += 1
      if role(of: current) == webAreaRole { return url(of: current) }
      queue.append(contentsOf: children(of: current))
    }
    return nil
  }

  private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
  }

  private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let raw = value(parent, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }

  private static func role(of element: AXUIElement) -> String? {
    value(element, kAXRoleAttribute) as? String
  }

  private static func url(of element: AXUIElement) -> String? {
    if let url = value(element, kAXURLAttribute) as? URL { return url.absoluteString }
    return value(element, kAXDocumentAttribute) as? String
  }
}

enum BitwardenSiteMatch {
  static func host(from url: String) -> String? {
    guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
    return normalized(host)
  }

  static func logins(for host: String, in entries: [VaultEntry]) -> [VaultEntry] {
    let wanted = normalized(host)
    let site = baseDomain(wanted)
    return entries
      .filter { entry in
        entry.kind == .login
          && entry.uriHosts.contains { candidate in
            let candidate = normalized(candidate)
            return candidate == wanted || baseDomain(candidate) == site
          }
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func baseDomain(_ host: String) -> String {
    let labels = host.split(separator: ".")
    return labels.count > 2 ? labels.suffix(2).joined(separator: ".") : host
  }

  private static func normalized(_ host: String) -> String {
    let lowered = host.lowercased()
    return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
  }
}
