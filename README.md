# Markets

A finance panel for the [Omarchy](https://omarchy.org) shell bar, laid out the
way Google Finance lays out its front page: your watchlist down the left, and
on the right the indexes across the top with market news and then your own
companies' news beneath.

One watchlist, one JSON file, one request per refresh.

![The panel: watchlist, indexes, market news, business news](docs/panel.png)

## Install

```bash
omarchy plugin add https://github.com/Windswell284/omarchy-markets --enable
```

You will be asked which bar section to place it in. That gets you the bar
readout and the panel; **keys are a separate step** — see [Keybindings](#keybindings).

It installs under the id `pyang.finance` — that is the name to use in
`shell.json`, in `omarchy plugin` commands and in IPC calls.

```bash
omarchy plugin update pyang.finance     # pull later changes
omarchy plugin disable pyang.finance    # take it off the bar
```

## The watchlist

One list, kept as a plain JSON array at:

```
~/.config/omarchy/finance/watchlist.json
```

```json
[
  "AAPL",
  "MSFT",
  "NVDA"
]
```

It is deliberately **outside** the plugin directory. The plugin is a git
checkout, and a file that changes every time you add a ticker would leave it
permanently dirty. The file is watched, so editing it in a text editor and
editing it from the panel both work and stay in step. Point it somewhere else
with the `watchlistFile` setting if you like.

On a machine that has no watchlist yet, a starter list is written out on first
run, so the first thing you open is a file you can see and edit.

### Adding tickers

Press `a` in the panel (or click **+ add ticker**), then type either a symbol
or a company name. Matches appear above the field as you type — symbol on the
left, company on the right — and `Up`/`Down` then `Enter` takes one. Enter with
nothing highlighted uses exactly what you typed, so a symbol you already know
goes straight in without waiting for the search.

| How | |
| --- | --- |
| Press `a`, type, `Enter` | the usual way |
| Click **+ add ticker** | same field, for the mouse |
| `omarchy-shell pyang.finance add NVDA` | from a script or a key |
| Edit `watchlist.json` | for a bulk change |

Search runs **locally**, against every symbol listed on a US exchange. The
picker answers in about a millisecond, from the first letter, offline.

That is a deliberate move away from an autocomplete API. Nasdaq publishes one,
it needs no key, and it answers partial symbols and company names — but it
takes **1.5 to 3 seconds per query**, and measuring it shows the time is all
server: connection setup is about 50ms and time-to-first-byte is the rest.
Nothing local hides a delay like that behind a keystroke.

The same exchange also publishes its entire symbol directory as two static
files, and *those* are fast — together they download in well under a second,
which is less than one autocomplete query costs. So the files are the search:

```
~/.config/omarchy/finance/symbols.txt      13,000 symbols, ~560KB
```

Fetched on first use, refreshed weekly in the background, and kept as a
compact three-column cache. A stale copy still answers, so a refresh never
makes you wait and a failed one is invisible. Delete the file and it is
rebuilt.

The autocomplete is still there, as a **fallback** for anything the directory
does not list — crypto, indexes, treasuries, OTC and foreign names. That path
keeps the old behaviour: nothing is searched until the second character, every
result set is cached under the query that fetched it, and a longer query whose
prefix is cached is answered from it instantly.

The box always says which of those it is doing — "Keep typing…", "Searching…",
"No matches for X", or "Search unavailable" — because a picker that just sits
there empty is indistinguishable from a broken one.

Results are ranked here rather than taken in the order they arrive: real
companies above funds, a matched symbol above a matched name, and, among name
matches, whichever company's first word the query covers most of. That last
rule is what puts Apple above Applied Industrial Technologies for `appl`.

ETFs and mutual funds are kept in the list, because people hold them, but
badged — a 2x leveraged tracker named after a company is otherwise
indistinguishable from the company.

Two things that used to be limits are worth noting as gone. Nasdaq's
autocomplete caps its reply at about thirty matches and picks them
alphabetically, so `micro` did not find Microsoft — a local index has no cap,
and it does. It also returns mutual funds, which buried the obvious answer:
`appl` led with a fund called ZAPPLX. The directory files are exchange-listed
securities only, so that noise is simply absent.

Case does not matter, and a handful of names are understood as well as
symbols: `spx`, `nasdaq`, `djia`, `vix`, `russell`, `btc`, `eth`, `10y` and
friends all resolve to what CNBC calls them. `^GSPC` works too.

Note that **only spellings that are not themselves listed tickers** are
aliased. `DOW`, `COMP` and `GOLD` all look like index shorthand and are all
real companies — Dow Inc., Compass, Barrick Gold — so typing one gets you the
company, which is what the exchange says it means.

A symbol the quote service does not recognise is not silently dropped: the row
stays, marked "not found" in red, so a typo is visible rather than mysterious.
(That is also what a private company does — `SPACEX` has no listed ticker.)

## Keys

| Key | Does |
| --- | --- |
| `j` / `k`, `Up` / `Down` | Move within the current list |
| `Tab` / `Shift+Tab` | Next / previous list — watchlist, market news, business news |
| `o`, `Enter`, `Space` | Open what the cursor is on — a company's page, or a news row in place; again closes it |
| `1`…`7` | Pick the chart period, while a page is open |
| `Left` / `Right` | Cross the gutter between the watchlist and the news stack |
| `a` | Add a ticker |
| `d` | Remove the ticker under the cursor |
| `[` / `]` | Move the ticker under the cursor up / down the list |
| drag a row | Reorder with the mouse — a marker shows where it will land |
| `g` / `G` | First / last row of the current list |
| `b` | Open the story under the cursor in the browser |
| `r` | Refresh now |
| `Esc` | Close an open story or page, cancel the add field, or close the panel |

Lists with nothing in them are stepped over by `Tab` rather than landed on — an
empty news list that eats the keyboard reads as the panel having frozen.

Clicking a watchlist row opens its page; clicking a news row selects it.
Dragging a watchlist row reorders the list — the row fades, a marker shows the
gap it is going into, and the list is rewritten on the drop rather than under
the pointer. Middle-clicking a watchlist row removes it. Middle-clicking the
bar icon refreshes.

**The panel leaves the shell in exactly one place**: the third click on a
story, or `b`. Everything else stays put. Clicking a news row selects it,
clicking the selected row opens the preview, and clicking a row whose preview
is already open hands the story to your browser — each click one step further
in, so nothing throws you out by surprise. A row with no preview to show goes
straight out on the second click.

That escalation is the whole design. The full text of an article is not
reachable from a shell panel — see below — so rather than pretend, the panel
shows you enough to decide and then gets out of the way.

Reading in place comes first. A news row opens downward to show what
its feed already carried alongside the headline, which differs by feed and is
taken as it comes rather than forced into one shape:

- **Market news** shows MarketWatch's one-sentence summary of the story.
- **Business news** shows *Also reported by* — the same story from other
  outlets, with each one named. Google's feed carries that list in place of a
  summary, and it is arguably the more useful of the two: it tells you who
  else thought the story mattered.

An open row is a **preview**, deliberately: a summary capped at three lines,
or one line per related headline with its outlet beside it. Enough to tell
whether the story is worth opening, and no taller than a glance.

It is also all there is. Google News carries at most five related items per
story and no article body, and **the full text is not reachable from here**:
its links are interstitials that resolve to the publisher in the browser's
JavaScript, with no publisher URL anywhere in what a fetch returns, and
MarketWatch — the one feed whose links are direct — answers `401` to anything
but a browser. No mainstream finance feed ships `content:encoded` either. So
the full story is a click away in a real browser rather than a scraper's
approximation of one in a bar panel.

Both arrived with the item in the original fetch, so opening a story costs no
request and reaches nowhere. Press `o`, `Enter` or `Space` on the row, or
click a row that is already selected; `Esc` or the same key again closes it.
Moving the cursor closes it too — an open row belongs to what you are reading,
not to the list.

![A story opened in place, showing who else reported it](docs/story.png)

The only hint a row carries is a small chevron, shown on the row under the
cursor and on hover. One on every row would be a column of arrows down the
side of the panel, and rows whose feed gave nothing extra do not get one at
all.

Headline links are still parsed and kept with each story. Nothing acts on
them — they are there if you ever want a copy-link or an explicit open key.

## The quote page

Click a company in the watchlist — or press `o`, `Enter` or `Space` on it —
and the right-hand side becomes that company: the price and the day's move,
a chart, and the fundamentals underneath. `Esc` brings the news back.

```
 AAPL                                        325.95
 Apple                               +0.82   +0.25%

 [1D] 1M  6M  YTD  1Y  5Y  MAX       +1.14   +0.35%
 ╭──────────────────────────────────────╮       │
 │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│ 327.00
 │        the chart, with yesterday's   │       │
 │        close dashed across it on 1D  │ 325.00
 │                                      │       │
 ╰──────────────────────────────────────╯ 324.00
   5:00 AM   7:30 AM   10:00 AM  12:00 PM

 Open        326.87    Mkt cap             4.753T
 High        328.40    P/E                  37.48
 …
```

Hovering the chart reads a value off it: a crosshair, a dot on the point under
the pointer, and its price and time in a readout that follows along the top
and stops at the edges rather than hanging off them. On 1D that time is the
minute; on the longer periods it is the day.

Prices run down the right against their own gridlines, on round steps rather
than wherever the data happened to land, and times run along the bottom — the
clock on 1D, dates on the rest, and years once the span is long enough that
the day of the month is noise. Both come from the feed's own labels rather
than from its timestamps, because Nasdaq sends exchange wall-clock dressed as
an epoch: 4:00 AM ET arrives as 04:00 UTC, and converting it would slide every
intraday chart by the reader's own offset.

The index cards stay across the top throughout. What the broad market is
doing is context for reading one company, not a competing screen, and the
news stack is what gives way.

The number beside the periods is the move **across the period on screen**,
which is not the day's change in the header: 1D agrees with it and every
other period does not.

Moving the cursor deliberately does not follow. Each period is a one-to-three
second request, so a page that tracked `j`/`k` would fire one per keystroke
and show whichever came back last. The row whose page is open is marked
separately from the cursor, because the two come apart.

**Periods**: `1D`, `1M`, `6M`, `YTD`, `1Y`, `5Y`, `MAX`, on the number keys
in that order. There is no `5D`: the source serves 1D as minute bars and every
other range as daily ones, so a five-day chart would be five dots joined by
lines. Each period is fetched once and kept for the session; only 1D expires,
after a minute. `r` refetches whatever is on screen.

**Charts are fetched before they are asked for.** Resting on a row — with the
pointer or with the cursor — fetches that company's 1D chart in the
background, so the page opens with the chart already drawn instead of showing
"Loading chart…" for two seconds. It is one request after a third of a second
of rest, not one per keystroke, and a guess that does not pan out goes in the
cache and nowhere near the screen.

**The stats all came with the quote.** CNBC returns the whole fundamentals
block whether or not anyone asks for it, so the page costs one chart request
and nothing else. Fields the quote does not carry are dropped rather than
shown as dashes — an index has no P/E, and an ETF has no EPS.

## The bar

The bar carries a chart glyph and one index's change, colored up or down:

```
󰄨 -0.68%
```

Which index is the `barSymbol` setting, defaulting to the S&P 500. Set
`showBarChange` to `false` for the glyph on its own. On a vertical bar the
readout is dropped automatically and you get the glyph either way.

## Where the data comes from

Three feeds, none of which needs an API key:

| | Source |
| --- | --- |
| Quotes | CNBC's quote service |
| Charts | Nasdaq's chart API — intraday for 1D, daily bars for every other period |
| Symbol search | Nasdaq's symbol directory, downloaded and searched locally |
| Unlisted symbols | Nasdaq's autocomplete, as a fallback |
| Market news | MarketWatch top stories, filtered to today |
| Business news | Google News, Business section |

The quote service takes every symbol on screen — indexes, stocks, crypto,
treasuries — in a single pipe-joined request, so the whole panel costs one
round trip per refresh no matter how long the watchlist gets. It also returns
far more than the panel shows: the open/high/low/volume strip under the
watchlist is already in the response, and costs nothing extra.

Yahoo Finance and Stooq were both tried first and neither is usable any more —
Yahoo rate-limits anonymous requests to `429`, and Stooq now sits behind a
JavaScript proof-of-work challenge.

### Why MarketWatch for market news

Market news shows **today only**, which turns out to constrain the feed
choice more than it looks. CNBC's feeds were the obvious candidates and are
the wrong shape for it: on a normal weekday afternoon their "Investing" feed
carried exactly one story filed that day, and "Finance" four. Filtering either
to today empties the section.

MarketWatch's top stories runs ten, and on the same afternoon all ten were
filed that day, so the filter costs nothing and the section stays full. The
filter is still applied rather than trusted away, because a feed that goes
stale over a weekend should show an honest "No market news yet today" rather
than Friday's headlines dressed up as the morning's.

"Today" means the reader's local day. A story filed at 21:00 Pacific is still
today's news to the person reading it, where a UTC comparison would already
have rolled over.

Set `marketNewsTodayOnly` to `false` to see the whole feed regardless of age.

### Business news

Google News' Business section, verbatim and newest first — the same front page
you would get by opening the section yourself, with the outlet named on each
row. It is not filtered against your watchlist: it is general business news,
and the watchlist has the whole left column to itself.

## Settings

All optional, all per-entry in `~/.config/omarchy/shell.json`. Find the
`pyang.finance` entry in the bar layout and add what you want:

```json
{
  "id": "pyang.finance",
  "barSymbol": ".DJI",
  "indexes": [".SPX", ".DJI", ".IXIC", "US10Y"],
  "refreshIntervalSec": 20
}
```

| Key | Default | |
| --- | --- | --- |
| `barSymbol` | `.SPX` | Which index the bar reads out |
| `showBarChange` | `true` | Whether the bar shows it at all |
| `indexes` | `.SPX`, `.DJI`, `.IXIC` | The cards across the top |
| `refreshIntervalSec` | `30` | Quote poll while the panel is open |
| `newsIntervalSec` | `600` | News poll |
| `watchlistFile` | `~/.config/omarchy/finance/watchlist.json` | |
| `symbolIndexFile` | `~/.config/omarchy/finance/symbols.txt` | The local search index |
| `symbolIndexMaxAgeDays` | `7` | How old the index may get before a refresh |
| `marketNewsUrl` | MarketWatch top stories | Any RSS feed |
| `businessNewsUrl` | Google News Business | Any RSS feed |
| `marketNewsTodayOnly` | `true` | Drop market stories not filed today |
| `defaultTickers` | AAPL, MSFT, NVDA, GOOGL, AMZN | Seeded on first run only |
| `textScale` | `1.25` | Panel text size, 0.6–2.5 |
| `upColor` / `downColor` | `#3fb950` / `#f85149` | |

`shell.json` hot-reloads on save, so settings apply immediately.

### About the colors

Up and down are the one place this panel does not follow the theme. A red loss
and a green gain are what the numbers *mean*, not decoration, and every other
finance surface a person reads uses them. Both are settings for anyone who
disagrees or cannot distinguish them.

## How often it asks

Quotes poll every 30 seconds while the panel is open and at most once a minute
while it is shut, back off to five minutes once the market has closed, and
back off exponentially after a failed request. News is fetched lazily — a panel
you never open does not pull two RSS feeds all day — and then every ten
minutes while it is on screen. The symbol index is lazier still: it is read
from disk the first time the panel opens, and re-downloaded only when it is
more than a week old. A chart is fetched when a period is first opened — or a little before, when
resting on a row gives it away — and then kept: only the intraday one goes
stale, after a minute. Reopening the panel on a page it was left on re-asks,
which the cache answers unless that minute has passed.

## Keybindings

**`omarchy plugin add` does not set up keys.** It places the widget in the bar
and stops there: the plugin manifest has no way to declare a binding, and
nothing in the install path touches Hyprland. So after installing, the bar
icon works and every key inside the panel works, but nothing summons it.

```bash
cd ~/.config/omarchy/plugins/pyang.finance
./install-bindings           # SUPER+Y
./install-bindings --remove  # take it out again
```

It backs `bindings.lua` up first, refuses rather than double-binding if the key
is already spoken for, and reloads Hyprland, failing loudly if the reload
reports a config error. Running it twice is a no-op.

Or add it yourself, to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Y", "Markets", "omarchy-shell pyang.finance toggle")
```

IPC methods, for binding to keys: `open`, `close`, `toggle`, `refresh`,
`add <symbol>`, `remove <symbol>`, `page <symbol>`, `period <1D|1M|6M|YTD|1Y|5Y|MAX>`
— e.g.

```bash
omarchy-shell pyang.finance add NVDA
omarchy-shell pyang.finance page NVDA     # straight to one company
```

`page` takes any symbol, not only one on the watchlist.

## Hacking on it

`Panel.qml` is the whole widget — bar readout, panel, all three lists, keys.
`Model.js` is the parsing, ranking and formatting: quote JSON in, RSS in,
search JSON in, flat objects out. `fetch-feed` is the transport, and exists for one reason worth knowing
before you try to remove it:

> **CNBC serves `403` to curl's default User-Agent**, on both the quote service
> and the RSS feeds. A browser User-Agent works; an empty one currently does
> too. Qt's QML `XMLHttpRequest` refuses to let a caller set `User-Agent` at
> all, which is why the panel shells out instead of fetching in-process.

`Model.js` is plain JavaScript with one QML-only line at the top, so it can be
exercised directly:

```bash
node -e 'const s=require("fs").readFileSync("Model.js","utf8").replace(/^\.pragma library\s*$/m,"");
         const M={}; new Function("x", s+"\nObject.assign(x,{parseQuotes,normalizeSymbol})")(M);
         console.log(M.normalizeSymbol("^gspc"))'
```

Two things that will otherwise waste your afternoon:

- **Run `omarchy restart shell` after editing the QML.** Saving logs
  `Local plugin changed, reloading` but does not rebuild an already-running
  widget, so your change appears not to have taken effect.
- **Inline components (`component Foo: Item {}`) cannot see this file's ids.**
  They get their own scope, so every `root.` reference inside one fails to
  resolve. The shared news row is a `Component` for exactly that reason.

## Requires

Omarchy 4.x with the Quickshell-based `omarchy-shell`, and `curl`. Both are
already on any Omarchy system.

## License

MIT — see [LICENSE](LICENSE).
