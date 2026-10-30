@testable import SopranoWeb
import AppKit
import Testing

/// Adblock Plus / EasyList filters → WebKit content rules.
struct BrowserFilterConverterTests {
    private typealias Rule = BrowserContentRule
    private let anchor = BrowserFilterConverter.domainAnchor
    private let separator = BrowserFilterConverter.separator
    private let defaultTypes = BrowserContentRule.defaultResourceTypes
    private let letPagesThrough = Rule(
        urlFilter: ".*",
        resourceTypes: ["document"],
        loadContext: "top-frame",
        action: .ignorePreviousRules
    )

    private func urlFilter(_ pattern: String) -> String? {
        try? BrowserFilterConverter.urlFilter(for: Substring(pattern)).get()
    }

    /// The network list of a conversion with one list per kind.
    private func networkRules(_ text: String) -> [Rule] {
        BrowserFilterConverter.convert(text).lists.first { $0.contains(letPagesThrough) } ?? []
    }

    private func block(_ urlFilter: String) -> Rule {
        Rule(urlFilter: urlFilter, resourceTypes: defaultTypes, action: .block)
    }

    // MARK: - Patterns

    @Test func patternsBecomeWebKitRegularExpressions() {
        #expect(urlFilter("||ads.example.com^") == "\(anchor)ads\\.example\\.com\(separator)")
        #expect(urlFilter("||ads.example.com") == "\(anchor)ads\\.example\\.com")
        #expect(urlFilter("|https://tracker.example/pixel") == "^https://tracker\\.example/pixel")
        #expect(urlFilter("swf|") == "swf$")
        #expect(urlFilter("|https://a.example/x|") == "^https://a\\.example/x$")
        #expect(urlFilter("-ad-banner.") == "-ad-banner\\.")
        #expect(urlFilter("&ad_type=") == "&ad_type=")
        #expect(urlFilter("/banner/*/img^") == "/banner/.*/img(\(separator).*)?$")
        #expect(urlFilter("/ads/^|") == "/ads/(\(separator))?$")
        #expect(urlFilter("||example.com/ads^") == "\(anchor)example\\.com/ads(\(separator).*)?$")
        #expect(urlFilter("||example.com^*/ad.js") == "\(anchor)example\\.com\(separator).*/ad\\.js")
        #expect(urlFilter("*ad**banner*") == "ad.*banner")
        #expect(urlFilter("?ad=(1)+[x]{y}") == "\\?ad=\\(1\\)\\+\\[x\\]\\{y\\}")
        #expect(urlFilter("*") == ".*")
        #expect(urlFilter("") == ".*")
    }

    @Test func regularExpressionFiltersAreKeptOnlyInWebKitsSubset() {
        #expect(urlFilter("/ads[0-9]+\\.js/") == "ads[0-9]+\\.js")
        #expect(urlFilter("/^https?:\\/\\/ads\\./") == "^https?:\\/\\/ads\\.")
        #expect(throws: BrowserFilterSkipReason.regexUnsupported) {
            try BrowserFilterConverter.urlFilter(for: "/banner\\d+/").get()
        }
        #expect(throws: BrowserFilterSkipReason.regexUnsupported) {
            try BrowserFilterConverter.urlFilter(for: "/(ads|banners)\\//").get()
        }
        #expect(throws: BrowserFilterSkipReason.regexUnsupported) {
            try BrowserFilterConverter.urlFilter(for: "/ad{2}/").get()
        }
        #expect(throws: BrowserFilterSkipReason.nonASCII) {
            try BrowserFilterConverter.urlFilter(for: "||пример.рф^").get()
        }
    }

    @Test func everyEmittedPatternFitsWebKitsSubset() {
        let text = """
        ||ads.example.com^
        |https://a.example/?q=(1)|
        /banner/*/img^
        $script,domain=example.com
        @@||example.com/ok.js^$script
        @@||news.example^$document
        @@/^https?:\\/\\/cdn\\./$elemhide
        /ads[0-9]+\\.js/
        a{1}b|c$image
        """
        for rule in BrowserFilterConverter.convert(text).lists.joined() {
            #expect(BrowserContentRuleRegex.isSupported(rule.urlFilter), "\(rule.urlFilter)")
            if case .ifTopURL(let patterns)? = rule.condition {
                #expect(patterns.allSatisfy(BrowserContentRuleRegex.isSupported), "\(patterns)")
            }
        }
    }

    // MARK: - Options

    @Test func optionsMapToTriggerFields() {
        let rules = networkRules("""
        ||ads.example^$third-party
        ||cdn.example^$~third-party
        ||x.example^$script,image,stylesheet,font,media
        ||y.example^$xmlhttprequest,subdocument,websocket,ping,other
        ||z.example^$~script,~image
        ||popup.example^$popup
        /Track.JS$match-case
        """)
        #expect(rules[0].loadType == "third-party")
        #expect(rules[1].loadType == "first-party")
        #expect(rules[2].resourceTypes == ["font", "image", "media", "script", "style-sheet"])
        #expect(rules[3].resourceTypes == ["document", "fetch", "other", "ping", "websocket"])
        #expect(rules[4].resourceTypes == defaultTypes.filter { $0 != "script" && $0 != "image" })
        #expect(rules[5].resourceTypes == ["popup"])
        #expect(rules[6].urlFilter == "/Track\\.JS")
        #expect(rules[6].caseSensitive)
        #expect(!rules[0].caseSensitive)
        // Without type options: every type but pop-ups.
        #expect(rules[0].resourceTypes == defaultTypes)
        #expect(!defaultTypes.contains("popup"))
    }

    @Test func domainOptionBecomesOneDomainCondition() {
        let rules = networkRules("""
        ||a.example^$domain=news.example|blog.example|~other.example
        ||b.example^$domain=~news.example|~blog.example
        ||c.example^$domain=Example.COM,third-party,script
        ||d.example^$domain=example.com|~example.com|other.example
        """)
        #expect(rules[0].condition == .ifDomain(["*blog.example", "*news.example"]))
        #expect(rules[1].condition == .unlessDomain(["*blog.example", "*news.example"]))
        #expect(rules[2].condition == .ifDomain(["*example.com"]))
        #expect(rules[2].loadType == "third-party")
        #expect(rules[2].resourceTypes == ["script"])
        // An excluded domain equal to an included one takes it out.
        #expect(rules[3].condition == .ifDomain(["*other.example"]))
    }

    @Test func domainListsWebKitCannotExpressAreSkipped() {
        let conversion = BrowserFilterConverter.convert("""
        ||a.example^$domain=example.com|~ads.example.com
        ||b.example^$domain=google.*
        ||c.example^$domain=пример.рф
        ||d.example^$domain=example.com|google.*
        ||e.example^$domain=example.com|~google.*
        """)
        #expect(conversion.skipped[.domainExceptionInsideInclude] == 1)
        #expect(conversion.skipped[.entityDomain] == 2)
        #expect(conversion.skipped[.nonASCII] == 1)
        // The usable include stays.
        let rules = conversion.lists.joined().filter { $0.action == .block }
        #expect(rules.map(\.condition) == [.ifDomain(["*example.com"])])
    }

    // MARK: - Exceptions

    @Test func exceptionsFollowTheirBlocksInEveryNetworkList() {
        let rules = networkRules("""
        ||ads.example^
        @@||ads.example/ok.js^$script,domain=example.com
        @@||cdn.example^
        ||late.example^$important
        """)
        #expect(rules == [
            block("\(anchor)ads\\.example\(separator)"),
            Rule(
                urlFilter: "\(anchor)ads\\.example/ok\\.js(\(separator).*)?$",
                resourceTypes: ["script"],
                condition: .ifDomain(["*example.com"]),
                action: .ignorePreviousRules
            ),
            Rule(urlFilter: "\(anchor)cdn\\.example\(separator)", resourceTypes: defaultTypes, action: .ignorePreviousRules),
            letPagesThrough,
            // `$important` comes after the exceptions, so none reaches it.
            block("\(anchor)late\\.example\(separator)"),
        ])
    }

    @Test func documentExceptionsCoverWholePagesInEveryList() {
        let conversion = BrowserFilterConverter.convert("""
        ||ads.example^
        ##.ad-banner
        @@||news.example^$document
        @@*$document,domain=shop.example
        """)
        let pageByURL = Rule(
            urlFilter: ".*",
            condition: .ifTopURL(["\(anchor)news\\.example\(separator)"]),
            action: .ignorePreviousRules
        )
        let pageByDomain = Rule(urlFilter: ".*", condition: .ifDomain(["*shop.example"]), action: .ignorePreviousRules)
        #expect(conversion.lists.count == 2)
        for list in conversion.lists {
            #expect(Array(list.suffix(2)) == [pageByURL, pageByDomain])
        }
        // Not a request exception: no ignore rule with the page's pattern.
        #expect(!conversion.lists[0].contains { $0.urlFilter.contains("news") && $0.condition == nil })
    }

    @Test func elementHidingExceptionsOnlyReachTheHidingList() {
        let conversion = BrowserFilterConverter.convert("""
        ||ads.example^
        ##.ad-banner
        example.com##.promo
        @@||forum.example^$elemhide
        @@||docs.example^$generichide
        """)
        let network = conversion.lists[0]
        let hiding = conversion.lists[1]
        #expect(!network.contains { $0.urlFilter == ".*" && $0.condition != nil })
        let elemhide = Rule(
            urlFilter: ".*",
            condition: .ifTopURL(["\(anchor)forum\\.example\(separator)"]),
            action: .ignorePreviousRules
        )
        let generichide = Rule(
            urlFilter: ".*",
            condition: .ifTopURL(["\(anchor)docs\\.example\(separator)"]),
            action: .ignorePreviousRules
        )
        // Generic rules, `$generichide`, domain rules, `$elemhide`.
        #expect(hiding == [
            Rule(urlFilter: ".*", action: .cssDisplayNone([".ad-banner"])),
            generichide,
            Rule(urlFilter: ".*", condition: .ifDomain(["*example.com"]), action: .cssDisplayNone([".promo"])),
            elemhide,
        ])
    }

    // MARK: - Element hiding

    @Test func genericSelectorsAreBatched() {
        let conversion = BrowserFilterConverter.convert("""
        ##.ad-banner
        ##.sponsor
        ###ad-top
        ##.ad-banner
        ##div[data-ad="1"]
        """, selectorsPerRule: 3)
        #expect(conversion.lists == [[
            Rule(urlFilter: ".*", action: .cssDisplayNone([".ad-banner", ".sponsor", "#ad-top"])),
            Rule(urlFilter: ".*", action: .cssDisplayNone(["div[data-ad=\"1\"]"])),
        ]])
        // One `css-display-none` rule with the selectors joined.
        let json = BrowserContentRule.json([conversion.lists[0][0]])
        #expect(json.contains(#""selector":".ad-banner, .sponsor, #ad-top""#))
        #expect(json.contains(#""type":"css-display-none""#))
    }

    @Test func domainSelectorsAndTheirExceptions() {
        let conversion = BrowserFilterConverter.convert("""
        ##.ad-banner
        ##.sponsor
        ##.everywhere
        ~shop.example##.teaser
        example.com,news.example##.promo
        news.example,example.com##.box
        example.com,~sub.example.com##.inner
        example.com#@#.ad-banner
        #@#.sponsor
        news.example#@#.promo
        """)
        #expect(conversion.lists == [[
            Rule(urlFilter: ".*", action: .cssDisplayNone([".everywhere"])),
            Rule(urlFilter: ".*", condition: .unlessDomain(["*example.com"]), action: .cssDisplayNone([".ad-banner"])),
            Rule(urlFilter: ".*", condition: .unlessDomain(["*shop.example"]), action: .cssDisplayNone([".teaser"])),
            Rule(urlFilter: ".*", condition: .ifDomain(["*example.com"]), action: .cssDisplayNone([".promo"])),
            Rule(urlFilter: ".*", condition: .ifDomain(["*example.com", "*news.example"]), action: .cssDisplayNone([".box"])),
        ]])
        #expect(conversion.skipped == [.domainExceptionInsideInclude: 1])
    }

    @Test func aGenericSelectorAlsoHiddenWithoutExclusionsHidesEverywhere() {
        let conversion = BrowserFilterConverter.convert("""
        ~a.example##.x
        ##.x
        ~a.example##.y
        ~b.example##.y
        """)
        #expect(conversion.lists == [[
            Rule(urlFilter: ".*", action: .cssDisplayNone([".x", ".y"])),
        ]])
    }

    // MARK: - Skipped filters

    @Test func whatWebKitCannotExpressIsSkippedAndCountedByReason() {
        let conversion = BrowserFilterConverter.convert("""
        [Adblock Plus 2.0]
        ! Title: test
        ||ads.example^$csp=script-src 'none'
        ||ads.example/x.js$redirect=noop.js
        ||ads.example/y.js$script,redirect-rule=noop.js
        ||example.com^$removeparam=utm_source
        ||ads.example/z.js$rewrite=abp-resource:blank-js
        ||ads.example^$badfilter
        @@||example.com^$genericblock
        ||ads.example^$object
        ||ads.example^$sitekey=abc
        example.com##+js(abort-on-property-read, ads)
        example.com#$#log hello
        example.com#?#div:-abp-has(.ad)
        ##div:-abp-has(.ad)
        ##.ad:has-text(Sponsored)
        ##^script:has-text(ads)
        example.com#%#//scriptlet('abort')
        ##.ad:unknown-pseudo
        ##.ad{display:none}
        /banner\\d+/
        ||пример.рф^
        example.*##.ad
        ~example.com#@#.ad
        ||ok.example^
        """)
        #expect(conversion.filterCount == 23)
        #expect(conversion.skipped == [
            .csp: 1,
            .redirect: 2,
            .removeparam: 1,
            .rewrite: 1,
            .badfilter: 1,
            .genericblock: 1,
            .unsupportedType: 1,
            .unsupportedOption: 1,
            .scriptlet: 1,
            .snippet: 1,
            .extendedCSS: 1,
            .procedural: 2,
            .htmlFilter: 1,
            .adguardScript: 1,
            .unsupportedSelector: 2,
            .regexUnsupported: 1,
            .nonASCII: 1,
            .entityDomain: 1,
            .unsupportedDomainList: 1,
        ])
        #expect(conversion.lists == [[block("\(anchor)ok\\.example\(separator)"), letPagesThrough]])
    }

    /// WebKit's parser rejects `:has()` inside `:has()` (four such filters in
    /// EasyList, 2026-10-30) and would drop their whole batch with them.
    @Test func aHasInsideAHasIsRefusedButSiblingHasStays() {
        #expect(BrowserFilterConverter.selectorProblem("article:has(header:has(.ct-sponsored))") == .unsupportedSelector)
        #expect(BrowserFilterConverter.selectorProblem("div > [style]:has([style]:has([href*=\"&utm\"]))") == .unsupportedSelector)
        #expect(BrowserFilterConverter.selectorProblem("li:has(> .a):has(.b)") == nil)
        #expect(BrowserFilterConverter.selectorProblem("div:has(:is(.a, .b))") == nil)
        #expect(BrowserFilterConverter.selectorProblem("a[title=\":has(:has(\"]") == nil)
        let conversion = BrowserFilterConverter.convert("""
        example.com##article:has(header:has(.ct-sponsored))
        example.com##.kept
        """)
        #expect(conversion.skipped == [.unsupportedSelector: 1])
        let hidden = conversion.lists.joined().compactMap { rule -> [String]? in
            if case let .cssDisplayNone(selectors) = rule.action { return selectors }
            return nil
        }
        #expect(hidden == [[".kept"]])
    }

    // MARK: - Lists

    @Test func listsAreChunkedWithTheirExceptionsInEach() {
        let conversion = BrowserFilterConverter.convert("""
        /a1
        /a2
        /a3
        /a4
        /a5
        @@/a3$script
        """, maxRulesPerList: 4)
        // Each list: up to 2 blocks, the exception and the page rule.
        #expect(conversion.lists.map(\.count) == [4, 4, 3])
        #expect(conversion.lists.allSatisfy { $0.count <= 4 })
        #expect(conversion.lists.map { $0.filter { $0.action == .block }.map(\.urlFilter) } == [
            ["/a1", "/a2"], ["/a3", "/a4"], ["/a5"],
        ])
        for list in conversion.lists {
            #expect(Array(list.suffix(2)) == [
                Rule(urlFilter: "/a3", resourceTypes: ["script"], action: .ignorePreviousRules),
                letPagesThrough,
            ])
        }
        #expect(conversion.ruleCount == 11)
    }

    @Test func theRealListLimitIsWebKits() {
        #expect(BrowserFilterConverter.maxRulesPerList == 150_000)
        let text = (1...3).map { "/ad\($0)" }.joined(separator: "\n")
        #expect(BrowserFilterConverter.convert(text).lists.count == 1)
    }

    @Test func encodesWebKitsJSON() throws {
        let rule = Rule(
            urlFilter: "\(anchor)ads\\.example\(separator)",
            caseSensitive: true,
            resourceTypes: ["script"],
            loadType: "third-party",
            loadContext: "child-frame",
            condition: .ifDomain(["*example.com"]),
            action: .block
        )
        let data = Data(BrowserContentRule.json([rule]).utf8)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: [String: Any]]])
        let trigger = try #require(decoded.first?["trigger"])
        #expect(trigger["url-filter"] as? String == rule.urlFilter)
        #expect(trigger["url-filter-is-case-sensitive"] as? Bool == true)
        #expect(trigger["resource-type"] as? [String] == ["script"])
        #expect(trigger["load-type"] as? [String] == ["third-party"])
        #expect(trigger["load-context"] as? [String] == ["child-frame"])
        #expect(trigger["if-domain"] as? [String] == ["*example.com"])
        #expect(decoded.first?["action"]?["type"] as? String == "block")
    }
}
