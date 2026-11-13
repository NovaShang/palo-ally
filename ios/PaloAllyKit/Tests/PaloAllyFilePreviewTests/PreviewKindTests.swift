import Foundation
import Testing
@testable import PaloAllyFilePreview

/// One decision for how a file opens, from 成果 and from the file tree alike.
struct PreviewKindTests {
    @Test func byName() {
        #expect(PreviewKind.classify(name: "README.md") == .markdown)
        #expect(PreviewKind.classify(name: "index.html") == .html)
        #expect(PreviewKind.classify(name: "a/图纸.pdf") == .pdf)
        #expect(PreviewKind.classify(name: "site.JPG") == .image)
        #expect(PreviewKind.classify(name: "anim.gif") == .quickLook)
        #expect(PreviewKind.classify(name: "logo.svg") == .quickLook)
        #expect(PreviewKind.classify(name: "intro.mov") == .video)
        #expect(PreviewKind.classify(name: "clip.mp4") == .video)
        #expect(PreviewKind.classify(name: "memo.m4a") == .audio)
        #expect(PreviewKind.classify(name: "plan.docx") == .office)
        #expect(PreviewKind.classify(name: "budget.xlsx") == .office)
        #expect(PreviewKind.classify(name: "deck.key") == .office)
        #expect(PreviewKind.classify(name: "spending.csv") == .text)
        #expect(PreviewKind.classify(name: "notes.txt") == .text)
        #expect(PreviewKind.classify(name: "app.ts") == .text)
        #expect(PreviewKind.classify(name: "archive.zip") == .quickLook)
    }

    @Test func aLibraryItemsTypeAndTheBytesDecideWhatTheNameDoesnt() {
        #expect(PreviewKind.classify(name: "brief", hint: .markdown) == .markdown)
        #expect(PreviewKind.classify(name: "page.txt", hint: .html) == .html)
        #expect(PreviewKind.classify(name: "report", mediaType: "application/pdf") == .pdf)
        #expect(PreviewKind.classify(name: "shot", mediaType: "image/png") == .image)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        #expect(PreviewKind.classify(name: "noext", head: png) == .image)
        #expect(PreviewKind.classify(name: "data.bin2", head: Data([1, 0, 2])) == .quickLook)
        #expect(PreviewKind.classify(name: "Makefile", head: Data("all:\n".utf8)) == .text)
    }
}
