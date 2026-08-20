import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Chat rich content — fenced code and link policy")
struct ChatRichContentTests {

    // MARK: - The defect this unit exists to fix

    /// NEGATIVE CONTROL. This is the exact measured corruption from the audit:
    /// with the block splitter removed and the message sent whole through the
    /// inline-only markdown parser, the interior newlines COLLAPSE and the
    /// language tag glues onto the first line of code. If someone deletes the
    /// splitter, this test is what fails.
    @Test func inlineOnlyMarkdownAloneDestroysFencedCode() throws {
        let content = "Here:\n```swift\nlet x = 1\nlet y = 2\n```\ndone"
        let attributed = try AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        let plain = String(attributed.characters)

        // The premise: the old path really is lossy, not merely unstyled.
        #expect(!plain.contains("let x = 1\nlet y = 2"),
                "Premise broken: inline-only parsing no longer collapses code newlines, so this unit's motivation is gone.")
        #expect(plain.contains("swift let x = 1"),
                "Premise broken: the language tag no longer glues onto the code.")
    }

    /// And the fix: the same input, through the shipped splitter, keeps the
    /// code byte-exact with its newlines.
    @Test func splitterPreservesFencedCodeExactly() {
        let content = "Here:\n```swift\nlet x = 1\nlet y = 2\n```\ndone"
        let blocks = ChatRichContentParser.blocks(content)

        #expect(blocks == [
            .prose("Here:"),
            .code(language: "swift", code: "let x = 1\nlet y = 2"),
            .prose("done"),
        ])
    }

    // MARK: - Splitter behaviour

    @Test func contentWithoutAnyFenceIsOneProseBlock() {
        let content = "- a list\n# a heading\n> a quote\n| a | b |"
        // Deliberate: lists, headings, quotes and tables are NOT structured.
        // They already survive verbatim; styling them was the cut.
        #expect(ChatRichContentParser.blocks(content) == [.prose(content)])
    }

    @Test func fenceWithoutLanguageHasNilLanguage() {
        #expect(ChatRichContentParser.blocks("```\nplain\n```")
                == [.code(language: nil, code: "plain")])
    }

    @Test func unterminatedFenceTakesTheRemainderAsCode() {
        // A cancelled or truncated turn still shows its snippet as a snippet.
        #expect(ChatRichContentParser.blocks("intro\n```py\nx = 1\ny = 2")
                == [.prose("intro"), .code(language: "py", code: "x = 1\ny = 2")])
    }

    @Test func backticksInsideACodeBlockDoNotCloseIt() {
        let content = "```md\nuse `inline` here\nand ``double`` too\n```"
        #expect(ChatRichContentParser.blocks(content)
                == [.code(language: "md", code: "use `inline` here\nand ``double`` too")])
    }

    @Test func longerClosingFenceIsAcceptedAndShorterOneIsNot() {
        #expect(ChatRichContentParser.blocks("````\na\n````")
                == [.code(language: nil, code: "a")])
        // A 3-backtick line inside a 4-backtick fence is content, not a close.
        #expect(ChatRichContentParser.blocks("````\n```\n````")
                == [.code(language: nil, code: "```")])
    }

    @Test func interiorIndentationAndBlankLinesSurvive() {
        let code = "def f():\n\n    return 1"
        #expect(ChatRichContentParser.blocks("```py\n\(code)\n```")
                == [.code(language: "py", code: code)])
    }

    @Test func multipleFencesAlternateWithProse() {
        let blocks = ChatRichContentParser.blocks("a\n```\n1\n```\nb\n```\n2\n```\nc")
        #expect(blocks == [
            .prose("a"),
            .code(language: nil, code: "1"),
            .prose("b"),
            .code(language: nil, code: "2"),
            .prose("c"),
        ])
    }

    @Test func whitespaceOnlyProseBetweenFencesIsDropped() {
        // Otherwise an empty Text opens a visible gap between two blocks.
        let blocks = ChatRichContentParser.blocks("```\n1\n```\n\n```\n2\n```")
        #expect(blocks == [
            .code(language: nil, code: "1"),
            .code(language: nil, code: "2"),
        ])
    }

    @Test func emptyContentStaysASingleProseBlock() {
        #expect(ChatRichContentParser.blocks("") == [.prose("")])
    }

    // MARK: - Purity

    @Test func splittingIsAPureFunctionOfContent() {
        let content = "x\n```swift\nlet a = 1\n```\ny"
        let first = ChatRichContentParser.blocks(content)
        for _ in 0..<50 {
            #expect(ChatRichContentParser.blocks(content) == first)
        }
    }

    @Test func cacheReturnsTheSameBlocksAsTheParser() {
        let content = "hello\n```rust\nfn main() {}\n```"
        #expect(ChatRichContentCache.blocks(content) == ChatRichContentParser.blocks(content))
        // Second read is the cached path and must not differ.
        #expect(ChatRichContentCache.blocks(content) == ChatRichContentParser.blocks(content))
    }

    // MARK: - Untrusted content

    @Test func dangerousLinkSchemesAreNotLiveLinks() throws {
        let raw = try AttributedString(
            markdown: "[click](javascript:alert(1)) and [f](file:///etc/passwd) and [ok](https://example.com)",
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        // Premise: the parser really does build live links for these schemes.
        let rawSchemes = raw.runs.compactMap { $0.link?.scheme?.lowercased() }
        #expect(rawSchemes.contains("javascript"))
        #expect(rawSchemes.contains("file"))

        let safe = ChatLinkPolicy.sanitized(raw)
        let safeSchemes = safe.runs.compactMap { $0.link?.scheme?.lowercased() }
        #expect(!safeSchemes.contains("javascript"))
        #expect(!safeSchemes.contains("file"))
        #expect(safeSchemes.contains("https"))
        // The label text is never hidden — only the link is removed.
        #expect(String(safe.characters) == String(raw.characters))
    }

    @Test func linkPolicyAllowsOnlyWebAndMailSchemes() throws {
        for allowed in ["https://x.com", "http://x.com", "mailto:a@b.com"] {
            #expect(ChatLinkPolicy.isAllowed(try #require(URL(string: allowed))))
        }
        for denied in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<b>",
                       "nativeagent://run", "ftp://host/x"] {
            #expect(!ChatLinkPolicy.isAllowed(try #require(URL(string: denied))))
        }
    }

    @Test func cachedMarkdownPathAppliesTheLinkPolicy() throws {
        let attributed = try #require(
            ChatMarkdownCache.attributed("[bad](javascript:alert(1)) [good](https://example.com)")
        )
        let schemes = attributed.runs.compactMap { $0.link?.scheme?.lowercased() }
        #expect(!schemes.contains("javascript"),
                "The shared transcript markdown cache must sanitize link schemes.")
        #expect(schemes.contains("https"))
    }

    // MARK: - Defects found in the adversarial pass over this diff

    /// A message can legitimately repeat the same snippet or the same line.
    /// Content-derived `ForEach` ids collided on exactly this input.
    @Test func repeatedIdenticalBlocksAreDistinctPositions() {
        let blocks = ChatRichContentParser.blocks("same\n```\nx\n```\nsame\n```\nx\n```")
        #expect(blocks == [
            .prose("same"),
            .code(language: nil, code: "x"),
            .prose("same"),
            .code(language: nil, code: "x"),
        ])
        #expect(blocks.count == 4, "Duplicates must survive as separate blocks, not be merged away.")
    }

    /// `runs` is a view over attribute storage; clearing a link mid-iteration
    /// coalesces adjacent runs. Many consecutive bad links is the shape that
    /// exercises it.
    @Test func sanitizingManyAdjacentBadLinksIsStable() throws {
        let markdown = (0..<12).map { "[l\($0)](javascript:alert(\($0)))" }.joined(separator: " ")
            + " [ok](https://example.com)"
        let raw = try AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        let safe = ChatLinkPolicy.sanitized(raw)

        #expect(safe.runs.compactMap { $0.link?.scheme?.lowercased() } == ["https"])
        #expect(String(safe.characters) == String(raw.characters),
                "Sanitizing must not disturb the text, only the link attributes.")
    }

    /// Sanitizing content with no offending link must return it untouched.
    @Test func sanitizingCleanContentIsIdentity() throws {
        let raw = try AttributedString(
            markdown: "plain **bold** [ok](https://example.com)",
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        #expect(ChatLinkPolicy.sanitized(raw) == raw)
    }

    /// Performance: a fence-free message must keep the pre-658.13 view tree —
    /// no VStack and no ForEach wrapper per bubble in a long transcript.
    @Test func fenceFreeMessagesTakeTheBareTextFastPath() throws {
        let blocks = ChatRichContentCache.blocks("just a normal reply")
        #expect(blocks.count == 1)
        #expect(try #require(blocks.first).isProse)

        let row = try AppSourceScraping.appSource("ChatMessageListView.swift")
        #expect(row.contains("if blocks.count == 1, case .prose(let only) = blocks[0]"),
                "The single-prose-block fast path must remain wired.")
    }

    /// The view-side half of the identity fix: `ForEach` must key on POSITION.
    /// Keying on the block value (or on its content) collides the moment a
    /// message repeats a snippet, and SwiftUI silently drops the duplicate row.
    @Test func blockForEachKeysOnPositionNotContent() throws {
        let row = try AppSourceScraping.appSource("ChatMessageListView.swift")
        #expect(row.contains("ForEach(blocks.indices, id: \\.self)"),
                "Blocks must be enumerated by index; content-derived ids collide on repeats.")
    }

    // MARK: - One renderer, both surfaces

    @Test func bothChatSurfacesRenderThroughTheSharedRow() throws {
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        #expect(detached.contains("ChatMessageListView("),
                "The detached panel must reuse the shared transcript row, not a rival renderer.")
        #expect(!detached.contains("ChatCodeBlockView("),
                "Code-block rendering must live only in the shared row.")

        let chat = try AppSourceScraping.appSource("ChatView.swift")
        #expect(!chat.contains("ChatCodeBlockView("),
                "Code-block rendering must live only in the shared row.")

        let row = try AppSourceScraping.appSource("ChatMessageListView.swift")
        #expect(row.contains("ChatRichContentCache.blocks(message.content)"))
        #expect(row.contains("ChatCodeBlockView(language: language, code: code)"))
    }

    /// Performance contract: the streaming bubble must not split or re-parse.
    @Test func streamingBubbleStaysOnTheRawTextPath() throws {
        let row = try AppSourceScraping.appSource("ChatMessageListView.swift")
        let start = try #require(row.range(of: "private var renderedMessageText: some View"))
        let end = try #require(row.range(of: "private var trimmedContent", range: start.upperBound..<row.endIndex))
        let body = String(row[start.lowerBound..<end.lowerBound])

        let streamingBranch = try #require(body.range(of: "isSessionStreaming"))
        let splitCall = try #require(body.range(of: "ChatRichContentCache.blocks"))
        #expect(streamingBranch.lowerBound < splitCall.lowerBound,
                "The streaming guard must short-circuit before any block split.")
    }

    /// The code-block view is a pure projection: no timers, no tasks, no state.
    @Test func codeBlockViewHasNoStateClockOrSideEffects() throws {
        let source = try AppSourceScraping.appSource("ChatCodeBlockView.swift")
        for forbidden in ["@State", "@StateObject", "Timer", "Date()", "Task {",
                         "onAppear", "URLSession", "AsyncImage", "DispatchQueue"] {
            #expect(!source.contains(forbidden),
                    "ChatCodeBlockView must stay a pure projection; found \(forbidden).")
        }
    }
}
