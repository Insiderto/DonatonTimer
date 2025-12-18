import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import 'log_manager.dart';

/// Сервис авторизации Twitch через OAuth PKCE flow.
/// Используется для Desktop приложений с публичным Client ID.
class TwitchAuthService {
  // Client ID из Twitch Developer Console
  static const String clientId = '6zkndqdfezbjuoyrvlwtqeau4umjku';
  static const String redirectUri = 'https://localhost:5173';

  // Scopes для EventSub подписок
  static const List<String> scopes = [
    'channel:read:redemptions',    // Для Channel Points
    'channel:read:subscriptions',  // Для подписок и gifted subs
  ];

  HttpServer? _server;
  Completer<Map<String, String>?>? _authCompleter;
  String? _codeVerifier;
  String? _state;

  // Токены
  String? accessToken;
  String? refreshToken;
  String? userId;
  String? userLogin;
  DateTime? tokenExpiresAt;

  /// Callback при успешной авторизации
  Function(String accessToken, String refreshToken, String userId, String userLogin)? onAuthorized;

  /// Callback при ошибке
  Function(String error)? onError;

  /// Проверяет, авторизован ли пользователь
  bool get isAuthorized => accessToken != null && !isTokenExpired;

  /// Проверяет, истёк ли токен
  bool get isTokenExpired {
    if (tokenExpiresAt == null) return true;
    // Считаем истёкшим за 5 минут до реального истечения
    return DateTime.now().isAfter(tokenExpiresAt!.subtract(const Duration(minutes: 5)));
  }

  /// Генерирует случайную строку для PKCE
  String _generateRandomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Генерирует code_challenge из code_verifier (SHA256 + Base64URL)
  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Запускает процесс авторизации OAuth PKCE
  Future<bool> authorize() async {
    try {
      LogManager.info('Twitch: начало авторизации...');

      // Генерируем PKCE параметры
      _codeVerifier = _generateRandomString(64);
      _state = _generateRandomString(32);
      final codeChallenge = _generateCodeChallenge(_codeVerifier!);

      // Запускаем локальный сервер для получения callback
      _authCompleter = Completer<Map<String, String>?>();
      await _startLocalServer();

      // Формируем URL авторизации
      final authUrl = Uri.https('id.twitch.tv', '/oauth2/authorize', {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'state': _state,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      });

      LogManager.info('Twitch: открытие браузера для авторизации');

      // Открываем браузер
      if (await canLaunchUrl(authUrl)) {
        await launchUrl(authUrl, mode: LaunchMode.externalApplication);
      } else {
        LogManager.error('Twitch: не удалось открыть браузер');
        await _stopLocalServer();
        onError?.call('Не удалось открыть браузер');
        return false;
      }

      // Ждём callback (таймаут 5 минут)
      final result = await _authCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          LogManager.warning('Twitch: таймаут авторизации');
          return null;
        },
      );

      await _stopLocalServer();

      if (result == null) {
        onError?.call('Авторизация отменена или истекло время');
        return false;
      }

      if (result.containsKey('error')) {
        final error = result['error'] ?? 'Unknown error';
        LogManager.error('Twitch: ошибка авторизации - $error');
        onError?.call(error);
        return false;
      }

      final code = result['code'];
      final state = result['state'];

      // Проверяем state для защиты от CSRF
      if (state != _state) {
        LogManager.error('Twitch: несоответствие state параметра');
        onError?.call('Ошибка безопасности: несоответствие state');
        return false;
      }

      // Обмениваем code на токены
      return await _exchangeCodeForTokens(code!);

    } catch (e) {
      LogManager.error('Twitch: ошибка авторизации - $e');
      await _stopLocalServer();
      onError?.call('Ошибка: $e');
      return false;
    }
  }

  /// Запускает локальный HTTPS сервер для OAuth callback
  Future<void> _startLocalServer() async {
    // Создаём самоподписанный сертификат для HTTPS
    final securityContext = SecurityContext()
      ..useCertificateChainBytes(_generateSelfSignedCert())
      ..usePrivateKeyBytes(_generatePrivateKey());

    _server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      5173,
      securityContext,
    );
    LogManager.info('Twitch: HTTPS сервер запущен на порту 5173');

    _server!.listen((request) async {
      if (request.uri.path == '/' || request.uri.path.isEmpty) {
        final params = request.uri.queryParameters;

        // Отправляем красивую страницу пользователю
        final response = request.response;
        response.statusCode = 200;
        response.headers.contentType = ContentType.html;

        if (params.containsKey('code')) {
          response.write(_getSuccessHtml());
          _authCompleter?.complete(params);
        } else if (params.containsKey('error')) {
          response.write(_getErrorHtml(params['error_description'] ?? params['error'] ?? 'Unknown error'));
          _authCompleter?.complete({'error': params['error_description'] ?? params['error']});
        } else {
          response.write(_getErrorHtml('Неизвестный ответ'));
          _authCompleter?.complete(null);
        }

        await response.close();
      }
    });
  }

  /// Генерирует самоподписанный сертификат (PEM формат)
  List<int> _generateSelfSignedCert() {
    // Самоподписанный сертификат для localhost
    // Этот сертификат предгенерирован для localhost:5173
    const cert = '''-----BEGIN CERTIFICATE-----
MIICpDCCAYwCCQDU+pQ4P4k8MzANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAls
b2NhbGhvc3QwHhcNMjQwMTAxMDAwMDAwWhcNMjUwMTAxMDAwMDAwWjAUMRIwEAYD
VQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC7
o5kwSN0bMKJxFrHpZ0HQV8Vupd8kLzELvQb7UPr1lkD1p9GWVHP8y4TpPvPqJZkL
qx8wMorvzLGX9rDkEnDd5MxB3q5vL4qeB5a3kqZhUFwd3rVxJOTk3qZnPvkNAqWT
vDqqhKDqvjx7XD9DoHqSIAepuzIJPvdCl5PDq6B4yHqen7V0xJDyZzS7FxEwQisD
nNmh1qHKN3v7dHCsK1UlvMv/E9R2rVDKPq6AX1VJHXlkqYdfn3qpNbCgUelcs1E4
h0qW5pOqrYDHdw2ovLMhO6zaqHJYrMzPYTqVLfjhbhNxUqpR7pNd0fMALpp9dGvQ
M6xBmFc2sPHNiunPaKd3AgMBAAEwDQYJKoZIhvcNAQELBQADggEBAGsKLdmgMPmx
EZpjPC2T7orP1M0Xtq5KMj3IbVLFj4rHOJIH0wDjz7dL3sv9lfCgPTLV0M0qga/L
rUjbGYLheLnBbMdnUoFPGNXjqH9y7gHmBxv9G5ngOz7pYXBF7VAOB6M5VLXHG9Xh
TI1TZGH7S1HYClbP7vb1Q5MpLRq8akra5BOMF6MEAW5FArG2M8P5geCqvU+EWWLF
vNGK9UCKDS2DNBWMBQ3N0qKwCDDfKRH9qVVdFj6dXJ4gpYFq2iwN1Klf0P2T7A4G
EMvvBZZPJDD9E5BCkpR3+N0PBVdAkPMrmNw54kQcS0JvyXxVA/BXl+l7N8F4Y0uY
7WKk9ib9xdA=
-----END CERTIFICATE-----''';
    return utf8.encode(cert);
  }

  /// Генерирует приватный ключ (PEM формат)
  List<int> _generatePrivateKey() {
    const key = '''-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7o5kwSN0bMKJx
FrHpZ0HQV8Vupd8kLzELvQb7UPr1lkD1p9GWVHP8y4TpPvPqJZkLqx8wMorvzLGX
9rDkEnDd5MxB3q5vL4qeB5a3kqZhUFwd3rVxJOTk3qZnPvkNAqWTvDqqhKDqvjx7
XD9DoHqSIAepuzIJPvdCl5PDq6B4yHqen7V0xJDyZzS7FxEwQisDnNmh1qHKN3v7
dHCsK1UlvMv/E9R2rVDKPq6AX1VJHXlkqYdfn3qpNbCgUelcs1E4h0qW5pOqrYDH
dw2ovLMhO6zaqHJYrMzPYTqVLfjhbhNxUqpR7pNd0fMALpp9dGvQM6xBmFc2sPHN
iunPaKd3AgMBAAECggEAI9Z9P9OgkKLqKzt3JxSRCs8UY9bdJGHaBz/OLTXfXcW9
D4T6C8B8KxLMD7OWLDvloB3ov0pTCq8CXRLE0UR2qBOv1Ckl0FKpLBuBdBAOnXEd
CqnK1DsB2HQxKOejLPr/R9P/siHTQT7By7V+S/lWJuVdNE0H3Q3qIaJ3u6gCjKsP
OKBJ5s3rxmFqFynMR3gpLyrZhQF7CR7fN1CAE8a9PbmksZBPBHr3qGPvYpMDB0sb
hfMgJh3xMlEqutHYXHQJOxgrPEN37B0pAGuvSnoGxaJsHl+4t5E3EsZ1tjHGsG8W
tYdrhdF3YJLOSgc2+bSVL3MX9u5cw7SodB5RXy47QQKBgQDqlJy+oeGOlG0R6GAZ
T/7rLdSKHUhPOqNfki2K5xZ7xShCe02ba+d6WPo9rWf6Y6P9t0sT1LbF2V2D8psr
dJnJ3vLB7NvrhHHOJR3eVE6iLfPwMMBvrrBnDD9SNPB7DVLZNyltDfSgPmnKJyZl
FPDhh8r9dE8ANFpHCPf7zWLuNwKBgQDNJ+mvBRBjpUnS+gjvCo20LLfc1+gWkmsR
ZT+cy/VfPwjZ3DORLU1zvS5pfGTSVZVL2Prbg+sOyAAKY3kxhTFc4GS5O5lKBPjQ
3ROMWL3bPxU99Dv3nNKLZ6FuBHV31e9LLd9hFSdcBB3lPzGdOhd7end1M8L1IVFF
2R0jlnXvwQKBgQDf5NPoJtmF3H3Vf4TlFtwvXmamtAPxgBGlVE7tzJZ0/3lbTsLR
m5Ja8CiSwAZBAtl/hXQINEp+4qignPqC3wKBzq1MS7N9TU23SLHivI0wZVbvVs7V
XMB3t7ULoFI0HVqul1vbbfWDCgW75s8Ehv3sFP/xEspghU7ABwRHAOFp2wKBgB0T
bT9TM7n/v9L0F3ByNPqy6RixkkR7XKNp+0F3JQGl4lTXhkMweNiXPmMoHDMnFE9B
90PRJfvHJklkQhZBmF2DOAXB4QUprhRbxLgwIm4SB2M3L0xIL5RB2+ sWi+suHBqJ
cPFQgvNOkW0wmFPp7QjzgAUR7g8mOqPEWnT7U6IBAoGBAKOjrbHPMGH4E2K7oSRr
2ofvvMQ02TZYVATNfQMiwFkXAtmLGEF/o5gJdCgF9P1L0DQAT7D1zj2J0sFPvs+v
zJDFBDCBORJOPmCp8DhuT7oJdPmOwPvKH3VFVdQvUBdVpr3Ftq4xsyVi4xmYTKFG
L/OSzxuQ1To2gA5EfL+ioFnk
-----END PRIVATE KEY-----''';
    return utf8.encode(key);
  }

  /// Останавливает локальный сервер
  Future<void> _stopLocalServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Обменивает authorization code на access token
  Future<bool> _exchangeCodeForTokens(String code) async {
    try {
      LogManager.info('Twitch: обмен кода на токен...');

      final response = await http.post(
        Uri.https('id.twitch.tv', '/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'code': code,
          'code_verifier': _codeVerifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirectUri,
        },
      );

      if (response.statusCode != 200) {
        LogManager.error('Twitch: ошибка получения токена - ${response.body}');
        onError?.call('Ошибка получения токена: ${response.statusCode}');
        return false;
      }

      final data = json.decode(response.body);
      accessToken = data['access_token'];
      refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] as int;
      tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      LogManager.info('Twitch: токен получен, истекает через $expiresIn секунд');

      // Получаем информацию о пользователе
      await _fetchUserInfo();

      if (userId != null && userLogin != null) {
        onAuthorized?.call(accessToken!, refreshToken!, userId!, userLogin!);
        LogManager.info('Twitch: авторизация успешна для $userLogin');
        return true;
      }

      return false;

    } catch (e) {
      LogManager.error('Twitch: ошибка обмена кода - $e');
      onError?.call('Ошибка: $e');
      return false;
    }
  }

  /// Получает информацию о пользователе
  Future<void> _fetchUserInfo() async {
    try {
      final response = await http.get(
        Uri.https('api.twitch.tv', '/helix/users'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Client-Id': clientId,
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final users = data['data'] as List;
        if (users.isNotEmpty) {
          userId = users[0]['id'];
          userLogin = users[0]['login'];
          LogManager.info('Twitch: пользователь - $userLogin (ID: $userId)');
        }
      }
    } catch (e) {
      LogManager.error('Twitch: ошибка получения информации о пользователе - $e');
    }
  }

  /// Обновляет access token используя refresh token
  Future<bool> refreshAccessToken() async {
    if (refreshToken == null) {
      LogManager.warning('Twitch: нет refresh token для обновления');
      return false;
    }

    try {
      LogManager.info('Twitch: обновление токена...');

      final response = await http.post(
        Uri.https('id.twitch.tv', '/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
      );

      if (response.statusCode != 200) {
        LogManager.error('Twitch: ошибка обновления токена - ${response.body}');
        return false;
      }

      final data = json.decode(response.body);
      accessToken = data['access_token'];
      refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] as int;
      tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      LogManager.info('Twitch: токен обновлён');
      return true;

    } catch (e) {
      LogManager.error('Twitch: ошибка обновления токена - $e');
      return false;
    }
  }

  /// Отзывает токен (выход)
  Future<void> revokeToken() async {
    if (accessToken == null) return;

    try {
      await http.post(
        Uri.https('id.twitch.tv', '/oauth2/revoke'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'token': accessToken,
        },
      );
      LogManager.info('Twitch: токен отозван');
    } catch (e) {
      LogManager.error('Twitch: ошибка отзыва токена - $e');
    }

    accessToken = null;
    refreshToken = null;
    userId = null;
    userLogin = null;
    tokenExpiresAt = null;
  }

  /// Загружает токены из сохранённых данных
  void loadFromCredentials(Map<String, dynamic> credentials) {
    accessToken = credentials['accessToken'];
    refreshToken = credentials['refreshToken'];
    userId = credentials['userId'];
    userLogin = credentials['userLogin'];
    if (credentials['tokenExpiresAt'] != null) {
      tokenExpiresAt = DateTime.tryParse(credentials['tokenExpiresAt']);
    }
  }

  /// Сохраняет токены в формате для хранения
  Map<String, dynamic> toCredentials() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'userId': userId,
      'userLogin': userLogin,
      'tokenExpiresAt': tokenExpiresAt?.toIso8601String(),
    };
  }

  /// HTML страница успешной авторизации
  String _getSuccessHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>DonatonTimer - Успех!</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #9146FF 0%, #772CE8 100%);
      color: white;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      margin: 0;
    }
    .container {
      text-align: center;
      padding: 40px;
      background: rgba(0,0,0,0.3);
      border-radius: 16px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.3);
    }
    h1 { font-size: 2.5em; margin-bottom: 16px; }
    p { font-size: 1.2em; opacity: 0.9; }
    .icon { font-size: 4em; margin-bottom: 20px; }
  </style>
</head>
<body>
  <div class="container">
    <div class="icon">✓</div>
    <h1>Авторизация успешна!</h1>
    <p>Можете закрыть это окно и вернуться в DonatonTimer</p>
  </div>
</body>
</html>
''';
  }

  /// HTML страница ошибки
  String _getErrorHtml(String error) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>DonatonTimer - Ошибка</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #FF4444 0%, #CC0000 100%);
      color: white;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      margin: 0;
    }
    .container {
      text-align: center;
      padding: 40px;
      background: rgba(0,0,0,0.3);
      border-radius: 16px;
    }
    h1 { font-size: 2em; margin-bottom: 16px; }
    p { font-size: 1.1em; opacity: 0.9; }
    .icon { font-size: 4em; margin-bottom: 20px; }
  </style>
</head>
<body>
  <div class="container">
    <div class="icon">✗</div>
    <h1>Ошибка авторизации</h1>
    <p>$error</p>
    <p style="margin-top: 20px;">Попробуйте ещё раз в приложении</p>
  </div>
</body>
</html>
''';
  }
}
