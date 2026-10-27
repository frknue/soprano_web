@testable import SopranoWeb
import AppKit
import Testing

/// Synthetic Arc support folders in Arc's Swift `JSONEncoder` encoding:
/// dictionaries as alternating `[key, value]` arrays, enums as
/// `{"case": {"_0": payload}}`, dates in seconds since 2001.
struct BrowserArcImportReaderTests {
    // Spaces and their containers.
    private let spaceA = "0A000000-0000-4000-8000-000000000001"
    private let spaceB = "0A000000-0000-4000-8000-000000000002"
    private let spaceC = "0A000000-0000-4000-8000-000000000003"
    private let pinnedA = "0C000000-0000-4000-8000-000000000011"
    private let todayA = "0C000000-0000-4000-8000-000000000012"
    private let pinnedB = "0C000000-0000-4000-8000-000000000021"
    private let todayB = "0C000000-0000-4000-8000-000000000022"
    private let favoritesDefault = "0C000000-0000-4000-8000-000000000031"
    private let favoritesWork = "0C000000-0000-4000-8000-000000000032"
    // Items. MD5("5F2C1A9E-0B7D-4C3E-9A11-2D6E8F4B7C01") = 7bcbb8d99ea0447dffc694e307a9a3ff.
    private let docs = "5F2C1A9E-0B7D-4C3E-9A11-2D6E8F4B7C01"
    private let workList = "1E000000-0000-4000-8000-000000000001"
    private let customTab = "1E000000-0000-4000-8000-000000000002"
    private let split = "1E000000-0000-4000-8000-000000000003"
    private let left = "1E000000-0000-4000-8000-000000000004"
    private let right = "1E000000-0000-4000-8000-000000000005"
    private let noURL = "1E000000-0000-4000-8000-000000000006"
    private let easel = "1E000000-0000-4000-8000-000000000007"
    private let loop = "1E000000-0000-4000-8000-000000000008"
    private let today = "1E000000-0000-4000-8000-000000000009"
    private let mail = "1E000000-0000-4000-8000-00000000000A"
    private let calendar = "1E000000-0000-4000-8000-00000000000B"
    private let pinB = "1E000000-0000-4000-8000-00000000000C"
    private let missing = "1E000000-0000-4000-8000-0000000000FF"
    // Archive. MD5("A1B2C3D4-0000-4000-8000-00000000000A") = dfe96d40a2941ea26d6a8155f57f4760.
    private let archived = "A1B2C3D4-0000-4000-8000-00000000000A"
    private let archivedLittle = "1F000000-0000-4000-8000-000000000002"
    private let archivedNoURL = "1F000000-0000-4000-8000-000000000003"
    private let archivedOdd = "1F000000-0000-4000-8000-000000000004"

    private let created = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    }

    // MARK: Encoding helpers

    private var empty: [String: Any] { [:] }

    private func item(
        _ id: String,
        parent: String? = nil,
        title: String? = nil,
        data: [String: Any],
        children: [String] = [],
        createdAt: Double = 700_000_000
    ) -> [String: Any] {
        [
            "id": id,
            "parentID": parent.map { $0 as Any } ?? NSNull(),
            "title": title.map { $0 as Any } ?? NSNull(),
            "childrenIds": children,
            "createdAt": createdAt,
            "isUnread": false,
            "originatingDevice": "0D000000-0000-4000-8000-000000000001",
            "data": data,
        ]
    }

    private func tab(_ url: String?, _ savedTitle: String? = nil) -> [String: Any] {
        var tab: [String: Any] = ["savedMuteStatus": "allowAudio", "timeLastActiveAt": 700_000_100.5]
        if let url { tab["savedURL"] = url }
        if let savedTitle { tab["savedTitle"] = savedTitle }
        return ["tab": tab]
    }

    private func container(_ type: [String: Any]) -> [String: Any] {
        ["itemContainer": ["containerType": type]]
    }

    private func custom(_ directory: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": directory, "machineID": "0E000000-0000-4000-8000-000000000001"]]]
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
        ["red": red, "green": green, "blue": blue, "alpha": 1, "colorSpace": "extendedSRGB"]
    }

    /// `[key0, value0, key1, value1, …]`.
    private func alternating(_ items: [[String: Any]]) -> [Any] {
        items.flatMap { [$0["id"] as Any, $0] as [Any] }
    }

    private func sidebar() -> [String: Any] {
        let items: [[String: Any]] = [
            item(pinnedA, data: container(["spaceItems": ["_0": spaceA]]),
                 children: [docs, workList, noURL, easel, missing]),
            item(docs, parent: pinnedA, data: tab("https://docs.example/", "Docs")),
            item(workList, parent: pinnedA, title: "Work", data: ["list": empty], children: [customTab, split]),
            item(customTab, parent: workList, title: "Custom", data: tab("https://custom.example/", "Page")),
            item(split, parent: workList, data: ["splitView": ["layoutOrientation": "horizontal"]], children: [left, right]),
            item(left, parent: split, data: tab("https://left.example/", "Left")),
            item(right, parent: split, data: tab("https://right.example/", "Right")),
            item(noURL, parent: pinnedA, data: tab(nil, "Nothing")),
            item(easel, parent: pinnedA, title: "Board", data: ["easel": ["_0": "x"]]),
            item(todayA, data: container(["spaceItems": ["_0": spaceA]]), children: [today]),
            item(today, parent: todayA, data: tab("https://today.example/")),
            item(pinnedB, data: container(["spaceItems": ["_0": spaceB]]), children: [loop, pinB]),
            item(loop, parent: pinnedB, data: ["list": empty], children: [loop]),
            item(pinB, parent: pinnedB, data: tab("https://b.example/", "B")),
            item(todayB, data: container(["spaceItems": ["_0": spaceB]])),
            item(favoritesDefault, data: container(["topApps": ["_0": ["default": empty]]]), children: [mail]),
            item(mail, parent: favoritesDefault, data: tab("https://mail.example/", "Mail")),
            item(favoritesWork, data: container(["topApps": ["_0": custom("Profile 1")]]), children: [calendar]),
            item(calendar, parent: favoritesWork, data: tab("https://calendar.example/", "Calendar")),
        ]
        let spaces: [[String: Any]] = [
            [
                "id": spaceA,
                "title": "Personal",
                "profile": ["default": empty],
                "containerIDs": ["unpinned", todayA, "pinned", pinnedA],
                "customInfo": [
                    "iconType": ["emoji_v2": "🦅", "emoji": 129_413],
                    "windowTheme": [
                        "primaryColorPalette": ["midTone": color(0.5, 0.25, 0.75), "shaded": color(0.1, 0.1, 0.1)],
                        "background": ["single": ["_0": ["style": ["color": ["_0": [
                            "blendedSingleColor": ["_0": ["color": color(0.9, 0.9, 0.9)]],
                        ]]]]]],
                    ],
                ],
            ],
            [
                "id": spaceB,
                "title": "Work",
                "profile": custom("Profile 1"),
                "newContainerIDs": [["pinned": empty], pinnedB, ["unpinned": ["_0": ["shared": empty]]], todayB],
                "customInfo": [
                    "iconType": ["emoji": 128_512],
                    "windowTheme": ["background": ["single": ["_0": ["style": ["color": ["_0": [
                        "blendedGradient": ["_0": ["baseColors": [color(0.2, 0.4, 0.6), color(1, 1, 1)]]],
                    ]]]]]]],
                ],
            ],
            ["id": spaceC, "title": "", "customInfo": ["iconType": ["icon": "planet"]]],
        ]
        var spacesArray: [Any] = spaces.flatMap { [$0["id"] as Any, $0] as [Any] }
        spacesArray += ["0A000000-0000-4000-8000-0000000000FF", ["title": "No id"]] as [Any]
        let topApps: [Any] = [
            ["default": empty], favoritesDefault,
            custom("Profile 1"), favoritesWork,
            custom("Profile 7"), "0C000000-0000-4000-8000-000000000099",
        ]
        let spacesContainer: [String: Any] = [
            "items": alternating(items),
            "spaces": spacesArray,
            "topAppsContainerIDs": topApps,
        ]
        return [
            "version": 1,
            "sidebar": ["containers": [["global": empty], spacesContainer]],
            "firebaseSyncState": ["publishInProgress": false],
        ]
    }

    private func archive() -> [String: Any] {
        let entries: [[String: Any]] = [
            [
                "sidebarItem": item(archived, data: tab("https://old.example/", "Old"), createdAt: 790_000_000),
                "reason": "auto",
                "source": ["space": ["_0": spaceA]],
                "archivedAt": 800_000_000.5,
            ],
            [
                "sidebarItem": item(archivedNoURL, data: tab(nil)),
                "reason": "manual",
                "source": ["littleArc": empty],
                "archivedAt": 800_000_001,
            ],
            [
                "sidebarItem": item(archivedLittle, data: tab("https://little.example/")),
                "reason": "manual",
                "source": ["littleArc": empty],
                "archivedAt": 800_000_002,
            ],
            [
                "sidebarItem": item(archivedOdd, data: tab("https://odd.example/", "Odd")),
                "reason": "somethingNew",
                "source": ["unknown": empty],
            ],
        ]
        return ["version": 1, "items": entries.flatMap { [($0["sidebarItem"] as? [String: Any])?["id"] as Any, $0] as [Any] }]
    }

    private func urlMatch(_ style: String, _ value: String) -> [String: Any] {
        ["id": "0F000000-0000-4000-8000-000000000001", "componentType": ["urlMatch": ["_0": [style: empty], "_1": value]]]
    }

    private func routing() -> [String: Any] {
        [
            "version": 1,
            "defaultDestination": ["littleArc": ["_0": ["mostRecent": empty]]],
            "rules": [
                ["destination": ["space": ["_0": ["mostRecent": empty]]], "sourceComponents": [urlMatch("contains", "meet.google.com")]],
                [
                    "destination": ["space": ["_0": ["specific": ["_0": spaceB]]]],
                    "sourceComponents": [
                        urlMatch("matches", "https://x.example/"),
                        ["componentType": ["sourceApp": ["_0": "com.example.chat"]]],
                        urlMatch("regex", "^x"),
                    ],
                ],
                ["destination": ["littleArc": ["_0": ["mostRecent": empty]]], "sourceComponents": [urlMatch("contains", "zoom.us")]],
                ["destination": ["profile": ["_0": custom("Profile 1")]], "sourceComponents": [urlMatch("contains", "work.example")]],
                ["destination": ["teleport": empty], "sourceComponents": [urlMatch("contains", "nope")]],
                "not a rule",
            ] as [Any],
        ]
    }

    /// A full support folder: sidebar, archive, routing, favicons, User Data.
    private func makeSupportFolder() throws -> URL {
        let support = temporaryDirectory()
        try writeJSON(sidebar(), to: support.appendingPathComponent("StorableSidebar.json"))
        try writeJSON(archive(), to: support.appendingPathComponent("StorableArchiveItems.json"))
        try writeJSON(routing(), to: support.appendingPathComponent("StorableLinkRouting.json"))
        try writeJSON(["version": 1, "autoArchiveStartTime": 735_259_900.3], to: support.appendingPathComponent("StorableArchive.json"))
        try touch(support.appendingPathComponent("SidebarItemsFaviconCache/7bcbb8d99ea0447dffc694e307a9a3ff"))
        try touch(support.appendingPathComponent("SidebarItemsFaviconCache/ffffffffffffffffffffffffffffffff"))
        try touch(support.appendingPathComponent("ArchiveItemsFaviconCache/dfe96d40a2941ea26d6a8155f57f4760"))
        let userData = support.appendingPathComponent("User Data", isDirectory: true)
        try writeJSON(["profile": ["info_cache": [
            "Default": ["name": "Person 1"],
            "Profile 1": ["name": "Work person"],
        ]]], to: userData.appendingPathComponent("Local State"))
        try touch(userData.appendingPathComponent("Default/History"))
        try FileManager.default.createDirectory(
            at: userData.appendingPathComponent("Profile 1", isDirectory: true),
            withIntermediateDirectories: true
        )
        return support
    }

    private func link(_ id: String, _ url: String, _ title: String, _ addedAt: Date? = nil) -> BrowserImportedLink {
        BrowserImportedLink(sourceID: id, url: url, title: title, addedAt: addedAt ?? created)
    }

    // MARK: Tests

    @Test func spacesKeepPinnedTreesTodayTabsIconsColorsAndProfiles() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let reader = BrowserArcImportReader(supportDirectory: support)
        #expect(reader.isAvailable)
        let result = try reader.read()

        #expect(result.spaces.map(\.sourceID) == [spaceA, spaceB, spaceC])
        let a = result.spaces[0]
        #expect(a.name == "Personal")
        #expect(a.emoji == "🦅")
        #expect(a.iconName == nil)
        #expect(a.color == BrowserImportedColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        #expect(a.profileKey == "Default")
        #expect(a.pinned == [
            .link(link(docs, "https://docs.example/", "Docs")),
            .folder(BrowserImportedFolder(name: "Work", addedAt: created, children: [
                .link(link(customTab, "https://custom.example/", "Custom")),
                .link(link(left, "https://left.example/", "Left")),
                .link(link(right, "https://right.example/", "Right")),
            ])),
        ])
        #expect(a.today == [link(today, "https://today.example/", "https://today.example/")])

        let b = result.spaces[1]
        #expect(b.name == "Work")
        #expect(b.emoji == "😀")
        #expect(b.color == BrowserImportedColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        #expect(b.profileKey == "Profile 1")
        #expect(b.pinned == [
            .folder(BrowserImportedFolder(name: "", addedAt: created)),
            .link(link(pinB, "https://b.example/", "B")),
        ])
        #expect(b.today.isEmpty)

        let c = result.spaces[2]
        #expect(c.name == "Space")
        #expect(c.emoji == nil)
        #expect(c.iconName == "planet")
        #expect(c.color == nil)
        #expect(c.profileKey == "Default")
        #expect(c.pinned.isEmpty && c.today.isEmpty)
    }

    @Test func favoritesProfilesAndHistoryFilesFollowTheSpaces() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let result = try BrowserArcImportReader(supportDirectory: support).read()

        #expect(result.favorites == [
            BrowserImportedFavorites(profileKey: "Default", links: [link(mail, "https://mail.example/", "Mail")]),
            BrowserImportedFavorites(profileKey: "Profile 1", links: [link(calendar, "https://calendar.example/", "Calendar")]),
        ])
        #expect(result.profiles.map(\.key) == ["Default", "Profile 1"])
        #expect(result.profiles.map(\.displayName) == ["Person 1", "Work person"])
        #expect(Array(result.historyFiles.keys) == ["Default"])
        #expect(result.historyFiles["Default"]?.lastPathComponent == "History")
        #expect(result.historyFiles["Default"]?.deletingLastPathComponent().lastPathComponent == "Default")
    }

    @Test func archiveRoutingAndFaviconsAreRead() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let result = try BrowserArcImportReader(supportDirectory: support).read()

        #expect(result.archive == [
            BrowserImportedArchiveItem(
                link: link(archived, "https://old.example/", "Old", Date(timeIntervalSinceReferenceDate: 790_000_000)),
                spaceSourceID: spaceA,
                archivedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.5),
                reason: .auto
            ),
            BrowserImportedArchiveItem(
                link: link(archivedLittle, "https://little.example/", "https://little.example/"),
                spaceSourceID: nil,
                archivedAt: Date(timeIntervalSinceReferenceDate: 800_000_002),
                reason: .manual
            ),
            BrowserImportedArchiveItem(
                link: link(archivedOdd, "https://odd.example/", "Odd"),
                spaceSourceID: nil,
                archivedAt: created,
                reason: .unknown
            ),
        ])

        #expect(result.routingRules == [
            BrowserImportedRoutingRule(match: .contains, value: "meet.google.com", destination: .space(sourceID: nil)),
            BrowserImportedRoutingRule(match: .equals, value: "https://x.example/", destination: .space(sourceID: spaceB)),
            BrowserImportedRoutingRule(match: .contains, value: "zoom.us", destination: .littleArc),
            BrowserImportedRoutingRule(match: .contains, value: "work.example", destination: .profile(key: "Profile 1")),
        ])

        #expect(Set(result.favicons.keys) == [docs, archived])
        #expect(result.favicons[docs]?.lastPathComponent == "7bcbb8d99ea0447dffc694e307a9a3ff")
        #expect(result.favicons[docs]?.deletingLastPathComponent().lastPathComponent == "SidebarItemsFaviconCache")
        #expect(result.favicons[archived]?.deletingLastPathComponent().lastPathComponent == "ArchiveItemsFaviconCache")
    }

    @Test func faviconFileNameIsTheMD5OfTheUpperCaseID() {
        #expect(BrowserArcImportReader.faviconFileName(for: docs) == "7bcbb8d99ea0447dffc694e307a9a3ff")
        #expect(BrowserArcImportReader.faviconFileName(for: docs.lowercased()) == "7bcbb8d99ea0447dffc694e307a9a3ff")
    }

    @Test func theNewestDatedArchiveIsReadWhenTheMainFileIsMissing() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let main = support.appendingPathComponent("StorableArchiveItems.json")
        try FileManager.default.removeItem(at: main)
        let older = support.appendingPathComponent("StorableArchiveItems.2025-01-01-00-00-00-000.json")
        let newer = support.appendingPathComponent("StorableArchiveItems.2026-01-01-00-00-00-000.json")
        try writeJSON(["version": 1, "items": [String]()], to: older)
        try writeJSON(archive(), to: newer)
        let reader = BrowserArcImportReader(supportDirectory: support)
        #expect(reader.archiveURL?.lastPathComponent == newer.lastPathComponent)
        #expect(try reader.read().archive.count == 3)

        try FileManager.default.removeItem(at: older)
        try FileManager.default.removeItem(at: newer)
        #expect(reader.archiveURL == nil)
        #expect(try reader.read().archive.isEmpty)
    }

    @Test func damagedArchiveRoutingAndFaviconsYieldNothingButTheSidebarStillReads() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        try Data("garbage".utf8).write(to: support.appendingPathComponent("StorableArchiveItems.json"))
        try Data("[1, 2".utf8).write(to: support.appendingPathComponent("StorableLinkRouting.json"))
        try FileManager.default.removeItem(at: support.appendingPathComponent("SidebarItemsFaviconCache"))
        let result = try BrowserArcImportReader(supportDirectory: support).read()
        #expect(result.spaces.count == 3)
        #expect(result.archive.isEmpty)
        #expect(result.routingRules.isEmpty)
        #expect(result.favicons.isEmpty)
    }

    @Test func aMissingOrForeignSidebarThrows() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let reader = BrowserArcImportReader(supportDirectory: support)
        #expect(!reader.isAvailable)
        #expect(throws: BrowserImportError.missingFile(reader.sidebarURL)) {
            try reader.read()
        }

        try Data("garbage".utf8).write(to: reader.sidebarURL)
        #expect(throws: BrowserImportError.unreadable(reader.sidebarURL, "not a JSON object")) {
            try reader.read()
        }

        try writeJSON(["sidebar": ["containers": [["global": empty]]]], to: reader.sidebarURL)
        #expect(throws: BrowserImportError.unreadable(reader.sidebarURL, "no sidebar container with spaces")) {
            try reader.read()
        }
    }

    @Test func spacesAreFoundOutsideTheSecondContainer() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let space: [String: Any] = ["id": spaceA, "title": "Only"]
        try writeJSON(["sidebar": ["containers": [["items": [Any](), "spaces": [spaceA, space] as [Any]]]]],
                      to: support.appendingPathComponent("StorableSidebar.json"))
        let result = try BrowserArcImportReader(supportDirectory: support).read()
        #expect(result.spaces.map(\.name) == ["Only"])
        #expect(result.profiles.map(\.key) == ["Default"])
        #expect(result.profiles.first?.directory == nil)
        #expect(result.historyFiles.isEmpty)
    }

    @Test func readHistoryOfAProfileWithoutADatabaseThrowsMissingFile() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let reader = BrowserArcImportReader(supportDirectory: support)
        let file = reader.userDataDirectory
            .appendingPathComponent("Profile 1", isDirectory: true)
            .appendingPathComponent("History")
        #expect(throws: BrowserImportError.missingFile(file)) {
            try reader.readHistory(profileKey: "Profile 1") { _ in }
        }
    }

    // MARK: Shapes from a real Arc 1.169 folder

    /// `StorableSidebar.json` as Arc 1.169 writes it: a favorites key with
    /// a bool payload, a custom profile with `machineID` first, a Space
    /// with a theme but no icon whose `midTone` leaves 0…1, a tab whose
    /// title and optional fields are null, and a list with a folder icon.
    private let realSidebar = """
    {"version":1,"sidebar":{"containers":[{"global":{}},{
      "items":[
        "C1",{"id":"C1","parentID":null,"childrenIds":["T1","L1"],"title":null,"createdAt":711383993,"isUnread":false,
              "data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S1"}}}}},
        "C0",{"id":"C0","parentID":null,"childrenIds":[],"title":null,"createdAt":711383993,
              "data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S1"}}}}},
        "T1",{"id":"T1","parentID":"C1","childrenIds":[],"title":null,"createdAt":711383994,"isUnread":false,
              "data":{"tab":{"savedMuteStatus":null,"timeLastActiveAt":null,"savedTitle":"Saved title","savedURL":"https://saved.example/"}}},
        "L1",{"id":"L1","parentID":"C1","childrenIds":["T2"],"title":"Egg folder","createdAt":711383995,
              "data":{"list":{"customInfo":{"iconType":{"icon":"egg"}}}}},
        "T2",{"id":"T2","parentID":"L1","childrenIds":[],"title":null,"createdAt":711383996,
              "data":{"tab":{"savedMuteStatus":"allowAudio","timeLastActiveAt":711383999.5,"savedTitle":"Inner","savedURL":"https://inner.example/"}}},
        "F1",{"id":"F1","parentID":null,"childrenIds":["T3"],"title":null,"createdAt":711383993,
              "data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},
        "T3",{"id":"T3","parentID":"F1","childrenIds":[],"title":null,"createdAt":711383997,
              "data":{"tab":{"savedMuteStatus":null,"timeLastActiveAt":null,"savedTitle":"Mail","savedURL":"https://mail.example/"}}}
      ],
      "spaces":["S1",{"id":"S1","title":"Real","containerIDs":["unpinned","C0","pinned","C1"],
        "newContainerIDs":[{"pinned":{}},"C1",{"unpinned":{"_0":{"shared":{}}}},"C0"],
        "profile":{"custom":{"_0":{"machineID":"82A50F46-0000-4000-8000-000000000001","directoryBasename":"Profile 6"}}},
        "customInfo":{"windowTheme":{"primaryColorPalette":{"midTone":
          {"red":-0.38497164845466614,"green":0.8467978239059448,"blue":0.33840304613113403,"alpha":1,"colorSpace":"extendedSRGB"}}}}}],
      "topAppsContainerIDs":[{"default":true},"F1"]}]}}
    """

    @Test func realShapesReadAsSpacesFavoritesAndFolders() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try Data(realSidebar.utf8).write(to: support.appendingPathComponent("StorableSidebar.json"))
        let result = try BrowserArcImportReader(supportDirectory: support).read()

        let space = try #require(result.spaces.first)
        #expect(space.profileKey == "Profile 6")
        #expect(space.emoji == nil)
        #expect(space.iconName == nil)
        // Extended sRGB kept as stored; the plan converts it.
        #expect(space.color == BrowserImportedColor(
            red: -0.38497164845466614, green: 0.8467978239059448, blue: 0.33840304613113403, alpha: 1
        ))
        let date = { (seconds: Double) in Date(timeIntervalSinceReferenceDate: seconds) }
        #expect(space.pinned == [
            .link(BrowserImportedLink(sourceID: "T1", url: "https://saved.example/", title: "Saved title", addedAt: date(711_383_994))),
            .folder(BrowserImportedFolder(name: "Egg folder", addedAt: date(711_383_995), children: [
                .link(BrowserImportedLink(sourceID: "T2", url: "https://inner.example/", title: "Inner", addedAt: date(711_383_996))),
            ])),
        ])
        #expect(space.today.isEmpty)
        #expect(result.favorites == [BrowserImportedFavorites(profileKey: "Default", links: [
            BrowserImportedLink(sourceID: "T3", url: "https://mail.example/", title: "Mail", addedAt: date(711_383_997)),
        ])])
        #expect(result.profiles.map(\.key) == ["Profile 6", "Default"])
    }

    @Test func archiveFromLittleArcAndUnknownSourcesHasNoSpace() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let entries: [[String: Any]] = [
            ["sidebarItem": item(archivedLittle, data: tab("https://little.example/", "Little")),
             "reason": "manual", "source": ["littleArc": empty], "archivedAt": 809_180_514.59],
            ["sidebarItem": item(archivedOdd, data: tab("https://odd.example/", "Odd")),
             "reason": "auto", "source": ["unknown": empty], "archivedAt": 809_180_601.12],
        ]
        let items = entries.flatMap { [($0["sidebarItem"] as? [String: Any])?["id"] as Any, $0] as [Any] }
        try writeJSON(["version": 1, "items": items], to: support.appendingPathComponent("StorableArchiveItems.json"))
        let archive = try BrowserArcImportReader(supportDirectory: support).read().archive
        #expect(archive.map(\.spaceSourceID) == [nil, nil])
        #expect(archive.map(\.reason) == [.manual, .auto])
        // Oldest first, as Arc stores them.
        #expect(archive.map(\.archivedAt) == [
            Date(timeIntervalSinceReferenceDate: 809_180_514.59),
            Date(timeIntervalSinceReferenceDate: 809_180_601.12),
        ])
    }

    @Test func historyOnlyProfilesAreListedAndArcsSystemProfileIsNot() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let userData = support.appendingPathComponent("User Data", isDirectory: true)
        try writeJSON(["profile": [
            "info_cache": [
                "Default": ["name": "Person 1"],
                "Profile 1": ["name": "Work person"],
                "Profile 2": ["name": "Private"],
                "Profile 7": ["name": BrowserArcImportReader.systemProfileName],
            ],
            "profiles_order": ["Default", "Profile 1", "Profile 2", "Profile 7"],
        ]], to: userData.appendingPathComponent("Local State"))
        try touch(userData.appendingPathComponent("Profile 2/History"))
        try touch(userData.appendingPathComponent("Profile 7/History"))
        let result = try BrowserArcImportReader(supportDirectory: support).read()
        #expect(result.profiles.map(\.key) == ["Default", "Profile 1", "Profile 2"])
        #expect(result.profiles.map(\.displayName) == ["Person 1", "Work person", "Private"])
        #expect(Set(result.historyFiles.keys) == ["Default", "Profile 2"])
    }

    @Test func prefixRoutingRulesAreRead() throws {
        let support = try makeSupportFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        try writeJSON([
            "version": 1,
            "rules": [["destination": ["space": ["_0": ["mostRecent": empty]]], "sourceComponents": [urlMatch("prefix", "https://docs.")]]],
        ], to: support.appendingPathComponent("StorableLinkRouting.json"))
        #expect(try BrowserArcImportReader(supportDirectory: support).read().routingRules == [
            BrowserImportedRoutingRule(match: .prefix, value: "https://docs.", destination: .space(sourceID: nil)),
        ])
    }
}
