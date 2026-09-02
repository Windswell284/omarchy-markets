.pragma library

// Parsing and formatting for the Markets panel. Deliberately free of QML
// types so it can be exercised from node -- see README, "Hacking on it".
//
// Three feeds come in here and leave as flat objects the panel can bind to:
// CNBC's quote service (JSON), CNBC's markets RSS, and a Google News RSS
// search. Nothing in this file touches the network; the panel owns the
// requests and hands the raw text over.

// -------------------------------------------------------------- symbols

// CNBC spells indexes with a leading dot and crypto with a trailing ".CM=",
// neither of which anyone types. These are the spellings people actually
// reach for, mapped onto what the quote service wants.
//
// Only spellings that are not themselves listed tickers belong here. "DOW",
// "COMP" and "GOLD" all look like index shorthand and are all real companies
// (Dow Inc., Compass, Barrick Gold), so they are left alone -- typing one of
// them gets you the company, which is what the exchange says it means.
var ALIASES = {
  "SPX": ".SPX", "SP500": ".SPX", "GSPC": ".SPX",
  "DJI": ".DJI", "DJIA": ".DJI",
  "IXIC": ".IXIC", "NASDAQ": ".IXIC", "NDX": ".NDX",
  "RUT": ".RUT", "RUSSELL": ".RUT", "VIX": ".VIX",
  "BTC": "BTC.CM=", "BITCOIN": "BTC.CM=",
  "ETH": "ETH.CM=", "ETHEREUM": "ETH.CM=",
  "10Y": "US10Y", "2Y": "US2Y", "30Y": "US30Y"
}

// Uppercase, strip what a symbol can never contain, then apply an alias.
// Anything already in CNBC's own spelling passes straight through.
function normalizeSymbol(raw) {
  if (raw === undefined || raw === null) return ""
  var s = String(raw).trim().toUpperCase()
  s = s.replace(/[^A-Z0-9.=&/^-]/g, "")
  if (s === "") return ""
  // Look the alias up without whichever index marker was typed, so "^GSPC",
  // ".SPX" and "spx" all land on the same symbol.
  var bare = s.replace(/^[\^.]/, "")
  if (ALIASES.hasOwnProperty(bare)) return ALIASES[bare]
  if (ALIASES.hasOwnProperty(s)) return ALIASES[s]
  return s.replace(/^\^/, ".")
}

// -------------------------------------------------------------- numbers

// CNBC formats for display, not for arithmetic: thousands separators, a
// leading sign, a trailing percent, and the literal "UNCH" when a thing has
// not moved. All of that has to come back off before anything can be compared.
function toNumber(value) {
  if (value === undefined || value === null) return NaN
  var s = String(value).replace(/,/g, "").replace(/%/g, "").trim()
  if (s === "" || s === "UNCH" || s === "N/A" || s === "--") return NaN
  var n = Number(s)
  return isFinite(n) ? n : NaN
}

// A signed percentage, always with its sign and always to two places, so a
// column of them lines up on the decimal point.
function formatPct(n) {
  if (!isFinite(n)) return "--"
  var sign = n > 0 ? "+" : (n < 0 ? "-" : "")
  return sign + Math.abs(n).toFixed(2) + "%"
}

function formatSigned(n, places) {
  if (!isFinite(n)) return "--"
  var p = places === undefined ? 2 : places
  var sign = n > 0 ? "+" : (n < 0 ? "-" : "")
  return sign + Math.abs(n).toFixed(p)
}

// ---------------------------------------------------------- company names

// Legal suffixes are noise in a two-column list and, more to the point, they
// stop a headline that says "Apple" from matching a quote called "Apple Inc.".
var NAME_NOISE = /\s*(,)?\s*\b(incorporated|inc|corporation|corp|company|co|holdings|holding|group|limited|ltd|plc|sa|nv|ag|se|the|class\s+[a-c]|common\s+stock|ordinary\s+shares|depositary\s+shares)\b\.?/gi

function shortCompanyName(name) {
  if (!name) return ""
  var s = String(name).replace(NAME_NOISE, " ")
  s = s.replace(/\s+/g, " ").replace(/[\s,.-]+$/, "").trim()
  return s === "" ? String(name).trim() : s
}

// ---------------------------------------------------------------- quotes

// One CNBC quote, flattened. `code` is non-zero when the service does not
// recognise the symbol, which is the only signal we get that a ticker someone
// typed does not exist.
function parseQuote(q) {
  if (!q || !q.symbol) return null
  var symbol = normalizeSymbol(q.symbol)
  if (q.code !== undefined && q.code !== 0) {
    return { symbol: symbol, valid: false, name: symbol, brand: symbol,
             last: "--", change: "--", changePct: "--", pct: NaN, delta: NaN,
             up: false, down: false, flat: true }
  }

  var pct = toNumber(q.change_pct)
  var delta = toNumber(q.change)
  // `changetype` is the service's own verdict and is right even when the
  // formatted change reads "UNCH", so it wins over the parsed number.
  var type = String(q.changetype || "").toUpperCase()
  var up = type === "UP" || (!isFinite(delta) ? false : delta > 0)
  var down = type === "DOWN" || (!isFinite(delta) ? false : delta < 0)

  var ext = q.ExtendedMktQuote || null
  var extType = ext ? String(ext.type || "").toUpperCase() : ""

  return {
    symbol: symbol,
    valid: true,
    name: q.name || symbol,
    brand: shortCompanyName(q.name || symbol),
    shortName: q.shortName || symbol,
    last: q.last || "--",
    change: isFinite(delta) ? formatSigned(delta, decimalsOf(q.change)) : "0.00",
    changePct: isFinite(pct) ? formatPct(pct) : "0.00%",
    pct: isFinite(pct) ? pct : 0,
    delta: isFinite(delta) ? delta : 0,
    up: up && !down,
    down: down && !up,
    flat: !up && !down,
    open: q.open || "",
    high: q.high || "",
    low: q.low || "",
    prevClose: q.previous_day_closing || "",
    volume: q.volume_alt || q.volume || "",
    marketCap: q.mktcapView || "",
    pe: q.pe || "",
    yearHigh: q.yrhiprice || "",
    yearLow: q.yrloprice || "",
    dividendYield: q.dividendyield || "",
    currency: q.currencyCode || "",
    exchange: q.exchange || "",
    isIndex: symbol.charAt(0) === "." || symbol.indexOf("US") === 0,
    marketStatus: String(q.curmktstatus || "").toUpperCase(),
    lastTime: q.last_timedate || "",
    extendedLabel: extType === "PRE_MKT" ? "Pre" : (extType === "AFT_MKT" ? "After" : ""),
    extendedLast: ext ? (ext.last || "") : "",
    extendedPct: ext ? (ext.change_pct || "") : "",
    extendedUp: ext ? String(ext.changetype || "").toUpperCase() === "UP" : false,
    extendedDown: ext ? String(ext.changetype || "").toUpperCase() === "DOWN" : false
  }
}

// Match the source's own precision rather than forcing two places: index
// changes come through as "-267.606" and rounding them looks like an error.
function decimalsOf(formatted) {
  var s = String(formatted === undefined || formatted === null ? "" : formatted)
  var dot = s.indexOf(".")
  if (dot < 0) return 2
  return Math.min(4, s.length - dot - 1)
}

// The whole response, keyed by symbol. CNBC collapses a single result to a
// bare object rather than a one-element array.
function parseQuotes(text) {
  var map = {}
  var data = null
  try { data = JSON.parse(text) } catch (e) { return map }
  var result = data ? data.FormattedQuoteResult : null
  var list = result ? result.FormattedQuote : null
  if (!list) return map
  if (!Array.isArray(list)) list = [list]
  for (var i = 0; i < list.length; i++) {
    var quote = parseQuote(list[i])
    if (quote) map[quote.symbol] = quote
  }
  return map
}

// The one status line the panel shows. Indexes carry it too, so any quote
// will do, but a stock's is the one that matches what people expect.
function marketStatusLabel(status) {
  switch (String(status || "").toUpperCase()) {
    case "REG_MKT": return "Market open"
    case "PRE_MKT": return "Pre-market"
    case "AFT_MKT": return "After hours"
    case "CLOSED_MKT": return "Market closed"
    default: return ""
  }
}

// ------------------------------------------------------------------- rss

var ENTITIES = {
  "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
  "nbsp": " ", "#39": "'", "#8217": "’", "#8216": "‘",
  "#8220": "“", "#8221": "”", "#8211": "–", "#8212": "—"
}

// Feeds arrive double-escaped often enough that one pass is not enough:
// "&amp;#39;" is common in Google's titles.
function decodeEntities(text) {
  if (!text) return ""
  var out = String(text)
  for (var pass = 0; pass < 2; pass++) {
    out = out.replace(/&(#?[a-z0-9]+);/gi, function(whole, name) {
      var key = name.toLowerCase()
      if (ENTITIES.hasOwnProperty(key)) return ENTITIES[key]
      if (key.charAt(0) === "#") {
        var code = key.charAt(1) === "x" ? parseInt(key.slice(2), 16)
                                         : parseInt(key.slice(1), 10)
        if (isFinite(code) && code > 0) return String.fromCharCode(code)
      }
      return whole
    })
  }
  return out
}

function stripTags(text) {
  return String(text === undefined || text === null ? "" : text).replace(/<[^>]*>/g, "")
}

function tagText(item, tag) {
  var match = item.match(new RegExp("<" + tag + "[^>]*>([\\s\\S]*?)</" + tag + ">", "i"))
  if (!match) return ""
  var body = match[1]
  var cdata = body.match(/^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/)
  if (cdata) body = cdata[1]
  return decodeEntities(stripTags(body)).replace(/\s+/g, " ").trim()
}

// Google News hangs the outlet off the end of every title as " - Outlet".
// Splitting it off gives us a byline and stops the same words being repeated
// in the row.
function splitSource(title, fallback) {
  var text = String(title || "")
  var cut = text.lastIndexOf(" - ")
  if (cut > 20 && text.length - cut < 40) {
    return { title: text.slice(0, cut).trim(), source: text.slice(cut + 3).trim() }
  }
  return { title: text.trim(), source: fallback || "" }
}

// `fallbackSource` names the outlet for feeds that do not tag their items
// with one. CNBC and MarketWatch both omit <source> -- everything in the feed
// is theirs -- so without it those rows would carry a timestamp and nothing
// else, while the Google-sourced rows beside them name an outlet.
function parseRss(xml, limit, fallbackSource) {
  var items = []
  if (!xml) return items
  var max = limit === undefined ? 40 : limit
  var blocks = String(xml).split(/<item[\s>]/i)
  for (var i = 1; i < blocks.length && items.length < max; i++) {
    var raw = blocks[i]
    var end = raw.search(/<\/item>/i)
    if (end >= 0) raw = raw.slice(0, end)

    var title = tagText(raw, "title")
    if (!title) continue
    var linkMatch = raw.match(/<link[^>]*>([\s\S]*?)<\/link>/i)
    var link = linkMatch ? decodeEntities(linkMatch[1]).trim() : ""
    var sourceMatch = raw.match(/<source[^>]*>([\s\S]*?)<\/source>/i)
    var feedSource = sourceMatch ? decodeEntities(stripTags(sourceMatch[1])).trim() : ""
    var split = splitSource(title, feedSource || fallbackSource || "")
    var published = tagText(raw, "pubDate")

    var descMatch = raw.match(/<description[^>]*>([\s\S]*?)<\/description>/i)
    var descRaw = descMatch ? descMatch[1] : ""
    var descCdata = descRaw.match(/^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/)
    if (descCdata) descRaw = descCdata[1]
    var detail = articleDetail(descRaw)

    items.push({
      title: split.title,
      source: split.source,
      link: link,
      published: published,
      timestamp: parseDate(published),
      summary: detail.summary,
      // Google's list leads with the story the headline already names, so it
      // would otherwise be shown twice.
      related: detail.related.filter(function(other) {
        return other.title !== split.title
      }),
      hasDetail: detail.summary !== ""
                 || detail.related.filter(function(other) {
                      return other.title !== split.title
                    }).length > 0
    })
  }
  return items
}

// RFC-822 dates, which Date can already read; NaN rather than a wrong guess
// when it cannot, so the caller can fall back to feed order.
// What a feed offers beyond the headline, which differs by feed and is worth
// taking as it comes rather than forcing into one shape:
//
//   MarketWatch puts a one-sentence summary in <description>.
//   Google News puts an <ol> of the same story from other outlets there.
//
// Both are already in the response, so showing either costs no extra request.
function articleDetail(raw) {
  var decoded = decodeEntities(String(raw || ""))
  var related = []

  var anchor = /<a[^>]*>([\s\S]*?)<\/a>\s*(?:<font[^>]*>([\s\S]*?)<\/font>)?/gi
  var match
  while ((match = anchor.exec(decoded)) !== null) {
    var title = decodeEntities(stripTags(match[1])).replace(/\s+/g, " ").trim()
    if (title === "") continue
    related.push({
      title: title,
      source: decodeEntities(stripTags(match[2] || "")).replace(/\s+/g, " ").trim()
    })
  }
  if (related.length > 0) return { summary: "", related: related }

  var text = decodeEntities(stripTags(decoded)).replace(/\s+/g, " ").trim()
  return { summary: text, related: [] }
}

function parseDate(text) {
  if (!text) return NaN
  var t = Date.parse(text)
  return isFinite(t) ? t : NaN
}

// "3m", "5h", "Tue", "12 Aug" -- the resolution people actually want, which
// gets coarser the further back the story is.
var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function relativeTime(timestamp, now) {
  if (!isFinite(timestamp)) return ""
  var then = new Date(timestamp)
  var elapsed = (now === undefined ? Date.now() : now) - timestamp
  if (elapsed < 0) elapsed = 0
  var minutes = Math.floor(elapsed / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 7) return DAY_NAMES[then.getDay()]
  return then.getDate() + " " + MONTH_NAMES[then.getMonth()]
}

// ------------------------------------------------------------ news filters

// Keep only what ran today, in local time. "Today" has to mean the reader's
// day, not UTC's: a story filed at 21:00 Pacific is still today's news to the
// person reading it, and a UTC comparison would have already moved on.
//
// Items with an unparseable date are kept rather than dropped -- a feed with
// a malformed pubDate should degrade to showing too much, not to showing
// nothing at all.
function filterToday(items, now) {
  var reference = new Date(now === undefined ? Date.now() : now)
  var y = reference.getFullYear(), m = reference.getMonth(), d = reference.getDate()
  var out = []
  for (var i = 0; i < items.length; i++) {
    var stamp = items[i].timestamp
    if (!isFinite(stamp)) { out.push(items[i]); continue }
    var when = new Date(stamp)
    if (when.getFullYear() === y && when.getMonth() === m && when.getDate() === d)
      out.push(items[i])
  }
  return out
}

// ------------------------------------------------------------- watchlist

// Accepts what the panel writes, what someone might type by hand, and the
// object form in case a future version needs somewhere to hang settings.
function parseWatchlist(text, fallback) {
  if (!text || !String(text).trim()) return (fallback || []).slice()
  var data = null
  try { data = JSON.parse(text) } catch (e) { return (fallback || []).slice() }
  var list = Array.isArray(data) ? data
           : (data && Array.isArray(data.tickers) ? data.tickers : null)
  if (!list) return (fallback || []).slice()
  return dedupe(list.map(normalizeSymbol).filter(function(s) { return s !== "" }))
}

function serializeWatchlist(list) {
  return JSON.stringify(dedupe(list || []), null, 2) + "\n"
}

function dedupe(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (!s || seen[s]) continue
    seen[s] = true
    out.push(s)
  }
  return out
}

// The quote request is one call for everything on screen: indexes first so
// they are always present even when the watchlist is empty.
function quoteUrl(symbols) {
  var joined = dedupe(symbols || []).join("|")
  return "https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol"
       + "?symbols=" + encodeURIComponent(joined)
       + "&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json"
}

// MarketWatch's top stories, which is where market news comes from. CNBC's
// feeds were tried first and are the wrong shape for a today-only section:
// their "Investing" feed carried exactly one item from today, "Finance" four.
// This one runs ten stories and all ten were filed today, so filtering to the
// current day leaves a full section rather than an empty one.
var MARKET_NEWS_URL = "https://feeds.content.dowjones.io/public/rss/mw_topstories"
var MARKET_NEWS_SOURCE = "MarketWatch"

// Google News' Business section, verbatim -- the whole front page of it,
// newest first, no per-company filtering.
var BUSINESS_NEWS_URL =
  "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=en-US&gl=US&ceid=US:en"

// ------------------------------------------------------------ symbol search

// Nasdaq's autocomplete. It answers on partial symbols and on company names,
// needs no key, and caps out around thirty results however many you ask for.
function searchUrl(query) {
  return "https://api.nasdaq.com/api/autocomplete/slookup/50?search="
       + encodeURIComponent(String(query || "").trim())
}

// Nasdaq returns its matches in roughly alphabetical order and truncates,
// which buries the obvious answer: searching "appl" puts a mutual fund called
// ZAPPLX above Apple, and four other "Applied ..." companies above it too. So
// the list is re-ranked here. Lower score sorts first.
var ASSET_RANK = { "STOCKS": 0, "ETF": 1, "INDEX": 1, "MUTUALFUNDS": 3 }

function scoreMatch(symbol, name, asset, query) {
  var score = (ASSET_RANK.hasOwnProperty(asset) ? ASSET_RANK[asset] : 2) * 100

  if (symbol === query) {
    // Typing a symbol exactly should surface it, but not so forcefully that a
    // leveraged ETF named TESL outranks Tesla for "tesl".
    score -= 150
  } else if (symbol.indexOf(query) === 0) {
    score -= 100
  } else {
    var firstWord = name.split(/[\s,.]+/)[0] || ""
    if (firstWord.indexOf(query) === 0) {
      // How much of the company's first word the query covers. "APPL" is most
      // of "APPLE" but little of "APPLIED", and that difference is the whole
      // reason Apple beats Applied Industrial Technologies here.
      score -= 60 + Math.round(40 * (query.length / Math.max(1, firstWord.length)))
    } else if (name.indexOf(query) === 0) {
      score -= 60
    } else if (name.indexOf(query) >= 0) {
      score -= 30
    } else {
      score += 50
    }
  }

  // Ties go to the shorter symbol: the primary listing is almost always the
  // short one, and the long ones are warrants, units and share classes.
  return score + symbol.length
}

// Split into "normalize the rows" and "rank them for a query" so a result set
// can be re-ranked against a longer query without going back to the network.
// Nasdaq's autocomplete answers in one and a half to three seconds, which is
// far too slow to sit behind every keystroke; narrowing a cached superset
// locally is what makes the picker feel immediate after the first reply.
function parseSearchRows(text) {
  var data = null
  try { data = JSON.parse(text) } catch (e) { return [] }
  var rows = data && data.data ? data.data : null
  if (!rows || !rows.length) return []

  var out = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || !row.symbol) continue
    var name = String(row.name || "")
    out.push({
      symbol: String(row.symbol).toUpperCase(),
      name: shortCompanyName(name),
      rawName: name.toUpperCase(),
      asset: row.asset || "",
      exchange: row.exchange || ""
    })
  }
  return out
}

// Does this row still answer a longer query than the one it was fetched for?
function rowMatches(row, query) {
  if (!row) return false
  return row.symbol.indexOf(query) >= 0 || row.rawName.indexOf(query) >= 0
}

function rankRows(rows, query, limit) {
  var max = limit === undefined ? 6 : limit
  var wanted = String(query || "").trim().toUpperCase()
  if (wanted === "" || !rows) return []

  var scored = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!rowMatches(row, wanted)) continue
    scored.push({
      symbol: row.symbol,
      name: row.name,
      asset: row.asset,
      exchange: row.exchange,
      score: scoreMatch(row.symbol, row.rawName, row.asset, wanted)
    })
  }
  scored.sort(function(a, b) { return a.score - b.score || (a.symbol < b.symbol ? -1 : 1) })
  return scored.slice(0, max)
}

function parseSearch(text, query, limit) {
  return rankRows(parseSearchRows(text), query, limit)
}

// ------------------------------------------------------- symbol index

// Nasdaq's autocomplete costs one and a half to three seconds per query, and
// measuring it shows the time is all server: connection setup is around 50ms
// and time-to-first-byte is the rest. Nothing local fixes that, so the search
// does not use it. The same exchange publishes its whole symbol directory as
// two static files that together download in well under a second, and ranking
// 13,000 rows of it locally costs about a millisecond -- so the files are the
// search, and the autocomplete stays only as a fallback for what they omit
// (crypto, indexes, treasuries, OTC and foreign listings).
//
// Both files are pipe-delimited, carry a header row and a "File Creation
// Time" trailer, and do not agree on column order -- hence a layout each.
var SYMBOL_DIRECTORIES = [
  { url: "https://www.nasdaqtrader.com/dynamic/symdir/nasdaqlisted.txt",
    symbol: 0, name: 1, etf: 6, test: 3 },
  { url: "https://www.nasdaqtrader.com/dynamic/symdir/otherlisted.txt",
    symbol: 0, name: 1, etf: 4, test: 6 }
]

// Nasdaq rebuilds these every trading day, but a week-old copy is wrong only
// about listings younger than a week, and those fall through to the
// autocomplete fallback anyway. Refreshing daily would buy nothing.
var SYMBOL_INDEX_MAX_AGE_DAYS = 7

// Rows come out in the shape parseSearchRows produces, so rankRows, scoreMatch
// and the picker cannot tell the two sources apart.
//
// `rawName` is the *short* name uppercased rather than the legal one. The
// directory files spell every row "... - Common Stock", and matching a query
// against that boilerplate means typing "common" ranks the entire exchange.
function parseSymbolDirectory(text, layout) {
  if (!text || !layout) return []
  var lines = String(text).split("\n")
  var out = []
  for (var i = 1; i < lines.length; i++) {
    var line = lines[i]
    if (line === "" || line.indexOf("File Creation Time") === 0) continue
    var f = line.split("|")
    if (f.length < 5) continue
    // Test issues are exchange plumbing, not securities anyone can hold.
    if (f[layout.test] === "Y") continue
    var symbol = String(f[layout.symbol] || "").trim().toUpperCase()
    var name = String(f[layout.name] || "").trim()
    if (symbol === "" || name === "") continue
    var short = shortCompanyName(name)
    out.push({
      symbol: symbol,
      name: short,
      rawName: short.toUpperCase(),
      asset: f[layout.etf] === "Y" ? "ETF" : "STOCKS",
      exchange: ""
    })
  }
  return out
}

// The cache is written as our own three-column TSV rather than the raw
// downloads: it is a third the size, needs no column layouts to read back,
// and re-parsing it on every shell start is a split rather than a scan.
var SYMBOL_INDEX_HEADER = "#pyang.finance symbol index v1"

function serializeSymbolIndex(rows, fetchedAtMs) {
  var lines = [SYMBOL_INDEX_HEADER, "#fetched " + Math.round(fetchedAtMs || 0)]
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    lines.push(r.symbol + "\t" + r.name + "\t" + r.asset)
  }
  return lines.join("\n") + "\n"
}

// Returns null for anything this version cannot read, which the panel treats
// as "no index yet" and refetches -- a cache from a future format should not
// be able to break the picker.
function parseSymbolIndex(text) {
  if (!text) return null
  var lines = String(text).split("\n")
  if (lines[0] !== SYMBOL_INDEX_HEADER) return null
  var fetchedAt = 0
  var rows = []
  for (var i = 1; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    if (line.indexOf("#fetched ") === 0) {
      fetchedAt = parseInt(line.slice(9), 10) || 0
      continue
    }
    if (line.charAt(0) === "#") continue
    var f = line.split("\t")
    if (f.length < 3) continue
    rows.push({
      symbol: f[0], name: f[1], rawName: f[1].toUpperCase(),
      asset: f[2], exchange: ""
    })
  }
  if (rows.length === 0) return null
  return { fetchedAt: fetchedAt, rows: rows }
}

function symbolIndexStale(fetchedAtMs, nowMs, maxAgeDays) {
  var days = maxAgeDays === undefined ? SYMBOL_INDEX_MAX_AGE_DAYS : maxAgeDays
  if (!fetchedAtMs) return true
  return (nowMs - fetchedAtMs) > days * 24 * 60 * 60 * 1000
}
