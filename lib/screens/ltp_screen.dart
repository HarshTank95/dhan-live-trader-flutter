import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../models/watchlist_model.dart';
import '../services/dhan_feed_service.dart';
import '../services/dhan_service.dart'
    show DhanService, DhanAuthException, DhanRateLimitException, DhanNetworkException, StockQuote;
import '../services/scrip_service.dart';
import '../services/paper_trading_service.dart';
import '../services/storage_service.dart';
import 'chart_screen.dart';
import 'holdings_screen.dart';
import 'log_viewer_screen.dart';
import 'paper_order_screen.dart';
import 'paper_positions_screen.dart';
import 'strategy_list_screen.dart';
import 'token_entry_screen.dart';
import 'watchlist_manager_screen.dart';

enum SortMode { changeDesc, changeAsc, nameAsc }

class LtpScreen extends StatefulWidget {
  final String clientId;
  final String accessToken;

  const LtpScreen({
    super.key,
    required this.clientId,
    required this.accessToken,
  });

  @override
  State<LtpScreen> createState() => _LtpScreenState();
}

class _LtpScreenState extends State<LtpScreen> {
  late DhanService _service;
  final ScripService _scripService = ScripService();

  List<StockQuote> _quotes = [];
  List<WatchlistModel> _watchlists = [];
  String _activeWatchlistId = '';
  bool _isLoading = true;
  bool _isLoadingScrips = true;
  String? _error;
  bool _isAuthError = false;
  bool _isNetworkError = false;
  bool _isRateLimitError = false;
  SortMode _sortMode = SortMode.changeDesc;

  // WebSocket live feed
  DhanFeedService? _feedService;
  StreamSubscription<Map<int, FeedUpdate>>? _feedSub;
  StreamSubscription<FeedStatus>? _statusSub;
  FeedStatus _feedStatus = FeedStatus.disconnected;

  // Funds / balance
  Map<String, double>? _funds;
  bool _fundsLoading = false;

  // Paper trading
  final PaperTradingService _paperService = PaperTradingService();
  String _tradingMode = 'paper'; // 'paper' or 'live'

  WatchlistModel? get _activeWatchlist {
    try {
      return _watchlists.firstWhere((w) => w.id == _activeWatchlistId);
    } catch (_) {
      return _watchlists.isNotEmpty ? _watchlists.first : null;
    }
  }

  @override
  void initState() {
    super.initState();
    _service = DhanService(
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    );
    _init();
  }

  Future<void> _init() async {
    // Step 1: Load all watchlists + active ID
    _watchlists = await StorageService.loadAllWatchlists();
    final savedActiveId = await StorageService.loadActiveWatchlistId();
    _activeWatchlistId = savedActiveId ?? _watchlists.first.id;

    // Step 2: Download/cache scrip master (NSE_EQ only via auth endpoint)
    await _scripService.loadScrips(
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    );
    // Load Nifty index constituents from NSE (cached daily)
    await _scripService.loadIndexConstituents();
    // Init paper trading
    await _paperService.init();
    _tradingMode = await StorageService.loadTradingMode();
    setState(() => _isLoadingScrips = false);

    // Step 3: Apply active watchlist
    _applyActiveWatchlist();

    // Step 4: Load prev closes + initial REST fetch
    await _service.loadPrevCloses();
    await _fetchLTP();

    // Step 5: Switch to live WebSocket feed (if no auth error)
    if (!_isAuthError) _connectFeed();
  }

  List<int> _getActiveSecurityIds() {
    return _activeWatchlist?.stockIds
            .map((id) => _scripService.findById(id))
            .whereType<ScripInfo>()
            .map((s) => s.securityId)
            .toList() ??
        [];
  }

  void _connectFeed() {
    _feedService?.dispose();
    _feedService = DhanFeedService(
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    );

    _statusSub?.cancel();
    _statusSub = _feedService!.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _feedStatus = status);
    });

    _feedSub?.cancel();
    _feedSub = _feedService!.dataStream.listen((data) {
      if (!mounted) return;
      _updateFromFeed(data);
    });

    _feedService!.connect(_getActiveSecurityIds());
  }

  void _updateFromFeed(Map<int, FeedUpdate> data) {
    final wl = _activeWatchlist;
    if (wl == null) return;

    final scrips = wl.stockIds
        .map((id) => _scripService.findById(id))
        .whereType<ScripInfo>()
        .toList();
    if (scrips.isEmpty) return;

    final newQuotes = scrips.map((scrip) {
      final u = data[scrip.securityId];
      return StockQuote(
        symbol: scrip.symbol,
        name: scrip.name,
        securityId: scrip.securityId,
        ltp: u?.ltp ?? 0,
        open: u?.open ?? 0,
        high: u?.high ?? 0,
        low: u?.low ?? 0,
        prevClose: u?.prevClose ?? 0,
      );
    }).toList();

    setState(() {
      _quotes = _sorted(newQuotes);
      _isLoading = false;
      _error = null;
      _isAuthError = false;
      _isNetworkError = false;
      _isRateLimitError = false;
    });
  }

  void _applyActiveWatchlist() {
    final wl = _activeWatchlist;
    if (wl == null) return;
    final scrips = wl.stockIds
        .map((id) => _scripService.findById(id))
        .whereType<ScripInfo>()
        .toList();
    _service.setWatchlist(scrips);
  }

  Future<void> _switchWatchlist(String id) async {
    if (_activeWatchlistId == id) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _activeWatchlistId = id;
      _isLoading = true;
      _quotes = [];
    });
    Navigator.pop(context); // close drawer
    await StorageService.saveActiveWatchlistId(id);
    _applyActiveWatchlist();
    // Load prevCloses for new watchlist in background (needed by pull-to-refresh)
    unawaited(_service.loadPrevCloses());
    // Resubscribe WebSocket with new instrument list
    _feedService?.resubscribe(_getActiveSecurityIds());
  }

  Future<void> _fetchLTP() async {
    try {
      final quotes = await _service.fetchLTP();
      setState(() {
        _quotes = _sorted(quotes);
        _isLoading = false;
        _error = null;
        _isAuthError = false;
        _isNetworkError = false;
        _isRateLimitError = false;
        });
    } on DhanAuthException catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.message;
        _isAuthError = true;
        _isNetworkError = false;
        _isRateLimitError = false;
      });
    } on DhanNetworkException catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.message;
        _isAuthError = false;
        _isNetworkError = true;
        _isRateLimitError = false;
      });
    } on DhanRateLimitException {
      setState(() {
        _isLoading = false;
        _error = 'Too many requests. The app will retry automatically.';
        _isAuthError = false;
        _isNetworkError = false;
        _isRateLimitError = true;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
        _isAuthError = false;
        _isNetworkError = false;
        _isRateLimitError = false;
      });
    }
  }

  List<StockQuote> _sorted(List<StockQuote> quotes) {
    final list = List<StockQuote>.from(quotes);
    switch (_sortMode) {
      case SortMode.changeDesc:
        list.sort((a, b) => b.changePercent.compareTo(a.changePercent));
      case SortMode.changeAsc:
        list.sort((a, b) => a.changePercent.compareTo(b.changePercent));
      case SortMode.nameAsc:
        list.sort((a, b) => a.symbol.compareTo(b.symbol));
    }
    return list;
  }

  void _setSort(SortMode mode) {
    setState(() {
      _sortMode = mode;
      _quotes = _sorted(_quotes);
    });
  }

  Future<void> _openWatchlistManager() async {
    Navigator.pop(context); // close drawer

    final result = await Navigator.push<({List<WatchlistModel> watchlists, String activeId})>(
      context,
      MaterialPageRoute(
        builder: (_) => WatchlistManagerScreen(
          watchlists: _watchlists,
          activeId: _activeWatchlistId,
          scripService: _scripService,
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _watchlists = result.watchlists;
        _activeWatchlistId = result.activeId;
        _isLoading = true;
        _quotes = [];
      });
      _applyActiveWatchlist();
      unawaited(_service.loadPrevCloses());
      _feedService?.resubscribe(_getActiveSecurityIds());
    }
  }

  Future<void> _addStockToWatchlist(ScripInfo scrip) async {
    final wl = _activeWatchlist;
    if (wl == null) return;

    if (wl.stockIds.contains(scrip.securityId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${scrip.symbol} is already in ${wl.name}')),
      );
      return;
    }
    if (wl.stockIds.length >= 20) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Watchlist is full (max 20 stocks)')),
      );
      return;
    }

    final updated = wl.copyWith(stockIds: [...wl.stockIds, scrip.securityId]);
    final idx = _watchlists.indexWhere((w) => w.id == wl.id);
    setState(() {
      _watchlists[idx] = updated;
      _isLoading = true;
      _quotes = [];
    });
    await StorageService.saveAllWatchlists(_watchlists);
    _applyActiveWatchlist();
    unawaited(_service.loadPrevCloses());
    _feedService?.resubscribe(_getActiveSecurityIds());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${scrip.symbol} added to ${wl.name}')),
      );
    }
  }

  void _openEditCredentials() {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TokenEntryScreen(
          initialClientId: widget.clientId,
          initialAccessToken: widget.accessToken,
        ),
      ),
    );
  }

  Future<void> _logout() async {
    Navigator.pop(context);
    await StorageService.clearCredentials();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const TokenEntryScreen()),
      (_) => false,
    );
  }

  Future<void> _fetchFunds() async {
    if (_fundsLoading) return;
    setState(() => _fundsLoading = true);
    try {
      final funds = await _service.fetchFunds();
      if (mounted) setState(() { _funds = funds; _fundsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _fundsLoading = false);
    }
  }

  void _openStrategies() {
    Navigator.pop(context); // close drawer
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StrategyListScreen(
          clientId: widget.clientId,
          accessToken: widget.accessToken,
        ),
      ),
    );
  }

  void _openHoldings() {
    Navigator.pop(context); // close drawer
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HoldingsScreen(dhanService: _service),
      ),
    );
  }

  void _openPaperPositions() {
    Navigator.pop(context); // close drawer
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaperPositionsScreen(
          clientId: widget.clientId,
          accessToken: widget.accessToken,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {}); // refresh after returning
    });
  }

  void _showStockDetail(StockQuote q) {
    final color = q.isPositive ? Colors.green : Colors.red;
    final arrow = q.isPositive ? '▲' : '▼';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.blue.shade100,
                  child: Text(q.symbol[0],
                      style: const TextStyle(
                          color: Colors.blue, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(q.symbol,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(q.name,
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const Text('NSE',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₹${q.ltp.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '$arrow ${q.change.abs().toStringAsFixed(2)} (${q.changePercent.toStringAsFixed(2)}%)',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 2,
              childAspectRatio: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _detailTile('Open', '₹${q.open.toStringAsFixed(2)}'),
                _detailTile('High', '₹${q.high.toStringAsFixed(2)}',
                    color: Colors.green),
                _detailTile('Low', '₹${q.low.toStringAsFixed(2)}',
                    color: Colors.red),
                _detailTile('Prev Close', '₹${q.prevClose.toStringAsFixed(2)}'),
              ],
            ),
            const SizedBox(height: 16),
            // Buy / Sell buttons (Paper mode only for now)
            if (_tradingMode == 'paper') ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _openOrderScreen(q, isBuy: true);
                      },
                      child: const Text('BUY',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _openOrderScreen(q, isBuy: false);
                      },
                      child: const Text('SELL',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ] else if (_tradingMode == 'live') ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey.shade400,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Live trading coming soon!')),
                        );
                      },
                      child: const Text('BUY / SELL  —  Coming Soon',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.pop(context); // close bottom sheet
                  _openChart(q);
                },
                icon: const Icon(Icons.candlestick_chart_outlined),
                label: const Text('View Chart',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openOrderScreen(StockQuote q, {required bool isBuy}) {
    showPaperOrderSheet(
      context: context,
      isBuy: isBuy,
      securityId: q.securityId,
      symbol: q.symbol,
      name: q.name,
      ltp: q.ltp,
      prevClose: q.prevClose,
      clientId: widget.clientId,
      accessToken: widget.accessToken,
    ).then((placed) {
      if (placed == true && mounted) setState(() {});
    });
  }

  void _openChart(StockQuote q) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChartScreen(
          securityId: q.securityId,
          symbol: q.symbol,
          name: q.name,
          ltp: q.ltp,
          change: q.change,
          changePercent: q.changePercent,
          open: q.open,
          high: q.high,
          low: q.low,
          prevClose: q.prevClose,
          isPositive: q.isPositive,
          dhanService: _service,
        ),
      ),
    );
  }

  Widget _detailTile(String label, String value, {Color? color}) {
    return Builder(builder: (context) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: (color ?? Colors.blue).withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: color ?? Theme.of(context).colorScheme.onSurface)),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _feedSub?.cancel();
    _feedService?.dispose();
    super.dispose();
  }

  bool get _isMarketOpen {
    final now =
        DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    if (now.weekday == DateTime.saturday ||
        now.weekday == DateTime.sunday) { return false; }
    final open = DateTime(now.year, now.month, now.day, 9, 15);
    final close = DateTime(now.year, now.month, now.day, 15, 30);
    return now.isAfter(open) && now.isBefore(close);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = MyApp.of(context).isDark;
    final activeWl = _activeWatchlist;

    return Scaffold(
      appBar: AppBar(
        title: Text(activeWl?.name ?? 'Live Prices'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Paper/Live toggle
          GestureDetector(
            onTap: () async {
              if (_tradingMode == 'paper') {
                // Switching to Live — show warning
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    icon: const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 40),
                    title: const Text('Switch to Live Mode?'),
                    content: const Text(
                      'In Live mode, orders will be placed using your real Dhan account with actual money.\n\n'
                      'Make sure you understand the risks before proceeding.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Stay on Paper'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Switch to Live'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
              }
              setState(() {
                _tradingMode = _tradingMode == 'paper' ? 'live' : 'paper';
              });
              StorageService.saveTradingMode(_tradingMode);
            },
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _tradingMode == 'paper'
                    ? Colors.teal.withOpacity(0.15)
                    : Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _tradingMode == 'paper' ? Colors.teal : Colors.orange,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _tradingMode == 'paper'
                        ? Icons.description_outlined
                        : Icons.bolt,
                    size: 14,
                    color: _tradingMode == 'paper' ? Colors.teal : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _tradingMode == 'paper' ? 'PAPER' : 'LIVE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _tradingMode == 'paper' ? Colors.teal : Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Market badge
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isMarketOpen
                  ? Colors.green.withOpacity(0.15)
                  : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: _isMarketOpen ? Colors.green : Colors.red, width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    color: _isMarketOpen ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isMarketOpen ? 'Open' : 'Closed',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _isMarketOpen ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
          ),

          // Sort
          PopupMenuButton<SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            onSelected: _setSort,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: SortMode.changeDesc,
                child: Row(children: [
                  Icon(Icons.trending_up,
                      color: _sortMode == SortMode.changeDesc
                          ? Colors.blue : null, size: 18),
                  const SizedBox(width: 8),
                  const Text('Best performers first'),
                ]),
              ),
              PopupMenuItem(
                value: SortMode.changeAsc,
                child: Row(children: [
                  Icon(Icons.trending_down,
                      color: _sortMode == SortMode.changeAsc
                          ? Colors.blue : null, size: 18),
                  const SizedBox(width: 8),
                  const Text('Worst performers first'),
                ]),
              ),
              PopupMenuItem(
                value: SortMode.nameAsc,
                child: Row(children: [
                  Icon(Icons.sort_by_alpha,
                      color: _sortMode == SortMode.nameAsc
                          ? Colors.blue : null, size: 18),
                  const SizedBox(width: 8),
                  const Text('Name A → Z'),
                ]),
              ),
            ],
          ),

        ],
      ),
      onDrawerChanged: (opened) { if (opened) _fetchFunds(); },
      drawer: _buildDrawer(isDark),
      body: Column(
        children: [
          // ── Search bar ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Material(
              elevation: 2,
              shadowColor: Colors.blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: () async {
                  if (!_scripService.isLoaded) return;
                  final scrip = await showSearch<ScripInfo?>(
                    context: context,
                    delegate: _StockSearchDelegate(_scripService),
                  );
                  if (scrip != null && mounted) _addStockToWatchlist(scrip);
                },
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.search, size: 16, color: Colors.blue),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Search & add stocks...',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.grey.shade400 : Colors.grey.shade500,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '+ Add',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ── Stock list ────────────────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              onRefresh: _fetchLTP,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(bool isDark) {
    return Drawer(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 56, 20, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Colors.white.withOpacity(0.4), width: 1.5),
                  ),
                  child: const Icon(Icons.candlestick_chart_rounded,
                      color: Colors.white, size: 30),
                ),
                const SizedBox(height: 16),
                const Text('Dhan LTP Viewer',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: const BoxDecoration(
                          color: Color(0xFF69F0AE), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Client: ${widget.clientId}',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // ── Funds card ───────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: _fundsLoading
                      ? Container(
                          height: 62,
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.grey.shade800
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : _funds != null
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.grey.shade800
                                    : Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isDark
                                      ? Colors.grey.shade700
                                      : Colors.blue.shade100,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('Available',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey.shade500)),
                                        Text(
                                          '₹${_fmtFunds(_funds!['available']!)}',
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.green),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    width: 1, height: 32,
                                    color: Colors.grey.withValues(alpha: 0.25),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding:
                                          const EdgeInsets.only(left: 12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('Used',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey.shade500)),
                                          Text(
                                            '₹${_fmtFunds(_funds!['used']!)}',
                                            style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                ),

                const SizedBox(height: 12),

                // Watchlists section
                _sectionLabel('WATCHLISTS'),
                ..._watchlists.map((wl) {
                  final isActive = wl.id == _activeWatchlistId;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 2),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      tileColor: isActive
                          ? Colors.blue.withOpacity(0.08)
                          : null,
                      leading: Icon(
                        isActive
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isActive ? Colors.blue : Colors.grey,
                      ),
                      title: Text(wl.name,
                          style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isActive ? Colors.blue : null,
                              fontSize: 14)),
                      subtitle: Text('${wl.stockIds.length} stocks',
                          style: const TextStyle(fontSize: 11)),
                      onTap: () => _switchWatchlist(wl.id),
                    ),
                  );
                }),

                _drawerTile(
                  icon: Icons.settings_outlined,
                  label: 'Manage Watchlists',
                  iconColor: const Color(0xFF2E7D32),
                  onTap: _openWatchlistManager,
                ),

                const SizedBox(height: 8),

                // Strategies section
                _sectionLabel('STRATEGIES'),
                _drawerTile(
                  icon: Icons.auto_graph,
                  label: 'Strategies',
                  iconColor: Colors.deepPurple,
                  onTap: _openStrategies,
                ),

                const SizedBox(height: 8),

                // Developer section
                _sectionLabel('DEVELOPER'),
                _drawerTile(
                  icon: Icons.article_outlined,
                  label: 'View Logs',
                  iconColor: Colors.blueGrey,
                  onTap: () {
                    Navigator.pop(context); // close drawer
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LogViewerScreen(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 8),

                // Account section
                _sectionLabel('ACCOUNT'),
                _drawerTile(
                  icon: Icons.pie_chart_outline_rounded,
                  label: 'Holdings / Portfolio',
                  iconColor: const Color(0xFF6750A4),
                  onTap: _openHoldings,
                ),
                _drawerTile(
                  icon: Icons.receipt_long_outlined,
                  label: 'Paper Trading',
                  iconColor: Colors.teal,
                  onTap: _openPaperPositions,
                ),
                _drawerTile(
                  icon: Icons.manage_accounts_outlined,
                  label: 'Edit Credentials',
                  iconColor: const Color(0xFF1565C0),
                  onTap: _openEditCredentials,
                ),
                _drawerTile(
                  icon: Icons.logout_rounded,
                  label: 'Clear & Logout',
                  iconColor: Colors.redAccent,
                  labelColor: Colors.redAccent,
                  onTap: _logout,
                ),

                const SizedBox(height: 8),

                // Preferences
                _sectionLabel('PREFERENCES'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 2),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    leading: Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color: Colors.purple.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                          isDark ? Icons.dark_mode : Icons.light_mode,
                          color: Colors.purple, size: 20),
                    ),
                    title: Text(isDark ? 'Dark Mode' : 'Light Mode',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    trailing: Switch(
                      value: isDark,
                      onChanged: (_) => MyApp.of(context).toggleTheme(),
                      activeColor: Colors.blue,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline,
                    size: 13, color: Colors.grey.shade400),
                const SizedBox(width: 5),
                Text('Dhan LTP Viewer  v1.0',
                    style: TextStyle(
                        color: Colors.grey.shade400, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtFunds(double val) {
    if (val >= 1e7) return '${(val / 1e7).toStringAsFixed(2)}Cr';
    if (val >= 1e5) return '${(val / 1e5).toStringAsFixed(2)}L';
    if (val >= 1e3) return '${(val / 1e3).toStringAsFixed(1)}K';
    return val.toStringAsFixed(2);
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade500,
                letterSpacing: 1.2)),
      );

  Widget _drawerTile({
    required IconData icon,
    required String label,
    required Color iconColor,
    Color? labelColor,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: labelColor ??
                    Theme.of(context).colorScheme.onSurface)),
        trailing: Icon(Icons.chevron_right,
            size: 18, color: Colors.grey.shade400),
        onTap: onTap,
      ),
    );
  }

  int get _gainers => _quotes.where((q) => q.changePercent > 0).length;
  int get _losers  => _quotes.where((q) => q.changePercent < 0).length;
  int get _flat    => _quotes.where((q) => q.changePercent == 0).length;

  Widget _buildBody() {
    if (_isLoadingScrips) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading stock data...'),
            SizedBox(height: 8),
            Text('Downloading scrip master from Dhan',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Fetching live prices...'),
          ],
        ),
      );
    }

    if (_error != null) {
      final icon = _isAuthError
          ? Icons.lock_outline
          : _isNetworkError
              ? Icons.wifi_off_rounded
              : _isRateLimitError
                  ? Icons.hourglass_empty_rounded
                  : Icons.error_outline;
      final iconColor = _isRateLimitError ? Colors.orange : Colors.red;
      final title = _isAuthError
          ? 'Token Expired'
          : _isNetworkError
              ? 'No Connection'
              : _isRateLimitError
                  ? 'Rate Limited'
                  : 'Something Went Wrong';

      return ListView(children: [
        SizedBox(
          height: 420,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 40, color: iconColor),
                  ),
                  const SizedBox(height: 20),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 28),
                  if (_isAuthError)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                      onPressed: _openEditCredentials,
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: const Text('Update Token'),
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                      onPressed: () {
                        setState(() {
                          _isLoading = true;
                          _error = null;
                        });
                        _fetchLTP();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ]);
    }

    if (_quotes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.playlist_add, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text('This watchlist is empty',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Open the drawer → Manage Watchlists to add stocks',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Symbol',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
              Text('LTP / Change',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _quotes.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final q = _quotes[index];
              final color = q.isPositive ? Colors.green : Colors.red;
              final arrow = q.isPositive ? '▲' : '▼';

              return ListTile(
                onTap: () => _showStockDetail(q),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                leading: CircleAvatar(
                  backgroundColor: Colors.blue.shade100,
                  child: Text(q.symbol[0],
                      style: const TextStyle(
                          color: Colors.blue,
                          fontWeight: FontWeight.bold)),
                ),
                title: Text(q.symbol,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                subtitle: Text(q.name,
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${q.ltp.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      '$arrow ${q.change.abs().toStringAsFixed(2)}  (${q.changePercent.toStringAsFixed(2)}%)',
                      style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              // ● LIVE status
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  color: switch (_feedStatus) {
                    FeedStatus.connected => Colors.green,
                    FeedStatus.connecting => Colors.orange,
                    FeedStatus.disconnected => Colors.red,
                  },
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                switch (_feedStatus) {
                  FeedStatus.connected => _isMarketOpen ? 'LIVE' : 'Connected',
                  FeedStatus.connecting => 'Connecting...',
                  FeedStatus.disconnected => 'Reconnecting...',
                },
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: switch (_feedStatus) {
                    FeedStatus.connected => Colors.green,
                    FeedStatus.connecting => Colors.orange,
                    FeedStatus.disconnected => Colors.red,
                  },
                ),
              ),
              // Gainers / Losers summary
              if (_quotes.isNotEmpty) ...[
                const Spacer(),
                Text('▲ $_gainers',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green)),
                const SizedBox(width: 10),
                Text('▼ $_losers',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.red)),
                if (_flat > 0) ...[
                  const SizedBox(width: 10),
                  Text('— $_flat',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade500)),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Stock search delegate ─────────────────────────────────────────────────────

class _StockSearchDelegate extends SearchDelegate<ScripInfo?> {
  final ScripService scripService;
  final ValueNotifier<ScripSegment?> _segmentFilter = ValueNotifier(null);

  _StockSearchDelegate(this.scripService);

  @override
  String get searchFieldLabel => 'Search stocks & F&O...';

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    return ValueListenableBuilder<ScripSegment?>(
      valueListenable: _segmentFilter,
      builder: (context, segment, _) {
        final results = scripService.searchWithFilter(query, segment: segment);
        return Column(
          children: [
            _buildFilterChips(segment),
            Expanded(child: _buildResultsList(context, results)),
          ],
        );
      },
    );
  }

  Widget _buildFilterChips(ScripSegment? active) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _chip('All', null, active),
          const SizedBox(width: 6),
          _chip('Equity', ScripSegment.equity, active),
          const SizedBox(width: 6),
          _chip('Futures', ScripSegment.futures, active),
          const SizedBox(width: 6),
          _chip('Options', ScripSegment.options, active),
        ],
      ),
    );
  }

  Widget _chip(String label, ScripSegment? value, ScripSegment? active) {
    final selected = active == value;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => _segmentFilter.value = value,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildResultsList(BuildContext context, List<ScripInfo> results) {
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              query.isEmpty ? 'Type to search stocks & F&O' : 'No results for "$query"',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final scrip = results[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: _segmentColor(scrip.segment).withValues(alpha: 0.15),
            child: Text(
              scrip.underlying[0],
              style: TextStyle(
                  color: _segmentColor(scrip.segment),
                  fontWeight: FontWeight.bold),
            ),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  scrip.segment == ScripSegment.equity
                      ? scrip.symbol
                      : scrip.displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              _segmentBadge(scrip),
            ],
          ),
          subtitle: Text(
            scrip.segment == ScripSegment.equity
                ? scrip.name
                : 'Lot: ${scrip.lotSize?.toInt() ?? '?'}',
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.add_circle_outline, color: Colors.blue),
          onTap: () => close(context, scrip),
        );
      },
    );
  }

  Color _segmentColor(ScripSegment segment) {
    switch (segment) {
      case ScripSegment.equity:
        return Colors.blue;
      case ScripSegment.futures:
        return Colors.orange;
      case ScripSegment.options:
        return Colors.purple;
    }
  }

  Widget _segmentBadge(ScripInfo scrip) {
    if (scrip.segment == ScripSegment.equity) return const SizedBox.shrink();

    final label = scrip.segment == ScripSegment.futures
        ? 'FUT'
        : scrip.optionType ?? 'OPT';
    final color = _segmentColor(scrip.segment);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
