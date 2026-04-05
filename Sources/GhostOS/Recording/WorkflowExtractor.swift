// WorkflowExtractor.swift - CapturedActionからレシピJSONを生成
//
// パッシブキャプチャのバッファからRecipe JSON（schemaVersion: 2）を生成する。
// typeアクションのテキストは{{param_N}}にパラメータ化する。

import Foundation

// MARK: - WorkflowExtractor

/// CapturedAction配列をEnrichedEvent経由でSemanticStepに変換し、
/// RecipeのJSON文字列を生成するクラス。
public enum WorkflowExtractor {

    /// CapturedAction配列からRecipe JSON文字列を生成する。
    /// - Parameters:
    ///   - actions: キャプチャ済みアクション配列
    ///   - name: ワークフロー名
    ///   - description: ワークフローの説明
    /// - Returns: schemaVersion 2 のRecipe JSON文字列
    public static func extract(
        actions: [CapturedAction],
        name: String,
        description: String
    ) -> String {
        let steps = convertToRecipeSteps(actions)
        let params = extractParams(from: steps)

        var recipe: [String: Any] = [
            "schema_version": 2,
            "name": name,
            "description": description,
            "steps": steps,
        ]

        if !params.isEmpty {
            recipe["params"] = params
        }

        // タグにアプリ名を含める
        let apps = Set(actions.map { $0.app }).sorted()
        if !apps.isEmpty {
            recipe["tags"] = apps
        }

        // メタデータ
        let now = ISO8601DateFormatter().string(from: Date())
        recipe["recorded_from"] = [
            "session_id": "passive-\(UUID().uuidString)",
            "original_events": actions.count,
            "duration_seconds": durationSeconds(actions),
            "recorded_at": now,
        ] as [String: Any]

        if let data = try? JSONSerialization.data(
            withJSONObject: recipe, options: [.prettyPrinted, .sortedKeys]
        ),
            let jsonStr = String(data: data, encoding: .utf8)
        {
            return jsonStr
        }

        return "{}"
    }

    // MARK: - Internal

    /// CapturedAction配列をRecipeStep互換のdictionary配列に変換する。
    private static func convertToRecipeSteps(_ actions: [CapturedAction]) -> [[String: Any]] {
        var steps: [[String: Any]] = []
        var paramIndex = 1
        var lastApp = ""

        for action in actions {
            // アプリ切替はfocusステップとして記録
            if action.actionType == .appSwitch || (action.app != lastApp && !lastApp.isEmpty) {
                let step: [String: Any] = [
                    "id": steps.count + 1,
                    "action": "focus",
                    "params": ["app": action.app],
                    "note": "「\(action.app)」にフォーカス",
                ]
                steps.append(step)
            }
            lastApp = action.app

            switch action.actionType {
            case .click:
                var step: [String: Any] = [
                    "id": steps.count + 1,
                    "action": "click",
                ]
                if let target = action.target, !target.isEmpty {
                    step["target"] = ["query": target]
                    step["note"] = "「\(target)」をクリック"
                } else {
                    step["note"] = "クリック"
                }
                steps.append(step)

            case .type:
                // テキスト入力はパラメータ化（中身は記録していないので
                // プレースホルダーのみ）
                let paramName = "param_\(paramIndex)"
                paramIndex += 1
                let step: [String: Any] = [
                    "id": steps.count + 1,
                    "action": "type",
                    "params": ["text": "{{\(paramName)}}"],
                    "note": "テキスト入力",
                ]
                steps.append(step)

            case .hotkey:
                if let combo = action.keyCombo {
                    let step: [String: Any] = [
                        "id": steps.count + 1,
                        "action": "hotkey",
                        "params": ["keys": combo],
                        "note": "ショートカット \(combo)",
                    ]
                    steps.append(step)
                }

            case .appSwitch:
                // 上で処理済み
                break
            }
        }

        return steps
    }

    /// ステップ内の{{param_N}}パラメータ定義を抽出する。
    private static func extractParams(from steps: [[String: Any]]) -> [String: Any] {
        var params: [String: Any] = [:]

        for step in steps {
            guard let stepParams = step["params"] as? [String: Any] else { continue }
            for (_, value) in stepParams {
                guard let strValue = value as? String else { continue }
                // {{param_N}} パターンを検出
                let pattern = #"\{\{(\w+)\}\}"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(
                       in: strValue,
                       range: NSRange(strValue.startIndex..., in: strValue)
                   )
                {
                    let paramName = String(strValue[Range(match.range(at: 1), in: strValue)!])
                    params[paramName] = [
                        "type": "string",
                        "description": "入力テキスト",
                        "required": true,
                    ] as [String: Any]
                }
            }
        }

        return params
    }

    /// アクション配列の先頭から末尾までの経過秒数を計算する。
    private static func durationSeconds(_ actions: [CapturedAction]) -> Double {
        guard let first = actions.first, let last = actions.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }
}
