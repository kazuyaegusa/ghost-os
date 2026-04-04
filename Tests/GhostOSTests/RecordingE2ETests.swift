// RecordingE2ETests.swift - 操作記録のフルパイプライン E2E テスト

import Foundation
import Testing
@testable import GhostOS

@Suite("Recording E2E Tests")
struct RecordingE2ETests {

    // MARK: - Helpers

    private func makeClickEvent(
        app: String = "TestApp",
        elementTitle: String? = nil,
        elementRole: String? = nil,
        identifier: String? = nil
    ) -> EnrichedEvent {
        let raw = RawEvent(
            type: .leftClick,
            timestamp: Date(),
            x: 100,
            y: 200
        )
        let element = AXElementInfo(
            role: elementRole,
            title: elementTitle,
            identifier: identifier
        )
        let ctx = AXContext(app: app, element: element)
        return EnrichedEvent(raw: raw, axContext: ctx)
    }

    private func makeScrollEvent(
        deltaX: Double = 0,
        deltaY: Double = 50,
        app: String = "TestApp"
    ) -> EnrichedEvent {
        let raw = RawEvent(
            type: .scroll,
            timestamp: Date(),
            scrollDeltaX: deltaX,
            scrollDeltaY: deltaY
        )
        let ctx = AXContext(app: app)
        return EnrichedEvent(raw: raw, axContext: ctx)
    }

    // MARK: - Tests

    @Test("クリックイベント→transform→JSON往復確認")
    func transformerToRecipeCompat() throws {
        // シミュレートされたクリックイベントを生成
        let event = makeClickEvent(
            app: "Safari",
            elementTitle: "送信",
            elementRole: "AXButton",
            identifier: "submit-button"
        )

        // SemanticTransformer で変換
        let steps = SemanticTransformer.transform([event])

        // action / target の検証
        #expect(steps.count == 1)
        #expect(steps[0].action == "click")
        #expect(steps[0].target?.query == "送信")
        #expect(steps[0].target?.role == "AXButton")
        #expect(steps[0].target?.identifier == "submit-button")
        #expect(steps[0].originalEventIndex == 0)

        // JSON エンコード → デコードの往復確認
        let encoder = JSONEncoder()
        let data = try encoder.encode(steps[0])

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SemanticStep.self, from: data)

        #expect(decoded.action == steps[0].action)
        #expect(decoded.target?.query == steps[0].target?.query)
        #expect(decoded.target?.role == steps[0].target?.role)
        #expect(decoded.target?.identifier == steps[0].target?.identifier)
        #expect(decoded.description == steps[0].description)
        #expect(decoded.originalEventIndex == steps[0].originalEventIndex)
    }

    @Test("クリック+スクロール→フルパイプライン→JSON往復確認")
    func fullPipeline() throws {
        // 複数種類のイベントを生成
        let clickEvent = makeClickEvent(
            app: "Finder",
            elementTitle: "ファイル",
            elementRole: "AXMenuItem"
        )
        let scrollEvent = makeScrollEvent(deltaX: 0, deltaY: 80, app: "Finder")

        // SemanticTransformer で変換
        let steps = SemanticTransformer.transform([clickEvent, scrollEvent])

        // ステップ数の確認
        #expect(steps.count == 2)

        // クリックステップの確認
        let clickStep = steps[0]
        #expect(clickStep.action == "click")
        #expect(clickStep.target?.query == "ファイル")
        #expect(clickStep.target?.role == "AXMenuItem")
        #expect(clickStep.originalEventIndex == 0)

        // スクロールステップの確認
        let scrollStep = steps[1]
        #expect(scrollStep.action == "scroll")
        #expect(scrollStep.params?["direction"] == "down")
        #expect(scrollStep.params?["amount"] == "80.0")
        #expect(scrollStep.originalEventIndex == 1)

        // JSON エンコード → デコードの往復確認（全ステップ）
        let encoder = JSONEncoder()
        let data = try encoder.encode(steps)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([SemanticStep].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].action == clickStep.action)
        #expect(decoded[0].target?.query == clickStep.target?.query)
        #expect(decoded[1].action == scrollStep.action)
        #expect(decoded[1].params?["direction"] == scrollStep.params?["direction"])
        #expect(decoded[1].params?["amount"] == scrollStep.params?["amount"])
    }
}
