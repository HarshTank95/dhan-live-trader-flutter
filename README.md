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
- Detects running state when app is reopened

### Plugin Architecture
- `BaseStrategy` abstract class with lifecycle: `prepare()` → `scan()` → `checkBreakout()` → `checkExit()`
- `StrategyRegistry` for registering and creating strategy types
- `StrategyParamDef` drives auto-generated config UI from parameter definitions
- Easily extensible — add new strategies by implementing `BaseStrategy` and registering in the registry

### Nifty 500 Stock Universe
- Hard-coded symbol list in `lib/data/nifty500_stocks.dart` (mirrors C# `Nifty500Stocks.cs`)
- `ScripService.getNifty500SecurityIds()` filters loaded NSE EQ instruments by Nifty 500 membership
- Matches C# `InstrumentService.GetNseEquities()` behavior exactly

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
│   └── log_viewer_screen.dart             # On-device log viewer with filter, copy, and share/export
│
├── services/
│   ├── dhan_service.dart                  # Dhan REST API calls (OHLC, charts, holdings, funds)
│   ├── dhan_feed_service.dart             # Dhan WebSocket binary feed (live prices)
│   ├── rate_limiter.dart                  # Centralized API rate limiter (singleton)
│   ├── scrip_service.dart                 # Scrip master download, parse, cache, Nifty 500 filter (singleton)
│   ├── storage_service.dart               # SharedPreferences: credentials, watchlists, theme, configs, trades
│   ├── app_logger.dart                    # File-based logger with memory buffer
│   ├── strategy_background_service.dart   # Android foreground service for background strategy execution
│   └── strategy_engine.dart               # Strategy execution engine (runs in background isolate)
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

### Phase 4 (Next)
- Live trading via Dhan Order API
- Order placement, confirmation, and monitoring
- End-of-day auto-square-off

### Phase 5
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
