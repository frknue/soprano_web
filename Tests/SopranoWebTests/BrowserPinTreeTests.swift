@testable import SopranoWeb
import AppKit
import Testing

struct BrowserPinTreeTests {
    private let root = BrowserPinTree.rootID

    private func pin(_ title: String, _ url: String? = nil) -> BrowserPinNode {
        .pin(BrowserPin(url: url ?? "https://\(title.lowercased()).example/", title: title))
    }

    private func folder(_ name: String, _ children: [BrowserPinNode] = []) -> BrowserPinNode {
        .folder(BrowserPinFolder(name: name, children: children))
    }

    /// Root: a, Work [b, Docs [c]], d
    private func sample() -> BrowserPinTree {
        BrowserPinTree(children: [
            pin("A"),
            folder("Work", [pin("B"), folder("Docs", [pin("C")])]),
            pin("D"),
        ])
    }

    private func id(_ title: String, in tree: BrowserPinTree) -> UUID {
        func find(_ nodes: [BrowserPinNode]) -> UUID? {
            for node in nodes {
                if node.title == title { return node.id }
                if let folder = node.folder, let found = find(folder.children) { return found }
            }
            return nil
        }
        return find(tree.root.children)!
    }

    private func titles(_ folder: BrowserPinFolder) -> [String] {
        folder.children.map(\.title)
    }

    @Test func insertPlacesAtTheIndexClampedAndRefusesTakenIdsOrMissingFolders() {
        var tree = sample()
        let work = id("Work", in: tree)
        var applied = tree.insert(pin("E"), into: work, at: 1)
        #expect(applied)
        #expect(titles(tree.folder(id: work)!) == ["B", "E", "Docs"])
        applied = tree.insert(pin("F"), into: root, at: 99) && tree.insert(pin("G"), into: root, at: -3)
        #expect(applied)
        #expect(titles(tree.root) == ["G", "A", "Work", "D", "F"])

        let before = tree
        let existing = tree.node(id: id("C", in: tree))!
        let refused = [
            tree.insert(existing, into: root),
            tree.insert(pin("H"), into: UUID()),
            tree.insert(pin("I"), into: id("A", in: tree)),
        ]
        #expect(refused == [false, false, false])
        #expect(tree == before)
    }

    @Test func movingWithinAFolderCountsTheGapBeforeTheItemLeaves() {
        var tree = BrowserPinTree(children: ["A", "B", "C", "D"].map { pin($0) })
        func move(_ title: String, to index: Int) -> [String] {
            let moved = tree.move(id(title, in: tree), to: root, at: index)
            #expect(moved)
            return titles(tree.root)
        }
        // Down: the gap before "D" (index 3) puts "A" just above "D".
        #expect(move("A", to: 3) == ["B", "C", "A", "D"])
        // To the end.
        #expect(move("B", to: 4) == ["C", "A", "D", "B"])
        // Up: the gap before "C".
        #expect(move("D", to: 0) == ["D", "C", "A", "B"])
        // Its own gap and the one after it leave it in place.
        #expect(move("C", to: 1) == ["D", "C", "A", "B"])
        #expect(move("C", to: 2) == ["D", "C", "A", "B"])
    }

    @Test func movingInAndOutOfFolders() {
        var tree = sample()
        let work = id("Work", in: tree)
        let docs = id("Docs", in: tree)
        var moved = tree.move(id("A", in: tree), to: docs, at: 0)
        #expect(moved)
        #expect(titles(tree.folder(id: docs)!) == ["A", "C"])
        moved = tree.move(id("C", in: tree), to: root, at: 0)
        #expect(moved)
        #expect(titles(tree.root) == ["C", "Work", "D"])
        // A whole folder moves with its contents.
        moved = tree.move(docs, to: root, at: 3)
        #expect(moved)
        #expect(titles(tree.root) == ["C", "Work", "D", "Docs"])
        #expect(titles(tree.folder(id: docs)!) == ["A"])
        #expect(titles(tree.folder(id: work)!) == ["B"])
    }

    @Test func aFolderNeverMovesIntoItselfOrItsDescendants() {
        var tree = sample()
        let before = tree
        let work = id("Work", in: tree)
        let docs = id("Docs", in: tree)
        #expect(!tree.canMove(work, into: work))
        #expect(!tree.canMove(work, into: docs))
        let refused = [
            tree.move(work, to: docs, at: 0),
            tree.move(work, to: work, at: 0),
            tree.move(root, to: work, at: 0),
            tree.move(UUID(), to: root, at: 0),
        ]
        #expect(refused == [false, false, false, false])
        #expect(tree == before)
        // The other way round is fine.
        let moved = tree.move(docs, to: root, at: 0)
        #expect(moved)
    }

    @Test func renameEditAndDelete() {
        var tree = sample()
        let work = id("Work", in: tree)
        let results = [
            tree.rename(folder: work, to: "Job"),
            tree.rename(folder: root, to: "Mine"),
            tree.rename(folder: id("A", in: tree), to: "Nope"),
            tree.edit(pin: id("B", in: tree), title: "Bee", url: "https://bee.example/"),
            tree.edit(pin: work, title: "x", url: "y"),
        ]
        #expect(results == [true, false, false, true, false])
        #expect(tree.folder(id: work)?.name == "Job")
        #expect(tree.root.name == "Bookmarks")
        #expect(tree.pins(url: "https://bee.example/").map(\.title) == ["Bee"])

        // Deleting a folder takes everything inside with it.
        let removed = tree.remove(work)
        #expect(removed?.folder?.allPins.map(\.title) == ["Bee", "C"])
        #expect(titles(tree.root) == ["A", "D"])
        #expect(tree.entries().map(\.pin.title) == ["A", "D"])
        let removedRoot = tree.remove(root)
        #expect(removedRoot == nil)
    }

    @Test func findByAddressAndFlattenWithPaths() {
        var tree = sample()
        tree.insert(pin("C again", "https://c.example/"), into: root, at: 0)
        #expect(tree.pins(url: "https://c.example/").map(\.title) == ["C again", "C"])
        #expect(tree.pins(url: "https://nothing.example/").isEmpty)

        let entries = tree.entries()
        #expect(entries.map(\.pin.title) == ["C again", "A", "B", "C", "D"])
        #expect(entries.map(\.path) == [[], [], ["Work"], ["Work", "Docs"], []])
        #expect(entries.map(\.pathText) == ["Bookmarks", "Bookmarks", "Work", "Work › Docs", "Bookmarks"])
        #expect(entries[3].detail == "Work › Docs · https://c.example/")
        #expect(entries[0].detail == "https://c.example/")
        #expect(entries[3].folderID == id("Docs", in: tree))
    }

    @Test func folderPickerListsEveryFolderButTheMovedOnesSubtree() {
        let tree = sample()
        let all = tree.folderEntries()
        #expect(all.map(\.name) == ["Bookmarks", "Work", "Docs"])
        #expect(all.map(\.depth) == [0, 1, 2])
        #expect(tree.folderEntries(excluding: id("Work", in: tree)).map(\.name) == ["Bookmarks"])
        #expect(tree.folderEntries(excluding: id("Docs", in: tree)).map(\.name) == ["Bookmarks", "Work"])
    }

    @Test func newPinsGoToTheLastUsedFolderWhileItExists() {
        var tree = sample()
        let docs = id("Docs", in: tree)
        #expect(tree.folderForNewPin(lastUsed: nil) == root)
        #expect(tree.folderForNewPin(lastUsed: docs) == docs)
        // A pin's id is not a folder.
        #expect(tree.folderForNewPin(lastUsed: id("A", in: tree)) == root)
        tree.remove(id("Work", in: tree))
        #expect(tree.folderForNewPin(lastUsed: docs) == root)
    }

    @Test func outlineRowsFollowTheExpandedFolders() {
        let tree = sample()
        let work = id("Work", in: tree)
        let docs = id("Docs", in: tree)
        let collapsed = BrowserPinOutline.rows(tree, expanded: [])
        #expect(collapsed.map(\.node.title) == ["A", "Work", "D"])
        // An expanded folder inside a collapsed one stays hidden.
        #expect(BrowserPinOutline.rows(tree, expanded: [docs]).map(\.node.title) == ["A", "Work", "D"])

        let open = BrowserPinOutline.rows(tree, expanded: [work, docs])
        #expect(open.map(\.node.title) == ["A", "Work", "B", "Docs", "C", "D"])
        #expect(open.map(\.depth) == [0, 0, 1, 1, 2, 0])
        #expect(open.map(\.index) == [0, 1, 0, 1, 0, 2])
        #expect(open[4].folderID == docs)
        #expect(open[1].isExpanded && !open[0].isExpanded)
    }

    @Test func dropsLandOnFoldersOrInTheGapAboveARow() {
        let tree = sample()
        let work = id("Work", in: tree)
        let docs = id("Docs", in: tree)
        let rows = BrowserPinOutline.rows(tree, expanded: [work])
        // A, Work, B, Docs, D
        func destination(_ drop: BrowserPinOutline.Drop) -> BrowserPinOutline.Destination? {
            BrowserPinOutline.destination(for: drop, rows: rows, tree: tree)
        }
        #expect(destination(.on(1)) == .init(folderID: work, index: 2))
        #expect(destination(.on(3)) == .init(folderID: docs, index: 1))
        #expect(destination(.on(0)) == nil)
        #expect(destination(.above(2)) == .init(folderID: work, index: 0))
        #expect(destination(.above(4)) == .init(folderID: root, index: 2))
        #expect(destination(.above(5)) == .init(folderID: root, index: 3))
        #expect(destination(.above(9)) == nil)

        // The destination feeds `move`: "A" dropped above "D" lands just
        // before it, counting the gap before "A" leaves the root.
        var moved = tree
        let target = destination(.above(4))!
        let applied = moved.move(id("A", in: tree), to: target.folderID, at: target.index)
        #expect(applied)
        #expect(titles(moved.root) == ["Work", "A", "D"])
    }

    @Test func deleteConfirmationCountsWhatIsInside() {
        let tree = sample()
        #expect(tree.folder(id: id("Work", in: tree))?.contentsSummary == "It holds 2 bookmarks and 1 folder.")
        #expect(tree.folder(id: id("Docs", in: tree))?.contentsSummary == "It holds 1 bookmark.")
        #expect(BrowserPinFolder(name: "x", children: [folder("y")]).contentsSummary == "It holds 1 folder.")
        #expect(BrowserPinFolder(name: "z").contentsSummary == "It is empty.")
    }
}
