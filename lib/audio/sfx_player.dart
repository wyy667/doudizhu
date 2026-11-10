import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';

/// 音效类型。
enum Sfx { select, play, pass, bomb, rocket, win, lose, bid }

/// 音效服务：用程序生成的 WAV 音色播放，无需外部音频文件。
///
/// 同时提供触觉反馈（HapticFeedback）作为辅助。
class SfxPlayer {
  final AudioPlayer _player = AudioPlayer();
  final Map<Sfx, Uint8List> _cache = {};
  bool _enabled = true;
  bool _vibrationEnabled = true;

  SfxPlayer();

  void setEnabled(bool v) => _enabled = v;
  void setVibrationEnabled(bool v) => _vibrationEnabled = v;

  Future<void> play(Sfx type) async {
    if (!_enabled) return;
    final wav = _cache[type] ??= _generate(type);
    try {
      await _player.play(BytesSource(wav));
    } catch (_) {}
    _haptic(type);
  }

  /// 仅触觉反馈（出牌改为 TTS 报牌后仍保留震动）。
  void haptic(Sfx type) => _haptic(type);

  void _haptic(Sfx type) {
    if (!_vibrationEnabled) return;
    switch (type) {
      case Sfx.bomb:
      case Sfx.rocket:
        HapticFeedback.heavyImpact();
      case Sfx.win:
      case Sfx.lose:
        HapticFeedback.mediumImpact();
      case Sfx.select:
        HapticFeedback.selectionClick();
      default:
        HapticFeedback.lightImpact();
    }
  }

  /// 生成 16-bit PCM mono WAV 字节。
  static Uint8List _generate(Sfx type) {
    const sampleRate = 44100;
    final samples = <int>[];

    void addTone(double freq, int ms, {double vol = 0.3}) {
      final n = (sampleRate * ms / 1000).round();
      for (var i = 0; i < n; i++) {
        final t = i / sampleRate;
        final env = _envelope(i, n);
        final v = sin(2 * pi * freq * t) * env * vol;
        samples.add((v * 32767).clamp(-32768, 32767).toInt());
      }
    }

    void addSweep(double f0, double f1, int ms, {double vol = 0.3}) {
      final n = (sampleRate * ms / 1000).round();
      for (var i = 0; i < n; i++) {
        final progress = i / n;
        final freq = f0 + (f1 - f0) * progress;
        final t = i / sampleRate;
        final env = _envelope(i, n);
        final v = sin(2 * pi * freq * t) * env * vol;
        samples.add((v * 32767).clamp(-32768, 32767).toInt());
      }
    }

    switch (type) {
      case Sfx.select:
        addTone(1200, 40, vol: 0.15);
      case Sfx.play:
        addTone(800, 80, vol: 0.25);
      case Sfx.pass:
        addTone(350, 100, vol: 0.2);
      case Sfx.bid:
        addTone(600, 60, vol: 0.2);
        samples.addAll(List.filled(2000 ~/ (sampleRate / 1000), 0));
        addTone(900, 60, vol: 0.2);
      case Sfx.bomb:
        addSweep(150, 60, 250, vol: 0.4);
      case Sfx.rocket:
        addSweep(800, 200, 200, vol: 0.35);
        samples.addAll(List.filled(3000 ~/ (sampleRate / 1000), 0));
        addSweep(400, 80, 150, vol: 0.3);
      case Sfx.win:
        addTone(523, 100, vol: 0.25); // C5
        addTone(659, 100, vol: 0.25); // E5
        addTone(784, 200, vol: 0.25); // G5
      case Sfx.lose:
        addTone(392, 150, vol: 0.2); // G4
        addTone(330, 150, vol: 0.2); // E4
        addTone(262, 250, vol: 0.2); // C4
    }

    return _buildWav(samples, sampleRate);
  }

  static double _envelope(int i, int n) {
    const fadeLen = 0.1; // 10% fade in/out
    final p = i / n;
    if (p < fadeLen) return p / fadeLen;
    if (p > 1 - fadeLen) return (1 - p) / fadeLen;
    return 1.0;
  }

  static Uint8List _buildWav(List<int> samples, int sampleRate) {
    final dataSize = samples.length * 2;
    final buf = BytesBuilder();
    buf.add('RIFF'.codeUnits);
    _addU32(buf, 36 + dataSize);
    buf.add('WAVE'.codeUnits);
    buf.add('fmt '.codeUnits);
    _addU32(buf, 16);
    _addU16(buf, 1); // PCM
    _addU16(buf, 1); // mono
    _addU32(buf, sampleRate);
    _addU32(buf, sampleRate * 2); // byte rate
    _addU16(buf, 2); // block align
    _addU16(buf, 16); // bits per sample
    buf.add('data'.codeUnits);
    _addU32(buf, dataSize);
    final data = ByteData(dataSize);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    buf.add(data.buffer.asUint8List());
    return buf.toBytes();
  }

  static void _addU32(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  static void _addU16(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }
}

/// 音效 Provider（单例，绑定 soundEnabledProvider）。
final sfxPlayerProvider = Provider<SfxPlayer>((ref) {
  final player = SfxPlayer();
  player.setEnabled(ref.read(soundEnabledProvider));
  player.setVibrationEnabled(ref.read(vibrationEnabledProvider));
  ref.listen(soundEnabledProvider, (_, v) => player.setEnabled(v));
  ref.listen(vibrationEnabledProvider, (_, v) => player.setVibrationEnabled(v));
  return player;
});
