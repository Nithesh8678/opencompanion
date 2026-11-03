import AppKit
import CoreText
import Testing

@testable import OpenCompanion

@Suite @MainActor struct CursorCaptionLayoutTests {
  @Test func mixedScriptsAndTallEmojiFitInsideTheMeasuredFourRows() throws {
    let text = "Top 👨‍👩‍👧‍👦\nதமிழ் हिन्दी\n👍🏽 e\u{301}\nশেষ🙂\nHidden fifth row"
    let attributed = NSMutableAttributedString(attributedString: caption(text))
    let emoji = (text as NSString).range(of: "👨‍👩‍👧‍👦")
    attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 28), range: emoji)
    let layout = CursorCaptionLayout.make(attributed, width: 280)

    #expect(layout.rows.count == 4)
    #expect(layout.rows[0].height > 17)
    #expect(layout.rows.last?.isTruncated == true)
    verifyMetrics(layout, width: 280)
    let reference = try glyphs(CTLineCreateWithAttributedString(caption("…")))
    let last = try #require(layout.rows.last)
    #expect(try glyphs(last.line).suffix(reference.count).elementsEqual(reference))
  }

  @Test func fourthHardNewlineStillShowsAnExplicitEllipsis() throws {
    let source = caption("one\ntwo\nthree\nfour\nfive")
    let layout = CursorCaptionLayout.make(source, width: 280)
    #expect(layout.rows.count == 4)
    #expect(layout.rows.dropLast().allSatisfy { !$0.isTruncated })
    let last = try #require(layout.rows.last)
    #expect(last.isTruncated)
    let expected = CTLineCreateWithAttributedString(caption("four…"))
    #expect(try glyphs(last.line) == glyphs(expected))
    verifyMetrics(layout, width: 280)

    let exactlyFour = CursorCaptionLayout.make(caption("one\ntwo\nthree\nfour"), width: 280)
    #expect(exactlyFour.rows.count == 4)
    #expect(exactlyFour.rows.allSatisfy { !$0.isTruncated })
    #expect(
      try glyphs(exactlyFour.rows[3].line)
        == glyphs(CTLineCreateWithAttributedString(caption("four"))))
  }

  @Test func longUnbrokenTextWrapsWithinTheWidthAndStopsAtFourRows() {
    let source = caption("https://example.com/" + String(repeating: "LongIdentifier", count: 20))
    for width: CGFloat in [64, 120, 280] {
      let layout = CursorCaptionLayout.make(source, width: width)
      #expect(layout.rows.count == 4)
      #expect(layout.rows.last?.isTruncated == true)
      #expect(layout.size.width <= width)
      verifyMetrics(layout, width: width)
      let ranges = layout.rows.dropLast().map { CTLineGetStringRange($0.line) }
      #expect(ranges.allSatisfy { $0.length > 0 })
      for pair in zip(ranges, ranges.dropFirst()) {
        #expect(pair.0.location + pair.0.length == pair.1.location)
      }
    }
  }

  @Test func truncationKeepsWholeEmojiAndCombiningClustersBeforeItsEllipsis() throws {
    for cluster in ["👨‍👩‍👧‍👦", "🇮🇳", "👍🏽", "e\u{301}"] {
      let tail = String(repeating: cluster, count: 12)
      let text = "one\ntwo\nthree\n" + tail + "\nfifth"
      let layout = CursorCaptionLayout.make(caption(text), width: 52)
      let last = try #require(layout.rows.last)
      #expect(layout.rows.count == 4 && last.isTruncated)
      let actual = try glyphs(last.line)
      var matchesWholePrefix = false
      for count in 0...12 {
        let safePrefix = String(tail.prefix(count)) + "…"
        let candidate = CTLineCreateWithAttributedString(caption(safePrefix))
        if actual == (try glyphs(candidate)) {
          matchesWholePrefix = true
          break
        }
      }
      #expect(matchesWholePrefix)
      verifyMetrics(layout, width: 52)
    }
  }

  @Test func normalWrappingRespectsUTF16GraphemeBoundaries() {
    let text = String(repeating: "A👨‍👩‍👧‍👦 e\u{301} 🇮🇳 👍🏽\r\n", count: 3)
    let boundaries = Set(text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count])
    let layout = CursorCaptionLayout.make(caption(text), width: 86)
    #expect(layout.rows.count <= 4 && !layout.rows.isEmpty)
    for row in layout.rows where !row.isTruncated {
      let range = CTLineGetStringRange(row.line)
      #expect(boundaries.contains(range.location))
      #expect(boundaries.contains(range.location + range.length))
    }
    verifyMetrics(layout, width: 86)
  }

  @Test func trailingWindowKeepsTheNewestWordsVisibleWithoutAHiddenFifthRow() {
    let source = String(repeating: "Earlier words 👨‍👩‍👧‍👦. ", count: 35) + "Finish at this exact control."
    for width: CGFloat in [86, 160, 280] {
      let layout = CursorCaptionLayout.makeTrailingWindow(caption(source), width: width)
      #expect(layout.text.hasPrefix("…"))
      #expect(source.hasSuffix(String(layout.text.dropFirst())))
      #expect(layout.text.hasSuffix("control."))
      #expect(layout.rows.count <= 4 && !layout.rows.isEmpty)
      #expect(layout.rows.allSatisfy { !$0.isTruncated })
      verifyMetrics(layout, width: width)
    }
  }

  @Test func trailingWindowKeepsEmojiWholeAndLeavesShortTextUntouched() {
    let short = "Hello 👨‍👩‍👧‍👦 e\u{301}"
    #expect(CursorCaptionLayout.makeTrailingWindow(caption(short), width: 280).text == short)
    let clusters = ["👨‍👩‍👧‍👦", "🇮🇳", "👍🏽", "e\u{301}"]
    for cluster in clusters {
      let source = String(repeating: cluster, count: 240)
      let layout = CursorCaptionLayout.makeTrailingWindow(caption(source), width: 120)
      #expect(layout.text.hasPrefix("…"))
      #expect(layout.text.dropFirst().allSatisfy { String($0) == cluster })
      #expect(layout.rows.allSatisfy { !$0.isTruncated })
      verifyMetrics(layout, width: 120)
    }
  }

  private func caption(_ text: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
        .paragraphStyle: paragraph,
      ])
  }

  /// Read CoreText's actual shaped metrics instead of assuming the system
  /// font's Latin metrics also cover fallback emoji and Indic glyphs.
  private func verifyMetrics(_ layout: CursorCaptionLayout, width: CGFloat) {
    #expect(layout.size.width.isFinite && layout.size.height.isFinite)
    #expect(layout.size.width <= width + 0.01)
    var top: CGFloat = 0
    for row in layout.rows {
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let typographicWidth = CTLineGetTypographicBounds(row.line, &ascent, &descent, &leading)
      let trailing = CTLineGetTrailingWhitespaceWidth(row.line)
      #expect(typographicWidth - trailing <= Double(width) + 0.01)
      #expect(row.baseline.isFinite && row.height.isFinite)
      #expect(abs(row.ascent - ascent) < 0.01 && abs(row.descent - descent) < 0.01)
      #expect(row.baseline - ascent >= top - 0.01)
      #expect(row.baseline + descent <= top + row.height + 0.01)
      #expect(row.baseline + descent <= layout.size.height + 0.01)
      top += row.height
    }
    #expect(abs(top - layout.size.height) < 0.01)
  }

  private struct Glyph: Equatable {
    let font: String
    let glyph: CGGlyph
  }

  /// Compare real shaped glyphs/font identities, including the truncation token,
  /// without drawing a view, opening a window, or comparing implementation math.
  private func glyphs(_ line: CTLine) throws -> [Glyph] {
    var result: [Glyph] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let attributes = CTRunGetAttributes(run) as NSDictionary
      let fontValue = try #require(attributes[kCTFontAttributeName])
      let font = fontValue as! CTFont
      let name = CTFontCopyPostScriptName(font) as String
      var values = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
      values.withUnsafeMutableBufferPointer { buffer in
        if let base = buffer.baseAddress {
          CTRunGetGlyphs(run, CFRange(location: 0, length: 0), base)
        }
      }
      result += values.map { Glyph(font: name, glyph: $0) }
    }
    return result
  }
}
