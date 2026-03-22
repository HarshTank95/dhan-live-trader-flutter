# Dhan Trader

A Flutter mobile app for **live stock prices**, **candlestick charts**, and **automated trading strategies** using the [Dhan](https://dhan.co) API. Built for Indian equity markets (NSE).

---

## Features

### Live Prices (WebSocket)
- Real-time LTP via Dhan's **WebSocket binary feed** — true tick-by-tick data
- Previous day's close sourced from **Code 6 packets** (sent on subscription)
- Shows **% change** from previous day's closing price
- Live connection status dot: **LIVE** (market open) / **Connected** (market closed) / **Connecting** / **Reconnecting**
- Auto-reconnects on disconnect with 5-second backoff

### Candlestick Chart
- Tap any stock → detail sheet → **View Chart** button
- **5 min** and **15 min** intraday intervals
- **Live candles** — current candle updates tick-by-tick via WebSocket (H/L/C update in real time)
- New candle automatically inserted when interval boundary is crossed
- Scroll left to auto-load previous trading days (handles weekends + holidays)
- **Touch any candle** to see OHLC + volume inside the chart
- Volume shown in the VOL overlay
- **Jump to latest** toolbar button to snap back to today's candles
- Filtered to **market hours only** (9:15 AM – 3:30 PM IST)

### Holdings / Portfolio
- View your **long-term holdings** with live LTP refresh
- Shows **unrealised P&L** (INR and %) per stock + overall portfolio
- Portfolio summary: Current Value, Total Invested, Overall P&L
- Large number formatting: K / L / Cr

### Funds Balance
- Drawer shows **Available** and **Used** margin balance
- Fetched from Dhan's `/v2/fundlimit` endpoint on drawer open

### Multiple Watchlists
- Create **unlimited named watchlists** (e.g. "Nifty 50", "Bank Stocks")
- Switch between watchlists from the side drawer instantly
- Add up to **20 stocks** per watchlist
- Drag to **reorder** stocks
- Double-tap to **rename** a watchlist
- Swipe to **delete** a watchlist

### Stock Search
- Downloads Dhan's **NSE_EQ instrument list** via authenticated API on first launch
- Cached locally — re-downloads **once per day** automatically
- Falls back to full public scrip master CSV if auth endpoint fails
- Search by symbol (e.g. `HDFC`) or company name (e.g. `Infosys`)
- **Search bar on home screen** — tap to search and add stocks directly to the active watchlist
- Duplicate and full-watchlist (20 stocks) guards with snackbar feedback

### Market Status
- Shows **Market Open / Closed** badge in app bar
- Based on IST time: 9:15 AM – 3:30 PM, Monday–Friday

### Sort Stocks
- Best performers first (% Change descending)
- Worst performers first (% Change ascending)
- Name A to Z

### Dark Mode
- Toggle from side drawer, persists across sessions

---

## Strategy Engine (Dominance + Breakout)

Automated trading strategy ported 1:1 from the C# Dhan Live Trader project. Scans **Nifty 500 stocks** for dominance candles and enters on breakout.

### How It Works

```
Pre-Market (before 9:15)
  → prepare(): Fetch 10 days of 5-min candles for Nifty 500 stocks
  → Compute: avgCandleSize, avgVolume, prevClose per stock

Screening Window (9:30 - 10:00)
  → scan() every 5 min: Check each candle against 8 dominance rules
  → First match per stock wins → creates a signal (entry = high, SL = low)

Breakout Monitoring (after signal)
  → WebSocket LTP feed: if LTP > dominance high → BREAKOUT
  → Position sizing: quantity = floor(fixedSL / riskPerShare)
  → Target: entryPrice + (fixedTarget / quantity)

Exit
  → LTP <= stopLoss → close at SL
  → LTP >= target → close at target
  → End of day → auto-close
```

### 8 Dominance Candle Rules (exact C# match)

| # | Rule | Default |
|---|------|---------|
| 1 | Must be bullish (close > open) | — |
| 2 | Body % of range in [min, max] | 70% – 85% |
| 3 | Both wicks >= min wick % | >= 5% |
| 4 | Candle size between min/max x average | 1.0x – 2.5x |
| 5 | Volume >= multiplier x average volume | >= 2.0x |
| 6 | All candles from 9:15 to dominance candle >= min absolute volume | >= 5000 |
| 7 | Actual movement <= max x expected movement | <= 2.0x |
| 8 | Gap filter: gap up <= max%, gap down <= max% | up <= 2.5%, down <= 1.0% |

### Position Sizing (exact C# match)

```
riskPerShare = entryPrice - stopLoss
quantity     = floor(fixedStopLoss / riskPerShare)
targetPrice  = entryPrice + (fixedTarget / quantity)
```
Default: Risk INR 500, Target INR 2000 per trade, max 2 trades/day.

### Strategy Config Screen
- All parameters editable via sliders and +/- buttons
- Grouped sections: Screening Window, Dominance Rules, Position Sizing, Pre-Market Data
- **Paper / Live toggle** with confirmation dialog for Live mode
- **Enabled / Paused toggle** — pause without deleting
- **Stock Universe** — auto-loaded from Nifty 500 (scrollable list of all stocks)

### Strategy List Screen
- **Default strategy auto-created** on first launch with Nifty 500 stocks
- **START / STOP button** directly on each strategy card
- Running state indicator with "RUNNING" badge
- Paper/Live badge, stock count, SL amount badges
- 3-dot menu: View Dashboard, Edit Config, Delete
- "+" button in app bar to create additional strategies

### Strategy Dashboard
- Gradient header with strategy name and START/STOP button
- Config summary chips: Stocks, Risk, Target, Max Trades
- Paper/Live mode badge in app bar
- **Phase Stepper**: Visual progress indicator — Load → Pre-Mkt → Screen → Monitor → Done (green checkmarks for completed, blue for active)
- **Candidates Section**: Horizontal scrollable cards for dominance signals showing symbol, entry price, SL, time, and status (Watching/Traded)
- **Auto-scroll Activity Log**: Real-time activity feed that auto-scrolls to newest entry
- **History Button**: Navigate to daily run history from app bar

### Strategy Engine
- Full engine running inside background isolate: `prepare()` → progressive screening → dominance scan → breakout monitoring → exit
- **Progressive Volume Elimination**: Filters out low-volume / no-data / API-error stocks at each 5-min interval with detailed breakdown logging (e.g., `Eliminated 254 — LowVolume: 200, NoData: 50, ApiError: 4`)
- **Dominance Rejection Logging**: Tracks which of the 8 rules rejected each candle with `onReject` callback — produces a rejection summary (e.g., `R5-Volume: 320, R2-Body%: 45`)
- **Daily Run Summary**: Auto-saves run results (stocks scanned, candidates found, trades, P&L, key events) to SharedPreferences for history

### Daily Run History
- View past strategy runs as cards (date, mode, stats, P&L)
- Tap card → bottom sheet with full details + color-coded activity log
- Delete individual days or clear all history
- Max 30 days retained automatically

### Background Service (Foreground Service)
- Strategy runs even when **phone is locked or app is minimized**
- Uses Android foreground service via `flutter_background_service`
- Small persistent notification: "Strategy Name (Paper/Live) — Scanning stocks..."
- Requests notification permission on Android 13+ before starting
- Auto-stops when strategy completes or user taps STOP
- **Active strategy tracking**: Persists running config ID in SharedPreferences to prevent false "running" state on app restart (service stays alive but strategy may have completed)

### Plugin Architecture
- `BaseStrategy` abstract class with lifecycle: `prepare()` → `scan()` → `checkBreakout()` → `checkExit()`
- `StrategyRegistry` for registering and creating strategy types
- `StrategyParamDef` drives auto-generated config UI from parameter definitions
- Easily extensible — add new strategies by implementing `BaseStrategy` and registering in the registry

### Nifty Index Stock Universe (Dynamic)
- **Dynamically fetched** from official NSE source (`niftyindices.com`) — Nifty 50, 200, 500 CSV files
- Cached daily in SharedPreferences; falls back to hardcoded list if fetch fails
- `ScripService.getSecurityIdsForUniverse('Nifty 500')` matches fetched symbols against Dhan scrip master
- Symbol alias mapping for known NSE↔Dhan name mismatches (e.g., renamed stocks)
- Existing saved strategy configs auto-refresh their security IDs on app load
- Currently matches **498/500** stocks (2 suspended/delisted stocks not in Dhan)
- Hardcoded fallback list in `lib/data/nifty500_stocks.dart` (mirrors C# `Nifty500Stocks.cs`)

### Signal Expiry & Re-screening
- Signals expire at the next scan interval boundary (e.g., found at 9:35 → expires at 9:40)
- Expired signals are removed from `alreadySignalled`, allowing the stock to be re-screened
- Consistent between live engine and backtest engine

### Duplicate Trade Prevention
- Same stock cannot be traded twice on the same day (tracked via `tradedSecIds` set)
- Consistent between live engine and backtest engine

### Immediate Breakout Detection (Live)
- After dominance screening (~1 min loop for 500 stocks), checks if breakout already happened during the delay
- Uses already-fetched candle data: if `latestCandle.high > entryPrice`, triggers immediate trade
- Prevents missing breakouts that occur during the screening window

---

## Backtest Engine

Run the same Dominance + Breakout strategy on historical data to validate before live trading.

### How It Works
```
Select date range + stock universe (Nifty 50 / 200 / 500)
  ↓
Download historical 5-min candles for all stocks (with progress UI)
  ↓
Per trading day:
  1. Compute stats from prior N days (same as live prepare())
  2. Progressive volume elimination at each scan interval
  3. Dominance screening with signal expiry & re-screening
  4. Breakout detection: candle.high > entry within expiry window
  5. Exit simulation: SL (conservative) / Target / EOD close
  ↓
Aggregate results: per-day and overall P&L, win/loss, drawdown
```

### Key Design Decisions
- **Breakout proxy**: Live uses `LTP > entry`, backtest uses `candle.high > entry` (correct proxy without tick data)
- **Conservative exit**: If same candle hits both SL and target, assume SL hit first
- **Signal expiry**: Matches live — breakout must happen within the scan interval window
- **Duplicate prevention**: Same stock cannot be traded twice per day (matches live)
- **Re-screening**: After signal expiry, stock is removed from `alreadySignalled` and can be re-screened

### Backtest UI
- **Config screen**: Date range presets (7d/30d/90d/6m/1y), stock universe selector, SL/target/max trades sliders
- **API usage estimate**: Shows estimated calls needed vs remaining quota
- **Progress screen**: Real-time download progress with cancel button (UI stays responsive via event loop yielding)
- **Results screen**: Summary stats, daily P&L chart, per-day details with entry/exit times, individual trade list
- Access via **3-dot menu → Backtest** on each strategy card

### Live vs Backtest Comparison Logging
Both engines log at identical decision points for side-by-side comparison:
- `DOMINANCE`: symbol, entry, SL, time window (signal→expiry)
- `BREAKOUT`: symbol, price, time, quantity, SL, target
- `EXPIRED`: symbol, re-screening note
- `SL HIT` / `TARGET` / `EOD EXIT`: symbol, exit price, P&L
- `SKIP`: reason (max trades reached / already traded today)
- `NO BREAKOUT`: signal that expired without breakout, with window details
- `DAY SUMMARY` (backtest only): stocks scanned, after elimination, signals, trades, W/L, P&L

Live logs tagged as `[INFO] Engine:`, backtest as `[INFO] Backtest:` — both visible in **Drawer → View Logs**.

---

## App Logging

File-based logger for debugging on device.

- Logs written to `app_log.txt` on device storage
- Levels: INFO, WARN, ERROR, STRAT (strategy), TRADE
- Includes timestamps, tags, and full stack traces on errors
- **Drawer → View Logs** opens the log viewer screen
- Filter by level (quick chips) or free text search
- **Copy** button to clipboard (copies filtered logs)
- **Share/Export** button — writes logs to a timestamped `.txt` file and opens Android share sheet (send via WhatsApp, email, save to files, etc.)
- Auto-trims log file at 500KB to prevent storage bloat
- Catches uncaught Flutter errors via `FlutterError.onError`

---

## Project Structure

```
lib/
├── main.dart                              # App entry, theme, error handling, service init
│
├── data/
│   └── nifty500_stocks.dart               # Nifty 500 symbol set (mirrors C# Nifty500Stocks.cs)
│
├── models/
│   ├── watchlist_model.dart               # WatchlistModel data class
│   ├── holding_model.dart                 # HoldingModel with P&L computed fields
│   ├── candle_stats_model.dart            # Pre-computed historical metrics per stock
│   ├── strategy_config_model.dart         # Strategy config: type, params, stocks, paper/live, enabled
│   ├── strategy_signal_model.dart         # Dominance candle signal with metrics
│   ├── strategy_trade_model.dart          # Trade with entry/exit, SL/target, P&L computed fields
│   └── daily_run_summary_model.dart       # Daily run history: stats, events, P&L
│
├── screens/
│   ├── token_entry_screen.dart            # Credential input screen
│   ├── ltp_screen.dart                    # Main live prices screen (WebSocket) + side drawer
│   ├── chart_screen.dart                  # Candlestick chart with live candle updates
│   ├── holdings_screen.dart               # Portfolio screen with live P&L
│   ├── watchlist_manager_screen.dart      # Create / rename / delete watchlists
│   ├── watchlist_screen.dart              # Add / remove stocks in a watchlist
│   ├── strategy_list_screen.dart          # Strategy cards with START/STOP buttons
│   ├── strategy_config_screen.dart        # Auto-generated param editor from StrategyParamDef
│   ├── strategy_dashboard_screen.dart     # Strategy run dashboard (phase stepper, candidates, activity)
│   ├── strategy_history_screen.dart       # Daily run history with details and delete
│   ├── backtest_config_screen.dart        # Backtest setup: date range, universe, params, API estimate
│   ├── backtest_progress_screen.dart      # Backtest download progress with cancel support
│   ├── backtest_results_screen.dart       # Backtest results: summary, daily chart, trades with entry/exit times
│   └── log_viewer_screen.dart             # On-device log viewer with filter, copy, and share/export
│
├── services/
│   ├── dhan_service.dart                  # Dhan REST API calls (OHLC, charts, holdings, funds)
│   ├── dhan_feed_service.dart             # Dhan WebSocket binary feed (live prices)
│   ├── rate_limiter.dart                  # Centralized API rate limiter (singleton)
│   ├── scrip_service.dart                 # Scrip master + dynamic NSE index fetching (singleton)
│   ├── candle_repository.dart             # Historical candle download with caching and progress
│   ├── storage_service.dart               # SharedPreferences: credentials, watchlists, theme, configs, trades, active strategy
│   ├── app_logger.dart                    # File-based logger with memory buffer
│   ├── strategy_background_service.dart   # Android foreground service for background strategy execution
│   ├── strategy_engine.dart               # Live strategy execution engine (runs in background isolate)
│   └── backtest_engine.dart               # Backtest simulation engine (same rules as live)
│
└── strategies/
    ├── base_strategy.dart                 # Abstract strategy interface + StrategyParamDef
    ├── strategy_registry.dart             # Factory registry for strategy types
    └── dominance_breakout_strategy.dart   # Dominance candle + breakout strategy (exact C# port)
```

---

## Tech Stack

| Package | Purpose |
|---|---|
| `http` | REST API calls to Dhan |
| `web_socket_channel` | WebSocket binary live feed |
| `shared_preferences` | Local key-value storage |
| `path_provider` | File system access for scrip/log cache |
| `uuid` | Unique IDs for watchlists, strategies, trades |
| `candlesticks` | Candlestick chart widget |
| `flutter_native_splash` | Branded splash screen |
| `flutter_background_service` | Android foreground service for background execution |
| `flutter_local_notifications` | Notification channel for foreground service |
| `share_plus` | Native share sheet for log export |

---

## Dhan API Endpoints Used

| Endpoint | Purpose |
|---|---|
| `wss://api-feed.dhan.co` | WebSocket live feed (LTP, OHLC, prevClose) |
| `GET /v2/instrument/NSE_EQ` | NSE equity instrument list (auth, small) |
| `POST /v2/marketfeed/ohlc` | Initial LTP + OHLC (REST, startup only) |
| `POST /v2/charts/intraday` | Intraday candlestick data (5m / 15m) |
| `POST /v2/charts/historical` | Previous day's close (startup, per watchlist) |
| `GET /v2/fundlimit` | Available and used margin balance |
| `GET /v2/holdings` | Long-term holdings portfolio |
| `images.dhan.co/api-data/api-scrip-master.csv` | Fallback full instrument list (no auth) |

---

## Getting Started

### Prerequisites
- Flutter SDK (3.x+)
- Android device (API 26+)
- Active [Dhan](https://dhan.co) account with API access

### Run the App

```bash
cd Flutter/my_app
flutter pub get
flutter run
```

### Build Release APK

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### First Launch
1. Enter your **Dhan Client ID** and **Access Token**
2. App downloads the NSE_EQ instrument list (authenticated, small file)
3. Default watchlist loads with 5 Nifty stocks
4. WebSocket connects — live prices start streaming instantly
5. Default "Dominance + Breakout" strategy auto-created with Nifty 500 stocks

---

## How It Works

### Startup Flow
```
App opens
  ↓
Init logger + background service
  ↓
Load saved credentials + watchlists + theme
  ↓
Download NSE_EQ instrument list (or load from cache)
  ↓
Fetch yesterday's close for each watchlist stock
  ↓
Initial REST OHLC call (fast first paint)
  ↓
Connect WebSocket → subscribe → live prices stream in
```

### WebSocket Binary Protocol
```
Connection: wss://api-feed.dhan.co?version=2&token=...&clientId=...&authType=2

Subscribe (JSON):
  { "RequestCode": 15, "InstrumentCount": N,
    "InstrumentList": [{"ExchangeSegment": "NSE_EQ", "SecurityId": "1333"}] }

Binary packets (little-endian, 8-byte header):
  Header: [code:u8][msgLen:u16][exchange:u8][securityId:i32]

  Code 2 – Ticker   : header + LTP(f32) + time(i32)          = 16 bytes
  Code 4 – Quote    : header + LTP + qty + time + avg +
                      vol + sell + buy + open + close +
                      high + low                               = 50 bytes
  Code 6 – PrevClose: header + prevClose(f32) + OI(i32)       = 16 bytes
```

### Strategy Flow
```
User taps START on strategy card
  ↓
Android foreground service starts (survives lock screen / background)
  ↓
prepare(): Fetch 10 days of 5-min candles for Nifty 500 (compute averages)
  ↓
scan() at 9:30, 9:35, 9:40, ..., 10:00: Check every candle against 8 rules
  ↓
Signal found → monitor LTP via WebSocket
  ↓
LTP > dominance high → BREAKOUT → open trade (paper or live)
  ↓
LTP hits SL or target → close trade → log result
  ↓
Screening window ends → auto-stop → show results
```

---

## Dhan API Rate Limits

| Category | Per Second | Per Day |
|---|---|---|
| **Quote APIs** (marketfeed/ltp, ohlc, quotes) | 1 req/sec | Unlimited |
| **Data APIs** (charts/intraday, charts/historical) | 5 req/sec | 100,000/day |
| **Order APIs** | 10 req/sec | 7,000/day |
| **Non-Trading APIs** | 20 req/sec | Unlimited |

### WebSocket Limits

| Limit | Value |
|---|---|
| Max simultaneous connections | 5 |
| Max instruments per connection | 5,000 |
| Max instruments per subscription message | 100 |

### How This App Handles Rate Limits
- Live prices: WebSocket push (zero REST usage)
- Centralized `RateLimiter` singleton for all REST calls
- Strategy prepare(): Sequential with rate limiting for 500 stocks

---

## Issues Faced During Development

### 1. Wrong Auth Header
**Problem:** 401 Unauthorized. **Fix:** Changed from `Authorization: Bearer` to `access-token` + `client-id` headers.

### 2. Missing Internet Permission
**Problem:** Silent failure on Android. **Fix:** Added `INTERNET` permission in AndroidManifest.xml.

### 3. Quotes Endpoint 404
**Problem:** `/v2/marketfeed/quotes` returned 404. **Fix:** Switched to `/v2/marketfeed/ohlc`.

### 4. Rate Limiting (HTTP 429)
**Problem:** Too many parallel API calls. **Fix:** Centralized rate limiter with per-category throttling.

### 5. % Change Showing 0%
**Problem:** `ohlc.close` equals LTP when market is closed. **Fix:** Fetch previous day's close via historical API + WebSocket Code 6.

### 6. DH-905 Error
**Problem:** Historical API error for weekends/holidays. **Fix:** Fetch 7-day range, use last available close.

### 7. DH-1111 Error
**Problem:** Holdings API returns HTTP 500 for empty portfolios. **Fix:** Detect `DH-1111` and treat as empty list.

### 8. % Change Resets on Watchlist Switch
**Problem:** New watchlist stocks had no cached prevClose. **Fix:** Fire `loadPrevCloses()` after every watchlist switch.

### 9. LIVE + Closed Labels Contradicting
**Problem:** Bottom bar showed LIVE while app bar showed Closed. **Fix:** Show LIVE only when market is open AND feed is connected.

### 10. Chart Live Candle Creating Separate Candles
**Problem:** Every WebSocket tick created a new tiny candle instead of updating existing. **Cause:** `DateTime.now().toUtc().add(5:30)` creates UTC-marked time with IST value — 5.5 hour mismatch with local-time candle dates. **Fix:** Use `DateTime.now()` (local time) to match API candle timestamps.

### 11. Strategy scan() Only Checking Last Candle
**Problem:** Flutter scan only checked `candles.last` instead of iterating all candles. C# processes every candle via `ProcessCandle` with `IsActiveAt` time check. **Fix:** Iterate all candles in screening window, first match per stock wins.

### 12. Background Service Crash on START
**Problem:** App crashed when tapping START. **Cause:** (a) `_onStart` was private — isolate couldn't find it. (b) Android 13+ requires runtime notification permission before foreground service. **Fix:** Made `onStart` public, added `requestNotificationsPermission()` call before starting service.

### 13. ScripService Not Singleton
**Problem:** `ScripService()` created new empty instances — strategy got 0 stocks. **Fix:** Made ScripService a singleton with `factory` constructor.

### 14. Strategy securityIds Always Empty
**Problem:** New strategy defaulted to `securityIds = []` — 0 stocks to scan. **Fix:** Auto-populate from Nifty 500 list on strategy creation.

### 15. UI Freeze During Backtest Download
**Problem:** App froze at ~70/409 stocks, cancel button unresponsive. **Cause:** Tight async loop without yielding to event loop. **Fix:** Added `await Future.delayed(Duration.zero)` every iteration + 15s HTTP timeout.

### 16. False "Running" State on App Restart
**Problem:** Strategy showed STOP button on app restart even when not started. **Cause:** Background service stays alive as foreground service; `isRunning()` always returns true. **Fix:** Persist active strategy config ID in SharedPreferences, check it matches before showing running state.

### 17. Backtest Signal Expiry Missing
**Problem:** Backtest allowed breakouts at any time (e.g., 14:00) instead of within 5-min expiry window like live. **Fix:** Override DateTime.now()-based timestamps with candle time, add expiry window check in breakout detection, re-screen after expiry.

### 18. Same Stock Traded Twice in Backtest
**Problem:** After adding re-screening, same stock could get multiple breakout trades on same day. **Fix:** Added `tradedSecIds` set to prevent duplicate trades per day.

### 19. Only ~410 Stocks Instead of 500
**Problem:** Hardcoded `nifty500_stocks.dart` was incomplete and many symbols didn't match Dhan's scrip master. **Fix:** Dynamic fetching from official NSE website (niftyindices.com), cached daily, with hardcoded fallback.

---

## Build Phases

### Phase 1 (Complete)
- Strategy models (config, signal, trade)
- Dominance + Breakout strategy (exact C# port, all 8 rules)
- Plugin architecture (BaseStrategy, StrategyRegistry, StrategyParamDef)
- Config screen with auto-generated UI
- Strategy list with START/STOP buttons
- Nifty 500 stock universe
- Background service infrastructure
- App logging system

### Phase 2 (Complete)
- Strategy engine inside background service (isolate)
- Historical data fetching (prepare phase) with progress tracking
- Progressive volume screening at 5-min intervals with elimination breakdown
- Dominance candle scanning with rejection logging (8 rules)
- Phase-aware dashboard with stepper, candidates, auto-scroll activity

### Phase 3 (Complete)
- Trade execution (paper mode: simulated fills)
- Breakout monitoring via REST LTP polling
- Results display on dashboard (signals, trades, P&L)
- Daily run history with persistence (max 30 days)
- Log export/share via Android share sheet
- Auto-stop at end of screening window

### Phase 4 (Complete)
- Backtest engine with historical candle simulation
- Backtest config screen (date range, universe, API estimate)
- Backtest progress screen with cancel support and UI freeze fix
- Backtest results screen with daily P&L chart, entry/exit times
- Dynamic Nifty index fetching from official NSE source (niftyindices.com)
- Signal expiry & re-screening in backtest (matching live engine)
- Duplicate trade prevention in backtest (matching live engine)
- Immediate breakout detection in live engine (catches breakouts during screening delay)
- Active strategy tracking to fix false running state on app restart
- Comparison logging for live vs backtest debugging

### Phase 5 (Next)
- Live trading via Dhan Order API
- Order placement, confirmation, and monitoring
- End-of-day auto-square-off

### Phase 6
- Auto-schedule (start strategy at fixed time daily)
- Trade history and analytics
- Multiple concurrent strategies

---

## Notes

- All credentials stored **locally on device only**
- ScripService is a singleton — loaded once, shared across app
- Strategy configs and trades persisted via SharedPreferences
- Background service uses Android foreground service (requires notification)
- Dark mode and all settings persist across app restarts
