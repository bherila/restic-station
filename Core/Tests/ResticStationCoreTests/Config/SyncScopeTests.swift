import Foundation
import Testing
@testable import ResticStationCore

/// #202: a sync covers only what the set's backup covers, as far as a
/// relative path can decide it.
@Suite("Sync scope")
struct SyncScopeTests {
    static func set(excludes: [String] = [], sources: [String] = ["/Users/someone/work"], usesGlobalExcludes: Bool = true) -> BackupSet {
        var set = BackupSet(id: UUID(), name: "Work", sources: sources, schedule: .daily(hour: 2, minute: 0),
                            destinations: [.init(id: UUID(), label: "Archive", repoURL: "/tmp/repo", isPrimary: true)])
        set.excludes = excludes
        set.usesGlobalExcludes = usesGlobalExcludes
        return set
    }

    @Test("unanchored names, globs and ** match anywhere below the root")
    func patternShapes() {
        let scope = SyncScope(patterns: ["*.pyc", "docs/**/draft", "build"], caseInsensitivePatterns: ["node_modules"])
        #expect(scope.excludes("m.pyc"))
        #expect(scope.excludes("pkg/__init__.pyc"))
        #expect(!scope.excludes("pkg/M.PYC"), "--exclude is case-sensitive")
        #expect(scope.excludes("docs/draft") && scope.excludes("docs/a/b/draft") && scope.excludes("docs/a/draft/notes.md"))
        #expect(!scope.excludes("docs/drafts"))
        #expect(scope.excludes("app/build") && scope.excludes("app/build/out.o"))
        #expect(!scope.excludes("app/builder"))
        #expect(scope.excludes("web/NODE_MODULES/x/index.js"), "--iexclude is not")
        #expect(!scope.excludes("src/main.swift"))
        #expect(SyncScope.everything.isEverything && !SyncScope.everything.excludes("anything"))
    }

    @Test("the scope mirrors the backup's own exclusion lists")
    func mirrorsBackupLists() {
        let plan = GlobalExcludePlan(patterns: ["__pycache__", ".DS_Store"], cloudPlaceholderPatterns: ["*.icloud"],
                                     hostPatterns: ["*.swp"], excludeCaches: true, excludeLargerThan: "1G")
        let scope = SyncScope.backupScope(of: Self.set(excludes: ["*.log"]), applying: plan)
        #expect(scope.patterns == ["*.log", "*.swp"])
        #expect(scope.caseInsensitivePatterns == ["__pycache__", ".DS_Store", "*.icloud"])
        // A set that opted out of the global list keeps only its own.
        let own = SyncScope.backupScope(of: Self.set(excludes: ["*.log"], usesGlobalExcludes: false), applying: plan)
        #expect(own == SyncScope(patterns: ["*.log"]))
    }

    @Test("a catalogue pattern the backup holds back for swallowing a source stays in scope")
    func heldBackPatternStaysInScope() {
        // restic would exclude the whole source, so the engine drops the
        // pattern for this set, and its backup does contain x.tmp files.
        let plan = GlobalExcludePlan(patterns: ["*.tmp"], excludeCaches: false)
        let set = Self.set(sources: ["/srv/project.tmp/work"])
        #expect(set.globalBackupExcludes(applying: plan).isEmpty)
        #expect(!SyncScope.backupScope(of: set, applying: plan).excludes("scratch.tmp"))
    }

    @Test("patterns this matcher cannot decide keep their paths in scope")
    func undecidablePatternsIgnored() {
        for pattern in ["/Users/someone/work/build", "build/", "a[bc]", "$HOME/x", "~/x", "a\\*b", "{a,b}", "a//b", "./a", "../a", " a", ""] {
            #expect(!SyncScope.isDecidable(pattern), "\(pattern)")
        }
        for pattern in ["build", "*.pyc", "a/**/b", "**", ".DS_Store", "Library/Caches"] {
            #expect(SyncScope.isDecidable(pattern), "\(pattern)")
        }
        let scope = SyncScope.backupScope(of: Self.set(excludes: ["/Users/someone/work/build", "build/"]), applying: .none)
        #expect(scope.isEverything)
    }

    @Test("case-insensitive matching folds ASCII only, and non-ASCII folded patterns are not decidable")
    func asciiFolding() {
        let scope = SyncScope(caseInsensitivePatterns: ["*.TMP", "library/caches"])
        #expect(scope.excludes("draft.tmp") && scope.excludes("Library/Caches/x"))
        // Swift lowercases U+0130 to "i" plus a combining dot; Go to "i".
        // Folding neither keeps the path in scope, the safe direction.
        #expect(!SyncScope(caseInsensitivePatterns: ["ix"]).excludes("\u{130}x"))
        let plan = GlobalExcludePlan(patterns: ["Caf\u{E9}", "build"], excludeCaches: false)
        #expect(SyncScope.backupScope(of: Self.set(), applying: plan).caseInsensitivePatterns == ["build"])
    }

    @Test("a preview report without excluded, from an older helper, still decodes")
    func previewDecodesWithoutExcluded() throws {
        let json = #"{"setId":"11111111-1111-4111-8111-111111111111","groupId":"22222222-2222-4222-8222-222222222222","copies":1,"removals":0,"conflicts":0,"backupSourceCount":1}"#
        let preview = try JSONDecoder().decode(SourceSyncPreview.self, from: Data(json.utf8))
        #expect(preview.excluded == 0 && preview.excludedPaths == nil && preview.copies == 1)
        let round = try JSONDecoder().decode(SourceSyncPreview.self, from: JSONEncoder().encode(preview))
        #expect(round.excluded == 0)
    }

    @Test("any negation disables the scope, since it can re-include what another pattern excluded")
    func negationDisablesScope() {
        let scope = SyncScope.backupScope(of: Self.set(excludes: ["*.pyc", "!keep.pyc"]), applying: .none)
        #expect(scope.isEverything)
        let global = GlobalExcludePlan(patterns: ["__pycache__"], hostPatterns: ["!important"], excludeCaches: false)
        #expect(SyncScope.backupScope(of: Self.set(), applying: global).isEverything)
    }

    @Test("an endpoint refuses to remove or replace a directory that holds excluded entries")
    func endpointRefusesHiddenRemoval() throws {
        let dir = SyncItem(kind: .directory, digest: "", mode: 0o755)
        let file = SyncItem(digest: String(repeating: "a", count: 64))
        let removal = SyncEndpointOperation(path: "old", before: dir, after: nil)
        let replacement = SyncEndpointOperation(path: "old", before: dir, after: file)
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.refuseHiddenRemovals([removal], excluded: ["old/__pycache__"]) }
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.refuseHiddenRemovals([replacement], excluded: ["old/__pycache__"]) }
        // A sibling with a shared prefix, or the directory's own name, is not inside it.
        try SyncEndpointService.refuseHiddenRemovals([removal], excluded: ["older/__pycache__", "old"])
        // Removing a file, or keeping a directory, is unaffected.
        try SyncEndpointService.refuseHiddenRemovals([.init(path: "old/m.py", before: file, after: nil)], excluded: ["old/__pycache__"])
        try SyncEndpointService.refuseHiddenRemovals([.init(path: "old", before: dir, after: dir)], excluded: ["old/__pycache__"])
    }

    @Test("inventory skips excluded entries without reading them and lists the topmost")
    func inventorySkipsExcluded() throws {
        let root = try syncTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg/__pycache__/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pkg.appendingPathComponent("m.pyc"))
        try Data("y".utf8).write(to: root.appendingPathComponent("pkg/m.py"))
        try Data("z".utf8).write(to: root.appendingPathComponent("top.pyc"))
        let scope = SyncScope(patterns: ["*.pyc"], caseInsensitivePatterns: ["__pycache__"])
        let (inventory, excluded) = try SourceSyncFilesystem.scopedInventory(at: root.path, scope: scope)
        #expect(Set(inventory.items.keys) == ["pkg", "pkg/m.py"])
        #expect(excluded == ["pkg/__pycache__", "top.pyc"])
        #expect(Set(try SourceSyncFilesystem.inventory(at: root.path).items.keys).count == 6)
    }
}
