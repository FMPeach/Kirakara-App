part of '../../screens/controller_screen.dart';

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.playbackService,
    required this.queueService,
    required this.castService,
    required this.onQueue,
    required this.onAfterQueueChanged,
  });

  final PlaybackService playbackService;
  final QueueService queueService;
  final CastService castService;
  final VoidCallback onQueue;
  final VoidCallback onAfterQueueChanged;

  @override
  Widget build(BuildContext context) {
    final state = playbackService.state;
    return Container(
      height: 115,
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
      decoration: const BoxDecoration(
        color: Color(0xff15161a),
        border: Border(top: BorderSide(color: KiraColors.line)),
      ),
      child: Row(
        children: [
          KtvIconButton(
            icon: Icons.queue_music,
            label: '点歌列表',
            width: 195,
            onPressed: onQueue,
          ),
          const SizedBox(width: 18),
          Container(
            width: 400,
            height: 80,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: _surfaceDecoration(color: KiraColors.surface2),
            child: Row(
              children: [
                const SizedBox(
                  width: 72,
                  child: Text(
                    '音量',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SquareIconButton(
                  icon: Icons.remove,
                  size: 48,
                  onPressed: () => playbackService.changeVolumeBy(-6),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 12,
                      value: state.volume / 100,
                      color: KiraColors.amber,
                      backgroundColor: const Color(0xff34363d),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SquareIconButton(
                  icon: Icons.add,
                  size: 48,
                  onPressed: () => playbackService.changeVolumeBy(6),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          KtvIconButton(
            icon: state.audioTrackMode == AudioTrackMode.vocal
                ? Icons.graphic_eq
                : Icons.music_note,
            label: state.audioTrackMode == AudioTrackMode.vocal ? '原唱' : '伴奏',
            width: 195,
            foregroundColor: KiraColors.teal,
            onPressed: playbackService.toggleAudioTrack,
          ),
          const Spacer(),
          SizedBox(
            width: 638,
            child: Row(
              children: [
                Expanded(
                  child: KtvIconButton(
                    icon: Icons.replay,
                    label: '重唱',
                    onPressed: playbackService.replay,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: KtvIconButton(
                    icon: state.isPlaying ? Icons.pause : Icons.play_arrow,
                    label: state.isPlaying ? '暂停' : '播放',
                    active: true,
                    onPressed: playbackService.togglePlayPause,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: KtvIconButton(
                    icon: Icons.skip_next,
                    label: '切歌',
                    onPressed: () {
                      playbackService.next();
                      onAfterQueueChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
