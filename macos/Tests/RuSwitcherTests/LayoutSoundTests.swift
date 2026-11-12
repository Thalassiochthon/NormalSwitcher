import Testing
@testable import RuSwitcher

struct LayoutSoundTests {
    @Test func defaultsAreDistinctAndFollowSourceIdentity() {
        let sources = ["ru", "abc", "es", "de"]
        let saved = LayoutSound.assignments([:], sources: sources, legacy: nil, first: "ru", second: "abc")
        #expect(Set(saved.values).count == 4)
        let reordered = LayoutSound.assignments(saved, sources: ["de", "abc", "it", "es"],
                                               legacy: nil, first: "abc", second: "es")
        #expect(reordered["ru"] == saved["ru"])
        #expect(reordered["es"] == saved["es"])
        #expect(reordered["it"] != nil)
        let restored = LayoutSound.assignments(reordered, sources: sources, legacy: nil, first: "ru", second: "abc")
        #expect(restored == reordered)
    }

    @Test func legacySoundMigratesWithoutOverwritingSavedChoices() {
        let saved = LayoutSound.assignments(["ru": "silent", "de": "unknown"],
                                           sources: ["ru", "abc", "es", "de"], legacy: "Pop",
                                           first: "ru", second: "abc")
        #expect(saved["ru"] == "silent")
        #expect(saved["abc"] == "wood")
        #expect(saved["es"] == "wood")
        #expect(LayoutSound.choices.contains { $0.rawValue == saved["de"] })
        #expect(LayoutSound.assignments(saved, sources: ["ru", "abc", "es", "de"], legacy: "Pop",
                                        first: "ru", second: "abc") == saved)
    }

    @Test func automaticMigrationResolvesOldPairByID() {
        let saved = LayoutSound.assignments([:], sources: ["es", "abc", "ru"], legacy: "automatic",
                                           first: "ru", second: "abc")
        #expect(saved == ["ru": "tap", "abc": "soft", "es": "drop"])
    }

    @Test func confirmedTransitionsDeduplicateNotifications() {
        var state = LayoutSoundTransition()
        let updates = ["", "abc", "abc", "ru", "ru", "", "es", "abc"]
        let changes = updates.map { state.update($0) }
        #expect(changes == [false, false, false, true, false, false, true, true])
    }
}
