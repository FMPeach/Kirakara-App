part of '../../screens/browse_screen.dart';

class _ArtistResultPanel extends StatelessWidget {
  const _ArtistResultPanel({
    required this.artists,
    required this.songCountForArtist,
    required this.onArtist,
    required this.typeLabel,
  });

  final List<ArtistSummary> artists;
  final int Function(ArtistSummary artist) songCountForArtist;
  final ValueChanged<ArtistSummary> onArtist;
  final String Function(ArtistSummary artist) typeLabel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: artists.isEmpty
          ? const _EmptyState(text: '没有匹配歌手')
          : GridView.builder(
              padding: const EdgeInsets.all(18),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 140,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: artists.length,
              itemBuilder: (context, index) {
                final artist = artists[index];
                return _ArtistCard(
                  artist: artist,
                  songCount: songCountForArtist(artist),
                  typeLabel: typeLabel(artist),
                  onTap: () => onArtist(artist),
                );
              },
            ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({
    required this.artist,
    required this.songCount,
    required this.typeLabel,
    required this.onTap,
  });

  final ArtistSummary artist;
  final int songCount;
  final String typeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: _cardDecoration(),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _AvatarLetter(text: artist.name.characters.first, size: 72),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: KiraColors.cream,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        typeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: KiraColors.muted,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _CountPill(text: '$songCount 首歌曲'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistDetailRail extends StatelessWidget {
  const _ArtistDetailRail({
    required this.artist,
    required this.songCount,
    required this.onBack,
  });

  final ArtistSummary artist;
  final int songCount;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _BackButton(onPressed: onBack),
              ],
            ),
            const SizedBox(height: 22),
            _AvatarLetter(
              text: artist.name.characters.first,
              size: 376,
              fontSize: 104,
            ),
            const SizedBox(height: 24),
            Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: KiraColors.cream,
                fontSize: 37,
                height: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '${artist.group} · ${artist.note}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: KiraColors.muted,
                fontSize: 18,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Container(
              height: 64,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x1af2b84b),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x45f2b84b)),
              ),
              child: Text(
                '共 $songCount 首歌曲',
                style: const TextStyle(
                  color: KiraColors.amber,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
