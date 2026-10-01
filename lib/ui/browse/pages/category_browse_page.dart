part of '../../screens/browse_screen.dart';

extension _CategoryBrowsePage on _BrowseScreenState {
  Widget _buildCategoryPage() {
    final activeMeta = widget.searchService.categories.firstWhere(
      (category) => category.name == _activeCategory,
      orElse: () => widget.searchService.categories.first,
    );
    final songs = widget.searchService.songsForCategory(
      activeMeta,
      query: _categoryQuery,
    );

    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _CategoryRail(
            categories: widget.searchService.categories,
            activeCategory: activeMeta.name,
            onBack: widget.onExit,
            onSelected: (category) {
              _update(() => _activeCategory = category.name);
            },
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _SongResultPanel(
            title: activeMeta.name,
            subtitle: activeMeta.note,
            songs: songs,
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
