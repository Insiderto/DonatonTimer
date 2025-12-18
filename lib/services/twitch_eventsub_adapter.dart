import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import '../models/donation.dart';
import 'donation_service_adapter.dart';
import 'twitch_auth_service.dart';
import 'log_manager.dart';

/// Типы событий Twitch для настройки времени
enum TwitchEventType {
  channelPoints,      // Использование баллов канала
  subscription,       // Новая подписка
  subscriptionGift,   // Подарочная подписка
  resubscription,     // Продление подписки
}

/// Настройки времени для разных типов событий Twitch
class TwitchTimeSettings {
  int channelPointsSeconds;      // Секунды за redemption баллов
  int tier1SubSeconds;           // Секунды за Tier 1 подписку
  int tier2SubSeconds;           // Секунды за Tier 2 подписку
  int tier3SubSeconds;           // Секунды за Tier 3 подписку
  int giftedSubSeconds;          // Секунды за каждый gifted sub
  int resubSeconds;              // Секунды за resub
  bool countResubs;              // Считать ли resub'ы
  String? specificRewardId;      // Только конкретный reward (null = все)
  String? specificRewardName;    // Название reward для фильтра

  TwitchTimeSettings({
    this.channelPointsSeconds = 60,    // +1 мин по умолчанию
    this.tier1SubSeconds = 300,        // +5 мин
    this.tier2SubSeconds = 600,        // +10 мин
    this.tier3SubSeconds = 1500,       // +25 мин
    this.giftedSubSeconds = 300,       // +5 мин за каждый
    this.resubSeconds = 60,            // +1 мин за resub
    this.countResubs = true,
    this.specificRewardId,
    this.specificRewardName,
  });

  Map<String, dynamic> toJson() => {
    'channelPointsSeconds': channelPointsSeconds,
    'tier1SubSeconds': tier1SubSeconds,
    'tier2SubSeconds': tier2SubSeconds,
    'tier3SubSeconds': tier3SubSeconds,
    'giftedSubSeconds': giftedSubSeconds,
    'resubSeconds': resubSeconds,
    'countResubs': countResubs,
    'specificRewardId': specificRewardId,
    'specificRewardName': specificRewardName,
  };

  factory TwitchTimeSettings.fromJson(Map<String, dynamic> json) {
    return TwitchTimeSettings(
      channelPointsSeconds: json['channelPointsSeconds'] ?? 60,
      tier1SubSeconds: json['tier1SubSeconds'] ?? 300,
      tier2SubSeconds: json['tier2SubSeconds'] ?? 600,
      tier3SubSeconds: json['tier3SubSeconds'] ?? 1500,
      giftedSubSeconds: json['giftedSubSeconds'] ?? 300,
      resubSeconds: json['resubSeconds'] ?? 60,
      countResubs: json['countResubs'] ?? true,
      specificRewardId: json['specificRewardId'],
      specificRewardName: json['specificRewardName'],
    );
  }
}

/// Адаптер для Twitch EventSub.
/// Подключается к WebSocket и слушает события баллов канала, подписок и gifted subs.
class TwitchEventSubAdapter extends BaseDonationServiceAdapter {
  static const String _eventSubUrl = 'wss://eventsub.wss.twitch.tv/ws';

  final Logger _logger = Logger('TwitchEventSubAdapter');
  final TwitchAuthService _authService = TwitchAuthService();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  String? _sessionId;
  final Set<String> _activeSubscriptions = {};

  TwitchTimeSettings timeSettings = TwitchTimeSettings();

  @override
  String get serviceName => 'Twitch';

  /// Возвращает сервис авторизации
  TwitchAuthService get authService => _authService;

  /// Проверяет, авторизован ли пользователь
  bool get isAuthorized => _authService.isAuthorized;

  /// Имя пользователя Twitch
  String? get userLogin => _authService.userLogin;

  @override
  Future<void> connect(Map<String, dynamic> config) async {
    // Загружаем сохранённые токены
    if (config.containsKey('accessToken') && config['accessToken'] != null) {
      _authService.loadFromCredentials(config);
    }

    // Загружаем настройки времени из сериализованной строки
    if (config.containsKey('timeSettingsJson')) {
      final str = config['timeSettingsJson']?.toString() ?? '';
      if (str.isNotEmpty) {
        timeSettings = _deserializeTimeSettings(str);
      }
    } else if (config.containsKey('timeSettings') && config['timeSettings'] is Map) {
      timeSettings = TwitchTimeSettings.fromJson(
        config['timeSettings'] as Map<String, dynamic>
      );
    }

    if (!_authService.isAuthorized) {
      _logger.warning('Twitch: требуется авторизация');
      LogManager.warning('Twitch: требуется авторизация');
      updateStatus(ConnectionStatus.disconnected);
      return;
    }

    // Проверяем и обновляем токен если нужно
    if (_authService.isTokenExpired) {
      _logger.info('Twitch: токен истёк, обновляем...');
      LogManager.info('Twitch: обновление токена...');
      final refreshed = await _authService.refreshAccessToken();
      if (!refreshed) {
        _logger.severe('Twitch: не удалось обновить токен');
        LogManager.error('Twitch: не удалось обновить токен, требуется повторная авторизация');
        updateStatus(ConnectionStatus.error);
        return;
      }
    }

    updateStatus(ConnectionStatus.connecting);
    _logger.info('Twitch: подключение к EventSub...');
    LogManager.info('Twitch: подключение к EventSub...');

    await _initWebSocket();
  }

  Future<void> _initWebSocket() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_eventSubUrl));
      LogManager.info('Twitch: WebSocket создан');

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          _logger.severe('Twitch: ошибка WebSocket - $error');
          LogManager.error('Twitch: ошибка WebSocket - $error');
          updateStatus(ConnectionStatus.error);
          _scheduleReconnect();
        },
        onDone: () {
          _logger.warning('Twitch: соединение закрыто');
          LogManager.warning('Twitch: соединение закрыто');
          if (status != ConnectionStatus.disconnected) {
            updateStatus(ConnectionStatus.reconnecting);
            _scheduleReconnect();
          }
        },
      );

    } catch (e, stackTrace) {
      _logger.severe('Twitch: ошибка подключения - $e\n$stackTrace');
      LogManager.error('Twitch: ошибка подключения - $e');
      updateStatus(ConnectionStatus.error);
      _scheduleReconnect();
    }
  }

  void _handleMessage(dynamic message) {
    try {
      final data = json.decode(message.toString()) as Map<String, dynamic>;
      final metadata = data['metadata'] as Map<String, dynamic>;
      final messageType = metadata['message_type'] as String;

      switch (messageType) {
        case 'session_welcome':
          _handleWelcome(data);
          break;
        case 'session_keepalive':
          _handleKeepalive();
          break;
        case 'notification':
          _handleNotification(data);
          break;
        case 'session_reconnect':
          _handleReconnect(data);
          break;
        case 'revocation':
          _handleRevocation(data);
          break;
      }
    } catch (e) {
      _logger.warning('Twitch: ошибка парсинга сообщения - $e');
    }
  }

  void _handleWelcome(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>;
    final session = payload['session'] as Map<String, dynamic>;
    _sessionId = session['id'] as String;
    final keepaliveTimeout = session['keepalive_timeout_seconds'] as int;

    _logger.info('Twitch: Welcome получен, session_id: $_sessionId');
    LogManager.info('Twitch: подключено к EventSub');

    // Устанавливаем таймер keepalive
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer(Duration(seconds: keepaliveTimeout + 10), () {
      _logger.warning('Twitch: keepalive timeout');
      LogManager.warning('Twitch: потеряно соединение (keepalive timeout)');
      _scheduleReconnect();
    });

    // Подписываемся на события
    _subscribeToEvents();
  }

  void _handleKeepalive() {
    _logger.fine('Twitch: keepalive получен');
    // Сбрасываем таймер keepalive
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer(const Duration(seconds: 20), () {
      _logger.warning('Twitch: keepalive timeout');
      _scheduleReconnect();
    });
  }

  void _handleNotification(Map<String, dynamic> data) {
    final metadata = data['metadata'] as Map<String, dynamic>;
    final subscriptionType = metadata['subscription_type'] as String;
    final payload = data['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;

    _logger.info('Twitch: событие $subscriptionType');

    switch (subscriptionType) {
      case 'channel.channel_points_custom_reward_redemption.add':
        _handleChannelPointsRedemption(event);
        break;
      case 'channel.subscribe':
        _handleSubscription(event);
        break;
      case 'channel.subscription.gift':
        _handleGiftedSubscription(event);
        break;
      case 'channel.subscription.message':
        _handleResubscription(event);
        break;
    }
  }

  void _handleReconnect(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>;
    final session = payload['session'] as Map<String, dynamic>;
    final reconnectUrl = session['reconnect_url'] as String;

    _logger.info('Twitch: требуется переподключение к $reconnectUrl');
    LogManager.info('Twitch: переподключение...');

    // Закрываем текущее соединение и подключаемся к новому URL
    _subscription?.cancel();
    _channel?.sink.close();

    _channel = WebSocketChannel.connect(Uri.parse(reconnectUrl));
    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (error) {
        updateStatus(ConnectionStatus.error);
        _scheduleReconnect();
      },
      onDone: () {
        if (status != ConnectionStatus.disconnected) {
          _scheduleReconnect();
        }
      },
    );
  }

  void _handleRevocation(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>;
    final subscription = payload['subscription'] as Map<String, dynamic>;
    final type = subscription['type'] as String;
    final reason = subscription['status'] as String;

    _logger.warning('Twitch: подписка $type отозвана: $reason');
    LogManager.warning('Twitch: подписка $type отозвана: $reason');

    _activeSubscriptions.remove(type);
  }

  /// Подписывается на все необходимые события
  Future<void> _subscribeToEvents() async {
    if (_sessionId == null || _authService.userId == null) return;

    final subscriptionTypes = [
      'channel.channel_points_custom_reward_redemption.add',
      'channel.subscribe',
      'channel.subscription.gift',
      'channel.subscription.message',
    ];

    for (final type in subscriptionTypes) {
      await _createSubscription(type);
    }

    updateStatus(ConnectionStatus.connected);
    _reconnectAttempts = 0;
    LogManager.info('Twitch: все подписки активированы');
  }

  /// Создаёт подписку на событие через HTTP API
  Future<void> _createSubscription(String type) async {
    try {
      final condition = {
        'broadcaster_user_id': _authService.userId,
      };

      // Для channel points можно указать конкретный reward
      if (type == 'channel.channel_points_custom_reward_redemption.add' &&
          timeSettings.specificRewardId != null) {
        condition['reward_id'] = timeSettings.specificRewardId!;
      }

      final body = json.encode({
        'type': type,
        'version': '1',
        'condition': condition,
        'transport': {
          'method': 'websocket',
          'session_id': _sessionId,
        },
      });

      final response = await http.post(
        Uri.https('api.twitch.tv', '/helix/eventsub/subscriptions'),
        headers: {
          'Authorization': 'Bearer ${_authService.accessToken}',
          'Client-Id': TwitchAuthService.clientId,
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response.statusCode == 202) {
        _activeSubscriptions.add(type);
        _logger.info('Twitch: подписка на $type создана');
        LogManager.info('Twitch: подписка на $type активна');
      } else {
        _logger.warning('Twitch: ошибка подписки на $type - ${response.body}');
        LogManager.warning('Twitch: не удалось подписаться на $type');
      }

    } catch (e) {
      _logger.severe('Twitch: ошибка создания подписки - $e');
    }
  }

  /// Обработка использования баллов канала
  void _handleChannelPointsRedemption(Map<String, dynamic> event) {
    final userName = event['user_name'] as String;
    final rewardTitle = event['reward']?['title'] as String? ?? 'Channel Points';
    final rewardId = event['reward']?['id'] as String?;

    // Проверяем фильтр по конкретному reward
    if (timeSettings.specificRewardId != null &&
        rewardId != timeSettings.specificRewardId) {
      _logger.info('Twitch: пропуск reward $rewardTitle (не соответствует фильтру)');
      return;
    }

    final seconds = timeSettings.channelPointsSeconds;

    _logger.info('Twitch: Channel Points от $userName - $rewardTitle (+$seconds сек)');
    LogManager.info('Twitch: $userName использовал баллы канала - $rewardTitle');

    _emitTwitchEvent(
      eventType: 'channel_points',
      username: userName,
      seconds: seconds,
      message: rewardTitle,
    );
  }

  /// Обработка новой подписки
  void _handleSubscription(Map<String, dynamic> event) {
    final userName = event['user_name'] as String;
    final tier = event['tier'] as String; // "1000", "2000", "3000"
    final isGift = event['is_gift'] as bool? ?? false;

    // Пропускаем gifted subs здесь - они обрабатываются в _handleGiftedSubscription
    if (isGift) {
      _logger.info('Twitch: пропуск gifted sub от $userName (обрабатывается отдельно)');
      return;
    }

    final seconds = _getSecondsForTier(tier);

    _logger.info('Twitch: подписка от $userName (Tier ${tier[0]}) +$seconds сек');
    LogManager.info('Twitch: $userName оформил подписку Tier ${tier[0]}');

    _emitTwitchEvent(
      eventType: 'subscription',
      username: userName,
      seconds: seconds,
      message: 'Подписка Tier ${tier[0]}',
      tier: tier,
    );
  }

  /// Обработка подарочных подписок
  void _handleGiftedSubscription(Map<String, dynamic> event) {
    final userName = event['user_name'] as String;
    final tier = event['tier'] as String;
    final total = event['total'] as int;
    final cumulativeTotal = event['cumulative_total'] as int?;

    final secondsPerGift = timeSettings.giftedSubSeconds;
    final totalSeconds = secondsPerGift * total;

    _logger.info('Twitch: $userName подарил $total подписок (всего: ${cumulativeTotal ?? "?"}) +$totalSeconds сек');
    LogManager.info('Twitch: $userName подарил $total подписок Tier ${tier[0]}');

    _emitTwitchEvent(
      eventType: 'gift_subscription',
      username: userName,
      seconds: totalSeconds,
      message: 'Подарил $total подписок',
      giftCount: total,
      tier: tier,
    );
  }

  /// Обработка продления подписки (resub)
  void _handleResubscription(Map<String, dynamic> event) {
    if (!timeSettings.countResubs) {
      _logger.info('Twitch: пропуск resub (отключено в настройках)');
      return;
    }

    final userName = event['user_name'] as String;
    final tier = event['tier'] as String;
    final months = event['cumulative_months'] as int? ?? 1;
    final message = event['message']?['text'] as String?;

    final seconds = timeSettings.resubSeconds;

    _logger.info('Twitch: resub от $userName ($months мес.) +$seconds сек');
    LogManager.info('Twitch: $userName продлил подписку ($months мес.)');

    _emitTwitchEvent(
      eventType: 'resubscription',
      username: userName,
      seconds: seconds,
      message: message ?? 'Продление подписки ($months мес.)',
      tier: tier,
    );
  }

  /// Возвращает количество секунд для указанного tier подписки
  int _getSecondsForTier(String tier) {
    switch (tier) {
      case '1000':
        return timeSettings.tier1SubSeconds;
      case '2000':
        return timeSettings.tier2SubSeconds;
      case '3000':
        return timeSettings.tier3SubSeconds;
      default:
        return timeSettings.tier1SubSeconds;
    }
  }

  /// Создаёт и отправляет событие как Donation
  void _emitTwitchEvent({
    required String eventType,
    required String username,
    required int seconds,
    String? message,
    int? giftCount,
    String? tier,
  }) {
    // Конвертируем секунды в "виртуальную сумму" для совместимости с системой
    // Используем rate 600 RUB = 60 мин, значит 1 секунда = 600/3600 = 0.1667 RUB
    // Но проще просто передать секунды напрямую через amount
    // И использовать специальную валюту "SEC" для секунд

    final donation = Donation(
      id: '${serviceName}_${eventType}_${DateTime.now().millisecondsSinceEpoch}',
      serviceName: serviceName,
      username: username,
      amount: seconds.toDouble(),
      currency: 'SEC', // Специальная валюта = секунды напрямую
      message: message,
      timestamp: DateTime.now(),
    );

    emitDonation(donation);
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _logger.severe('Twitch: превышено число попыток переподключения');
      LogManager.error('Twitch: превышено число попыток переподключения');
      updateStatus(ConnectionStatus.error);
      return;
    }

    _reconnectTimer?.cancel();
    final delay = Duration(seconds: 5 * (_reconnectAttempts + 1));
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _logger.info('Twitch: попытка переподключения #$_reconnectAttempts');
      LogManager.info('Twitch: попытка переподключения #$_reconnectAttempts');
      updateStatus(ConnectionStatus.reconnecting);
      _activeSubscriptions.clear();
      _initWebSocket();
    });
  }

  @override
  Future<void> disconnect() async {
    _logger.info('Twitch: отключение...');
    LogManager.info('Twitch: отключение...');
    updateStatus(ConnectionStatus.disconnected);

    _keepaliveTimer?.cancel();
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();

    _channel = null;
    _subscription = null;
    _sessionId = null;
    _activeSubscriptions.clear();

    _logger.info('Twitch: отключено');
    LogManager.info('Twitch: отключено');
  }

  /// Выполняет авторизацию через OAuth
  Future<bool> authorize() async {
    return await _authService.authorize();
  }

  /// Выход из аккаунта
  Future<void> logout() async {
    await disconnect();
    await _authService.revokeToken();
  }

  /// Возвращает credentials для сохранения
  Map<String, dynamic> getCredentials() {
    final creds = _authService.toCredentials();
    creds['timeSettings'] = timeSettings.toJson();
    return creds;
  }

  /// Десериализует настройки времени из строки
  TwitchTimeSettings _deserializeTimeSettings(String str) {
    try {
      final parts = str.split(',');
      if (parts.length >= 7) {
        return TwitchTimeSettings(
          channelPointsSeconds: int.tryParse(parts[0]) ?? 60,
          tier1SubSeconds: int.tryParse(parts[1]) ?? 300,
          tier2SubSeconds: int.tryParse(parts[2]) ?? 600,
          tier3SubSeconds: int.tryParse(parts[3]) ?? 1500,
          giftedSubSeconds: int.tryParse(parts[4]) ?? 300,
          resubSeconds: int.tryParse(parts[5]) ?? 60,
          countResubs: parts[6] == '1',
        );
      }
    } catch (_) {}
    return TwitchTimeSettings();
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await super.dispose();
  }
}
