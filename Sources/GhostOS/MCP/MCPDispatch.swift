// MCPDispatch.swift - Route MCP tool calls to module functions
//
// Maps tool names to handler functions. Wraps each call in a timeout.
// Formats responses as MCP content arrays.

import AXorcist
import Foundation

/// Routes MCP tool calls to the appropriate module function.
public enum MCPDispatch {

    /// Per-tool-call timeout. Most tools complete in <2s; deep AX tree walks
    /// can take 10-20s for Chrome. 60s is the absolute ceiling — if a tool takes
    /// longer than this, the MCP server was effectively stuck.
    private static let toolTimeoutSeconds: TimeInterval = 60

    /// 操作記録セッションマネージャー（プロセス全体で1インスタンス）
    static let recordingSession = RecordingSession()

    /// パッシブキャプチャマネージャー（プロセス全体で1インスタンス）
    static let passiveCapture = PassiveCaptureManager()

    /// パターン検出器
    static let patternDetector = PatternDetector()

    /// Handle a tools/call request. Returns MCP-formatted result.
    /// Wraps every tool call in a timeout so no single tool can block
    /// the MCP server indefinitely (the #1 user-reported issue).
    public static func handle(_ params: [String: Any]) -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            return errorContent("Missing tool name")
        }

        let args = params["arguments"] as? [String: Any] ?? [:]
        let startTime = DispatchTime.now()
        Log.info("Tool call: \(toolName)")

        // Screenshot and annotate return MCP image content directly (not text-wrapped JSON)
        let response: [String: Any]
        if toolName == "ghost_screenshot" {
            response = handleScreenshot(args)
        } else if toolName == "ghost_annotate" {
            response = handleAnnotate(args)
        } else {
            let result = dispatch(tool: toolName, args: args)
            response = formatResult(result, toolName: toolName)
        }

        // Log timing for every tool call (helps diagnose slow tools)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        if elapsed > 5000 {
            Log.warn("Tool \(toolName) took \(Int(elapsed))ms (slow)")
        } else {
            Log.info("Tool \(toolName) completed in \(Int(elapsed))ms")
        }

        return response
    }

    /// Screenshot handler returns MCP image content type for inline display.
    private static func handleScreenshot(_ args: [String: Any]) -> [String: Any] {
        let result = Perception.screenshot(
            appName: str(args, "app"),
            fullResolution: bool(args, "full_resolution") ?? false
        )

        guard result.success,
              let data = result.data,
              let base64 = data["image"] as? String
        else {
            return formatResult(result, toolName: "ghost_screenshot")
        }

        // Return as MCP image + text caption (v1 pattern: both content types)
        let mimeType = data["mime_type"] as? String ?? "image/png"
        let width = data["width"] as? Int ?? 0
        let height = data["height"] as? Int ?? 0
        let windowTitle = data["window_title"] as? String ?? ""
        var caption = "Screenshot: \(width)x\(height)"
        if !windowTitle.isEmpty { caption += " - \(windowTitle)" }

        return [
            "content": [
                [
                    "type": "image",
                    "data": base64,
                    "mimeType": mimeType,
                ] as [String: Any],
                [
                    "type": "text",
                    "text": caption,
                ] as [String: Any],
            ] as [[String: Any]],
            "isError": false,
        ]
    }

    /// Annotate handler returns MCP image + text index for labeled screenshots.
    private static func handleAnnotate(_ args: [String: Any]) -> [String: Any] {
        let rolesArray = args["roles"] as? [String]
        let result = Annotate.annotate(
            appName: str(args, "app"),
            roles: rolesArray,
            maxLabels: int(args, "max_labels")
        )

        guard result.success,
              let data = result.data,
              let base64 = data["annotated_image"] as? String,
              let index = data["index"] as? String
        else {
            return formatResult(result, toolName: "ghost_annotate")
        }

        let mimeType = data["mime_type"] as? String ?? "image/png"
        let width = data["width"] as? Int ?? 0
        let height = data["height"] as? Int ?? 0
        let elementCount = data["element_count"] as? Int ?? 0
        let windowTitle = data["window_title"] as? String ?? ""

        var caption = "Annotated screenshot: \(width)x\(height), \(elementCount) labeled elements"
        if !windowTitle.isEmpty { caption += " — \(windowTitle)" }

        return [
            "content": [
                [
                    "type": "image",
                    "data": base64,
                    "mimeType": mimeType,
                ] as [String: Any],
                [
                    "type": "text",
                    "text": caption + "\n\n" + index,
                ] as [String: Any],
            ] as [[String: Any]],
            "isError": false,
        ]
    }

    // MARK: - Dispatch

    private static func dispatch(tool: String, args: [String: Any]) -> ToolResult {
        switch tool {

        // Perception
        case "ghost_context":
            return Perception.getContext(appName: str(args, "app"))

        case "ghost_state":
            return Perception.getState(appName: str(args, "app"))

        case "ghost_find":
            return Perception.findElements(
                query: str(args, "query"),
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                domClass: str(args, "dom_class"),
                identifier: str(args, "identifier"),
                appName: str(args, "app"),
                depth: int(args, "depth")
            )

        case "ghost_read":
            return Perception.readContent(
                appName: str(args, "app"),
                query: str(args, "query"),
                depth: int(args, "depth")
            )

        case "ghost_inspect":
            guard let query = str(args, "query") else {
                return ToolResult(success: false, error: "Missing required parameter: query")
            }
            return Perception.inspect(
                query: query,
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                appName: str(args, "app")
            )

        case "ghost_element_at":
            guard let x = double(args, "x"), let y = double(args, "y") else {
                return ToolResult(success: false, error: "Missing required parameters: x, y")
            }
            return Perception.elementAt(x: x, y: y)

        case "ghost_screenshot":
            return Perception.screenshot(
                appName: str(args, "app"),
                fullResolution: bool(args, "full_resolution") ?? false
            )

        // Actions
        case "ghost_click":
            return FocusManager.withFocusRestore {
                Actions.click(
                    query: str(args, "query"),
                    role: str(args, "role"),
                    domId: str(args, "dom_id"),
                    appName: str(args, "app"),
                    x: double(args, "x"),
                    y: double(args, "y"),
                    button: str(args, "button"),
                    count: int(args, "count")
                )
            }

        case "ghost_type":
            guard let text = str(args, "text") else {
                return ToolResult(success: false, error: "Missing required parameter: text")
            }
            return FocusManager.withFocusRestore {
                Actions.typeText(
                    text: text,
                    into: str(args, "into"),
                    domId: str(args, "dom_id"),
                    appName: str(args, "app"),
                    clear: bool(args, "clear") ?? false
                )
            }

        // Press, hotkey, scroll, hover, long_press, drag are synthetic input tools
        // that send events to the FRONTMOST app. They need the target app to STAY
        // focused after the tool returns — the agent will call ghost_focus to
        // restore when ready. Do NOT wrap these in withFocusRestore, which would
        // steal focus back before the app processes the event (e.g. Cmd+L needs
        // Chrome to stay focused while it selects the address bar text).
        case "ghost_press":
            guard let key = str(args, "key") else {
                return ToolResult(success: false, error: "Missing required parameter: key")
            }
            let modifiers = (args["modifiers"] as? [String])
            return Actions.pressKey(key: key, modifiers: modifiers, appName: str(args, "app"))

        case "ghost_hotkey":
            guard let keys = args["keys"] as? [String] else {
                return ToolResult(success: false, error: "Missing required parameter: keys (array of strings)")
            }
            return Actions.hotkey(keys: keys, appName: str(args, "app"))

        case "ghost_scroll":
            guard let direction = str(args, "direction") else {
                return ToolResult(success: false, error: "Missing required parameter: direction")
            }
            return Actions.scroll(
                direction: direction,
                amount: int(args, "amount"),
                appName: str(args, "app"),
                x: double(args, "x"),
                y: double(args, "y")
            )

        case "ghost_hover":
            return Actions.hover(
                query: str(args, "query"),
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                appName: str(args, "app"),
                x: double(args, "x"),
                y: double(args, "y")
            )

        case "ghost_long_press":
            return Actions.longPress(
                query: str(args, "query"),
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                appName: str(args, "app"),
                x: double(args, "x"),
                y: double(args, "y"),
                duration: double(args, "duration"),
                button: str(args, "button")
            )

        case "ghost_drag":
            guard let toX = double(args, "to_x"),
                  let toY = double(args, "to_y")
            else {
                return ToolResult(success: false, error: "Missing required parameters: to_x, to_y")
            }
            return Actions.drag(
                query: str(args, "query"),
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                appName: str(args, "app"),
                fromX: double(args, "from_x"),
                fromY: double(args, "from_y"),
                toX: toX,
                toY: toY,
                duration: double(args, "duration"),
                holdDuration: double(args, "hold_duration")
            )

        case "ghost_focus":
            guard let app = str(args, "app") else {
                return ToolResult(success: false, error: "Missing required parameter: app")
            }
            return FocusManager.focus(appName: app, windowTitle: str(args, "window"))

        case "ghost_window":
            guard let action = str(args, "action"),
                  let app = str(args, "app")
            else {
                return ToolResult(success: false, error: "Missing required parameters: action, app")
            }
            return Actions.manageWindow(
                action: action,
                appName: app,
                windowTitle: str(args, "window"),
                x: double(args, "x"),
                y: double(args, "y"),
                width: double(args, "width"),
                height: double(args, "height")
            )

        // Wait
        case "ghost_wait":
            guard let condition = str(args, "condition") else {
                return ToolResult(success: false, error: "Missing required parameter: condition")
            }
            return WaitManager.waitFor(
                condition: condition,
                value: str(args, "value"),
                appName: str(args, "app"),
                timeout: double(args, "timeout") ?? 10,
                interval: double(args, "interval") ?? 0.5
            )

        // Recipes
        case "ghost_recipes":
            let recipes = RecipeStore.listRecipes()
            let summaries: [[String: Any]] = recipes.map { recipe in
                var summary: [String: Any] = [
                    "name": recipe.name,
                    "description": recipe.description,
                ]
                if let app = recipe.app { summary["app"] = app }
                if let params = recipe.params {
                    summary["params"] = params.map { key, param in
                        ["name": key, "type": param.type, "description": param.description,
                         "required": param.required ?? false] as [String: Any]
                    }
                }
                return summary
            }
            return ToolResult(success: true, data: ["recipes": summaries, "count": summaries.count])

        case "ghost_run":
            guard let recipeName = str(args, "recipe") else {
                return ToolResult(success: false, error: "Missing required parameter: recipe")
            }
            guard let recipe = RecipeStore.loadRecipe(named: recipeName) else {
                return ToolResult(
                    success: false,
                    error: "Recipe '\(recipeName)' not found",
                    suggestion: "Use ghost_recipes to list available recipes"
                )
            }
            // Parse params from the MCP arguments
            let recipeParams: [String: String]
            if let paramsObj = args["params"] as? [String: Any] {
                recipeParams = paramsObj.reduce(into: [:]) { result, pair in
                    result[pair.key] = "\(pair.value)"
                }
            } else {
                recipeParams = [:]
            }
            return RecipeEngine.run(recipe: recipe, params: recipeParams)

        case "ghost_recipe_show":
            guard let name = str(args, "name") else {
                return ToolResult(success: false, error: "Missing required parameter: name")
            }
            guard let recipe = RecipeStore.loadRecipe(named: name) else {
                return ToolResult(
                    success: false,
                    error: "Recipe '\(name)' not found",
                    suggestion: "Use ghost_recipes to list available recipes"
                )
            }
            if let data = try? JSONEncoder().encode(recipe),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return ToolResult(success: true, data: dict)
            }
            return ToolResult(success: false, error: "Failed to serialize recipe")

        case "ghost_recipe_save":
            guard let jsonStr = str(args, "recipe_json") else {
                return ToolResult(success: false, error: "Missing required parameter: recipe_json")
            }
            do {
                let name = try RecipeStore.saveRecipeJSON(jsonStr)
                return ToolResult(success: true, data: ["saved": name])
            } catch {
                return ToolResult(success: false, error: "Failed to save recipe: \(error)")
            }

        case "ghost_recipe_delete":
            guard let name = str(args, "name") else {
                return ToolResult(success: false, error: "Missing required parameter: name")
            }
            let deleted = RecipeStore.deleteRecipe(named: name)
            return ToolResult(
                success: deleted,
                data: deleted ? ["deleted": name] : nil,
                error: deleted ? nil : "Recipe '\(name)' not found"
            )

        // Vision
        case "ghost_parse_screen":
            return VisionPerception.parseScreen(
                appName: str(args, "app"),
                fullResolution: bool(args, "full_resolution") ?? false
            )

        case "ghost_ground":
            guard let description = str(args, "description") else {
                return ToolResult(success: false, error: "Missing required parameter: description")
            }
            let cropBox: [Double]?
            if let arr = args["crop_box"] as? [Any] {
                cropBox = arr.compactMap { val -> Double? in
                    if let d = val as? Double { return d }
                    if let i = val as? Int { return Double(i) }
                    return nil
                }
            } else {
                cropBox = nil
            }
            return VisionPerception.groundElement(
                description: description,
                appName: str(args, "app"),
                cropBox: cropBox
            )

        // Recording
        case "ghost_record_start":
            do {
                let sessionId = try recordingSession.startRecording(app: str(args, "app"))
                return ToolResult(success: true, data: ["session_id": sessionId, "status": "recording"])
            } catch {
                return ToolResult(success: false, error: "Failed to start recording: \(error.localizedDescription)")
            }

        case "ghost_record_stop":
            do {
                let sessionId = try recordingSession.stopRecording()
                return ToolResult(success: true, data: ["session_id": sessionId, "status": "stopped"])
            } catch {
                return ToolResult(success: false, error: "Failed to stop recording: \(error.localizedDescription)")
            }

        case "ghost_record_preview":
            guard let sessionId = str(args, "session_id") else {
                return ToolResult(success: false, error: "Missing required parameter: session_id")
            }
            do {
                let events = try recordingSession.previewSession(sessionId: sessionId, limit: int(args, "limit"))
                let steps = SemanticTransformer.transform(events)
                let stepsData: [[String: Any]] = steps.map { step in
                    var d: [String: Any] = [
                        "action": step.action,
                        "description": step.description,
                    ]
                    if let params = step.params { d["params"] = params }
                    if let target = step.target {
                        var t: [String: Any] = [:]
                        if let q = target.query { t["query"] = q }
                        if let r = target.role { t["role"] = r }
                        if let i = target.identifier { t["identifier"] = i }
                        if !t.isEmpty { d["target"] = t }
                    }
                    return d
                }
                return ToolResult(success: true, data: [
                    "session_id": sessionId,
                    "steps": stepsData,
                    "count": stepsData.count,
                ])
            } catch {
                return ToolResult(success: false, error: "Failed to preview session: \(error.localizedDescription)")
            }

        case "ghost_record_save":
            guard let sessionId = str(args, "session_id"),
                  let name = str(args, "name"),
                  let description = str(args, "description")
            else {
                return ToolResult(success: false, error: "Missing required parameters: session_id, name, description")
            }
            do {
                let events = try recordingSession.getSession(sessionId: sessionId)
                let steps = SemanticTransformer.transform(events)

                var recipeSteps: [RecipeStep] = []
                for (idx, step) in steps.enumerated() {
                    let locator: Locator? = step.target.map { t in
                        LocatorBuilder.build(
                            query: t.query,
                            role: t.role,
                            identifier: t.identifier
                        )
                    }
                    recipeSteps.append(RecipeStep(
                        id: idx + 1,
                        action: step.action,
                        target: locator,
                        params: step.params,
                        waitAfter: nil,
                        note: step.description,
                        onFailure: nil
                    ))
                }

                let now = ISO8601DateFormatter().string(from: Date())
                let metadata = RecordingMetadata(
                    sessionId: sessionId,
                    originalEvents: events.count,
                    durationSeconds: 0,
                    recordedAt: now
                )

                let tags = args["tags"] as? [String]
                let recipe = Recipe(
                    schemaVersion: 2,
                    name: name,
                    description: description,
                    app: nil,
                    params: nil,
                    preconditions: nil,
                    steps: recipeSteps,
                    onFailure: nil,
                    tags: tags,
                    recordedFrom: metadata
                )

                try RecipeStore.saveRecipe(recipe, toWorkflows: true)
                return ToolResult(success: true, data: [
                    "saved": name,
                    "steps": recipeSteps.count,
                    "location": "~/.ghost-os/workflows/\(name).json",
                ])
            } catch {
                return ToolResult(success: false, error: "Failed to save workflow: \(error.localizedDescription)")
            }

        case "ghost_workflow_list":
            let allRecipes = RecipeStore.listRecipes()
            let tagFilter = str(args, "tag")
            let appFilter = str(args, "app")

            let workflows = allRecipes.filter { recipe in
                // recordedFrom があるものをワークフローとして扱う
                guard recipe.recordedFrom != nil else { return false }
                if let tag = tagFilter {
                    guard let tags = recipe.tags, tags.contains(where: { $0.localizedCaseInsensitiveContains(tag) }) else { return false }
                }
                if let app = appFilter {
                    guard let recipeApp = recipe.app, recipeApp.localizedCaseInsensitiveContains(app) else { return false }
                }
                return true
            }

            let summaries: [[String: Any]] = workflows.map { r in
                var d: [String: Any] = ["name": r.name, "description": r.description, "steps": r.steps.count]
                if let tags = r.tags { d["tags"] = tags }
                if let app = r.app { d["app"] = app }
                if let meta = r.recordedFrom { d["recorded_at"] = meta.recordedAt }
                return d
            }
            return ToolResult(success: true, data: ["workflows": summaries, "count": summaries.count])

        case "ghost_workflow_search":
            guard let query = str(args, "query") else {
                return ToolResult(success: false, error: "Missing required parameter: query")
            }
            let allRecipes = RecipeStore.listRecipes()
            let lq = query.lowercased()

            let matched = allRecipes.filter { recipe in
                if recipe.name.lowercased().contains(lq) { return true }
                if recipe.description.lowercased().contains(lq) { return true }
                if let tags = recipe.tags, tags.contains(where: { $0.lowercased().contains(lq) }) { return true }
                return false
            }

            let results: [[String: Any]] = matched.map { r in
                var d: [String: Any] = ["name": r.name, "description": r.description, "steps": r.steps.count]
                if let tags = r.tags { d["tags"] = tags }
                if let meta = r.recordedFrom { d["recorded_at"] = meta.recordedAt }
                return d
            }
            return ToolResult(success: true, data: ["results": results, "count": results.count, "query": query])

        // Passive Capture
        case "ghost_capture_status":
            return ToolResult(success: true, data: [
                "running": passiveCapture.isRunning,
                "buffer_count": passiveCapture.bufferCount,
                "detected_patterns": patternDetector.detectedCount,
            ])

        case "ghost_capture_save":
            guard let name = str(args, "name"),
                  let description = str(args, "description")
            else {
                return ToolResult(success: false, error: "Missing required parameters: name, description")
            }
            let seconds = int(args, "seconds") ?? 60
            let actions = passiveCapture.saveRecent(seconds: seconds)
            guard !actions.isEmpty else {
                return ToolResult(
                    success: false,
                    error: "バッファに直近\(seconds)秒のアクションがありません",
                    suggestion: "パッシブキャプチャが起動中か確認してください (ghost_capture_status)"
                )
            }
            let recipeJSON = WorkflowExtractor.extract(
                actions: actions, name: name, description: description
            )
            do {
                let savedName = try RecipeStore.saveRecipeJSON(recipeJSON)
                return ToolResult(success: true, data: [
                    "saved": savedName,
                    "actions_captured": actions.count,
                    "seconds": seconds,
                    "location": "~/.ghost-os/workflows/\(savedName).json",
                ])
            } catch {
                return ToolResult(success: false, error: "ワークフロー保存に失敗: \(error.localizedDescription)")
            }

        case "ghost_capture_patterns":
            let patterns = patternDetector.detectedPatterns
            let data: [[String: Any]] = patterns.map { p in
                [
                    "pattern_hash": p.patternHash,
                    "count": p.count,
                    "description": p.description,
                    "action_count": p.actions.count,
                ]
            }
            return ToolResult(success: true, data: [
                "patterns": data,
                "count": data.count,
            ])

        default:
            return ToolResult(success: false, error: "Unknown tool: \(tool)")
        }
    }

    // MARK: - Response Formatting

    /// Format a ToolResult as MCP content array.
    private static func formatResult(_ result: ToolResult, toolName: String) -> [String: Any] {
        let dict = result.toDict()

        // Serialize to JSON string for MCP text content
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let jsonStr = String(data: data, encoding: .utf8)
        {
            return [
                "content": [
                    ["type": "text", "text": jsonStr],
                ],
                "isError": !result.success,
            ]
        }

        return errorContent("Failed to serialize response for \(toolName)")
    }

    static func errorContent(_ message: String) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": "{\"success\":false,\"error\":\"\(message)\"}"],
            ],
            "isError": true,
        ]
    }

    // MARK: - Parameter Helpers

    private static func str(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        return nil
    }

    private static func double(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        return nil
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }
}
