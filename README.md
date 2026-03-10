# Dhan LTP Viewer

A Flutter mobile app for viewing **live stock prices** from your [Dhan](https://dhan.co) account. Built for Indian equity markets (NSE).

---

## Features

### Live Prices (WebSocket)
- Real-time LTP via Dhan's **WebSocket binary feed** — true tick-by-tick data
- Previous day's close sourced from **Code 6 packets** (sent on subscription)
- Shows **% change** from previous day's closing price
- Live connection status dot: **● LIVE** (market open) / **● Connected** (market closed) / **● Connecting** / **● Reconnecting**
- Auto-reconnects on disconnect with 5-second backoff

### Holdings / Portfolio
- View your **long-term holdings** with live LTP refresh
- Shows **unrealised P&L** (₹ and %) per stock + overall portfolio
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

### Dynamic Stock Search
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
- Best performers first (▲ % Change)
- Worst performers first (▼ % Change)
- Name A → Z

### Candlestick Chart
- Tap any stock → detail sheet → **View Chart** button
- **5 min** and **15 min** intraday intervals
- **Live candles** — current candle updates tick-by-tick via WebSocket (H/L/C update in real time)
- New candle automatically inserted when interval boundary is crossed
- Scroll left to auto-load previous trading days (handles weekends + holidays)
- **Touch any candle** to see OHLC + volume inside the chart
- Volume shown in the VOL overlay — displays actual value (blue) when hovering a candle
- **Jump to latest** toolbar button to snap back to today's candles
- Filtered to **market hours only** (9:15 AM – 3:30 PM IST)

### UI & UX
- **Dark Mode** toggle (saved across sessions)
- **Pull to refresh** manually
- Modern side drawer with gradient header
- Stock detail bottom sheet on tap
- Branded splash screen (blue theme)
- **Gainers / Losers summary** in the bottom bar: `▲ 12  ▼ 8  — 2` alongside the live status dot
- **Search bar** below the app bar for quick stock discovery and adding

### Credentials
- Enter Dhan **Client ID** and **Access Token** once
- Saved securely on device using `shared_preferences`
- Edit or clear credentials from the drawer anytime

---

## Project Structure

```
lib/
├── main.dart                          # App entry, theme management
│
├── models/
│   ├── watchlist_model.dart           # WatchlistModel data class
│   └── holding_model.dart             # HoldingModel with P&L computed fields
│
├── screens/
│   ├── token_entry_screen.dart        # Credential input screen
│   ├── ltp_screen.dart                # Main live prices screen (WebSocket)
│   ├── chart_screen.dart              # Candlestick chart with OHLC info bar
│   ├── holdings_screen.dart           # Portfolio screen with live P&L
│   ├── watchlist_manager_screen.dart  # Create / rename / delete watchlists
│   └── watchlist_screen.dart          # Add / remove stocks in a watchlist
│
└── services/
    ├── dhan_service.dart              # Dhan REST API calls (OHLC, charts, holdings, funds)
    ├── dhan_feed_service.dart         # Dhan WebSocket binary feed (live prices)
    ├── rate_limiter.dart              # Centralized API rate limiter (singleton)
    ├── scrip_service.dart             # Scrip master download, parse, cache
    └── storage_service.dart           # SharedPreferences: credentials, watchlists, theme
```

---

## Tech Stack

| Package | Purpose |
|---|---|
| `http` | REST API calls to Dhan |
| `web_socket_channel` | WebSocket binary live feed |
| `shared_preferences` | Local key-value storage |
| `path_provider` | File system access for scrip cache |
| `uuid` | Unique IDs for each watchlist |
| `candlesticks` | Candlestick chart widget |
| `flutter_native_splash` | Branded splash screen |

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
- Android emulator or physical device
- Active [Dhan](https://dhan.co) account with API access

### Run the App

```bash
cd Flutter/my_app
flutter pub get
flutter run
```

### First Launch
1. Enter your **Dhan Client ID** and **Access Token**
2. App downloads the NSE_EQ instrument list (authenticated, small file)
3. Default watchlist loads with 5 Nifty stocks
4. WebSocket connects — live prices start streaming instantly

---

## How It Works

### Startup Flow
```
App opens
  ↓
Load saved credentials + watchlists + theme
  ↓
Download NSE_EQ instrument list via /v2/instrument/NSE_EQ (or fallback CSV)
  ↓
Fetch yesterday's close for each watchlist stock (historical API)
  ↓
Initial REST OHLC call (fast first paint)
  ↓
Connect WebSocket → subscribe → Code 6 (prevClose) + Code 4 (OHLC) stream in
```

### WebSocket Binary Protocol
```
Connection: wss://api-feed.dhan.co?version=2&token=…&clientId=…&authType=2

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

### % Change Calculation
```
% Change = (LTP - Previous Day Close) / Previous Day Close × 100
```
Previous day close sourced from WebSocket Code 6 packets (sent on subscription)
and Code 4's `close` field as fallback. Also pre-loaded via historical REST API
at startup so pull-to-refresh always shows correct values.

### Scrip Master Caching
```
First launch of the day  →  GET /v2/instrument/NSE_EQ (auth, NSE_EQ only)
                            Fallback: download full CSV from Dhan CDN
                         →  Filter: EQUITY + EQ series only
                         →  Save as JSON to device storage
Same day relaunch        →  Load from local JSON cache (instant)
Next day                 →  Re-download fresh copy
```

---

## Dhan API Rate Limits

> Source: [dhanhq.co/docs/v2](https://dhanhq.co/docs/v2/)

### Official Limits by Endpoint Category

| Category | Per Second | Per Minute | Per Hour | Per Day |
|---|---|---|---|---|
| **Quote APIs** (marketfeed/ltp, ohlc, quotes) | **1 req/sec** | Unlimited | Unlimited | Unlimited |
| **Data APIs** (charts/intraday, charts/historical) | **5 req/sec** | — | — | 100,000/day |
| **Order APIs** | 10 req/sec | 250 | 1,000 | 7,000 |
| **Non-Trading APIs** | 20 req/sec | Unlimited | Unlimited | Unlimited |

### WebSocket Limits

| Limit | Value |
|---|---|
| Max simultaneous connections | 5 |
| Max instruments per connection | 5,000 |
| Max instruments per subscription message | 100 |
| Server ping interval | Every 10 seconds |
| Connection timeout (no pong) | 40 seconds |

### How This App Handles Rate Limits

| Action | Method | Frequency |
|---|---|---|
| Live price updates | WebSocket push | Real-time (per trade) |
| Initial OHLC display | REST (`/v2/marketfeed/ohlc`) | Once at startup |
| Prev close loading | REST (`/v2/charts/historical`) | Once per watchlist load |
| Chart data | REST (`/v2/charts/intraday`) | On demand |
| Funds balance | REST (`/v2/fundlimit`) | On drawer open |
| Holdings | REST (`/v2/holdings`) | On screen open |

### Centralized Rate Limiter (`lib/services/rate_limiter.dart`)

The app uses a **centralized watchman** — a `RateLimiter` singleton that every REST API call must pass through. This prevents 429 errors entirely.

**Usage in code:**
```dart
await RateLimiter.instance.acquire(ApiCategory.quote); // for marketfeed/*
await RateLimiter.instance.acquire(ApiCategory.data);  // for charts/*
```

---

## Notes

- All credentials are stored **locally on your device only**
- WebSocket connection uses the same access token as REST APIs
- Dark mode and watchlist configuration persist across app restarts

---

## Issues Faced During Development

### 1. Wrong Auth Header
**Problem:** Initial API calls returned 401 Unauthorized.
**Cause:** Used `Authorization: Bearer <token>` — but Dhan expects a custom header.
**Fix:** Changed to `access-token: <token>` and `client-id: <clientId>` as separate headers.

### 2. Missing Internet Permission
**Problem:** App failed silently with "Failed to fetch prices" on Android.
**Cause:** `AndroidManifest.xml` did not have the internet permission declared.
**Fix:** Added `<uses-permission android:name="android.permission.INTERNET"/>` before the `<application>` tag.

### 3. Quotes Endpoint Returning 404
**Problem:** `POST /v2/marketfeed/quotes` returned `404 page not found`.
**Cause:** This endpoint is not available on all Dhan API plans.
**Fix:** Switched to `POST /v2/marketfeed/ohlc` which provides LTP + Open/High/Low/Close.

### 4. Rate Limiting (HTTP 429)
**Problem:** App started getting rate limit errors from Dhan.
**Cause:** Were making 2 parallel API calls (LTP + OHLC) every 3 seconds, exceeding the 1 req/sec limit.
**Fix:** Consolidated to a single OHLC call and added centralized rate limiter.

### 5. % Change Showing 0% or Wrong Value
**Problem:** All stocks showed 0.00% change.
**Cause:** `ohlc.close` equals `ltp` when the market is closed — both reflect the last traded price.
**Fix:** Fetch yesterday's closing price via the historical API at startup. WebSocket Code 6 packets also provide prevClose on subscription.

### 6. DH-905 Error from Historical API
**Problem:** Historical API returned error code DH-905 when requesting a single day's data.
**Cause:** No trading data exists for the specific date requested (e.g. weekend or holiday).
**Fix:** Fetch a 7-day range and use the last available close value.

### 7. DH-1111 Error from Holdings API
**Problem:** `GET /v2/holdings` returned HTTP 500 with `errorCode: "DH-1111"`.
**Cause:** Dhan returns HTTP 500 (not 404) when the account has no holdings — poor API design.
**Fix:** Detect the specific `DH-1111` error code and treat it as an empty holdings list.

### 8. % Change Resets to 0% After Watchlist Switch
**Problem:** Switching watchlists then pulling to refresh showed 0% change for all stocks.
**Cause:** `loadPrevCloses()` only ran at startup for the initial watchlist. New watchlist stocks had no cached prevClose, so the REST pull-to-refresh built quotes with prevClose=0.
**Fix:** Fire `loadPrevCloses()` in the background after every watchlist switch so the REST fallback always has correct prevClose values. WebSocket Code 6 handles the immediate live display.

### 9. MissingPluginException for shared_preferences
**Problem:** App crashed with `MissingPluginException` after adding `shared_preferences`.
**Cause:** Native plugins require a full rebuild — hot reload / hot restart is not enough.
**Fix:** Stop the app and run `flutter run` from scratch to trigger a full rebuild.

### 10. Windows Developer Mode Required
**Problem:** `flutter run` failed with a symlink permission error on Windows.
**Cause:** Flutter creates symlinks for plugin packages, which require Developer Mode on Windows.
**Fix:** Enable Developer Mode via `Settings → Privacy & Security → For Developers`.

### 11. Private Field Access Across Files
**Problem:** `ltp_screen.dart` could not access `_isDark` from `_MyAppState`.
**Cause:** Dart's `_` prefix makes fields private to the file they are declared in, not just the class.
**Fix:** Added a public getter `bool get isDark => _isDark;` in `_MyAppState`.

### 12. LIVE + Closed Labels Contradicting Each Other
**Problem:** Bottom bar showed `● LIVE` (green) while app bar showed `● Closed` (red) at the same time.
**Cause:** These are two different states — WebSocket connection status vs. market trading hours. Both were correct but looked contradictory.
**Fix:** Show `● LIVE` only when market is open AND feed is connected. Show `● Connected` when feed is active but market is closed.

### 13. Duplicate OHLC Display in Chart
**Problem:** OHLC values appeared both inside the chart (package's built-in info bar on long-press) and in a separate row outside the chart where the interval selector normally sits.
**Cause:** The external row showed stale data and had no clear purpose once the package's built-in display was working.
**Fix:** Removed the external OHLC row entirely. OHLC is now shown only inside the chart on long-press, which is the correct location.

---

## Future Considerations

### F&O (Futures & Options) Support
Dhan API supports `NSE_FNO` segment for index/stock futures and call/put options. Adding F&O would require: downloading the F&O scrip master (50,000+ instruments), an option chain UI (strike × expiry × CE/PE), and updating WebSocket subscriptions to use `NSE_FNO` exchange segment.

### Token Expiry
Dhan access tokens expire daily. The app detects 401/403 responses and shows an "Update Token" prompt, but cannot auto-refresh. Consider integrating Dhan's OAuth flow if it becomes available.

### Market Holidays
The **Market Open** badge is based purely on clock time (9:15 AM – 3:30 PM, Mon–Fri). It does not account for Indian stock market holidays.

### Credential Security
Credentials are stored using `shared_preferences` (plain-text on Android). For production use, consider `flutter_secure_storage` which uses Android Keystore / iOS Keychain.

### No Background Refresh
Prices only update while the app is in the foreground. No background service or price alerts. The WebSocket disconnects when the app is backgrounded and reconnects on foreground.

### Historical API on Weekends
When the app is opened on a weekend, the "previous close" is technically Friday's close. Consider labeling the % change as "vs Fri Close" on weekends.

### No State Management Library
The app uses `setState` and `MyApp.of(context)` for state sharing. For a larger app, adopting Riverpod or Bloc would improve maintainability.
