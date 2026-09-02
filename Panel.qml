import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A markets panel in the bar, laid out the way Google Finance lays out its
// front page: your watchlist down the left, and on the right the indexes
// across the top with market news and then your companies' news beneath.
//
// One watchlist, kept as a plain JSON array so it can be edited either from
// the panel or in a text editor, and one quote request per refresh -- CNBC
// takes every symbol on screen, indexes and stocks together, in a single
// call, so the whole panel costs one round trip.
Panel {
  id: root
  moduleName: "pyang.finance"
  ipcTarget: "pyang.finance"
  // Taken over below so `add` and `refresh` can be bound to keys too.
  manageIpc: false

  // ---- Where things live. The watchlist is deliberately outside the plugin
  //      directory: the plugin is a git checkout, and a file that changes
  //      every time you add a ticker would leave it permanently dirty.
  readonly property string home: Quickshell.env("HOME")
  readonly property string watchlistPath: setting("watchlistFile",
    home + "/.config/omarchy/finance/watchlist.json")
  readonly property string watchlistDir: watchlistPath.replace(/\/[^\/]*$/, "")
  // The symbol index is a cache, not a document: it sits beside the
  // watchlist so both survive a reinstall, but nothing here expects anyone
  // to open it, and deleting it only costs one download.
  readonly property string symbolIndexPath: setting("symbolIndexFile",
    home + "/.config/omarchy/finance/symbols.txt")
  readonly property string symbolIndexDir: symbolIndexPath.replace(/\/[^\/]*$/, "")

  readonly property string pluginDir: {
    var here = Qt.resolvedUrl(".").toString()
    return here.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string fetcher: pluginDir + "/fetch-feed"

  // ---- Settings, all overridable per-entry in shell.json.
  readonly property var indexSymbols: {
    var configured = setting("indexes", null)
    if (configured && configured.length) {
      var out = []
      for (var i = 0; i < configured.length; i++) {
        var s = Model.normalizeSymbol(configured[i])
        if (s !== "") out.push(s)
      }
      if (out.length) return out
    }
    return [".SPX", ".DJI", ".IXIC"]
  }
  readonly property string barSymbol: Model.normalizeSymbol(setting("barSymbol", ".SPX"))
  readonly property bool showBarChange: setting("showBarChange", true) === true
  readonly property int refreshIntervalSec: Math.max(10, setting("refreshIntervalSec", 30))
  readonly property int newsIntervalSec: Math.max(60, setting("newsIntervalSec", 600))
  readonly property string marketNewsUrl: setting("marketNewsUrl", Model.MARKET_NEWS_URL)
  readonly property string businessNewsUrl: setting("businessNewsUrl", Model.BUSINESS_NEWS_URL)
  // Market news is the day's news. Anything older is history, and history
  // belongs on the chart rather than in a headline list.
  readonly property bool marketNewsTodayOnly: setting("marketNewsTodayOnly", true) !== false
  readonly property var seedTickers: setting("defaultTickers",
    ["AAPL", "MSFT", "NVDA", "GOOGL", "AMZN"])

  // ---- Look. Up and down are the one place this panel does not follow the
  //      theme: a red loss and a green gain are what the numbers mean, not
  //      decoration, and every other finance surface a person reads uses
  //      them. Both are settings for anyone who disagrees or cannot see them.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color upColor: setting("upColor", "#3fb950")
  readonly property color downColor: setting("downColor", "#f85149")
  readonly property color mutedColor: Util.alpha(fg, 0.58)
  readonly property color faintColor: Util.alpha(fg, 0.36)
  readonly property color ruleColor: Util.alpha(fg, 0.14)
  readonly property bool vertical: bar ? bar.vertical : false

  function tone(quote) {
    if (!quote || !quote.valid) return root.mutedColor
    return quote.up ? root.upColor : (quote.down ? root.downColor : root.mutedColor)
  }

  // ---- Type. The panel runs a step above the shell's own ramp: this is a
  //      reading surface, not a status readout, and the shell sizes for a
  //      26px bar. Every size derives from the shell's tokens rather than
  //      being pinned, so `omarchy font set` and a theme's [font] scale still
  //      carry through. `textScale` re-tunes the whole panel at once.
  readonly property real textScale: {
    var n = Number(setting("textScale", 1.25))
    return isFinite(n) && n > 0 ? Math.max(0.6, Math.min(2.5, n)) : 1.25
  }
  function scaled(px) { return Math.max(1, Math.round(px * root.textScale)) }

  readonly property int fontTiny: scaled(Style.font.caption)
  readonly property int fontSmall: scaled(Style.font.bodySmall)
  readonly property int fontBody: scaled(Style.font.body)
  readonly property int fontHead: scaled(Style.font.subtitle)
  readonly property int fontDisplay: scaled(Style.font.title)

  // ---- Metrics. Scaled alongside the type: rows that keep their old height
  //      around larger text clip the descenders and crowd the two lines in a
  //      quote row into each other.
  readonly property int listWidth: scaled(Style.space(268))
  readonly property int gutter: Style.space(20)
  readonly property int quoteRowHeight: scaled(Style.space(40))
  readonly property int newsRowHeight: scaled(Style.space(34))
  readonly property int indexCardHeight: scaled(Style.space(70))
  readonly property int sectionHeaderHeight: scaled(Style.space(22))

  // ---- State. `quotes` is replaced wholesale on every load rather than
  //      mutated, so the bindings that read it actually re-evaluate.
  property var tickers: []
  property var quotes: ({})
  property var marketNews: []
  property var businessNews: []
  property bool watchlistLoaded: false
  property string lastError: ""
  property double lastQuoteAt: 0
  property double lastNewsAt: 0
  property int failures: 0
  property double nowMs: Date.now()

  // What we last wrote, so the reload our own write provokes is not mistaken
  // for someone editing the file underneath us.
  property string writtenText: ""

  readonly property var barQuote: quotes[root.barSymbol] || null
  readonly property var selectedQuote: (section === 0 && wlCursor >= 0 && wlCursor < tickers.length)
    ? (quotes[tickers[wlCursor]] || null) : null
  readonly property string marketStatus: {
    for (var i = 0; i < root.tickers.length; i++) {
      var q = root.quotes[root.tickers[i]]
      if (q && q.valid && q.marketStatus) return Model.marketStatusLabel(q.marketStatus)
    }
    var idx = root.quotes[root.indexSymbols[0]]
    return idx && idx.valid ? Model.marketStatusLabel(idx.marketStatus) : ""
  }

  // ---- Cursor. Three lists share the keyboard; `section` says which one has
  //      it, and each keeps its own row so tabbing back returns you where you
  //      were rather than to the top.
  property int section: 0
  property int wlCursor: 0
  property int mnCursor: 0
  property int bizCursor: 0
  property bool adding: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ watchlist

  function ingestWatchlist(text) {
    if (text !== null && text === root.writtenText) return
    var seeded = !text || !String(text).trim()
    root.tickers = Model.parseWatchlist(text, root.seedTickers)
    root.watchlistLoaded = true
    // A machine with no watchlist file gets the seed written out, so the
    // first thing anyone opens is a file they can see and edit.
    if (seeded) saveWatchlist()
    clampCursors()
    refreshQuotes()
  }

  function saveWatchlist() {
    var out = Model.serializeWatchlist(root.tickers)
    root.writtenText = out
    watchlistFile.setText(out)
  }

  function addTicker(raw) {
    var symbol = Model.normalizeSymbol(raw)
    if (symbol === "") return false
    if (root.tickers.indexOf(symbol) >= 0) {
      // Already there: take the cursor to it rather than saying no.
      root.section = 0
      root.wlCursor = root.tickers.indexOf(symbol)
      return true
    }
    var next = root.tickers.slice()
    next.push(symbol)
    root.tickers = next
    root.section = 0
    root.wlCursor = next.length - 1
    saveWatchlist()
    refreshQuotes()
    return true
  }

  function removeTicker(index) {
    if (index < 0 || index >= root.tickers.length) return
    var next = root.tickers.slice()
    next.splice(index, 1)
    root.tickers = next
    saveWatchlist()
    clampCursors()
    refreshNews()
  }

  function moveTicker(index, delta) {
    var target = index + delta
    if (index < 0 || index >= root.tickers.length) return
    if (target < 0 || target >= root.tickers.length) return
    var next = root.tickers.slice()
    var held = next[index]
    next[index] = next[target]
    next[target] = held
    root.tickers = next
    root.wlCursor = target
    saveWatchlist()
  }

  function clampCursors() {
    root.wlCursor = Math.max(0, Math.min(root.wlCursor, root.tickers.length - 1))
    root.mnCursor = Math.max(0, Math.min(root.mnCursor, root.marketNews.length - 1))
    root.bizCursor = Math.max(0, Math.min(root.bizCursor, root.businessNews.length - 1))
  }

  // ---------------------------------------------------------------- fetch

  // A refresh asked for while one is in flight is remembered rather than
  // dropped: adding a ticker calls straight through to here, and dropping
  // that call leaves the new row blank until the next poll comes round.
  property bool quotesPending: false

  function refreshQuotes() {
    if (quoteProc.running) { root.quotesPending = true; return }
    root.quotesPending = false
    var wanted = root.indexSymbols.slice()
    if (root.barSymbol !== "" && wanted.indexOf(root.barSymbol) < 0) wanted.push(root.barSymbol)
    for (var i = 0; i < root.tickers.length; i++) wanted.push(root.tickers[i])
    quoteProc.command = [root.fetcher, Model.quoteUrl(wanted)]
    quoteProc.running = true
  }

  function refreshNews() {
    if (!marketNewsProc.running) {
      marketNewsProc.command = [root.fetcher, root.marketNewsUrl]
      marketNewsProc.running = true
    }
    if (!businessNewsProc.running) {
      businessNewsProc.command = [root.fetcher, root.businessNewsUrl]
      businessNewsProc.running = true
    }
  }

  function refresh() {
    root.failures = 0
    refreshQuotes()
    refreshNews()
  }

  function ingestQuotes(text) {
    var parsed = Model.parseQuotes(text)
    if (!parsed || Object.keys(parsed).length === 0) {
      root.failures += 1
      root.lastError = "No quotes returned"
      return
    }
    // CNBC answers an unknown symbol with code 1, but a symbol it drops from
    // the response altogether would sit on the loading ellipsis forever.
    // Anything asked for and not returned is marked not found here.
    for (var i = 0; i < root.tickers.length; i++) {
      var symbol = root.tickers[i]
      if (!parsed[symbol]) {
        parsed[symbol] = { symbol: symbol, valid: false, name: symbol, brand: symbol,
                           shortName: symbol, last: "--", change: "--", changePct: "--",
                           pct: NaN, delta: NaN, up: false, down: false, flat: true,
                           open: "", high: "", low: "", prevClose: "", volume: "",
                           marketCap: "", isIndex: false, marketStatus: "" }
      }
    }
    root.quotes = parsed
    root.lastQuoteAt = Date.now()
    root.nowMs = root.lastQuoteAt
    root.failures = 0
    root.lastError = ""
  }

  // Nothing in this panel launches a browser. "More" happens in place: a news
  // row opens downward to show what its feed already carried alongside the
  // headline -- a summary sentence from MarketWatch, the same story from other
  // outlets from Google. Both arrived with the item, so expanding costs
  // nothing and reaches nowhere.
  property int expandedSection: -1
  property int expandedIndex: -1

  readonly property bool detailOpen: root.expandedSection >= 0

  function toggleExpand(sectionId, index) {
    if (root.expandedSection === sectionId && root.expandedIndex === index) {
      root.collapseDetail()
      return
    }
    root.expandedSection = sectionId
    root.expandedIndex = index
    // An expanded row is usually taller than what is left below it, so bring
    // it into view rather than leaving the reader to scroll for it.
    Qt.callLater(function() { root.setCursorIn(sectionId, index) })
  }

  function collapseDetail() {
    root.expandedSection = -1
    root.expandedIndex = -1
  }

  function expandCurrent() {
    if (root.section === 0) return
    root.toggleExpand(root.section, root.cursorIn(root.section))
  }

  // ------------------------------------------------------------ keyboard

  function rowsIn(which) {
    if (which === 0) return root.tickers.length
    if (which === 1) return root.marketNews.length
    return root.businessNews.length
  }

  function cursorIn(which) {
    if (which === 0) return root.wlCursor
    if (which === 1) return root.mnCursor
    return root.bizCursor
  }

  function setCursorIn(which, value) {
    var count = rowsIn(which)
    if (count <= 0) return
    var next = Math.max(0, Math.min(value, count - 1))
    // Expansion belongs to the row being read. Moving off it closes it, so a
    // stale open row is never left behind somewhere off screen.
    if (root.detailOpen && (root.expandedSection !== which || root.expandedIndex !== next))
      root.collapseDetail()
    if (which === 0) { root.wlCursor = next; watchlistView.positionViewAtIndex(next, ListView.Contain) }
    else if (which === 1) { root.mnCursor = next; marketNewsView.positionViewAtIndex(next, ListView.Contain) }
    else { root.bizCursor = next; businessNewsView.positionViewAtIndex(next, ListView.Contain) }
  }

  function moveCursor(delta) {
    setCursorIn(root.section, cursorIn(root.section) + delta)
  }

  // Tab walks the three lists in reading order and wraps. Sections with
  // nothing in them are stepped over rather than landed on -- an empty news
  // list that eats the keyboard reads as the panel having frozen.
  function stepSection(direction) {
    for (var i = 0; i < 3; i++) {
      var next = (root.section + direction * (i + 1) + 9) % 3
      if (rowsIn(next) > 0) { root.section = next; return }
    }
  }

  // ---- Adding a ticker. Typing searches Nasdaq for matching symbols and
  //      company names, because a ticker is not something most people can
  //      recall on demand -- you know the company, not its four letters.
  property var suggestions: []
  property int suggestionIndex: 0
  property string pendingQuery: ""
  property string activeQuery: ""
  // A picker that shows nothing is ambiguous: still typing? no matches? search
  // down? Each of those gets its own line, so the box is never silently empty.
  property bool searching: false
  property bool searchFailed: false
  property string searchedQuery: ""
  // Every result set is kept, keyed by the query that fetched it. A longer
  // query whose prefix is already cached is answered from it instantly while
  // the network catches up, so only the first keystrokes of a word ever wait.
  property var searchCache: ({})

  // Nasdaq answers a one-character query slowest of all and least usefully,
  // so the *network* search does not start until there are two. The local
  // index below is free and answers from the first letter.
  readonly property int minSearchChars: 2

  // ---- The local symbol index: every US-listed symbol and name, ranked in
  //      about a millisecond, which is what lets the picker keep up with
  //      typing at all. Nasdaq's autocomplete is 1.5-3 seconds of server time
  //      per query and no amount of debouncing hides that, so it is now only
  //      the fallback for what the directory does not list. See Model.js.
  property var symbolIndex: []
  property double symbolIndexFetchedAt: 0
  // Loaded on first open rather than at shell start: a widget nobody opens
  // should not read half a megabyte off disk, let alone fetch two files.
  property bool symbolIndexWanted: false
  // Which directory file is in flight, and the rows collected so far.
  property int symbolIndexStep: -1
  property var symbolIndexRows: []
  property bool symbolIndexFailed: false
  readonly property int symbolIndexMaxAgeDays:
    Math.max(1, setting("symbolIndexMaxAgeDays", Model.SYMBOL_INDEX_MAX_AGE_DAYS))

  readonly property var chosenSuggestion:
    (suggestionIndex >= 0 && suggestionIndex < suggestions.length)
      ? suggestions[suggestionIndex] : null

  function beginAdd() {
    root.adding = true
    root.wantSymbolIndex()
    addField.text = ""
    root.suggestions = []
    root.suggestionIndex = 0
    root.pendingQuery = ""
    root.activeQuery = ""
    root.searching = false
    root.searchFailed = false
    root.searchedQuery = ""
    // Deferred: when this is reached by clicking "+ add ticker", the field is
    // only becoming visible on this same frame, and an item that is not yet
    // visible cannot take active focus. Asking on the next tick works for both
    // the click and the `a` key.
    Qt.callLater(function() { if (root.adding) addField.forceActiveFocus() })
  }

  function cancelAdd() {
    searchTimer.stop()
    root.adding = false
    root.searching = false
    root.searchFailed = false
    root.suggestions = []
    addField.text = ""
    keyCatcher.forceActiveFocus()
  }

  // Enter takes the highlighted match if there is one, and otherwise whatever
  // was typed -- so a symbol you already know still goes straight in without
  // waiting for the search to come back.
  function commitAdd() {
    var pick = root.chosenSuggestion
    var symbol = pick ? pick.symbol : addField.text
    root.cancelAdd()
    root.addTicker(symbol)
  }

  function moveSuggestion(delta) {
    if (root.suggestions.length === 0) return
    var next = root.suggestionIndex + delta
    if (next < 0) next = root.suggestions.length - 1
    else if (next >= root.suggestions.length) next = 0
    root.suggestionIndex = next
  }

  // The best cached answer for a query: the longest cached prefix of it,
  // re-ranked. Returns null when nothing cached can speak to this query.
  function localSuggestions(query) {
    var q = String(query || "").trim().toUpperCase()
    if (q === "") return null
    var bestKey = ""
    for (var key in root.searchCache) {
      if (q.indexOf(key) === 0 && key.length > bestKey.length) bestKey = key
    }
    if (bestKey === "") return null
    return Model.rankRows(root.searchCache[bestKey], q, 6)
  }

  // The index covers the whole listed universe, so when it has a match there
  // is nothing a round trip could add -- and unlike Nasdaq's reply it is
  // neither capped at thirty rows nor padded with mutual funds, so "micro"
  // finds Microsoft and "appl" is not led by ZAPPLX. Crypto, indexes,
  // treasuries and OTC names are not in it and still fall through below.
  function indexSuggestions(query) {
    if (root.symbolIndex.length === 0) return null
    var q = String(query || "").trim().toUpperCase()
    if (q === "") return null
    var hits = Model.rankRows(root.symbolIndex, q, 6)
    return hits.length > 0 ? hits : null
  }

  // ---- Keeping the index current.

  function wantSymbolIndex() {
    // Setting this starts the FileView load; a second call only re-checks age.
    if (!root.symbolIndexWanted) root.symbolIndexWanted = true
    else root.maybeRefreshSymbolIndex()
  }

  function ingestSymbolIndex(text) {
    if (!root.symbolIndexWanted) return
    var parsed = Model.parseSymbolIndex(text)
    if (parsed !== null) {
      root.symbolIndex = parsed.rows
      root.symbolIndexFetchedAt = parsed.fetchedAt
    }
    root.maybeRefreshSymbolIndex()
  }

  function maybeRefreshSymbolIndex() {
    if (root.symbolIndexStep >= 0) return
    if (!Model.symbolIndexStale(root.symbolIndexFetchedAt, Date.now(),
                                root.symbolIndexMaxAgeDays)) return
    root.symbolIndexRows = []
    root.symbolIndexFailed = false
    root.symbolIndexStep = 0
    root.fetchSymbolDirectory()
  }

  function fetchSymbolDirectory() {
    var step = root.symbolIndexStep
    if (step < 0 || step >= Model.SYMBOL_DIRECTORIES.length) return
    symbolIndexProc.command = [root.fetcher, Model.SYMBOL_DIRECTORIES[step].url]
    symbolIndexProc.running = true
  }

  function queueSearch(text) {
    var next = String(text || "").trim()
    root.pendingQuery = next
    if (next === "") {
      searchTimer.stop()
      root.suggestions = []
      root.searching = false
      root.searchFailed = false
      root.searchedQuery = ""
      return
    }
    root.searchFailed = false

    // The index first, and if it answers, that is the answer -- no timer, no
    // request, no spinner.
    var indexed = root.indexSuggestions(next)
    if (indexed !== null) {
      searchTimer.stop()
      root.suggestions = indexed
      root.suggestionIndex = 0
      root.searching = false
      root.searchedQuery = next
      return
    }

    // Show whatever the cache can answer right now, before deciding whether a
    // request is even needed. This is what makes typing past the first couple
    // of letters feel instant.
    var local = root.localSuggestions(next)
    if (local !== null) {
      root.suggestions = local
      root.suggestionIndex = 0
      root.searching = false
    } else {
      root.suggestions = []
      root.searching = next.length >= root.minSearchChars
    }

    if (next.length < root.minSearchChars) { searchTimer.stop(); return }
    searchTimer.restart()
  }

  function runSearch() {
    if (!root.adding || root.pendingQuery === "") return
    // One search in flight at a time; whatever was typed meanwhile is picked
    // up when it exits, so the last keystroke always wins.
    if (searchProc.running) return
    root.activeQuery = root.pendingQuery
    root.searching = true
    searchProc.command = [root.fetcher, Model.searchUrl(root.activeQuery)]
    searchProc.running = true
  }

  // ---------------------------------------------------------------- wiring

  onOpenedChanged: {
    if (root.opened) {
      root.nowMs = Date.now()
      // News is fetched lazily: a panel that is never opened should not be
      // pulling two RSS feeds all day.
      if (root.marketNews.length === 0 || Date.now() - root.lastNewsAt > root.newsIntervalSec * 1000)
        refreshNews()
      if (Date.now() - root.lastQuoteAt > 5000) refreshQuotes()
      root.wantSymbolIndex()
    } else {
      cancelAdd()
    }
  }

  Component.onCompleted: refreshQuotes()

  IpcHandler {
    target: "pyang.finance"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function add(symbol: string): void {
      root.addTicker(symbol)
    }
    function remove(symbol: string): void {
      var index = root.tickers.indexOf(Model.normalizeSymbol(symbol))
      if (index >= 0) root.removeTicker(index)
    }
  }

  // FileView will not create the directory it writes into.
  Process {
    id: mkdirProc
    running: true
    command: ["mkdir", "-p", root.watchlistDir, root.symbolIndexDir]
  }

  FileView {
    id: watchlistFile
    path: root.watchlistPath
    watchChanges: true
    printErrors: false
    onLoaded: root.ingestWatchlist(text())
    onLoadFailed: root.ingestWatchlist(null)
    onFileChanged: reload()
  }

  FileView {
    id: symbolIndexFile
    // Empty until the panel is first opened; FileView starts loading as soon
    // as it has a path.
    path: root.symbolIndexWanted ? root.symbolIndexPath : ""
    printErrors: false
    onLoaded: root.ingestSymbolIndex(text())
    // No cache yet, or one this version cannot read: fetch a fresh one.
    onLoadFailed: root.ingestSymbolIndex(null)
  }

  // The two directory files are fetched one after the other rather than at
  // once, because they are a single artifact: a half-built index should never
  // reach the picker, and one Process makes "half" easy to rule out.
  Process {
    id: symbolIndexProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var step = root.symbolIndexStep
        if (step < 0 || step >= Model.SYMBOL_DIRECTORIES.length) return
        var rows = Model.parseSymbolDirectory(String(text || ""),
                                              Model.SYMBOL_DIRECTORIES[step])
        if (rows.length === 0) root.symbolIndexFailed = true
        else root.symbolIndexRows = root.symbolIndexRows.concat(rows)
      }
    }
    onExited: function(code, status) {
      if (code !== 0) root.symbolIndexFailed = true

      var next = root.symbolIndexStep + 1
      if (!root.symbolIndexFailed && next < Model.SYMBOL_DIRECTORIES.length) {
        root.symbolIndexStep = next
        Qt.callLater(root.fetchSymbolDirectory)
        return
      }
      root.symbolIndexStep = -1

      // A failed or partial download leaves whatever was already on disk in
      // place. A stale index still answers; half an index answers wrongly.
      if (!root.symbolIndexFailed && root.symbolIndexRows.length > 0) {
        root.symbolIndex = root.symbolIndexRows
        root.symbolIndexFetchedAt = Date.now()
        symbolIndexFile.setText(
          Model.serializeSymbolIndex(root.symbolIndex, root.symbolIndexFetchedAt))
      }
      root.symbolIndexRows = []
    }
  }

  Process {
    id: quoteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestQuotes(String(text || ""))
    }
    onExited: function(code, status) {
      if (code !== 0) {
        root.failures += 1
        root.lastError = "Quotes unavailable"
      }
      if (root.quotesPending) Qt.callLater(root.refreshQuotes)
    }
  }

  // 300ms. The list keeps up regardless because the cache answers while this
  // waits; the debounce only decides how many two-second requests get made.
  Timer {
    id: searchTimer
    interval: 300
    onTriggered: root.runSearch()
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.adding) return
        var rows = Model.parseSearchRows(String(text || ""))
        if (rows.length > 0) root.searchCache[root.activeQuery.toUpperCase()] = rows

        // A reply for a query the user has already typed past is still worth
        // having: it goes in the cache above, and the cache can then answer
        // what they have actually typed. Every path through here has to settle
        // `searching`, or a superseded reply leaves the box saying "Searching"
        // with nothing ever coming to replace it.
        if (root.activeQuery !== root.pendingQuery) {
          var local = root.localSuggestions(root.pendingQuery)
          if (local !== null) {
            root.suggestions = local
            root.suggestionIndex = 0
          }
          root.searching = root.pendingQuery.length >= root.minSearchChars
                           && local === null
          return
        }

        root.suggestions = Model.rankRows(rows, root.activeQuery, 6)
        root.suggestionIndex = 0
        root.searchedQuery = root.activeQuery
        root.searching = false
      }
    }
    onExited: function(code, status) {
      if (code !== 0 && root.activeQuery === root.pendingQuery) {
        root.searchFailed = true
        root.searching = false
      }
      if (root.adding && root.pendingQuery !== root.activeQuery) Qt.callLater(root.runSearch)
    }
  }

  Process {
    id: marketNewsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var items = Model.parseRss(String(text || ""), 30, Model.MARKET_NEWS_SOURCE)
        // An empty parse means the fetch failed -- keep whatever is on screen.
        // An empty *filter* is a real answer ("nothing yet today") and must be
        // allowed to clear the list, so the two cases are separated here.
        if (items.length > 0) {
          root.marketNews = root.marketNewsTodayOnly
            ? Model.filterToday(items, Date.now()) : items
          root.lastNewsAt = Date.now()
          root.clampCursors()
        }
      }
    }
  }

  Process {
    id: businessNewsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var items = Model.parseRss(String(text || ""), 40)
        if (items.length > 0) {
          root.businessNews = items
          root.clampCursors()
        }
      }
    }
  }

  // Quotes poll faster while the panel is on screen than behind it, slower
  // still once the market has shut, and back off on repeated failure so a
  // blocked endpoint is not hammered.
  Timer {
    id: quoteTimer
    running: true
    repeat: true
    interval: {
      var base = root.opened ? root.refreshIntervalSec * 1000
                             : Math.max(60000, root.refreshIntervalSec * 2000)
      var status = root.barQuote ? root.barQuote.marketStatus : ""
      if (status === "CLOSED_MKT") base = Math.max(base, 300000)
      var backoff = Math.min(8, Math.pow(2, root.failures))
      return Math.round(base * backoff)
    }
    onTriggered: root.refreshQuotes()
  }

  Timer {
    id: newsTimer
    running: root.opened
    repeat: true
    interval: root.newsIntervalSec * 1000
    onTriggered: root.refreshNews()
  }

  // Only to keep the relative timestamps on the news honest while the panel
  // sits open; nothing else reads it.
  Timer {
    running: root.opened
    repeat: true
    interval: 30000
    onTriggered: root.nowMs = Date.now()
  }

  // ------------------------------------------------------------ bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.barQuote && root.barQuote.valid
      ? root.barQuote.shortName + "  " + root.barQuote.last + "  " + root.barQuote.changePct
      : "Markets"
    fixedWidth: root.vertical ? -1 : Math.max(Style.bar.iconSlot,
      Math.round(barRow.implicitWidth + Style.spaceReal(8.5) * 2))
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.refresh() }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰄨"
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        color: button.foreground
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showBarChange && !root.vertical
                 && root.barQuote !== null && root.barQuote.valid
        text: root.barQuote && root.barQuote.valid ? root.barQuote.changePct : ""
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.tone(root.barQuote)
        renderType: Text.NativeRendering
      }
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.scaled(Style.space(920)))
    contentHeight: panel.fittedContentHeight(root.scaled(Style.space(560)),
                                            Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the add field owns the keyboard every key belongs to it,
      // including the letters that are otherwise commands.
      blocked: root.adding

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        // Left and right cross the gutter: the watchlist on one side, the
        // news stack on the other.
        if (dx < 0) { if (root.rowsIn(0) > 0) root.section = 0 }
        else if (dx > 0) { if (root.section === 0) root.stepSection(1) }
      }
      onActivateRequested: root.expandCurrent()
      onReturnRequested: root.expandCurrent()
      // Esc closes what is open before it closes the panel, so the key always
      // undoes the most recent thing.
      onCloseRequested: {
        if (root.detailOpen) root.collapseDetail()
        else root.close()
      }
      onDeleteRequested: { if (root.section === 0) root.removeTicker(root.wlCursor) }
      onTabRequested: function(direction) { root.stepSection(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "A" || t === "+") root.beginAdd()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "d" || t === "D" || t === "x") {
          if (root.section === 0) root.removeTicker(root.wlCursor)
        }
        else if (t === "[") { if (root.section === 0) root.moveTicker(root.wlCursor, -1) }
        else if (t === "]") { if (root.section === 0) root.moveTicker(root.wlCursor, 1) }
        else if (t === "o" || t === "O") root.expandCurrent()
        else if (t === "g") root.setCursorIn(root.section, 0)
        else if (t === "G") root.setCursorIn(root.section, root.rowsIn(root.section) - 1)
      }

      // ============================================================ left

      Item {
        id: leftColumn
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.listWidth

        Item {
          id: watchlistHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.sectionHeaderHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Watchlist"
            font.family: root.fontFamily
            font.pixelSize: root.fontHead
            color: root.fg
            renderType: Text.NativeRendering
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.marketStatus
            font.family: root.fontFamily
            font.pixelSize: root.fontTiny
            color: root.faintColor
            renderType: Text.NativeRendering
          }
        }

        Rectangle {
          id: leftRule
          anchors.top: watchlistHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(1, Style.space(1))
          color: root.ruleColor
        }

        ListView {
          id: watchlistView
          anchors.top: leftRule.bottom
          anchors.topMargin: Style.space(4)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: detailStrip.top
          anchors.bottomMargin: Style.space(6)
          clip: true
          model: root.tickers
          boundsBehavior: Flickable.StopAtBounds
          snapMode: ListView.SnapToItem

          delegate: Item {
            id: quoteRow
            required property string modelData
            required property int index
            width: watchlistView.width
            height: root.quoteRowHeight

            readonly property var quote: root.quotes[quoteRow.modelData] || null
            readonly property bool current: root.section === 0 && root.wlCursor === quoteRow.index
            readonly property bool hot: rowMouse.containsMouse

            Rectangle {
              anchors.fill: parent
              anchors.rightMargin: Style.space(2)
              radius: Style.cornerRadius
              color: quoteRow.current ? Style.selectedFill
                                      : (quoteRow.hot ? Style.hoverFill : "transparent")
            }

            // The cursor's own mark, so a selected row is still legible on a
            // theme whose selection fill is nearly invisible.
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(1, Style.space(2))
              height: parent.height - Style.space(12)
              radius: width
              visible: quoteRow.current
              color: Color.accent
            }

            Item {
              anchors.fill: parent
              anchors.leftMargin: Style.space(9)
              anchors.rightMargin: Style.space(9)

              Text {
                id: symbolText
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                text: quoteRow.modelData
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                color: root.fg
                renderType: Text.NativeRendering
              }

              Text {
                anchors.left: parent.left
                anchors.right: lastText.left
                anchors.rightMargin: Style.space(8)
                anchors.top: symbolText.bottom
                text: quoteRow.quote
                  ? (quoteRow.quote.valid ? quoteRow.quote.brand : "not found")
                  : "…"
                font.family: root.fontFamily
                font.pixelSize: root.fontTiny
                color: quoteRow.quote && !quoteRow.quote.valid ? root.downColor : root.mutedColor
                elide: Text.ElideRight
                renderType: Text.NativeRendering
              }

              Text {
                id: lastText
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                text: quoteRow.quote && quoteRow.quote.valid ? quoteRow.quote.last : ""
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                color: root.fg
                renderType: Text.NativeRendering
              }

              Text {
                anchors.right: parent.right
                anchors.top: lastText.bottom
                text: quoteRow.quote && quoteRow.quote.valid ? quoteRow.quote.changePct : ""
                font.family: root.fontFamily
                font.pixelSize: root.fontTiny
                color: root.tone(quoteRow.quote)
                renderType: Text.NativeRendering
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(mouse) {
                root.section = 0
                root.wlCursor = quoteRow.index
                if (mouse.button === Qt.MiddleButton) root.removeTicker(quoteRow.index)
              }
            }
          }

          // An empty watchlist is a state worth naming rather than a blank box.
          Text {
            anchors.centerIn: parent
            visible: root.watchlistLoaded && root.tickers.length === 0
            text: "No tickers yet.\nPress a to add one."
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: root.fontTiny
            color: root.faintColor
            renderType: Text.NativeRendering
          }
        }

        // The stats Google Finance puts beside the chart, for whichever row
        // the cursor is on. Everything here arrived with the quote, so it
        // costs no extra request.
        Item {
          id: detailStrip
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: addRow.top
          anchors.bottomMargin: Style.space(6)
          height: visible ? root.scaled(Style.space(46)) : 0
          visible: root.selectedQuote !== null && root.selectedQuote.valid

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(1, Style.space(1))
            color: root.ruleColor
          }

          Grid {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.space(3)
            columns: 3
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(2)

            Repeater {
              model: {
                var q = root.selectedQuote
                if (!q) return []
                var pairs = [
                  { key: "Open", value: q.open },
                  { key: "High", value: q.high },
                  { key: "Low", value: q.low },
                  { key: "Prev", value: q.prevClose },
                  { key: "Vol", value: q.volume },
                  { key: q.isIndex ? "" : "Mkt cap", value: q.isIndex ? "" : q.marketCap }
                ]
                // Coerced and filtered here rather than in the delegate: a
                // not-found quote carries none of these fields, and binding a
                // Text to an undefined one warns on every evaluation.
                var out = []
                for (var i = 0; i < pairs.length; i++) {
                  var value = pairs[i].value
                  if (pairs[i].key === "" || value === undefined || value === null) continue
                  if (String(value) === "") continue
                  out.push({ key: pairs[i].key, value: String(value) })
                }
                return out
              }

              delegate: Row {
                required property var modelData
                spacing: Style.space(4)

                Text {
                  text: modelData.key
                  font.family: root.fontFamily
                  font.pixelSize: root.fontTiny
                  color: root.faintColor
                  renderType: Text.NativeRendering
                }

                Text {
                  text: modelData.value
                  font.family: root.fontFamily
                  font.pixelSize: root.fontTiny
                  color: root.mutedColor
                  renderType: Text.NativeRendering
                }
              }
            }
          }
        }

        // Adding a ticker is the one thing this panel must make trivial, so
        // the field is always on screen rather than behind a menu: press a,
        // or click it, type, Enter.
        Item {
          id: addRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: root.scaled(Style.space(30))

          TextField {
            id: addField
            anchors.fill: parent
            visible: root.adding
            foreground: root.fg
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontSmall
            verticalPadding: Style.space(4)
            placeholderText: "Ticker or company name"
            onTextChanged: root.queueSearch(text)
            onAccepted: root.commitAdd()
            Keys.onEscapePressed: root.cancelAdd()
            Keys.onUpPressed: root.moveSuggestion(-1)
            Keys.onDownPressed: root.moveSuggestion(1)
            onActiveFocusChanged: if (!activeFocus && root.adding) root.cancelAdd()
          }

          Rectangle {
            anchors.fill: parent
            visible: !root.adding
            radius: Style.cornerRadius
            color: addMouse.containsMouse ? Style.hoverFill : "transparent"
            border.width: Math.max(1, Style.space(1))
            border.color: addMouse.containsMouse ? Style.hoverBorderColor : root.ruleColor

            Text {
              anchors.centerIn: parent
              text: "+  add ticker"
              font.family: root.fontFamily
              font.pixelSize: root.fontTiny
              color: addMouse.containsMouse ? root.fg : root.mutedColor
              renderType: Text.NativeRendering
            }

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.beginAdd()
            }
          }
        }
      }

      // Matches open upward over the watchlist: the field is pinned to the
      // bottom of the column, so there is nowhere below it to go.
      Rectangle {
        id: suggestionBox
        parent: leftColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: addRow.top
        anchors.bottomMargin: Style.space(4)
        readonly property bool hasStatus: root.adding && root.pendingQuery !== ""
                                          && root.suggestions.length === 0
        visible: root.adding && (root.suggestions.length > 0 || hasStatus)
        height: !visible ? 0
              : (root.suggestions.length > 0
                 ? root.suggestions.length * root.quoteRowHeight + Style.space(8)
                 : root.quoteRowHeight + Style.space(8))
        z: 10
        radius: Style.cornerRadius
        color: Color.popups.background
        border.width: Math.max(1, Style.space(1))
        border.color: Style.hoverBorderColor

        Text {
          anchors.centerIn: parent
          visible: suggestionBox.hasStatus
          text: root.searchFailed ? "Search unavailable"
              : (root.pendingQuery.length < root.minSearchChars ? "Keep typing\u2026"
              : (root.searching ? "Searching\u2026"
                                : "No matches for " + root.pendingQuery))
          font.family: root.fontFamily
          font.pixelSize: root.fontTiny
          color: root.searchFailed ? root.downColor : root.faintColor
          renderType: Text.NativeRendering
        }

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(4)

          Repeater {
            model: root.suggestions

            delegate: Item {
              id: suggestionRow
              required property var modelData
              required property int index
              width: suggestionBox.width - Style.space(8)
              height: root.quoteRowHeight
              readonly property bool current: root.suggestionIndex === suggestionRow.index

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: suggestionRow.current ? Style.selectedFill
                     : (suggestionMouse.containsMouse ? Style.hoverFill : "transparent")
              }

              Text {
                id: suggestionSymbol
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                text: suggestionRow.modelData.symbol
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                color: root.fg
                renderType: Text.NativeRendering
              }

              // ETFs and funds are kept in the list -- people do hold them --
              // but marked, because a two-times-leveraged tracker sitting next
              // to the company it tracks is otherwise indistinguishable.
              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: suggestionSymbol.verticalCenter
                visible: suggestionRow.modelData.asset === "ETF"
                         || suggestionRow.modelData.asset === "MUTUALFUNDS"
                text: suggestionRow.modelData.asset === "ETF" ? "ETF" : "Fund"
                font.family: root.fontFamily
                font.pixelSize: root.fontTiny
                color: root.faintColor
                renderType: Text.NativeRendering
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.top: suggestionSymbol.bottom
                text: suggestionRow.modelData.name
                font.family: root.fontFamily
                font.pixelSize: root.fontTiny
                color: root.mutedColor
                elide: Text.ElideRight
                renderType: Text.NativeRendering
              }

              MouseArea {
                id: suggestionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.suggestionIndex = suggestionRow.index
                onClicked: {
                  root.suggestionIndex = suggestionRow.index
                  root.commitAdd()
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: spine
        anchors.left: leftColumn.right
        anchors.leftMargin: Math.round(root.gutter / 2)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.max(1, Style.space(1))
        color: root.ruleColor
      }

      // =========================================================== right

      Item {
        id: rightColumn
        anchors.left: spine.right
        anchors.leftMargin: Math.round(root.gutter / 2)
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        // Both news lists are sized to a whole number of rows. Letting them
        // fill the space instead leaves a headline sliced through the middle
        // at the bottom edge, which reads as the panel having been cut off
        // rather than as a list that scrolls.
        readonly property int newsAreaHeight:
          height - root.indexCardHeight - Style.space(26)
        readonly property int rowsAvailable: Math.max(2, Math.floor(
          (newsAreaHeight - marketHeading.height - businessHeading.height - Style.space(4))
          / root.newsRowHeight))
        readonly property int businessRows: Math.max(1, Math.round(rowsAvailable * 0.55))
        readonly property int marketRows: Math.max(1, rowsAvailable - businessRows)

        Row {
          id: indexRow
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.indexCardHeight
          spacing: Style.space(10)

          Repeater {
            model: root.indexSymbols

            delegate: Rectangle {
              id: indexCard
              required property string modelData
              readonly property var quote: root.quotes[indexCard.modelData] || null
              width: Math.floor((indexRow.width - Style.space(10) * (root.indexSymbols.length - 1))
                                / Math.max(1, root.indexSymbols.length))
              height: indexRow.height
              radius: Style.cornerRadius
              color: Style.normalFill
              border.width: Math.max(1, Style.space(1))
              border.color: cardMouse.containsMouse ? Style.hoverBorderColor : root.ruleColor

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(11)
                anchors.rightMargin: Style.space(11)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: indexCard.quote && indexCard.quote.valid
                    ? indexCard.quote.shortName : indexCard.modelData
                  font.family: root.fontFamily
                  font.pixelSize: root.fontTiny
                  color: root.mutedColor
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }

                Text {
                  width: parent.width
                  text: indexCard.quote && indexCard.quote.valid ? indexCard.quote.last : "…"
                  font.family: root.fontFamily
                  font.pixelSize: root.fontDisplay
                  color: root.fg
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }

                Text {
                  width: parent.width
                  text: indexCard.quote && indexCard.quote.valid
                    ? indexCard.quote.change + "  " + indexCard.quote.changePct : ""
                  font.family: root.fontFamily
                  font.pixelSize: root.fontTiny
                  color: root.tone(indexCard.quote)
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }
              }

              // Hover only. There is nowhere for a click on an index to go.
              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }
            }
          }
        }

        // ---- Market news

        Item {
          id: marketSection
          anchors.top: indexRow.bottom
          anchors.topMargin: Style.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          height: marketHeading.height + Style.space(2)
                  + rightColumn.marketRows * root.newsRowHeight

          PanelSectionHeader {
            id: marketHeading
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            text: "Market news"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: root.fontTiny
          }

          ListView {
            id: marketNewsView
            anchors.top: marketHeading.bottom
            anchors.topMargin: Style.space(2)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            model: root.marketNews
            boundsBehavior: Flickable.StopAtBounds
            snapMode: ListView.SnapToItem
            onModelChanged: if (root.mnCursor <= 0) positionViewAtBeginning()
            // Read back by the shared delegate, which cannot see this file's
            // ids from inside a Component any more than it could inline.
            property int sectionId: 1
            property int cursor: root.mnCursor
            delegate: newsDelegate
          }

          Text {
            anchors.centerIn: parent
            visible: root.marketNews.length === 0
            text: root.lastError !== "" ? root.lastError : "Loading news…"
            font.family: root.fontFamily
            font.pixelSize: root.fontTiny
            color: root.faintColor
            renderType: Text.NativeRendering
          }
        }

        // ---- Company news, for the watchlist

        Item {
          id: businessSection
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: businessHeading.height + Style.space(2)
                  + rightColumn.businessRows * root.newsRowHeight

          PanelSectionHeader {
            id: businessHeading
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            text: "Business news"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: root.fontTiny
          }

          ListView {
            id: businessNewsView
            anchors.top: businessHeading.bottom
            anchors.topMargin: Style.space(2)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            model: root.businessNews
            boundsBehavior: Flickable.StopAtBounds
            snapMode: ListView.SnapToItem
            onModelChanged: if (root.bizCursor <= 0) positionViewAtBeginning()
            property int sectionId: 2
            property int cursor: root.bizCursor
            delegate: newsDelegate
          }

          Text {
            anchors.centerIn: parent
            visible: root.businessNews.length === 0
            text: "Loading business news\u2026"
            font.family: root.fontFamily
            font.pixelSize: root.fontTiny
            color: root.faintColor
            renderType: Text.NativeRendering
          }
        }
      }

    }
  }

  // One news row: a ticker chip when the section wants one, the headline,
  // and the outlet with how long ago it ran.
  //
  // A Component rather than an inline `component NewsRow`, because an inline
  // component gets its own scope and cannot see this file's ids -- every
  // `root.` in here would fail to resolve. Both news lists share this one and
  // are told apart through the attached ListView.
  Component {
    id: newsDelegate

    Item {
      id: newsRow
      required property var modelData
      required property int index

      readonly property var view: ListView.view
      readonly property bool current: view
        ? (root.section === view.sectionId && view.cursor === newsRow.index) : false
      readonly property bool expanded: view
        ? (root.expandedSection === view.sectionId && root.expandedIndex === newsRow.index)
        : false
      readonly property bool hasDetail: newsRow.modelData.hasDetail === true

      width: view ? view.width : 0
      // The collapsed height is the section's whole-row rhythm; an open row
      // simply adds its content underneath rather than reflowing anything.
      height: root.newsRowHeight
              + (newsRow.expanded ? detailBlock.implicitHeight + Style.space(10) : 0)

      Rectangle {
        anchors.fill: parent
        anchors.rightMargin: Style.space(2)
        anchors.bottomMargin: newsRow.expanded ? Style.space(4) : 0
        radius: Style.cornerRadius
        color: newsRow.current ? Style.selectedFill
                               : (newsMouse.containsMouse ? Style.hoverFill : "transparent")
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: Style.space(5)
        width: Math.max(1, Style.space(2))
        height: root.newsRowHeight - Style.space(10)
        radius: width
        visible: newsRow.current
        color: Color.accent
      }

      // ---- the headline, always the same height ----
      Item {
        id: headerBlock
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(9)
        anchors.rightMargin: Style.space(6)
        height: root.newsRowHeight

        Text {
          id: headline
          anchors.left: parent.left
          anchors.right: chevron.left
          anchors.rightMargin: Style.space(6)
          anchors.top: parent.top
          anchors.topMargin: Style.space(3)
          text: newsRow.modelData.title || ""
          font.family: root.fontFamily
          font.pixelSize: root.fontSmall
          color: root.fg
          elide: Text.ElideRight
          renderType: Text.NativeRendering
        }

        // The only hint that a row opens, and only on the row you are on --
        // one on every row would be a column of arrows down the panel.
        Text {
          id: chevron
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.space(3)
          visible: newsRow.hasDetail && (newsRow.current || newsMouse.containsMouse)
          text: newsRow.expanded ? "\u2304" : "\u203a"
          font.family: root.fontFamily
          font.pixelSize: root.fontTiny
          color: root.faintColor
          renderType: Text.NativeRendering
        }

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: headline.bottom
          text: {
            var source = newsRow.modelData.source || ""
            var when = Model.relativeTime(newsRow.modelData.timestamp, root.nowMs)
            if (source === "") return when
            return when === "" ? source : source + "  \u00b7  " + when
          }
          font.family: root.fontFamily
          font.pixelSize: root.fontTiny
          color: root.faintColor
          elide: Text.ElideRight
          renderType: Text.NativeRendering
        }
      }

      // ---- what the feed carried beyond the headline ----
      Column {
        id: detailBlock
        anchors.top: headerBlock.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(9) + Math.max(1, Style.space(2)) + Style.space(6)
        anchors.rightMargin: Style.space(14)
        visible: newsRow.expanded
        spacing: Style.space(5)

        // MarketWatch's one-sentence summary.
        Text {
          width: parent.width
          visible: (newsRow.modelData.summary || "") !== ""
          text: newsRow.modelData.summary || ""
          font.family: root.fontFamily
          font.pixelSize: root.fontTiny
          color: root.mutedColor
          wrapMode: Text.WordWrap
          renderType: Text.NativeRendering
        }

        // Google's related coverage: the same story, elsewhere.
        Text {
          width: parent.width
          visible: (newsRow.modelData.related || []).length > 0
          text: "Also reported by"
          font.family: root.fontFamily
          font.pixelSize: root.fontTiny
          color: root.faintColor
          renderType: Text.NativeRendering
        }

        Repeater {
          model: newsRow.modelData.related || []

          delegate: Row {
            required property var modelData
            width: detailBlock.width
            spacing: Style.space(6)

            Text {
              width: Math.round(detailBlock.width * 0.72)
              text: modelData.title
              font.family: root.fontFamily
              font.pixelSize: root.fontTiny
              color: root.mutedColor
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }

            Text {
              text: modelData.source
              font.family: root.fontFamily
              font.pixelSize: root.fontTiny
              color: root.faintColor
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }
          }
        }

        Item { width: 1; height: Style.space(2) }
      }

      MouseArea {
        id: newsMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
          if (!newsRow.view) return
          root.section = newsRow.view.sectionId
          if (root.cursorIn(newsRow.view.sectionId) === newsRow.index && newsRow.hasDetail)
            root.toggleExpand(newsRow.view.sectionId, newsRow.index)
          else
            root.setCursorIn(newsRow.view.sectionId, newsRow.index)
        }
      }
    }
  }
}
