part of '../../screens/browse_screen.dart';

extension _CategoryBrowsePage on _BrowseScreenState {
  Widget _buildCategoryPage() {
    final categories = widget.searchService.categories;
    // A fresh or unsynchronized catalog can have no categories. Keep the
    // navigation controls available instead of failing the entire page build.
    final activeMeta = categories.isEmpty
        ? null
        : categories.firstWhere(
            (category) => category.name == _activeCategory,
            orElse: () => categories.first,
          );
    final songs = activeMeta == null
        ? const <Song>[]
        : widget.searchService.songsForCategory(
            activeMeta,
            query: _categoryQuery,
          );

    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _CategoryRail(
            categories: categories,
            activeCategory: activeMeta?.name ?? '',
            onBack: widget.onExit,
            onSelected: (category) {
              _update(() => _activeCategory = category.name);
            },
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _SongResultPanel(
            title: activeMeta?.name ?? '分类点歌',
            subtitle: activeMeta?.note ?? '曲库同步后即可按分类点歌',
            songs: songs,
            emptyText: activeMeta == null ? '暂无歌曲分类' : '没有找到匹配歌曲',
            columns: 1,
            onAddSong: _addSong,
            onBumpSong: _bumpSong,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        SizedBox(
          width: KiraLayout.inputPanelWidth,
          child: KaraokeInputPanel(
            activeTab: '分类',
            placeholder: '在当前分类中搜索歌曲、歌手、编号',
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
