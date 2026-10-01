import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum StagePresentationBackend { externalTexture, composed }

@immutable
class StagePresentationAttachment {
  const StagePresentationAttachment.externalTexture(this.textureId)
      : backend = StagePresentationBackend.externalTexture;

  const StagePresentationAttachment.composed()
      : backend = StagePresentationBackend.composed,
        textureId = null;

  final StagePresentationBackend backend;
  final int? textureId;

  bool get isComposed => backend == StagePresentationBackend.composed;
}

class StageTextureController {
  StageTextureController({
    MethodChannel textureChannel =
        const MethodChannel('kirakara/stage_texture'),
    MethodChannel compositorChannel =
        const MethodChannel('kirakara/dcomp_compositor'),
  })  : _textureChannel = textureChannel,
        _compositorChannel = compositorChannel;

  final MethodChannel _textureChannel;
  final MethodChannel _compositorChannel;
  int? _hostHandle;
  StagePresentationAttachment? _attachment;
  Future<StagePresentationAttachment?>? _pendingAttach;
  Map<String, Object?>? _lastGeometry;

  StagePresentationAttachment? get attachment => _attachment;
  int? get textureId => _attachment?.textureId;
  bool get isComposed => _attachment?.isComposed ?? false;

  Future<StagePresentationAttachment?> attach(int hostHandle) {
    if (hostHandle == 0) {
      return Future<StagePresentationAttachment?>.value(null);
    }
    if (_hostHandle == hostHandle && _attachment != null) {
      return Future<StagePresentationAttachment?>.value(_attachment);
    }
    final pending = _pendingAttach;
    if (_hostHandle == hostHandle && pending != null) return pending;

    final previousHostHandle = _hostHandle;
    final previousAttachment = _attachment;
    _hostHandle = hostHandle;
    final future = _attach(hostHandle).then(
      (attachment) {
        if (attachment == null && _hostHandle == hostHandle) {
          _hostHandle = previousHostHandle;
          _attachment = previousAttachment;
        }
        return attachment;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_hostHandle == hostHandle) {
          _hostHandle = previousHostHandle;
          _attachment = previousAttachment;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _pendingAttach = future;
    return future;
  }

  Future<StagePresentationAttachment?> _attach(int hostHandle) async {
    try {
      try {
        final backend = await _compositorChannel
            .invokeMapMethod<String, Object?>('getBackendInfo');
        if (backend?['backend'] == 'composed') {
          final attached =
              await _compositorChannel.invokeMapMethod<String, Object?>(
            'attachStage',
            <String, Object?>{'hostHandle': hostHandle},
          );
          if (attached?['backend'] != 'composed') {
            throw PlatformException(
              code: 'dcomp_stage_attach_invalid_response',
              message: 'Composed Stage attach returned incompatible metadata.',
            );
          }
          const attachment = StagePresentationAttachment.composed();
          if (_hostHandle == hostHandle) _attachment = attachment;
          return attachment;
        }
      } on MissingPluginException {
        // A stock or external-texture Runner intentionally has no compositor
        // channel. Continue through the preserved external texture backend.
      } on PlatformException catch (error) {
        // An explicitly selected composed backend must fail visibly. Falling
        // through here would hide ABI, synchronization, or implementation bugs.
        debugPrint('Composed Stage unavailable: ${error.message}');
        return null;
      }

      try {
        final textureId = await _textureChannel.invokeMethod<int>(
          'attach',
          <String, Object?>{'hostHandle': hostHandle},
        );
        if (textureId == null) return null;
        final attachment =
            StagePresentationAttachment.externalTexture(textureId);
        if (_hostHandle == hostHandle) _attachment = attachment;
        return attachment;
      } on MissingPluginException catch (error) {
        debugPrint('Unified Stage texture bridge is unavailable: $error');
        return null;
      } on PlatformException catch (error) {
        debugPrint('Unified Stage texture unavailable: ${error.message}');
        return null;
      }
    } finally {
      if (_hostHandle == hostHandle) _pendingAttach = null;
    }
  }

  Future<void> setActive(bool active) async {
    final attachment = _attachment;
    if (attachment == null) return;
    try {
      if (attachment.isComposed) {
        await _compositorChannel.invokeMethod<void>(
          'setStageActive',
          <String, Object?>{'active': active},
        );
      } else {
        await _textureChannel.invokeMethod<void>(
          'setActive',
          <String, Object?>{'active': active},
        );
      }
    } on MissingPluginException catch (error) {
      debugPrint('Unified Stage texture bridge is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('Unable to update Stage texture activity: ${error.message}');
    }
  }

  Future<void> setComposedGeometry({
    required Rect physicalBounds,
    bool visible = true,
    String fit = 'contain',
  }) async {
    if (!isComposed) return;
    final geometry = <String, Object?>{
      'visible': visible,
      'x': physicalBounds.left,
      'y': physicalBounds.top,
      'width': physicalBounds.width,
      'height': physicalBounds.height,
      'fit': fit,
    };
    if (mapEquals(_lastGeometry, geometry)) return;
    try {
      await _compositorChannel.invokeMethod<void>(
        'setStageGeometry',
        geometry,
      );
      if (isComposed) _lastGeometry = geometry;
    } on MissingPluginException catch (error) {
      debugPrint('Composed Stage geometry bridge is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('Unable to update composed Stage geometry: ${error.message}');
    }
  }

  Future<void> detach() async {
    final attachment = _attachment;
    _attachment = null;
    _lastGeometry = null;
    if (attachment == null) return;
    try {
      if (attachment.isComposed) {
        await _compositorChannel.invokeMethod<void>('detachStage');
      } else {
        await _textureChannel.invokeMethod<void>('detach');
      }
    } on MissingPluginException catch (error) {
      debugPrint('Stage detach bridge is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('Unable to detach Stage: ${error.message}');
    }
  }
}
