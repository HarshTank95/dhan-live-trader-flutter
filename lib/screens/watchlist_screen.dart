import 'package:flutter/material.dart';
import '../services/scrip_service.dart';

class WatchlistScreen extends StatefulWidget {
  final String watchlistName;
  final List<int> currentWatchlist;
  final ScripService scripService;

  const WatchlistScreen({
    super.key,
    required this.watchlistName,
    required this.currentWatchlist,
    required this.scripService,
  });

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  late List<int> _watchlist;
  final _searchController = TextEditingController();
  List<ScripInfo> _searchResults = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _watchlist = List.from(widget.currentWatchlist);
  }

  void _onSearchChanged(String query) {
    setState(() {
      _isSearching = query.isNotEmpty;
      _searchResults = widget.scripService.search(query);
    });
  }

  void _addStock(ScripInfo scrip) {
    if (_watchlist.contains(scrip.securityId)) return;
    if (_watchlist.length >= 20) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Max 20 stocks in watchlist')),
      );
      return;
    }
    setState(() => _watchlist.add(scrip.securityId));
  }

  void _removeStock(int securityId) {
    if (_watchlist.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Watchlist must have at least 1 stock')),
      );
      return;
    }
    setState(() => _watchlist.remove(securityId));
  }

  void _save() {
    Navigator.pop(context, _watchlist);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.watchlistName),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search stocks (e.g. HDFC, Infosys...)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                filled: true,
              ),
            ),
          ),

          Expanded(
            child: _isSearching
                ? _buildSearchResults()
                : _buildCurrentWatchlist(),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentWatchlist() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'YOUR WATCHLIST  (${_watchlist.length}/20)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _watchlist.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final id = _watchlist.removeAt(oldIndex);
                _watchlist.insert(newIndex, id);
              });
            },
            itemBuilder: (context, index) {
              final id = _watchlist[index];
              final scrip = widget.scripService.findById(id);
              return ListTile(
                key: ValueKey(id),
                leading: CircleAvatar(
                  backgroundColor: Colors.blue.shade100,
                  child: Text(
                    (scrip?.symbol ?? '?')[0],
                    style: const TextStyle(
                        color: Colors.blue, fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(scrip?.symbol ?? 'ID: $id',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  scrip?.name ?? '',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline,
                          color: Colors.red),
                      onPressed: () => _removeStock(id),
                    ),
                    const Icon(Icons.drag_handle, color: Colors.grey),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.blue.shade50,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.drag_indicator, size: 14, color: Colors.grey),
              SizedBox(width: 4),
              Text('Drag to reorder  •  Tap − to remove',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return const Center(child: Text('No stocks found'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'RESULTS  (${_searchResults.length})',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _searchResults.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final scrip = _searchResults[index];
              final isAdded = _watchlist.contains(scrip.securityId);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      isAdded ? Colors.green.shade100 : Colors.blue.shade50,
                  child: Text(
                    scrip.symbol[0],
                    style: TextStyle(
                      color: isAdded ? Colors.green : Colors.blue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(scrip.symbol,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(scrip.name,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis),
                trailing: isAdded
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : IconButton(
                        icon: const Icon(Icons.add_circle_outline,
                            color: Colors.blue),
                        onPressed: () => _addStock(scrip),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}
