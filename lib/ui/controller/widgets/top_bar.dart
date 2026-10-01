part of '../../screens/controller_screen.dart';

enum _AnnouncementMotion {
  marquee,
  lowMotionFade,
  lowMotionHardCut,
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.customAnnouncement,
    required this.playbackService,
    required this.isLoading,
    required this.isBuffering,
    required this.showSearch,
    required this.controllerFullscreen,
    required this.isCasting,
    required this.announcementMotion,
    required this.onSearchTap,
    required this.onQr,
    required this.onSettings,
    required this.onFullscreen,
    required this.onCast,
  });

  final String customAnnouncement;
  final PlaybackService playbackService;
  final bool isLoading;
  final bool isBuffering;
  final bool showSearch;
  final bool controllerFullscreen;
  final bool isCasting;
  final _AnnouncementMotion announcementMotion;
  final VoidCallback onSearchTap;
  final VoidCallback onQr;
  final VoidCallback onSettings;
  final VoidCallback onFullscreen;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final state = playbackService.state;
    final tickerItems = _tickerItems(
      customAnnouncement: customAnnouncement,
      current: state.currentSong,
      next: state.upNext?.song,
      mode: state.mode,
      isLoading: isLoading,
      isBuffering: isBuffering,
    );
    final tickerText = tickerItems.join('  ·  ');
    final brandBlock = SizedBox(
      width: 325,
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: KiraColors.cream,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/branding/app_icon.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              semanticLabel: 'Kirakara app icon',
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: const Offset(0, 4),
                child: Image.asset(
                  'assets/branding/wordmark.png',
                  height: 40,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  filterQuality: FilterQuality.high,
                  semanticLabel: 'Kira Karaoke',
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final tickerBlock = Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 19),
      decoration: BoxDecoration(
        color: const Color(0xff111216),
        border: Border.all(color: KiraColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const _TickerTag(text: '报幕'),
          const SizedBox(width: 15),
          Expanded(
            child: announcementMotion != _AnnouncementMotion.marquee
                ? _LowMotionAnnouncementRotator(
                    items: tickerItems,
                    fadeTransitions:
                        announcementMotion == _AnnouncementMotion.lowMotionFade,
                    style: const TextStyle(
                      color: KiraColors.cream,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : _MarqueeText(
                    text: tickerText,
                    style: const TextStyle(
                      color: KiraColors.cream,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
    );

    Widget buildActions({required bool includeSearch}) {
      return Row(
        mainAxisSize: includeSearch ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (includeSearch) ...[
            Expanded(
              child: _TopSearchEntry(onPressed: onSearchTap),
            ),
            const SizedBox(width: 15),
          ],
          _TopIconButton(
            icon: Icons.qr_code,
            tooltip: '手机点歌',
            onPressed: onQr,
          ),
          const SizedBox(width: 15),
          _TopIconButton(
            icon: Icons.settings,
            tooltip: '设置',
            onPressed: onSettings,
          ),
          const SizedBox(width: 15),
          _TopIconButton(
            icon:
                controllerFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            tooltip: controllerFullscreen ? '退出全屏' : '全屏',
            onPressed: onFullscreen,
          ),
          const SizedBox(width: 15),
          _TopTextButton(
            icon: Icons.cast,
            width: 115,
            label: isCasting ? '投屏中' : '投屏',
            active: isCasting,
            onPressed: onCast,
          ),
        ],
      );
    }

    return Container(
      height: 95,
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
      decoration: const BoxDecoration(
        color: Color(0xf5121317),
        border: Border(bottom: BorderSide(color: KiraColors.line)),
      ),
      child: Row(
        children: showSearch
            ? [
                Expanded(
                  flex: 2,
                  child: Row(
                    children: [
                      brandBlock,
                      const SizedBox(width: 22),
                      Expanded(child: tickerBlock),
                    ],
                  ),
                ),
                const SizedBox(width: 22),
                Expanded(
                  flex: 1,
                  child: buildActions(includeSearch: true),
                ),
              ]
            : [
                brandBlock,
                const SizedBox(width: 22),
                Expanded(child: tickerBlock),
                const SizedBox(width: 22),
                buildActions(includeSearch: false),
              ],
      ),
    );
  }

  static List<String> _tickerItems({
    required String customAnnouncement,
    required Song? current,
    required Song? next,
    required PlaybackMode mode,
    required bool isLoading,
    required bool isBuffering,
  }) {
    final custom = customAnnouncement.trim();
    var currentText = '当前播放：${_songLabel(current, fallback: '等待点歌')}';
    if (isLoading) {
      currentText += ' · 正在加载';
    } else if (isBuffering) {
      currentText += ' · 正在缓冲';
    } else if (current == null || mode == PlaybackMode.stopped) {
      currentText += ' · 已停止';
    } else if (mode == PlaybackMode.paused) {
      currentText += ' · 暂停中';
    }
    return <String>[
      if (custom.isNotEmpty) custom,
      currentText,
      next == null ? '下一首：暂无，快去点一首吧' : '下一首：${_songLabel(next)}',
    ];
  }

  static String _songLabel(Song? song, {String fallback = '暂无'}) {
    if (song == null) return fallback;
    return '${song.title} - ${song.artist?.name ?? '未知歌手'}';
  }
}

class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> implements TickerProvider {
  static const int _marqueeTickerFps = 30;
  static const double _overflowSafetyMargin = 12;
  static const Duration _marqueeStep =
      Duration(microseconds: 1000000 ~/ _marqueeTickerFps);

  late final AnimationController _controller;
  Duration _marqueeLastEmit = Duration.zero;
  Duration _marqueeNextEmit = Duration.zero;
  Ticker? _marqueeTicker;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  Ticker createTicker(TickerCallback onTick) {
    assert(
      _marqueeTicker == null,
      'createTicker 只能调用一次；滚动报幕只应有一个 ticker',
    );
    _marqueeTicker = Ticker(
      (Duration elapsed) {
        if (elapsed < _marqueeLastEmit) {
          _marqueeLastEmit = Duration.zero;
          _marqueeNextEmit = Duration.zero;
        }
        if (elapsed < _marqueeNextEmit) return;
        _marqueeLastEmit = elapsed;
        _marqueeNextEmit = elapsed + _marqueeStep;
        onTick(elapsed);
      },
      debugLabel: 'marquee-throttled-${_marqueeTickerFps}fps',
    );
    return _marqueeTicker!;
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const ValueKey('marquee-viewport'),
      builder: (context, constraints) {
        final textWidth = _measureText(context, widget.text, widget.style);
        final availableWidth = constraints.maxWidth;
        if (!textWidth.isFinite ||
            !availableWidth.isFinite ||
            textWidth <= availableWidth - _overflowSafetyMargin) {
          _controller.stop();
          return Text(
            key: const ValueKey('marquee-static-run'),
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: widget.style,
          );
        }

        const gap = 96.0;
        final distance = textWidth + gap;
        final duration = Duration(
          milliseconds: (distance / 68 * 1000).round().clamp(5000, 30000),
        );
        if (!_controller.isAnimating || _controller.duration != duration) {
          _controller
            ..duration = duration
            ..repeat();
        }

        return ClipRect(
          child: SizedBox.expand(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              child: AnimatedBuilder(
                animation: _controller,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MarqueeTextRun(
                      key: const ValueKey('marquee-leading-run'),
                      text: widget.text,
                      style: widget.style,
                    ),
                    const SizedBox(width: gap),
                    _MarqueeTextRun(
                      key: const ValueKey('marquee-trailing-run'),
                      text: widget.text,
                      style: widget.style,
                    ),
                    const SizedBox(width: gap),
                  ],
                ),
                builder: (context, child) => FractionalTranslation(
                  translation: Offset(-0.5 * _controller.value, 0),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static double _measureText(
    BuildContext context,
    String text,
    TextStyle style,
  ) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final painter = TextPainter(
      text: TextSpan(text: text, style: effectiveStyle),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _MarqueeTextRun extends StatelessWidget {
  const _MarqueeTextRun({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
      style: style,
    );
  }
}

class _LowMotionAnnouncementRotator extends StatefulWidget {
  const _LowMotionAnnouncementRotator({
    required this.items,
    required this.fadeTransitions,
    required this.style,
  });

  final List<String> items;
  final bool fadeTransitions;
  final TextStyle style;

  @override
  State<_LowMotionAnnouncementRotator> createState() =>
      _LowMotionAnnouncementRotatorState();
}

class _LowMotionAnnouncementRotatorState
    extends State<_LowMotionAnnouncementRotator> with WidgetsBindingObserver {
  static const Duration _switchInterval = Duration(seconds: 5);
  static const Duration _fadeDuration = Duration(milliseconds: 180);

  Timer? _switchTimer;
  int _index = 0;
  bool _appVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appVisible = _isVisible(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didUpdateWidget(covariant _LowMotionAnnouncementRotator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.items, widget.items)) {
      _switchTimer?.cancel();
      _switchTimer = null;
      _index = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _isVisible(state);
    if (_appVisible == visible) return;
    _appVisible = visible;
    if (visible) {
      _scheduleNext();
    } else {
      _switchTimer?.cancel();
      _switchTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _switchTimer?.cancel();
    super.dispose();
  }

  static bool _isVisible(AppLifecycleState? state) {
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  void _scheduleNext() {
    if (!_appVisible || widget.items.length <= 1 || _switchTimer != null) {
      return;
    }
    _switchTimer = Timer(_switchInterval, () {
      _switchTimer = null;
      if (!mounted || !_appVisible || widget.items.length <= 1) return;
      setState(() => _index = (_index + 1) % widget.items.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_index >= widget.items.length) _index = 0;
    _scheduleNext();
    final text = widget.items.isEmpty ? '' : widget.items[_index];
    final textChild = SizedBox(
      key: ValueKey<int>(_index),
      width: double.infinity,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: widget.style,
      ),
    );
    return RepaintBoundary(
      key: const ValueKey('low-motion-announcement'),
      child: Semantics(
        label: text,
        excludeSemantics: true,
        child: widget.fadeTransitions
            ? AnimatedSwitcher(
                key: const ValueKey('low-motion-fade-switcher'),
                duration: _fadeDuration,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                child: textChild,
              )
            : textChild,
      ),
    );
  }
}

class _TickerTag extends StatelessWidget {
  const _TickerTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 35,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x1af2b84b),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x2ef2b84b)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: KiraColors.amber,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TopSearchEntry extends StatelessWidget {
  const _TopSearchEntry({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          backgroundColor: KiraColors.surface2,
          foregroundColor: KiraColors.muted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: KiraColors.line),
          ),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.search,
              size: 30,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '搜索歌名、歌手、编号',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
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

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 65,
      height: 60,
      child: IconButton.filled(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, size: 30),
        style: IconButton.styleFrom(
          backgroundColor: KiraColors.surface2,
          foregroundColor: KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: KiraColors.line),
          ),
        ),
      ),
    );
  }
}

class _TopTextButton extends StatelessWidget {
  const _TopTextButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.width = 98,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final double width;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 60,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor:
              active ? const Color(0x1fdd3e38) : KiraColors.surface2,
          foregroundColor: active ? const Color(0xffff827d) : KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: active ? const Color(0x6bdd3e38) : KiraColors.line,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 30),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
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
