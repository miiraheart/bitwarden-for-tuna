import AppKit
import Foundation

protocol BitwardenPasteboard: AnyObject {
  var changeCount: Int { get }
  func write(_ string: String, concealed: Bool) -> Bool
  func clear()
}

final class SystemPasteboard: BitwardenPasteboard {
  static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  var changeCount: Int { NSPasteboard.general.changeCount }

  func write(_ string: String, concealed: Bool) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var types: [NSPasteboard.PasteboardType] = [.string]
    if concealed { types.append(Self.concealedType) }
    pasteboard.declareTypes(types, owner: nil)
    if concealed { pasteboard.setString("", forType: Self.concealedType) }
    return pasteboard.setString(string, forType: .string)
  }

  func clear() {
    NSPasteboard.general.clearContents()
  }
}

@MainActor
final class BitwardenClipboard {
  typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

  static let shared = BitwardenClipboard(pasteboard: SystemPasteboard())

  private let pasteboard: BitwardenPasteboard
  private let scheduleClear: Scheduler

  init(pasteboard: BitwardenPasteboard, scheduleClear: @escaping Scheduler = BitwardenClipboard.defaultScheduler) {
    self.pasteboard = pasteboard
    self.scheduleClear = scheduleClear
  }

  @discardableResult
  func copySecret(_ value: String, clearAfter seconds: Int) -> Bool {
    guard pasteboard.write(value, concealed: true) else { return false }
    guard seconds > 0 else { return true }
    let expected = pasteboard.changeCount
    scheduleClear(TimeInterval(seconds)) { [pasteboard] in
      if pasteboard.changeCount == expected { pasteboard.clear() }
    }
    return true
  }

  @discardableResult
  func copyText(_ value: String) -> Bool {
    pasteboard.write(value, concealed: false)
  }

  nonisolated static let defaultScheduler: Scheduler = { delay, work in
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      work()
    }
  }
}
