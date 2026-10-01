part of '../../screens/browse_screen.dart';

extension _RankingPage on _BrowseScreenState {
  /// 榜单列表来自服务器 manifest（本地 rankings 表），直接用服务器下发的值。
  /// 服务器暂未下发 note/icon，先用统一默认；后续 json 加描述一栏再扩展读取。
  List<({String name, String note, IconData icon})> get _rankingCategories {
    final rankings = widget.searchService.rankings;
    if (rankings.isEmpty) return const [];
    return rankings
        .map((r) => (name: r.name, note: '', icon: Icons.star))
        .toList();
  }

  Widget _buildRankingPage() {
    final allRankings = widget.searchService.rankings;
    final categories = _rankingCategories;
    final activeRanking = allRankings.isEmpty
        ? null
        : allRankings.firstWhere(
            (r) => r.name == _activeRanking,
            orElse: () => allRankings.first,
          );
    final rankingSongs = activeRanking != null
        ? widget.searchService.songsForRanking(activeRanking).take(8).toList()
        : widget.searchService.featuredSongs.take(8).toList();
    final activeMeta = categories.firstWhere(
      (r) => r.name == (activeRanking?.name ?? ''),
      orElse: () => categories.isNotEmpty
          ? categories.first
          : (name: '', note: '', icon: Icons.star),
    );

    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _RankingRail(
            categories: categories,
            activeCategory: activeRanking?.name ?? '',
            onBack: widget.onExit,
            onSelected: (name) {
              _update(() => _activeRanking = name);
            },
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _SongResultPanel(
            title: activeMeta.name,
            subtitle: activeMeta.note,
            songs: rankingSongs,
            columns: 1,
            onAddSong: _addSong,
            onBumpSong: _bumpSong,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        SizedBox(
          width: KiraLayout.inputPanelWidth,
          child: KaraokeInputPanel(
            activeTab: '排行',
            tabs: const ['排行'],
            placeholder: '在排行榜中搜索歌曲',
            controller: _searchQueryController.textController,
            searchFocusNode: _searchFocusNode,
            imeController: _imeController,
            onTab: _switchSearchTab,
            onSearch: _handleSearchSubmit,
          ),
        ),
      ],
    );
  }
}
