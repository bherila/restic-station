import AppKit
import Testing
@testable import Restic_Station

@Suite("Native run log", .serialized)
@MainActor
struct RunLogTextViewTests {
    @Test("Large logs use on-demand layout and preserve selection as output appends")
    func largeLogAppend() throws {
        let text = String(repeating: "synthetic backup output\n", count: 30_000)
        let presenter = RunLogTextView(text: text, isPlaceholder: false, followTail: false)
        let scroll = presenter.makeScrollView()
        let coordinator = presenter.makeCoordinator()
        presenter.update(scroll, coordinator: coordinator)
        let view = try #require(scroll.documentView as? NSTextView)
        #expect(view.layoutManager?.allowsNonContiguousLayout == true)
        #expect(view.layoutManager?.backgroundLayoutEnabled == false)
        #expect(!view.isEditable && view.isSelectable)
        let selection = NSRange(location: 10, length: 100)
        view.setSelectedRange(selection)
        RunLogTextView(text: text + "new output\n", isPlaceholder: false, followTail: false)
            .update(scroll, coordinator: coordinator)
        #expect(view.string == text + "new output\n")
        #expect(view.selectedRange() == selection)
    }

    @Test("Trimmed output replaces old text instead of splicing log generations")
    func replacement() throws {
        let presenter = RunLogTextView(text: "old output\n", isPlaceholder: false, followTail: false)
        let scroll = presenter.makeScrollView()
        let coordinator = presenter.makeCoordinator()
        presenter.update(scroll, coordinator: coordinator)
        RunLogTextView(text: "… earlier output truncated\nrecent output\n", isPlaceholder: false, followTail: false)
            .update(scroll, coordinator: coordinator)
        let view = try #require(scroll.documentView as? NSTextView)
        #expect(view.string == "… earlier output truncated\nrecent output\n")
        #expect(!view.string.contains("old output"))
    }
}
