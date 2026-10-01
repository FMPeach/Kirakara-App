import 'package:flutter/foundation.dart';

import '../domain/queue_item.dart';
import '../domain/song.dart';

class QueueService extends ChangeNotifier {
  final List<QueueItem> _items = [];
  final Map<String, String> _failures = {};
  int _sequence = 0;

  List<QueueItem> get items => List.unmodifiable(_items);
  QueueItem? get nextPlayableItem {
    for (final item in _items) {
      if (!_failures.containsKey(item.id)) return item;
    }
    return null;
  }

  bool isFailed(String itemId) => _failures.containsKey(itemId);
  String? failureFor(String itemId) => _failures[itemId];

  QueueItem addSong(Song song, {String requestedBy = '本机'}) {
    final item = QueueItem(
      id: 'queue-${++_sequence}',
      song: song,
      requestedBy: requestedBy,
      addedAt: DateTime.now(),
    );
    _items.add(item);
    notifyListeners();
    return item;
  }

  QueueItem? takeNext() {
    for (var index = 0; index < _items.length; index++) {
      final item = _items[index];
      if (_failures.containsKey(item.id)) continue;
      _items.removeAt(index);
      _failures.remove(item.id);
      notifyListeners();
      return item;
    }
    return null;
  }

  void move(int from, int to) {
    if (from < 0 || from >= _items.length || to < 0 || to >= _items.length) {
      return;
    }
    final item = _items.removeAt(from);
    _items.insert(to, item);
    notifyListeners();
  }

  QueueItem bumpToNext(Song song, {String requestedBy = '本机'}) {
    final item = QueueItem(
      id: 'queue-${++_sequence}',
      song: song,
      requestedBy: requestedBy,
      addedAt: DateTime.now(),
    );
    _items.insert(0, item);
    notifyListeners();
    return item;
  }

  void bumpItemToNext(String id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final item = _items.removeAt(index);
    _items.insert(0, item);
    notifyListeners();
  }

  void remove(String id) {
    _items.removeWhere((item) => item.id == id);
    _failures.remove(id);
    notifyListeners();
  }

  void retainFailed(QueueItem item, String error) {
    if (!_items.any((candidate) => candidate.id == item.id)) {
      _items.insert(0, item);
    }
    _failures[item.id] = error;
    notifyListeners();
  }

  void markFailed(String id, String error) {
    if (!_items.any((item) => item.id == id)) return;
    _failures[id] = error;
    notifyListeners();
  }

  void retry(String id) {
    if (!_items.any((item) => item.id == id)) return;
    _failures.remove(id);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    _failures.clear();
    notifyListeners();
  }
}
