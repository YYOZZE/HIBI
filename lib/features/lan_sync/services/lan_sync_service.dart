import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../assistant/services/assistant_repository.dart';
import '../../auth/services/account_storage_paths.dart';
import '../../auth/services/auth_repository.dart';
import '../../auth/services/sync_merge.dart';
import '../../auth/services/user_sync_scheduler.dart';
import '../../mind/services/mind_repository.dart';
import '../../schedule/schedule_event_store.dart';
import 'app_clock_offset.dart';
import 'lan_sync_discovery.dart';
import 'lan_sync_password.dart';

enum LanSyncInboundKind { request, none }

/// 对端发来的同步申请（等待本机同意）。
class LanSyncInboundRequest {
  LanSyncInboundRequest({
    required this.requestId,
    required this.fromDeviceId,
    required this.fromDeviceName,
    required this.fromAccountHint,
    required this.fromAccountId,
    required this.pinRequired,
    required this.peerIp,
    required this.createdAt,
  });

  final String requestId;
  final String fromDeviceId;
  final String fromDeviceName;
  final String fromAccountHint;
  final String fromAccountId;
  final bool pinRequired;
  final String peerIp;
  final DateTime createdAt;
}

class LanSyncResult {
  const LanSyncResult({
    required this.ok,
    this.message = '',
    this.mindCount = 0,
    this.scheduleCount = 0,
    this.agentCount = 0,
    this.clockOffsetMs = 0,
  });

  final bool ok;
  final String message;
  final int mindCount;
  final int scheduleCount;
  final int agentCount;
  final int clockOffsetMs;
}

/// 局域网数据同步：UDP 发现 + 本地 HTTP + 连接密码配对 + 账号一致性校验 + LWW 合并。
class LanSyncService {
  LanSyncService._();
  static final LanSyncService instance = LanSyncService._();

  static const int preferredHttpPort = 18765;

  final ValueNotifier<List<LanSyncPeer>> peersNotifier =
      ValueNotifier<List<LanSyncPeer>>(const []);
  final ValueNotifier<LanSyncInboundRequest?> inboundNotifier =
      ValueNotifier<LanSyncInboundRequest?>(null);
  final ValueNotifier<String?> statusNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<String> passwordNotifier = ValueNotifier<String>('');

  LanSyncDiscovery? _discovery;
  HttpServer? _server;
  String? _deviceId;
  String _deviceName = '希比设备';
  String _accountHint = '';
  String _accountId = '';
  String _connectionPassword = '';
  int _httpPort = preferredHttpPort;
  bool _running = false;

  /// requestId → 期望连接密码（发起方本地保存，对端回传后校验）
  final Map<String, String?> _pendingPins = {};
  /// requestId → Completer（发起方等待对端响应）
  final Map<String, Completer<Map<String, dynamic>>> _awaitingAccept = {};
  /// 已授权 session
  final Map<String, _LanSession> _sessions = {};
  final Map<String, int> _callbackPorts = {};

  bool get isRunning => _running;
  int get httpPort => _httpPort;
  String get deviceId => _deviceId ?? '';
  String get accountId => _accountId;
  String get connectionPassword => _connectionPassword;

  /// 稳定账号键：GitHub → login（小写）；本地账号 → 稳定 local id。
  /// 握手字段 `accountId` 用此值比对「账号一致才连接」。
  static String? resolveAccountId() {
    final user = AuthRepository.instance.currentUser;
    if (user == null) return null;
    if (user.isGitHub) {
      final login = user.githubLogin?.trim();
      if (login != null && login.isNotEmpty) return login.toLowerCase();
    }
    if (user.isLocal) {
      final id = user.userId.trim();
      if (id.isNotEmpty) return id.toLowerCase();
    }
    final login = user.githubLogin?.trim();
    if (login != null && login.isNotEmpty) return login.toLowerCase();
    final id = user.userId.trim();
    if (id.isNotEmpty) return id.toLowerCase();
    return null;
  }

  static bool accountsMatch(String? a, String? b) {
    final left = (a ?? '').trim().toLowerCase();
    final right = (b ?? '').trim().toLowerCase();
    if (left.isEmpty || right.isEmpty) return false;
    return left == right;
  }

  Future<void> start() async {
    if (_running) return;
    final accountId = resolveAccountId();
    if (accountId == null) {
      throw StateError('请先登录');
    }
    _deviceId ??= _newId('dev');
    _deviceName = await _resolveDeviceName();
    _accountId = accountId;
    _accountHint = _resolveAccountHint();
    _connectionPassword = await LanSyncPasswordStore.getOrCreate();
    passwordNotifier.value = _connectionPassword;
    await AppClockOffset.instance.ensureLoaded();

    _httpPort = await _bindHttpServer();
    _discovery = LanSyncDiscovery(
      deviceId: _deviceId!,
      deviceName: _deviceName,
      accountHint: _accountHint,
      accountId: _accountId,
      httpPort: _httpPort,
    );
    _discovery!.peers.listen((list) {
      peersNotifier.value = list;
    });
    _discovery!.errors.listen((e) {
      statusNotifier.value = '发现服务异常：$e';
    });
    await _discovery!.start();
    _running = true;
    statusNotifier.value = '已在局域网广播，端口 $_httpPort';
  }

  Future<void> stop() async {
    _running = false;
    await _discovery?.dispose();
    _discovery = null;
    await _server?.close(force: true);
    _server = null;
    peersNotifier.value = const [];
    inboundNotifier.value = null;
    _pendingPins.clear();
    for (final c in _awaitingAccept.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('同步服务已停止'));
      }
    }
    _awaitingAccept.clear();
    _sessions.clear();
    _callbackPorts.clear();
    statusNotifier.value = null;
  }

  Future<String> refreshPasswordDisplay() async {
    _connectionPassword = await LanSyncPasswordStore.getOrCreate();
    passwordNotifier.value = _connectionPassword;
    return _connectionPassword;
  }

  Future<void> setConnectionPassword(String password) async {
    await LanSyncPasswordStore.set(password);
    _connectionPassword = password.trim();
    passwordNotifier.value = _connectionPassword;
  }

  Future<String> resetConnectionPassword() async {
    _connectionPassword = await LanSyncPasswordStore.reset();
    passwordNotifier.value = _connectionPassword;
    return _connectionPassword;
  }

  /// 向对端发起同步申请；使用本机连接密码，对端需输入相同密码。
  Future<LanSyncResult> requestSyncWith(LanSyncPeer peer) async {
    if (!_running) {
      return const LanSyncResult(ok: false, message: '请先开启局域网同步');
    }
    if (_accountId.isEmpty) {
      return const LanSyncResult(ok: false, message: '请先登录');
    }
    if (!accountsMatch(_accountId, peer.accountId)) {
      return const LanSyncResult(ok: false, message: '账号不一致');
    }

    final password = await LanSyncPasswordStore.getOrCreate();
    _connectionPassword = password;
    passwordNotifier.value = password;

    final requestId = _newId('req');
    final completer = Completer<Map<String, dynamic>>();
    _awaitingAccept[requestId] = completer;
    _pendingPins[requestId] = password;

    statusNotifier.value = '正在向 ${peer.displayLabel} 发起同步申请…';
    try {
      final res = await http
          .post(
            Uri.parse('http://${peer.ip}:${peer.httpPort}/lan-sync/request'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'requestId': requestId,
              'fromDeviceId': _deviceId,
              'fromDeviceName': _deviceName,
              'fromAccountHint': _accountHint,
              'fromAccountId': _accountId,
              'pinRequired': true,
              'callbackIp': await _guessLocalIp(),
              'callbackPort': _httpPort,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 403) {
        _awaitingAccept.remove(requestId);
        _pendingPins.remove(requestId);
        return const LanSyncResult(ok: false, message: '账号不一致');
      }
      if (res.statusCode != 200) {
        throw StateError('对端拒绝接收申请（HTTP ${res.statusCode}）');
      }
      try {
        final data = jsonDecode(res.body);
        if (data is Map && data['ok'] == false) {
          final err = data['error']?.toString() ?? '';
          if (err == 'account_mismatch') {
            _awaitingAccept.remove(requestId);
            _pendingPins.remove(requestId);
            return const LanSyncResult(ok: false, message: '账号不一致');
          }
        }
      } catch (_) {}
    } catch (e) {
      _awaitingAccept.remove(requestId);
      _pendingPins.remove(requestId);
      return LanSyncResult(ok: false, message: '无法联系对端：$e');
    }

    Map<String, dynamic> accept;
    try {
      accept = await completer.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      _awaitingAccept.remove(requestId);
      _pendingPins.remove(requestId);
      return const LanSyncResult(ok: false, message: '等待对端同意超时');
    } catch (e) {
      _awaitingAccept.remove(requestId);
      _pendingPins.remove(requestId);
      return LanSyncResult(ok: false, message: '$e');
    } finally {
      _awaitingAccept.remove(requestId);
      _pendingPins.remove(requestId);
    }

    if (accept['accepted'] != true) {
      final reason = accept['reason']?.toString() ?? '对端已拒绝';
      if (reason.contains('密码') || reason == 'bad pin') {
        return const LanSyncResult(ok: false, message: '密码错误');
      }
      if (reason.contains('账号')) {
        return const LanSyncResult(ok: false, message: '账号不一致');
      }
      return LanSyncResult(ok: false, message: reason);
    }
    final sessionToken = accept['sessionToken']?.toString() ?? '';
    if (sessionToken.isEmpty) {
      return const LanSyncResult(ok: false, message: '对端未返回会话令牌');
    }

    return _runExchange(
      peerIp: peer.ip,
      peerPort: peer.httpPort,
      sessionToken: sessionToken,
    );
  }

  Future<void> rejectInbound({String reason = '对端已拒绝'}) async {
    final inbound = inboundNotifier.value;
    if (inbound == null) return;
    try {
      await http
          .post(
            Uri.parse(
              'http://${inbound.peerIp}:${_findCallbackPort(inbound)}/lan-sync/accept',
            ),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'requestId': inbound.requestId,
              'accepted': false,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    inboundNotifier.value = null;
    _pendingPins.remove(inbound.requestId);
    statusNotifier.value = '已拒绝同步申请';
  }

  int _findCallbackPort(LanSyncInboundRequest inbound) {
    return _callbackPorts[inbound.requestId] ?? preferredHttpPort;
  }

  Future<int> _bindHttpServer() async {
    final ports = [preferredHttpPort, 18766, 18767, 0];
    Object? lastError;
    for (final p in ports) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _server = server;
        server.listen(_handleHttp, onError: (e) {
          debugPrint('lan-sync http error: $e');
        });
        return server.port;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('无法启动局域网同步 HTTP 服务：$lastError');
  }

  Future<void> _handleHttp(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/lan-sync/time') {
        await _writeJson(request, {
          'ok': true,
          'epochMs': DateTime.now().millisecondsSinceEpoch,
          'beijingIso': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 8))
              .toIso8601String(),
        });
        return;
      }
      if (request.method == 'POST' && path == '/lan-sync/request') {
        final body = await _readJson(request);
        final requestId = body['requestId']?.toString() ?? '';
        final fromId = body['fromDeviceId']?.toString() ?? '';
        if (requestId.isEmpty || fromId.isEmpty) {
          await _writeJson(request, {'ok': false}, status: 400);
          return;
        }
        if (_accountId.isEmpty) {
          await _writeJson(
            request,
            {'ok': false, 'error': 'not_logged_in'},
            status: 403,
          );
          return;
        }
        final fromAccountId = body['fromAccountId']?.toString() ?? '';
        if (!accountsMatch(_accountId, fromAccountId)) {
          await _writeJson(
            request,
            {'ok': false, 'error': 'account_mismatch'},
            status: 403,
          );
          return;
        }
        final pinRequired = body['pinRequired'] != false;
        final callbackPort = (body['callbackPort'] is num)
            ? (body['callbackPort'] as num).toInt()
            : int.tryParse('${body['callbackPort']}') ?? preferredHttpPort;
        _callbackPorts[requestId] = callbackPort;
        inboundNotifier.value = LanSyncInboundRequest(
          requestId: requestId,
          fromDeviceId: fromId,
          fromDeviceName: body['fromDeviceName']?.toString() ?? '希比设备',
          fromAccountHint: body['fromAccountHint']?.toString() ?? '',
          fromAccountId: fromAccountId,
          pinRequired: pinRequired,
          peerIp: request.connectionInfo?.remoteAddress.address ??
              body['callbackIp']?.toString() ??
              '',
          createdAt: DateTime.now(),
        );
        if (pinRequired) {
          _pendingPins[requestId] = '__peer_will_send__';
        }
        await _writeJson(request, {'ok': true});
        return;
      }
      if (request.method == 'POST' && path == '/lan-sync/accept') {
        final body = await _readJson(request);
        final requestId = body['requestId']?.toString() ?? '';
        final completer = _awaitingAccept[requestId];
        if (completer == null) {
          await _writeJson(request, {'ok': false, 'error': 'unknown request'});
          return;
        }
        final accepted = body['accepted'] == true;
        if (accepted) {
          final peerAccountId = body['fromAccountId']?.toString() ?? '';
          if (peerAccountId.isNotEmpty &&
              !accountsMatch(_accountId, peerAccountId)) {
            completer.complete({
              'accepted': false,
              'reason': '账号不一致',
            });
            await _writeJson(
              request,
              {'ok': false, 'error': 'account_mismatch'},
            );
            return;
          }
          final expected = _pendingPins[requestId];
          if (expected != null && expected != '__peer_will_send__') {
            final got = body['pin']?.toString() ?? '';
            if (got != expected) {
              completer.complete({
                'accepted': false,
                'reason': '密码错误',
              });
              await _writeJson(request, {'ok': false, 'error': 'bad pin'});
              return;
            }
          }
        }
        if (!completer.isCompleted) completer.complete(body);
        await _writeJson(request, {'ok': true});
        return;
      }
      if (request.method == 'POST' && path == '/lan-sync/exchange') {
        final body = await _readJson(request);
        final token = body['sessionToken']?.toString() ?? '';
        final session = _sessions[token];
        if (session == null) {
          await _writeJson(request, {'ok': false, 'error': 'invalid session'},
              status: 401);
          return;
        }
        final remoteBundle = body['bundle'];
        if (remoteBundle is! Map) {
          await _writeJson(request, {'ok': false, 'error': 'bad bundle'},
              status: 400);
          return;
        }
        final localBundle = await _readLocalBundle();
        final merged =
            _mergeBundles(localBundle, Map<String, dynamic>.from(remoteBundle));
        await _writeLocalBundle(merged);
        await _reloadRepos();
        await _writeJson(request, {
          'ok': true,
          'bundle': merged,
          'epochMs': DateTime.now().millisecondsSinceEpoch,
        });
        return;
      }
      await _writeJson(request, {'ok': false, 'error': 'not found'}, status: 404);
    } catch (e) {
      try {
        await _writeJson(request, {'ok': false, 'error': '$e'}, status: 500);
      } catch (_) {}
    }
  }

  Future<LanSyncResult> _runExchange({
    required String peerIp,
    required int peerPort,
    required String sessionToken,
  }) async {
    statusNotifier.value = '正在校准时间…';
    var clockOffset = 0;
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final timeRes = await http
          .get(Uri.parse('http://$peerIp:$peerPort/lan-sync/time'))
          .timeout(const Duration(seconds: 5));
      final t1 = DateTime.now().millisecondsSinceEpoch;
      if (timeRes.statusCode == 200) {
        final data = jsonDecode(timeRes.body) as Map<String, dynamic>;
        final peerEpoch = (data['epochMs'] as num?)?.toInt() ?? 0;
        if (peerEpoch > 0) {
          clockOffset = await AppClockOffset.instance
              .calibrateWithPeerEpoch(peerEpoch, rttMs: t1 - t0);
        }
      }
    } catch (e) {
      debugPrint('lan-sync time calibrate failed: $e');
    }

    statusNotifier.value = '正在交换数据…';
    _sessions[sessionToken] = _LanSession(
      peerDeviceId: 'peer',
      createdAt: DateTime.now(),
    );

    final localBundle = await _readLocalBundle();
    try {
      final res = await http
          .post(
            Uri.parse('http://$peerIp:$peerPort/lan-sync/exchange'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sessionToken': sessionToken,
              'bundle': localBundle,
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        return LanSyncResult(
          ok: false,
          message: '数据交换失败（HTTP ${res.statusCode}）',
          clockOffsetMs: clockOffset,
        );
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true) {
        return LanSyncResult(
          ok: false,
          message: data['error']?.toString() ?? '交换失败',
          clockOffsetMs: clockOffset,
        );
      }
      final remoteMerged = data['bundle'];
      if (remoteMerged is Map) {
        final merged = _mergeBundles(
          localBundle,
          Map<String, dynamic>.from(remoteMerged),
        );
        await _writeLocalBundle(merged);
        await _reloadRepos();
        final mind = (merged['mind'] as List?)?.length ?? 0;
        final schedule = (merged['schedule'] as List?)?.length ?? 0;
        final agents =
            ((merged['assistant'] as Map?)?['agents'] as List?)?.length ?? 0;
        statusNotifier.value = '同步完成';
        return LanSyncResult(
          ok: true,
          message: '同步完成',
          mindCount: mind,
          scheduleCount: schedule,
          agentCount: agents,
          clockOffsetMs: clockOffset,
        );
      }
      return LanSyncResult(
        ok: false,
        message: '对端返回数据无效',
        clockOffsetMs: clockOffset,
      );
    } catch (e) {
      return LanSyncResult(
        ok: false,
        message: '数据交换失败：$e',
        clockOffsetMs: clockOffset,
      );
    }
  }

  /// 同意时把用户输入的连接密码带回给发起方校验。
  Future<LanSyncResult> acceptInboundWithPin(String pin) async {
    final inbound = inboundNotifier.value;
    if (inbound == null) {
      return const LanSyncResult(ok: false, message: '没有待处理的同步申请');
    }
    if (!accountsMatch(_accountId, inbound.fromAccountId)) {
      await rejectInbound(reason: '账号不一致');
      return const LanSyncResult(ok: false, message: '账号不一致');
    }
    if (inbound.pinRequired && pin.trim().isEmpty) {
      return const LanSyncResult(ok: false, message: '密码错误');
    }
    final sessionToken = _newId('sess');
    _sessions[sessionToken] = _LanSession(
      peerDeviceId: inbound.fromDeviceId,
      createdAt: DateTime.now(),
    );
    try {
      final res = await http
          .post(
            Uri.parse(
              'http://${inbound.peerIp}:${_findCallbackPort(inbound)}/lan-sync/accept',
            ),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'requestId': inbound.requestId,
              'accepted': true,
              'sessionToken': sessionToken,
              'fromDeviceId': _deviceId,
              'fromAccountId': _accountId,
              'pin': pin.trim(),
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        _sessions.remove(sessionToken);
        return LanSyncResult(
          ok: false,
          message: '通知发起方失败（HTTP ${res.statusCode}）',
        );
      }
      final data = jsonDecode(res.body);
      if (data is Map && data['ok'] == false) {
        _sessions.remove(sessionToken);
        final err = data['error']?.toString() ?? '';
        if (err == 'bad pin') {
          return const LanSyncResult(ok: false, message: '密码错误');
        }
        if (err == 'account_mismatch') {
          return const LanSyncResult(ok: false, message: '账号不一致');
        }
        return const LanSyncResult(ok: false, message: '发起方拒绝');
      }
    } catch (e) {
      _sessions.remove(sessionToken);
      return LanSyncResult(ok: false, message: '无法通知发起方：$e');
    }
    inboundNotifier.value = null;
    _pendingPins.remove(inbound.requestId);
    statusNotifier.value = '已同意，正在等待数据交换…';
    return const LanSyncResult(ok: true, message: '已同意同步申请');
  }

  Future<Map<String, dynamic>> _readLocalBundle() async {
    final bundle = <String, dynamic>{
      'mind': <dynamic>[],
      'schedule': <dynamic>[],
      'assistant': <String, dynamic>{
        'agents': <dynamic>[],
        'messages': <String, dynamic>{},
      },
    };
    try {
      final mindFile = await AccountStoragePaths.mindNodesFile();
      if (await mindFile.exists()) {
        final raw = jsonDecode(await mindFile.readAsString());
        if (raw is List) bundle['mind'] = raw;
      }
    } catch (_) {}
    try {
      final scheduleFile = await AccountStoragePaths.scheduleEventsFile();
      if (await scheduleFile.exists()) {
        final raw = jsonDecode(await scheduleFile.readAsString());
        if (raw is List) bundle['schedule'] = raw;
      }
    } catch (_) {}
    try {
      final assistantDir = await AccountStoragePaths.assistantDir();
      final agentsFile = File('${assistantDir.path}/assistant_agents.json');
      List<dynamic> agents = [];
      final messages = <String, dynamic>{};
      if (await agentsFile.exists()) {
        final raw = jsonDecode(await agentsFile.readAsString());
        if (raw is List) agents = raw;
      }
      await for (final ent in assistantDir.list()) {
        if (ent is File &&
            ent.path.contains('messages_') &&
            ent.path.endsWith('.json')) {
          final name = ent.uri.pathSegments.last
              .replaceFirst('messages_', '')
              .replaceFirst('.json', '');
          try {
            messages[name] = jsonDecode(await ent.readAsString());
          } catch (_) {}
        }
      }
      bundle['assistant'] = {'agents': agents, 'messages': messages};
    } catch (_) {}
    return bundle;
  }

  Map<String, dynamic> _mergeBundles(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final mind = SyncMerge.mergeMindLists(
      local['mind'] as List<dynamic>?,
      remote['mind'] as List<dynamic>?,
    );
    final schedule = SyncMerge.mergeScheduleListsByMtime(
      local['schedule'] as List<dynamic>?,
      remote['schedule'] as List<dynamic>?,
    );
    final assistant = SyncMerge.mergeAssistant(
      local['assistant'] is Map
          ? Map<String, dynamic>.from(local['assistant'] as Map)
          : null,
      remote['assistant'] is Map
          ? Map<String, dynamic>.from(remote['assistant'] as Map)
          : null,
    );
    return {
      'mind': mind,
      'schedule': schedule,
      'assistant': assistant,
    };
  }

  Future<void> _writeLocalBundle(Map<String, dynamic> bundle) async {
    final mindFile = await AccountStoragePaths.mindNodesFile();
    await mindFile.writeAsString(jsonEncode(bundle['mind'] ?? []));
    final scheduleFile = await AccountStoragePaths.scheduleEventsFile();
    await scheduleFile.writeAsString(jsonEncode(bundle['schedule'] ?? []));
    final assistantDir = await AccountStoragePaths.assistantDir();
    final assistant = bundle['assistant'];
    if (assistant is Map) {
      final agents = assistant['agents'] ?? [];
      await File('${assistantDir.path}/assistant_agents.json')
          .writeAsString(jsonEncode(agents));
      final messages = assistant['messages'];
      if (messages is Map) {
        for (final e in messages.entries) {
          final key = e.key.toString();
          await File('${assistantDir.path}/messages_$key.json')
              .writeAsString(jsonEncode(e.value));
        }
      }
    }
  }

  Future<void> _reloadRepos() async {
    try {
      await MindRepository.instance.reloadFromDisk();
    } catch (_) {}
    try {
      await ScheduleEventStore.instance.reloadFromDisk();
    } catch (_) {}
    try {
      await AssistantRepository.instance.reloadFromDisk();
    } catch (_) {}
    UserSyncScheduler.syncEpoch.value++;
  }

  Future<String> _resolveDeviceName() async {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.isAndroid
          ? '希比 Android'
          : (Platform.isWindows ? '希比 Windows' : '希比设备');
    }
  }

  String _resolveAccountHint() {
    final user = AuthRepository.instance.currentUser;
    if (user == null) return '';
    if (user.isGitHub) {
      final login = user.githubLogin?.trim();
      if (login != null && login.isNotEmpty) return '@$login';
    }
    if (user.isLocal) {
      final id = user.userId.trim();
      if (id.length <= 12) return id;
      return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
    }
    final login = user.githubLogin?.trim();
    if (login != null && login.isNotEmpty) return '@$login';
    final name = user.displayName.trim();
    if (name.isNotEmpty) return name;
    final id = user.userId.trim();
    if (id.length <= 8) return id;
    return '${id.substring(0, 4)}…${id.substring(id.length - 4)}';
  }

  Future<String> _guessLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  String _newId(String prefix) {
    final r = Random.secure();
    final n = List.generate(10, (_) => r.nextInt(36))
        .map((e) => e.toRadixString(36))
        .join();
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$n';
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) return {};
    final data = jsonDecode(raw);
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return {};
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, dynamic> body, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _LanSession {
  _LanSession({required this.peerDeviceId, required this.createdAt});
  final String peerDeviceId;
  final DateTime createdAt;
}
