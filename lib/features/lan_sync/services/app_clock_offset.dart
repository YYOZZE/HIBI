import 'package:shared_preferences/shared_preferences.dart';

/// 应用时间基准偏移（相对本机系统时钟的毫秒差）。
/// 局域网同步时与对端对齐北京时间后写入；[now] 供需要校准时间的场景使用。
class AppClockOffset {
  AppClockOffset._();
  static final AppClockOffset instance = AppClockOffset._();

  static const _prefsKey = 'hibi_app_clock_offset_ms';

  int _offsetMs = 0;
  bool _loaded = false;

  int get offsetMs => _offsetMs;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _offsetMs = prefs.getInt(_prefsKey) ?? 0;
    _loaded = true;
  }

  Future<void> setOffsetMs(int ms) async {
    _offsetMs = ms;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, ms);
  }

  /// 校准后的「现在」
  DateTime now() => DateTime.now().add(Duration(milliseconds: _offsetMs));

  /// 用对端声称的北京时间 epoch（毫秒）校准本机偏移。
  /// [peerEpochMs] 为对端 `DateTime.now().toUtc()` 毫秒；双方再共同对齐到 UTC+8 展示基准。
  Future<int> calibrateWithPeerEpoch(int peerEpochMs, {int rttMs = 0}) async {
    final localEpoch = DateTime.now().millisecondsSinceEpoch;
    final adjustedPeer = peerEpochMs + (rttMs ~/ 2);
    final delta = adjustedPeer - localEpoch;
    await setOffsetMs(delta);
    return delta;
  }
}
