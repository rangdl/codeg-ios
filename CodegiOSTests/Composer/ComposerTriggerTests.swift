import Foundation
import SwiftUI
import Testing
@testable import Codeg

/// Web `suggestion/mention-match.test.ts` (`canStartMentionAt`), ported case
/// for case.
@Suite struct MentionStartTests {
    /// `@` appended to `prefix`, asked about at the `@`'s own offset.
    private func afterPrefix(_ prefix: String) -> Bool {
        MentionStart.canStart("\(prefix)@app", at: prefix.utf16.count)
    }

    @Test func allowsTheStartAndAnyWhitespace() {
        #expect(MentionStart.canStart("@app", at: 0))
        for prefix in [" ", "\n", "\t", "\u{00A0}", "\u{3000}"] {
            #expect(afterPrefix(prefix), "prefix \(prefix.unicodeScalars.map { $0.value })")
        }
    }

    @Test func allowsTheScriptsWrittenWithoutSpaces() {
        for prefix in ["请看", "汇", "テスト", "ん", "한글", "ㄅ", "你好，", "结束。", "「引用」", "（括号）", "标题："] {
            #expect(afterPrefix(prefix), "prefix \(prefix)")
        }
    }

    @Test func allowsTheCommonScriptMarksCJKWordsEndOn() {
        #expect(afterPrefix("ユーザー"))
        #expect(afterPrefix("サーバー"))
        #expect(afterPrefix("ヨミ・カナ"))
        #expect(afterPrefix("ゲーム゠センター"))
        #expect(afterPrefix("玛丽·居里"))
    }

    @Test func doesNotLetACombiningMarkCarryALatinLocalPartPastTheGuard() {
        #expect(!afterPrefix("a\u{0323}"))
        #expect(!afterPrefix("o\u{0305}"))
        #expect(!afterPrefix("me\u{0323}"))
    }

    @Test func allowsAHanCharacterFromBeyondTheBMP() {
        #expect(afterPrefix("𠀋"))
        #expect(afterPrefix("先祖𠀋"))
    }

    @Test func keepsBlockingTheTailOfAnEmailsLocalPart() {
        for prefix in ["me", "Z", "foo9", "a.b", "a_b", "a-b", "a+b", "100%", "(", "["] {
            #expect(!afterPrefix(prefix), "prefix \(prefix)")
        }
    }
}

/// The caret-scoped trigger detection (web `detectSlashTrigger` + Tiptap's
/// `findSuggestionMatch` with `findMentionMatch`).
@Suite struct ComposerTriggerTests {
    private func detect(_ text: String, caret: Int? = nil, agent: AgentType = .claudeCode) -> ComposerTrigger? {
        ComposerTrigger.detect(text: text, caretUTF16: caret ?? text.utf16.count, agent: agent)
    }

    @Test func slashOpensAtTheStartOrAfterWhitespace() {
        #expect(detect("/") == .command(prefix: .slash, query: "", range: 0..<1))
        #expect(detect("/re") == .command(prefix: .slash, query: "re", range: 0..<3))
        #expect(detect("please /rev") == .command(prefix: .slash, query: "rev", range: 7..<11))
        #expect(detect("hi\n/co") == .command(prefix: .slash, query: "co", range: 3..<6))
    }

    @Test func slashInsideAWordDoesNotOpen() {
        #expect(detect("a/b") == nil)
        #expect(detect("src/main") == nil)
        #expect(detect("/re ") == nil, "a space after the token ends it")
    }

    @Test func onlyTheTextBeforeTheCaretCounts() {
        #expect(detect("/review the code", caret: 4) == .command(prefix: .slash, query: "rev", range: 0..<4))
        #expect(detect("x /a/b", caret: 6) == .command(prefix: .slash, query: "a/b", range: 2..<6))
        #expect(detect("/re", caret: 99) == nil, "a caret past the text is no caret")
    }

    @Test func dollarOpensOnlyForTheAgentWhoseSkillsItTriggers() {
        #expect(detect("$dep", agent: .codex) == .command(prefix: .dollar, query: "dep", range: 0..<4))
        #expect(detect("$dep", agent: .claudeCode) == nil)
        #expect(detect("$dep", agent: .openCode) == nil, "OpenCode's disk skills ride `/`")
        #expect(detect("/x", agent: .codex) == .command(prefix: .slash, query: "x", range: 0..<2))
    }

    @Test func atOpensTheMentionPanel() {
        #expect(detect("@") == .mention(query: "", range: 0..<1))
        #expect(detect("see @src/ma") == .mention(query: "src/ma", range: 4..<11))
        #expect(detect("请看@文件") == .mention(query: "文件", range: 2..<5))
        #expect(detect("结束。@a") == .mention(query: "a", range: 3..<5))
    }

    @Test func anEmailAddressNeverOpensIt() {
        #expect(detect("me@x.com") == nil)
        #expect(detect("mail me@x") == nil)
        #expect(detect("@a@b") == nil, "the last `@` follows a letter")
    }

    @Test func aSpaceEndsTheMentionQuery() {
        #expect(detect("@foo bar") == nil)
        #expect(detect("@foo ") == nil)
    }

    @Test func theTriggerNearerTheCaretWins() {
        #expect(detect("/文@x") == .mention(query: "x", range: 2..<4))
        #expect(detect("@/x") == .mention(query: "/x", range: 0..<3))
    }
}


/// `ComposerEdit` replaces UTF-16 ranges.
@Suite struct ComposerEditTests {
    @Test func replacesTheRangeAndReportsTheCaret() {
        let edit = ComposerEdit(range: 3..<6, replacement: "/review ")
        #expect(edit.apply(to: "hi /re there") == "hi /review  there")
        #expect(edit.caretAfter == 11)
    }

    @Test func refusesARangeThatNoLongerFits() {
        #expect(ComposerEdit(range: 2..<9, replacement: "x").apply(to: "abc") == nil)
    }
}
