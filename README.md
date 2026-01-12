# Looming Tech Flutter Logging SDK

Remote logging SDK for Flutter apps. Sends logs to a self-hosted Loki backend with automatic batching, offline persistence, and device info collection.

## Related SDKs

| Platform | Repository |
|----------|------------|
| Flutter | [looming-logger](https://github.com/Looming-Tech/looming-logger-flutter) |
| Swift (iOS) | [looming-logger-swift](https://github.com/Looming-Tech/looming-logger-flutter-swift) |

## Features

- Automatic device info collection (platform, OS version, model, device ID, etc.)
- Batched log sending with configurable flush interval (default: 30 seconds)
- Offline persistence - logs are saved to disk on network failure and retried
- Immediate flush for error-level logs
- Configurable queue size, flush interval, and timeouts

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  looming_logger:
    git:
      url: https://github.com/Looming-Tech/looming-logger-flutter.git
```

Then run `flutter pub get`.

## Dependencies

This SDK uses the following packages (handled automatically by Flutter):

```yaml
http: ^1.2.2
device_info_plus: ^10.1.0
package_info_plus: ^8.0.0
shared_preferences: ^2.2.0
```

You don't need to add these to your project - Flutter resolves transitive dependencies automatically. However, if your project already uses any of these packages with a different version, you may need to align versions to avoid conflicts.

## Usage

### Initialize

Call `init()` once at app startup, before `runApp()`:

```dart
import 'package:looming_logger/looming_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LoomingLogger.init(
    baseUrl: 'https://logs.yourdomain.com',
    apiKey: 'your-api-key',
    appId: 'your-app-id',
  );

  runApp(MyApp());
}
```

### Logging

```dart
// Info level
LoomingLogger.info('User logged in', {'userId': '123'});

// Debug level
LoomingLogger.debug('Fetching data from API');

// Warning level
LoomingLogger.warn('Slow network detected', {'latency': 2000});

// Error level (flushes immediately)
LoomingLogger.error('Payment failed', {
  'orderId': '456',
  'errorCode': 'TIMEOUT',
});
```

### Configuration

Customize behavior with `LoggerConfig`:

```dart
await LoomingLogger.init(
  baseUrl: 'https://logs.yourdomain.com',
  apiKey: 'your-api-key',
  appId: 'your-app-id',
  config: LoggerConfig(
    maxQueueSize: 200,           // Max logs to queue (default: 100)
    flushIntervalSeconds: 60,    // Flush interval (default: 30)
    httpTimeoutSeconds: 15,      // HTTP timeout (default: 10)
    printToConsole: false,       // Disable console output (default: true)
  ),
);
```

### Manual Flush

Force flush all pending logs:

```dart
await LoomingLogger.flush();
```

### Cleanup

Optional - call on app termination to flush remaining logs:

```dart
await LoomingLogger.dispose();
```

## Device Info Collected

The SDK automatically collects:

**All platforms:**
- App name, version, build number, package ID
- Platform (ios/android)
- OS version
- Device ID
- Model

**Android-specific:**
- Manufacturer, brand, device, product
- SDK version, security patch
- Hardware, board, display, fingerprint
- Supported ABIs

**iOS-specific:**
- Device name, localized model
- Machine ID, system name

## Log Format

Logs are sent to `/api/logs/batch` as JSON:

```json
{
  "logs": [
    {
      "app_id": "your-app-id",
      "level": "info",
      "message": "User logged in",
      "timestamp": "2025-01-09T10:30:00.000Z",
      "device_id": "abc123",
      "platform": "android",
      "os_version": "14",
      "model": "Pixel 8",
      "app_version": "2.0.0",
      "build_number": "42",
      "metadata": {"userId": "123"}
    }
  ]
}
```

## Requirements

- Flutter >= 3.10.0
- Dart >= 3.0.0
