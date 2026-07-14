import 'package:candlesticks/candlesticks.dart';
import 'package:uuid/uuid.dart';

import '../data/nifty_tiers.dart';
import '../models/backtest_result_model.dart';
import '../models/candle_stats_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/candle_repository.dart';
import '../services/dhan_feed_service.dart';
import '../services/scrip_service.dart';
import 'base_strategy.dart';
import 'strategy_engine_context.dart';

/// One stock's opening-range setup for the day — everything computable at
/// range close (09:15 + rangeMinutes) from completed bars only. Built in
/// pass 1, ranked by relative volume, then simulated in pass 2.
class OrbSetup {
  final int securityId;
  final String symbol;
  final List<Candle> today;
  final double rangeHigh;
  final double rangeLow;
  final double rangePct; // (high−low)/mid ×100
  final double rangeVol; // total volume of the range bars
  final int barsInRange;
  final int firstPostRangeIdx; // first bar index after the range window
  final double relVol; // rangeVol ÷ N-day baseline of the same window
  final double gapPct; // today's open vs prior daily close
  final double atrPct; // daily ATR(14) as % of prev close
  final double avgDailyVol20;
  final double prevClose;
  final double pdh; // prior day high/low — "range break beyond the day level"
  final double pdl;
  final int indexTier;
  final Map<String, dynamic> trendFeatures;
  final double dayOpen; // today's 09:15 open
  /// Where the LAST range bar closed inside the range, 0 (at low) … 1 (at
  /// high). "Coiled at the break side" vs "breaking away from the far side".
  final double rangeClosePos;
  /// Net drift across the range window in range units: (last close − day
  /// open) / (high − low). Trending open vs balanced auction.
  final double rangeDrift;
  int relVolRank = 0; // 1-based rank among today's qualifying setups

  OrbSetup({
    required this.securityId,
    required this.symbol,
    required this.today,
    required this.rangeHigh,
    required this.rangeLow,
    required this.rangePct,
    required this.rangeVol,
    required this.barsInRange,
    required this.firstPostRangeIdx,
    required this.relVol,
    required this.gapPct,
    required this.atrPct,
    required this.avgDailyVol20,
    required this.prevClose,
    required this.pdh,
    required this.pdl,
    required this.indexTier,
    required this.trendFeatures,
    required this.dayOpen,
    required this.rangeClosePos,
    required this.rangeDrift,
  });
}

/// A detected breakout, pre-execution. Kept separate from the exit sim so the
/// day can order ALL breakouts chronologically and hand each trade the exact
/// tape state (how many long/short breakouts fired earlier across the
/// universe) — live-safe, since the engine watches every stock in real time.
class OrbBreakout {
  final bool isShort;
  final double entryPrice;
  final int breakoutIdx; // bar whose break signalled the trade
  final int entryIdx; // bar on which we are filled
  // Level-test texture before the break (post-range bars only, completed):
  final int touchesBeforeBreak; // came within 0.1% of the broken level
  final int oppTouches; // tests of the OPPOSITE end before the break
  // Universe tape at breakout time (strictly earlier bars):
  int tapeL = 0;
  int tapeS = 0;

  OrbBreakout({
    required this.isShort,
    required this.entryPrice,
    required this.breakoutIdx,
    required this.entryIdx,
    required this.touchesBeforeBreak,
    required this.oppTouches,
  });
}

/// A simulated ORB trade plus its research payload (excursions in R, exit
/// classification, bar path). Mirrors the LAB's LabExecutedTrade shape so the
/// offline mining tooling carries over.
class OrbExecutedTrade {
  final StrategyTradeModel trade;
  final String exitKind; // 'stop' | 'trail' | 'target' | 'time'
  final double mfeR; // max favorable excursion in R
  final double maeR; // max adverse excursion in R
  final int mfeBar;
  final int maeBar;
  final int barsHeld;
  final int breakoutIdx; // bar index whose break triggered entry
  final List<double> pathFA; // per-bar (favorable, adverse) R pairs to session end

  const OrbExecutedTrade(this.trade, this.exitKind, this.mfeR, this.maeR,
      this.mfeBar, this.maeBar, this.barsHeld, this.breakoutIdx, this.pathFA);
}

/// Opening Range Breakout — RESEARCH build (backtest-only Phase 1).
///
/// The one intraday strategy with a transparent multi-year Indian backtest
/// (IntradayLab, Nifty-50 index: PF 1.23 over 2,122 trades) — but that result
/// is on the INDEX, which cash equity can't trade. This build tests the
/// tradeable per-stock version, whose documented edge (Zarattini et al.,
/// SSRN 4729284) comes from restricting to "Stocks in Play" by relative
/// volume: filtered Sharpe 2.81 vs 0.48 unfiltered. So relVol is the one
/// default gate; every other filter starts OFF and is LOGGED for mining —
/// the same log-first methodology the hammer LAB used.
///
/// Look-ahead discipline (the C# RVOL-ORB port died as a look-ahead mirage;
/// every rule here uses only completed bars):
///   • Opening range and its volume are fixed at range close.
///   • RVOL baseline = the SAME window on prior days — fully known pre-entry.
///   • Touch entries fill at the range level (or bar open when it gaps
///     through); the breakout bar's own CLOSE/VOLUME are never entry inputs.
///   • VWAP is computed from bars strictly BEFORE the breakout bar.
///   • breakBarVolX (breakout-bar volume surge) IS logged but is flagged
///     outcome-only in touch mode — the bar is still forming at fill time.
class OrbStrategy extends BaseStrategy {
  OrbStrategy();

  @override
  String get type => 'orb';

  @override
  bool get hasCustomEngine => true;

  @override
  String get displayName => 'Opening Range Breakout (research)';

  @override
  String get description =>
      'ORB on stocks with the mined STACK defaults: 30-min range, touch '
      'entry, LONGS ONLY (shorts tape-counted + shadow-logged), relVol ≥ '
      '1.5×, skip instant breaks, ≥1% open→entry momentum, range closed on '
      'the break side, market-activity floor ≥30 universe breakouts, ATR ≥ '
      '3%, NO target, stop at 0.5× the range (failed-break cut), hold to '
      '15:20, daily loss stop −2R realized. No day trade cap. OPTION-C '
      'concentration: only setups with ≥1 conviction tilt (price<₹100 / '
      'range 3.5-5% / below SMA20). Passed the untouched 2022-23 exam '
      '(+0.132R pure OOS); Option-C book on the 4yr master: ~2.1 tr/day, '
      '₹123/trade @₹500 risk, PF 1.67, ₹258k, 17-of-17 quarters positive. '
      'Gated breakouts are Shadow-logged with would-have outcomes. Next '
      'phase: paper trading.';

  // ── Per-run state ────────────────────────────────────────────────────────
  /// Daily candles per stock (oldest first) — ATR/trend/breadth/gap context.
  final Map<int, List<Candle>> _dailyData = {};

  @override
  Map<String, dynamic> get defaultParams => {
        // Data
        'historicalDays': 12, // intraday pre-roll ≥ relVolBaselineDays
        'candleInterval': '5',
        // Opening range
        'rangeMinutes': 30.0, // 09:15–09:45 (the popular Indian default)
        'minRangePct': 0.0, // 0 = off (logged; the "skip narrow range" rule is mined, not assumed)
        'maxRangePct': 0.0, // 0 = off
        // Entry
        'allowLong': true,
        'allowShort': true, // index study: shorts made 75% of profits — measure it
        'entryOnCloseBeyond': false, // false = touch entry at the level; true = signal bar must CLOSE beyond, enter next bar open
        'lastEntryHour': 14.0, // no fresh entries at/after this time
        'lastEntryMin': 0.0,
        // ── THE STACK (mined 2026-07-08, runs 54548+3254, 2024-26). Every
        // rule is a MONOTONE trader threshold (no band-picking). Together,
        // with no target + hold to 15:20: +0.050R / PF 1.22 / 9/9 quarters
        // positive / both years positive / maxDD 15R / worst day −3R /
        // ~10 tr/day / ₹123k per 2yr @ ₹500 risk (offline path-replay —
        // the engine run verifies). Set 0 (or -1 where noted) to disable
        // any rule and reproduce the raw base. NO day trade cap — every
        // qualifying breakout is taken; only the daily loss stop halts. ──
        'minBreakoutDelayBars': 1.0, // skip instant 09:45 breaks (−0.044R both years)
        'minDayMovePct': 1.0, // break with <1% open→entry travel = fake (0/9 quarters)
        // 0.4→0.6 (mined on the 4yr master book): the 0.4-0.6 band is
        // NEGATIVE-sum over 4 years — "coiled" must mean the top 40% of the
        // range. 0.6 book: +0.170R / PF 1.50 / 17-of-17 quarters.
        'minCoilPos': 0.6,
        'maxOppTouches': 1.0, // -1 = off; skip bars whose other end was tested 2+ times first
        'minTapeTotal': 30.0, // market-activity floor (mined 20→30 on run-28473: 13/13 quarters)
        'dailyStopR': 2.0, // stop NEW entries once REALIZED day P&L <= -2R (closed trades only)
        // OPTION C (2026-07-13, user-chosen concentration): trade only
        // setups carrying >= this many of the three tilts that replicated
        // on every book (each positive-everywhere, never cuttable):
        //   price < 100  |  rangePct in [3.5, 5)  |  below 20-day SMA.
        // 1 → ~2.1 tr/day, ₹123/trade, PF 1.67, 17/17 quarters, ₹258k/4yr
        // (vs full book 3.5/day, ₹87/trade, ₹301k). 0 = off (full book).
        'requireTiltCount': 1.0,
        // Longs only (mined run-28473, 3yr): longs +0.064R/PF 1.28 vs shorts
        // +0.025R and NEGATIVE in the recent year; longs+tape30 = +0.081R /
        // PF 1.38 / 13/13 quarters. Execution-side switch — short breakouts
        // are still DETECTED and counted in the tape (turning allowShort off
        // instead would shrink the tape = the run-41234 bug class). Their
        // hypothetical results keep flowing into the Shadow log for
        // quarterly monitoring in case the short side revives.
        'tradeLongsOnly': true,
        // Research logging: simulate + log the outcome of every GATED
        // breakout (stage + features + would-have R) so future gate tuning
        // is pure offline work — no re-runs.
        'logShadowTrades': true,
        // Stocks in Play (the ONE default gate)
        'minRelVol': 1.5,
        'relVolBaselineDays': 10.0,
        'minBaselineDays': 5.0, // need ≥ this many prior days with window volume
        'topKByRelVol': 0.0, // 0 = off; >0 = trade only the top K setups per day
        // Mining filters (minAtrPct is part of the stack; rest OFF, logged)
        'minAtrPct': 3.0, // volatility floor — sub-3% ATR names drift, don't run
        'maxAtrPct': 0.0,
        'minIndexTier': 0.0, // 0=off; 50/100/200/500 like the LAB gate
        'minPrice': 0.0,
        'minAvgDailyVol': 0.0,
        'minGapAbsPct': 0.0, // 0=off; >0 = require |gap| ≥ this (catalyst proxy)
        // Exit — STACK: no target (targets cap the good days — tested, they
        // hurt), full range stop, hold to 15:20. The doc-spec 2R/14:30 is
        // reproduced with targetR=2, hardExit 14:30.
        'targetR': 0.0,
        // Stop distance as a FRACTION of the entry→range-end distance. On
        // the FILTERED book a deep retrace into the range is a FAILED
        // breakout — cut it. (On the raw unfiltered population this same
        // tightening was fatal — do not reuse outside the stack.)
        // 0.6→0.5 with coil 0.6 (4yr master book): more-coiled breaks need
        // even less retrace room — plateau 0.4-0.6 all 17/17 quarters, 0.5 =
        // mid-plateau = +0.185R / PF 1.45 / ₹327k per 4yr with the SAME
        // worst-day as 0.6. (0.4 pays more but doubles the worst day —
        // rejected.) 1.0 = classic full-range stop.
        'stopRangeFrac': 0.5,
        'stopBufferPct': 0.0, // widen stop past the opposite range end by this %
        'useTrailingStop': false, // full exit grid mined: every trail inferior
        'trailActivateR': 1.0,
        'trailGapR': 1.0,
        'hardExitHour': 15.0,
        'hardExitMin': 20.0,
        // Risk & costs
        'riskPerTrade': 500.0,
        'maxTradesPerDay': 0.0, // 0 = off (caps off for research; rank order makes any cap = top-RVOL-first)
        'maxCapitalPerTrade': 0.0, // 0 = off
        'costModelRoundTripPct': 0.10, // brokerage+STT+txn+GST+stamp+slippage, both legs
      };

  @override
  List<StrategyParamDef> get paramDefinitions => const [
        // Data
        StrategyParamDef(
          key: 'historicalDays',
          label: 'Historical days (intraday pre-roll)',
          description:
              'Days of prior intraday candles kept before each trade day. Must '
              'cover the RVOL baseline days.',
          type: ParamType.integer,
          defaultValue: 12,
          min: 3,
          max: 30,
          group: 'Data',
        ),
        // Opening range
        StrategyParamDef(
          key: 'rangeMinutes',
          label: 'Opening range minutes',
          description:
              'Range window from 09:15. 15 = fast/noisy, 30 = Indian default, '
              '45 = slow/fewest false breaks. Must be a multiple of the candle '
              'interval.',
          type: ParamType.integer,
          defaultValue: 30,
          min: 10,
          max: 60,
          unit: 'min',
          group: 'Opening Range',
        ),
        StrategyParamDef(
          key: 'minRangePct',
          label: 'Min range width %',
          description:
              'Skip stocks whose opening range is narrower than this % of '
              'price (narrow range = false-break chop). 0 = off — width is '
              'logged per trade for mining first.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 5,
          unit: '%',
          group: 'Opening Range',
        ),
        StrategyParamDef(
          key: 'maxRangePct',
          label: 'Max range width %',
          description:
              'Skip stocks whose opening range exceeds this % of price '
              '(already-exhausted wild opens). 0 = off.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 20,
          unit: '%',
          group: 'Opening Range',
        ),
        // Entry
        StrategyParamDef(
          key: 'allowLong',
          label: 'Allow long breakouts',
          description: 'Buy the break above the range high.',
          type: ParamType.boolean,
          defaultValue: true,
          group: 'Entry',
        ),
        StrategyParamDef(
          key: 'allowShort',
          label: 'Allow short breakouts',
          description:
              'Short the break below the range low (backtest simulation only '
              'in Phase 1 — no live short orders). The index ORB evidence says '
              'shorts carried 75% of profits; keep on to measure it.',
          type: ParamType.boolean,
          defaultValue: true,
          group: 'Entry',
        ),
        StrategyParamDef(
          key: 'entryOnCloseBeyond',
          label: 'Require close beyond level',
          description:
              'OFF: enter the moment price touches the level (fill at level, '
              'or bar open on gap-through). ON: the signal bar must CLOSE '
              'beyond the level and entry is the NEXT bar open — slower but '
              'immune to touch-and-fail wicks.',
          type: ParamType.boolean,
          defaultValue: false,
          group: 'Entry',
        ),
        StrategyParamDef(
          key: 'lastEntryHour',
          label: 'Last entry hour',
          description: 'No fresh entries at/after this time.',
          type: ParamType.integer,
          defaultValue: 14,
          min: 10,
          max: 15,
          group: 'Entry',
        ),
        StrategyParamDef(
          key: 'lastEntryMin',
          label: 'Last entry minute',
          description: '',
          type: ParamType.integer,
          defaultValue: 0,
          min: 0,
          max: 59,
          group: 'Entry',
        ),
        // Stack rules (each a monotone trader threshold; 0 / -1 disables)
        StrategyParamDef(
          key: 'minBreakoutDelayBars',
          label: 'Min bars after range before break',
          description:
              'Skip breakouts on the very first post-range bar — chasing the '
              'instant 09:45 break lost −0.044R in both mined years. 0 = off.',
          type: ParamType.integer,
          defaultValue: 1,
          min: 0,
          max: 12,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'minDayMovePct',
          label: 'Min open→entry move %',
          description:
              'The stock must already have travelled this far from today\'s '
              'open when the break fires. A breakout with no momentum behind '
              'it is a fake — sub-1% movers lost in 9/9 mined quarters. '
              '0 = off.',
          type: ParamType.decimal,
          defaultValue: 1.0,
          min: 0,
          max: 5,
          unit: '%',
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'minCoilPos',
          label: 'Min range-close position',
          description:
              'Where the opening range closed, measured toward the broken '
              'side (1 = right at it). Far-side breaks lost in 9/9 quarters; '
              'the 0.4-0.6 band proved negative-sum over 4 years — coiled '
              'means the TOP 40% of the range. 0 = off.',
          type: ParamType.decimal,
          defaultValue: 0.6,
          min: 0,
          max: 1,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'maxOppTouches',
          label: 'Max opposite-end tests',
          description:
              'Skip if the OTHER end of the range was tested more than this '
              'many times before the break (whipsaw bar). -1 = off.',
          type: ParamType.integer,
          defaultValue: 1,
          min: -1,
          max: 10,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'minTapeTotal',
          label: 'Min universe breakouts before entry',
          description:
              'Market-activity floor: at least this many ORB breakouts (any '
              'direction) must already have fired across the whole universe. '
              'Dead days bleed; active days pay. Live-safe — the engine '
              'watches every stock. 30 (mined) made all 13 quarters '
              'positive; 0 = off.',
          type: ParamType.integer,
          defaultValue: 30,
          min: 0,
          max: 200,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'requireTiltCount',
          label: 'Min conviction tilts',
          description:
              'Trade only setups with at least this many proven signs: '
              'price < ₹100, range width 3.5-5%, or below the 20-day SMA. '
              '1 = the Option-C book (₹123/trade, PF 1.67, 17/17 quarters). '
              '0 = off (trade every qualifying breakout).',
          type: ParamType.integer,
          defaultValue: 1,
          min: 0,
          max: 3,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'tradeLongsOnly',
          label: 'Trade longs only',
          description:
              'Skip short breakouts at EXECUTION (they still count toward '
              'the market-activity tape and still get Shadow-logged). Mined: '
              'longs +0.064R vs shorts +0.025R and negative in the recent '
              'year.',
          type: ParamType.boolean,
          defaultValue: true,
          group: 'Stack rules',
        ),
        StrategyParamDef(
          key: 'logShadowTrades',
          label: 'Log shadow trades',
          description:
              'Simulate and log the would-have-been outcome of every gated '
              'breakout (which rule blocked it + features + result). Makes '
              'future gate tuning pure offline analysis. Adds log volume, '
              'no effect on results.',
          type: ParamType.boolean,
          defaultValue: true,
          group: 'Data',
        ),
        StrategyParamDef(
          key: 'dailyStopR',
          label: 'Daily loss stop (R)',
          description:
              'Stop taking NEW entries once the day\'s REALIZED (closed) '
              'P&L reaches -this many R. Open trades keep running to their '
              'stop or time exit. Bad days cluster — this took the worst day '
              'from −21R to −3R in the mined book. 0 = off.',
          type: ParamType.decimal,
          defaultValue: 2.0,
          min: 0,
          max: 10,
          unit: 'R',
          group: 'Stack rules',
        ),
        // Stocks in Play
        StrategyParamDef(
          key: 'minRelVol',
          label: 'Min relative volume',
          description:
              'Opening-range volume ÷ average of the SAME window over the '
              'baseline days. The Zarattini result: this filter IS the edge '
              '(Sharpe 2.81 filtered vs 0.48 unfiltered). 0 = off.',
          type: ParamType.decimal,
          defaultValue: 1.5,
          min: 0,
          max: 10,
          unit: 'x',
          group: 'Stocks in Play',
        ),
        StrategyParamDef(
          key: 'relVolBaselineDays',
          label: 'RVOL baseline days',
          description: 'Prior days averaged for the opening-window baseline.',
          type: ParamType.integer,
          defaultValue: 10,
          min: 3,
          max: 20,
          group: 'Stocks in Play',
        ),
        StrategyParamDef(
          key: 'topKByRelVol',
          label: 'Top K by RVOL (0 = off)',
          description:
              'Trade only the K highest-RVOL setups each day (the literal '
              '"top-20 stocks in play" spec). Rank is logged per trade either '
              'way, so K can also be tested offline.',
          type: ParamType.integer,
          defaultValue: 0,
          min: 0,
          max: 100,
          group: 'Stocks in Play',
        ),
        StrategyParamDef(
          key: 'minAvgDailyVol',
          label: 'Min 20-day avg daily volume',
          description: 'Liquidity floor (shares/day). 0 = off, logged.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 10000000,
          group: 'Stocks in Play',
        ),
        // Mining filters
        StrategyParamDef(
          key: 'minAtrPct',
          label: 'Min daily ATR %',
          description:
              'Volatility floor — need movement to clear costs. Part of the '
              'stack (3.0): sub-3% ATR names drift instead of running. '
              '0 = off, logged (atrPct) for mining.',
          type: ParamType.decimal,
          defaultValue: 3.0,
          min: 0,
          max: 10,
          unit: '%',
          group: 'Filters (mining)',
        ),
        StrategyParamDef(
          key: 'maxAtrPct',
          label: 'Max daily ATR %',
          description: 'Volatility ceiling — skip wild names. 0 = off.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 20,
          unit: '%',
          group: 'Filters (mining)',
        ),
        StrategyParamDef(
          key: 'minIndexTier',
          label: 'Min index tier (0 = off)',
          description:
              'Universe gate by Nifty membership: 50/100/200/500. The hammer '
              'work found edges live in specific tiers — logged per trade '
              '(indexTier) so ORB\'s tier profile is mined, not assumed.',
          type: ParamType.integer,
          defaultValue: 0,
          min: 0,
          max: 500,
          group: 'Filters (mining)',
        ),
        StrategyParamDef(
          key: 'minPrice',
          label: 'Min price',
          description: 'Skip low-priced names. 0 = off.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 5000,
          unit: 'INR',
          group: 'Filters (mining)',
        ),
        StrategyParamDef(
          key: 'minGapAbsPct',
          label: 'Min |gap| %',
          description:
              'Require an overnight gap of at least this magnitude (catalyst '
              'proxy — "in play" days usually open away from prior close). '
              '0 = off, gapPct logged.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 10,
          unit: '%',
          group: 'Filters (mining)',
        ),
        // Exit
        StrategyParamDef(
          key: 'targetR',
          label: 'Target (R multiple)',
          description:
              'Fixed target at entry ± R×risk. STACK default 0 = no target '
              '(targets cap the good days — mined, they hurt). The doc spec '
              'is 2.0.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 10,
          unit: 'R',
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'stopRangeFrac',
          label: 'Stop fraction of range',
          description:
              'Stop distance as a fraction of entry→range-end. 1.0 = classic '
              'full-range stop; 0.5 (plateau centre on the coiled book) '
              'exits failed breakouts that retrace deep into the range — '
              '17/17 quarters, same worst-day as 0.6. Below ~0.35 whipsaw '
              'takes over.',
          type: ParamType.decimal,
          defaultValue: 0.5,
          min: 0.25,
          max: 1.0,
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'stopBufferPct',
          label: 'Stop buffer %',
          description:
              'Widen the stop past the opposite range end by this % of the '
              'level (whipsaw room).',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 2,
          unit: '%',
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'useTrailingStop',
          label: 'Use trailing stop',
          description:
              'Trail behind the favorable extreme once trailActivateR is '
              'reached. OFF for the base spec — trail designs get mined from '
              'the logged bar paths first.',
          type: ParamType.boolean,
          defaultValue: false,
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'trailActivateR',
          label: 'Trail activate (R)',
          description: 'Start trailing after this favorable excursion.',
          type: ParamType.decimal,
          defaultValue: 1.0,
          min: 0.1,
          max: 5,
          unit: 'R',
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'trailGapR',
          label: 'Trail gap (R)',
          description: 'Stop sits this far behind the favorable extreme.',
          type: ParamType.decimal,
          defaultValue: 1.0,
          min: 0.1,
          max: 5,
          unit: 'R',
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'hardExitHour',
          label: 'Hard exit hour',
          description:
              'Square off at this time regardless of P&L. STACK: 15:20 — '
              'holding past the doc\'s 14:30 beat it everywhere in the '
              'mined book (the drift keeps paying into the close).',
          type: ParamType.integer,
          defaultValue: 15,
          min: 10,
          max: 15,
          group: 'Exit',
        ),
        StrategyParamDef(
          key: 'hardExitMin',
          label: 'Hard exit minute',
          description: '',
          type: ParamType.integer,
          defaultValue: 20,
          min: 0,
          max: 59,
          group: 'Exit',
        ),
        // Risk & costs
        StrategyParamDef(
          key: 'riskPerTrade',
          label: 'Risk per trade',
          description: 'Position sized so a stop-out loses this amount.',
          type: ParamType.decimal,
          defaultValue: 500.0,
          min: 100,
          max: 10000,
          unit: 'INR',
          group: 'Risk & Costs',
        ),
        StrategyParamDef(
          key: 'maxTradesPerDay',
          label: 'Max trades per day (0 = off)',
          description:
              'Day cap. Setups are simulated highest-RVOL-first, so any cap '
              'means "the K most in-play stocks", not "the K earliest".',
          type: ParamType.integer,
          defaultValue: 0,
          min: 0,
          max: 100,
          group: 'Risk & Costs',
        ),
        StrategyParamDef(
          key: 'maxCapitalPerTrade',
          label: 'Max capital per trade (0 = off)',
          description: 'Skip trades whose notional exceeds this.',
          type: ParamType.decimal,
          defaultValue: 0.0,
          min: 0,
          max: 2000000,
          unit: 'INR',
          group: 'Risk & Costs',
        ),
        StrategyParamDef(
          key: 'costModelRoundTripPct',
          label: 'Round-trip cost %',
          description:
              'Brokerage + STT + exchange + GST + stamp + slippage as % of '
              'round-trip notional. All logged R-multiples are net of this.',
          type: ParamType.decimal,
          defaultValue: 0.10,
          min: 0,
          max: 1,
          unit: '%',
          group: 'Risk & Costs',
        ),
      ];

  @override
  String? diagnosisHint(String rule) {
    switch (rule) {
      case 'no_daily':
        return 'No prior daily candles — daily prep may have failed for these stocks.';
      case 'no_open_bar':
        return 'First bar is not 09:15 — intraday data hole at the open.';
      case 'insufficient_bars':
        return 'Too few intraday bars for a range + breakout walk (data hole or half-day).';
      case 'range_data_hole':
        return 'Missing bars inside the opening-range window — range/RVOL would be distorted, stock skipped.';
      case 'no_baseline':
        return 'Not enough prior days with opening-window volume for the RVOL baseline — raise historicalDays or check the cache.';
      case 'rel_vol':
        return 'Opening-range volume below minRelVol × its 10-day baseline — the stock is not "in play" today. The dominant reject by design.';
      case 'top_k':
        return 'Qualified but ranked below topKByRelVol for the day.';
      case 'range_width':
        return 'Opening range width outside [minRangePct, maxRangePct].';
      case 'both_sides_same_bar':
        return 'One bar broke BOTH range ends — direction unknowable from 5-min bars, skipped rather than guessed.';
      case 'no_breakout':
        return 'Price never left the opening range before the entry cutoff.';
      case 'late_breakout':
        return 'Breakout came at/after lastEntry time.';
      case 'qty_zero':
        return 'Range so wide (vs riskPerTrade) that even 1 share exceeds the risk budget.';
      case 'day_cap':
        return 'maxTradesPerDay reached — remaining setups skipped.';
      case 'instant_break':
        return 'Broke on the very first post-range bar — chasing the instant break lost both mined years.';
      case 'no_momentum':
        return 'Open→entry travel below minDayMovePct — a break with nothing behind it is a fake (0/9 mined quarters).';
      case 'far_side_break':
        return 'Opening range closed on the FAR side of the broken level (0/9 mined quarters).';
      case 'whipsaw_bar':
        return 'Opposite range end was tested more than maxOppTouches times before the break.';
      case 'tape_quiet':
        return 'Fewer than minTapeTotal universe breakouts had fired — dead market, no follow-through.';
      case 'daily_stop':
        return 'Realized day P&L hit -dailyStopR — no new entries for the day (open trades still managed).';
      case 'short_disabled':
        return 'Short breakout skipped (tradeLongsOnly) — still tape-counted and Shadow-logged.';
      case 'no_tilt':
        return 'Qualifying breakout without any conviction tilt (price<100 / range 3.5-5% / below SMA20) — Option-C concentration skips it; Shadow tracks what it would have done.';
      case 'skipped_capital':
        return 'Trade notional above maxCapitalPerTrade.';
      case 'gap_band':
        return '|gap| below minGapAbsPct — no overnight catalyst.';
      case 'atr_band':
        return 'Daily ATR% outside [minAtrPct, maxAtrPct].';
      case 'liquidity':
        return '20-day avg daily volume below minAvgDailyVol.';
      case 'index_tier':
        return 'Symbol below the minIndexTier universe gate.';
      case 'price':
        return 'Price below minPrice.';
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════════════
  // Custom engine: Backtest
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> prepareBacktest(BacktestPrepContext ctx) async {
    // SMA50 trend context needs ~50 trading days ≈ 70 calendar + cushion.
    final dailyStart = ctx.fromDate.subtract(const Duration(days: 95));
    ctx.log('ORB: downloading daily candles (ATR/trend/breadth) from ${_fmt(dailyStart)}...');
    final daily = await CandleRepository.instance.bulkFetchDaily(
      securityIds: ctx.securityIds,
      fromDate: dailyStart,
      toDate: ctx.toDate,
      accessToken: ctx.accessToken,
      clientId: ctx.clientId,
      onProgress: (c, t, s) {
        ctx.progress(c, t, 'Daily candles $c/$t (ATR/trend context)');
        if (c % 100 == 0 || c == t) {
          ctx.log('Daily candles: $c/$t stocks');
        }
      },
      onLog: (m) => ctx.log(m),
      isCancelled: () => ctx.isCancelled,
    );
    _dailyData
      ..clear()
      ..addAll(daily);
    ctx.log('ORB: daily candles loaded for ${_dailyData.length} stocks.');
  }

  @override
  Future<BacktestDayResult?> backtestDayAsync(BacktestDayContext ctx) async {
    final p = OrbParams(ctx.params);
    final tradeDay = DateTime.parse(ctx.dateStr);
    final barMinutes = int.tryParse(p.candleInterval) ?? 5;
    final rangeBarsWanted = p.rangeMinutes ~/ barMinutes;
    final rangeEndMin = 9 * 60 + 15 + p.rangeMinutes;

    // Market-regime snapshot, once per day, prior dailies only (live-safe).
    // ORB is regime-sensitive by the evidence (the index study's only losing
    // year was choppy 2023) — breadth is the day-type feature the mining will
    // need to test trend-day vs chop-day conditioning.
    final breadth = _dayBreadth(tradeDay);

    int stocksScanned = 0;
    final dayRejects = <String, int>{};
    void reject(String stage) =>
        dayRejects[stage] = (dayRejects[stage] ?? 0) + 1;

    // Same GC/ANR discipline as the LAB: yield to the event loop periodically
    // so a caps-off 500-stock day can't starve the GC or freeze the UI.
    const yieldEvery = 5;
    int processed = 0;

    // ── Pass 1: build setups (range + RVOL + context) for every stock ──────
    final setups = <OrbSetup>[];
    for (final secId in ctx.securityIds) {
      if (++processed % yieldEvery == 0) await Future.delayed(Duration.zero);

      final byDate = ctx.intradayByDate(secId);
      if (byDate == null) continue;
      final today = byDate[ctx.dateStr];
      // Need the full range window plus at least one bar to break out.
      if (today == null || today.length < rangeBarsWanted + 1) {
        if (today != null) reject('insufficient_bars');
        continue;
      }
      final daily = _dailyData[secId];
      final dailyBefore =
          daily?.where((c) => c.date.isBefore(tradeDay)).toList() ??
              const <Candle>[];
      if (dailyBefore.isEmpty) {
        reject('no_daily');
        continue;
      }
      stocksScanned++;

      // Data sanity: the day must start at 09:15 or the range is not the
      // opening range at all.
      final first = today.first;
      if (first.date.hour != 9 || first.date.minute != 15) {
        reject('no_open_bar');
        continue;
      }

      // Opening range from completed bars strictly inside the window.
      double rangeHigh = 0, rangeLow = double.infinity, rangeVol = 0;
      int barsInRange = 0;
      int firstPostRangeIdx = -1;
      for (int i = 0; i < today.length; i++) {
        final c = today[i];
        final m = c.date.hour * 60 + c.date.minute;
        if (m < rangeEndMin) {
          if (c.high > rangeHigh) rangeHigh = c.high;
          if (c.low < rangeLow) rangeLow = c.low;
          rangeVol += c.volume;
          barsInRange++;
        } else {
          firstPostRangeIdx = i;
          break;
        }
      }
      // Missing bars inside the window distort both the range and RVOL —
      // strict skip keeps the research data clean.
      if (barsInRange != rangeBarsWanted || firstPostRangeIdx < 0) {
        reject('range_data_hole');
        continue;
      }
      final rangeMid = (rangeHigh + rangeLow) / 2;
      final rangePct =
          rangeMid > 0 ? (rangeHigh - rangeLow) / rangeMid * 100 : 0.0;

      final scrip = ctx.scripService.findById(secId);
      final symbol = scrip?.symbol ?? secId.toString();

      // Cheap universe gates (all off by default — mining decides later).
      if (p.minPrice > 0 && first.open < p.minPrice) {
        reject('price');
        continue;
      }
      final tier = NiftyTiers.tier(symbol);
      if (p.minIndexTier > 0 && tier < p.minIndexTier) {
        reject('index_tier');
        continue;
      }
      final avgDailyVol20 = _avgDailyVolume(dailyBefore, 20);
      if (p.minAvgDailyVol > 0 && avgDailyVol20 < p.minAvgDailyVol) {
        reject('liquidity');
        continue;
      }

      final prevClose = dailyBefore.last.close;
      final gapPct = prevClose > 0
          ? (first.open - prevClose) / prevClose * 100
          : 0.0;
      if (p.minGapAbsPct > 0 && gapPct.abs() < p.minGapAbsPct) {
        reject('gap_band');
        continue;
      }
      // ATR is computed here but GATED in pass 2c — low-ATR stocks' breakouts
      // must still count toward the universe tape (mined semantics).
      final atrPct = prevClose > 0
          ? _atr14(dailyBefore) / prevClose * 100
          : 0.0;
      if (p.minRangePct > 0 && rangePct < p.minRangePct) {
        reject('range_width');
        continue;
      }
      if (p.maxRangePct > 0 && rangePct > p.maxRangePct) {
        reject('range_width');
        continue;
      }

      // RVOL baseline: total volume of the SAME opening window on prior days.
      // Completed history only — identical live. Days with window data holes
      // are excluded from the baseline the same way today would be excluded.
      final priorDates = byDate.keys
          .where((d) => d.compareTo(ctx.dateStr) < 0)
          .toList()
        ..sort();
      double baseSum = 0;
      int baseDays = 0;
      for (int di = priorDates.length - 1;
          di >= 0 && baseDays < p.relVolBaselineDays;
          di--) {
        final bars = byDate[priorDates[di]]!;
        double v = 0;
        int n = 0;
        for (final c in bars) {
          final m = c.date.hour * 60 + c.date.minute;
          if (m < rangeEndMin) {
            v += c.volume;
            n++;
          } else {
            break;
          }
        }
        if (n == rangeBarsWanted && v > 0) {
          baseSum += v;
          baseDays++;
        }
      }
      if (baseDays < p.minBaselineDays) {
        reject('no_baseline');
        continue;
      }
      final relVol = rangeVol / (baseSum / baseDays);

      // The Stocks-in-Play gate — the one default filter. Rejects in the
      // 1.0–minRelVol band are logged WITH their values so the mining can
      // study the threshold; deeper rejects are count-only (pure noise, and
      // per-stock records for them would triple the log size).
      if (p.minRelVol > 0 && relVol < p.minRelVol) {
        reject('rel_vol');
        if (relVol >= 1.0) {
          ctx.runLogInfo('Reject',
              '[${ctx.dateStr}] $symbol rel_vol: ${relVol.toStringAsFixed(2)}x < ${p.minRelVol}x',
              {
                'date': ctx.dateStr,
                'symbol': symbol,
                'stage': 'rel_vol',
                'relVol': double.parse(relVol.toStringAsFixed(2)),
                'rangePct': double.parse(rangePct.toStringAsFixed(3)),
                'gapPct': double.parse(gapPct.toStringAsFixed(2)),
                'indexTier': tier,
              });
        }
        continue;
      }

      // Range shape (completed bars only): where the auction closed inside
      // the range and its net drift — "coiled at the break side" context.
      final lastRangeClose = today[firstPostRangeIdx - 1].close;
      final rangeSpan = rangeHigh - rangeLow;
      final rangeClosePos =
          rangeSpan > 0 ? (lastRangeClose - rangeLow) / rangeSpan : 0.5;
      final rangeDrift =
          rangeSpan > 0 ? (lastRangeClose - first.open) / rangeSpan : 0.0;

      setups.add(OrbSetup(
        securityId: secId,
        symbol: symbol,
        today: today,
        rangeHigh: rangeHigh,
        rangeLow: rangeLow,
        rangePct: rangePct,
        rangeVol: rangeVol,
        barsInRange: barsInRange,
        firstPostRangeIdx: firstPostRangeIdx,
        relVol: relVol,
        gapPct: gapPct,
        atrPct: atrPct,
        avgDailyVol20: avgDailyVol20,
        prevClose: prevClose,
        pdh: dailyBefore.last.high,
        pdl: dailyBefore.last.low,
        indexTier: tier,
        trendFeatures: _trendFeatures(dailyBefore, first.open),
        dayOpen: first.open,
        rangeClosePos: rangeClosePos,
        rangeDrift: rangeDrift,
      ));
    }

    // ── Rank by RVOL (most in-play first) + optional top-K gate ────────────
    setups.sort((a, b) => b.relVol.compareTo(a.relVol));
    for (int i = 0; i < setups.length; i++) {
      setups[i].relVolRank = i + 1;
    }
    var selected = setups;
    if (p.topKByRelVol > 0 && setups.length > p.topKByRelVol) {
      for (final s in setups.skip(p.topKByRelVol)) {
        reject('top_k');
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] ${s.symbol} top_k: rank ${s.relVolRank} > ${p.topKByRelVol} (relVol ${s.relVol.toStringAsFixed(2)}x)',
            {
              'date': ctx.dateStr,
              'symbol': s.symbol,
              'stage': 'top_k',
              'relVol': double.parse(s.relVol.toStringAsFixed(2)),
              'relVolRank': s.relVolRank,
            });
      }
      selected = setups.take(p.topKByRelVol).toList();
    }

    // ── Pass 2a: detect breakouts for every selected setup ─────────────────
    final candidates = <({OrbSetup s, OrbBreakout b})>[];
    processed = 0;
    for (final s in selected) {
      if (++processed % yieldEvery == 0) await Future.delayed(Duration.zero);
      final b = _findBreakout(s, p, dayRejects, ctx);
      if (b != null) candidates.add((s: s, b: b));
    }

    // ── Pass 2b: chronological tape walk ───────────────────────────────────
    // Every stock shares the 09:15 5-min grid (range_data_hole guarantees a
    // complete open), so bar index == time bucket across stocks. Each
    // breakout is handed the universe tape as it stood STRICTLY BEFORE its
    // bar — breakouts in the same bar cannot see each other. Live-safe: the
    // engine observes all stocks' breakouts in real time.
    candidates.sort((a, c) => a.b.breakoutIdx.compareTo(c.b.breakoutIdx));
    int tapeL = 0, tapeS = 0;
    int gi = 0;
    while (gi < candidates.length) {
      int gj = gi;
      while (gj < candidates.length &&
          candidates[gj].b.breakoutIdx == candidates[gi].b.breakoutIdx) {
        gj++;
      }
      for (int k = gi; k < gj; k++) {
        candidates[k].b
          ..tapeL = tapeL
          ..tapeS = tapeS;
      }
      for (int k = gi; k < gj; k++) {
        if (candidates[k].b.isShort) {
          tapeS++;
        } else {
          tapeL++;
        }
      }
      gi = gj;
    }

    // ── Pass 2c: size + exit sim, in TIME order ────────────────────────────
    // A day cap now means "the earliest K breakouts" — what a live session
    // would actually take — instead of "the K highest-RVOL in hindsight".
    int breakouts = 0;
    final trades = <StrategyTradeModel>[];
    processed = 0;
    for (final c in candidates) {
      if (p.maxTradesPerDay > 0 && trades.length >= p.maxTradesPerDay) {
        reject('day_cap');
        continue;
      }
      // Portfolio context at this entry bar (research + daily stop):
      // realized = closed-trade R the desk would actually know; open =
      // positions still running. Logged on trades AND shadows so pileup
      // risk (the −12R day) and sequencing rules can be mined offline.
      final entryTime = c.s.today[c.b.entryIdx].date;
      double realizedR = 0;
      int openAtEntry = 0;
      for (final t in trades) {
        if (t.exitTime != null && t.exitTime!.isBefore(entryTime)) {
          realizedR += t.pnl / p.riskPerTrade;
        } else {
          openAtEntry++;
        }
      }

      // ── STACK quality gates (entry-time-safe; a gated breakout is a skip
      // for the stock's whole day — it still counted toward the tape).
      // Each gated breakout is Shadow-logged with its would-have outcome.
      String? gated;
      if (p.tradeLongsOnly && c.b.isShort) {
        gated = 'short_disabled';
      } else if (p.minAtrPct > 0 && c.s.atrPct < p.minAtrPct) {
        gated = 'atr_band';
      } else if (p.maxAtrPct > 0 && c.s.atrPct > p.maxAtrPct) {
        gated = 'atr_band';
      } else if (p.minBreakoutDelayBars > 0 &&
          c.b.breakoutIdx - c.s.firstPostRangeIdx < p.minBreakoutDelayBars) {
        gated = 'instant_break';
      } else if (p.minDayMovePct > 0 && c.s.dayOpen > 0 &&
          ((c.b.entryPrice - c.s.dayOpen) / c.s.dayOpen * 100).abs() <
              p.minDayMovePct) {
        gated = 'no_momentum';
      } else if (p.minCoilPos > 0 &&
          (c.b.isShort ? 1 - c.s.rangeClosePos : c.s.rangeClosePos) <
              p.minCoilPos) {
        gated = 'far_side_break';
      } else if (p.maxOppTouches >= 0 && c.b.oppTouches > p.maxOppTouches) {
        gated = 'whipsaw_bar';
      } else if (p.minTapeTotal > 0 &&
          c.b.tapeL + c.b.tapeS < p.minTapeTotal) {
        // Market-activity floor — uses the RAW tape strictly before this
        // bar; all breakouts count, including gate-skipped ones.
        gated = 'tape_quiet';
      } else if (p.requireTiltCount > 0 &&
          _tiltCount(c.s, c.b) < p.requireTiltCount) {
        // Option C: concentration on the three replicated conviction tilts.
        gated = 'no_tilt';
      } else if (p.dailyStopR > 0 && realizedR <= -p.dailyStopR) {
        // Daily loss stop on a REALIZED basis — exactly what live can know.
        gated = 'daily_stop';
      }
      if (gated != null) {
        reject(gated);
        if (p.logShadowTrades) _logShadow(ctx, c.s, c.b, gated, p, realizedR);
        continue;
      }

      if (++processed % yieldEvery == 0) await Future.delayed(Duration.zero);
      breakouts++;

      final exec = _executeExit(c.s, c.b, p, dayRejects, ctx);
      if (exec == null) continue;
      final trade = exec.trade;

      // Capital cap — mirrors the orchestrator (skipped, not counted).
      final capital = trade.quantity * trade.entryPrice;
      if (p.maxCapitalPerTrade > 0 && capital > p.maxCapitalPerTrade) {
        reject('skipped_capital');
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] ${c.s.symbol} skipped_capital: ₹${capital.toStringAsFixed(0)} > max ₹${p.maxCapitalPerTrade.toStringAsFixed(0)}',
            {'date': ctx.dateStr, 'symbol': c.s.symbol, 'stage': 'skipped_capital'});
        continue;
      }

      trades.add(trade);
      _logTradeRecord(ctx, c.s, c.b, exec, p, breadth,
          tradeSeq: trades.length,
          openAtEntry: openAtEntry,
          realizedAtEntry: realizedR);
    }

    final dayWins = trades.where((t) => t.pnl > 0).length;
    final dayLosses = trades.where((t) => t.pnl < 0).length;
    final dayPnl = trades.fold<double>(0, (sum, t) => sum + t.pnl);
    final longs = trades.where((t) => !t.isShort).length;
    ctx.log('DAY SUMMARY [${ctx.dateStr}]: Scanned=$stocksScanned InPlay=${setups.length} Breakouts=$breakouts Trades=${trades.length} (L=$longs/S=${trades.length - longs}) W=$dayWins L=$dayLosses PnL=₹${dayPnl.toStringAsFixed(0)}');
    // Per-day structured summary — the day-clustering mining (which days work
    // for breakouts?) reads these instead of re-aggregating trade records.
    ctx.runLogInfo('DaySummary', 'ORB day ${ctx.dateStr}', {
      'date': ctx.dateStr,
      'scanned': stocksScanned,
      'inPlay': setups.length,
      'breakouts': breakouts,
      'trades': trades.length,
      'longs': longs,
      'shorts': trades.length - longs,
      'wins': dayWins,
      'losses': dayLosses,
      'pnl': double.parse(dayPnl.toStringAsFixed(0)),
      ...breadth,
      'rejects': dayRejects,
    });

    if (trades.isEmpty && dayRejects.isNotEmpty) {
      final sorted = dayRejects.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = sorted.first;
      ctx.runLogWarn('Diagnosis',
          'WHY ZERO [${ctx.dateStr}]: scanned=$stocksScanned inPlay=${setups.length}. Dominant reject: ${top.key} (${top.value}×). ${diagnosisHint(top.key) ?? ""}',
          {'date': ctx.dateStr, 'rejects': dayRejects});
    }

    return BacktestDayResult(
      date: ctx.dateStr,
      stocksScanned: stocksScanned,
      stocksAfterElimination: setups.length,
      dominanceSignals: breakouts,
      tradesEntered: trades.length,
      wins: dayWins,
      losses: dayLosses,
      dayPnl: dayPnl,
      trades: trades,
    );
  }

  /// Walk the post-range bars for the first allowed breakout. Returns the
  /// detected breakout (with level-test texture) or null with a reject
  /// recorded. No sizing/exit here — the day tape is assembled between
  /// detection and execution.
  OrbBreakout? _findBreakout(OrbSetup s, OrbParams p,
      Map<String, int> dayRejects, BacktestDayContext ctx) {
    void reject(String stage) =>
        dayRejects[stage] = (dayRejects[stage] ?? 0) + 1;

    final today = s.today;
    final lastEntry = p.lastEntryHour * 60 + p.lastEntryMin;
    final hardExit = p.hardExitHour * 60 + p.hardExitMin;

    bool isShort = false;
    double entryPrice = 0;
    int breakoutIdx = -1; // bar whose break signalled the trade
    int entryIdx = -1; // bar on which we are filled

    for (int i = s.firstPostRangeIdx; i < today.length; i++) {
      final c = today[i];
      final m = c.date.hour * 60 + c.date.minute;
      if (m >= lastEntry || m >= hardExit) {
        reject('no_breakout');
        return null;
      }

      final longHit = p.allowLong && c.high > s.rangeHigh;
      final shortHit = p.allowShort && c.low < s.rangeLow;

      if (p.entryOnCloseBeyond) {
        // Close-confirm mode: the signal bar must CLOSE beyond the level;
        // entry is the NEXT bar's open — every input is a completed bar.
        final longClose = p.allowLong && c.close > s.rangeHigh;
        final shortClose = p.allowShort && c.close < s.rangeLow;
        if (longClose || shortClose) {
          if (i + 1 >= today.length) {
            reject('no_breakout');
            return null;
          }
          final nm =
              today[i + 1].date.hour * 60 + today[i + 1].date.minute;
          if (nm >= lastEntry || nm >= hardExit) {
            reject('late_breakout');
            return null;
          }
          isShort = shortClose;
          breakoutIdx = i;
          entryIdx = i + 1;
          entryPrice = today[i + 1].open;
          break;
        }
      } else {
        // Touch mode: filled at the level itself, or at the bar's open when
        // it gaps through the level. A bar that pierces BOTH ends is
        // direction-unknowable from OHLC — skip rather than guess (the
        // honest call; count is logged to size the ambiguity).
        if (longHit && shortHit) {
          reject('both_sides_same_bar');
          ctx.runLogInfo('Reject',
              '[${ctx.dateStr}] ${s.symbol} both_sides_same_bar: bar ${_hm(c.date)} H=${c.high} L=${c.low} spans the whole range',
              {
                'date': ctx.dateStr,
                'symbol': s.symbol,
                'stage': 'both_sides_same_bar',
                'relVol': double.parse(s.relVol.toStringAsFixed(2)),
                'rangePct': double.parse(s.rangePct.toStringAsFixed(3)),
              });
          return null;
        }
        if (longHit || shortHit) {
          isShort = shortHit;
          breakoutIdx = i;
          entryIdx = i;
          entryPrice = isShort
              ? (c.open < s.rangeLow ? c.open : s.rangeLow)
              : (c.open > s.rangeHigh ? c.open : s.rangeHigh);
          break;
        }
      }
    }
    if (entryIdx < 0) {
      reject('no_breakout');
      return null;
    }

    // Level-test texture before the break (completed bars only): how many
    // post-range bars came within 0.1% of the broken level ("3rd test
    // breaks cleaner" lore) and how many tested the OPPOSITE end first
    // (failed move at one end fueling the break of the other).
    int touches = 0, opp = 0;
    for (int j = s.firstPostRangeIdx; j < breakoutIdx; j++) {
      final c = today[j];
      final nearHigh = c.high >= s.rangeHigh * 0.999;
      final nearLow = c.low <= s.rangeLow * 1.001;
      if (isShort) {
        if (nearLow) touches++;
        if (nearHigh) opp++;
      } else {
        if (nearHigh) touches++;
        if (nearLow) opp++;
      }
    }

    // NOTE: the stack quality gates are deliberately NOT applied here.
    // Detection must return every raw breakout so the universe tape
    // (tapeL/tapeS) counts ALL market activity — the activity floor was
    // mined against the raw tape. Gates run in pass 2c, after tape
    // assignment. (Applying them here silently shrank the tape and
    // strangled the whole day — the run-41234 bug.)
    return OrbBreakout(
      isShort: isShort,
      entryPrice: entryPrice,
      breakoutIdx: breakoutIdx,
      entryIdx: entryIdx,
      touchesBeforeBreak: touches,
      oppTouches: opp,
    );
  }

  /// Size the position and simulate the exit for a detected breakout.
  /// Conservative same-bar rule throughout (stop checked before target —
  /// same as the hammer engines).
  OrbExecutedTrade? _executeExit(OrbSetup s, OrbBreakout b, OrbParams p,
      Map<String, int> dayRejects, BacktestDayContext ctx) {
    void reject(String stage) =>
        dayRejects[stage] = (dayRejects[stage] ?? 0) + 1;

    final today = s.today;
    final hardExit = p.hardExitHour * 60 + p.hardExitMin;
    final isShort = b.isShort;
    final entryPrice = b.entryPrice;
    final entryIdx = b.entryIdx;

    // ── Size the position ───────────────────────────────────────────────
    // Base stop = the classic opposite range end (± buffer); the final stop
    // sits stopRangeFrac of the way there from entry (0.6 mined — a quality
    // breakout that retraces that deep has failed). Same formula both
    // directions: for shorts (entryPrice − baseStop) is negative.
    final baseStop = isShort
        ? s.rangeHigh * (1 + p.stopBufferPct / 100)
        : s.rangeLow * (1 - p.stopBufferPct / 100);
    final stopLoss = entryPrice - p.stopRangeFrac * (entryPrice - baseStop);
    final risk = (entryPrice - stopLoss).abs();
    if (risk <= 0) {
      reject('qty_zero');
      return null;
    }
    final quantity = (p.riskPerTrade / risk).floor();
    if (quantity <= 0) {
      reject('qty_zero');
      ctx.runLogInfo('Reject',
          '[${ctx.dateStr}] ${s.symbol} qty_zero: risk/share ₹${risk.toStringAsFixed(2)} > budget ₹${p.riskPerTrade.toStringAsFixed(0)}',
          {
            'date': ctx.dateStr,
            'symbol': s.symbol,
            'stage': 'qty_zero',
            'rangePct': double.parse(s.rangePct.toStringAsFixed(3)),
            'price': entryPrice,
          });
      return null;
    }
    final dir = isShort ? -1.0 : 1.0;
    final target =
        p.targetR > 0 ? entryPrice + dir * p.targetR * risk : null;

    // ── Exit walk (conservative same-bar: stop → target → time) ────────
    var effectiveStop = stopLoss;
    var favWater = entryPrice; // high-water for longs, low-water for shorts
    double favR(double px) => dir * (px - entryPrice) / risk;
    double favExtreme(Candle c) => isShort ? c.low : c.high;
    double advExtreme(Candle c) => isShort ? c.high : c.low;

    var mfe = 0.0, mae = 0.0;
    var mfeBar = 0, maeBar = 0;
    final pathFA = <double>[];

    StrategyTradeModel build(Candle exitBar, double exitPx, TradeOutcome outcome) =>
        StrategyTradeModel(
          id: const Uuid().v4(),
          strategyConfigId: 'backtest',
          signalId: const Uuid().v4(),
          securityId: s.securityId,
          symbol: s.symbol,
          status: TradeStatus.closed,
          isPaperTrade: true,
          entryPrice: entryPrice,
          quantity: quantity,
          entryTime: today[entryIdx].date,
          exitPrice: exitPx,
          exitTime: exitBar.date,
          outcome: outcome,
          stopLoss: stopLoss,
          target: target ?? 0,
          costModelPct: p.costModelRoundTripPct,
          isShort: isShort,
        );

    ({int idx, Candle bar, double px, TradeOutcome outcome, String kind})? exit;

    for (int i = entryIdx; i < today.length; i++) {
      final c = today[i];
      final fR = favR(favExtreme(c));
      final aR = -favR(advExtreme(c));
      if (fR > mfe) {
        mfe = fR;
        mfeBar = i - entryIdx;
      }
      if (aR > mae) {
        mae = aR;
        maeBar = i - entryIdx;
      }

      if (exit == null) {
        // 1. Protective / trailing stop first (conservative on same-bar).
        final stopHit =
            isShort ? c.high >= effectiveStop : c.low <= effectiveStop;
        if (stopHit) {
          final trailed = isShort
              ? effectiveStop < stopLoss
              : effectiveStop > stopLoss;
          exit = (
            idx: i,
            bar: c,
            px: effectiveStop,
            outcome: TradeOutcome.stopLoss,
            kind: trailed ? 'trail' : 'stop'
          );
        }
        // 2. Fixed R target.
        else if (target != null &&
            (isShort ? c.low <= target : c.high >= target)) {
          exit = (
            idx: i,
            bar: c,
            px: target,
            outcome: TradeOutcome.target,
            kind: 'target'
          );
        }
        // 3. Hard time exit.
        else {
          final m = c.date.hour * 60 + c.date.minute;
          if (m >= hardExit) {
            exit = (
              idx: i,
              bar: c,
              px: c.close,
              outcome: TradeOutcome.endOfDay,
              kind: 'time'
            );
          }
        }
        // 4. Update favorable-water + trail for the NEXT bar (no intrabar peek).
        if (exit == null && p.useTrailingStop) {
          final fx = favExtreme(c);
          if (dir * (fx - favWater) > 0) favWater = fx;
          if (dir * (favWater - entryPrice) >= p.trailActivateR * risk) {
            final trailed = favWater - dir * p.trailGapR * risk;
            if (dir * (trailed - effectiveStop) > 0) effectiveStop = trailed;
          }
        }
      }

      // Bar path in FAVORABLE orientation (fav first, adverse second) to
      // session end — past the recorded exit ON PURPOSE, so alternative
      // exits (other targets, earlier trails, later time exits) replay
      // exactly offline instead of being estimated from MFE summaries — the
      // estimate-mirage the hammer LAB's first trail number died of.
      pathFA
        ..add(double.parse(fR.toStringAsFixed(2)))
        ..add(double.parse((-aR).toStringAsFixed(2)));
    }

    // Truncated session (data ends before hard exit): close on the last bar
    // rather than silently dropping an entered trade.
    exit ??= (
      idx: today.length - 1,
      bar: today.last,
      px: today.last.close,
      outcome: TradeOutcome.endOfDay,
      kind: 'time'
    );

    return OrbExecutedTrade(
      build(exit.bar, exit.px, exit.outcome),
      exit.kind,
      mfe,
      mae,
      mfeBar,
      maeBar,
      exit.idx - entryIdx,
      b.breakoutIdx,
      pathFA,
    );
  }

  /// Compact record for a GATED breakout: which rule blocked it, its
  /// entry-time features, and the outcome it WOULD have had — so every
  /// gate's true cost/benefit is measurable offline, quarterly, without
  /// ever re-running with the gate off. No bar path (size).
  void _logShadow(BacktestDayContext ctx, OrbSetup s, OrbBreakout b,
      String stage, OrbParams p, double realizedAtEntry) {
    // Throwaway rejects map: a shadow's qty_zero etc. must not pollute the
    // real day counters.
    final scratch = <String, int>{};
    final exec = _executeExit(s, b, p, scratch, ctx);
    final dirLabel = b.isShort ? 'S' : 'L';
    ctx.runLogInfo(
      'Shadow',
      'Shadow: ${s.symbol} ${ctx.dateStr} $dirLabel $stage',
      {
        'date': ctx.dateStr,
        'symbol': s.symbol,
        'direction': dirLabel,
        'stage': stage,
        'entryTime': _hm(s.today[b.entryIdx].date),
        'relVol': double.parse(s.relVol.toStringAsFixed(2)),
        'rangePct': double.parse(s.rangePct.toStringAsFixed(3)),
        'atrPct': double.parse(s.atrPct.toStringAsFixed(2)),
        'gapPct': double.parse(s.gapPct.toStringAsFixed(2)),
        'indexTier': s.indexTier,
        'price': b.entryPrice,
        'dayMovePct': s.dayOpen > 0
            ? double.parse(((b.entryPrice - s.dayOpen) / s.dayOpen * 100)
                .toStringAsFixed(2))
            : 0,
        'coilPos': double.parse(
            (b.isShort ? 1 - s.rangeClosePos : s.rangeClosePos)
                .toStringAsFixed(2)),
        'oppTouches': b.oppTouches,
        'delayBars': b.breakoutIdx - s.firstPostRangeIdx,
        'tapeL': b.tapeL,
        'tapeS': b.tapeS,
        'realizedAtEntry': double.parse(realizedAtEntry.toStringAsFixed(2)),
        'tiltCount': _tiltCount(s, b),
        // The would-have outcome (null exec = would never have filled/sized).
        'wouldExitKind': exec?.exitKind,
        'wouldR': exec != null
            ? double.parse((exec.trade.pnl / p.riskPerTrade).toStringAsFixed(3))
            : null,
        'wouldMfeR': exec != null
            ? double.parse(exec.mfeR.toStringAsFixed(2))
            : null,
      },
    );
  }

  /// One structured record per trade with every feature the offline mining
  /// needs — entry-time-safe context, outcome, and the full bar path.
  void _logTradeRecord(BacktestDayContext ctx, OrbSetup s, OrbBreakout b,
      OrbExecutedTrade exec, OrbParams p, Map<String, dynamic> breadth,
      {required int tradeSeq,
      required int openAtEntry,
      required double realizedAtEntry}) {
    final t = exec.trade;
    final today = s.today;
    final bo = today[exec.breakoutIdx];
    final risk = (t.entryPrice - t.stopLoss).abs();
    final rangeEndIdx = s.firstPostRangeIdx;

    // VWAP from completed bars BEFORE the breakout bar (live-safe): which
    // side of institutional fair value did the break come from?
    double pv = 0, vv = 0;
    for (int j = 0; j < exec.breakoutIdx; j++) {
      final c = today[j];
      final tp = (c.high + c.low + c.close) / 3;
      pv += tp * c.volume;
      vv += c.volume;
    }
    final vwap = vv > 0 ? pv / vv : 0.0;

    // Volume texture around the break. avgRangeBarVol is the denominator.
    final avgRangeBarVol =
        s.barsInRange > 0 ? s.rangeVol / s.barsInRange : 0.0;
    // Bar BEFORE the breakout bar — completed at entry, live-safe.
    final priorBar =
        exec.breakoutIdx > 0 ? today[exec.breakoutIdx - 1] : null;
    final priorBarVolX = priorBar != null && avgRangeBarVol > 0
        ? priorBar.volume / avgRangeBarVol
        : 0.0;
    // Breakout bar's own volume: in touch mode the bar is STILL FORMING at
    // fill time, so this is OUTCOME data (mine it only as confirmation-mode
    // research, never as a touch-mode entry filter — that exact look-ahead
    // sank the C# RVOL-ORB port). In close-confirm mode it IS entry-safe.
    final breakBarVolX =
        avgRangeBarVol > 0 ? bo.volume / avgRangeBarVol : 0.0;

    final dirLabel = t.isShort ? 'S' : 'L';
    ctx.runLogInfo(
      'Trade',
      'Trade record: ${t.symbol} ${ctx.dateStr} $dirLabel ${exec.exitKind} ₹${t.pnl.toStringAsFixed(0)}',
      {
        'date': ctx.dateStr,
        'symbol': t.symbol,
        'securityId': t.securityId,
        'direction': dirLabel,
        // ── Setup (entry-time-safe) ──
        'rangeHigh': s.rangeHigh,
        'rangeLow': s.rangeLow,
        'rangePct': double.parse(s.rangePct.toStringAsFixed(3)),
        'rangeVol': double.parse(s.rangeVol.toStringAsFixed(0)),
        'relVol': double.parse(s.relVol.toStringAsFixed(2)),
        'relVolRank': s.relVolRank,
        'gapPct': double.parse(s.gapPct.toStringAsFixed(3)),
        'atrPct': double.parse(s.atrPct.toStringAsFixed(3)),
        'avgDailyVol': double.parse(s.avgDailyVol20.toStringAsFixed(0)),
        'indexTier': s.indexTier,
        'prevClose': s.prevClose,
        // Break vs the prior DAY's levels: a range break that also clears
        // PDH/PDL is a two-level break (classic continuation confluence).
        'pdhDistPct': s.pdh > 0
            ? double.parse(
                ((t.entryPrice - s.pdh) / s.pdh * 100).toStringAsFixed(3))
            : 0,
        'pdlDistPct': s.pdl > 0
            ? double.parse(
                ((t.entryPrice - s.pdl) / s.pdl * 100).toStringAsFixed(3))
            : 0,
        // VWAP side/distance at break (completed bars only): >0 = entry above
        // VWAP. For longs above VWAP = with institutional flow.
        'vwapDistPct': vwap > 0
            ? double.parse(
                ((t.entryPrice - vwap) / vwap * 100).toStringAsFixed(3))
            : 0,
        // Breakout timing: bars waited after range close before the break.
        // Early breaks = momentum; late breaks = midday drift (folklore says
        // the edge dies after ~10:30 — this field tests that).
        'breakoutDelayBars': exec.breakoutIdx - rangeEndIdx,
        'breakoutTime': _hm(bo.date),
        // Level-test texture before the break (completed bars only).
        'touchesBeforeBreak': b.touchesBeforeBreak,
        'oppTouches': b.oppTouches,
        // Range shape: where the auction closed inside the range (0=low,
        // 1=high) and its net drift in range units — coiled-spring context.
        'rangeClosePos': double.parse(s.rangeClosePos.toStringAsFixed(2)),
        'rangeDrift': double.parse(s.rangeDrift.toStringAsFixed(2)),
        // How far the stock already travelled open→entry (chase detector).
        'dayMovePct': s.dayOpen > 0
            ? double.parse(((t.entryPrice - s.dayOpen) / s.dayOpen * 100)
                .toStringAsFixed(3))
            : 0,
        // Universe tape strictly before this breakout's bar (engine-exact,
        // live-safe): long vs short breakouts fired earlier today.
        'tapeL': b.tapeL,
        'tapeS': b.tapeS,
        // Conviction tilts carried (0-3) — sizing research + Option-C audit.
        'tiltCount': _tiltCount(s, b),
        // Portfolio context at entry (research: pileup/sequencing rules).
        'tradeSeq': tradeSeq, // 1 = first kept trade of the day
        'openAtEntry': openAtEntry, // positions still running at this entry
        'realizedAtEntry':
            double.parse(realizedAtEntry.toStringAsFixed(2)), // closed-day R
        'priorBarVolX': double.parse(priorBarVolX.toStringAsFixed(2)),
        // OUTCOME-ONLY in touch mode (bar forming at fill) — see comment.
        'breakBarVolX': double.parse(breakBarVolX.toStringAsFixed(2)),
        'dow': DateTime.parse(ctx.dateStr).weekday, // index study: Friday = 40% of returns
        // Daily trend context (prior dailies): with-trend vs counter-trend break.
        ...s.trendFeatures,
        // Market-regime snapshot (trend day vs chop day — ORB's known regime risk).
        ...breadth,
        // ── Execution ──
        'entryTime': _hm(t.entryTime!),
        'entryPrice': t.entryPrice,
        'qty': t.quantity,
        'stopLoss': t.stopLoss,
        'stopPct':
            double.parse((risk / t.entryPrice * 100).toStringAsFixed(4)),
        'targetR': p.targetR,
        // ── Outcome ──
        'exitKind': exec.exitKind,
        'exitTime': _hm(t.exitTime!),
        'exitPrice': t.exitPrice,
        'pnl': double.parse(t.pnl.toStringAsFixed(2)),
        'rMult': double.parse((t.pnl / p.riskPerTrade).toStringAsFixed(3)),
        'mfeR': double.parse(exec.mfeR.toStringAsFixed(3)),
        'maeR': double.parse(exec.maeR.toStringAsFixed(3)),
        'mfeBar': exec.mfeBar,
        'maeBar': exec.maeBar,
        'barsHeld': exec.barsHeld,
        // Favorable-oriented (fav,adv) R pairs per bar to session end.
        'pathFA': exec.pathFA,
      },
    );
    ctx.log(
        'TRADE [${ctx.dateStr} ${_hm(t.entryTime!)}]: ${t.symbol} $dirLabel Entry=${t.entryPrice.toStringAsFixed(2)} Qty=${t.quantity} SL=${t.stopLoss.toStringAsFixed(2)}${t.target > 0 ? " Tgt=${t.target.toStringAsFixed(2)}" : ""} relVol=${s.relVol.toStringAsFixed(1)}x → ${exec.exitKind} Exit=${t.exitPrice?.toStringAsFixed(2)} P&L=₹${t.pnl.toStringAsFixed(0)}');
  }

  // ════════════════════════════════════════════════════════════════════════
  // Custom engine: Live / Paper — Phase 2 (after the edge passes IS + OOS)
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> runLive(LiveEngineContext ctx) async {
    ctx.log('ORB is Phase 1 (backtest research only) — the live/paper session '
        'is not implemented yet. Run it from the Backtest screen instead.');
    ctx.sendUpdate('update', {
      'status': 'stopped',
      'message': 'ORB: backtest-only research build — no live session yet.',
    });
  }

  /// Conviction tilts (each replicated positive-everywhere on every mined
  /// book): cheap stock, sweet-spot range width, beaten-down breakout.
  /// Entry-time-safe: price is the fill, the rest are setup fields.
  static int _tiltCount(OrbSetup s, OrbBreakout b) {
    int n = 0;
    if (b.entryPrice < 100) n++;
    if (s.rangePct >= 3.5 && s.rangePct < 5) n++;
    if (s.trendFeatures['aboveSma20'] == false) n++;
    return n;
  }

  // ── Feature helpers (entry-time-safe — prior/completed data only) ────────

  /// Simple 14-day average true range from prior daily candles.
  static double _atr14(List<Candle> daily) {
    if (daily.length < 2) return 0;
    final start = daily.length - 15 < 1 ? 1 : daily.length - 15;
    double sum = 0;
    int cnt = 0;
    for (int j = start; j < daily.length; j++) {
      final h = daily[j].high, l = daily[j].low, pc = daily[j - 1].close;
      var tr = h - l;
      final hc = (h - pc).abs(), lc = (l - pc).abs();
      if (hc > tr) tr = hc;
      if (lc > tr) tr = lc;
      sum += tr;
      cnt++;
    }
    return cnt > 0 ? sum / cnt : 0;
  }

  static double _avgDailyVolume(List<Candle> daily, int days) {
    if (daily.isEmpty) return 0;
    final s = daily.length - days < 0 ? 0 : daily.length - days;
    double sum = 0;
    int cnt = 0;
    for (int j = s; j < daily.length; j++) {
      sum += daily[j].volume;
      cnt++;
    }
    return cnt > 0 ? sum / cnt : 0;
  }

  /// Universe-wide market-breadth snapshot for [tradeDay] from PRIOR daily
  /// candles only (live-safe — computable pre-market). Same fields as the
  /// hammer LAB so the day-type mining tooling carries over unchanged.
  Map<String, dynamic> _dayBreadth(DateTime tradeDay) {
    int above = 0, counted = 0, retCnt = 0;
    double retSum = 0;
    for (final daily in _dailyData.values) {
      int end = daily.length;
      while (end > 0 && !daily[end - 1].date.isBefore(tradeDay)) {
        end--;
      }
      if (end < 21) continue;
      final last = daily[end - 1].close;
      double sum = 0;
      for (int j = end - 20; j < end; j++) {
        sum += daily[j].close;
      }
      final sma20 = sum / 20;
      if (sma20 > 0) {
        counted++;
        if (last > sma20) above++;
      }
      final past = daily[end - 6].close;
      if (past > 0) {
        retSum += (last - past) / past * 100;
        retCnt++;
      }
    }
    return {
      'breadthAbove20Pct': counted > 0
          ? double.parse((100 * above / counted).toStringAsFixed(1))
          : -1,
      'breadthRet5dPct': retCnt > 0
          ? double.parse((retSum / retCnt).toStringAsFixed(2))
          : 0,
      'breadthN': counted,
    };
  }

  /// Daily trend context (prior dailies + today's open only). Field names
  /// match the hammer LAB so cross-strategy mining scripts reuse cleanly.
  /// For ORB the question inverts: breakouts should be TREND-continuation —
  /// does aboveSma20 help here where it hurt the reversion strategies?
  static Map<String, dynamic> _trendFeatures(List<Candle> daily, double price) {
    double sma(int n) {
      if (daily.isEmpty) return 0;
      final s = daily.length - n < 0 ? 0 : daily.length - n;
      double sum = 0;
      int cnt = 0;
      for (int j = s; j < daily.length; j++) {
        sum += daily[j].close;
        cnt++;
      }
      return cnt > 0 ? sum / cnt : 0;
    }

    double smaBack(int n, int backFromEnd) {
      final end = daily.length - backFromEnd;
      if (end <= 0) return 0;
      final s = end - n < 0 ? 0 : end - n;
      double sum = 0;
      int cnt = 0;
      for (int j = s; j < end; j++) {
        sum += daily[j].close;
        cnt++;
      }
      return cnt > 0 ? sum / cnt : 0;
    }

    double ret(int n) {
      if (daily.length <= n) return 0;
      final past = daily[daily.length - 1 - n].close;
      final last = daily.last.close;
      return past > 0 ? (last - past) / past * 100 : 0;
    }

    final sma20 = sma(20), sma50 = sma(50), sma20Prev = smaBack(20, 5);
    return {
      'sma20DistPct': sma20 > 0
          ? double.parse(((price - sma20) / sma20 * 100).toStringAsFixed(2))
          : 0,
      'sma50DistPct': sma50 > 0
          ? double.parse(((price - sma50) / sma50 * 100).toStringAsFixed(2))
          : 0,
      'aboveSma20': sma20 > 0 && price > sma20,
      'aboveSma50': sma50 > 0 && price > sma50,
      'smaStack': sma20 > 0 && sma50 > 0 && sma20 > sma50,
      'sma20Rising': sma20 > 0 && sma20Prev > 0 && sma20 > sma20Prev,
      'stockRet5d': double.parse(ret(5).toStringAsFixed(2)),
      'stockRet20d': double.parse(ret(20).toStringAsFixed(2)),
    };
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';

  // ── BaseStrategy pipeline (unused — custom engine drives everything) ─────

  @override
  Future<Map<int, CandleStatsModel>> prepare({
    required List<int> securityIds,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Future<List<Candle>> Function(int securityId, String interval,
            {DateTime? date})
        fetchIntraday,
    required void Function(int completed, int total) onProgress,
  }) async =>
      {};

  @override
  List<StrategySignalModel> scan({
    required String configId,
    required Map<int, CandleStatsModel> stats,
    required Map<int, List<Candle>> todayCandles,
    required Map<String, dynamic> params,
    required ScripService scripService,
    required Set<int> alreadySignalled,
    void Function(String message)? debugLog,
    void Function(ScanReport report)? onScanReport,
    void Function(StockRejectEvent event)? onStockReject,
  }) =>
      const [];

  @override
  StrategyTradeModel? checkBreakout({
    required FeedUpdate tick,
    required int securityId,
    required List<StrategySignalModel> activeSignals,
    required Map<String, dynamic> params,
    required int tradesPlacedToday,
    required bool isPaperTrade,
    required String configId,
  }) =>
      null;

  @override
  StrategyTradeModel? checkExit({
    required FeedUpdate tick,
    required StrategyTradeModel trade,
  }) =>
      null;
}

/// Typed accessor for ORB params.
class OrbParams {
  final Map<String, dynamic> _m;
  OrbParams(this._m);

  double _d(String k, double def) => (_m[k] as num?)?.toDouble() ?? def;
  int _i(String k, int def) => (_m[k] as num?)?.toInt() ?? def;
  bool _b(String k, bool def) => _m[k] as bool? ?? def;

  // Data
  String get candleInterval => _m['candleInterval'] as String? ?? '5';
  // Opening range
  int get rangeMinutes => _i('rangeMinutes', 30);
  double get minRangePct => _d('minRangePct', 0.0);
  double get maxRangePct => _d('maxRangePct', 0.0);
  // Entry
  bool get allowLong => _b('allowLong', true);
  bool get allowShort => _b('allowShort', true);
  bool get entryOnCloseBeyond => _b('entryOnCloseBeyond', false);
  int get lastEntryHour => _i('lastEntryHour', 14);
  int get lastEntryMin => _i('lastEntryMin', 0);
  // Stack rules (0 / -1 = off; missing key falls back to OFF so configs
  // saved before the stack behave as they always did)
  int get minBreakoutDelayBars => _i('minBreakoutDelayBars', 0);
  double get minDayMovePct => _d('minDayMovePct', 0.0);
  double get minCoilPos => _d('minCoilPos', 0.0);
  int get maxOppTouches => _i('maxOppTouches', -1);
  int get minTapeTotal => _i('minTapeTotal', 0);
  double get dailyStopR => _d('dailyStopR', 0.0);
  bool get tradeLongsOnly => _b('tradeLongsOnly', false);
  bool get logShadowTrades => _b('logShadowTrades', false);
  int get requireTiltCount => _i('requireTiltCount', 0);
  // Stocks in Play
  double get minRelVol => _d('minRelVol', 1.5);
  int get relVolBaselineDays => _i('relVolBaselineDays', 10);
  int get minBaselineDays => _i('minBaselineDays', 5);
  int get topKByRelVol => _i('topKByRelVol', 0);
  double get minAvgDailyVol => _d('minAvgDailyVol', 0.0);
  // Mining filters
  double get minAtrPct => _d('minAtrPct', 0.0);
  double get maxAtrPct => _d('maxAtrPct', 0.0);
  int get minIndexTier => _i('minIndexTier', 0);
  double get minPrice => _d('minPrice', 0.0);
  double get minGapAbsPct => _d('minGapAbsPct', 0.0);
  // Exit
  double get targetR => _d('targetR', 2.0);
  double get stopRangeFrac => _d('stopRangeFrac', 1.0);
  double get stopBufferPct => _d('stopBufferPct', 0.0);
  bool get useTrailingStop => _b('useTrailingStop', false);
  double get trailActivateR => _d('trailActivateR', 1.0);
  double get trailGapR => _d('trailGapR', 1.0);
  int get hardExitHour => _i('hardExitHour', 14);
  int get hardExitMin => _i('hardExitMin', 30);
  // Risk & costs
  double get riskPerTrade => _d('riskPerTrade', 500.0);
  int get maxTradesPerDay => _i('maxTradesPerDay', 0);
  double get maxCapitalPerTrade => _d('maxCapitalPerTrade', 0.0);
  double get costModelRoundTripPct => _d('costModelRoundTripPct', 0.10);
}
