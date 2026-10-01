part of '../../screens/browse_screen.dart';

class _SongResultPanel extends StatelessWidget {
  const _SongResultPanel({
    required this.title,
    required this.subtitle,
    required this.songs,
    required this.columns,
    required this.onAddSong,
    required this.onBumpSong,
  });

  final String title;
  final String subtitle;
  final List<Song> songs;
  final int columns;
  final ValueChanged<Song> onAddSong;
  final ValueChanged<Song> onBumpSong;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            _ResultHero(
              title: title,
              subtitle: subtitle,
              count: songs.length,
            ),
            Expanded(
              child: songs.isEmpty
                  ? const _EmptyState(text: '没有找到匹配歌曲')
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 94,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        return _SongResultCard(
                          song: songs[index],
                          index: index,
                          onAddSong: onAddSong,
                          onBumpSong: onBumpSong,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultHero extends StatelessWidget {
  const _ResultHero({
    required this.title,
    required this.subtitle,
    required this.count,
  });

  final String title;
  final String subtitle;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 116,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xff79335f),
            Color(0xff33466f),
          ],
        ),
        border: Border(bottom: BorderSide(color: KiraColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: KiraColors.cream,
                    fontSize: 42,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xdfffffff),
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$count',
            style: const TextStyle(
              color: KiraColors.amber,
              fontSize: 50,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SongResultCard extends StatelessWidget {
  const _SongResultCard({
    required this.song,
    required this.index,
    required this.onAddSong,
    required this.onBumpSong,
  });

  final Song song;
  final int index;
  final ValueChanged<Song> onAddSong;
  final ValueChanged<Song> onBumpSong;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(
                (index + 1).toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: KiraColors.amber,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: KiraColors.cream,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${song.artist?.name ?? '未知'} · ${song.category} · ${song.code ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: KiraColors.muted,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 56,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onBumpSong(song),
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_upward,
                                size: 14, color: KiraColors.muted),
                            SizedBox(width: 4),
                            Text(
                              '顶歌',
                              style: TextStyle(
                                color: KiraColors.muted,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    height: 56,
                    child: FilledButton(
                      onPressed: () => onAddSong(song),
                      style: FilledButton.styleFrom(
                        backgroundColor: KiraColors.red,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        '点歌',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
