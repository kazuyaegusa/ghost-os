// RecipeStore.swift - File-based recipe storage
//
// Loads/saves/lists/deletes recipes from ~/.ghost-os/recipes/
// Also searches ~/.ghost-os/workflows/ for operation recordings.
// Logs decode errors so broken recipes are visible, not silently skipped.

import Foundation

/// File-based recipe storage.
public enum RecipeStore {

    private static let recipesDir = NSString(string: "~/.ghost-os/recipes").expandingTildeInPath
    private static let workflowsDir = NSString(string: "~/.ghost-os/workflows").expandingTildeInPath

    /// List all available recipes. Logs decode errors for broken recipe files.
    /// Searches both recipes/ and workflows/ directories.
    public static func listRecipes() -> [Recipe] {
        let fm = FileManager.default
        ensureDirectory()

        var recipes: [Recipe] = []
        let decoder = JSONDecoder()

        func loadFrom(dir: String) {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for file in files where file.hasSuffix(".json") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: path) else { continue }
                do {
                    let recipe = try decoder.decode(Recipe.self, from: data)
                    recipes.append(recipe)
                } catch {
                    Log.warn("Failed to decode recipe '\(file)': \(error)")
                }
            }
        }

        loadFrom(dir: recipesDir)
        // workflows/ は存在しない場合はスキップ
        if fm.fileExists(atPath: workflowsDir) {
            loadFrom(dir: workflowsDir)
        }

        return recipes.sorted { $0.name < $1.name }
    }

    /// Load a specific recipe by name. Searches recipes/ first, then workflows/.
    /// Returns nil with logged error if decode fails.
    public static func loadRecipe(named name: String) -> Recipe? {
        let recipePath = (recipesDir as NSString).appendingPathComponent("\(name).json")
        let workflowPath = (workflowsDir as NSString).appendingPathComponent("\(name).json")

        let fm = FileManager.default
        let candidates: [String]
        if fm.fileExists(atPath: workflowsDir) {
            candidates = [recipePath, workflowPath]
        } else {
            candidates = [recipePath]
        }

        for path in candidates {
            guard let data = fm.contents(atPath: path) else { continue }
            do {
                return try JSONDecoder().decode(Recipe.self, from: data)
            } catch {
                Log.error("Failed to decode recipe '\(name)' at \(path): \(error)")
                return nil
            }
        }

        Log.info("Recipe '\(name)' not found in recipes/ or workflows/")
        return nil
    }

    /// Save a recipe.
    /// - Parameters:
    ///   - recipe: 保存するレシピ
    ///   - toWorkflows: trueのとき workflows/ に保存。デフォルトは false（recipes/ に保存）
    public static func saveRecipe(_ recipe: Recipe, toWorkflows: Bool = false) throws {
        if toWorkflows {
            try FileManager.default.createDirectory(
                atPath: workflowsDir,
                withIntermediateDirectories: true
            )
        } else {
            ensureDirectory()
        }
        let dir = toWorkflows ? workflowsDir : recipesDir
        let path = (dir as NSString).appendingPathComponent("\(recipe.name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recipe)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Delete a recipe by name.
    public static func deleteRecipe(named name: String) -> Bool {
        let path = (recipesDir as NSString).appendingPathComponent("\(name).json")
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Save a recipe from raw JSON string. Returns recipe name on success.
    /// Validates the JSON parses correctly before saving.
    public static func saveRecipeJSON(_ jsonString: String) throws -> String {
        guard let data = jsonString.data(using: .utf8) else {
            throw GhostError.invalidParameter("Invalid JSON string")
        }
        do {
            let recipe = try JSONDecoder().decode(Recipe.self, from: data)
            try saveRecipe(recipe)
            return recipe.name
        } catch let decodingError as DecodingError {
            // Give the agent a helpful error message about what's wrong with the JSON
            let detail: String
            switch decodingError {
            case let .keyNotFound(key, context):
                detail = "Missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case let .typeMismatch(type, context):
                detail = "Type mismatch: expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case let .valueNotFound(type, context):
                detail = "Missing value of type \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case let .dataCorrupted(context):
                detail = "Corrupted data at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
            @unknown default:
                detail = "\(decodingError)"
            }
            throw GhostError.invalidParameter("Recipe JSON decode error: \(detail)")
        }
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: recipesDir,
            withIntermediateDirectories: true
        )
    }
}
