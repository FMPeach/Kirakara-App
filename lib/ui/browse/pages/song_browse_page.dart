part of '../../screens/browse_screen.dart';

extension _SongBrowsePage on _BrowseScreenState {
  Widget _buildSongPage() {
    final songs = _scopedSongs();
    final subtitle = _songScope == '全部'
        ? (_songQuery.trim().isEmpty ? '全曲库搜索' : '搜索：$_songQuery')
        : '$_songScope 分类内搜索';
    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _SongScopeRail(
            title: '搜索范围',
            options: _songScopeOptions,
            activeOption: _songScope,
            onBack: widget.onExit,
            onSelected: _handleSongScope,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _SongResultPanel(
            title: '歌名点歌',
            subtitle: subtitle,
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
            activeTab: '歌名',
            placeholder: '搜索歌名、歌手、编号',
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
