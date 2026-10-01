part of '../../screens/browse_screen.dart';

extension _ExternalLinkPage on _BrowseScreenState {
  Widget _buildExternalLinkPage() {
    return Row(
      children: [
        SizedBox(
          width: KiraLayout.browseRailWidth,
          child: _BilibiliAccountRail(
            accountService: widget.bilibiliAccountService,
            onBack: widget.onExit,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        Expanded(
          child: _ExternalLinkPanel(
            accountService: widget.bilibiliAccountService,
            clipboardService: widget.clipboardService,
            onAddSong: widget.onAddSong,
            onBumpSong: widget.onBumpSong,
          ),
        ),
        const SizedBox(width: KiraLayout.sectionGap),
        SizedBox(
          width: KiraLayout.inputPanelWidth,
          child: KaraokeInputPanel(
            activeTab: '外链',
            tabs: const ['外链'],
            placeholder: '搜索已解析的外链歌曲',
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
