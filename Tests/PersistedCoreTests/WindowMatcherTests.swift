import Testing
import PersistedCore

@Suite("Conservative window matching")
struct WindowMatcherTests {
    @Test func uniqueTitlesAndDocumentsMatchOneToOne() {
        let one = CoreFixtures.live(1, title: "Document A", document: "file:///a")
        let two = CoreFixtures.live(2, title: "Document B")
        let saved = [CoreFixtures.saved(one), CoreFixtures.saved(two)]
        var changed = one
        changed.id = CoreFixtures.id(11)
        changed.identity.title = "A — Edited"
        let result = WindowMatcher.match(saved: saved, live: [two, changed, CoreFixtures.live(3, title: "Extra")])
        #expect(result.matches[saved[0].id]?.id == changed.id)
        #expect(result.matches[saved[1].id]?.id == two.id)
        #expect(result.ambiguous.isEmpty)
        #expect(Set(result.matches.values.map(\.id)).count == 2)
    }

    @Test func duplicateTitlesNeverSwapBasedOnGeometryOrInputOrder() {
        let one = CoreFixtures.live(1, title: "Browser", frame: Rect(x: 10, y: 30, width: 600, height: 500))
        let two = CoreFixtures.live(2, title: "Browser", frame: Rect(x: 700, y: 30, width: 600, height: 500))
        let saved = [CoreFixtures.saved(one), CoreFixtures.saved(two)]
        let result = WindowMatcher.match(saved: saved, live: [two, one])
        #expect(result.matches.isEmpty)
        #expect(result.ambiguous == Set(saved.map(\.id)))
        let reversed = WindowMatcher.match(saved: saved.reversed(), live: [one, two])
        #expect(reversed.matches.isEmpty)
        #expect(reversed.ambiguous == result.ambiguous)
    }

    @Test func validatedReferenceSurvivesTitleChangesWithinProcess() {
        let one = CoreFixtures.live(1, title: "Browser")
        let two = CoreFixtures.live(2, title: "Browser")
        let saved = [CoreFixtures.saved(one), CoreFixtures.saved(two)]
        var changed = one
        changed.identity.title = "A new tab"
        let result = WindowMatcher.match(saved: saved, live: [changed, two], references: [saved[0].id: one.id, saved[1].id: two.id])
        #expect(result.matches.count == 2)
        #expect(result.matches[saved[0].id]?.id == one.id)
    }

    @Test func referencesFromOtherLayoutsDoNotConsumeCurrentWindow() {
        let live = CoreFixtures.live()
        let saved = CoreFixtures.saved(live)
        let references = [saved.id: live.id, CoreFixtures.id(9999): live.id]
        let result = WindowMatcher.match(saved: [saved], live: [live], references: references)
        #expect(result.matches[saved.id]?.id == live.id)
        #expect(result.ambiguous.isEmpty)
    }

    @Test func optionalAccessibilityIdentifierRequiresTitleCorroboration() {
        let previous = CoreFixtures.live(title: "Old document", accessibility: "window-1")
        let saved = CoreFixtures.saved(previous)
        let reused = CoreFixtures.live(11, title: "New document", accessibility: "window-1", launch: 30)
        let result = WindowMatcher.match(saved: [saved], live: [reused])
        #expect(result.matches.isEmpty)
        #expect(result.ambiguous.isEmpty)
        var corroborated = reused
        corroborated.identity.title = previous.identity.title
        #expect(WindowMatcher.match(saved: [saved], live: [corroborated]).matches[saved.id]?.id == corroborated.id)
    }

    @Test func diaWindowIdentifierSurvivesTabTitleAndDocumentChangesWithoutReferences() {
        let identifier = "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93"
        let saved = CoreFixtures.saved(CoreFixtures.live(title: "Ripple — Local control", bundle: "company.thebrowser.dia",
            document: "https://example.com/ripple", accessibility: identifier))
        let live = CoreFixtures.live(11, title: "Another tab", bundle: "company.thebrowser.dia",
            document: "https://example.com/another", accessibility: identifier)
        let result = WindowMatcher.match(saved: [saved], live: [live])
        #expect(result.matches[saved.id]?.id == live.id)
        #expect(result.ambiguous.isEmpty)
    }

    @Test func diaWindowIdentifiersOutweighSwappedTabTitlesAndDocuments() {
        let first = CoreFixtures.live(1, title: "First tab", bundle: "company.thebrowser.dia",
            document: "https://example.com/first", accessibility: "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93")
        let second = CoreFixtures.live(2, title: "Second tab", bundle: "company.thebrowser.dia",
            document: "https://example.com/second", accessibility: "bigBrowserWindow_22222222-3333-4444-8555-666666666666")
        let saved = [CoreFixtures.saved(first), CoreFixtures.saved(second)]
        var changedFirst = first, changedSecond = second
        changedFirst.id = CoreFixtures.id(11); changedSecond.id = CoreFixtures.id(12)
        changedFirst.identity.title = second.identity.title; changedFirst.identity.documentID = second.identity.documentID
        changedSecond.identity.title = first.identity.title; changedSecond.identity.documentID = first.identity.documentID
        for live in [[changedSecond, changedFirst], [changedFirst, changedSecond]] {
            let result = WindowMatcher.match(saved: saved, live: live)
            #expect(result.matches[saved[0].id]?.id == changedFirst.id)
            #expect(result.matches[saved[1].id]?.id == changedSecond.id)
            #expect(result.ambiguous.isEmpty)
        }
    }

    @Test func duplicateDiaWindowIdentifiersRemainAmbiguous() {
        let first = CoreFixtures.live(1, title: "First tab", bundle: "company.thebrowser.dia",
            accessibility: "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93")
        var second = first
        second.id = CoreFixtures.id(12); second.identity.title = "Another tab"
        let saved = CoreFixtures.saved(first)
        let duplicateLive = WindowMatcher.match(saved: [saved], live: [first, second])
        #expect(duplicateLive.matches.isEmpty)
        #expect(duplicateLive.ambiguous == [saved.id])
        var duplicateSaved = saved
        duplicateSaved.id = CoreFixtures.id(2002)
        let duplicateTargets = WindowMatcher.match(saved: [saved, duplicateSaved], live: [first])
        #expect(duplicateTargets.matches.isEmpty)
        #expect(duplicateTargets.ambiguous == [saved.id, duplicateSaved.id])
    }

    @Test func diaIdentifierExceptionDoesNotTrustOtherAppsOrMalformedIdentifiers() {
        let cases = [
            ("example.browser", "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93"),
            ("company.thebrowser.dia", "bigBrowserWindow_window-1"),
            ("company.thebrowser.dia", "otherWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93"),
            ("company.thebrowser.dia", "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93-extra")
        ]
        for (bundle, identifier) in cases {
            let saved = CoreFixtures.saved(CoreFixtures.live(title: "Old tab", bundle: bundle, accessibility: identifier))
            let live = CoreFixtures.live(11, title: "New tab", bundle: bundle, accessibility: identifier)
            let result = WindowMatcher.match(saved: [saved], live: [live])
            #expect(result.matches.isEmpty)
            #expect(result.ambiguous.isEmpty)
        }
    }

    @Test func diaIdentifierChangesRetainExistingTitleFallback() {
        let saved = CoreFixtures.saved(CoreFixtures.live(title: "Returning tab", bundle: "company.thebrowser.dia",
            accessibility: "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93"))
        let reopened = CoreFixtures.live(11, title: "Returning tab", bundle: "company.thebrowser.dia",
            accessibility: "bigBrowserWindow_22222222-3333-4444-8555-666666666666", launch: 30)
        #expect(WindowMatcher.match(saved: [saved], live: [reopened]).matches[saved.id]?.id == reopened.id)
        var unrelated = reopened
        unrelated.identity.title = "Unrelated tab"
        #expect(WindowMatcher.match(saved: [saved], live: [unrelated]).matches.isEmpty)
    }

    @Test func diaIdentifierDoesNotOverrideExplicitTitleRules() {
        let identifier = "bigBrowserWindow_444BF09E-3F7E-463C-83FE-01EF3DFA6C93"
        var saved = CoreFixtures.saved(CoreFixtures.live(title: "Project tab", bundle: "company.thebrowser.dia", accessibility: identifier))
        var live = CoreFixtures.live(11, title: "Unrelated tab", bundle: "company.thebrowser.dia", accessibility: identifier)
        saved.matchingRule = .exactTitle("Project tab")
        #expect(WindowMatcher.match(saved: [saved], live: [live]).matches.isEmpty)
        saved.matchingRule = .titleContains("Project")
        #expect(WindowMatcher.match(saved: [saved], live: [live]).matches.isEmpty)
        live.identity.title = "Project tab — Updated"
        #expect(WindowMatcher.match(saved: [saved], live: [live]).matches[saved.id]?.id == live.id)
    }

    @Test func restartIncludingReusedPIDInvalidatesOpaqueReferences() {
        let previous = CoreFixtures.live(1, title: "Browser")
        let saved = [CoreFixtures.saved(previous), CoreFixtures.saved(CoreFixtures.live(2, title: "Browser"))]
        let restarted = [CoreFixtures.live(11, title: "Browser", launch: 30), CoreFixtures.live(12, title: "Browser", launch: 30)]
        #expect(previous.instance.pid == restarted[0].instance.pid)
        #expect(previous.instance != restarted[0].instance)
        let result = WindowMatcher.match(saved: saved, live: restarted, references: [saved[0].id: previous.id])
        #expect(result.matches.isEmpty)
        #expect(result.ambiguous.count == 2)
    }

    @Test func twoSavedEntriesCannotConsumeSameWindow() {
        let live = CoreFixtures.live()
        let first = CoreFixtures.saved(live)
        var second = first
        second.id = CoreFixtures.id(2002)
        let result = WindowMatcher.match(saved: [first, second], live: [live])
        #expect(result.matches.isEmpty)
        #expect(result.ambiguous == [first.id, second.id])
        let conflictingReferences = WindowMatcher.match(saved: [first, second], live: [live], references: [first.id: live.id, second.id: live.id])
        #expect(conflictingReferences.matches.isEmpty)
        #expect(conflictingReferences.ambiguous.count == 2)
    }

    @Test func strongDocumentEvidenceResolvesRemainingTitleMatch() {
        let one = CoreFixtures.live(1, title: "Untitled", document: "file:///one")
        let two = CoreFixtures.live(2, title: "Untitled")
        let saved = [CoreFixtures.saved(one), CoreFixtures.saved(two)]
        let result = WindowMatcher.match(saved: saved, live: [two, one])
        #expect(result.matches[saved[0].id]?.id == one.id)
        #expect(result.matches[saved[1].id]?.id == two.id)
    }

    @Test func knownDifferentDocumentOutweighsSameTitle() {
        let saved = CoreFixtures.saved(CoreFixtures.live(document: "file:///first"))
        let live = CoreFixtures.live(2, document: "file:///second")
        #expect(WindowMatcher.match(saved: [saved], live: [live]).matches.isEmpty)
    }

    @Test func explicitTitleRulesAreStillAmbiguityGated() {
        var saved = CoreFixtures.saved()
        saved.matchingRule = .titleContains("Project")
        let one = CoreFixtures.live(1, title: "Project - editor")
        let two = CoreFixtures.live(2, title: "Project - browser")
        #expect(WindowMatcher.match(saved: [saved], live: [one]).matches[saved.id]?.id == one.id)
        #expect(WindowMatcher.match(saved: [saved], live: [one, two]).ambiguous == [saved.id])
        saved.matchingRule = .exactTitle("Project - editor")
        #expect(WindowMatcher.match(saved: [saved], live: [one, two]).matches[saved.id]?.id == one.id)
    }

    @Test func unknownWindowCannotBeMatchedByApplicationAlone() {
        let saved = CoreFixtures.saved(CoreFixtures.live(title: ""))
        #expect(WindowMatcher.match(saved: [saved], live: [CoreFixtures.live(2, title: "")]).matches.isEmpty)
        var wrongRole = CoreFixtures.live()
        wrongRole.identity.subrole = "AXDialog"
        #expect(WindowMatcher.match(saved: [CoreFixtures.saved()], live: [wrongRole]).matches.isEmpty)
        #expect(WindowMatcher.match(saved: [CoreFixtures.saved()], live: [CoreFixtures.live(bundle: "other.app")]).matches.isEmpty)
    }
}
