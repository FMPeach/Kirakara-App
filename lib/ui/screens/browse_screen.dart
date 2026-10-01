import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/song.dart';
import '../../ime/ime_controller.dart';
import '../../ime/search_query_controller.dart';
import '../../services/bilibili_account_service.dart';
import '../../services/bilibili_clipboard_input.dart';
import '../../services/bilibili_quality.dart';
import '../../services/bilibili_resolver.dart';
import '../../services/clipboard_service.dart';
import '../../services/search_service.dart';
import '../browse/browse_mode.dart';
import '../input/karaoke_input_panel.dart';
import '../theme/kirakara_theme.dart';
import '../theme/layout_tokens.dart';
import '../widgets/kira_design_canvas.dart';

part '../browse/pages/song_browse_page.dart';
part '../browse/pages/artist_browse_page.dart';
part '../browse/pages/artist_detail_page.dart';
part '../browse/pages/category_browse_page.dart';
part '../browse/pages/external_link_page.dart';
part '../browse/pages/ranking_page.dart';
part '../browse/widgets/song_result_panel.dart';
part '../browse/widgets/external_link_panel.dart';
part '../browse/widgets/bilibili_account_rail.dart';
part '../browse/widgets/artist_result_panel.dart';
part '../browse/widgets/browse_rails.dart';
part '../browse/widgets/browse_shared_widgets.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.searchService,
    required this.bilibiliAccountService,
    required this.initialMode,
    required this.onExit,
    required this.onAddSong,
    required this.onBumpSong,
    this.initialQuery = '',
    this.clipboardService = const ClipboardService(),
  });

  final SearchService searchService;
  final BilibiliAccountService bilibiliAccountService;
  final BrowseMode initialMode;
  final String initialQuery;
  final ClipboardService clipboardService;
  final VoidCallback onExit;
  final ValueChanged<Song> onAddSong;
  final ValueChanged<Song> onBumpSong;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  late final SearchQueryController _searchQueryController;
  late final ImeController _imeController;
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'browse-search');

  late BrowseMode _mode;
  String _songQuery = '';
  String _songScope = '全部';
  String _artistQuery = '';
  String _artistCategory = '全部';
  String _artistSongQuery = '';
  String _categoryQuery = '';
  String _activeCategory = '热门';
  String _activeRanking = '热门榜';
  ArtistSummary? _activeArtist;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _songQuery = widget.initialQuery;
    _searchQueryController = SearchQueryController(text: _songQuery);
    _searchQueryController.addListener(_handleSearchControllerChanged);
    _imeController = ImeController(
      searchQueryController: _searchQueryController,
    );
    _syncSearchController();
  }

  @override
  void didUpdateWidget(covariant BrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMode != widget.initialMode ||
        oldWidget.initialQuery != widget.initialQuery) {
      _mode = widget.initialMode;
      _songQuery = widget.initialQuery;
      _songScope = '全部';
      _activeArtist = null;
      _syncSearchController();
    }
  }

  @override
  void dispose() {
    _searchQueryController.removeListener(_handleSearchControllerChanged);
    _imeController.dispose();
    _searchQueryController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: KiraLayout.pagePadding,
      child: switch (_mode) {
        BrowseMode.songs => _buildSongPage(),
        BrowseMode.artists => _buildArtistPage(),
        BrowseMode.artistDetail => _buildArtistDetailPage(),
        BrowseMode.categories => _buildCategoryPage(),
        BrowseMode.externalLink => _buildExternalLinkPage(),
        BrowseMode.ranking => _buildRankingPage(),
      },
    );
  }

  void _update(VoidCallback fn) {
    setState(fn);
  }

  void _openArtist(ArtistSummary artist) {
    setState(() {
      _activeArtist = artist;
      _artistSongQuery = '';
      _mode = BrowseMode.artistDetail;
    });
    _syncSearchController();
  }

  void _addSong(Song song) {
    widget.onAddSong(song);
  }

  void _bumpSong(Song song) {
    widget.onBumpSong(song);
  }

  void _switchSearchTab(String tab) {
    setState(() {
      _activeArtist = null;
      _mode = switch (tab) {
        '歌手' => BrowseMode.artists,
        '分类' => BrowseMode.categories,
        _ => BrowseMode.songs,
      };
    });
    _syncSearchController();
  }

  void _handleSearchChanged(String value) {
    setState(() {
      switch (_mode) {
        case BrowseMode.songs:
          _songQuery = value;
        case BrowseMode.artists:
          _artistQuery = value;
        case BrowseMode.artistDetail:
          _artistSongQuery = value;
        case BrowseMode.categories:
          _categoryQuery = value;
        case BrowseMode.externalLink:
        case BrowseMode.ranking:
          break;
      }
    });
  }

  void _handleSongScope(String scope) {
    setState(() => _songScope = scope);
  }

  void _handleSearchControllerChanged() {
    if (!mounted) {
      return;
    }
    _handleSearchChanged(_searchQueryController.text);
  }

  void _handleSearchSubmit() {}

  String _currentQuery() {
    return switch (_mode) {
      BrowseMode.songs => _songQuery,
      BrowseMode.artists => _artistQuery,
      BrowseMode.artistDetail => _artistSongQuery,
      BrowseMode.categories => _categoryQuery,
      BrowseMode.externalLink => '',
      BrowseMode.ranking => '',
    };
  }

  List<Song> _scopedSongs() {
    if (_songScope != '全部') {
      // 通过 DB 关系查分类，不用 song.category（后者只存了首个分类）
      final scopeCategory = CategorySummary(name: _songScope, note: '');
      return widget.searchService
          .songsForCategory(scopeCategory, query: _songQuery);
    }
    return widget.searchService.searchSongs(_songQuery);
  }

  List<String> get _songScopeOptions {
    final cats = widget.searchService.categories
        .where((c) => c.name != '热门')
        .map((c) => c.name)
        .toList();
    return ['全部', ...cats];
  }

  void _syncSearchController() {
    final value = _currentQuery();
    _searchQueryController.setText(value);
  }
}
