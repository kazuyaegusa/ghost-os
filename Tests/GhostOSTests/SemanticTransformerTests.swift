// SemanticTransformerTests.swift - SemanticTransformer のユニットテスト

import Foundation
import Testing
@testable import GhostOS

@Suite("SemanticTransformer Tests")
struct SemanticTransformerTests {

    // MARK: - Helpers

    private func makeEvent(
        type: RawEventType,
        keyCode: Int? = nil,
        characters: String? = nil,
        modifiers: [String]? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        app: String = "TestApp",
        elementTitle: String? = nil,
        elementRole: String? = nil
    ) -> EnrichedEvent {
        let raw = RawEvent(
            type: type,
            timestamp: Date(),
            keyCode: keyCode,
            characters: characters,
            modifiers: modifiers,
            scrollDeltaX: scrollDeltaX,
            scrollDeltaY: scrollDeltaY
        )
        let element = (elementTitle != nil || elementRole != nil)
            ? AXElementInfo(role: elementRole, title: elementTitle)
            : nil
        let ctx = AXContext(app: app, element: element)
        return EnrichedEvent(raw: raw, axContext: ctx)
    }

    // MARK: - Tests

    @Test("クリックイベントをclickステップに変換する")
    func clickEvent() {
        let event = makeEvent(
            type: .leftClick,
            app: "Safari",
            elementTitle: "送信",
            elementRole: "AXButton"
        )

        let steps = SemanticTransformer.transform([event])

        #expect(steps.count == 1)
        #expect(steps[0].action == "click")
        #expect(steps[0].target?.query == "送信")
        #expect(steps[0].target?.role == "AXButton")
        #expect(steps[0].description == "「送信」をクリック")
        #expect(steps[0].originalEventIndex == 0)
    }

    @Test("連続するkeyDownを1つのtypeステップにマージする")
    func consecutiveKeyDownMerge() {
        let events: [EnrichedEvent] = [
            makeEvent(type: .keyDown, characters: "h"),
            makeEvent(type: .keyDown, characters: "i"),
            makeEvent(type: .keyDown, characters: "!"),
        ]

        let steps = SemanticTransformer.transform(events)

        #expect(steps.count == 1)
        #expect(steps[0].action == "type")
        #expect(steps[0].params?["text"] == "hi!")
        #expect(steps[0].originalEventIndex == 0)
    }

    @Test("modifier付きkeyDownをhotkeyステップに変換する")
    func modifierKeyDown() {
        let event = makeEvent(
            type: .keyDown,
            keyCode: 1, // "s"
            modifiers: ["cmd"]
        )

        let steps = SemanticTransformer.transform([event])

        #expect(steps.count == 1)
        #expect(steps[0].action == "hotkey")
        #expect(steps[0].params?["keys"] == "cmd+s")
        #expect(steps[0].description == "ショートカット cmd+s")
        #expect(steps[0].originalEventIndex == 0)
    }

    @Test("scrollイベントをscrollステップに変換する")
    func scrollEvent() {
        let event = makeEvent(
            type: .scroll,
            scrollDeltaX: 0,
            scrollDeltaY: 30
        )

        let steps = SemanticTransformer.transform([event])

        #expect(steps.count == 1)
        #expect(steps[0].action == "scroll")
        #expect(steps[0].params?["direction"] == "down")
        #expect(steps[0].params?["amount"] == "30.0")
        #expect(steps[0].originalEventIndex == 0)
    }
}
