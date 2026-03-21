import 'package:uuid/uuid.dart';

class StrategyConfigModel {
  final String id;
  final String strategyType; // e.g. 'dominance_breakout'
  String name;
  bool paperTrading;
  bool enabled; // can pause without deleting
  Map<String, dynamic> params;
  List<int> securityIds; // stock universe to scan
  final DateTime createdAt;
  DateTime updatedAt;

  StrategyConfigModel({
    String? id,
    required this.strategyType,
    required this.name,
    this.paperTrading = true,
    this.enabled = true,
    required this.params,
    this.securityIds = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'strategyType': strategyType,
        'name': name,
        'paperTrading': paperTrading,
        'enabled': enabled,
        'params': params,
        'securityIds': securityIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory StrategyConfigModel.fromJson(Map<String, dynamic> json) =>
      StrategyConfigModel(
        id: json['id'] as String,
        strategyType: json['strategyType'] as String,
        name: json['name'] as String,
        paperTrading: json['paperTrading'] as bool? ?? true,
        enabled: json['enabled'] as bool? ?? true,
        params: Map<String, dynamic>.from(json['params'] as Map),
        securityIds:
            (json['securityIds'] as List<dynamic>).map((e) => e as int).toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  StrategyConfigModel copyWith({
    String? name,
    bool? paperTrading,
    bool? enabled,
    Map<String, dynamic>? params,
    List<int>? securityIds,
  }) =>
      StrategyConfigModel(
        id: id,
        strategyType: strategyType,
        name: name ?? this.name,
        paperTrading: paperTrading ?? this.paperTrading,
        enabled: enabled ?? this.enabled,
        params: params ?? Map<String, dynamic>.from(this.params),
        securityIds: securityIds ?? List<int>.from(this.securityIds),
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}
