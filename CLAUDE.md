# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This App Is

**Dhan LTP Viewer** — a Flutter trading app for Indian NSE markets that integrates with the [Dhan broker API](https://dhanhq.co/docs/v2/). It provides real-time watchlist monitoring (WebSocket + REST), paper trading simulation, a live strategy automation engine, backtesting, and candlestick charts.

---

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run on connected device/emulator
flutter run -d <id>      # Run on specific device
flutter analyze          # Static analysis / lint
flutter test             # All tests
flutter test test/widget_test.dart   # Single test file
flutter build apk        # Debug APK
flutter build apk --release          # Release APK
flutter pub run flutter_native_splash:create  # Regenerate splash screen
```

---

## Architecture Overview

```
lib/
  main.dart               # App entry point, global navigatorKey
  data/
    nifty500_stocks.dart  # Static Nifty 500 symbol list
  models/                 # Pure data classes (fromJson/toJson)
  screens/                # UI — one file per screen
  services/               # Business logic and API
  strategies/             # Strategy plugin system
  widgets/                # Reusable widgets (SwipeConfirmWidget)
```

### Entry & Navigation

`main.dart` initialises `AppLogger`, `StrategyRegistry`, `StrategyBackgroundService`, and `StrategyReminderService` before the app launches. A global `navigatorKey` allows background isolates and notification taps to push routes from outside the widget tree.

Route logic: if saved credentials exist → `LtpScreen`; otherwise → `TokenEntryScreen`.

Theme toggle is done via `MyApp.of(context).toggleTheme()` (propagates from root `_MyAppState`).

---

### Services

| Service | Role |
|---|---|
| `DhanService` | REST wrapper — OHLC/LTP polling, historical candles, holdings, funds |
| `DhanAuthService` | Mints a fresh access token from Client ID + PIN + TOTP via `POST https://auth.dhan.co/app/generateAccessToken` (params as query string). Used by `TokenEntryScreen`'s "Generate token" mode so the user doesn't have to copy a token from the Dhan portal. Requires TOTP enabled on the account |
| `DhanFeedService` | WebSocket live feed — binary protocol, little-endian, codes 2/4/6 |
| `StrategyEngine` | Full trading workflow runner; lives in background isolate |
| `StrategyBackgroundService` | Manages `flutter_background_service` isolate; exposes streams to UI |
| `PaperTradingService` | **Singleton** — paper portfolio state (positions, trades, balance) |
| `StorageService` | All app-state persistence via `SharedPreferences` (paper, strategy, watchlists, credentials) |
| `CandleRepository` | **Singleton** — SQLite-backed candle cache (`candle_cache.db`). Intraday (`bulkFetch`) and **daily** (`bulkFetchDaily`, interval `1day`, `expiryCode=0`, IST-dated) ranges, cache-first. All parse/merge boundaries pass through `CandleSanitizer` |
| `CandleSanitizer` | Single choke point for candle quality — dedupe-by-timestamp (first wins, matching the SQLite PK) + OHLC validity + sort. Every API parse and cache+fetch merge calls it, so strategies can assume unique/valid/sorted bars. Fixed real data-quality bugs (Dhan duplicate bars corrupting next-bar entry & exit walks) |
| `ScripService` | Instrument master — fetches from Dhan API, caches to file. Loud diagnostics on failure (an empty master cripples watchlist/search/universe) |
| `RateLimiter` | **Singleton** — sliding-window rate limiter; must be called before every API request |
| `BacktestEngine` | Generic backtest runner. **Chunked sliding-window**: processes ~28-day calendar chunks (pre-roll = strategy history) — fetch chunk → simulate days → free memory → next. Same per-day view as a whole-range load, so results are identical; bounded memory for multi-year runs. Streams live running totals to the progress UI. Delegates to the strategy for `hasCustomEngine` types |
| `AppLogger` | File-based logger (`app_log.txt` in app docs dir); must call `AppLogger.init()` in each isolate separately |
| `RunLogger` | Per-run structured logger — writes JSONL + `.meta.json` files under `{appDocs}/strategy_logs/`; one file per live engine run AND per backtest. Survives `app_log.txt` rolling. `RunLogger.cleanup(retentionDays:)` runs on app start |
| `StrategyReminderService` | Local notifications (`flutter_local_notifications`) for strategy reminders |

### Rate Limiting — Critical Rule

**Every API call must be gated by `RateLimiter.instance.acquire(category)` before executing.** This is not optional — the Dhan API will ban the access token on repeated limit violations.

```dart
await RateLimiter.instance.acquire(ApiCategory.quote);  // market feed endpoints (1 req/sec)
await RateLimiter.instance.acquire(ApiCategory.data);   // chart endpoints (5 req/sec, 100k/day)
```

---

### Strategy System

`StrategyRegistry` (`strategies/strategy_registry.dart`) maps type strings to factories. Two strategies are registered:
- **`dominance_breakout`** — `DominanceBreakoutStrategy`, the original C# port. 8-rule dominance candle 9:35–10:00, LTP breakout above the dominance high, fixed ₹ risk/target.
- **`hammer_dominance_s1`** — `HammerDominanceStrategy`, the focus of recent work (see below).

`StrategyConfigScreen` auto-generates its parameter form from `BaseStrategy.paramDefinitions` — no manual form code when adding params. The backtest config screen overlays a saved config's params on top of the strategy's current `defaultParams`, so **editing a default in code only affects NEW configs** — change an existing card's value via Edit, or delete + re-add it.

#### Two engine shapes (`BaseStrategy.hasCustomEngine`)

`BaseStrategy` has the legacy 4-method interface (`prepare`/`scan`/`checkBreakout`/`checkExit`) used by the dominance pipeline, AND an optional **self-contained-engine** path for strategies whose shape doesn't fit it:

- `hasCustomEngine == false` (dominance): the built-in engine drives everything. The live `StrategyEngine` only uses `scan()` + its own inline pre-market/LTP-poll/exit loop; the backtest engine runs its inline `_simulateDay`.
- `hasCustomEngine == true` (hammer, future strategies): the engines delegate to `prepareBacktest()` / `backtestDay()` / `runLive()`, passing a context façade (`strategies/strategy_engine_context.dart`: `BacktestPrepContext` / `BacktestDayContext` / `LiveEngineContext`). The strategy owns its full screening, entry, exit and logging; the engines stay strategy-agnostic. **A new self-contained strategy = new class (set `hasCustomEngine`, implement the 3 hooks) + one registry line. Zero engine edits.**

#### `HammerDominanceStrategy` (`hammer_dominance_s1`)

Port of the C# "Hammer/Dominance (Long) — S1" preset, then **tuned in-app** with offline mining. *The level is the edge; the candle is the trigger; the break is the proof.* A hammer or green-dominance candle probes an Indian intraday support level — CPR/vCPR, floor pivots P/S2 (S1-pivot & PDH excluded as mined losers), PDL/PDC, Camarilla L3, round numbers, 60-day reactive-swing zones, and **rising daily trendlines projected to today** (`computeTrendlines`, price×time) — closes back above it, and the *next* candle must break the trigger's high (buy-stop fill). 09:30–12:00 IST. Needs daily candles (support levels; look-ahead-safe — prior days only).

In-app tuning vs the C# defaults (each split-validated train/test; 1-year Nifty-500 in-sample ₹14.9k → ₹47.3k, ~3.2×):
- **Exit** (`trailActivateR` 1.0→**2.5**, `trailGapR` 1.0→**0.75**): the 1R/1R trail locked breakeven too early and choked winners; grid-search found an interior optimum that lets winners run, then protects tight. ~2× alone. (Set 1.0/1.0 for C#-parity.)
- **Gap filter** (`gapRejectLowPct` 0.3 / `gapRejectHighPct` 1.0 → `gapRejected()`): skips the "weak gap-up" day band (open +0.3–1.0% vs prior close) — a single cohort that lost −₹17k at 30% win while flat/gap-down/big-gap days won.
- `maxRangeMultVsPrevDay` defaults **0** (C# configures 4.0 but never executes it — a C# bug; validated C# results ran with it inert).

Per-trade **mining payload** is logged on every backtest trade (`Trade` tag in the run JSONL): pattern, matched levels, confluence, support distance, stop %, gap %, exit kind (stop/trail/target/time), **MFE/MAE in R**, and volume/day-type context (rel-vol prior-6, rel-vol day, 20-day avg vol, CPR width). This is what the exit/filter tuning was mined from — an offline simulator (`node:sqlite` over `candle_cache.db` + the JSONL) replays exit variants and reproduces the live engine within ₹2/trade.

> The fixed-target **S2** variant was removed (registry-only; the class machinery was collapsed to S1). Re-add by reintroducing a variant + registry line.

---

### Strategy Engine Execution Flow

The engine **runs in a background isolate via `flutter_background_service`** as a foreground service (Android notification channel `strategy_service`). It uses **REST APIs only** — no WebSocket inside the isolate (the Dhan WebSocket only allows one connection per token, which is reserved for the main isolate's live watchlist feed).

```
StrategyBackgroundService.start()
  └─ spawns Flutter background isolate
       └─ creates StrategyEngine(config, onUpdate callback)
            └─ engine.run():
                 1. _loadInstruments()      — ScripService + Nifty 500 IDs
                 2. _loadPreMarketData()    — historical 5-min candles → CandleStatsModel
                 3. _runProgressiveScreening() — fetch candles every 5 min, volume filter,
                                                 dominance screen from 9:35, then _monitorBreakouts()
                 4. _monitorOpenPositions() — REST LTP poll every 3s until 3:15 PM (square-off)
                 5. _saveTrades() + _saveDailyRunSummary()
```

`_monitorBreakouts()` runs in **two phases** after each slot's scan:

1. **Phase 0 — partial-bar pre-check.** For each newly-detected (and still-active) signal, re-fetch the stock's intraday data, find the dominance candle by OHLC fingerprint, and inspect every bar that came *after* it. If any post-dominance bar's high already exceeds the entry price, enter immediately. This phase exists because the slot's fetch loop typically takes 2–3 min under the 5 req/sec rate limit on ~350 stocks — by the time the LTP poll starts, the bar after dominance has been forming for those minutes and any breakout in that window is already encoded in its current high. Without this, live missed every breakout that happened during the fetch delay (the backtest's "if bar high > entry, fill" semantics caught them effortlessly).
2. **Phase 1 — continuous LTP poll loop.** For any signal still pending, loop calling `_fetchLtpBatch()` until every signal has entered, expired, or `maxTradesPerDay` is hit. The `RateLimiter` on `ApiCategory.quote` (1 req/sec) throttles the loop naturally — no explicit `Future.delayed` needed. Previously this was a single LTP snapshot per slot, which missed any breakout that happened between two slot ticks.

`StrategyBackgroundService` keeps a main-isolate buffer of recent activity (`_activityBuffer`, max 300) and a `StrategySessionState` snapshot, both persisted to `SharedPreferences` (`strategy_activity_buffer_v1`, `strategy_session_state_v1`) on a debounced 500 ms flush. This allows the UI to recover full state if the main isolate gets killed while the background service keeps running.

`StrategyDashboardScreen` seeds itself from `StrategyBackgroundService.sessionFor(configId)` and `activityFor(configId)`, then subscribes to `activityStream` for live updates. Call `flushNow()` on `AppLifecycleState.paused` to avoid losing in-flight events on swipe-away.

---

### Paper Trading

`PaperTradingService` is a singleton. Call `await paperService.init()` once before use (loads persisted state from `StorageService`). Operations: `buyStock`, `sellShort`, `closePosition`, `sellPartial`, `updateLtp`, `resetPortfolio`.

`PaperPositionsScreen` (2-tab `TabController`: Positions / Trade History) connects a `DhanFeedService` WebSocket to stream live LTP updates into `PaperTradingService.updateLtp()`.

Buy/sell/short orders are placed via `showPaperOrderSheet()` (defined in `paper_order_screen.dart`) — a `showModalBottomSheet` returning `Future<bool?>`. The internal `_PaperOrderSheet` widget uses `SwipeConfirmWidget` for confirmation; there is no full-page order screen and no plain confirm button. Called from both `LtpScreen` (Buy/Sell on each watchlist row) and `PaperPositionsScreen` (close-position flow).

---

### Data Storage

Two storage layers:

1. **`SharedPreferences`** (via `StorageService`) — all app state. Key constants at the top of `storage_service.dart`:
   - `paper_positions`, `paper_trades`, `paper_balance`, `paper_initial_capital`
   - `strategy_configs`, `strategy_trades`, `daily_run_history`, `backtest_results`
   - `all_watchlists`, `active_watchlist_id`
   - `dhan_client_id`, `dhan_access_token`
   - `strategy_activity_buffer_v1`, `strategy_session_state_v1` (managed by `StrategyBackgroundService`, not `StorageService`)

2. **SQLite** (`candle_cache.db` via `CandleRepository`) — historical candle cache. Schema: `(security_id, timestamp, interval)` primary key, plus `(security_id, date, interval)` index. Used by `BacktestEngine.bulkFetch()` to avoid re-hitting the Dhan API for already-downloaded candles.

3. **File** (`app_log.txt` in app docs dir via `AppLogger`) — rolling log, max 500 KB / 5000 lines.

4. **Files** (`{appDocs}/strategy_logs/{runId}.jsonl` + `.meta.json` via `RunLogger`) — per-run structured logs. `runId = ${date}_${configIdShort}` for live, `bt_${date}_${strategyType}_${ts}` for backtests. Each JSONL line is `{t, lvl, tag, msg, data?}`. Meta sidecar carries `kind: 'live'|'backtest'`, status, signals, trades, P&L for fast listing in the Log Viewer Runs tab. Retention configurable via `StorageService.getLogRetentionDays()` (default 14 days), swept on `main()`.

---

### Candles

- The `candlesticks` package **requires candles newest-first**. Always call `.reversed.toList()` after parsing.
- Market hours filter: 9:15 AM – 3:30 PM IST. Candles outside this window are discarded during parsing.
- `DhanService.fetchIntraday()` and `StrategyEngine._fetchIntradayCandles()` both apply this filter.
- HTTP 400 from the intraday API = no data for that date (market holiday/closed) — return empty list, not an error.
- **Live: strip the currently-forming bar before storing.** Dhan's intraday endpoint returns the just-opened bar (often with only a few seconds of tick data) as the "latest" candle. The live `_runProgressiveScreening` loop drops any candle whose start-minute ≥ the current slot's start-minute before writing to `_todayCandles`. Without this strip, the volume filter and dominance rules see a flat near-zero bar and falsely reject ~60% of the universe at every slot. The FETCH log line includes `incomplete=N` showing how many bars were stripped — a healthy run shows `incomplete ≈ active_stocks` at every slot. Backtest never hit this because `CandleRepository` only caches closed bars.

---

### Dhan API Quirks

- `fetchFunds()` response has a typo in the Dhan API itself: field is `availabelBalance` (not `availableBalance`).
- `fetchHoldings()` returns HTTP 500 with `errorCode: "DH-1111"` when the account has zero holdings — treat this as an empty list, not an error.
- WebSocket feed URL: `wss://api-feed.dhan.co?version=2&token=…&clientId=…&authType=2`
- Binary packet layout (little-endian): header 8 bytes `[code:u8][msgLen:u16][exchange:u8][securityId:i32]`, then payload varies by code (2=Ticker, 4=Quote, 6=PrevClose).
- Rate limit error code `805` / `DH-904` = too many requests — retry with exponential backoff.
- **`/v2/charts/intraday` omits the pre-open auction price on single-day queries.** Asking for a single date returns the first 5-min bar's `open` as the first regular-session trade — auction price is dropped. Asking for the same date as part of a multi-day window returns `open` = auction print (often making 09:15 a degenerate `open == high` bar). Dhan's own chart UI uses the multi-day shape. R8-Gap and any other rule that compares today's open vs prev-day close must use the multi-day shape, or live will see a different number than backtest (which already uses 90-day windows via `bulkFetch`). `StrategyEngine._fetchIntradayCandles` always queries with a 1-day-prior buffer and filters to the target date locally for this reason. Verified 2026-05-20: FIRSTCRY 09:15 single-day returned o=218.05; multi-day returned o=220.73; chart UI showed 220.73.

---

### Screens Reference

All navigation is via `Navigator.push` with `MaterialPageRoute` (no named routes, no router package). Drawer-launched destinations call `Navigator.pop(context)` first to close the drawer.

| Screen | Entry point | Notes |
|---|---|---|
| `TokenEntryScreen` | App start (no saved credentials), or re-auth from `LtpScreen` drawer | Saves clientId + accessToken via `StorageService`. Has a "Paste token" / "Generate token" segmented toggle: paste = manual token entry (original flow); generate = Client ID + PIN + TOTP → `DhanAuthService.generateAccessToken` mints + saves the token, then continues. PIN/TOTP are used once, never persisted |
| `LtpScreen` | App start (credentials saved); `pushReplacement` from `TokenEntryScreen` after login | Main hub — watchlist with WebSocket feed, drawer navigation to all other screens |
| `WatchlistManagerScreen` | From `LtpScreen` drawer | Create/delete/rename watchlists |
| `WatchlistScreen` | From `WatchlistManagerScreen` | Stock-picker UI for editing one watchlist's contents |
| `ChartScreen` | Tap a stock row in `LtpScreen` | Intraday + historical candlestick view (uses `candlesticks` package) |
| `HoldingsScreen` | From `LtpScreen` drawer | Real broker holdings via `DhanService.fetchHoldings()` |
| `PaperPositionsScreen` | From `LtpScreen` drawer | Tabs: positions + trade history, live WebSocket feed |
| `StrategyListScreen` | From `LtpScreen` drawer | List saved `StrategyConfigModel`s |
| `StrategyConfigScreen` | From `StrategyListScreen` (new / edit) | Form auto-generated from `BaseStrategy.paramDefinitions` |
| `StrategyDashboardScreen` | From `StrategyListScreen` (run) | Live phase/candidate/trade view; observes `WidgetsBinding` lifecycle to call `flushNow()` on pause |
| `StrategyHistoryScreen` | From `StrategyDashboardScreen` | Past `DailyRunSummaryModel` entries |
| `BacktestConfigScreen` | From `StrategyListScreen` (⋮ → Backtest) | Configure backtest range; receives the selected `StrategyConfigModel` so it backtests the chosen strategy with its params |
| `BacktestProgressScreen` | From `BacktestConfigScreen` | Live progress (phase chips + running totals); instantiates the strategy via the registry |
| `BacktestResultsScreen` | From `BacktestProgressScreen` or a history card | Results display (P&L, day-by-day) |
| `BacktestHistoryScreen` | History icon in `StrategyListScreen` app bar | Browsable list of past backtest runs (persisted by `StorageService`, max 20). Tap a card → `BacktestResultsScreen`; swipe to delete |
| `LogViewerScreen` | From `LtpScreen` drawer | Two-tab viewer: **App** (flat `app_log.txt`) + **Runs** (per-run JSONL list, retention picker, delete-all). Tap a run row → `RunLogDetailScreen` |
| `RunLogDetailScreen` | From Runs tab in `LogViewerScreen` OR "View full logs" button on the `StrategyHistoryScreen` detail sheet | Single-run JSONL viewer. Tag chips are **derived from loaded events** (frequency-sorted), not a static list — any new strategy emitting its own tag gets a chip for free. Level filter (Info+/Warn+/Error), search, share-as-JSONL |

Note: `paper_order_screen.dart` does **not** contain a Screen class — it exports the `showPaperOrderSheet()` modal-sheet helper described above.

---

### Per-Run Logging (Diagnostic Stack)

The dominance strategy hit a "live returns 0 candidates while backtest finds 26" mystery whose forensic trail was being eaten by the rolling `app_log.txt`. The diagnostic stack landed to make every future "why didn't this fire" answerable from saved data — without guessing.

**Per-run JSONL** (`RunLogger`):
- File per run, lives forever (until retention sweeps it). Live + backtest both use it.
- `BaseStrategy.scan()` returns a `ScanReport({stocksEvaluated, candlesInWindow, rejectCounts})` via `onScanReport` callback — strategies do not log strings, they emit structured payloads.
- `BaseStrategy.scan()` also fires `onStockReject(StockRejectEvent)` once per (stock, candle, failed rule) — both engines wire this to a `Reject` tag in the JSONL with the candle's full OHLCV. Lets devs answer "did live see stock X and why did it reject it?" by diffing live vs backtest Reject streams per-symbol.
- `BaseStrategy.diagnosisHint(rule)` returns a human-readable hint per rule key. Default null; `DominanceBreakoutStrategy` overrides with R1–R8 hints.

**Diagnostic events** emitted by both engines (tags in parentheses):
- `SCAN [HH:MM] in=N window=M signals=K | R5=147 R6a=31` (`Scan` / `Backtest`) — per slot, structured payload includes full `rejectCounts` map
- `PREMARKET: 499 loaded | avgVol p50=83k min=12 max=2.1M | bad(<1k)=8` (`PreMarket`) — end of pre-market load
- `Per-stock prevClose snapshot (N stocks)` (`PreMarket` / `Backtest`) — JSONL-only payload `{prevCloseBySymbol: {SYM: close, …}}`. Lets devs diff live's pre-market `stats.prevClose` against backtest's for any stock — exactly how the 2026-05-19 R8-Gap regression (live computed `prevClose` from the *oldest* fetched day instead of the most recent, hitting MCX with a fake −13 % gap) was caught.
- `FETCH [HH:MM] latest=09:30 expected=09:30 clean=244 stale=4 incomplete=N` (`Fetch`) — live only; flags partial-candle data from Dhan. `incomplete=N` counts stocks whose currently-forming bar was stripped (see Candles section); a healthy run has `incomplete ≈ active_stocks` at every slot.
- `Reject` events — per-stock, per-candle, per-rule. Detail strings are designed to be self-diagnosing on grep: e.g. R8-Gap embeds `open=X.XX prevClose=Y.YY` inline so a JSONL line tells the full story without cross-referencing.
- `WHY ZERO: 7 slots × 248 stocks avg = 1736 checks. Dominant reject: R5-VolMult (1247×, 71%). <hint>` (`Diagnosis`) — only when 0 signals at end of day; consults `strategy.diagnosisHint(topReject)` for the hint text
- `BREAKOUT (partial-bar): SYM bar=HH:MM high=X > Entry=Y — caught during fetch-delay window` (`Engine`) — live only; fires from Phase 0 of `_monitorBreakouts` when a breakout already happened during the slot's fetch loop. Distinguishes from `BREAKOUT: SYM LTP=X > Entry=Y` (Phase 1, continuous LTP poll).

`_log()` in `StrategyEngine` and `BacktestEngine` mirrors every line to both `AppLogger` AND the run's `RunLoggerSession`, so the JSONL is a complete forensic record. The SCAN/PREMARKET/FETCH/WHY-ZERO events additionally emit structured `data` payloads alongside the human-readable `msg`.

**Activity log cap**: bumped 50 → 100 in `StrategyEngine._maxKeyEvents` to fit per-slot SCAN summaries alongside trade events.
