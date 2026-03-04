import 'package:uuid/uuid.dart';

class WatchlistModel {
  final String id;
  String name;
  List<int> stockIds;

  WatchlistModel({
    String? id,
    required this.name,
    required this.stockIds,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'stockIds': stockIds,
      };

  factory WatchlistModel.fromJson(Map<String, dynamic> json) => WatchlistModel(
        id: json['id'] as String,
        name: json['name'] as String,
        stockIds:
            (json['stockIds'] as List<dynamic>).map((e) => e as int).toList(),
      );

  WatchlistModel copyWith({String? name, List<int>? stockIds}) => WatchlistModel(
        id: id,
        name: name ?? this.name,
        stockIds: stockIds ?? this.stockIds,
      );
}
