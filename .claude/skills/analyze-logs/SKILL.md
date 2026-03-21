---
name: analyze-logs
description: Analyze Dhan Strategy app logs to identify errors, flow issues, stock elimination stats, and dominance/breakout results. Use when the user pastes logs, shares a log file, or asks to debug a strategy run.
argument-hint: [paste logs or provide log file path]
---

# Dhan Strategy Log Analyzer

Analyze the provided logs from the Dhan Strategy trading app. The logs may be pasted directly or provided as a file path.

## Step 1: Parse the Input

If `$ARGUMENTS` is a file path, read it with the Read tool. Otherwise, analyze the pasted log content directly from the conversation.

## Step 2: Identify Log Format

The app uses this log format:
```
YYYY-MM-DD HH:MM:SS [LEVEL] Tag: Message
```

Levels: `INFO`, `ERROR`, `WARN`, `STRAT`, `TRADE`
Tags: `App`, `BgService`, `Engine`, `Scan`, `Zone`, `StrategyList`

## Step 3: Analyze and Report

Produce a structured report with these sections:

### A. Run Summary
- **Start time** and **end time** of the strategy run
- **Config**: strategy name, mode (Paper/Live), config ID
- **Final status**: completed / stopped / error / crashed
- **Total duration** of the run

### B. Phase Timeline
Map log entries to these phases and show timestamps:
1. **Initialization** — `BgService: Configuring service`, `isolate_started`
2. **Loading Instruments** — `Step 1: Loading instruments`
3. **Pre-Market Data** — `Step 2: Loading X days of historical data`, progress lines `Pre-market progress: X/Y`
4. **Progressive Screening** — `Fetching candles for X stocks at HH:MM`, `Eliminated X stocks`, `Waiting for HH:MM candle`
5. **Dominance Screening** — `Screening for dominance candles`, `DOMINANCE FOUND`, `REJECTION SUMMARY`
6. **Breakout Monitoring** — `Monitoring LTP for X candidates`, `BREAKOUT:`
7. **Trade Execution** — `TRADE:`, order placement logs
8. **Position Monitoring** — `Monitoring open positions`
9. **Completion** — `STRATEGY ENGINE COMPLETE`, `END OF DAY SUMMARY`

### C. Stock Elimination Breakdown
Parse all `Eliminated` log lines and build a table:

| Time | Before | Eliminated | LowVol | NoData | ApiErr | After |
|------|--------|-----------|--------|--------|--------|-------|

Show the progressive reduction funnel (e.g., 408 -> 154 -> 84 -> ... -> 5).

### D. Dominance & Breakout Results
- List all `DOMINANCE FOUND` entries with symbol, entry, SL
- List all `BREAKOUT` entries
- List all `TRADE` entries with full details (symbol, qty, entry, SL, target)
- If `REJECTION SUMMARY` exists, show which rules eliminated the most candles
- If individual `REJECT` lines exist, show top 5 most-rejected stocks and their failure reasons

### E. Error Analysis
- List ALL `[ERROR]` entries
- List ALL `Zone:` error entries (uncaught exceptions)
- For each error:
  - Classify: network error, API error, parse error, auth error, timeout, other
  - If it's a `SocketException` / DNS failure: note it's a network issue
  - If it's a WebSocket reconnect loop: count how many times and note it's from DhanFeedService (UI), not the engine
  - Suggest fix or whether it's harmless

### F. Performance Metrics
- Pre-market data loading time (first progress line to last)
- API rate: approximate requests/second during screening (count fetches / time elapsed)
- Time spent waiting vs. working

### G. Issues & Recommendations
Based on the analysis:
- Flag any phases that didn't execute
- Flag if 0 candidates were found and show top rejection reasons
- Flag if engine crashed or stopped unexpectedly
- Flag any repeated errors (>3 occurrences)
- Suggest parameter tuning if rejection stats show a dominant rule
- Note if WebSocket errors are from UI (DhanFeedService) vs engine

## Output Format

Use clear headers, tables, and bullet points. Keep it concise but complete. End with a one-line verdict:
- "Clean run, no issues" OR
- "X issues found — [brief summary]"
