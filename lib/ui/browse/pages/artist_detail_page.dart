part of '../../screens/browse_screen.dart';

extension _ArtistDetailPage on _BrowseScreenState {
  Widget _buildArtistDetailPage() {
    final artist = _activeArtist;
    final artistSongs = artist == null
        ? const <Song>[]
        : widget.searchService.songsForArtist(
            artist,
            query: _artistSongQuery,
          );
    final total = artist == null
        ? 0
        : widget.searchService.songCountForArtist(artist);

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
            title: artist?.name ?? '歌手详情',
            subtitle: artist == null
                ? ''
                : widget.searchService.labelMaps?.artistTypeLabel(artist.type) ??
                    artist.type,
            songs: artistSongs,
            emptyText: artist == null
                ? '暂无歌手'
                : total == 0
                    ? '该歌手暂无歌曲'
                    : '没有找到匹配歌曲',
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
            placeholder:
                artist == null ? '在歌手内搜索' : '在 ${artist.name} 的歌曲中搜索',
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
