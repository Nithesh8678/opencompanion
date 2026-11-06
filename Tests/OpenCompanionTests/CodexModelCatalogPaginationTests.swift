import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Public stdio fixtures only: no installed CLI, account, model request or UI.
@Suite(.serialized) struct CodexModelCatalogPaginationTests: Sendable {
  @Test(arguments: [false, true])
  func newerVisibleTerraOnTheSecondPageWinsRegardlessOfEntryOrder(_ reverse: Bool) async throws {
    var first = [model("account-default", isDefault: true), model("gpt-5.6-terra")]
    var second = [
      model("gpt-6.1-terra"), model("gpt-6-terra"),
      model("gpt-99-terra", hidden: true), model("gpt-98-terra", images: false),
    ]
    if reverse {
      first.reverse()
      second.reverse()
    }
    let cursor = "opaque/界\u{0}+=🌒"
    let fixture = try Fixture(pages: [page(first, next: .string(cursor)), page(second)])
    defer { fixture.remove() }
    let result = await stream(fixture)
    #expect(result.failure == nil && !result.watchdog)
    #expect(result.text == "ready")
    #expect(
      result.selections == [
        .init(model: "gpt-6.1-terra", effort: "low", reason: .terraGuidance)
      ])
    let requests = try fixture.requests()
    let catalogs = requests.filter { $0["method"] as? String == "model/list" }
    #expect(catalogs.count == 2)
    let secondRequest = try #require(catalogs.last?["params"] as? [String: Any])
    #expect(secondRequest["cursor"] as? String == cursor)
    for request in requests
    where ["thread/start", "turn/start"].contains(
      request["method"] as? String ?? "")
    {
      let params = try #require(request["params"] as? [String: Any])
      #expect(params["model"] as? String == "gpt-6.1-terra")
    }
  }

  @Test func inspectionIncludesLaterVisibleModelsAndAcceptsTheExactCursorByteLimit() async throws {
    let cursor = String(repeating: "😀", count: 1_024)
    #expect(cursor.utf8.count == 4_096)
    let fixture = try Fixture(pages: [
      page([model("account-default", isDefault: true)], next: .string(cursor)),
      page([model("gpt-6.1-terra"), model("hidden-public-model", hidden: true)]),
    ])
    defer { fixture.remove() }
    let status = try await inspect(fixture)
    #expect(status.authType == "chatgpt")
    #expect(status.models.map(\.id) == ["account-default", "gpt-6.1-terra"])
    #expect(status.models.last?.displayName == "Public gpt-6.1-terra")
    let requests = try fixture.requests()
    #expect(requests.filter { $0["method"] as? String == "model/list" }.count == 2)
    #expect(!requests.contains { $0["method"] as? String == "thread/start" })
  }

  @Test func allFourFullPagesAreRetainedWhenTheCatalogEndsAtTheExactEntryLimit() async throws {
    let pages = (0..<4).map { index in
      page(
        (0..<100).map { model("public-model-\(index * 100 + $0)") },
        next: index == 3 ? .null : .string("public-page-\(index + 1)"))
    }
    let fixture = try Fixture(pages: pages)
    defer { fixture.remove() }
    let status = try await inspect(fixture)
    #expect(status.models.count == 400)
    #expect(status.models.first?.id == "public-model-0")
    #expect(status.models.last?.id == "public-model-399")
    #expect(try fixture.requests().filter { $0["method"] as? String == "model/list" }.count == 4)
  }

  @Test func opaqueCursorsCompareExactUTF8RatherThanUnicodeEquivalence() async throws {
    let fixture = try Fixture(pages: [
      page([model("public-first")], next: .string("é")),
      page([model("public-second")], next: .string("e\u{301}")),
      page([model("public-third")]),
    ])
    defer { fixture.remove() }
    let status = try await inspect(fixture)
    #expect(status.models.map(\.id) == ["public-first", "public-second", "public-third"])
    #expect(try fixture.requests().filter { $0["method"] as? String == "model/list" }.count == 3)
  }

  @Test func aliasesAndExplicitVisualSelectionSurvivePaginationWithoutTerraPromotion() async throws
  {
    let fixture = try Fixture(pages: [
      page([model("gpt-5.6-terra")], next: .string("page-two")),
      page([model("gpt-6.1-terra"), model("public-configured", alias: "configured-alias")]),
    ])
    defer { fixture.remove() }
    let result = await stream(
      fixture, configured: "configured-alias",
      policy: .init(route: .notebook, includesExistingNotebook: false))
    #expect(result.failure == nil && !result.watchdog)
    #expect(
      result.selections == [
        .init(model: "configured-alias", effort: "low", reason: .visual)
      ])
  }

  @Test func duplicateCanonicalTerraEntriesAcrossPagesRemainAmbiguous() async throws {
    let fixture = try Fixture(pages: [
      page([model("gpt-6.1-terra")], next: .string("page-two")),
      page([model("gpt-6.1-terra"), model("gpt-5.6-terra")]),
    ])
    defer { fixture.remove() }
    let result = await stream(fixture)
    #expect(result.failure == nil && !result.watchdog)
    #expect(
      result.selections == [
        .init(model: "gpt-5.6-terra", effort: "low", reason: .terraGuidance)
      ])
  }

  @Test(arguments: InvalidCatalog.allCases)
  func invalidOrUnfinishedCatalogNeverStartsAProviderTurn(_ invalid: InvalidCatalog) async throws {
    let fixture = try Fixture(pages: invalidPages(invalid))
    defer { fixture.remove() }
    let result = await stream(fixture)
    #expect(!result.watchdog)
    #expect(result.failure?.contains("catalog") == true)
    #expect(result.selections.isEmpty && result.text.isEmpty)
    let requests = try fixture.requests()
    #expect(!requests.contains { $0["method"] as? String == "thread/start" })
    #expect(!requests.contains { $0["method"] as? String == "turn/start" })
    let catalogs = requests.filter { $0["method"] as? String == "model/list" }
    #expect(catalogs.count == invalid.requestCount)
    let ids = catalogs.compactMap { $0["id"] as? Int }
    #expect(Set(ids).count == catalogs.count)
  }

  @Test func inspectionAlsoRejectsARepeatedCursorInsteadOfReturningAPartialList() async throws {
    let fixture = try Fixture(pages: invalidPages(.repeatedCursor))
    defer { fixture.remove() }
    do {
      _ = try await inspect(fixture)
      Issue.record("Inspection silently returned an incomplete catalog")
    } catch let error as ProviderError {
      #expect(error.localizedDescription.contains("repeated model catalog cursor"))
    }
    #expect(try fixture.requests().filter { $0["method"] as? String == "model/list" }.count == 2)
  }

  enum InvalidCatalog: CaseIterable, Sendable {
    case repeatedCursor, numericCursor, emptyCursor, oversizedCursor, oversizedPage
    case fifthPage, missingData

    var requestCount: Int {
      switch self {
      case .repeatedCursor: 2
      case .fifthPage: 4
      default: 1
      }
    }
  }

  private func invalidPages(_ invalid: InvalidCatalog) -> [JSONValue] {
    let available = [model("gpt-6.1-terra")]
    switch invalid {
    case .repeatedCursor:
      return [page(available, next: .string("same")), page(available, next: .string("same"))]
    case .numericCursor: return [page(available, next: .number(4))]
    case .emptyCursor: return [page(available, next: .string(""))]
    case .oversizedCursor:
      return [page(available, next: .string(String(repeating: "😀", count: 1_025)))]
    case .oversizedPage: return [page((0..<101).map { model("public-model-\($0)") })]
    case .fifthPage:
      return (0..<4).map { index in
        page(
          (0..<100).map { model("public-model-\(index * 100 + $0)") },
          next: .string("page-\(index + 1)"))
      }
    case .missingData: return [.object(["nextCursor": .null])]
    }
  }

  private func model(
    _ name: String, alias: String? = nil, isDefault: Bool = false,
    hidden: Bool = false, images: Bool = true
  ) -> JSONValue {
    .object([
      "id": .string(alias ?? name), "model": .string(name),
      "displayName": .string("Public \(name)"), "isDefault": .bool(isDefault),
      "hidden": .bool(hidden),
      "inputModalities": .array(images ? [.string("text"), .string("image")] : [.string("text")]),
      "supportedReasoningEfforts": .array([
        .object(["reasoningEffort": .string("medium")]),
        .object(["reasoningEffort": .string("low")]),
      ]),
    ])
  }

  private func page(_ models: [JSONValue], next: JSONValue = .null) -> JSONValue {
    .object(["data": .array(models), "nextCursor": next])
  }

  private struct StreamResult: Sendable {
    let failure: String?
    let selections: [CodexRoutingSelection]
    let text: String
    let watchdog: Bool
  }

  private func stream(
    _ fixture: Fixture, configured: String = "",
    policy: ResponsePolicy = .init(route: .screenGuidance, includesExistingNotebook: false)
  ) async -> StreamResult {
    let provider = CodexProvider()
    let receiver = CatalogPaginationReceiver()
    let task = Task {
      try await provider.stream(
        executable: fixture.executable.path, model: configured,
        messages: [.init(role: "user", text: "Public catalog fixture")], context: "", image: nil,
        scene: nil, onRouting: { await receiver.routing($0) },
        onUnit: { await receiver.unit($0) }, responsePolicy: policy)
    }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      await receiver.timedOut()
      task.cancel()
      await provider.stop()
    }
    defer { watchdog.cancel() }
    let failure: String?
    do {
      try await task.value
      failure = nil
    } catch { failure = String(describing: error) }
    return await StreamResult(
      failure: failure, selections: receiver.selections, text: receiver.text,
      watchdog: receiver.watchdog)
  }

  private func inspect(_ fixture: Fixture) async throws -> CodexAccountStatus {
    let provider = CodexProvider()
    let task = Task { try await provider.inspect(executable: fixture.executable.path) }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      task.cancel()
    }
    defer { watchdog.cancel() }
    return try await task.value
  }

  private struct Fixture: Sendable {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("fixture.py") }
    private var requestLog: URL { directory.appendingPathComponent("requests.jsonl") }

    init(pages: [JSONValue]) throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-catalog-pagination-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(JSONValue.array(pages)).write(
        to: directory.appendingPathComponent("pages.json"))
      let script = #"""
        #!/usr/bin/env python3
        import json,sys
        from pathlib import Path
        root=Path(__file__).parent
        pages=json.loads((root/"pages.json").read_text())
        page_index=0
        def emit(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            method=request.get("method")
            if method=="turn/interrupt": continue
            with (root/"requests.jsonl").open("a") as log:
                log.write(json.dumps(request)+"\n")
            if method=="initialized": continue
            result={}
            if method=="account/read": result={"account":{"type":"chatgpt"}}
            if method=="model/list":
                params=request.get("params",{})
                expected=None if page_index==0 else pages[page_index-1].get("nextCursor")
                if (page_index>=len(pages) or params.get("cursor")!=expected
                        or params.get("includeHidden") is not False or params.get("limit")!=100):
                    emit({"id":request["id"],"error":{"message":"public pagination fixture rejected request"}})
                    continue
                result=pages[page_index]
                page_index+=1
            if method=="config/read": result={"layers":[]}
            if method=="thread/start": result={"thread":{"id":"public-thread"}}
            if method=="turn/start": result={"turn":{"id":"public-turn"}}
            emit({"id":request["id"],"result":result})
            if method=="turn/start":
                emit({"method":"item/completed","params":{"threadId":"public-thread","turnId":"public-turn","item":{"type":"agentMessage","id":"public-answer","phase":"final_answer","text":'{"type":"text","text":"ready"}'}}})
                emit({"method":"turn/completed","params":{"threadId":"public-thread","turn":{"id":"public-turn","status":"completed"}}})
        """#
      try Data(script.utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func requests() throws -> [[String: Any]] {
      try String(contentsOf: requestLog, encoding: .utf8).split(separator: "\n").map { line in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}

private actor CatalogPaginationReceiver {
  private(set) var selections: [CodexRoutingSelection] = []
  private(set) var text = ""
  private(set) var watchdog = false
  func routing(_ selection: CodexRoutingSelection) { selections.append(selection) }
  func unit(_ value: ProviderUnit) { text += value.text ?? "" }
  func timedOut() { watchdog = true }
}
