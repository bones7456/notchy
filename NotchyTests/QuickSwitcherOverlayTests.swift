import Testing
@testable import Notchy

/// Tests for `QuickSwitcherOverlay.fuzzyMatch` — the case-insensitive
/// subsequence filter behind the ⌘K quick switcher. Every character of the
/// query must appear in the text in order, but not necessarily contiguously.
@MainActor
@Suite("QuickSwitcher fuzzyMatch")
struct QuickSwitcherOverlayTests {

    @Test("An empty query matches anything, including empty text")
    func emptyQueryMatchesAll() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "", in: "Notchy"))
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "", in: ""))
    }

    @Test("A contiguous substring matches")
    func contiguousSubstring() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "otch", in: "Notchy"))
    }

    @Test("A non-contiguous subsequence matches")
    func nonContiguousSubsequence() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "ntc", in: "Notchy"))
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "ace", in: "abcde"))
    }

    @Test("Matching is case-insensitive in both directions")
    func caseInsensitive() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "NOT", in: "notchy"))
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "abc", in: "ABC"))
    }

    @Test("Order matters — a scrambled query does not match")
    func orderMatters() {
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "cba", in: "abc"))
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "cab", in: "abc"))
    }

    @Test("A query with a character absent from the text fails")
    func missingCharacter() {
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "abz", in: "abc"))
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "x", in: "abc"))
    }

    @Test("A query longer than the text cannot match")
    func queryLongerThanText() {
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "abcd", in: "abc"))
    }

    @Test("Repeated query characters need that many occurrences, in order")
    func repeatedCharacters() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "aaa", in: "banana"))  // 3 a's
        #expect(!QuickSwitcherOverlay.fuzzyMatch(query: "aaaa", in: "banana")) // only 3
    }

    @Test("Spaces in the text are matched like any other character")
    func spacesInText() {
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "myapp", in: "my app"))
        #expect(QuickSwitcherOverlay.fuzzyMatch(query: "my app", in: "my app"))
    }
}
