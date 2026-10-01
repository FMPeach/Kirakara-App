part of '../../screens/browse_screen.dart';

extension _ArtistDetailPage on _BrowseScreenState {
  Widget _buildArtistDetailPage() {
    final artist = _activeArtist ?? widget.searchService.artists.first;
    final artistSongs = widget.searchService.songsForArtist(
      artist,
      query: _artistSongQuery,
    );
    final total = widget.searchService.songCountForArtist(artist);

    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _ArtistDetailRail(
            artist: artist,
            songCount: total,
            onBack: () {
              _update(() {
                _mode = BrowseMode.artists;
                _activeArtist = null;
                _artistSongQuery = '';
              });
              _syncSearchController();
            },
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _SongResultPanel(
            title: artist.name,
            subtitle:
                widget.searchService.labelMaps?.artistTypeLabel(artist.type) ??
                    artist.type,
            songs: artistSongs,
            columns: 1,
            onAddSong: _addSong,
            onBumpSong: _bumpSong,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        SizedBox(
          width: KiraLayout.inputPanelWidth,
          child: KaraokeInputPanel(
            activeTab: '歌手内',
            tabs: const ['歌手内'],
            placeholder: '在 ${artist.name} 的歌曲中搜索',
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
