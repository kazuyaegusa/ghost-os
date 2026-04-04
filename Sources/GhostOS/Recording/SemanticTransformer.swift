// SemanticTransformer.swift - EnrichedEvent配列をSemanticStep配列に変換

import Foundation

public enum SemanticTransformer {

    // MARK: - Public API

    public static func transform(_ events: [EnrichedEvent]) -> [SemanticStep] {
        var steps: [SemanticStep] = []
        var i = 0

        while i < events.count {
            let event = events[i]

            switch event.raw.type {
            case .leftClick, .rightClick, .doubleClick:
                steps.append(makeClickStep(event, index: i))
                i += 1

            case .keyDown:
                let hasModifier = !(event.raw.modifiers ?? []).isEmpty
                if hasModifier {
                    steps.append(makeHotkeyStep(event, index: i))
                    i += 1
                } else {
                    // 連続するmodifierなしkeyDownをひとつのtypeにマージ
                    let (step, consumed) = makeTypeStep(events, startIndex: i)
                    steps.append(step)
                    i += consumed
                }

            case .scroll:
                steps.append(makeScrollStep(event, index: i))
                i += 1

            case .appSwitch:
                steps.append(makeFocusStep(event, index: i))
                i += 1
            }
        }

        return steps
    }

    // MARK: - Key Code Mapping

    static let keyCodeToName: [Int: String] = {
        var map: [Int: String] = [:]
        // a-z (keyCode 0-25 は a=0, s=1, d=2, f=3, h=4, g=5, z=6, x=7, c=8, v=9,
        //       b=11, q=12, w=13, e=14, r=15, y=16, t=17, 1=18...
        // 正確な macOS Virtual Key Codes を使用)
        let letterMap: [Int: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
            6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
            12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            31: "o", 32: "u", 34: "i", 35: "p",
            37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
        for (code, name) in letterMap { map[code] = name }

        map[36] = "return"
        map[48] = "tab"
        map[49] = "space"
        map[51] = "delete"
        map[53] = "escape"
        map[123] = "left"
        map[124] = "right"
        map[125] = "down"
        map[126] = "up"
        return map
    }()

    // MARK: - Step Builders

    private static func makeClickStep(_ event: EnrichedEvent, index: Int) -> SemanticStep {
        let element = event.axContext.element
        let title = element?.title
        let role = element?.role
        let identifier = element?.identifier

        let target = StepTarget(
            query: title,
            role: role,
            identifier: identifier
        )

        let desc: String
        if let t = title, !t.isEmpty {
            desc = "「\(t)」をクリック"
        } else if let r = role {
            desc = "\(r) をクリック"
        } else {
            desc = "クリック"
        }

        return SemanticStep(
            action: "click",
            target: target,
            params: nil,
            description: desc,
            originalEventIndex: index
        )
    }

    private static func makeTypeStep(
        _ events: [EnrichedEvent],
        startIndex: Int
    ) -> (SemanticStep, Int) {
        var text = ""
        var consumed = 0

        var j = startIndex
        while j < events.count {
            let e = events[j]
            guard e.raw.type == .keyDown,
                  (e.raw.modifiers ?? []).isEmpty
            else { break }

            if let chars = e.raw.characters, !chars.isEmpty {
                text += chars
            } else if let kc = e.raw.keyCode, let name = keyCodeToName[kc] {
                text += "[\(name)]"
            }
            consumed += 1
            j += 1
        }

        let step = SemanticStep(
            action: "type",
            target: nil,
            params: ["text": text],
            description: "「\(text)」を入力",
            originalEventIndex: startIndex
        )
        return (step, consumed)
    }

    private static func makeHotkeyStep(_ event: EnrichedEvent, index: Int) -> SemanticStep {
        let modifiers = event.raw.modifiers ?? []
        let keyName: String
        if let kc = event.raw.keyCode, let name = keyCodeToName[kc] {
            keyName = name
        } else if let chars = event.raw.characters, !chars.isEmpty {
            keyName = chars
        } else {
            keyName = "?"
        }

        let combo = (modifiers + [keyName]).joined(separator: "+")

        return SemanticStep(
            action: "hotkey",
            target: nil,
            params: ["keys": combo],
            description: "ショートカット \(combo)",
            originalEventIndex: index
        )
    }

    private static func makeScrollStep(_ event: EnrichedEvent, index: Int) -> SemanticStep {
        let dx = event.raw.scrollDeltaX ?? 0
        let dy = event.raw.scrollDeltaY ?? 0

        let direction: String
        let amount: Double
        if abs(dy) >= abs(dx) {
            direction = dy > 0 ? "down" : "up"
            amount = abs(dy)
        } else {
            direction = dx > 0 ? "right" : "left"
            amount = abs(dx)
        }

        return SemanticStep(
            action: "scroll",
            target: nil,
            params: ["direction": direction, "amount": String(amount)],
            description: "\(direction) 方向にスクロール（量: \(amount)）",
            originalEventIndex: index
        )
    }

    private static func makeFocusStep(_ event: EnrichedEvent, index: Int) -> SemanticStep {
        let app = event.axContext.app
        return SemanticStep(
            action: "focus",
            target: nil,
            params: ["app": app],
            description: "「\(app)」にフォーカス",
            originalEventIndex: index
        )
    }
}
