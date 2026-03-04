# Dhan LTP Viewer

A Flutter mobile app for viewing **live stock prices** from your [Dhan](https://dhan.co) account. Built for Indian equity markets (NSE).

---

## Features

### Live Prices
- Fetches real-time LTP (Last Traded Price) using Dhan's Market Feed API
- Auto-refreshes every **5 seconds**
- Shows **% change** from previous day's closing price
- Displays **Open, High, Low, Prev Close** on tap

### Multiple Watchlists
- Create **unlimited named watchlists** (e.g. "Nifty 50", "Bank Stocks")
- Switch between watchlists from the side drawer instantly
- Add up to **20 stocks** per watchlist
- Drag to **reorder** stocks
- Double-tap to **rename** a watchlist
- Swipe to **delete** a watchlist

### Dynamic Stock Search
- Downloads Dhan's official **scrip master CSV** on first launch
- Cached locally — re-downloads **once per day** automatically
- Always up to date with **newly listed stocks**
- Search by symbol (e.g. `HDFC`) or company name (e.g. `Infosys`)

### Market Status
- Shows **Market Open / Closed** badge in app bar
- Based on IST time: 9:15 AM – 3:30 PM, Monday–Friday

### Sort Stocks
- Best performers first (▲ % Change)
- Worst performers first (▼ % Change)
- Name A → Z

### UI & UX
- **Dark Mode** toggle (saved across sessions)
- **Pull to refresh** manually
- Modern side drawer with gradient header
- Stock detail bottom sheet on tap

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
│   └── watchlist_model.dart           # WatchlistModel data class
│
├── screens/
│   ├── token_entry_screen.dart        # Credential input screen
│   ├── ltp_screen.dart                # Main live prices screen
│   ├── watchlist_manager_screen.dart  # Create / rename / delete watchlists
│   └── watchlist_screen.dart          # Add / remove stocks in a watchlist
│
└── services/
    ├── dhan_service.dart              # Dhan API calls (OHLC, historical)
    ├── scrip_service.dart             # Scrip master download, parse, cache
    └── storage_service.dart           # SharedPreferences: credentials, watchlists, theme
```

---

## Tech Stack

| Package | Purpose |
|---|---|
| `http` | API calls to Dhan |
| `shared_preferences` | Local key-value storage |
| `path_provider` | File system access for scrip cache |
| `uuid` | Unique IDs for each watchlist |

---

## Dhan API Endpoints Used

| Endpoint | Purpose |
|---|---|
| `POST /v2/marketfeed/ohlc` | Live LTP + Open, High, Low |
| `POST /v2/charts/historical` | Previous day's closing price |
| `GET images.dhan.co/api-data/api-scrip-master.csv` | Full NSE instruments list |

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
2. App downloads the scrip master (one-time per day)
3. Default watchlist loads with 5 Nifty stocks
4. Live prices start updating every 5 seconds

---

## How It Works

### Startup Flow
```
App opens
  ↓
Load saved credentials + watchlists + theme
  ↓
Download scrip master CSV (if not cached today)
  ↓
Fetch yesterday's close for each stock (historical API)
  ↓
Start live OHLC polling every 5 seconds
```

### % Change Calculation
```
% Change = (LTP - Previous Day Close) / Previous Day Close × 100
```
Previous day close is fetched once at startup via the historical API and cached in memory for the session.

### Scrip Master Caching
```
First launch of the day  →  Download CSV from Dhan
                         →  Filter: NSE + EQUITY + EQ series only
                         →  Save as JSON to device storage
Same day relaunch        →  Load from local JSON cache (instant)
Next day                 →  Re-download fresh copy
```

---

## Rate Limits

Dhan Market Feed API allows **1 request per second**.
The app makes **1 OHLC request every 5 seconds** — well within limits.

Historical API calls at startup are staggered **400ms apart** to avoid rate limit errors.

---

## Notes

- All credentials are stored **locally on your device only**
- The scrip master is downloaded from Dhan's **official public URL** — no auth required
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
**Fix:** Consolidated to a single OHLC call and slowed the timer to 5 seconds.

### 5. % Change Showing 0% or Wrong Value
**Problem:** All stocks showed 0.00% change.
**Cause:** `ohlc.close` equals `ltp` when the market is closed — both reflect the last traded price.
**Fix:** Fetch yesterday's closing price via the historical API at startup, cache in memory, use for % calculation.

### 6. DH-905 Error from Historical API
**Problem:** Historical API returned error code DH-905 when requesting a single day's data.
**Cause:** No trading data exists for the specific date requested (e.g. weekend or holiday).
**Fix:** Fetch a 7-day range (`toDate = today - 1`, `fromDate = today - 7`) and use the last available close value.

### 7. Historical Calls Triggering Rate Limits
**Problem:** Fetching prev close for 5+ stocks at startup caused 429 errors.
**Cause:** Simultaneous historical API calls exceeded the rate limit.
**Fix:** Staggered calls 400ms apart using `Future.delayed`.

### 8. MissingPluginException for shared_preferences
**Problem:** App crashed with `MissingPluginException` after adding `shared_preferences`.
**Cause:** Native plugins require a full rebuild — hot reload / hot restart is not enough.
**Fix:** Stop the app and run `flutter run` from scratch to trigger a full rebuild.

### 9. Windows Developer Mode Required
**Problem:** `flutter run` failed with a symlink permission error on Windows.
**Cause:** Flutter creates symlinks for plugin packages, which require Developer Mode on Windows.
**Fix:** Enable Developer Mode via `Settings → Privacy & Security → For Developers`.

### 10. Private Field Access Across Files
**Problem:** `ltp_screen.dart` could not access `_isDark` from `_MyAppState`.
**Cause:** Dart's `_` prefix makes fields private to the file they are declared in, not just the class.
**Fix:** Added a public getter `bool get isDark => _isDark;` in `_MyAppState`.

---

## Future Considerations

### Token Expiry
Dhan access tokens expire daily. The app has no way to detect expiry — it simply fails to fetch prices. A future improvement would be to detect 401 responses and prompt the user to re-enter their token automatically.

### Market Holidays
The **Market Open** badge is based purely on clock time (9:15 AM – 3:30 PM, Mon–Fri). It does not account for Indian stock market holidays. A holiday calendar or a live market-status API call would make this accurate.

### Credential Security
Credentials are stored using `shared_preferences`, which saves to a plain-text XML file on Android. For production use, consider `flutter_secure_storage` which uses Android Keystore / iOS Keychain for encrypted storage.

### Large Watchlist Performance
The scrip master CSV contains ~80,000+ rows. Parsing and searching is done in-memory. On low-end devices, the initial load may be slow. A future improvement would be to move parsing to an isolate or use a local SQLite database.

### No Background Refresh
Prices only update while the app is in the foreground. There is no background service or push notification for price alerts. This is intentional (to stay within rate limits) but limits real-time monitoring use cases.

### Historical API on Weekends
When the app is opened on a weekend, the historical API returns data through Friday. This works correctly, but the "previous close" is technically 2+ days old. Consider labeling the % change as "vs Fri Close" on weekends.

### No State Management Library
The app uses `setState` and `MyApp.of(context)` for state sharing. For a larger app, adopting a proper state management solution (Provider, Riverpod, or Bloc) would improve maintainability and testability.
