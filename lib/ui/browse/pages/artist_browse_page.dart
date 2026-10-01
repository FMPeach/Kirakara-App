part of '../../screens/browse_screen.dart';

extension _ArtistBrowsePage on _BrowseScreenState {
  Widget _buildArtistPage() {
    final artists = widget.searchService.searchArtists(
      _artistQuery,
      category: _artistCategory,
    );
    final categories = [
      '全部',
      ...widget.searchService.artists.map((artist) => artist.group).toSet(),
    ];

    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _OptionRail(
            title: '地区与类型',
            options: categories,
            activeOption: _artistCategory,
            onBack: widget.onExit,
            onSelected: (category) {
              _update(() => _artistCategory = category);
            },
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _ArtistResultPanel(
            artists: artists,
            songCountForArtist: widget.searchService.songCountForArtist,
            typeLabel: (a) =>
                widget.searchService.labelMaps?.artistTypeLabel(a.type) ??
                a.type,
            onArtist: _openArtist,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        SizedBox(
          width: KiraLayout.inputPanelWidth,
          child: KaraokeInputPanel(
            activeTab: '歌手',
            placeholder: '搜索歌手、角色、社团或声库',
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
