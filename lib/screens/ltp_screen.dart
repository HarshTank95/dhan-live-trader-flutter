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
import '../theme/app_theme.dart';
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

  // Price tick flash — securityId → latest tick (row pulses green/red on LTP change)
  final Map<int, _FlashTick> _flashes = {};
  int _flashSeq = 0;

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

    // Detect per-stock LTP ticks so the row can flash green/red.
    final prevLtp = {for (final q in _quotes) q.securityId: q.ltp};
    for (final nq in newQuotes) {
      final old = prevLtp[nq.securityId];
      if (old != null && old > 0 && nq.ltp > 0 && nq.ltp != old) {
        _flashes[nq.securityId] = _FlashTick(++_flashSeq, nq.ltp > old);
      }
    }

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

  Future<void> _selectWatchlist(String id) async {
    if (_activeWatchlistId == id) return;
    setState(() {
      _activeWatchlistId = id;
      _isLoading = true;
      _quotes = [];
    });
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

  Future<void> _openWatchlistManager({bool fromDrawer = true}) async {
    if (fromDrawer) Navigator.pop(context); // close drawer

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
    final color = q.isPositive ? AppColors.up : AppColors.down;

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
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
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
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('NSE',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: Colors.grey.shade500)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₹${AppFmt.inr(q.ltp)}', style: AppText.priceXL),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    AppFmt.changeLine(q.change, q.changePercent),
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        fontFeatures: const [FontFeature.tabularFigures()]),
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
                _detailTile('Open', '₹${AppFmt.inr(q.open)}'),
                _detailTile('High', '₹${AppFmt.inr(q.high)}',
                    color: AppColors.up),
                _detailTile('Low', '₹${AppFmt.inr(q.low)}',
                    color: AppColors.down),
                _detailTile('Prev Close', '₹${AppFmt.inr(q.prevClose)}'),
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
                        backgroundColor: AppColors.up,
                        foregroundColor: const Color(0xFF0B0D10),
                        elevation: 0,
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
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.down,
                        foregroundColor: const Color(0xFF0B0D10),
                        elevation: 0,
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
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
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
                        backgroundColor: AppColors.surfaceRaised,
                        foregroundColor: AppColors.textMuted,
                        elevation: 0,
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
                  backgroundColor: AppColors.accentDim,
                  foregroundColor: AppColors.accent,
                  elevation: 0,
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
          color: color == null
              ? AppColors.surfaceRaised
              : color.withValues(alpha: 0.08),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchlist'),
        actions: [
          _MarketStatusPill(feedStatus: _feedStatus, marketOpen: _isMarketOpen),
          const SizedBox(width: 12),
          _buildPaperChip(),
          const SizedBox(width: 16),
        ],
      ),
      onDrawerChanged: (opened) { if (opened) _fetchFunds(); },
      drawer: _buildDrawer(isDark),
      body: Column(
        children: [
          _buildSearchRow(),
          _buildWatchlistTabs(),
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

  Future<void> _toggleTradingMode() async {
    if (_tradingMode == 'paper') {
      // Switching to Live — show warning
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded,
              color: AppColors.warn, size: 40),
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
              style: FilledButton.styleFrom(backgroundColor: AppColors.warn),
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
  }

  Widget _buildPaperChip() {
    final isPaper = _tradingMode == 'paper';
    return InkWell(
      onTap: _toggleTradingMode,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isPaper
                ? const Color(0x24FFFFFF)
                : AppColors.warn.withValues(alpha: 0.5),
          ),
          color: isPaper
              ? Colors.transparent
              : AppColors.warn.withValues(alpha: 0.08),
        ),
        child: Text(
          isPaper ? 'PAPER' : 'LIVE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: isPaper ? AppColors.textMuted : AppColors.warn,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchRow() {
    final count = _activeWatchlist?.stockIds.length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () async {
            if (!_scripService.isLoaded) return;
            final scrip = await showSearch<ScripInfo?>(
              context: context,
              delegate: _StockSearchDelegate(_scripService),
            );
            if (scrip != null && mounted) _addStockToWatchlist(scrip);
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
            child: Row(
              children: [
                const Icon(Icons.search, size: 18, color: AppColors.textMuted),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Search & add',
                      style: TextStyle(
                          fontSize: 13.5, color: AppColors.textMuted)),
                ),
                Text('$count/20', style: AppText.counter),
                PopupMenuButton<SortMode>(
                  icon: const Icon(Icons.swap_vert,
                      size: 18, color: AppColors.textMuted),
                  tooltip: 'Sort',
                  onSelected: _setSort,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: SortMode.changeDesc,
                      child: Row(children: [
                        Icon(Icons.trending_up,
                            color: _sortMode == SortMode.changeDesc
                                ? AppColors.accent : null, size: 18),
                        const SizedBox(width: 8),
                        const Text('Best performers first'),
                      ]),
                    ),
                    PopupMenuItem(
                      value: SortMode.changeAsc,
                      child: Row(children: [
                        Icon(Icons.trending_down,
                            color: _sortMode == SortMode.changeAsc
                                ? AppColors.accent : null, size: 18),
                        const SizedBox(width: 8),
                        const Text('Worst performers first'),
                      ]),
                    ),
                    PopupMenuItem(
                      value: SortMode.nameAsc,
                      child: Row(children: [
                        Icon(Icons.sort_by_alpha,
                            color: _sortMode == SortMode.nameAsc
                                ? AppColors.accent : null, size: 18),
                        const SizedBox(width: 8),
                        const Text('Name A → Z'),
                      ]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWatchlistTabs() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final wl in _watchlists) _watchlistTab(wl),
          InkWell(
            onTap: () => _openWatchlistManager(fromDrawer: false),
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.add, size: 18, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _watchlistTab(WatchlistModel wl) {
    final active = wl.id == _activeWatchlistId;
    return InkWell(
      onTap: () => _selectWatchlist(wl.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: active ? AppColors.accent : Colors.transparent,
                width: 2),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          wl.name,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? AppColors.accent : AppColors.textMuted,
          ),
        ),
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
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.hairline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: AppColors.accentDim,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.35)),
                  ),
                  child: const Icon(Icons.candlestick_chart_rounded,
                      color: AppColors.accent, size: 27),
                ),
                const SizedBox(height: 16),
                const Text('Dhan Trader',
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3)),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Container(
                      width: 6, height: 6,
                      decoration: const BoxDecoration(
                          color: AppColors.up, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Client: ${widget.clientId}',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
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
                            color: AppColors.surface,
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
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.hairline),
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
                                              color: AppColors.up),
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
                                                color: AppColors.warn),
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
                      tileColor: isActive ? AppColors.accentDim : null,
                      leading: Icon(
                        isActive
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isActive
                            ? AppColors.accent
                            : AppColors.textMuted,
                        size: 20,
                      ),
                      title: Text(wl.name,
                          style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isActive ? AppColors.accent : null,
                              fontSize: 14)),
                      subtitle: Text('${wl.stockIds.length} stocks',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textMuted)),
                      onTap: () {
                        Navigator.pop(context); // close drawer
                        _selectWatchlist(wl.id);
                      },
                    ),
                  );
                }),

                _drawerTile(
                  icon: Icons.settings_outlined,
                  label: 'Manage Watchlists',
                  iconColor: AppColors.textMuted,
                  onTap: _openWatchlistManager,
                ),

                const SizedBox(height: 8),

                // Strategies section
                _sectionLabel('STRATEGIES'),
                _drawerTile(
                  icon: Icons.auto_graph,
                  label: 'Strategies',
                  iconColor: AppColors.textMuted,
                  onTap: _openStrategies,
                ),

                const SizedBox(height: 8),

                // Developer section
                _sectionLabel('DEVELOPER'),
                _drawerTile(
                  icon: Icons.article_outlined,
                  label: 'View Logs',
                  iconColor: AppColors.textMuted,
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
                  iconColor: AppColors.textMuted,
                  onTap: _openHoldings,
                ),
                _drawerTile(
                  icon: Icons.receipt_long_outlined,
                  label: 'Paper Trading',
                  iconColor: AppColors.textMuted,
                  onTap: _openPaperPositions,
                ),
                _drawerTile(
                  icon: Icons.manage_accounts_outlined,
                  label: 'Edit Credentials',
                  iconColor: AppColors.textMuted,
                  onTap: _openEditCredentials,
                ),
                _drawerTile(
                  icon: Icons.logout_rounded,
                  label: 'Clear & Logout',
                  iconColor: AppColors.down,
                  labelColor: AppColors.down,
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
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                          isDark ? Icons.dark_mode : Icons.light_mode,
                          color: AppColors.textMuted, size: 20),
                    ),
                    title: Text(isDark ? 'Dark Mode' : 'Light Mode',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    trailing: Switch(
                      value: isDark,
                      onChanged: (_) => MyApp.of(context).toggleTheme(),
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
      final iconColor = _isRateLimitError ? AppColors.warn : AppColors.down;
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
                        backgroundColor: AppColors.accent,
                        foregroundColor: const Color(0xFF0B0D10),
                        elevation: 0,
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
            const Icon(Icons.playlist_add, size: 56, color: AppColors.textFaint),
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

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 2, bottom: 24),
      itemCount: _quotes.length,
      separatorBuilder: (_, __) =>
          const Divider(indent: 16, endIndent: 16),
      itemBuilder: (context, index) => _buildQuoteRow(_quotes[index]),
    );
  }

  Widget _buildQuoteRow(StockQuote q) {
    final chColor = q.isPositive ? AppColors.up : AppColors.down;
    final Widget row = InkWell(
      onTap: () => _showStockDetail(q),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(q.symbol, style: AppText.symbol),
                  const SizedBox(height: 3),
                  Text(q.name,
                      style: AppText.rowSub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(AppFmt.inr(q.ltp), style: AppText.price),
                const SizedBox(height: 3),
                Text(AppFmt.changeLine(q.change, q.changePercent),
                    style: AppText.change.copyWith(color: chColor)),
              ],
            ),
          ],
        ),
      ),
    );

    final flash = _flashes[q.securityId];
    if (flash == null) return row;
    final flashColor = flash.up ? AppColors.up : AppColors.down;
    return TweenAnimationBuilder<double>(
      key: ValueKey('flash_${q.securityId}_${flash.seq}'),
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      builder: (context, t, child) => ColoredBox(
        color: flashColor.withValues(alpha: 0.10 * t),
        child: child,
      ),
      child: row,
    );
  }
}

/// One LTP tick on one stock — drives the row's flash animation.
class _FlashTick {
  final int seq;
  final bool up;
  const _FlashTick(this.seq, this.up);
}

/// Ambient market/feed status: a small dot + label in the app bar.
/// Pulses (gold) only when the feed is connected AND the market is open.
class _MarketStatusPill extends StatefulWidget {
  final FeedStatus feedStatus;
  final bool marketOpen;
  const _MarketStatusPill(
      {required this.feedStatus, required this.marketOpen});

  @override
  State<_MarketStatusPill> createState() => _MarketStatusPillState();
}

class _MarketStatusPillState extends State<_MarketStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live =
        widget.feedStatus == FeedStatus.connected && widget.marketOpen;
    final (color, label) = switch (widget.feedStatus) {
      FeedStatus.connected =>
        live ? (AppColors.accent, 'LIVE') : (AppColors.textFaint, 'CLOSED'),
      FeedStatus.connecting => (AppColors.warn, 'SYNC'),
      FeedStatus.disconnected => (AppColors.down, 'OFFLINE'),
    };

    Widget dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (live) {
      dot = FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
        child: dot,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: color)),
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
          // No letter avatar — the segment badge in the title already
          // carries the type; brokers lead with the symbol text itself.
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
          trailing:
              const Icon(Icons.add_circle_outline, color: AppColors.accent),
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
