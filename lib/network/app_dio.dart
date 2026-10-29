import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

const _androidWebUserAgent =
    'Mozilla/5.0 (Linux; Android 13; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error(
      "Network",
      "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}",
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    var headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      "Response ${response.realUri.toString()} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    Log.info(
      "Network",
      "${options.method} ${options.uri}\n"
          "headers:\n${options.extra.containsKey("maskHeadersInLog") ? options.headers.map((key, value) => MapEntry(key, options.extra["maskHeadersInLog"].contains(key) ? headerMask : value)) : options.headers}\n"
          "data:\n${options.extra["maskDataInLog"] == true ? dataMask : options.data}",
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = HybridHttpAdapter();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, bool> _requests = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (options?.headers?['prevent-parallel'] == 'true') {
      while (_requests.containsKey(path)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      _requests[path] = true;
      options!.headers!.remove('prevent-parallel');
    }
    try {
      return super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (_requests.containsKey(path)) {
        _requests.remove(path);
      }
    }
  }
}

class HybridHttpAdapter implements HttpClientAdapter {
  final AndroidHttpAdapter _android = AndroidHttpAdapter();
  IOHttpClientAdapter? _dartAdapter;
  String? _dartProxy;

  @override
  void close({bool force = false}) {
    _android.close(force: force);
    _dartAdapter?.close(force: force);
    _dartAdapter = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (App.isAndroid) {
      options.headers.removeWhere(
        (name, _) => name.toLowerCase() == 'accept-encoding',
      );
    }
    _takeHttpClientHint(options.headers);
    try {
      return await _android.fetch(options, requestStream, cancelFuture);
    } catch (error) {
      if (requestStream != null) rethrow;
      Log.warning(
        "Network",
        "Android native HTTP failed; retrying with Dart HTTP client: "
        "${options.method} ${options.uri}\n$error",
      );
      for (final alternateUri in _alternateSourceHosts(options.uri)) {
        try {
          return await _android.fetch(
            options.copyWith(
              path: alternateUri.toString(),
              baseUrl: '',
              queryParameters: const <String, dynamic>{},
            ),
            null,
            cancelFuture,
          );
        } catch (alternateError) {
          Log.warning(
            "Network",
            "Android native source host fallback failed: "
            "$alternateUri\n$alternateError",
          );
        }
      }
    }
    return _fetchWithDartHttpWithHostFallback(options, null, cancelFuture);
  }

  Future<ResponseBody> _fetchWithDartHttpWithHostFallback(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    try {
      return await _fetchWithDartHttp(options, requestStream, cancelFuture);
    } catch (error) {
      if (requestStream == null) {
        for (final alternateUri in _alternateSourceHosts(options.uri)) {
          try {
            return await _fetchWithDartHttp(
              options.copyWith(
                path: alternateUri.toString(),
                baseUrl: '',
                queryParameters: const <String, dynamic>{},
              ),
              null,
              cancelFuture,
            );
          } catch (alternateError) {
            Log.warning(
              "Network",
              "Source host fallback failed: $alternateUri\n$alternateError",
            );
          }
        }
      }
      rethrow;
    }
  }

  Future<ResponseBody> _fetchWithDartHttp(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final proxy = await getProxy();
    if (_dartAdapter == null || _dartProxy != proxy) {
      _dartAdapter?.close(force: true);
      _dartProxy = proxy;
      _dartAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient()
            ..connectionTimeout = options.connectTimeout
            ..idleTimeout = const Duration(seconds: 3)
            ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
          if (appdata.settings['ignoreBadCertificate'] == true) {
            client.badCertificateCallback = (certificate, host, port) => true;
          }
          return client;
        },
      );
    }
    return _dartAdapter!.fetch(options, requestStream, cancelFuture);
  }

  /// `http_client` is an internal source hint and must never be sent to a
  /// website as an HTTP header.
  static String? _takeHttpClientHint(Map<String, dynamic> headers) {
    String? hint;
    String? key;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'http_client') {
        key = entry.key;
        hint = entry.value?.toString().toLowerCase();
        break;
      }
    }
    if (key != null) {
      headers.remove(key);
    }
    return hint;
  }

  static List<Uri> _alternateSourceHosts(Uri uri) {
    final segments = uri.pathSegments;
    const jsdelivrHosts = {
      'cdn.jsdelivr.net',
      'gcore.jsdelivr.net',
      'testingcf.jsdelivr.net',
    };
    if (jsdelivrHosts.contains(uri.host) &&
        segments.length >= 4 &&
        segments[0] == 'gh') {
      final repositoryRef = segments[2];
      final at = repositoryRef.lastIndexOf('@');
      if (at > 0 && at < repositoryRef.length - 1) {
        final owner = segments[1];
        final repository = repositoryRef.substring(0, at);
        final ref = repositoryRef.substring(at + 1);
        final path = segments.sublist(3).join('/');
        final result = <Uri>[
          Uri.https(
            'raw.githubusercontent.com',
            '/$owner/$repository/$ref/$path',
            uri.queryParameters,
          ),
        ];
        for (final host in jsdelivrHosts) {
          if (host != uri.host) {
            result.add(Uri.https(host, uri.path, uri.queryParameters));
          }
        }
        return result;
      }
    }
    if (uri.host == 'raw.githubusercontent.com' && segments.length >= 4) {
      final owner = segments[0];
      final repository = segments[1];
      final ref = segments[2];
      final path = segments.sublist(3).join('/');
      return [
        for (final host in jsdelivrHosts)
          Uri.https(
            host,
            '/gh/$owner/$repository@$ref/$path',
            uri.queryParameters,
          ),
      ];
    }
    return const [];
  }
}

/// Uses Android's platform HTTPS implementation for normal Android requests.
///
/// Some mobile networks reject the TLS fingerprint emitted by Dart's IO
/// client, while the same URL works in an Android browser. The platform
/// implementation uses the Android security provider and therefore follows
/// the same network path as the rest of the device. The response is buffered
/// by the platform channel before being exposed as a Dio response stream.
class AndroidHttpAdapter implements HttpClientAdapter {
  static const MethodChannel _channel = MethodChannel('venera/android_http');

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null
        ? null
        : Uint8List.fromList(
            await requestStream.fold<List<int>>(
              <int>[],
              (buffer, chunk) => buffer..addAll(chunk),
            ),
          );

    final headers = <String, String>{};
    for (final entry in options.headers.entries) {
      final value = entry.value;
      if (value is Iterable) {
        headers[entry.key] = value.join(', ');
      } else if (value != null) {
        headers[entry.key] = value.toString();
      }
    }
    String? userAgentKey;
    for (final key in headers.keys) {
      if (key.toLowerCase() == 'user-agent') {
        userAgentKey = key;
        break;
      }
    }
    if (userAgentKey == null) {
      headers['User-Agent'] = _androidWebUserAgent;
    } else if (headers[userAgentKey] == webUA) {
      // Source scripts historically use the desktop webUA. Android sites
      // often apply different filtering to mobile browser and desktop clients.
      headers[userAgentKey] = _androidWebUserAgent;
    }
    if (!headers.keys.any((key) => key.toLowerCase() == 'accept-encoding')) {
      // HttpURLConnection does not transparently decode every compressed
      // response. Asking for an identity response keeps Dio's byte stream
      // consistent for both text and image requests.
      headers['Accept-Encoding'] = 'identity';
    }

    final result = await _channel.invokeMapMethod<String, dynamic>('request', {
      'method': options.method,
      'url': options.uri.toString(),
      'headers': headers,
      'body': body,
      'connectTimeoutMs': options.connectTimeout?.inMilliseconds ?? 15000,
      'readTimeoutMs': options.receiveTimeout?.inMilliseconds ?? 15000,
      'proxy': await getProxy(),
    });
    if (result == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Android native HTTP returned no response',
      );
    }

    final statusCode = (result['status'] as num?)?.toInt();
    if (statusCode == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: result['error']?.toString() ?? 'Android native HTTP failed',
      );
    }

    final responseHeaders = <String, List<String>>{};
    final rawHeaders = result['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key?.toString();
        if (key == null || key.isEmpty) continue;
        final value = entry.value;
        responseHeaders[key.toLowerCase()] = value is Iterable
            ? value.map((item) => item.toString()).toList()
            : [value.toString()];
      }
    }

    final rawBody = result['body'];
    final responseBytes = rawBody is Uint8List
        ? rawBody
        : rawBody is List<int>
        ? Uint8List.fromList(rawBody)
        : Uint8List(0);
    return ResponseBody(
      Stream<Uint8List>.value(responseBytes),
      statusCode,
      statusMessage: result['statusMessage']?.toString(),
      isRedirect: statusCode >= 300 && statusCode < 400,
      headers: responseHeaders,
    );
  }
}
