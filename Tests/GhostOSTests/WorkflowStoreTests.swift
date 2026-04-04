// WorkflowStoreTests.swift - RecipeTypes 拡張フィールドのテスト

import Testing
@testable import GhostOS

// JSONDecoder/Data は Foundation に依存するため、GhostOS 経由でインポート
import struct Foundation.Data
import class Foundation.JSONDecoder

@Suite("WorkflowStore / RecipeTypes Tests")
struct WorkflowStoreTests {

    // MARK: - tags

    @Test("tags付きレシピのデコード")
    func decodeRecipeWithTags() throws {
        let json = """
        {
            "schema_version": 2,
            "name": "tagged-recipe",
            "description": "A recipe with tags",
            "steps": [],
            "tags": ["automation", "mail"]
        }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(recipe.tags == ["automation", "mail"])
        #expect(recipe.recordedFrom == nil)
    }

    // MARK: - recorded_from

    @Test("recorded_from付きレシピのデコード")
    func decodeRecipeWithRecordedFrom() throws {
        let json = """
        {
            "schema_version": 2,
            "name": "recorded-recipe",
            "description": "A recipe from recording",
            "steps": [],
            "recorded_from": {
                "session_id": "abc123",
                "original_events": 42,
                "duration_seconds": 15.5,
                "recorded_at": "2026-04-04T00:00:00Z"
            }
        }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        let meta = try #require(recipe.recordedFrom)
        #expect(meta.sessionId == "abc123")
        #expect(meta.originalEvents == 42)
        #expect(meta.durationSeconds == 15.5)
        #expect(meta.recordedAt == "2026-04-04T00:00:00Z")
        #expect(recipe.tags == nil)
    }

    // MARK: - element_exists

    @Test("element_exists付きpreconditionsのデコード")
    func decodeRecipeWithElementExists() throws {
        let json = """
        {
            "schema_version": 2,
            "name": "precond-recipe",
            "description": "A recipe with element_exists precondition",
            "steps": [],
            "preconditions": {
                "app_running": "Safari",
                "element_exists": "//button[@id='submit']"
            }
        }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        let pre = try #require(recipe.preconditions)
        #expect(pre.appRunning == "Safari")
        #expect(pre.elementExists == "//button[@id='submit']")
        #expect(pre.urlContains == nil)
    }

    // MARK: - 後方互換性

    @Test("新フィールドなし既存レシピの後方互換性")
    func decodeBackwardCompatibleRecipe() throws {
        let json = """
        {
            "schema_version": 2,
            "name": "legacy-recipe",
            "description": "An old recipe without new fields",
            "steps": [
                {
                    "id": 1,
                    "action": "click",
                    "params": {"text": "OK"}
                }
            ]
        }
        """
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(recipe.name == "legacy-recipe")
        #expect(recipe.tags == nil)
        #expect(recipe.recordedFrom == nil)
        #expect(recipe.preconditions == nil)
        #expect(recipe.steps.count == 1)
    }
}
