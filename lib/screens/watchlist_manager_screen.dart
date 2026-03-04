import 'package:flutter/material.dart';
import '../models/watchlist_model.dart';
import '../services/scrip_service.dart';
import '../services/storage_service.dart';
import 'watchlist_screen.dart';

class WatchlistManagerScreen extends StatefulWidget {
  final List<WatchlistModel> watchlists;
  final String activeId;
  final ScripService scripService;

  const WatchlistManagerScreen({
    super.key,
    required this.watchlists,
    required this.activeId,
    required this.scripService,
  });

  @override
  State<WatchlistManagerScreen> createState() =>
      _WatchlistManagerScreenState();
}

class _WatchlistManagerScreenState extends State<WatchlistManagerScreen> {
  late List<WatchlistModel> _watchlists;
  late String _activeId;

  @override
  void initState() {
    super.initState();
    _watchlists = List.from(widget.watchlists);
    _activeId = widget.activeId;
  }

  Future<void> _save() async {
    await StorageService.saveAllWatchlists(_watchlists);
    await StorageService.saveActiveWatchlistId(_activeId);
    if (!mounted) return;
    Navigator.pop(context, (watchlists: _watchlists, activeId: _activeId));
  }

  Future<void> _createWatchlist() async {
    final name = await _showNameDialog('New Watchlist', '');
    if (name == null || name.trim().isEmpty) return;
    setState(() {
      _watchlists.add(WatchlistModel(
        name: name.trim(),
        stockIds: [],
      ));
    });
  }

  Future<void> _renameWatchlist(WatchlistModel wl) async {
    final name = await _showNameDialog('Rename Watchlist', wl.name);
    if (name == null || name.trim().isEmpty) return;
    setState(() => wl.name = name.trim());
  }

  void _deleteWatchlist(WatchlistModel wl) {
    if (_watchlists.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the last watchlist')),
      );
      return;
    }
    setState(() {
      _watchlists.remove(wl);
      if (_activeId == wl.id) {
        _activeId = _watchlists.first.id;
      }
    });
  }

  Future<void> _editStocks(WatchlistModel wl) async {
    final result = await Navigator.push<List<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => WatchlistScreen(
          watchlistName: wl.name,
          currentWatchlist: wl.stockIds,
          scripService: widget.scripService,
        ),
      ),
    );

    if (result != null) {
      setState(() => wl.stockIds = result);
    }
  }

  Future<String?> _showNameDialog(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Bank Stocks, Nifty 50...',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Watchlists'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('Done'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createWatchlist,
        icon: const Icon(Icons.add),
        label: const Text('New Watchlist'),
      ),
      body: _watchlists.isEmpty
          ? const Center(child: Text('No watchlists yet. Create one!'))
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: _watchlists.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final wl = _watchlists[index];
                final isActive = wl.id == _activeId;

                return Dismissible(
                  key: ValueKey(wl.id),
                  direction: _watchlists.length > 1
                      ? DismissDirection.endToStart
                      : DismissDirection.none,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Colors.red,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
                    return await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Delete Watchlist?'),
                        content: Text(
                            'Delete "${wl.name}"? This cannot be undone.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                  },
                  onDismissed: (_) => _deleteWatchlist(wl),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    leading: GestureDetector(
                      onTap: () => setState(() => _activeId = wl.id),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.blue
                              : Colors.grey.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isActive
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: isActive ? Colors.white : Colors.grey,
                          size: 22,
                        ),
                      ),
                    ),
                    title: GestureDetector(
                      onDoubleTap: () => _renameWatchlist(wl),
                      child: Text(
                        wl.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isActive ? Colors.blue : null,
                        ),
                      ),
                    ),
                    subtitle: Text(
                      '${wl.stockIds.length} stock${wl.stockIds.length == 1 ? '' : 's'}  •  Double-tap to rename',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.blue),
                            ),
                            child: const Text('Active',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.w600)),
                          ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined,
                              color: Colors.blue),
                          tooltip: 'Edit stocks',
                          onPressed: () => _editStocks(wl),
                        ),
                      ],
                    ),
                    onTap: () => setState(() => _activeId = wl.id),
                  ),
                );
              },
            ),
    );
  }
}
