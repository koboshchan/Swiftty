import Foundation
import HighlightSwift
import SwiftUI

@MainActor
struct HighlightManager {
  static let shared = Highlight()

  static func highlight(code: String, language: String = "bash") async -> AttributedString {
    do {
      // Use the shared Highlight instance to parse the code snippet
      return try await shared.attributedText(code, language: language)
    } catch {
      var plain = AttributedString(code)
      plain.foregroundColor = .swText
      return plain
    }
  }
}
