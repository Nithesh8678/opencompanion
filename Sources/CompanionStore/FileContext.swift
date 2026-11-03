import CryptoKit
import Foundation

#if canImport(PDFKit)
  import PDFKit
#endif
#if canImport(ImageIO)
  import ImageIO
#endif

public enum FileContextError: Error, LocalizedError, Sendable, Equatable {
  case outsideScope, notRegularFile, unsupportedType, unreadableText, invalidBookmark,
    changedDuringRead, invalidLimit
  case tooLarge(limit: Int)

  public var errorDescription: String? {
    switch self {
    case .outsideScope:
      "The selected file is outside the allowed folder. Select it explicitly to grant access."
    case .notRegularFile:
      "Select a regular file. Folders and special files cannot be read as a document."
    case .tooLarge(let limit): "The selected file exceeds the \(limit)-byte context limit."
    case .unsupportedType: "This file type does not have a supported parser."
    case .unreadableText:
      "This document has no extractable text. Image descriptions contain metadata only."
    case .invalidBookmark: "Access to the saved file could not be restored. Select the file again."
    case .changedDuringRead:
      "This file changed while it was being read. Read its current version again."
    case .invalidLimit: "File context limits must be positive."
    }
  }
}

public struct FileContextChunk: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let text: String
  public let path: String
  public let page: Int?
  public let lineStart: Int?

  public var citation: String {
    if let page { return "\(path), page \(page)" }
    if let lineStart { return "\(path), line \(lineStart)" }
    return path
  }
}

public struct FileContext: Identifiable, Codable, Sendable, Equatable {
  public var id: String { contentHash }
  public let path: String
  public let filename: String
  public let contentHash: String
  public let modifiedAt: Date?
  public let byteCount: Int
  public let bookmark: Data?
  public let kind: String
  public let chunks: [FileContextChunk]
  public let truncated: Bool

  /// Returns bounded excerpts with source file/page references.
  public func excerpts(matching query: String, maximumCharacters: Int = 8_000) -> [FileContextChunk]
  {
    guard maximumCharacters > 0 else { return [] }
    let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(
      String.init)
    let ordered =
      terms.isEmpty
      ? chunks
      : chunks.enumerated().sorted { left, right in
        let leftText = left.element.text.lowercased()
        let rightText = right.element.text.lowercased()
        let leftScore = terms.reduce(0) { $0 + (leftText.contains($1) ? 1 : 0) }
        let rightScore = terms.reduce(0) { $0 + (rightText.contains($1) ? 1 : 0) }
        return leftScore == rightScore ? left.offset < right.offset : leftScore > rightScore
      }.map(\.element)
    var remaining = maximumCharacters
    var result: [FileContextChunk] = []
    for chunk in ordered where remaining > 0 {
      let text = String(chunk.text.prefix(remaining))
      result.append(
        FileContextChunk(
          id: chunk.id, text: text, path: chunk.path, page: chunk.page, lineStart: chunk.lineStart))
      remaining -= text.count
    }
    return result
  }
}

/// Reads only a selected file or a file inside an explicitly granted root.
/// Call from a background task when parsing large PDFs.
public struct FileContextReader: Sendable {
  public init() {}

  public func read(
    url: URL, allowedRoot: URL? = nil, maximumCharacters: Int = 24_000,
    maximumBytes: Int = 32_000_000
  ) throws -> FileContext {
    guard maximumCharacters > 0, maximumBytes > 0 else { throw FileContextError.invalidLimit }
    guard url.isFileURL else { throw FileContextError.outsideScope }
    #if os(macOS)
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    #endif
    var canonical = url.standardizedFileURL.resolvingSymlinksInPath()
    if let allowedRoot {
      let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
      guard canonical.pathComponents.starts(with: root.pathComponents) else {
        throw FileContextError.outsideScope
      }
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    let before = try canonical.resourceValues(forKeys: keys)
    guard before.isRegularFile == true else { throw FileContextError.notRegularFile }
    guard (before.fileSize ?? 0) <= maximumBytes else {
      throw FileContextError.tooLarge(limit: maximumBytes)
    }
    let data = try Data(contentsOf: canonical)
    guard data.count <= maximumBytes else { throw FileContextError.tooLarge(limit: maximumBytes) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let parsed: (kind: String, chunks: [FileContextChunk], truncated: Bool)
    if canonical.pathExtension.lowercased() == "pdf" {
      parsed = try parsePDF(data: data, path: canonical.path, hash: hash, limit: maximumCharacters)
    } else if let image = imageMetadata(
      data: data, path: canonical.path, hash: hash, limit: maximumCharacters)
    {
      parsed = image
    } else {
      let text: String?
      if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        text = String(data: data, encoding: .utf16)
      } else {
        text = String(data: data, encoding: .utf8)
      }
      guard let text, !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
        throw FileContextError.unsupportedType
      }
      parsed = parseText(text, path: canonical.path, hash: hash, limit: maximumCharacters)
    }
    canonical.removeAllCachedResourceValues()
    let after = try canonical.resourceValues(forKeys: keys)
    guard before.fileSize == after.fileSize,
      before.contentModificationDate == after.contentModificationDate
    else { throw FileContextError.changedDuringRead }
    let bookmark: Data?
    #if os(macOS)
      bookmark =
        (try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: keys, relativeTo: nil))
        ?? (try? url.bookmarkData(
          options: .minimalBookmark, includingResourceValuesForKeys: keys, relativeTo: nil))
    #else
      bookmark = nil
    #endif
    return FileContext(
      path: canonical.path, filename: canonical.lastPathComponent, contentHash: hash,
      modifiedAt: after.contentModificationDate, byteCount: data.count, bookmark: bookmark,
      kind: parsed.kind, chunks: parsed.chunks, truncated: parsed.truncated)
  }

  public func readBookmark(
    _ bookmark: Data, allowedRoot: URL? = nil, maximumCharacters: Int = 24_000,
    maximumBytes: Int = 32_000_000
  ) throws -> FileContext {
    #if os(macOS)
      var stale = false
      let scoped = try? URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale)
      let plain =
        scoped == nil
        ? try? URL(
          resolvingBookmarkData: bookmark, options: [.withoutUI],
          relativeTo: nil, bookmarkDataIsStale: &stale) : nil
      guard let url = scoped ?? plain else { throw FileContextError.invalidBookmark }
      return try read(
        url: url, allowedRoot: allowedRoot, maximumCharacters: maximumCharacters,
        maximumBytes: maximumBytes)
    #else
      throw FileContextError.invalidBookmark
    #endif
  }

  public func hasChanged(_ context: FileContext, allowedRoot: URL? = nil) throws -> Bool {
    let current: FileContext
    let byteLimit = max(context.byteCount * 2, 32_000_000)
    if let bookmark = context.bookmark {
      current = try readBookmark(
        bookmark, allowedRoot: allowedRoot, maximumCharacters: 1, maximumBytes: byteLimit)
    } else {
      current = try read(
        url: URL(fileURLWithPath: context.path), allowedRoot: allowedRoot, maximumCharacters: 1,
        maximumBytes: byteLimit)
    }
    return current.contentHash != context.contentHash
  }

  private func parseText(_ text: String, path: String, hash: String, limit: Int) -> (
    String, [FileContextChunk], Bool
  ) {
    let bounded = String(text.prefix(limit))
    var chunks: [FileContextChunk] = []
    var buffer = ""
    var line = 1
    var firstLine = 1
    let lines = bounded.split(separator: "\n", omittingEmptySubsequences: false)
    for (offset, part) in lines.enumerated() {
      if !buffer.isEmpty && buffer.count + part.count > 2_000 {
        chunks.append(
          FileContextChunk(
            id: "\(hash):\(firstLine)", text: buffer, path: path, page: nil, lineStart: firstLine))
        buffer = ""
        firstLine = line
      }
      buffer += String(part)
      if offset < lines.count - 1 { buffer += "\n" }
      line += 1
    }
    if !buffer.isEmpty {
      chunks.append(
        FileContextChunk(
          id: "\(hash):\(firstLine)", text: buffer, path: path, page: nil, lineStart: firstLine))
    }
    return ("text", chunks, text.count > limit)
  }

  private func parsePDF(data: Data, path: String, hash: String, limit: Int) throws -> (
    String, [FileContextChunk], Bool
  ) {
    #if canImport(PDFKit)
      guard let document = PDFDocument(data: data) else { throw FileContextError.unsupportedType }
      guard !document.isLocked else { throw FileContextError.unreadableText }
      var remaining = limit
      var chunks: [FileContextChunk] = []
      var visited = 0
      var truncated = false
      for index in 0..<min(document.pageCount, 200) {
        guard remaining > 0 else {
          truncated = true
          break
        }
        visited += 1
        let pageText = document.page(at: index)?.string ?? ""
        let excerpt = String(pageText.prefix(remaining))
        remaining -= excerpt.count
        if !excerpt.isEmpty {
          chunks.append(
            FileContextChunk(
              id: "\(hash):page:\(index + 1)", text: excerpt, path: path, page: index + 1,
              lineStart: nil))
        }
        if pageText.count > excerpt.count { truncated = true }
      }
      if visited < document.pageCount { truncated = true }
      guard !chunks.isEmpty else { throw FileContextError.unreadableText }
      return ("pdf", chunks, truncated)
    #else
      throw FileContextError.unsupportedType
    #endif
  }

  private func imageMetadata(data: Data, path: String, hash: String, limit: Int) -> (
    String, [FileContextChunk], Bool
  )? {
    #if canImport(ImageIO)
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      else { return nil }
      let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
      let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
      let frames = CGImageSourceGetCount(source)
      let summary =
        "Image file: \(URL(fileURLWithPath: path).lastPathComponent). Dimensions: \(width) × \(height) pixels. Frames: \(frames). This is file metadata; visual contents have not been interpreted."
      let text = String(summary.prefix(limit))
      return (
        "image",
        [
          FileContextChunk(
            id: "\(hash):metadata", text: text, path: path, page: nil, lineStart: nil)
        ], summary.count > limit
      )
    #else
      return nil
    #endif
  }
}
