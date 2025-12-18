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
  static const String redirectUri = 'http://localhost:5173';

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

  /// Запускает локальный HTTP сервер для OAuth callback
  Future<void> _startLocalServer() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 5173);
    LogManager.info('Twitch: локальный сервер запущен на порту 5173');

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
