import Testing
@testable import SelfImprovement

// R23: diffTouchesSwift drives the post-promote "full rebuild needed" warning.
// A false negative silently hides the warning; a false positive nags on
// docs-only promotions.
@Suite struct DiffTouchesSwiftTests {

    @Test func swiftFileInHeadersIsDetected() {
        let diff = """
        diff --git a/Sources/App/Foo.swift b/Sources/App/Foo.swift
        --- a/Sources/App/Foo.swift
        +++ b/Sources/App/Foo.swift
        @@ -1,2 +1,2 @@
        -let a = 1
        +let a = 2
        """
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func nonSwiftDiffIsNotFlagged() {
        let diff = """
        diff --git a/docs/notes.md b/docs/notes.md
        --- a/docs/notes.md
        +++ b/docs/notes.md
        @@ -1 +1 @@
        -old
        +new line mentioning code.swift inline should not count
        """
        #expect(!SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func newSwiftFileWithDevNullSourceIsDetected() {
        let diff = """
        diff --git a/Sources/App/New.swift b/Sources/App/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/Sources/App/New.swift
        @@ -0,0 +1 @@
        +struct New {}
        """
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func deletedSwiftFileIsDetected() {
        let diff = """
        diff --git a/Sources/App/Dead.swift b/Sources/App/Dead.swift
        deleted file mode 100644
        --- a/Sources/App/Dead.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -struct Dead {}
        """
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func emptyDiffIsNotFlagged() {
        #expect(!SelfImprovementOrchestrator.diffTouchesSwift(""))
    }

    @Test func pureRenameWithoutContentChangeIsDetected() {
        let diff = """
        diff --git a/Sources/App/Old.swift b/Sources/App/New.swift
        similarity index 100%
        rename from Sources/App/Old.swift
        rename to Sources/App/New.swift
        """
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func headerWithMtimeTabSuffixIsDetected() {
        let diff = "--- a/Sources/App/Foo.swift\t2026-07-01 12:00:00.000000000 -0700\n"
            + "+++ b/Sources/App/Foo.swift\t2026-07-01 12:00:01.000000000 -0700\n"
            + "@@ -1 +1 @@\n-old\n+new"
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func crlfHeaderIsDetected() {
        let diff = "+++ b/Sources/App/Foo.swift\r\n@@ -1 +1 @@\r\n-old\r\n+new"
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func pureCopyHeaderIsDetected() {
        let diff = """
        diff --git a/Sources/App/Base.swift b/Sources/App/Copy.swift
        similarity index 100%
        copy from Sources/App/Base.swift
        copy to Sources/App/Copy.swift
        """
        #expect(SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }

    @Test func swiftOrigBackupFileIsNotFlagged() {
        let diff = """
        diff --git a/Sources/App/Foo.swift.orig b/Sources/App/Foo.swift.orig
        --- a/Sources/App/Foo.swift.orig
        +++ b/Sources/App/Foo.swift.orig
        @@ -1 +1 @@
        -old
        +new
        """
        #expect(!SelfImprovementOrchestrator.diffTouchesSwift(diff))
    }
}
