import 'package:uuid/uuid.dart';
import '../models/paper_position_model.dart';
import '../models/paper_trade_model.dart';
import 'storage_service.dart';

class PaperTradingService {
  static final PaperTradingService _instance = PaperTradingService._internal();
  factory PaperTradingService() => _instance;
  PaperTradingService._internal();

  static const double defaultCapital = 1000000; // ₹10 Lakh
  static const int maxTradeHistory = 200;

  double _initialCapital = defaultCapital;
  double _availableBalance = defaultCapital;
  List<PaperPositionModel> _positions = [];
  List<PaperTradeModel> _trades = [];
  bool _initialized = false;

  // ── Getters ───────────────────────────────────────────────────────────

  double get initialCapital => _initialCapital;
  double get availableBalance => _availableBalance;
  double get usedMargin =>
      _positions.fold<double>(0, (s, p) => s + p.invested);
  List<PaperPositionModel> get positions => List.unmodifiable(_positions);
  List<PaperTradeModel> get tradeHistory => List.unmodifiable(_trades);
  bool get isInitialized => _initialized;

  double get unrealisedPnl =>
      _positions.fold<double>(0, (s, p) => s + p.pnl);
  double get realisedPnl =>
      _trades.fold<double>(0, (s, t) => s + t.pnl);

  Set<int> get positionSecurityIds =>
      _positions.map((p) => p.securityId).toSet();

  PaperPositionModel? positionFor(int securityId) {
    for (final p in _positions) {
      if (p.securityId == securityId) return p;
    }
    return null;
  }

  // ── Init ──────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _positions = await StorageService.loadPaperPositions();
    _trades = await StorageService.loadPaperTrades();
    final balance = await StorageService.loadPaperBalance();
    if (balance != null) {
      _availableBalance = balance.available;
      _initialCapital = balance.initial;
    }
    _initialized = true;
  }

  // ── Buy ───────────────────────────────────────────────────────────────

  /// Returns null on success, or error message on failure.
  Future<String?> buyStock({
    required int securityId,
    required String symbol,
    required String name,
    required int quantity,
    required double ltp,
  }) async {
    if (ltp <= 0) return 'Invalid price';
    if (quantity <= 0) return 'Invalid quantity';

    final cost = quantity * ltp;
    if (cost > _availableBalance) {
      return 'Insufficient balance (need ₹${cost.toStringAsFixed(0)}, '
          'available ₹${_availableBalance.toStringAsFixed(0)})';
    }

    // Check if position already exists → average up
    final existing = positionFor(securityId);
    if (existing != null) {
      final totalQty = existing.quantity + quantity;
      final totalCost = (existing.quantity * existing.entryPrice) + cost;
      existing.quantity = totalQty;
      existing.entryPrice = totalCost / totalQty;
      existing.ltp = ltp;
    } else {
      _positions.add(PaperPositionModel(
        id: const Uuid().v4(),
        securityId: securityId,
        symbol: symbol,
        name: name,
        quantity: quantity,
        entryPrice: ltp,
        entryTime: DateTime.now(),
        ltp: ltp,
      ));
    }

    _availableBalance -= cost;
    await _persist();
    return null;
  }

  // ── Short Sell ────────────────────────────────────────────────────────

  /// Short sell a stock. Returns null on success, or error message.
  Future<String?> sellShort({
    required int securityId,
    required String symbol,
    required String name,
    required int quantity,
    required double ltp,
  }) async {
    if (ltp <= 0) return 'Invalid price';
    if (quantity <= 0) return 'Invalid quantity';

    final margin = quantity * ltp;
    if (margin > _availableBalance) {
      return 'Insufficient margin (need ₹${margin.toStringAsFixed(0)}, '
          'available ₹${_availableBalance.toStringAsFixed(0)})';
    }

    // Check if short position already exists → average down
    final existing = positionFor(securityId);
    if (existing != null && existing.isShort) {
      final totalQty = existing.quantity + quantity;
      final totalCost = (existing.quantity * existing.entryPrice) + margin;
      existing.quantity = totalQty;
      existing.entryPrice = totalCost / totalQty;
      existing.ltp = ltp;
    } else if (existing != null && !existing.isShort) {
      return 'You have a long position. Close it first.';
    } else {
      _positions.add(PaperPositionModel(
        id: const Uuid().v4(),
        securityId: securityId,
        symbol: symbol,
        name: name,
        quantity: quantity,
        entryPrice: ltp,
        entryTime: DateTime.now(),
        ltp: ltp,
        isShort: true,
      ));
    }

    _availableBalance -= margin;
    await _persist();
    return null;
  }

  // ── Close Position ────────────────────────────────────────────────────

  /// Returns null on success, or error message on failure.
  Future<String?> closePosition(String positionId, double ltp) async {
    final idx = _positions.indexWhere((p) => p.id == positionId);
    if (idx < 0) return 'Position not found';
    if (ltp <= 0) return 'Invalid price';

    final position = _positions[idx];

    // Create trade history entry
    _trades.insert(
      0,
      PaperTradeModel(
        id: const Uuid().v4(),
        securityId: position.securityId,
        symbol: position.symbol,
        name: position.name,
        quantity: position.quantity,
        entryPrice: position.entryPrice,
        entryTime: position.entryTime,
        exitPrice: ltp,
        exitTime: DateTime.now(),
      ),
    );

    // Trim history
    if (_trades.length > maxTradeHistory) {
      _trades = _trades.sublist(0, maxTradeHistory);
    }

    // Credit balance
    if (position.isShort) {
      // Short: return margin + profit (or - loss)
      // Margin was: qty * entryPrice, P&L = (entry - exit) * qty
      _availableBalance += position.quantity * position.entryPrice +
          (position.entryPrice - ltp) * position.quantity;
    } else {
      _availableBalance += position.quantity * ltp;
    }

    // Remove position
    _positions.removeAt(idx);

    await _persist();
    return null;
  }

  // ── Partial Sell ───────────────────────────────────────────────────────

  /// Sell a specific quantity from a position. Returns null on success.
  Future<String?> sellPartial({
    required String positionId,
    required int quantity,
    required double ltp,
  }) async {
    final idx = _positions.indexWhere((p) => p.id == positionId);
    if (idx < 0) return 'Position not found';
    if (ltp <= 0) return 'Invalid price';
    final position = _positions[idx];
    if (quantity <= 0 || quantity > position.quantity) return 'Invalid quantity';

    // Full close if selling all
    if (quantity == position.quantity) {
      return closePosition(positionId, ltp);
    }

    // Create trade record for partial close
    _trades.insert(
      0,
      PaperTradeModel(
        id: const Uuid().v4(),
        securityId: position.securityId,
        symbol: position.symbol,
        name: position.name,
        quantity: quantity,
        entryPrice: position.entryPrice,
        entryTime: position.entryTime,
        exitPrice: ltp,
        exitTime: DateTime.now(),
      ),
    );

    if (_trades.length > maxTradeHistory) {
      _trades = _trades.sublist(0, maxTradeHistory);
    }

    // Credit partial close proceeds
    if (position.isShort) {
      _availableBalance += quantity * position.entryPrice +
          (position.entryPrice - ltp) * quantity;
    } else {
      _availableBalance += quantity * ltp;
    }

    // Reduce position quantity (avg price stays the same)
    position.quantity -= quantity;

    await _persist();
    return null;
  }

  // ── Today's Stats ─────────────────────────────────────────────────────

  List<PaperTradeModel> get todayTrades {
    final now = DateTime.now();
    return _trades
        .where((t) =>
            t.exitTime.year == now.year &&
            t.exitTime.month == now.month &&
            t.exitTime.day == now.day)
        .toList();
  }

  double get todayRealisedPnl =>
      todayTrades.fold<double>(0, (s, t) => s + t.pnl);

  int get todayTradeCount => todayTrades.length;

  int get todayWinCount => todayTrades.where((t) => t.isProfit).length;

  // ── Update Live Prices ────────────────────────────────────────────────

  void updateLtp(Map<int, double> ltpMap) {
    for (final p in _positions) {
      final ltp = ltpMap[p.securityId];
      if (ltp != null && ltp > 0) p.ltp = ltp;
    }
  }

  // ── Reset ─────────────────────────────────────────────────────────────

  Future<void> resetPortfolio({double? capital}) async {
    _initialCapital = capital ?? defaultCapital;
    _availableBalance = _initialCapital;
    _positions.clear();
    _trades.clear();
    await StorageService.clearPaperData();
    await StorageService.savePaperBalance(_availableBalance, _initialCapital);
  }

  // ── Persistence ───────────────────────────────────────────────────────

  Future<void> _persist() async {
    await StorageService.savePaperPositions(_positions);
    await StorageService.savePaperTrades(_trades);
    await StorageService.savePaperBalance(_availableBalance, _initialCapital);
  }
}
