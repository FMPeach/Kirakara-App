part of '../../screens/controller_screen.dart';

class _LeftPane extends StatelessWidget {
  const _LeftPane({
    required this.playbackService,
    required this.castService,
    required this.stageRenderer,
  });

  final PlaybackService playbackService;
  final CastService castService;
  final StageRenderer stageRenderer;

  @override
  Widget build(BuildContext context) {
    final state = playbackService.state;
    final song = state.currentSong;
    final castActive = castService.state != CastState.idle;
    return LayoutBuilder(
      builder: (context, constraints) {
        const songStripHeight = 148.0;
        const stageGap = 22.0;
        final availableStageHeight =
            constraints.maxHeight - songStripHeight - stageGap;
        final maxStageHeight =
            availableStageHeight < 0 ? 0.0 : availableStageHeight;
        final stageHeight = maxStageHeight;

        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: stageHeight,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: KiraColors.lineStrong),
                ),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: castActive
                        ? _CastStagePlaceholder(castService: castService)
                        : StagePreviewHost(
                            playbackService: playbackService,
                            stageRenderer: stageRenderer,
                            overlays: [
                              if (!state.isPlaying)
                                Center(
                                  child: FilledButton(
                                    onPressed: playbackService.play,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: KiraColors.cream,
                                      foregroundColor: const Color(0xff17181c),
                                      shape: const CircleBorder(),
                                      fixedSize: const Size(138, 138),
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow,
                                      size: 70,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: stageGap),
            SizedBox(
              height: songStripHeight,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      decoration: _surfaceDecoration(),
                      child: Row(
                        children: [
                          _SongCover(song: song, size: 98),
                          const SizedBox(width: 22),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song?.title ?? '等待点歌',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: KiraColors.cream,
                                    fontSize: 40,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  song?.artist?.name ?? '请从右侧或手机加入歌曲',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: KiraColors.muted,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 22),
                  Container(
                    width: 268,
                    padding: const EdgeInsets.all(19),
                    decoration: _surfaceDecoration(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '升降 Key',
                          style: TextStyle(
                            color: KiraColors.muted,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            SquareIconButton(
                              icon: Icons.remove,
                              onPressed: () => playbackService.transposeBy(-1),
                            ),
                            Expanded(
                              child: Text(
                                state.key > 0
                                    ? '+${state.key}'
                                    : '${state.key}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: KiraColors.amber,
                                  fontSize: 48,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            SquareIconButton(
                              icon: Icons.add,
                              onPressed: () => playbackService.transposeBy(1),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CastStagePlaceholder extends StatelessWidget {
  const _CastStagePlaceholder({
    required this.castService,
  });

  final CastService castService;

  @override
  Widget build(BuildContext context) {
    final url = castService.mpegTsUrl;
    final isStarting = castService.state == CastState.searching;
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.black),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cast_connected,
              color: KiraColors.amber,
              size: 64,
            ),
            const SizedBox(height: 18),
            const Text(
              'Stage 正在投屏输出',
              style: TextStyle(
                color: KiraColors.cream,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              isStarting ? '正在准备输出链路' : url ?? '主控预览已暂停',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: KiraColors.muted,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RightPane extends StatelessWidget {
  const _RightPane({
    required this.onPanel,
  });

  final ValueChanged<String> onPanel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _MenuCard(
            title: '歌名点歌',
            subtitle: '按歌曲标题、编号或作品名查找',
            chips: const ['拼音', '编号', '收藏'],
            icon: Icons.music_note,
            colors: const [
              Color(0xff8f2425),
              KiraColors.red,
              Color(0xffe58c41)
            ],
            leadingStripe: true,
            onTap: () => onPanel('歌名点歌'),
          ),
        ),
        const SizedBox(height: 22),
        Expanded(
          child: _MenuCard(
            title: '歌手点歌',
            subtitle: '按歌手、社团、角色或声库筛选',
            chips: const ['歌手', '社团', '声库'],
            icon: Icons.mic_external_on,
            colors: const [
              Color(0xff2f62db),
              KiraColors.blue,
              Color(0xff70a7ff)
            ],
            onTap: () => onPanel('歌手点歌'),
          ),
        ),
        const SizedBox(height: 22),
        Expanded(
          child: _MenuCard(
            title: '分类点歌',
            subtitle: '热门、动画、同人、VOCALOID',
            chips: const ['热门', '动画', '同人', 'VOCALOID'],
            icon: Icons.library_music,
            colors: const [
              Color(0xffbb3d79),
              KiraColors.pink,
              Color(0xffff91bd)
            ],
            onTap: () => onPanel('分类点歌'),
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 148,
          child: Row(
            children: [
              Expanded(
                child: _SmallMenuCard(
                  title: '外链点歌',
                  icon: Icons.link,
                  colors: const [
                    Color(0xff281b72),
                    KiraColors.violet,
                    Color(0xff6d54d6),
                  ],
                  onTap: () => onPanel('外链点歌'),
                ),
              ),
              const SizedBox(width: 22),
              SizedBox(
                width: 148,
                child: _SmallMenuCard(
                  title: '排行榜',
                  icon: Icons.emoji_events,
                  colors: const [
                    Color(0xffa85422),
                    KiraColors.orange,
                    Color(0xfff0a258),
                  ],
                  compact: true,
                  onTap: () => onPanel('排行榜'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.title,
    required this.subtitle,
    required this.chips,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.leadingStripe = false,
  });

  final String title;
  final String subtitle;
  final List<String> chips;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  final bool leadingStripe;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0x3dffffff)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (leadingStripe)
                const Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(
                    color: Color(0xb8ffffff),
                    child: SizedBox(width: 10),
                  ),
                ),
              const Positioned(
                right: -48,
                bottom: -68,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x1fffffff),
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(width: 212, height: 212),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 35),
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
                              fontSize: 50,
                              height: 1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 11),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xcaffffff),
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 15),
                          Wrap(
                            spacing: 9,
                            runSpacing: 5,
                            children: [
                              for (final chip in chips)
                                Container(
                                  height: 30,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0x29ffffff),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    chip,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 22),
                    Icon(icon, size: 72, color: const Color(0xeaffffff)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallMenuCard extends StatelessWidget {
  const _SmallMenuCard({
    required this.title,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.compact = false,
  });

  final String title;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0x3dffffff)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned(
                right: -48,
                bottom: -68,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x1fffffff),
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(width: 212, height: 212),
                ),
              ),
              Center(
                child: compact
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 38),
                          const SizedBox(height: 9),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 40),
                          const SizedBox(width: 15),
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SongCover extends StatelessWidget {
  const _SongCover({
    required this.song,
    required this.size,
  });

  final Song? song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final coverAsset = song?.assets.cast<MediaAsset?>().firstWhere(
          (a) => a?.type == MediaAssetType.cover,
          orElse: () => null,
        );
    final coverPath = coverAsset?.cachedPath;
    // 构建期间不做同步文件检查：Image.file 自带 errorBuilder，缺图会回退占位图。
    final hasCover = coverPath != null && coverPath.isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x29ffffff)),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasCover
          ? Image.file(
              File(coverPath),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  _CoverPlaceholder(song: song, size: size),
            )
          : _CoverPlaceholder(song: song, size: size),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.song, required this.size});

  final Song? song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Color(song?.coverColor ?? 0xffdd3e38);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.9),
            KiraColors.amber.withValues(alpha: 0.5),
          ],
        ),
      ),
      child: const Icon(
        Icons.music_note,
        color: KiraColors.cream,
      ),
    );
  }
}
