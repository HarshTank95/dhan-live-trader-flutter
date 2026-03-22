import 'package:uuid/uuid.dart';
import 'strategy_trade_model.dart';

/// Per-day results within a backtest run.
class BacktestDayResult {
  final String date; // yyyy-MM-dd
  final int stocksScanned;
  final int stocksAfterElimination;
  final int dominanceSignals;
  final int tradesEntered;
  final int wins;
  final int losses;
  final double dayPnl;
  final List<StrategyTradeModel> trades;

  const BacktestDayResult({
    required this.date,
    required this.stocksScanned,
    required this.stocksAfterElimination,
    required this.dominanceSignals,
    required this.tradesEntered,
    required this.wins,
    required this.losses,
    required this.dayPnl,
    required this.trades,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'stocksScanned': stocksScanned,
        'stocksAfterElimination': stocksAfterElimination,
        'dominanceSignals': dominanceSignals,
        'tradesEntered': tradesEntered,
        'wins': wins,
        'losses': losses,
        'dayPnl': dayPnl,
        'trades': trades.map((t) => t.toJson()).toList(),
      };

  factory BacktestDayResult.fromJson(Map<String, dynamic> json) =>
      BacktestDayResult(
        date: json['date'] as String,
        stocksScanned: (json['stocksScanned'] as num?)?.toInt() ?? 0,
        stocksAfterElimination:
            (json['stocksAfterElimination'] as num?)?.toInt() ?? 0,
        dominanceSignals: (json['dominanceSignals'] as num?)?.toInt() ?? 0,
        tradesEntered: (json['tradesEntered'] as num?)?.toInt() ?? 0,
        wins: (json['wins'] as num?)?.toInt() ?? 0,
        losses: (json['losses'] as num?)?.toInt() ?? 0,
        dayPnl: (json['dayPnl'] as num?)?.toDouble() ?? 0,
        trades: (json['trades'] as List<dynamic>?)
                ?.map((e) =>
                    StrategyTradeModel.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// Full backtest result — summary + per-day breakdown.
class BacktestResultModel {
  final String id;
  final String strategyType;
  final String strategyName;
  final Map<String, dynamic> params;
  final DateTime fromDate;
  final DateTime toDate;
  final int stockUniverseSize;
  final String stockUniverseLabel; // "Nifty 50", "Nifty 200", "Nifty 500"
  final DateTime runAt;
  final int durationSeconds;

  // Summary metrics
  final int totalTradingDays;
  final int daysWithSignals;
  final int daysWithTrades;
  final int totalSignals;
  final int totalTrades;
  final int wins;
  final int losses;
  final double totalPnl;
  final double maxDrawdown;
  final double peakPnl;

  // Per-day breakdown
  final List<BacktestDayResult> dayResults;

  BacktestResultModel({
    String? id,
    required this.strategyType,
    required this.strategyName,
    required this.params,
    required this.fromDate,
    required this.toDate,
    required this.stockUniverseSize,
    required this.stockUniverseLabel,
    DateTime? runAt,
    required this.durationSeconds,
    required this.totalTradingDays,
    required this.daysWithSignals,
    required this.daysWithTrades,
    required this.totalSignals,
    required this.totalTrades,
    required this.wins,
    required this.losses,
    required this.totalPnl,
    required this.maxDrawdown,
    required this.peakPnl,
    required this.dayResults,
  })  : id = id ?? const Uuid().v4(),
        runAt = runAt ?? DateTime.now();

  double get winRate => totalTrades > 0 ? (wins / totalTrades) * 100 : 0;

  double get avgPnlPerTrade => totalTrades > 0 ? totalPnl / totalTrades : 0;

  double get avgPnlPerDay =>
      totalTradingDays > 0 ? totalPnl / totalTradingDays : 0;

  double get profitFactor {
    double grossProfit = 0;
    double grossLoss = 0;
    for (final day in dayResults) {
      for (final trade in day.trades) {
        if (trade.pnl > 0) {
          grossProfit += trade.pnl;
        } else if (trade.pnl < 0) {
          grossLoss += trade.pnl.abs();
        }
      }
    }
    return grossLoss > 0 ? grossProfit / grossLoss : grossProfit > 0 ? double.infinity : 0;
  }

  /// Cumulative P&L series for equity curve chart.
  List<double> get equityCurve {
    final curve = <double>[];
    double cumulative = 0;
    for (final day in dayResults) {
      cumulative += day.dayPnl;
      curve.add(cumulative);
    }
    return curve;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'strategyType': strategyType,
        'strategyName': strategyName,
        'params': params,
        'fromDate': fromDate.toIso8601String(),
        'toDate': toDate.toIso8601String(),
        'stockUniverseSize': stockUniverseSize,
        'stockUniverseLabel': stockUniverseLabel,
        'runAt': runAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'totalTradingDays': totalTradingDays,
        'daysWithSignals': daysWithSignals,
        'daysWithTrades': daysWithTrades,
        'totalSignals': totalSignals,
        'totalTrades': totalTrades,
        'wins': wins,
        'losses': losses,
        'totalPnl': totalPnl,
        'maxDrawdown': maxDrawdown,
        'peakPnl': peakPnl,
        'dayResults': dayResults.map((d) => d.toJson()).toList(),
      };

  factory BacktestResultModel.fromJson(Map<String, dynamic> json) =>
      BacktestResultModel(
        id: json['id'] as String,
        strategyType: json['strategyType'] as String? ?? '',
        strategyName: json['strategyName'] as String? ?? '',
        params: Map<String, dynamic>.from(json['params'] as Map? ?? {}),
        fromDate: DateTime.parse(json['fromDate'] as String),
        toDate: DateTime.parse(json['toDate'] as String),
        stockUniverseSize: (json['stockUniverseSize'] as num?)?.toInt() ?? 0,
        stockUniverseLabel: json['stockUniverseLabel'] as String? ?? '',
        runAt: DateTime.parse(json['runAt'] as String),
        durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
        totalTradingDays: (json['totalTradingDays'] as num?)?.toInt() ?? 0,
        daysWithSignals: (json['daysWithSignals'] as num?)?.toInt() ?? 0,
        daysWithTrades: (json['daysWithTrades'] as num?)?.toInt() ?? 0,
        totalSignals: (json['totalSignals'] as num?)?.toInt() ?? 0,
        totalTrades: (json['totalTrades'] as num?)?.toInt() ?? 0,
        wins: (json['wins'] as num?)?.toInt() ?? 0,
        losses: (json['losses'] as num?)?.toInt() ?? 0,
        totalPnl: (json['totalPnl'] as num?)?.toDouble() ?? 0,
        maxDrawdown: (json['maxDrawdown'] as num?)?.toDouble() ?? 0,
        peakPnl: (json['peakPnl'] as num?)?.toDouble() ?? 0,
        dayResults: (json['dayResults'] as List<dynamic>?)
                ?.map((e) =>
                    BacktestDayResult.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}
