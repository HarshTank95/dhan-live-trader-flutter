import 'package:candlesticks/candlesticks.dart';
import 'package:uuid/uuid.dart';
import '../models/backtest_result_model.dart';
import '../models/candle_stats_model.dart';
import '../models/strategy_signal_model.dart';
import '../models/strategy_trade_model.dart';
import '../services/candle_repository.dart';
import '../services/dhan_feed_service.dart';
import '../services/scrip_service.dart';
import 'base_strategy.dart';
import 'strategy_engine_context.dart';

/// One Indian-intraday support level for the day (band [lo, hi] + a tag like
/// "CPR 412.10-413.40" or "RN 450.00" used in trade notes / logs).
class LabSupportLevel {
  final double lo;
  final double hi;
  final int touches;
  final String tag;
  // Virgin/fresh: recent daily candles have NOT traded into this level's band
  // (generalises the vCPR idea to every level type). Set in computeDayLevels.
  bool fresh;
  LabSupportLevel(this.lo, this.hi, this.touches, this.tag, {this.fresh = true});
}

/// Result of scanning one stock-day for the first qualifying trigger candle.
/// Carries the trigger's analysis features (pattern type, support distance,
/// confluence) so both engines can log a complete mining record per trade.
class LabScanResult {
  final bool passed;
  final int? triggerIndex; // index into today's candles
  final String? supportNote; // matched level tag(s)
  final String? patternType; // 'hammer' | 'dominance'
  final double supportDistPct; // low's distance % from the nearest level
  final int confluence; // how many levels coincide at the low
  // Rich support-quality features computed at the trigger (freshness, the
  // matched level's strength/width, pierce depth, room to overhead resistance).
  // Spread into the Trade/Trigger logs for support mining. Null on reject.
  final Map<String, dynamic>? supportFeatures;
  final String? rejectStage;
  final String? rejectDetail;
  const LabScanResult._(
      {required this.passed,
      this.triggerIndex,
      this.supportNote,
      this.patternType,
      this.supportDistPct = 0,
      this.confluence = 0,
      this.supportFeatures,
      this.rejectStage,
      this.rejectDetail});
  factory LabScanResult.pass(int idx, String note,
          {String? pattern,
          double dist = 0,
          int conf = 0,
          Map<String, dynamic>? features}) =>
      LabScanResult._(
          passed: true,
          triggerIndex: idx,
          supportNote: note,
          patternType: pattern,
          supportDistPct: dist,
          confluence: conf,
          supportFeatures: features);
  factory LabScanResult.reject(String stage, String detail) =>
      LabScanResult._(passed: false, rejectStage: stage, rejectDetail: detail);
}

/// A completed backtest trade plus the execution analytics the mining needs:
/// which exit fired (initial stop vs trailed stop vs target vs time) and the
/// max favorable / adverse excursion in R — i.e. how far the trade ran for
/// and against us before exiting. MFE/MAE is the key input for exit-redesign
/// experiments (trail activation, stop cushions, breakeven rules).
class LabExecutedTrade {
  final StrategyTradeModel trade;
  final String exitKind; // 'stop' | 'trail' | 'target' | 'time'
  final double mfeR; // max favorable excursion (R multiples)
  final double maeR; // max adverse excursion (R multiples)
  final int mfeBar; // bars from entry to the high-water mark
  final int maeBar; // bars from entry to the low-water mark
  final int barsHeld; // bars from entry to exit
  const LabExecutedTrade(this.trade, this.exitKind, this.mfeR, this.maeR,
      this.mfeBar, this.maeBar, this.barsHeld);
}

/// Hammer/Dominance — LAB (base-only research vehicle).
///
/// A standalone STRIPPED clone of HammerDominanceStrategy (S1). It shares NO
/// code with S1 — every class here is renamed (HammerLab*, Lab*) — so S1 is
/// guaranteed unaffected by anything we do in the lab.
///
/// THE BASE (kept identical to S1): a hammer OR green-dominance candle probes
/// an Indian intraday support level and closes back above it, the IMMEDIATE
/// next candle breaks the trigger high (buy-stop fill), stop at the trigger
/// low, 15:00 time exit. Morning window 09:30–12:00 IST. All levels derive from
/// PRIOR daily candles — zero look-ahead.
///
/// EVERYTHING ELSE IS OFF. S1's learned filters and grid-tuned trail were fit
/// to the 2025-26 year (+₹47k there, −₹23k on the held-out 2024-25 year). This
/// lab turns them ALL off — gap-reject band, liquidity cap, range-spike filter,
/// min-stop-distance, exact-tick reject, PDH/S1 exclusions, trailing exit — and
/// runs the raw base across multiple years, logging the FULL unfiltered trade
/// population with rich per-trade + per-level features. We then mine those logs
/// for rules that hold or GROW across all years, re-earning each filter from
/// cross-year evidence instead of one lucky year.
///
/// Support is a first-class research target here: see [computeDayLevels] and
/// the `LevelInventory` / `SupportMiss` log records, which capture how many
/// levels of each type we build, which the trigger matched, and the candidate
/// bounces our current support net MISSED — the inputs for improving the level
/// construction itself.
class HammerLabStrategy extends BaseStrategy {
  HammerLabStrategy();

  // Distinct registry key — the lab has its own saved configs. S1
  // ('hammer_dominance_s1') is a separate strategy and is left untouched.
  @override
  String get type => 'hammer_lab';

  @override
  bool get hasCustomEngine => true;

  @override
  String get displayName => 'Hammer/Dominance — LAB (base-only research)';

  @override
  String get description =>
      'Research clone of S1 reduced to the base rule only: a hammer or green '
      'dominance candle at an Indian support level whose next candle breaks the '
      'trigger high. ALL learned filters are OFF (gap band, liquidity, range '
      'spike, min-stop, exact-tick, PDH/S1 exclusions) and the exit is a plain '
      'stop + 15:00 time exit — no trail, no target. Backtest the raw base over '
      'multiple years and mine the rich logs for rules that persist across '
      'years before adding any of them back.';

  // ── Per-run state ────────────────────────────────────────────────────────
  /// Daily candles per stock (oldest first) — for support levels.
  final Map<int, List<Candle>> _dailyData = {};

  @override
  Map<String, dynamic> get defaultParams => {
        // Data
        'historicalDays': 5, // intraday pre-roll (prev-day avg range needs 1)
        'candleInterval': '5',
        // Trigger geometry — hammer
        'wickBodyRatio': 2.0,
        'maxUpperWickPct': 10.0,
        'maxBodyPct': 33.0,
        'hammerMinWickPct': 2.0,
        // Trigger geometry — green dominance
        'allowHammer': true,
        'allowDominanceCandle': true,
        'domMinBodyPct': 80.0,
        'domMinWickPct': 5.0,
        // Gap filter (mined 2026-06-13, split-validated). Reject the stock-day
        // when today's gap (open vs prior daily close) is in (low, high] — the
        // weak-gap-up zone that loses badly. 0/0 disables. See gapRejected().
        'gapRejectLowPct': 0.0, // LAB: gap-reject band OFF (re-earn via mining)
        'gapRejectHighPct': 0.0,
        // Risk filters
        // C# parity note: the C# preset configures MaxRangeMultVsPrevDay=4.0
        // but its engine NEVER applies it (the screener gets no prior-day
        // intraday context, so prevDayAvgRange is always 0 and the filter
        // silently skips — proven against run-167: zero range_too_big rejects
        // with the filter "on", trades at 6.5× the limit). Every validated C#
        // result was therefore produced with the filter inert. Default 0
        // reproduces the validated behavior; the filter itself is implemented
        // and can be enabled here once C# fixes the bug and re-validates.
        'maxRangeMultVsPrevDay': 0.0,
        'minStopDistancePct': 0.0, // LAB: min stop-distance filter OFF
        // First EARNED rule (mined from 2yr LAB logs): reject trigger candles
        // whose range is <0.3% of price (noise). <0.3% = half the trades at 14%
        // win; ≥0.3% = 28% win, robust both years. 0 = off.
        'minTriggerRangePct': 0.3,
        // EARNED support rule (mined 2yr): skip if the nearest resistance ABOVE
        // the entry is closer than this % (boxed-in bounce, no room to run —
        // loses more both years). No overhead level nearby always passes. 0=off.
        'minOverheadPct': 0.8,
        'minPrice': 50.0, // universe sanity floor (not an alpha rule) — kept
        // Support levels
        'supportLookbackDays': 60,
        'supportZoneWidthPct': 0.5,
        'supportMinTouches': 2,
        'supportSwingStrength': 2,
        'supportMinReactionPct': 1.5,
        'reactionLookforward': 10,
        'supportTolerancePct': 0.2,
        'supportUseRoundNumbers': true,
        'usePrevDayLevels': true,
        'usePivotLevels': true,
        'useCprLevels': true,
        'useCamarillaL3': true,
        'excludePdh': false, // LAB: include every level type; mining decides
        'excludeS1': false,
        'minSupportDistPct': 0.0, // LAB: exact-tick (stop-hunt) reject OFF
        // Rising daily trendlines projected to today as an additional support
        // level (tag TL). Additive — can only add trigger opportunities, never
        // removes one. Set false for strict C#-parity comparisons (C# has no
        // trendlines). Cohort verdict comes from per-tag mining.
        'useTrendlines': true,
        // Window (IST) — LAB: ELIMINATED to the full session (09:15 → 15:00).
        // The morning-only 09:30–12:00 window in S1 is itself a learned filter.
        // triggerTime is logged on every Trigger/Trade, so we mine which hours
        // actually carry the edge per year and re-impose a window only if the
        // data demands it. (The 15:00 hard exit squares off intraday, so entries
        // near the close are naturally short-held — extend the square-off later
        // if afternoons prove worthwhile.)
        'windowStartHour': 9,
        'windowStartMin': 15,
        'windowEndHour': 15,
        'windowEndMin': 0,
        // Execution / exits
        'hardExitHour': 15,
        'hardExitMin': 0,
        'requireConfirmation': true,
        'stopBufferPct': 0.0,
        'stopBufferRangePct': 0.0,
        'targetR': 0.0, // LAB: no fixed target — a target caps the right tail
        // EARNED exit (mined from 2yr LAB logs): a fixed target HURTS both years
        // (it caps the +3R/+5R runners that carry the edge — every target level
        // was worse than holding). A TRAILING stop — let winners run, lock in as
        // price climbs — flips the strategy POSITIVE in both years. Start
        // trailing at +1R, sit 1R below the high-water. (Deliberately NOT S1's
        // 2.5/0.75, which was overfit to one year and lost OOS.)
        'useTrailingStop': true,
        'trailActivateR': 1.0,
        'trailGapR': 1.0,
        // Sizing / caps
        'riskPerTrade': 500.0,
        // LAB: execution caps OFF so the run keeps the FULL unfiltered
        // population. With the full-session window the base fires many more
        // triggers/day; a 20/day cap would keep only the first 20 stocks that
        // trigger (an arbitrary, biased sample). ₹ risk per trade stays ~₹500 by
        // construction (qty = riskPerTrade / stop-distance), so dropping the
        // capital cap can't blow up ₹ P&L — it only stops discarding trades.
        'maxTradesPerDay': 0, // 0 = unlimited
        'maxCapitalPerTrade': 0.0, // 0 = off
        // Liquidity filter (mined, cross-year robust): the breakout edge lives
        // in lower-liquidity names; ultra-liquid mega-caps (avg vol 400k+) made
        // big money in 2025-26 but lost −₹33k in the 2024-25 held-out year. Skip
        // names whose 20-day avg volume ≥ this cap — UNLESS the matched level is
        // a Camarilla L3 (the one level type robust at any liquidity). 0 = off.
        // 250k OR CAM_L3 → +₹24k/+₹22k both years (vs +₹47k/−₹23k unfiltered).
        'maxAvgDailyVol': 0.0, // LAB: liquidity cap OFF
        'costModelRoundTripPct': 0.10,
        // ── Support-research logging (LAB only) ───────────────────────────
        // Near-miss diagnostic: log the first in-window candle that passes the
        // hammer/dominance geometry but is at NO level we built, with the
        // nearest level and the forward bounce. Shows where the support net has
        // holes. Look-ahead (forward bounce) is used ONLY for the log, never
        // for entry. Toggle off for a faster/leaner run.
        'logSupportMiss': true,
        'supportMissForwardBars': 6,
      };

  @override
  List<StrategyParamDef> get paramDefinitions => [
        // Geometry — hammer
        const StrategyParamDef(
            key: 'wickBodyRatio',
            label: 'Wick / Body Ratio',
            description: 'Lower wick must be ≥ this × body (the long tail)',
            type: ParamType.decimal,
            defaultValue: 2.0,
            min: 1.0,
            max: 10.0,
            unit: 'x',
            group: 'Hammer Geometry'),
        const StrategyParamDef(
            key: 'maxUpperWickPct',
            label: 'Max Upper Wick %',
            description: 'Upper shadow ≤ this % of range',
            type: ParamType.decimal,
            defaultValue: 10.0,
            min: 0.0,
            max: 50.0,
            unit: '%',
            group: 'Hammer Geometry'),
        const StrategyParamDef(
            key: 'maxBodyPct',
            label: 'Max Body %',
            description: 'Body ≤ this % of range (small body at the top)',
            type: ParamType.decimal,
            defaultValue: 33.0,
            min: 1.0,
            max: 60.0,
            unit: '%',
            group: 'Hammer Geometry'),
        const StrategyParamDef(
            key: 'hammerMinWickPct',
            label: 'Min Wick % (both sides)',
            description: 'Both wicks ≥ this % of range',
            type: ParamType.decimal,
            defaultValue: 2.0,
            min: 0.0,
            max: 20.0,
            unit: '%',
            group: 'Hammer Geometry'),
        // Geometry — dominance
        const StrategyParamDef(
            key: 'allowHammer',
            label: 'Allow Hammer',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Trigger Patterns'),
        const StrategyParamDef(
            key: 'allowDominanceCandle',
            label: 'Allow Dominance Candle',
            description: 'Green big-body candle also triggers',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Trigger Patterns'),
        const StrategyParamDef(
            key: 'domMinBodyPct',
            label: 'Dom Min Body %',
            type: ParamType.decimal,
            defaultValue: 80.0,
            min: 50.0,
            max: 100.0,
            unit: '%',
            group: 'Trigger Patterns'),
        const StrategyParamDef(
            key: 'domMinWickPct',
            label: 'Dom Min Wick %',
            description: 'Each wick ≥ this % of range',
            type: ParamType.decimal,
            defaultValue: 5.0,
            min: 0.0,
            max: 20.0,
            unit: '%',
            group: 'Trigger Patterns'),
        // Risk filters
        const StrategyParamDef(
            key: 'maxRangeMultVsPrevDay',
            label: 'Max Range × Prev-Day Avg',
            description:
                'Trigger range ≤ this × prev-day avg bar range. 0 = off '
                '(matches validated C# behavior — see code note)',
            type: ParamType.decimal,
            defaultValue: 0.0,
            min: 0.0,
            max: 10.0,
            unit: 'x',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'minStopDistancePct',
            label: 'Min Stop Distance %',
            description: '(next-bar open − trigger low)/open must be ≥ this',
            type: ParamType.decimal,
            defaultValue: 0.8,
            min: 0.0,
            max: 5.0,
            unit: '%',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'minTriggerRangePct',
            label: 'Min Trigger Range %',
            description:
                'Reject trigger candles whose range is < this % of price '
                '(noise filter). Mined: <0.3% wins 14%, ≥0.3% wins 28%. 0 = off.',
            type: ParamType.decimal,
            defaultValue: 0.3,
            min: 0.0,
            max: 3.0,
            unit: '%',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'minOverheadPct',
            label: 'Min Overhead Room %',
            description:
                'Skip if the nearest level ABOVE the entry is closer than this % '
                '(boxed-in bounce, no room to run). Mined robust both years. 0 = off.',
            type: ParamType.decimal,
            defaultValue: 0.8,
            min: 0.0,
            max: 5.0,
            unit: '%',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'minPrice',
            label: 'Min Price',
            type: ParamType.decimal,
            defaultValue: 50.0,
            min: 0.0,
            max: 10000.0,
            unit: 'INR',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'gapRejectLowPct',
            label: 'Gap Reject Low %',
            description:
                'Skip the day when the open gap is in (low, high]. Mined weak '
                'gap-up zone. Set low=high to disable.',
            type: ParamType.decimal,
            defaultValue: 0.3,
            min: -5.0,
            max: 5.0,
            unit: '%',
            group: 'Risk Filters'),
        const StrategyParamDef(
            key: 'gapRejectHighPct',
            label: 'Gap Reject High %',
            type: ParamType.decimal,
            defaultValue: 1.0,
            min: -5.0,
            max: 5.0,
            unit: '%',
            group: 'Risk Filters'),
        // Support
        const StrategyParamDef(
            key: 'supportLookbackDays',
            label: 'Support Lookback Days',
            description: 'Daily candles for 60-day swing zones',
            type: ParamType.integer,
            defaultValue: 60,
            min: 10,
            max: 250,
            unit: 'd',
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'supportTolerancePct',
            label: 'Support Tolerance %',
            description: 'How far outside a band the low still tags it',
            type: ParamType.decimal,
            defaultValue: 0.2,
            min: 0.0,
            max: 2.0,
            unit: '%',
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'minSupportDistPct',
            label: 'Min Support Dist %',
            description: 'Reject lows WITHIN this % of the level (stop-hunt)',
            type: ParamType.decimal,
            defaultValue: 0.06,
            min: 0.0,
            max: 0.5,
            unit: '%',
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'supportUseRoundNumbers',
            label: 'Use Round Numbers',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'usePrevDayLevels',
            label: 'Use PDL / PDC',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'usePivotLevels',
            label: 'Use Pivots P / S2',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'useCprLevels',
            label: 'Use CPR',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'useCamarillaL3',
            label: 'Use Camarilla L3',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        const StrategyParamDef(
            key: 'useTrendlines',
            label: 'Use Trendlines (TL)',
            description:
                'Rising daily trendlines (≥3rd touch, unbroken) projected to '
                'today as support. Off = C#-parity level set.',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Support Levels'),
        // Window
        const StrategyParamDef(
            key: 'windowStartHour',
            label: 'Window Start Hour',
            type: ParamType.integer,
            defaultValue: 9,
            min: 9,
            max: 15,
            group: 'Time Window'),
        const StrategyParamDef(
            key: 'windowStartMin',
            label: 'Window Start Min',
            type: ParamType.integer,
            defaultValue: 30,
            min: 0,
            max: 59,
            group: 'Time Window'),
        const StrategyParamDef(
            key: 'windowEndHour',
            label: 'Window End Hour',
            type: ParamType.integer,
            defaultValue: 12,
            min: 9,
            max: 15,
            group: 'Time Window'),
        const StrategyParamDef(
            key: 'windowEndMin',
            label: 'Window End Min',
            type: ParamType.integer,
            defaultValue: 0,
            min: 0,
            max: 59,
            group: 'Time Window'),
        const StrategyParamDef(
            key: 'hardExitHour',
            label: 'Hard Exit Hour',
            type: ParamType.integer,
            defaultValue: 15,
            min: 9,
            max: 15,
            group: 'Time Window'),
        const StrategyParamDef(
            key: 'hardExitMin',
            label: 'Hard Exit Min',
            type: ParamType.integer,
            defaultValue: 0,
            min: 0,
            max: 59,
            group: 'Time Window'),
        // Exits
        const StrategyParamDef(
            key: 'targetR',
            label: 'Target (R)',
            description: 'Take profit at entry + R×risk. 0 = no target (trail only).',
            type: ParamType.decimal,
            defaultValue: 0.0,
            min: 0.0,
            max: 20.0,
            unit: 'R',
            group: 'Exit'),
        const StrategyParamDef(
            key: 'useTrailingStop',
            label: 'Use Trailing Stop',
            description: 'Run-the-winner: trail Gap R below high-water once Activate R in profit',
            type: ParamType.boolean,
            defaultValue: true,
            group: 'Exit'),
        const StrategyParamDef(
            key: 'trailActivateR',
            label: 'Trail Activate (R)',
            description:
                'Start trailing once this many R in profit. 2.5 (mined optimum) '
                'lets winners run; 1.0 = C#-parity.',
            type: ParamType.decimal,
            defaultValue: 2.5,
            min: 0.0,
            max: 10.0,
            unit: 'R',
            group: 'Exit'),
        const StrategyParamDef(
            key: 'trailGapR',
            label: 'Trail Gap (R)',
            description: 'Trail sits this many R below the high-water mark.',
            type: ParamType.decimal,
            defaultValue: 0.75,
            min: 0.1,
            max: 10.0,
            unit: 'R',
            group: 'Exit'),
        const StrategyParamDef(
            key: 'stopBufferRangePct',
            label: 'Stop Buffer (% of range)',
            description: 'Stop sits this % of the trigger range BELOW its low',
            type: ParamType.decimal,
            defaultValue: 0.0,
            min: 0.0,
            max: 50.0,
            unit: '%',
            group: 'Exit'),
        // Sizing
        const StrategyParamDef(
            key: 'riskPerTrade',
            label: 'Risk per Trade',
            type: ParamType.decimal,
            defaultValue: 500.0,
            min: 100.0,
            max: 10000.0,
            unit: 'INR',
            group: 'Position Sizing'),
        const StrategyParamDef(
            key: 'maxTradesPerDay',
            label: 'Max Trades / Day',
            type: ParamType.integer,
            defaultValue: 20,
            min: 1,
            max: 50,
            group: 'Position Sizing'),
        const StrategyParamDef(
            key: 'maxCapitalPerTrade',
            label: 'Max Capital / Trade',
            type: ParamType.decimal,
            defaultValue: 300000.0,
            min: 0.0,
            max: 10000000.0,
            unit: 'INR',
            group: 'Position Sizing'),
        const StrategyParamDef(
            key: 'maxAvgDailyVol',
            label: 'Max Avg Daily Volume',
            description:
                'Skip names whose 20-day avg volume ≥ this (Camarilla-L3 levels bypass the cap). 0 = off. Lower-liquidity names hold their edge out-of-sample; mega-caps do not.',
            type: ParamType.decimal,
            defaultValue: 250000.0,
            min: 0.0,
            max: 100000000.0,
            unit: 'shares',
            group: 'Position Sizing'),
        const StrategyParamDef(
            key: 'costModelRoundTripPct',
            label: 'Cost Model RT %',
            type: ParamType.decimal,
            defaultValue: 0.10,
            min: 0.0,
            max: 1.0,
            unit: '%',
            group: 'Position Sizing'),
      ];

  @override
  String? diagnosisHint(String rule) {
    switch (rule) {
      case 'no_pattern':
        return 'No bar matched hammer/dominance geometry in 09:30–12:00.';
      case 'range_too_small':
        return 'Trigger candles were tiny (<min range %) — noise, mined-out.';
      case 'no_overhead_room':
        return 'Resistance sat right above entry (<min room) — bounce boxed in.';
      case 'not_at_support':
        return 'Triggers formed but none probed an enabled support level.';
      case 'exact_tick':
        return 'Lows landed ON the level (stop-hunt zone) — rejected by design.';
      case 'stop_too_tight':
        return 'Stop distance < 0.8% — whipsaw protection rejected them.';
      case 'range_too_big':
        return 'Trigger candles were abnormal spikes (>4× prev-day avg range).';
      case 'no_confirmation':
        return 'Next candle never broke the trigger high — buy-stop unfilled.';
      case 'no_daily':
        return 'No prior daily candles — support levels unavailable.';
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════════════
  // Pure decision core (shared verbatim by backtest and live)
  // ════════════════════════════════════════════════════════════════════════

  /// Decimal-parity tolerance. The C# engine evaluates every filter in
  /// `decimal` (exact base-10): a stop distance of exactly 0.80% passes a
  /// `< 0.80` check. Dart doubles can land a hair under an exact boundary
  /// (ASHOKLEY 2026-05-14: stop_dist exactly 0.80% computed as 0.79999…,
  /// falsely rejected — caught reconciling against C# run-167). All boundary
  /// comparisons below treat values within [tol] as equal, mirroring decimal
  /// semantics. 1e-9 is far below any economically meaningful difference and
  /// far above double rounding error at these magnitudes.
  static const double tol = 1e-9;

  /// a strictly less than b, decimal-style (a == b within [tol] → false).
  static bool ltTol(double a, double b) => a < b - tol;

  /// a strictly greater than b, decimal-style (a == b within [tol] → false).
  static bool gtTol(double a, double b) => a > b + tol;

  /// a ≤ b, decimal-style (a == b within [tol] → true).
  static bool leTol(double a, double b) => a <= b + tol;

  /// Levels for the day from PRIOR daily candles (strictly before the trade
  /// day, oldest first). Mirrors HammerScreener's level construction exactly.
  List<LabSupportLevel> computeDayLevels(
      List<Candle> dailyBefore, Map<String, dynamic> params) {
    final p = HammerLabParams(params);
    final levels = <LabSupportLevel>[];
    if (dailyBefore.isEmpty) return levels;

    for (final z in computeSupportZones(dailyBefore, p)) {
      levels.add(z);
    }
    if (p.useTrendlines) {
      levels.addAll(computeTrendlines(dailyBefore, p));
    }

    final dbars = List<Candle>.from(dailyBefore)
      ..sort((a, b) => a.date.compareTo(b.date));
    final y = dbars.last; // yesterday
    final h = y.high, l = y.low, c = y.close;
    final pivot = (h + l + c) / 3;

    if (p.usePrevDayLevels) {
      levels.add(LabSupportLevel(l, l, 1, 'PDL ${l.toStringAsFixed(2)}'));
      levels.add(LabSupportLevel(c, c, 1, 'PDC ${c.toStringAsFixed(2)}'));
      if (!p.excludePdh) {
        levels.add(LabSupportLevel(h, h, 1, 'PDH ${h.toStringAsFixed(2)}'));
      }
    }
    if (p.usePivotLevels) {
      final s1 = 2 * pivot - h, s2 = pivot - (h - l);
      levels.add(LabSupportLevel(pivot, pivot, 1, 'P ${pivot.toStringAsFixed(2)}'));
      if (!p.excludeS1) {
        levels.add(LabSupportLevel(s1, s1, 1, 'S1 ${s1.toStringAsFixed(2)}'));
      }
      levels.add(LabSupportLevel(s2, s2, 1, 'S2 ${s2.toStringAsFixed(2)}'));
    }
    if (p.useCprLevels) {
      var bc = (h + l) / 2, tc = 2 * pivot - bc;
      if (bc > tc) {
        final t = bc;
        bc = tc;
        tc = t;
      }
      int cprVirgin = 0;
      if (dbars.length >= 2) {
        final y2 = dbars[dbars.length - 2];
        final p2 = (y2.high + y2.low + y2.close) / 3;
        var bc2 = (y2.high + y2.low) / 2, tc2 = 2 * p2 - bc2;
        if (bc2 > tc2) {
          final t = bc2;
          bc2 = tc2;
          tc2 = t;
        }
        // Virgin CPR: yesterday's session never traded into its own CPR band.
        if (y.high < bc2 || y.low > tc2) cprVirgin = 1;
      }
      levels.add(LabSupportLevel(bc, tc, 1,
          '${cprVirgin == 1 ? "vCPR" : "CPR"} ${bc.toStringAsFixed(2)}-${tc.toStringAsFixed(2)}'));
    }
    if (p.useCamarillaL3) {
      final l3 = c - (h - l) * 1.1 / 4;
      levels.add(LabSupportLevel(l3, l3, 1, 'CAM_L3 ${l3.toStringAsFixed(2)}'));
    }

    // Freshness pass (generalises vCPR to every level): a level is FRESH if none
    // of the last [freshLookbackDays] daily candles traded into its band — i.e.
    // price hasn't visited it recently. The vCPR result said fresh levels give
    // bigger, cleaner bounces; this lets the next run test that across all types.
    const freshLookbackDays = 5;
    final recent = dbars.length > freshLookbackDays
        ? dbars.sublist(dbars.length - freshLookbackDays)
        : dbars;
    for (final z in levels) {
      bool touched = false;
      for (final d in recent) {
        if (!(d.high < z.lo || d.low > z.hi)) {
          touched = true;
          break;
        }
      }
      z.fresh = !touched;
    }
    return levels;
  }

  /// Rising trendlines from prior daily swing lows, projected to TODAY.
  ///
  /// A trendline is a line in (time, price) space — its support value is
  /// different every day, so today's level = the line projected to today's
  /// bar index (trading-day axis, like a real chart). Construction follows
  /// classic charting discipline (Edwards & Magee; Bulkowski's trendline
  /// stats: shallow, long, well-touched lines are the reliable ones):
  ///
  ///   • anchors = daily swing lows (lowest of ±2 bars), ≥5 trading days apart
  ///   • rising only (we buy support), slope capped at 2%/day (steeper =
  ///     parabolic, breaks immediately)
  ///   • a touch = a later bar's low within ±0.3% of the line AT THAT BAR'S
  ///     TIME that closed back above it; ≥2 touches required, so today's
  ///     probe is the 3rd touch — "two points draw it, the third confirms it"
  ///   • any daily CLOSE below the line kills it (broken support ≠ support)
  ///   • projected value must sit below yesterday's close (support, not
  ///     overhead resistance)
  ///
  /// Near-duplicate lines (many pivot pairs ⇒ similar lines) are clustered
  /// by today-value (0.5%) keeping the strongest. Parameters are fixed at
  /// charting-convention values — deliberately NOT tunable, so the mining
  /// verdict on the TL cohort stays honest.
  List<LabSupportLevel> computeTrendlines(
      List<Candle> dailyBefore, HammerLabParams p) {
    var bars = List<Candle>.from(dailyBefore)
      ..sort((a, b) => a.date.compareTo(b.date));
    if (bars.length > p.supportLookbackDays) {
      bars = bars.sublist(bars.length - p.supportLookbackDays);
    }
    final n = bars.length;
    if (n < 10) return [];
    final lastClose = bars.last.close;

    const pivotW = 2; // swing strength
    const minAnchorGap = 5; // trading days between anchors
    const touchTolPct = 0.3; // touch / break tolerance (% of line value)
    const maxSlopePctPerDay = 2.0; // steeper = parabolic, not a trend
    const minTouches = 2; // today's probe = 3rd touch

    // Swing lows (pivot strength ±2).
    final pivots = <int>[];
    for (int i = pivotW; i < n - pivotW; i++) {
      bool isLow = true;
      for (int j = i - pivotW; j <= i + pivotW; j++) {
        if (bars[j].low < bars[i].low) {
          isLow = false;
          break;
        }
      }
      if (isLow) pivots.add(i);
    }
    if (pivots.length < 2) return [];

    final candidates =
        <({double vToday, int touches, double slopePct, int lastAnchor})>[];

    for (int a = 0; a < pivots.length - 1; a++) {
      for (int b = a + 1; b < pivots.length; b++) {
        final ia = pivots[a], ib = pivots[b];
        if (ib - ia < minAnchorGap) continue;
        final la = bars[ia].low, lb = bars[ib].low;
        final slope = (lb - la) / (ib - ia); // ₹ per trading day
        if (slope <= 0) continue; // rising support only
        final slopePct = slope / la * 100;
        if (slopePct > maxSlopePctPerDay) continue;

        double valueAt(int t) => la + slope * (t - ia);

        // Walk forward from the first anchor: count touches, detect breaks.
        int touches = 0;
        bool broken = false;
        for (int t = ia; t < n; t++) {
          final v = valueAt(t);
          if (v <= 0) {
            broken = true;
            break;
          }
          if (bars[t].close < v * (1 - touchTolPct / 100)) {
            broken = true;
            break;
          }
          if ((bars[t].low - v).abs() / v * 100 <= touchTolPct &&
              bars[t].close >= v) {
            touches++;
          }
        }
        if (broken || touches < minTouches) continue;

        final vToday = valueAt(n); // projected to today's bar
        if (vToday <= 0 || vToday > lastClose) continue; // must be support

        candidates.add((
          vToday: vToday,
          touches: touches,
          slopePct: slopePct,
          lastAnchor: ib,
        ));
      }
    }
    if (candidates.isEmpty) return [];

    // Cluster near-duplicates by today-value (0.5%); keep the strongest
    // (most touches, then the most recent anchor).
    candidates.sort((x, y) => x.vToday.compareTo(y.vToday));
    final kept = <({double vToday, int touches, double slopePct, int lastAnchor})>[];
    for (final c in candidates) {
      if (kept.isNotEmpty &&
          (c.vToday - kept.last.vToday) / kept.last.vToday * 100 <= 0.5) {
        final prev = kept.last;
        if (c.touches > prev.touches ||
            (c.touches == prev.touches && c.lastAnchor > prev.lastAnchor)) {
          kept[kept.length - 1] = c;
        }
      } else {
        kept.add(c);
      }
    }

    return kept
        .map((c) => LabSupportLevel(
              c.vToday,
              c.vToday,
              c.touches,
              'TL ${c.vToday.toStringAsFixed(2)} (+${c.slopePct.toStringAsFixed(2)}%/d x${c.touches})',
            ))
        .toList();
  }

  /// 60-day reactive swing-low zones — port of ComputeSupportZones.
  List<LabSupportLevel> computeSupportZones(
      List<Candle> daily, HammerLabParams p) {
    var bars = List<Candle>.from(daily)
      ..sort((a, b) => a.date.compareTo(b.date));
    if (bars.length > p.supportLookbackDays) {
      bars = bars.sublist(bars.length - p.supportLookbackDays);
    }
    final n = bars.length;
    if (n == 0) return [];

    final w = p.supportSwingStrength < 1 ? 1 : p.supportSwingStrength;
    final lastClose = bars.last.close;

    // 1+2. Reactive swing lows: a local bottom that then bounced ≥ MinReaction.
    final lows = <({double price, int idx})>[];
    for (int i = w; i < n - w; i++) {
      bool isLow = true;
      for (int j = i - w; j <= i + w; j++) {
        if (bars[j].low < bars[i].low) {
          isLow = false;
          break;
        }
      }
      if (!isLow) continue;
      final lowP = bars[i].low;
      final end = (i + p.reactionLookforward) < (n - 1)
          ? i + p.reactionLookforward
          : n - 1;
      double maxHigh = 0;
      for (int j = i + 1; j <= end; j++) {
        if (bars[j].high > maxHigh) maxHigh = bars[j].high;
      }
      final reactionPct = lowP > 0 ? (maxHigh - lowP) / lowP * 100 : 0;
      if (reactionPct >= p.supportMinReactionPct) lows.add((price: lowP, idx: i));
    }
    if (lows.isEmpty) return [];

    // 3. Cluster by price, anchored to the cluster base.
    lows.sort((a, b) => a.price.compareTo(b.price));
    final raw = <({double lo, double hi, int touches, int lastIdx})>[];
    double clo = lows[0].price, chi = lows[0].price;
    int cnt = 1, lastIdx = lows[0].idx;
    for (int i = 1; i < lows.length; i++) {
      if (clo > 0 && (lows[i].price - clo) / clo * 100 <= p.supportZoneWidthPct) {
        chi = lows[i].price;
        cnt++;
        if (lows[i].idx > lastIdx) lastIdx = lows[i].idx;
      } else {
        raw.add((lo: clo, hi: chi, touches: cnt, lastIdx: lastIdx));
        clo = chi = lows[i].price;
        cnt = 1;
        lastIdx = lows[i].idx;
      }
    }
    raw.add((lo: clo, hi: chi, touches: cnt, lastIdx: lastIdx));

    // 4. Keep strong, valid floors below price, not broken since last touch.
    final breakBuf = p.supportZoneWidthPct / 100;
    final zones = <LabSupportLevel>[];
    for (final z in raw) {
      if (z.touches < p.supportMinTouches) continue;
      if (z.hi > lastClose) continue; // overhead = resistance
      bool broken = false;
      for (int j = z.lastIdx + 1; j < n; j++) {
        if (bars[j].close < z.lo * (1 - breakBuf)) {
          broken = true;
          break;
        }
      }
      if (broken) continue;
      zones.add(LabSupportLevel(z.lo, z.hi, z.touches,
          'ZONE ${z.lo.toStringAsFixed(2)}-${z.hi.toStringAsFixed(2)} x${z.touches}'));
    }
    return zones;
  }

  bool isHammer(Candle c, double range, double body, double lowerWick,
      double upperWick, HammerLabParams p) {
    if (gtTol(body, p.maxBodyPct / 100 * range)) return false;
    if (gtTol(upperWick, p.maxUpperWickPct / 100 * range)) return false;
    if (body > 0 && ltTol(lowerWick, p.wickBodyRatio * body)) return false;
    if (lowerWick <= 0) return false;
    if (p.hammerMinWickPct > 0) {
      final minWick = p.hammerMinWickPct / 100 * range;
      if (ltTol(upperWick, minWick) || ltTol(lowerWick, minWick)) return false;
    }
    return true;
  }

  bool isDominance(Candle c, double range, double body, double upperWick,
      double lowerWick, HammerLabParams p) {
    if (c.close <= c.open) return false; // green only
    if (ltTol(body, p.domMinBodyPct / 100 * range)) return false;
    if (ltTol(upperWick, p.domMinWickPct / 100 * range)) return false;
    if (ltTol(lowerWick, p.domMinWickPct / 100 * range)) return false;
    return true;
  }

  /// Whole-day pre-filter: reject the stock-day when today's gap (open vs
  /// prior daily close) falls in the "weak gap-up" reject band.
  ///
  /// Mined from the tuned-exit 1-year run (2026-06-13): a +0.3%→+1.0% gap-up
  /// that then probes support is usually a failed open / distribution — that
  /// single cohort lost −₹16,966 at 30% win, while flat opens, gap-downs, and
  /// big (>1%) momentum gap-ups all won. Cutting just this band took S1 from
  /// ₹30k→₹47k AND held stronger out-of-sample (test-half ₹12.8k→₹26.9k).
  /// Set rejectLow == rejectHigh (e.g. 0/0) to disable.
  bool gapRejected(double gapPct, HammerLabParams p) {
    if (p.gapRejectHighPct <= p.gapRejectLowPct) return false; // disabled
    return gapPct > p.gapRejectLowPct && gapPct <= p.gapRejectHighPct;
  }

  /// Is the candle's low probing one of the day's levels (and closing back
  /// above it)? Returns the nearest match distance% + a note of all matches.
  ({bool at, double dist, String note, int conf, LabSupportLevel? primary})
      atSupport(Candle c, List<LabSupportLevel> levels, HammerLabParams p) {
    final bandTol = p.supportTolerancePct / 100;
    final matched = <({LabSupportLevel level, double d})>[];

    for (final z in levels) {
      final bandLo = z.lo * (1 - bandTol), bandHi = z.hi * (1 + bandTol);
      if (!ltTol(c.low, bandLo) && !gtTol(c.low, bandHi) && gtTol(c.close, z.lo)) {
        final center = (z.lo + z.hi) / 2;
        final d = center > 0 ? (c.low - center).abs() / center * 100 : 0.0;
        matched.add((level: z, d: d));
      }
    }

    if (p.supportUseRoundNumbers) {
      final rn = nearestRound(c.low);
      final d = rn > 0 ? (c.low - rn).abs() / rn * 100 : 999.0;
      if (leTol(d, p.supportTolerancePct) && gtTol(c.close, rn)) {
        matched.add((
          level: LabSupportLevel(rn, rn, 1, 'RN ${rn.toStringAsFixed(2)}'),
          d: d
        ));
      }
    }

    if (matched.isEmpty) {
      return (at: false, dist: -1, note: '', conf: 0, primary: null);
    }
    matched.sort((a, b) => a.d.compareTo(b.d));
    final note =
        '${matched.map((m) => m.level.tag).join(" + ")} (conf ${matched.length})';
    return (
      at: true,
      dist: matched.first.d,
      note: note,
      conf: matched.length,
      primary: matched.first.level
    );
  }

  static double nearestRound(double price) {
    final step = price < 100
        ? 5.0
        : price < 500
            ? 10.0
            : price < 2000
                ? 50.0
                : 100.0;
    return (price / step).round() * step;
  }

  /// Scan today's bars (oldest first) for the FIRST qualifying trigger.
  /// [scanUpTo] (exclusive) limits the scan to closed bars in live; pass
  /// todayCandles.length for backtest. Mirrors HammerScreener.Scan exactly,
  /// including the "furthest-reached stage" reject reporting.
  LabScanResult scanForTrigger({
    required List<Candle> todayCandles,
    required List<LabSupportLevel> levels,
    required double prevDayAvgRange,
    required Map<String, dynamic> params,
    int? scanUpTo,
  }) {
    final p = HammerLabParams(params);
    final upTo = scanUpTo ?? todayCandles.length;
    final windowStart = p.windowStartHour * 60 + p.windowStartMin;
    final windowEnd = p.windowEndHour * 60 + p.windowEndMin;

    String? lastStage;
    String? lastDetail;
    int lastRank = 0;
    void note(int rank, String stage, String detail) {
      if (rank >= lastRank) {
        lastRank = rank;
        lastStage = stage;
        lastDetail = detail;
      }
    }

    if (todayCandles.length < 2) {
      return LabScanResult.reject('insufficient_bars',
          'today bars=${todayCandles.length} < 2 (need a next bar to enter)');
    }

    for (int k = 0; k < upTo; k++) {
      final c = todayCandles[k];
      final m = c.date.hour * 60 + c.date.minute;
      if (m < windowStart || m > windowEnd) continue;

      final range = c.high - c.low;
      if (range <= 0) {
        note(1, 'no_range', 'zero-range candle');
        continue;
      }
      final body = (c.close - c.open).abs();
      final lowerWick =
          (c.open < c.close ? c.open : c.close) - c.low;
      final upperWick =
          c.high - (c.open > c.close ? c.open : c.close);

      final isHam =
          p.allowHammer && isHammer(c, range, body, lowerWick, upperWick, p);
      final isDom = p.allowDominanceCandle &&
          isDominance(c, range, body, upperWick, lowerWick, p);
      if (!isHam && !isDom) {
        note(3, 'no_pattern', 'neither a hammer nor a green-dominance candle');
        continue;
      }

      // Min trigger range (first earned rule, mined from 2yr LAB logs): tiny
      // "noise" candles probing a level are not a real test — trigger range
      // <0.3% of price is HALF of all trades and wins only 14% (vs 28% at
      // ≥0.3%), losing −0.71R both years. Gating them eliminates ~86%-loser
      // trades while keeping the rest. 0 = off.
      if (p.minTriggerRangePct > 0) {
        final rangePct = c.close > 0 ? range / c.close * 100 : 0.0;
        if (ltTol(rangePct, p.minTriggerRangePct)) {
          note(4, 'range_too_small',
              'trigger range ${rangePct.toStringAsFixed(2)}% < min ${p.minTriggerRangePct.toStringAsFixed(2)}% (noise candle)');
          continue;
        }
      }

      if (p.maxRangeMultVsPrevDay > 0 &&
          prevDayAvgRange > 0 &&
          gtTol(range, p.maxRangeMultVsPrevDay * prevDayAvgRange)) {
        note(2, 'range_too_big',
            'candle range ₹${range.toStringAsFixed(2)} > ${p.maxRangeMultVsPrevDay.toStringAsFixed(1)}× prev-day avg ₹${prevDayAvgRange.toStringAsFixed(2)}');
        continue;
      }

      if (p.minPrice > 0 && ltTol(c.close, p.minPrice)) {
        note(6, 'min_price',
            'close ₹${c.close.toStringAsFixed(2)} < min ₹${p.minPrice.toStringAsFixed(2)}');
        continue;
      }

      // need a next bar to enter on
      if (k + 1 >= todayCandles.length) break;
      final entryOpen = todayCandles[k + 1].open;

      // Candle-at-support
      final sup = atSupport(c, levels, p);
      if (!sup.at) {
        note(8, 'not_at_support',
            'low ₹${c.low.toStringAsFixed(2)} not at any enabled support level');
        continue;
      }
      if (p.minSupportDistPct > 0 && leTol(sup.dist, p.minSupportDistPct)) {
        note(8, 'exact_tick',
            'low ₹${c.low.toStringAsFixed(2)} within ${sup.dist.toStringAsFixed(3)}% of the level (≤${p.minSupportDistPct.toStringAsFixed(2)}% stop-hunt zone)');
        continue;
      }

      // Min stop-distance (uses k+1's open, matching C#)
      if (p.minStopDistancePct > 0) {
        final sdp = entryOpen > 0 ? (entryOpen - c.low) / entryOpen * 100 : 0.0;
        if (ltTol(sdp, p.minStopDistancePct)) {
          note(9, 'stop_too_tight',
              'stop ${sdp.toStringAsFixed(2)}% < min ${p.minStopDistancePct.toStringAsFixed(2)}%');
          continue;
        }
      }

      // Rich support features for mining: freshness (daily-virgin + intraday
      // first-test), the matched level's strength/width, how deep the low
      // pierced it, how strongly the close reclaimed it, and how much room to
      // the nearest overhead level (a low ceiling stalls bounces).
      final prim = sup.primary!;
      final pctr = (prim.lo + prim.hi) / 2;
      final btol = p.supportTolerancePct / 100;
      final pLo = prim.lo * (1 - btol), pHi = prim.hi * (1 + btol);
      int testsToday = 0;
      for (int j = 0; j < k; j++) {
        final b = todayCandles[j];
        if (!(b.high < pLo || b.low > pHi)) testsToday++;
      }
      double overhead = -1;
      for (final z in levels) {
        final zc = (z.lo + z.hi) / 2;
        if (zc > c.high) {
          final od = (zc - c.high) / c.high * 100;
          if (overhead < 0 || od < overhead) overhead = od;
        }
      }
      // EARNED support rule (mined 2yr): need room above. If the nearest level
      // ABOVE the entry is closer than minOverheadPct, the bounce is boxed in by
      // resistance and can't run — those trades lose more in both years. No
      // ceiling nearby (overhead<0) always passes. 0 = off.
      if (p.minOverheadPct > 0 && overhead >= 0 && ltTol(overhead, p.minOverheadPct)) {
        note(5, 'no_overhead_room',
            'nearest resistance ${overhead.toStringAsFixed(2)}% above < min ${p.minOverheadPct.toStringAsFixed(2)}% (no room to run)');
        continue;
      }
      final feats = <String, dynamic>{
        'primaryFresh': prim.fresh, // daily-virgin (no recent daily touch)
        'testsToday': testsToday, // intraday touches before this bar (0 = first)
        'primaryTouches': prim.touches,
        'primaryWidthPct': double.parse(
            (pctr > 0 ? (prim.hi - prim.lo) / pctr * 100 : 0).toStringAsFixed(3)),
        'penetrationPct': double.parse(
            (c.low < prim.lo ? (prim.lo - c.low) / prim.lo * 100 : 0)
                .toStringAsFixed(3)),
        'reclaimPct': double.parse(
            (prim.lo > 0 ? (c.close - prim.lo) / prim.lo * 100 : 0)
                .toStringAsFixed(3)),
        'overheadPct':
            overhead < 0 ? -1 : double.parse(overhead.toStringAsFixed(3)),
      };
      return LabScanResult.pass(k, sup.note,
          pattern: isHam ? 'hammer' : 'dominance',
          dist: sup.dist,
          conf: sup.conf,
          features: feats);
    }

    if (lastStage != null) {
      return LabScanResult.reject(lastStage!, lastDetail!);
    }
    return LabScanResult.reject(
        'no_hammer', 'no intraday bar matched the trigger geometry in the window');
  }

  /// Backtest trade execution from the trigger: k+1 confirmation entry, then
  /// stop/trail/target/time-exit walk. Mirrors HammerStrategy.ExecuteTrade.
  /// Returns the trade plus exit analytics (exit kind, MFE/MAE in R).
  LabExecutedTrade? executeFromBars({
    required int securityId,
    required String symbol,
    required List<Candle> todayCandles,
    required int triggerIndex,
    required Map<String, dynamic> params,
    required String configId,
    required bool isPaperTrade,
    String? note,
  }) {
    final p = HammerLabParams(params);
    final trigger = todayCandles[triggerIndex];
    final entryIdx = triggerIndex + 1;
    if (entryIdx >= todayCandles.length) return null;
    final entryBar = todayCandles[entryIdx];
    final hardExit = p.hardExitHour * 60 + p.hardExitMin;
    final entryBarMin = entryBar.date.hour * 60 + entryBar.date.minute;
    if (entryBarMin >= hardExit) return null;

    double entryPrice;
    if (p.requireConfirmation) {
      if (entryBar.high < trigger.high) return null; // buy-stop never filled
      entryPrice = trigger.high > entryBar.open ? trigger.high : entryBar.open;
    } else {
      entryPrice = entryBar.open;
    }

    final triggerRange = trigger.high - trigger.low;
    final stopLoss = trigger.low * (1 - p.stopBufferPct / 100) -
        p.stopBufferRangePct / 100 * triggerRange;
    final risk = entryPrice - stopLoss;
    if (risk <= 0) return null;
    final quantity = (p.riskPerTrade / risk).floor();
    if (quantity <= 0) return null;
    final target = p.targetR > 0 ? entryPrice + p.targetR * risk : null;

    var effectiveStop = stopLoss;
    var highWater = entryPrice;
    final trailActivate = entryPrice + p.trailActivateR * risk;
    // Excursion tracking (mining): how far the trade ran for/against us, and
    // WHEN (bars from entry) — the input for designing trail/target exits.
    var maxHigh = entryPrice;
    var minLow = entryPrice;
    var maxHighBar = 0;
    var minLowBar = 0;

    StrategyTradeModel build(Candle exitBar, double exitPx, TradeOutcome outcome) =>
        StrategyTradeModel(
          id: const Uuid().v4(),
          strategyConfigId: configId,
          signalId: const Uuid().v4(),
          securityId: securityId,
          symbol: symbol,
          status: TradeStatus.closed,
          isPaperTrade: isPaperTrade,
          entryPrice: entryPrice,
          quantity: quantity,
          entryTime: entryBar.date,
          exitPrice: exitPx,
          exitTime: exitBar.date,
          outcome: outcome,
          stopLoss: stopLoss,
          target: target ?? 0,
          costModelPct: p.costModelRoundTripPct,
        );

    LabExecutedTrade done(int exitIdx, Candle exitBar, double exitPx,
            TradeOutcome outcome, String kind) =>
        LabExecutedTrade(
          build(exitBar, exitPx, outcome),
          kind,
          (maxHigh - entryPrice) / risk,
          (entryPrice - minLow) / risk,
          maxHighBar,
          minLowBar,
          exitIdx - entryIdx,
        );

    for (int i = entryIdx; i < todayCandles.length; i++) {
      final c = todayCandles[i];
      if (c.high > maxHigh) {
        maxHigh = c.high;
        maxHighBar = i - entryIdx;
      }
      if (c.low < minLow) {
        minLow = c.low;
        minLowBar = i - entryIdx;
      }

      // 1. Protective / trailing stop first (conservative on same-bar).
      if (c.low <= effectiveStop) {
        return done(i, c, effectiveStop, TradeOutcome.stopLoss,
            effectiveStop > stopLoss ? 'trail' : 'stop');
      }
      // 2. Optional R-target.
      if (target != null && c.high >= target) {
        return done(i, c, target, TradeOutcome.target, 'target');
      }
      // 3. Hard time exit.
      final cm = c.date.hour * 60 + c.date.minute;
      if (cm >= hardExit) {
        return done(i, c, c.close, TradeOutcome.endOfDay, 'time');
      }
      // 4. Update high-water + trail for the NEXT bar (no intrabar peek).
      if (p.useTrailingStop) {
        if (c.high > highWater) highWater = c.high;
        if (highWater >= trailActivate) {
          final trailed = highWater - p.trailGapR * risk;
          if (trailed > effectiveStop) effectiveStop = trailed;
        }
      }
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════════════
  // Custom engine: Backtest
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> prepareBacktest(BacktestPrepContext ctx) async {
    final p = HammerLabParams(ctx.params);
    // supportLookbackDays trading days ≈ ×7/5 calendar days + cushion.
    final dailyStart = ctx.fromDate
        .subtract(Duration(days: (p.supportLookbackDays * 7 ~/ 5) + 20));
    ctx.log('Hammer: downloading daily candles (support levels) from ${_fmt(dailyStart)}...');
    final daily = await CandleRepository.instance.bulkFetchDaily(
      securityIds: ctx.securityIds,
      fromDate: dailyStart,
      toDate: ctx.toDate,
      accessToken: ctx.accessToken,
      clientId: ctx.clientId,
      onProgress: (c, t, s) {
        ctx.progress(c, t, 'Daily candles $c/$t (support levels)');
        // Heartbeat into the activity log so a long prep phase visibly moves.
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
    ctx.log('Hammer: daily candles loaded for ${_dailyData.length} stocks.');
  }

  @override
  Future<BacktestDayResult?> backtestDayAsync(BacktestDayContext ctx) async {
    final p = HammerLabParams(ctx.params);
    final tradeDay = DateTime.parse(ctx.dateStr);

    int stocksScanned = 0;
    int triggers = 0;
    final dayRejects = <String, int>{};
    final trades = <StrategyTradeModel>[];

    // With caps off the LAB scans all ~500 stocks per day. Doing that in one
    // synchronous block starves the Dart GC — the per-stock level/log garbage
    // can't be reclaimed, the heap balloons to multiple GB and the OS kills the
    // app — and it freezes the UI thread (ANR). Yielding to the event loop
    // every [yieldEvery] stocks gives Dart a safepoint to run the GC (heap
    // stays bounded) and lets the UI breathe. Pure scheduling — it changes no
    // value, so the trades/logs are identical to the synchronous path. (S1
    // never needs this: its trade cap stops the loop after ~20 stocks/day.)
    //
    // 5, not 25: at ~107 ms/stock on a phone, 25 stocks between yields is ~2.7s
    // average and a heavy batch + a GC pause occasionally blew past Android's 5s
    // ANR limit (killed mid-chunk-2). 5 keeps each block ~0.5s — comfortably
    // under the ANR window — and ~5× lowers the per-chunk heap peak.
    const yieldEvery = 5;
    int processed = 0;

    for (final secId in ctx.securityIds) {
      // Day cap — mirrors orchestrator: stop processing more stocks.
      if (p.maxTradesPerDay > 0 && trades.length >= p.maxTradesPerDay) break;
      if (++processed % yieldEvery == 0) await Future.delayed(Duration.zero);

      final byDate = ctx.intradayByDate(secId);
      if (byDate == null) continue;
      final today = byDate[ctx.dateStr];
      if (today == null || today.length < 4) continue; // orchestrator: <4 skip

      final daily = _dailyData[secId];
      final dailyBefore =
          daily?.where((c) => c.date.isBefore(tradeDay)).toList() ?? const <Candle>[];
      if (dailyBefore.isEmpty) {
        dayRejects['no_daily'] = (dayRejects['no_daily'] ?? 0) + 1;
        continue;
      }
      stocksScanned++;

      // Gap pre-filter (mined, split-validated): skip weak gap-up days.
      final prevClose = dailyBefore.last.close;
      final gapPct =
          prevClose > 0 ? (today.first.open - prevClose) / prevClose * 100 : 0.0;
      if (gapRejected(gapPct, p)) {
        dayRejects['gap_band'] = (dayRejects['gap_band'] ?? 0) + 1;
        continue;
      }

      final scrip = ctx.scripService.findById(secId);
      final symbol = scrip?.symbol ?? secId.toString();

      // Prev-day avg bar range from the prior trading day's intraday bars.
      final priorDates = byDate.keys
          .where((d) => d.compareTo(ctx.dateStr) < 0)
          .toList()
        ..sort();
      double prevDayAvgRange = 0;
      if (priorDates.isNotEmpty) {
        final prevBars = byDate[priorDates.last]!;
        if (prevBars.isNotEmpty) {
          prevDayAvgRange =
              prevBars.fold<double>(0, (s, c) => s + (c.high - c.low)) /
                  prevBars.length;
        }
      }

      final levels = computeDayLevels(dailyBefore, ctx.params);

      // Support-research diagnostic (LAB): record the first in-window candle
      // that has the right geometry but lands at no level — a near-miss that
      // shows where the support net has holes. Pure logging; never affects
      // entries (the forward bounce it logs is look-ahead, for the log only).
      if (p.logSupportMiss) {
        _logSupportMiss(ctx, secId, symbol, today, levels, p);
      }

      final scan = scanForTrigger(
        todayCandles: today,
        levels: levels,
        prevDayAvgRange: prevDayAvgRange,
        params: ctx.params,
      );

      if (!scan.passed) {
        final stage = scan.rejectStage ?? 'unknown';
        dayRejects[stage] = (dayRejects[stage] ?? 0) + 1;
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] $symbol $stage: ${scan.rejectDetail}',
            {'date': ctx.dateStr, 'symbol': symbol, 'stage': stage, 'detail': scan.rejectDetail});
        continue;
      }

      // Liquidity filter (mined, cross-year robust). avgVol uses only prior
      // days → look-ahead-safe and identical to live. Camarilla-L3 levels bypass.
      if (!passesLiquidity(_avgDailyVolume(dailyBefore, 20), scan.supportNote, p)) {
        dayRejects['liquidity'] = (dayRejects['liquidity'] ?? 0) + 1;
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] $symbol liquidity: avgVol ${_avgDailyVolume(dailyBefore, 20).toStringAsFixed(0)} ≥ ${p.maxAvgDailyVol.toStringAsFixed(0)} (no CAM_L3 bypass)',
            {'date': ctx.dateStr, 'symbol': symbol, 'stage': 'liquidity'});
        continue;
      }

      triggers++;
      final k = scan.triggerIndex!;
      final trig = today[k];
      final trigTime =
          '${trig.date.hour.toString().padLeft(2, "0")}:${trig.date.minute.toString().padLeft(2, "0")}';
      ctx.log('TRIGGER [${ctx.dateStr} $trigTime]: $symbol high=${trig.high} low=${trig.low} @ ${scan.supportNote}');
      // Structured trigger record — mirrors the live `Trigger` payload so the
      // two runs reconcile on (date, symbol, triggerTime, triggerIndex) even
      // for triggers that never fill. This is the "same stock, same candle" check.
      ctx.runLogInfo(
        'Trigger',
        'TRIGGER ${ctx.dateStr} $trigTime $symbol @ ${scan.supportNote}',
        {
          'date': ctx.dateStr,
          'symbol': symbol,
          'securityId': secId,
          'triggerTime': trigTime,
          'triggerIndex': k,
          'triggerHigh': trig.high,
          'triggerLow': trig.low,
          'levels': scan.supportNote,
          'confluence': scan.confluence,
          'pattern': scan.patternType,
          // Support coverage context (LAB): which level type the trigger matched
          // (nearest), and the full level inventory that existed for the stock
          // that day — so the mining can ask "did we trade the best level
          // available, and is the net too sparse/dense?".
          'primaryLevelType': levelType(scan.supportNote ?? ''),
          'levelCountToday': levels.length,
          'levelMix': _levelInventory(levels),
          ..._geo(trig), // trigger-candle geometry (bodyPct/wickPct/rangePct)
          ...?scan.supportFeatures, // freshness/strength/pierce/overhead
          'avgDailyVol':
              double.parse(_avgDailyVolume(dailyBefore, 20).toStringAsFixed(0)),
        },
      );

      final exec = executeFromBars(
        securityId: secId,
        symbol: symbol,
        todayCandles: today,
        triggerIndex: k,
        params: ctx.params,
        configId: 'backtest',
        isPaperTrade: true,
        note: scan.supportNote,
      );

      if (exec == null) {
        dayRejects['no_confirmation'] = (dayRejects['no_confirmation'] ?? 0) + 1;
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] $symbol no_confirmation: next bar never broke trigger high ${trig.high}',
            {'date': ctx.dateStr, 'symbol': symbol, 'stage': 'no_confirmation'});
        continue;
      }
      final trade = exec.trade;

      // Capital cap — mirrors orchestrator (skipped, not counted).
      final capital = trade.quantity * trade.entryPrice;
      if (p.maxCapitalPerTrade > 0 && capital > p.maxCapitalPerTrade) {
        dayRejects['skipped_capital'] = (dayRejects['skipped_capital'] ?? 0) + 1;
        ctx.runLogInfo('Reject',
            '[${ctx.dateStr}] $symbol skipped_capital: ₹${capital.toStringAsFixed(0)} > max ₹${p.maxCapitalPerTrade.toStringAsFixed(0)}',
            {'date': ctx.dateStr, 'symbol': symbol, 'stage': 'skipped_capital'});
        continue;
      }

      trades.add(trade);
      final et =
          '${trade.entryTime!.hour.toString().padLeft(2, '0')}:${trade.entryTime!.minute.toString().padLeft(2, '0')}';
      final risk = trade.entryPrice - trade.stopLoss;
      // Human line (kept stable for quick greps) + a full features payload —
      // everything the post-run mining cross-tabs need, computable at entry
      // or exit, in one structured record per trade.
      ctx.runLogInfo(
        'Trade',
        'Trade record: ${trade.symbol} ${ctx.dateStr} ${exec.exitKind} ₹${trade.pnl.toStringAsFixed(0)}',
        {
          'date': ctx.dateStr,
          'symbol': trade.symbol,
          'pattern': scan.patternType,
          'levels': scan.supportNote,
          'confluence': scan.confluence,
          'primaryLevelType': levelType(scan.supportNote ?? ''),
          'levelCountToday': levels.length,
          'levelMix': _levelInventory(levels),
          ..._geo(trig), // trigger-candle geometry (bodyPct/wickPct/rangePct)
          ...?scan.supportFeatures, // freshness/strength/pierce/overhead
          'supportDistPct': double.parse(scan.supportDistPct.toStringAsFixed(4)),
          'triggerTime':
              '${trig.date.hour.toString().padLeft(2, "0")}:${trig.date.minute.toString().padLeft(2, "0")}',
          'entryTime': et,
          'entryPrice': trade.entryPrice,
          'qty': trade.quantity,
          'stopPct': double.parse(
              (risk / trade.entryPrice * 100).toStringAsFixed(4)),
          'exitKind': exec.exitKind,
          'exitTime':
              '${trade.exitTime!.hour.toString().padLeft(2, "0")}:${trade.exitTime!.minute.toString().padLeft(2, "0")}',
          'exitPrice': trade.exitPrice,
          'pnl': double.parse(trade.pnl.toStringAsFixed(2)),
          'rMult': double.parse((trade.pnl / p.riskPerTrade).toStringAsFixed(3)),
          'mfeR': double.parse(exec.mfeR.toStringAsFixed(3)),
          'maeR': double.parse(exec.maeR.toStringAsFixed(3)),
          // Exit-design inputs (when the run/drawdown happened + hold time):
          'mfeBar': exec.mfeBar,
          'maeBar': exec.maeBar,
          'barsHeld': exec.barsHeld,
          'gapPct': dailyBefore.last.close > 0
              ? double.parse(((today.first.open - dailyBefore.last.close) /
                      dailyBefore.last.close *
                      100)
                  .toStringAsFixed(3))
              : 0,
          'dow': DateTime.parse(ctx.dateStr).weekday,
          // ── Volume & day-type context: lets the mining test CONDITIONED
          // levels ("RN only with a volume surge", "P only on trending days")
          // instead of binary keep/kill decisions per level.
          'trigVol': trig.volume,
          'relVolPrior6': double.parse(_relVolPrior(today, k, 6).toStringAsFixed(2)),
          'relVolDay': double.parse(_relVolDay(today, k).toStringAsFixed(2)),
          // Richer volume (live-safe: trigger + prior bars only — see _volFeatures)
          ..._volFeatures(today, k, _avgDailyVolume(dailyBefore, 20)),
          'avgDailyVol': double.parse(_avgDailyVolume(dailyBefore, 20).toStringAsFixed(0)),
          'cprWidthPct': double.parse(_cprWidthPct(dailyBefore).toStringAsFixed(3)),
        },
      );
      ctx.log('TRADE [${ctx.dateStr} $et]: ${trade.symbol} Entry=${trade.entryPrice.toStringAsFixed(2)} Qty=${trade.quantity} SL=${trade.stopLoss.toStringAsFixed(2)}${trade.target > 0 ? " Tgt=${trade.target.toStringAsFixed(2)}" : " (trail)"} → ${trade.outcome.name}[${exec.exitKind}] Exit=${trade.exitPrice?.toStringAsFixed(2)} P&L=₹${trade.pnl.toStringAsFixed(0)} | ${scan.supportNote}');
    }

    final dayWins = trades.where((t) => t.pnl > 0).length;
    final dayLosses = trades.where((t) => t.pnl < 0).length;
    final dayPnl = trades.fold<double>(0, (sum, t) => sum + t.pnl);
    ctx.log('DAY SUMMARY [${ctx.dateStr}]: Scanned=$stocksScanned Triggers=$triggers Trades=${trades.length} W=$dayWins L=$dayLosses PnL=₹${dayPnl.toStringAsFixed(0)}');

    if (trades.isEmpty && dayRejects.isNotEmpty) {
      final sorted = dayRejects.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = sorted.first;
      ctx.runLogWarn('Diagnosis',
          'WHY ZERO [${ctx.dateStr}]: scanned=$stocksScanned. Dominant reject: ${top.key} (${top.value}×). ${diagnosisHint(top.key) ?? ""}',
          {'date': ctx.dateStr, 'rejects': dayRejects});
    }

    return BacktestDayResult(
      date: ctx.dateStr,
      stocksScanned: stocksScanned,
      stocksAfterElimination: stocksScanned,
      dominanceSignals: triggers,
      tradesEntered: trades.length,
      wins: dayWins,
      losses: dayLosses,
      dayPnl: dayPnl,
      trades: trades,
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Custom engine: Live / Paper
  // ════════════════════════════════════════════════════════════════════════

  @override
  Future<void> runLive(LiveEngineContext ctx) async {
    final prep = await _livePreMarket(ctx);
    if (ctx.stopRequested) return;
    // Entries and exits run CONCURRENTLY over a shared trade list. The exit
    // monitor manages each position from the moment it is appended — so a trade
    // entered at 09:40 is stop/trail-protected from 09:40, exactly like the
    // backtest. (Previously the session ran to completion FIRST and exits only
    // began after the 12:00 entry window, leaving morning trades unmanaged for
    // hours and diverging from the backtest.) The monitor runs until the 15:00
    // hard exit regardless of when the entry window closes.
    final liveTrades = <StrategyTradeModel>[];
    await Future.wait([
      _liveSession(ctx, prep, liveTrades),
      _liveMonitorExits(ctx, liveTrades),
    ]);
  }

  /// Pre-market: daily candles → per-stock day levels; prior-day intraday →
  /// prev-day average bar range (the 4× spike filter baseline).
  Future<({Map<int, List<LabSupportLevel>> levels, Map<int, double> prevAvgRange, Map<int, double> prevClose, Map<int, String> symbols, Map<int, double> avgDailyVol})>
      _livePreMarket(LiveEngineContext ctx) async {
    final p = HammerLabParams(ctx.params);
    final today = DateTime.now();
    final dayMidnight = DateTime(today.year, today.month, today.day);

    ctx.log('Hammer pre-market: daily levels + prev-day range for ${ctx.securityIds.length} stocks...');

    final dailyStart =
        today.subtract(Duration(days: (p.supportLookbackDays * 7 ~/ 5) + 20));
    final dailyData = await CandleRepository.instance.bulkFetchDaily(
      securityIds: ctx.securityIds,
      fromDate: dailyStart,
      toDate: today,
      accessToken: ctx.accessToken,
      clientId: ctx.clientId,
      onProgress: (c, t, s) {
        if (c % 50 == 0 || c == t) {
          ctx.sendUpdate('update', {
            'status': 'running',
            'message': 'Daily candles $c/$t',
            'progress': (c * 100 / t).toInt(),
          });
        }
      },
      isCancelled: () => ctx.stopRequested,
    );
    if (ctx.stopRequested) {
      return (levels: <int, List<LabSupportLevel>>{}, prevAvgRange: <int, double>{}, prevClose: <int, double>{}, symbols: <int, String>{}, avgDailyVol: <int, double>{});
    }
    ctx.log('Daily candles loaded for ${dailyData.length} stocks');

    final levels = <int, List<LabSupportLevel>>{};
    final prevAvgRange = <int, double>{};
    final prevClose = <int, double>{};
    final symbols = <int, String>{};
    final avgDailyVol = <int, double>{}; // 20-day avg vol (prior days) for the liquidity filter

    int done = 0;
    for (final secId in ctx.securityIds) {
      if (ctx.stopRequested) break;
      done++;
      final daily = dailyData[secId];
      if (daily == null || daily.isEmpty) continue;
      final dailyBefore =
          daily.where((c) => c.date.isBefore(dayMidnight)).toList();
      if (dailyBefore.isEmpty) continue;

      final scrip = ctx.scripService.findById(secId);
      symbols[secId] = scrip?.symbol ?? secId.toString();
      levels[secId] = computeDayLevels(dailyBefore, ctx.params);
      prevClose[secId] = dailyBefore.last.close; // for the gap pre-filter
      avgDailyVol[secId] = _avgDailyVolume(dailyBefore, 20); // for the liquidity filter

      // Prior trading day's intraday avg bar range (walk back over weekends).
      double avgRange = 0;
      int daysBack = 0;
      while (avgRange == 0 && daysBack < 7) {
        daysBack++;
        final date = today.subtract(Duration(days: daysBack));
        if (date.weekday == DateTime.saturday ||
            date.weekday == DateTime.sunday) {
          continue;
        }
        try {
          final candles = await ctx.fetchIntraday(secId, '5', date: date);
          if (candles.isNotEmpty) {
            avgRange = candles.fold<double>(0, (s, c) => s + (c.high - c.low)) /
                candles.length;
          }
        } catch (_) {}
      }
      prevAvgRange[secId] = avgRange;

      if (done % 25 == 0 || done == ctx.securityIds.length) {
        ctx.sendUpdate('update', {
          'status': 'running',
          'message': 'Pre-market $done/${ctx.securityIds.length}',
          'progress': (done * 100 / ctx.securityIds.length).toInt(),
        });
      }
    }

    ctx.recordActiveStocks(levels.length);
    ctx.log('Hammer pre-market complete: ${levels.length} stocks with levels');
    ctx.addKeyEvent('Hammer pre-market: ${levels.length} stocks ready');
    return (levels: levels, prevAvgRange: prevAvgRange, prevClose: prevClose, symbols: symbols, avgDailyVol: avgDailyVol);
  }

  /// Session: at each 5-min slot, scan closed bars for new triggers; for a
  /// pending trigger, watch the k+1 bar — poll LTP and fill the buy-stop at
  /// max(trigger.high, k+1 open-if-gapped); abandon if k+1 closes below.
  Future<void> _liveSession(
      LiveEngineContext ctx,
      ({Map<int, List<LabSupportLevel>> levels, Map<int, double> prevAvgRange, Map<int, double> prevClose, Map<int, String> symbols, Map<int, double> avgDailyVol})
          prep,
      List<StrategyTradeModel> liveTrades) async {
    final p = HammerLabParams(ctx.params);
    final today = DateTime.now();
    // Slots: first closed bar lands at windowStart+5min; keep polling until
    // the bar AFTER the last possible trigger (windowEnd) has closed.
    // `liveTrades` is shared with the concurrent exit monitor — every entry we
    // append is protected from the moment it fills (matches the backtest, which
    // applies stop/trail/time from the entry bar onward).
    final windowEndMin = p.windowEndHour * 60 + p.windowEndMin;
    final doneStocks = <int>{}; // one attempt per stock-day (traded or failed)
    final todayCandles = <int, List<Candle>>{};

    var slot = DateTime(
        today.year, today.month, today.day, p.windowStartHour, p.windowStartMin)
        .add(const Duration(minutes: 5));
    final lastSlot = DateTime(today.year, today.month, today.day,
            windowEndMin ~/ 60, windowEndMin % 60)
        .add(const Duration(minutes: 10)); // trigger@12:00 → k+1 closes 12:10

    while (!slot.isAfter(lastSlot)) {
      if (ctx.stopRequested) return;
      if (p.maxTradesPerDay > 0 && liveTrades.length >= p.maxTradesPerDay) break;

      final slotLabel =
          '${slot.hour.toString().padLeft(2, "0")}:${slot.minute.toString().padLeft(2, "0")}';
      // Wait for the slot (+5s candle-close buffer).
      final targetTime = slot.add(const Duration(seconds: 5));
      final now = DateTime.now();
      if (targetTime.isAfter(now)) {
        ctx.sendUpdate('update',
            {'status': 'running', 'message': 'Waiting for $slotLabel candle...'});
        final waitEnd = now.add(targetTime.difference(now));
        while (DateTime.now().isBefore(waitEnd)) {
          if (ctx.stopRequested) return;
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      // Fetch closed bars for stocks still in play.
      final slotMinute = slot.hour * 60 + slot.minute;
      final inPlay = prep.levels.keys
          .where((id) => !doneStocks.contains(id))
          .toList();
      for (final secId in inPlay) {
        if (ctx.stopRequested) return;
        try {
          final candles = await ctx.fetchIntraday(secId, '5', date: today);
          if (candles.isEmpty) continue;
          final closed = candles
              .where((c) => c.date.hour * 60 + c.date.minute < slotMinute)
              .toList()
              .reversed
              .toList(); // oldest first
          if (closed.isNotEmpty) todayCandles[secId] = closed;
        } catch (_) {}
      }

      // Scan each in-play stock for its first trigger among CLOSED bars.
      // The k+1 bar may already be closed (catch-up → bar semantics, same as
      // backtest) or still forming (→ LTP buy-stop watch below).
      final pendingStops = <({int secId, Candle trigger, String note})>[];
      for (final secId in inPlay) {
        if (p.maxTradesPerDay > 0 && liveTrades.length >= p.maxTradesPerDay) break;
        final bars = todayCandles[secId];
        if (bars == null || bars.length < 2) continue;
        // Gap pre-filter — same rule as backtest (weak gap-up reject band).
        final pc = prep.prevClose[secId] ?? 0;
        if (pc > 0) {
          final gapPct = (bars.first.open - pc) / pc * 100;
          if (gapRejected(gapPct, p)) {
            doneStocks.add(secId);
            _liveReject(ctx, today, secId, prep.symbols[secId] ?? '$secId',
                'gap_band', 'gap ${gapPct.toStringAsFixed(2)}% in reject band');
            continue;
          }
        }
        final scan = scanForTrigger(
          todayCandles: bars,
          levels: prep.levels[secId]!,
          prevDayAvgRange: prep.prevAvgRange[secId] ?? 0,
          params: ctx.params,
        );
        if (!scan.passed) continue; // not rejected-for-the-day: more bars may come
        // Liquidity filter — identical gate to backtest. avgVol was precomputed
        // in pre-market from prior daily bars (no intraday data), so live and
        // backtest decide this the same way. Camarilla-L3 levels bypass the cap.
        if (!passesLiquidity(prep.avgDailyVol[secId] ?? 0, scan.supportNote, p)) {
          doneStocks.add(secId);
          _liveReject(ctx, today, secId, prep.symbols[secId] ?? '$secId',
              'liquidity',
              'avgVol ${(prep.avgDailyVol[secId] ?? 0).toStringAsFixed(0)} ≥ ${p.maxAvgDailyVol.toStringAsFixed(0)} (no CAM_L3 bypass)');
          continue;
        }
        final k = scan.triggerIndex!;
        final symbol = prep.symbols[secId] ?? secId.toString();
        final trig = bars[k];

        // Structured trigger record — same shape/keys as the backtest `Trigger`
        // record, so the day's two logs reconcile on (date, symbol, triggerTime,
        // triggerIndex). Emitted for every passing trigger, filled or not.
        ctx.runLogInfo(
          'Trigger',
          'TRIGGER ${_fmt(today)} ${_hm(trig.date)} $symbol @ ${scan.supportNote}',
          {
            'date': _fmt(today),
            'symbol': symbol,
            'securityId': secId,
            'triggerTime': _hm(trig.date),
            'triggerIndex': k,
            'triggerHigh': trig.high,
            'triggerLow': trig.low,
            'levels': scan.supportNote,
            'confluence': scan.confluence,
            'pattern': scan.patternType,
            'avgDailyVol':
                double.parse((prep.avgDailyVol[secId] ?? 0).toStringAsFixed(0)),
          },
        );

        if (k + 1 < bars.length) {
          // k+1 already closed → resolve with bar semantics (identical to
          // backtest): either it broke the high (enter at max(high, open),
          // walk remaining LIVE via LTP) or it didn't (done for the day).
          doneStocks.add(secId);
          final trade = _liveEnterFromClosedBar(
              ctx, p, secId, symbol, bars, k, scan.supportNote ?? '');
          if (trade != null) {
            liveTrades.add(trade);
          } else {
            _liveReject(ctx, today, secId, symbol, 'no_confirmation',
                'next bar never broke trigger high ${trig.high}');
          }
        } else {
          // k+1 is the currently forming bar → arm a buy-stop at the high.
          doneStocks.add(secId);
          pendingStops.add((secId: secId, trigger: trig, note: scan.supportNote ?? ''));
          ctx.recordSignal();
          ctx.log('TRIGGER: $symbol high=${trig.high} low=${trig.low} @ ${scan.supportNote} — buy-stop armed for the next bar');
          ctx.addKeyEvent('TRIGGER: $symbol buy-stop @ ${trig.high}');
          ctx.sendUpdate('signal_found', {
            'symbol': symbol,
            'securityId': secId,
            'entryPrice': trig.high,
            'stopLoss': trig.low,
            'reason': 'Hammer/Dominance @ ${scan.supportNote}',
          });
        }
      }

      // Poll LTP through the k+1 bar for armed buy-stops.
      if (pendingStops.isNotEmpty) {
        final barEnd = slot.add(const Duration(minutes: 5));
        final stillPending = List.of(pendingStops);
        // Stocks already observed below the stop this bar. If the FIRST LTP we
        // ever see is already above the trigger high, the bar gapped above —
        // fill at that LTP (C#'s max(high, k+1 open)); otherwise the stop
        // fills at the trigger high, like a real stop order.
        final seenBelow = <int>{};
        while (!ctx.stopRequested &&
            stillPending.isNotEmpty &&
            DateTime.now().isBefore(barEnd)) {
          if (p.maxTradesPerDay > 0 && liveTrades.length >= p.maxTradesPerDay) break;
          try {
            final ltpMap = await ctx
                .fetchLtpBatch(stillPending.map((e) => e.secId).toList());
            for (final pend in List.of(stillPending)) {
              final ltp = ltpMap[pend.secId];
              if (ltp == null || ltp <= 0) continue;
              if (ltp < pend.trigger.high) {
                seenBelow.add(pend.secId);
                continue;
              }
              {
                final fill = seenBelow.contains(pend.secId)
                    ? pend.trigger.high // crossed up through the stop
                    : ltp; // first sight already above = gapped open
                final symbol = prep.symbols[pend.secId] ?? '${pend.secId}';
                final trade = _buildLiveTrade(
                    ctx, p, pend.secId, symbol, pend.trigger, fill);
                stillPending.remove(pend);
                if (trade != null) {
                  liveTrades.add(trade);
                  ctx.recordTrade(trade);
                  _logLiveEntry(ctx, trade, pend.trigger, pend.note,
                      seenBelow.contains(pend.secId)
                          ? 'buystop-cross'
                          : 'buystop-gap');
                  ctx.log('TRADE: ${trade.symbol} Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss}${trade.target > 0 ? " Target=${trade.target}" : " (trail)"} | ${pend.note}');
                  ctx.addKeyEvent('TRADE: ${trade.symbol} Qty=${trade.quantity} @ ${trade.entryPrice}');
                  ctx.sendUpdate('trade_update', {
                    'type': 'entry',
                    'symbol': trade.symbol,
                    'securityId': trade.securityId,
                    'entryPrice': trade.entryPrice,
                    'quantity': trade.quantity,
                    'stopLoss': trade.stopLoss,
                    'target': trade.target,
                    'isPaper': trade.isPaperTrade,
                  });
                  if (!ctx.isPaperTrading) await ctx.placeLiveOrder(trade);
                }
              }
            }
          } catch (e) {
            ctx.log('Buy-stop LTP poll error: $e');
            await Future.delayed(const Duration(seconds: 1));
          }
        }
        for (final pend in stillPending) {
          final symbol = prep.symbols[pend.secId] ?? '${pend.secId}';
          ctx.log('NO FILL: $symbol — next bar never broke trigger high ${pend.trigger.high}');
          _liveReject(ctx, today, pend.secId, symbol, 'no_confirmation',
              'buy-stop unfilled — next bar never broke trigger high ${pend.trigger.high}');
        }
      }

      slot = slot.add(const Duration(minutes: 5));
    }

    // End-of-session reject parity: every level-stock without a terminal
    // outcome above (gap / liquidity / trigger) gets exactly one logged reason
    // here — a final scan stage if it never triggered, or no_data. Mirrors the
    // backtest's one-Reject-per-stock so a missed-trade diff shows precisely why
    // live skipped any stock the backtest traded.
    int sweptRejects = 0;
    for (final secId in prep.levels.keys) {
      if (doneStocks.contains(secId)) continue;
      final symbol = prep.symbols[secId] ?? '$secId';
      final bars = todayCandles[secId];
      if (bars == null || bars.length < 2) {
        _liveReject(ctx, today, secId, symbol, 'no_data',
            'no intraday bars in the 09:30–12:00 window');
        sweptRejects++;
        continue;
      }
      final scan = scanForTrigger(
        todayCandles: bars,
        levels: prep.levels[secId]!,
        prevDayAvgRange: prep.prevAvgRange[secId] ?? 0,
        params: ctx.params,
      );
      _liveReject(
          ctx,
          today,
          secId,
          symbol,
          scan.passed ? 'no_fill' : (scan.rejectStage ?? 'no_trigger'),
          scan.rejectDetail ?? 'no qualifying hammer/dominance setup at support');
      sweptRejects++;
    }
    ctx.log('Hammer session complete (entry window closed). Trades: ${liveTrades.length}, end-of-day rejects logged: $sweptRejects');
  }

  /// Catch-up path: trigger AND its k+1 bar are both already closed. Resolve
  /// entry by bar semantics; if filled, return an OPEN trade for live exit
  /// monitoring (entry price exactly as backtest: max(trigger high, k+1 open)).
  StrategyTradeModel? _liveEnterFromClosedBar(
      LiveEngineContext ctx,
      HammerLabParams p,
      int secId,
      String symbol,
      List<Candle> bars,
      int triggerIdx,
      String note) {
    final trigger = bars[triggerIdx];
    final entryBar = bars[triggerIdx + 1];
    ctx.recordSignal();
    ctx.log('TRIGGER (catch-up): $symbol high=${trigger.high} low=${trigger.low} @ $note');

    if (p.requireConfirmation && entryBar.high < trigger.high) {
      ctx.log('NO FILL: $symbol — next bar high ${entryBar.high} never broke trigger high ${trigger.high}');
      return null;
    }
    final entryBarMin = entryBar.date.hour * 60 + entryBar.date.minute;
    if (entryBarMin >= p.hardExitHour * 60 + p.hardExitMin) return null;
    final fill = p.requireConfirmation
        ? (trigger.high > entryBar.open ? trigger.high : entryBar.open)
        : entryBar.open;
    final trade = _buildLiveTrade(ctx, p, secId, symbol, trigger, fill);
    if (trade != null) {
      ctx.recordTrade(trade);
      _logLiveEntry(ctx, trade, trigger, note, 'catchup-bar');
      ctx.log('TRADE (catch-up): $symbol Qty=${trade.quantity} Entry=${trade.entryPrice} SL=${trade.stopLoss}');
      ctx.sendUpdate('trade_update', {
        'type': 'entry',
        'symbol': trade.symbol,
        'securityId': trade.securityId,
        'entryPrice': trade.entryPrice,
        'quantity': trade.quantity,
        'stopLoss': trade.stopLoss,
        'target': trade.target,
        'isPaper': trade.isPaperTrade,
      });
      if (!ctx.isPaperTrading) ctx.placeLiveOrder(trade);
    }
    return trade;
  }

  StrategyTradeModel? _buildLiveTrade(LiveEngineContext ctx, HammerLabParams p,
      int secId, String symbol, Candle trigger, double entryPrice) {
    final triggerRange = trigger.high - trigger.low;
    final stopLoss = trigger.low * (1 - p.stopBufferPct / 100) -
        p.stopBufferRangePct / 100 * triggerRange;
    final risk = entryPrice - stopLoss;
    if (risk <= 0) return null;
    final quantity = (p.riskPerTrade / risk).floor();
    if (quantity <= 0) return null;
    final capital = quantity * entryPrice;
    if (p.maxCapitalPerTrade > 0 && capital > p.maxCapitalPerTrade) {
      ctx.log('SKIPPED (capital): $symbol ₹${capital.toStringAsFixed(0)} > max ₹${p.maxCapitalPerTrade.toStringAsFixed(0)}');
      return null;
    }
    final target = p.targetR > 0 ? entryPrice + p.targetR * risk : 0.0;
    return StrategyTradeModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      strategyConfigId: ctx.configId,
      signalId: 'hammer_$secId',
      securityId: secId,
      symbol: symbol,
      status: TradeStatus.open,
      isPaperTrade: ctx.isPaperTrading,
      entryPrice: entryPrice,
      quantity: quantity,
      entryTime: DateTime.now(),
      stopLoss: stopLoss,
      target: target,
      costModelPct: p.costModelRoundTripPct,
    );
  }

  /// LTP exit monitor: stop (initial or trailed) → target → 15:00 square-off.
  /// Trailing mirrors the backtest: high-water from observed LTP, trail
  /// activates at +ActivateR and sits GapR below the high-water mark.
  Future<void> _liveMonitorExits(
      LiveEngineContext ctx, List<StrategyTradeModel> trades) async {
    final p = HammerLabParams(ctx.params);
    final now = DateTime.now();
    final hardExit = DateTime(
        now.year, now.month, now.day, p.hardExitHour, p.hardExitMin);

    // Per-trade trailing state, lazily initialised as entries appear — the
    // session appends to the shared `trades` list concurrently, so positions
    // are picked up the moment they fill.
    final state = <String, ({double effectiveStop, double highWater, double risk})>{};

    ctx.log('Hammer exit monitor armed until ${p.hardExitHour.toString().padLeft(2, "0")}:${p.hardExitMin.toString().padLeft(2, "0")} (manages each position from entry)...');

    void close(StrategyTradeModel t, double px, TradeOutcome outcome, String tag) {
      t.status = TradeStatus.closed;
      t.exitPrice = px;
      t.exitTime = DateTime.now();
      t.outcome = outcome;
      ctx.log('$tag: ${t.symbol} @ ${px.toStringAsFixed(2)} P&L=₹${t.pnl.toStringAsFixed(0)}');
      ctx.addKeyEvent('$tag: ${t.symbol} @ ${px.toStringAsFixed(2)} P&L=₹${t.pnl.toStringAsFixed(0)}');
      // Structured exit record — exitKind vocabulary matches the backtest
      // (stop/trail/target/time) so the two runs compare exit-for-exit.
      final exitT = t.exitTime ?? DateTime.now();
      ctx.runLogInfo(
        'LiveExit',
        'EXIT ${t.symbol} ${_exitKindFromTag(tag)} @ ${px.toStringAsFixed(2)} P&L=₹${t.pnl.toStringAsFixed(0)}',
        {
          'date': _fmt(t.entryTime ?? exitT),
          'symbol': t.symbol,
          'securityId': t.securityId,
          'entryTime': _hm(t.entryTime ?? exitT),
          'exitTime': _hm(exitT),
          'exitKind': _exitKindFromTag(tag),
          'entryPrice': t.entryPrice,
          'exitPrice': px,
          'qty': t.quantity,
          'pnl': double.parse(t.pnl.toStringAsFixed(2)),
        },
      );
      ctx.sendUpdate('trade_update', {
        'type': outcome == TradeOutcome.stopLoss
            ? 'sl_hit'
            : outcome == TradeOutcome.target
                ? 'target_hit'
                : 'eod_exit',
        'symbol': t.symbol,
        'securityId': t.securityId,
        'entryPrice': t.entryPrice,
        'exitPrice': t.exitPrice,
        'quantity': t.quantity,
        'pnl': t.pnl,
        'outcome': t.outcome.name,
        'isPaper': t.isPaperTrade,
      });
    }

    while (!ctx.stopRequested && DateTime.now().isBefore(hardExit)) {
      final open = trades.where((t) => t.status == TradeStatus.open).toList();
      if (open.isEmpty) {
        // No open position yet (or all closed) — keep waiting; the session can
        // still append new entries until the 12:00 window closes.
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      try {
        final ltpMap =
            await ctx.fetchLtpBatch(open.map((t) => t.securityId).toList());
        for (final t in open) {
          final ltp = ltpMap[t.securityId];
          if (ltp == null || ltp <= 0) continue;
          final s = state.putIfAbsent(
              t.id,
              () => (
                    effectiveStop: t.stopLoss,
                    highWater: t.entryPrice,
                    risk: t.entryPrice - t.stopLoss,
                  ));

          // 1. Stop (initial or trailed).
          if (ltp <= s.effectiveStop) {
            close(t, s.effectiveStop,
                TradeOutcome.stopLoss,
                s.effectiveStop > t.stopLoss ? 'TRAIL STOP' : 'SL HIT');
            continue;
          }
          // 2. Optional fixed R-target (only when targetR > 0; off by default).
          if (t.target > 0 && ltp >= t.target) {
            close(t, t.target, TradeOutcome.target, 'TARGET HIT');
            continue;
          }
          // 3. Trail update for subsequent polls.
          if (p.useTrailingStop) {
            var hw = s.highWater;
            if (ltp > hw) hw = ltp;
            var eff = s.effectiveStop;
            if (hw >= t.entryPrice + p.trailActivateR * s.risk) {
              final trailed = hw - p.trailGapR * s.risk;
              if (trailed > eff) eff = trailed;
            }
            state[t.id] = (effectiveStop: eff, highWater: hw, risk: s.risk);
          }
        }
      } catch (e) {
        ctx.log('Hammer exit monitor error: $e');
      }
      await Future.delayed(const Duration(seconds: 3));
    }

    // Hard time exit at 15:00 — square off at latest LTP.
    final remaining = trades.where((t) => t.status == TradeStatus.open).toList();
    if (remaining.isNotEmpty && !ctx.stopRequested) {
      ctx.log('Hard exit — squaring off ${remaining.length} position(s)');
      Map<int, double> ltpMap = const {};
      try {
        ltpMap = await ctx.fetchLtpBatch(remaining.map((t) => t.securityId).toList());
      } catch (_) {}
      for (final t in remaining) {
        final ltp = ltpMap[t.securityId];
        final exitPx = (ltp != null && ltp > 0) ? ltp : t.entryPrice;
        close(t, exitPx, TradeOutcome.endOfDay, 'TIME EXIT');
      }
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// HH:MM — the candle identifier used for live↔backtest reconciliation.
  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// Maps the exit-monitor's human tag to the backtest's `exitKind` vocabulary
  /// (stop/trail/target/time) so live and backtest exit records compare directly.
  static String _exitKindFromTag(String tag) => tag == 'TRAIL STOP'
      ? 'trail'
      : tag == 'SL HIT'
          ? 'stop'
          : tag == 'TARGET HIT'
              ? 'target'
              : 'time';

  /// One structured live reject record — same `Reject` tag, stage vocabulary
  /// and shape the backtest emits in `backtestDay`, so a missed-trade diff is
  /// diagnosable: for any stock that traded in backtest but not live, the live
  /// log now says exactly why (gap_band / liquidity / no_confirmation / a scan
  /// stage / no_data). Mirrors the backtest's one-outcome-per-stock contract.
  void _liveReject(LiveEngineContext ctx, DateTime day, int secId, String symbol,
      String stage, String detail) {
    ctx.runLogInfo('Reject', '[${_fmt(day)}] $symbol $stage: $detail', {
      'date': _fmt(day),
      'symbol': symbol,
      'securityId': secId,
      'stage': stage,
      'detail': detail,
    });
  }

  /// One structured live-entry record, keyed/shaped to line up with the
  /// backtest `Trade` payload (join on date+symbol; compare triggerTime ↔
  /// triggerTime and entryCandle ↔ entryTime). [fillMode] records HOW live
  /// filled (catch-up bar vs buy-stop cross vs gap) — the documented sources of
  /// the small entry-price differences vs backtest's bar-semantics fill.
  void _logLiveEntry(LiveEngineContext ctx, StrategyTradeModel t, Candle trigger,
      String note, String fillMode) {
    final risk = t.entryPrice - t.stopLoss;
    final entryT = t.entryTime ?? DateTime.now();
    ctx.runLogInfo(
      'LiveEntry',
      'ENTRY ${t.symbol} @ ${t.entryPrice.toStringAsFixed(2)} ($fillMode)',
      {
        'date': _fmt(entryT),
        'symbol': t.symbol,
        'securityId': t.securityId,
        'triggerTime': _hm(trigger.date),
        'entryCandle': _hm(trigger.date.add(const Duration(minutes: 5))),
        'entryWallClock': _hm(entryT),
        'entryPrice': t.entryPrice,
        'qty': t.quantity,
        'stopLoss': t.stopLoss,
        'stopPct': double.parse((risk / t.entryPrice * 100).toStringAsFixed(4)),
        'levels': note,
        'fillMode': fillMode,
      },
    );
  }

  // ── Mining feature helpers (computable at entry — no look-ahead) ─────────

  /// Trigger volume ÷ average of the [n] bars before it (volume surge).
  static double _relVolPrior(List<Candle> bars, int k, int n) {
    final s = k - n < 0 ? 0 : k - n;
    double sum = 0;
    int cnt = 0;
    for (int j = s; j < k; j++) {
      sum += bars[j].volume;
      cnt++;
    }
    final avg = cnt > 0 ? sum / cnt : 0;
    return avg > 0 ? bars[k].volume / avg : 0;
  }

  /// Trigger volume ÷ average of all bars from open through the trigger.
  static double _relVolDay(List<Candle> bars, int k) {
    double sum = 0;
    for (int j = 0; j <= k; j++) {
      sum += bars[j].volume;
    }
    final avg = sum / (k + 1);
    return avg > 0 ? bars[k].volume / avg : 0;
  }

  /// Richer volume bundle for mining — every field uses ONLY the trigger candle
  /// and EARLIER bars, so it is available LIVE. (At entry the buy candle k+1 is
  /// still forming; its final volume is unknown, so it must never feed a rule —
  /// using it would be look-ahead that works only in the backtest.) Captures the
  /// trigger's surge from a few angles + whether volume was building up.
  static Map<String, dynamic> _volFeatures(
      List<Candle> bars, int k, double avgDailyVol) {
    double avgPrior(int n) {
      final s = k - n < 0 ? 0 : k - n;
      double sum = 0;
      int cnt = 0;
      for (int j = s; j < k; j++) {
        sum += bars[j].volume;
        cnt++;
      }
      return cnt > 0 ? sum / cnt : 0;
    }

    final trigVol = bars[k].volume;
    final p3 = avgPrior(3);
    // Volume rising into the trigger (accumulation vs a one-off spike) — all
    // bars at/before the trigger, so live-safe.
    final rising = k >= 2 &&
        bars[k].volume > bars[k - 1].volume &&
        bars[k - 1].volume > bars[k - 2].volume;
    return {
      'relVolPrior3':
          double.parse((p3 > 0 ? trigVol / p3 : 0).toStringAsFixed(2)),
      'trigVolPctDaily': avgDailyVol > 0
          ? double.parse((trigVol / avgDailyVol * 100).toStringAsFixed(3))
          : 0,
      'volRising': rising,
    };
  }

  /// Average daily share volume over the most recent [days] daily candles.
  /// Liquidity gate: trade only if the 20-day avg volume is below the cap, OR
  /// the matched level is a Camarilla L3 (the one level type robust at any
  /// liquidity). A cap of 0 disables the filter. [avgVol] is built from prior
  /// days only, so this is look-ahead-safe and computes identically in backtest
  /// and live — which is why the two agree.
  static bool passesLiquidity(double avgVol, String? supportNote, HammerLabParams p) {
    if (p.maxAvgDailyVol <= 0) return true;
    if (avgVol < p.maxAvgDailyVol) return true;
    return (supportNote ?? '').contains('CAM_L3'); // Camarilla-L3 bypass
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

  /// Yesterday's CPR band width as % of pivot — narrow = trending day,
  /// wide = rangebound (the classic Indian day-type signal).
  static double _cprWidthPct(List<Candle> daily) {
    if (daily.isEmpty) return 0;
    final y = daily.last;
    final p = (y.high + y.low + y.close) / 3;
    var bc = (y.high + y.low) / 2, tc = 2 * p - bc;
    if (bc > tc) {
      final t = bc;
      bc = tc;
      tc = t;
    }
    return p > 0 ? (tc - bc) / p * 100 : 0;
  }

  // ── Support-research helpers (LAB) ───────────────────────────────────────

  /// Classify a level tag/note into its type token (everything before the
  /// first space): CAM_L3, CPR, vCPR, P, S1, S2, PDL, PDC, PDH, RN, ZONE, TL.
  /// Given a full match note (e.g. "CAM_L3 123.45 + P 120.00 (conf 2)") this
  /// returns the PRIMARY (nearest) level's type, since atSupport sorts the
  /// matches by distance and lists the nearest first.
  static String levelType(String tagOrNote) {
    final t = tagOrNote.trim();
    if (t.isEmpty) return 'NONE';
    final sp = t.indexOf(' ');
    return sp < 0 ? t : t.substring(0, sp);
  }

  /// Per-stock-day inventory of the levels we built, counted by type — the
  /// coverage context the support mining needs ("we matched CAM_L3, but 8 other
  /// levels existed that day").
  static Map<String, int> _levelInventory(List<LabSupportLevel> levels) {
    final m = <String, int>{};
    for (final z in levels) {
      final t = levelType(z.tag);
      m[t] = (m[t] ?? 0) + 1;
    }
    return m;
  }

  /// Trigger-candle geometry as % of the candle — lets the mining ask whether
  /// textbook hammers/dominance candles outperform marginal ones and tune the
  /// pattern thresholds from data. NOT recoverable after the run, so logged
  /// now. Spread into the Trigger/Trade/SupportMiss payloads.
  static Map<String, dynamic> _geo(Candle c) {
    final range = c.high - c.low;
    if (range <= 0) {
      return {
        'bodyPct': 0.0,
        'lowerWickPct': 0.0,
        'upperWickPct': 0.0,
        'rangePct': 0.0,
      };
    }
    final body = (c.close - c.open).abs();
    final lowerWick = (c.open < c.close ? c.open : c.close) - c.low;
    final upperWick = c.high - (c.open > c.close ? c.open : c.close);
    return {
      'bodyPct': double.parse((body / range * 100).toStringAsFixed(2)),
      'lowerWickPct': double.parse((lowerWick / range * 100).toStringAsFixed(2)),
      'upperWickPct': double.parse((upperWick / range * 100).toStringAsFixed(2)),
      'rangePct': double.parse(
          (c.close > 0 ? range / c.close * 100 : 0).toStringAsFixed(3)),
    };
  }

  /// Nearest level to a price by band-center distance (%). Used by the
  /// SupportMiss diagnostic to name the closest level we DID build when a
  /// geometry candle matched none of them.
  ({String tag, String type, double distPct, bool fresh}) _nearestLevel(
      double price, List<LabSupportLevel> levels) {
    String tag = '';
    String type = 'NONE';
    bool fresh = false;
    double best = double.infinity;
    for (final z in levels) {
      final center = (z.lo + z.hi) / 2;
      if (center <= 0) continue;
      final d = (price - center).abs() / center * 100;
      if (d < best) {
        best = d;
        tag = z.tag;
        type = levelType(z.tag);
        fresh = z.fresh;
      }
    }
    return (
      tag: tag,
      type: type,
      distPct: best == double.infinity ? -1.0 : best,
      fresh: fresh
    );
  }

  /// LAB support diagnostic: find the FIRST in-window candle that passes the
  /// hammer/dominance geometry but is at NO level we built, and log it with the
  /// nearest level + the forward bounce/drawdown over the next N bars. One
  /// record per stock-day. The forward look-ahead is used ONLY for this log and
  /// never feeds an entry decision. Answers "is our support net missing real
  /// floors?" — many high-bounce misses ⇒ the level construction needs work.
  void _logSupportMiss(BacktestDayContext ctx, int secId, String symbol,
      List<Candle> today, List<LabSupportLevel> levels, HammerLabParams p) {
    final windowStart = p.windowStartHour * 60 + p.windowStartMin;
    final windowEnd = p.windowEndHour * 60 + p.windowEndMin;
    final fwd = p.supportMissForwardBars;

    for (int k = 0; k < today.length; k++) {
      final c = today[k];
      final m = c.date.hour * 60 + c.date.minute;
      if (m < windowStart || m > windowEnd) continue;

      final range = c.high - c.low;
      if (range <= 0) continue;
      final body = (c.close - c.open).abs();
      final lowerWick = (c.open < c.close ? c.open : c.close) - c.low;
      final upperWick = c.high - (c.open > c.close ? c.open : c.close);
      final isHam =
          p.allowHammer && isHammer(c, range, body, lowerWick, upperWick, p);
      final isDom = p.allowDominanceCandle &&
          isDominance(c, range, body, upperWick, lowerWick, p);
      if (!isHam && !isDom) continue;

      // Geometry passed — is it at a level? If yes, not a miss; keep scanning.
      if (atSupport(c, levels, p).at) continue;

      // A real near-miss: geometry candle at no level. Measure the forward
      // bounce/drawdown over the next [fwd] bars (look-ahead, for the log only).
      final near = _nearestLevel(c.low, levels);
      double maxHigh = c.high, minLow = c.low;
      final end = (k + fwd < today.length) ? k + fwd : today.length - 1;
      for (int j = k + 1; j <= end; j++) {
        if (today[j].high > maxHigh) maxHigh = today[j].high;
        if (today[j].low < minLow) minLow = today[j].low;
      }
      final bouncePct = c.close > 0 ? (maxHigh - c.close) / c.close * 100 : 0.0;
      final ddPct = c.close > 0 ? (c.close - minLow) / c.close * 100 : 0.0;
      final tt =
          '${c.date.hour.toString().padLeft(2, "0")}:${c.date.minute.toString().padLeft(2, "0")}';

      ctx.runLogInfo(
        'SupportMiss',
        '[${ctx.dateStr}] $symbol $tt ${isHam ? "hammer" : "dom"}@${c.low.toStringAsFixed(2)} at NO level (nearest ${near.tag} ${near.distPct.toStringAsFixed(2)}%) → bounce ${bouncePct.toStringAsFixed(2)}% over ${end - k} bars',
        {
          'date': ctx.dateStr,
          'symbol': symbol,
          'securityId': secId,
          'candleTime': tt,
          'pattern': isHam ? 'hammer' : 'dominance',
          'low': c.low,
          'close': c.close,
          ..._geo(c), // geometry of the missed candle (compare vs traded ones)
          'nearestType': near.type,
          'nearestTag': near.tag,
          'nearestDistPct': double.parse(near.distPct.toStringAsFixed(3)),
          'nearestFresh': near.fresh,
          'levelCountToday': levels.length,
          'fwdBars': end - k,
          'maxBouncePct': double.parse(bouncePct.toStringAsFixed(3)),
          'maxDrawdownPct': double.parse(ddPct.toStringAsFixed(3)),
        },
      );
      return; // one near-miss record per stock-day
    }
  }

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

/// Typed accessor for Hammer/Dominance params.
class HammerLabParams {
  final Map<String, dynamic> _m;
  HammerLabParams(this._m);

  double _d(String k, double def) => (_m[k] as num?)?.toDouble() ?? def;
  int _i(String k, int def) => (_m[k] as num?)?.toInt() ?? def;
  bool _b(String k, bool def) => _m[k] as bool? ?? def;

  // Geometry
  double get wickBodyRatio => _d('wickBodyRatio', 2.0);
  double get maxUpperWickPct => _d('maxUpperWickPct', 10.0);
  double get maxBodyPct => _d('maxBodyPct', 33.0);
  double get hammerMinWickPct => _d('hammerMinWickPct', 2.0);
  bool get allowHammer => _b('allowHammer', true);
  bool get allowDominanceCandle => _b('allowDominanceCandle', true);
  double get domMinBodyPct => _d('domMinBodyPct', 80.0);
  double get domMinWickPct => _d('domMinWickPct', 5.0);
  // Risk filters
  double get maxRangeMultVsPrevDay => _d('maxRangeMultVsPrevDay', 4.0);
  double get minStopDistancePct => _d('minStopDistancePct', 0.8);
  double get minTriggerRangePct => _d('minTriggerRangePct', 0.0);
  double get minOverheadPct => _d('minOverheadPct', 0.0);
  double get minPrice => _d('minPrice', 50.0);
  // Support
  int get supportLookbackDays => _i('supportLookbackDays', 60);
  double get supportZoneWidthPct => _d('supportZoneWidthPct', 0.5);
  int get supportMinTouches => _i('supportMinTouches', 2);
  int get supportSwingStrength => _i('supportSwingStrength', 2);
  double get supportMinReactionPct => _d('supportMinReactionPct', 1.5);
  int get reactionLookforward => _i('reactionLookforward', 10);
  double get supportTolerancePct => _d('supportTolerancePct', 0.2);
  bool get supportUseRoundNumbers => _b('supportUseRoundNumbers', true);
  bool get usePrevDayLevels => _b('usePrevDayLevels', true);
  bool get usePivotLevels => _b('usePivotLevels', true);
  bool get useCprLevels => _b('useCprLevels', true);
  bool get useCamarillaL3 => _b('useCamarillaL3', true);
  bool get excludePdh => _b('excludePdh', true);
  bool get excludeS1 => _b('excludeS1', true);
  double get minSupportDistPct => _d('minSupportDistPct', 0.06);
  bool get useTrendlines => _b('useTrendlines', true);
  double get gapRejectLowPct => _d('gapRejectLowPct', 0.3);
  double get gapRejectHighPct => _d('gapRejectHighPct', 1.0);
  // Window
  int get windowStartHour => _i('windowStartHour', 9);
  int get windowStartMin => _i('windowStartMin', 30);
  int get windowEndHour => _i('windowEndHour', 12);
  int get windowEndMin => _i('windowEndMin', 0);
  int get hardExitHour => _i('hardExitHour', 15);
  int get hardExitMin => _i('hardExitMin', 0);
  // Execution
  bool get requireConfirmation => _b('requireConfirmation', true);
  double get stopBufferPct => _d('stopBufferPct', 0.0);
  double get stopBufferRangePct => _d('stopBufferRangePct', 0.0);
  double get targetR => _d('targetR', 0.0);
  bool get useTrailingStop => _b('useTrailingStop', false);
  double get trailActivateR => _d('trailActivateR', 1.0);
  double get trailGapR => _d('trailGapR', 1.0);
  // Sizing
  double get riskPerTrade => _d('riskPerTrade', 500.0);
  int get maxTradesPerDay => _i('maxTradesPerDay', 20);
  double get maxCapitalPerTrade => _d('maxCapitalPerTrade', 300000.0);
  // 0 = off (fallback keeps old behaviour for saved configs missing the key;
  // re-added configs pick up 250000 from defaultParams).
  double get maxAvgDailyVol => _d('maxAvgDailyVol', 0.0);
  double get costModelRoundTripPct => _d('costModelRoundTripPct', 0.10);
  // Support-research logging (LAB)
  bool get logSupportMiss => _b('logSupportMiss', true);
  int get supportMissForwardBars => _i('supportMissForwardBars', 6);
}
