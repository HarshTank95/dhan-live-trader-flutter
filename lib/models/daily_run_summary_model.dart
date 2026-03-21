import 'dart:convert';

/// Summary of a single day's strategy engine run.
class DailyRunSummaryModel {
  final String date; // yyyy-MM-dd
  final String configId;
  final String configName;
  final String strategyType;
  final bool paperTrading;
  final int totalStocks;
  final int finalActiveStocks;
  final int dominanceCandidates;
  final int totalTrades;
  final int winners;
  final int losers;
  final double totalPnl;
  final String startTime; // HH:mm:ss
  final String endTime; // HH:mm:ss
  final String status; // completed, stopped, error
  final List<String> activityLog; // key events

  DailyRunSummaryModel({
    required this.date,
    required this.configId,
    required this.configName,
    required this.strategyType,
    required this.paperTrading,
    required this.totalStocks,
    required this.finalActiveStocks,
    required this.dominanceCandidates,
    required this.totalTrades,
    required this.winners,
    required this.losers,
    required this.totalPnl,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.activityLog,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'configId': configId,
        'configName': configName,
        'strategyType': strategyType,
        'paperTrading': paperTrading,
        'totalStocks': totalStocks,
        'finalActiveStocks': finalActiveStocks,
        'dominanceCandidates': dominanceCandidates,
        'totalTrades': totalTrades,
        'winners': winners,
        'losers': losers,
        'totalPnl': totalPnl,
        'startTime': startTime,
        'endTime': endTime,
        'status': status,
        'activityLog': activityLog,
      };

  factory DailyRunSummaryModel.fromJson(Map<String, dynamic> json) {
    return DailyRunSummaryModel(
      date: json['date'] as String? ?? '',
      configId: json['configId'] as String? ?? '',
      configName: json['configName'] as String? ?? '',
      strategyType: json['strategyType'] as String? ?? '',
      paperTrading: json['paperTrading'] as bool? ?? true,
      totalStocks: (json['totalStocks'] as num?)?.toInt() ?? 0,
      finalActiveStocks: (json['finalActiveStocks'] as num?)?.toInt() ?? 0,
      dominanceCandidates: (json['dominanceCandidates'] as num?)?.toInt() ?? 0,
      totalTrades: (json['totalTrades'] as num?)?.toInt() ?? 0,
      winners: (json['winners'] as num?)?.toInt() ?? 0,
      losers: (json['losers'] as num?)?.toInt() ?? 0,
      totalPnl: (json['totalPnl'] as num?)?.toDouble() ?? 0,
      startTime: json['startTime'] as String? ?? '',
      endTime: json['endTime'] as String? ?? '',
      status: json['status'] as String? ?? '',
      activityLog: (json['activityLog'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  String toJsonString() => jsonEncode(toJson());
}
