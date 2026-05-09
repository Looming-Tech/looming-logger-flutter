import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Configuration options for the logger.
class LoggerConfig {
  /// Maximum number of logs to queue before oldest are dropped.
  final int maxQueueSize;

  /// Interval in seconds between automatic flushes.
  final int flushIntervalSeconds;

  /// HTTP timeout in seconds for sending logs.
  final int httpTimeoutSeconds;

  /// Whether to print logs to console in debug mode.
  final bool printToConsole;

  const LoggerConfig({
    this.maxQueueSize = 100,
    this.flushIntervalSeconds = 30,
    this.httpTimeoutSeconds = 10,
    this.printToConsole = true,
  });
}

/// Remote logging service for sending logs to a self-hosted Loki backend.
///
/// Features:
/// - Automatic device info collection (platform, OS version, model, etc.)
/// - Batched log sending with configurable flush interval
/// - Offline persistence using SharedPreferences
/// - Immediate flush for error-level logs
///
/// Usage:
/// ```dart
/// await LoomingLogger.init(
///   baseUrl: 'https://logs.example.com',
///   apiKey: 'your-api-key',
///   appId: 'your-app-id',
/// );
///
/// LoomingLogger.info('User logged in', {'userId': '123'});
/// LoomingLogger.error('Payment failed', {'orderId': '456'});
/// ```
class LoomingLogger {
  static LoomingLogger? _instance;
  static LoomingLogger get instance => _instance!;

  final String _baseUrl;
  final String _apiKey;
  final String _appId;
  final LoggerConfig _config;

  Map<String, dynamic>? _deviceInfo;
  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;
  bool _isInitialized = false;

  static const String _storageKey = 'looming_logger_queue';

  LoomingLogger._({
    required String baseUrl,
    required String apiKey,
    required String appId,
    required LoggerConfig config,
  })  : _baseUrl = baseUrl,
        _apiKey = apiKey,
        _appId = appId,
        _config = config;

  /// Initialize the logger. Call once at app startup.
  ///
  /// Parameters:
  /// - [baseUrl]: The base URL of your logging server (e.g., 'https://logs.example.com')
  /// - [apiKey]: API key for authentication
  /// - [appId]: Identifier for this app (e.g., 'my-app-ios', 'my-app-android')
  /// - [config]: Optional configuration options
  static Future<void> init({
    required String baseUrl,
    required String apiKey,
    required String appId,
    LoggerConfig config = const LoggerConfig(),
  }) async {
    _instance = LoomingLogger._(
      baseUrl: baseUrl,
      apiKey: apiKey,
      appId: appId,
      config: config,
    );
    await _instance!._initialize();
  }

  /// Check if the logger has been initialized.
  static bool get isInitialized => _instance?._isInitialized ?? false;

  Future<void> _initialize() async {
    _deviceInfo = await _collectDeviceInfo();
    await _loadQueueFromDisk();
    _startFlushTimer();
    _isInitialized = true;
  }

  /// Collect comprehensive device metadata.
  Future<Map<String, dynamic>> _collectDeviceInfo() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    final Map<String, dynamic> info = {
      'app_name': packageInfo.appName,
      'package_id': packageInfo.packageName,
      'app_version': packageInfo.version,
      'build_number': packageInfo.buildNumber,
    };

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      info.addAll({
        'device_id': android.id,
        'platform': 'android',
        'os_version': android.version.release,
        'sdk_int': android.version.sdkInt,
        'security_patch': android.version.securityPatch ?? '',
        'manufacturer': android.manufacturer,
        'model': android.model,
        'brand': android.brand,
        'device': android.device,
        'product': android.product,
        'hardware': android.hardware,
        'board': android.board,
        'display': android.display,
        'fingerprint': android.fingerprint,
        'is_physical_device': android.isPhysicalDevice,
        'supported_abis': android.supportedAbis,
      });
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      info.addAll({
        'device_id': ios.identifierForVendor ?? 'unknown',
        'platform': 'ios',
        'os_version': ios.systemVersion,
        'device_name': ios.name,
        'model': ios.model,
        'localized_model': ios.localizedModel,
        'machine': ios.utsname.machine,
        'system_name': ios.systemName,
        'is_physical_device': ios.isPhysicalDevice,
      });
    }

    return info;
  }

  // ============ Public Logging Methods ============

  /// Log a debug message.
  static void debug(String message, [Map<String, dynamic>? metadata]) {
    _instance?._log('debug', message, metadata);
  }

  /// Log an info message.
  static void info(String message, [Map<String, dynamic>? metadata]) {
    _instance?._log('info', message, metadata);
  }

  /// Log a warning message.
  static void warn(String message, [Map<String, dynamic>? metadata]) {
    _instance?._log('warn', message, metadata);
  }

  /// Log an error message.
  static void error(String message, [Map<String, dynamic>? metadata]) {
    _instance?._log('error', message, metadata);
  }

  /// Log with custom level.
  void _log(String level, String message, Map<String, dynamic>? metadata) {
    if (!_isInitialized) return;

    // Print to console in debug mode
    if (kDebugMode && _config.printToConsole) {
      print('[$level] $message${metadata != null ? ' $metadata' : ''}');
    }

    final logEntry = <String, dynamic>{
      'app_id': _appId,
      ..._deviceInfo!,
      'level': level,
      'message': message,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    if (metadata != null) {
      logEntry['metadata'] = metadata;
    }

    _queue.add(logEntry);

    // Flush immediately for errors
    if (level == 'error') {
      _flush();
    }

    // Trim queue if too large
    if (_queue.length > _config.maxQueueSize) {
      _queue.removeRange(0, _queue.length - _config.maxQueueSize);
    }
  }

  // ============ Queue Management ============

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      Duration(seconds: _config.flushIntervalSeconds),
      (_) => _flush(),
    );
  }

  Future<void> _flush() async {
    if (_queue.isEmpty) return;

    // Drop entries older than 50 minutes — Loki rejects samples older than
    // 1h ("entry too far behind") and a single rejected entry fails the
    // whole batch. Without this, a one-time flush failure poisons the
    // queue forever: persisted entries age past the threshold, every
    // subsequent flush gets 400, and we re-queue back to the front.
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 50))
        .toIso8601String();
    _queue.removeWhere((log) {
      final ts = log['timestamp'] as String?;
      return ts != null && ts.compareTo(cutoff) < 0;
    });
    if (_queue.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(_queue);
    _queue.clear();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/logs/batch'),
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': _apiKey,
            },
            body: jsonEncode({'logs': batch}),
          )
          .timeout(Duration(seconds: _config.httpTimeoutSeconds));

      if (response.statusCode >= 400 && response.statusCode < 500) {
        // 4xx is a permanent rejection — re-queueing would loop forever.
        // Drop the batch.
        return;
      }
      if (response.statusCode != 201) {
        // 5xx / transient — retry on next flush.
        _queue.insertAll(0, batch);
        await _saveQueueToDisk();
      }
    } catch (e) {
      // Re-queue on network error
      _queue.insertAll(0, batch);
      await _saveQueueToDisk();
    }
  }

  /// Manually flush all pending logs.
  static Future<void> flush() async {
    await _instance?._flush();
  }

  // ============ Offline Persistence ============

  Future<void> _saveQueueToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_queue));
    } catch (_) {}
  }

  Future<void> _loadQueueFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      if (stored != null) {
        final list = jsonDecode(stored) as List;
        // Drop any persisted entries older than 50 minutes — Loki will
        // reject them with "entry too far behind" and fail the whole
        // batch. See _flush() for the same guard.
        final cutoff = DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 50))
            .toIso8601String();
        for (final raw in list.cast<Map<String, dynamic>>()) {
          final ts = raw['timestamp'] as String?;
          if (ts == null || ts.compareTo(cutoff) >= 0) {
            _queue.add(raw);
          }
        }
        await prefs.remove(_storageKey);
      }
    } catch (_) {}
  }

  /// Flush all pending logs and stop the timer.
  /// Call on app termination if needed.
  static Future<void> dispose() async {
    await _instance?._dispose();
  }

  Future<void> _dispose() async {
    _flushTimer?.cancel();
    await _flush();
    await _saveQueueToDisk();
  }
}
