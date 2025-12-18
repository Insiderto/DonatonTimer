import 'package:flutter/material.dart';
import 'package:nes_ui/nes_ui.dart';
import 'package:provider/provider.dart';

import '../providers/localization_provider.dart';
import '../providers/timer_provider.dart';
import '../services/donation_service.dart';
import '../services/donation_service_adapter.dart';
import '../services/twitch_eventsub_adapter.dart';
import '../services/sound_service.dart';
import '../services/log_manager.dart';
import '../models/service_config.dart';
import '../models/app_settings.dart';

/// Экран настроек с вкладками для сервисов, таймера и звуков.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final localization = context.watch<LocalizationProvider>();

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                NesButton.icon(
                  type: NesButtonType.normal,
                  icon: NesIcons.leftArrowIndicator,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 16),
                Text(
                  localization.tr('settings'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Tab buttons
            _buildTabButtons(localization),
            const SizedBox(height: 16),
            
            // Tab content
            Expanded(
              child: _buildTabContent(localization),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButtons(LocalizationProvider localization) {
    return Row(
      children: [
        Expanded(
          child: NesButton.text(
            type: _selectedTabIndex == 0 
                ? NesButtonType.primary 
                : NesButtonType.normal,
            text: localization.tr('services'),
            onPressed: () => setState(() => _selectedTabIndex = 0),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NesButton.text(
            type: _selectedTabIndex == 1 
                ? NesButtonType.primary 
                : NesButtonType.normal,
            text: localization.tr('timer'),
            onPressed: () => setState(() => _selectedTabIndex = 1),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NesButton.text(
            type: _selectedTabIndex == 2 
                ? NesButtonType.primary 
                : NesButtonType.normal,
            text: localization.tr('sounds'),
            onPressed: () => setState(() => _selectedTabIndex = 2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NesButton.text(
            type: _selectedTabIndex == 3 
                ? NesButtonType.primary 
                : NesButtonType.normal,
            text: localization.tr('data'),
            onPressed: () => setState(() => _selectedTabIndex = 3),
          ),
        ),
      ],
    );
  }

  Widget _buildTabContent(LocalizationProvider localization) {
    switch (_selectedTabIndex) {
      case 0:
        return const ServicesSettingsTab();
      case 1:
        return const TimerSettingsTab();
      case 2:
        return const SoundsSettingsTab();
      case 3:
        return const DataSettingsTab();
      default:
        return const ServicesSettingsTab();
    }
  }
}


/// Вкладка настройки донат-сервисов.
class ServicesSettingsTab extends StatefulWidget {
  const ServicesSettingsTab({super.key});

  @override
  State<ServicesSettingsTab> createState() => _ServicesSettingsTabState();
}

class _ServicesSettingsTabState extends State<ServicesSettingsTab> {
  // DonationAlerts controllers
  final _daTokenController = TextEditingController();
  bool _daEnabled = false;
  String _daSocketServer = 'socket5';
  bool _daTokenVisible = false;

  // DonatePay controllers
  final _dpApiKeyController = TextEditingController();
  bool _dpEnabled = false;
  bool _dpKeyVisible = false;

  // Donate.Stream controllers
  final _dsTokenController = TextEditingController();
  bool _dsEnabled = false;
  bool _dsTokenVisible = false;

  // DonateX controllers
  final _dxWidgetUrlController = TextEditingController();
  final _dxGroupUrlController = TextEditingController();
  bool _dxEnabled = false;
  bool _dxTokenVisible = false;

  // Twitch state
  bool _twitchEnabled = false;
  bool _twitchAuthorizing = false;
  TwitchTimeSettings _twitchTimeSettings = TwitchTimeSettings();
  final _twitchChannelPointsController = TextEditingController(text: '60');
  final _twitchTier1Controller = TextEditingController(text: '300');
  final _twitchTier2Controller = TextEditingController(text: '600');
  final _twitchTier3Controller = TextEditingController(text: '1500');
  final _twitchGiftedController = TextEditingController(text: '300');
  final _twitchResubController = TextEditingController(text: '60');
  bool _twitchCountResubs = true;

  // Available socket servers for DonationAlerts
  static const List<String> _socketServers = [
    'socket5',
    'socket',
    'socket1',
    'socket2',
    'socket3',
    'socket4',
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final settings = donationService.settings;

    // DonationAlerts
    final daConfig = settings.getServiceConfig('DonationAlerts');
    if (daConfig != null) {
      _daEnabled = daConfig.enabled;
      _daTokenController.text = daConfig.getCredential('token') ?? '';
      _daSocketServer = daConfig.getCredential('socketServer') ?? 'socket5';
    }

    // DonatePay
    final dpConfig = settings.getServiceConfig('DonatePay');
    if (dpConfig != null) {
      _dpEnabled = dpConfig.enabled;
      _dpApiKeyController.text = dpConfig.getCredential('apiKey') ?? '';
    }

    // Donate.Stream
    final dsConfig = settings.getServiceConfig('DonateStream');
    if (dsConfig != null) {
      _dsEnabled = dsConfig.enabled;
      _dsTokenController.text = dsConfig.getCredential('token') ?? '';
    }

    // DonateX
    final dxConfig = settings.getServiceConfig('DonateX');
    if (dxConfig != null) {
      _dxEnabled = dxConfig.enabled;
      _dxWidgetUrlController.text = dxConfig.getCredential('widgetUrl') ?? '';
      _dxGroupUrlController.text = dxConfig.getCredential('groupUrl') ?? '';
    }

    // Twitch
    final twitchConfig = settings.getServiceConfig('Twitch');
    if (twitchConfig != null) {
      _twitchEnabled = twitchConfig.enabled;
      final timeSettingsStr = twitchConfig.getCredential('timeSettingsJson');
      if (timeSettingsStr != null && timeSettingsStr.isNotEmpty) {
        _twitchTimeSettings = _deserializeTimeSettings(timeSettingsStr);
      }
    }
    _twitchChannelPointsController.text = _twitchTimeSettings.channelPointsSeconds.toString();
    _twitchTier1Controller.text = _twitchTimeSettings.tier1SubSeconds.toString();
    _twitchTier2Controller.text = _twitchTimeSettings.tier2SubSeconds.toString();
    _twitchTier3Controller.text = _twitchTimeSettings.tier3SubSeconds.toString();
    _twitchGiftedController.text = _twitchTimeSettings.giftedSubSeconds.toString();
    _twitchResubController.text = _twitchTimeSettings.resubSeconds.toString();
    _twitchCountResubs = _twitchTimeSettings.countResubs;

    setState(() {});
  }

  @override
  void dispose() {
    _daTokenController.dispose();
    _dpApiKeyController.dispose();
    _dsTokenController.dispose();
    _dxWidgetUrlController.dispose();
    _dxGroupUrlController.dispose();
    _twitchChannelPointsController.dispose();
    _twitchTier1Controller.dispose();
    _twitchTier2Controller.dispose();
    _twitchTier3Controller.dispose();
    _twitchGiftedController.dispose();
    _twitchResubController.dispose();
    super.dispose();
  }

  Future<void> _saveServiceConfig(String serviceName, bool enabled, Map<String, String> credentials) async {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final config = ServiceConfig(
      serviceName: serviceName,
      enabled: enabled,
      credentials: credentials,
    );

    await donationService.updateServiceConfig(config);

    if (mounted) {
      NesSnackbar.show(
        context,
        text: '$serviceName OK!',
        type: NesSnackbarType.success,
      );
    }
  }

  ConnectionStatus _getAdapterStatus(String serviceName) {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return ConnectionStatus.disconnected;
    final adapter = donationService.getAdapter(serviceName);
    return adapter?.status ?? ConnectionStatus.disconnected;
  }

  Widget _buildStatusIndicator(ConnectionStatus status) {
    Color color;
    String tooltip;
    
    switch (status) {
      case ConnectionStatus.connected:
        color = Colors.green;
        tooltip = 'Подключено';
        break;
      case ConnectionStatus.connecting:
      case ConnectionStatus.reconnecting:
        color = Colors.orange;
        tooltip = 'Подключение...';
        break;
      case ConnectionStatus.error:
        color = Colors.red;
        tooltip = 'Ошибка';
        break;
      case ConnectionStatus.disconnected:
      default:
        color = Colors.grey;
        tooltip = 'Отключено';
    }
    
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: status == ConnectionStatus.connected
              ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4, spreadRadius: 1)]
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localization = context.watch<LocalizationProvider>();
    // Watch donation service for status updates
    context.watch<DonationService?>();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // DonationAlerts
          _buildDonationAlertsSection(localization),
          const SizedBox(height: 16),

          // DonatePay
          _buildDonatePaySection(localization),
          const SizedBox(height: 16),

          // Donate.Stream
          _buildDonateStreamSection(localization),
          const SizedBox(height: 16),

          // DonateX
          _buildDonateXSection(localization),
          const SizedBox(height: 16),

          // Twitch (Subathon)
          _buildTwitchSection(localization),
        ],
      ),
    );
  }

  Widget _buildDonationAlertsSection(LocalizationProvider localization) {
    final status = _getAdapterStatus('DonationAlerts');
    return NesContainer(
      label: localization.tr('donation_alerts'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable checkbox + status indicator
            Row(
              children: [
                NesCheckBox(
                  value: _daEnabled,
                  onChange: (value) => setState(() => _daEnabled = value),
                ),
                const SizedBox(width: 12),
                Text(
                  _daEnabled 
                      ? localization.tr('enabled') 
                      : localization.tr('disabled'),
                ),
                const Spacer(),
                _buildStatusIndicator(status),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 16),

            // Token field
            Text('${localization.tr('token')} (${localization.tr('or_widget_url')}):'),
            const SizedBox(height: 8),
            TextField(
              controller: _daTokenController,
              obscureText: !_daTokenVisible,
              decoration: InputDecoration(
                hintText: 'Token or widget URL',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  icon: Icon(_daTokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _daTokenVisible = !_daTokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Можно вставить ссылку виджета или только токен',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Socket server dropdown
            Text('${localization.tr('socket_server')}:'),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: _daSocketServer,
              isExpanded: true,
              items: _socketServers.map((socket) {
                return DropdownMenuItem(
                  value: socket,
                  child: Text('$socket.donationalerts.ru'),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _daSocketServer = value);
                }
              },
            ),
            const SizedBox(height: 4),
            Text(
              'Если донаты не приходят - попробуйте другой сокет',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Save button
            NesButton.text(
              type: NesButtonType.success,
              text: localization.tr('save'),
              onPressed: () => _saveServiceConfig(
                'DonationAlerts',
                _daEnabled,
                {
                  'token': _daTokenController.text,
                  'socketServer': _daSocketServer,
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDonatePaySection(LocalizationProvider localization) {
    final status = _getAdapterStatus('DonatePay');
    return NesContainer(
      label: localization.tr('donate_pay'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable checkbox + status indicator
            Row(
              children: [
                NesCheckBox(
                  value: _dpEnabled,
                  onChange: (value) => setState(() => _dpEnabled = value),
                ),
                const SizedBox(width: 12),
                Text(
                  _dpEnabled 
                      ? localization.tr('enabled') 
                      : localization.tr('disabled'),
                ),
                const Spacer(),
                _buildStatusIndicator(status),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 16),

            // API Key field
            Text('API Key:'),
            const SizedBox(height: 8),
            TextField(
              controller: _dpApiKeyController,
              obscureText: !_dpKeyVisible,
              decoration: InputDecoration(
                hintText: 'API key from DonatePay',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  icon: Icon(_dpKeyVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _dpKeyVisible = !_dpKeyVisible),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Save button
            NesButton.text(
              type: NesButtonType.success,
              text: localization.tr('save'),
              onPressed: () => _saveServiceConfig(
                'DonatePay',
                _dpEnabled,
                {
                  'apiKey': _dpApiKeyController.text,
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDonateStreamSection(LocalizationProvider localization) {
    final status = _getAdapterStatus('DonateStream');
    return NesContainer(
      label: localization.tr('donate_stream'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable checkbox + status indicator
            Row(
              children: [
                NesCheckBox(
                  value: _dsEnabled,
                  onChange: (value) => setState(() => _dsEnabled = value),
                ),
                const SizedBox(width: 12),
                Text(
                  _dsEnabled 
                      ? localization.tr('enabled') 
                      : localization.tr('disabled'),
                ),
                const Spacer(),
                _buildStatusIndicator(status),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 16),

            // Token field
            Text('${localization.tr('token')} (${localization.tr('or_widget_url')}):'),
            const SizedBox(height: 8),
            TextField(
              controller: _dsTokenController,
              obscureText: !_dsTokenVisible,
              decoration: InputDecoration(
                hintText: 'Token or widget URL',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  icon: Icon(_dsTokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _dsTokenVisible = !_dsTokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Можно вставить ссылку виджета или только токен',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Save button
            NesButton.text(
              type: NesButtonType.success,
              text: localization.tr('save'),
              onPressed: () => _saveServiceConfig(
                'DonateStream',
                _dsEnabled,
                {'token': _dsTokenController.text},
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDonateXSection(LocalizationProvider localization) {
    final status = _getAdapterStatus('DonateX');
    return NesContainer(
      label: localization.tr('donatex'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable checkbox + status indicator
            Row(
              children: [
                NesCheckBox(
                  value: _dxEnabled,
                  onChange: (value) => setState(() => _dxEnabled = value),
                ),
                const SizedBox(width: 12),
                Text(
                  _dxEnabled 
                      ? localization.tr('enabled') 
                      : localization.tr('disabled'),
                ),
                const Spacer(),
                _buildStatusIndicator(status),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 16),

            // Widget URL field (for token extraction)
            Text('${localization.tr('donatex_widget_url')}:'),
            const SizedBox(height: 8),
            TextField(
              controller: _dxWidgetUrlController,
              obscureText: !_dxTokenVisible,
              decoration: InputDecoration(
                hintText: 'https://donatex.gg/recent-donations?token=...',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  icon: Icon(_dxTokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _dxTokenVisible = !_dxTokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Group URL field (for widget_id extraction)
            Text('${localization.tr('donatex_group_url')}:'),
            const SizedBox(height: 8),
            TextField(
              controller: _dxGroupUrlController,
              decoration: InputDecoration(
                hintText: 'https://donatex.gg/widgets/donations/...',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Виджет последних сообщений → токен, Группа оповещалки → widget_id',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Save button
            NesButton.text(
              type: NesButtonType.success,
              text: localization.tr('save'),
              onPressed: () => _saveDonateXConfig(),
            ),
          ],
        ),
      ),
    );
  }

  void _saveDonateXConfig() {
    // Extract token from widget URL
    String? token;
    final widgetUrl = _dxWidgetUrlController.text;
    if (widgetUrl.contains('token=')) {
      final uri = Uri.tryParse(widgetUrl);
      token = uri?.queryParameters['token'];
    } else {
      token = widgetUrl; // Assume it's just the token
    }

    // Extract widget_id from group URL
    String? widgetId;
    final groupUrl = _dxGroupUrlController.text;
    final donationsMatch = RegExp(r'/widgets/donations/([a-f0-9-]+)').firstMatch(groupUrl);
    if (donationsMatch != null) {
      widgetId = donationsMatch.group(1);
    } else {
      widgetId = groupUrl; // Assume it's just the widget_id
    }

    _saveServiceConfig(
      'DonateX',
      _dxEnabled,
      {
        'token': token ?? '',
        'widgetId': widgetId ?? '',
        'widgetUrl': _dxWidgetUrlController.text,
        'groupUrl': _dxGroupUrlController.text,
      },
    );
  }

  Widget _buildTwitchSection(LocalizationProvider localization) {
    final status = _getAdapterStatus('Twitch');
    final donationService = context.read<DonationService?>();
    final twitchAdapter = donationService?.getAdapter('Twitch') as TwitchEventSubAdapter?;
    final isAuthorized = twitchAdapter?.isAuthorized ?? false;
    final userLogin = twitchAdapter?.userLogin;

    return NesContainer(
      label: 'Twitch (Subathon)',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable checkbox + status indicator
            Row(
              children: [
                NesCheckBox(
                  value: _twitchEnabled,
                  onChange: (value) => setState(() => _twitchEnabled = value),
                ),
                const SizedBox(width: 12),
                Text(
                  _twitchEnabled
                      ? localization.tr('enabled')
                      : localization.tr('disabled'),
                ),
                const Spacer(),
                _buildStatusIndicator(status),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 16),

            // Authorization section
            if (isAuthorized) ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Авторизован как: $userLogin',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              NesButton.text(
                type: NesButtonType.warning,
                text: 'Выйти из Twitch',
                onPressed: () async {
                  await twitchAdapter?.logout();
                  setState(() {});
                },
              ),
            ] else ...[
              Text(
                'Для работы subathon-функций необходима авторизация в Twitch',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              NesButton.text(
                type: NesButtonType.primary,
                text: _twitchAuthorizing ? 'Авторизация...' : 'Войти через Twitch',
                onPressed: _twitchAuthorizing ? null : () => _authorizeTwitch(twitchAdapter),
              ),
            ],
            const SizedBox(height: 24),

            // Time settings section
            Text(
              'Настройки времени (в секундах)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Channel Points
            _buildTimeSettingRow(
              'Баллы канала (за использование):',
              _twitchChannelPointsController,
              'Время за каждое использование баллов канала',
            ),
            const SizedBox(height: 12),

            // Subscriptions
            Text(
              'Подписки:',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildCompactTimeField('Tier 1', _twitchTier1Controller),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCompactTimeField('Tier 2', _twitchTier2Controller),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildCompactTimeField('Tier 3', _twitchTier3Controller),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Gifted Subs
            _buildTimeSettingRow(
              'Gifted Sub (за каждый):',
              _twitchGiftedController,
              'Время за каждую подаренную подписку',
            ),
            const SizedBox(height: 12),

            // Resubs
            Row(
              children: [
                Expanded(
                  child: _buildTimeSettingRow(
                    'Resub:',
                    _twitchResubController,
                    'Время за продление подписки',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                NesCheckBox(
                  value: _twitchCountResubs,
                  onChange: (value) => setState(() => _twitchCountResubs = value),
                ),
                const SizedBox(width: 8),
                const Text('Учитывать resub\'ы', style: TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 24),

            // Save button
            NesButton.text(
              type: NesButtonType.success,
              text: localization.tr('save'),
              onPressed: _saveTwitchConfig,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeSettingRow(String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            suffixText: 'сек',
          ),
        ),
      ],
    );
  }

  Widget _buildCompactTimeField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            suffixText: 'с',
          ),
        ),
      ],
    );
  }

  Future<void> _authorizeTwitch(TwitchEventSubAdapter? adapter) async {
    if (adapter == null) return;

    setState(() => _twitchAuthorizing = true);

    try {
      final success = await adapter.authorize();
      if (success && mounted) {
        NesSnackbar.show(
          context,
          text: 'Twitch авторизация успешна!',
          type: NesSnackbarType.success,
        );
        // Save credentials
        await _saveTwitchConfig();
      } else if (mounted) {
        NesSnackbar.show(
          context,
          text: 'Ошибка авторизации Twitch',
          type: NesSnackbarType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        NesSnackbar.show(
          context,
          text: 'Ошибка: $e',
          type: NesSnackbarType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _twitchAuthorizing = false);
      }
    }
  }

  Future<void> _saveTwitchConfig() async {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final twitchAdapter = donationService.getAdapter('Twitch') as TwitchEventSubAdapter?;

    // Update time settings
    _twitchTimeSettings = TwitchTimeSettings(
      channelPointsSeconds: int.tryParse(_twitchChannelPointsController.text) ?? 60,
      tier1SubSeconds: int.tryParse(_twitchTier1Controller.text) ?? 300,
      tier2SubSeconds: int.tryParse(_twitchTier2Controller.text) ?? 600,
      tier3SubSeconds: int.tryParse(_twitchTier3Controller.text) ?? 1500,
      giftedSubSeconds: int.tryParse(_twitchGiftedController.text) ?? 300,
      resubSeconds: int.tryParse(_twitchResubController.text) ?? 60,
      countResubs: _twitchCountResubs,
    );

    // Build credentials map with string values
    final credentials = <String, String>{};

    if (twitchAdapter != null) {
      final adapterCreds = twitchAdapter.getCredentials();
      twitchAdapter.timeSettings = _twitchTimeSettings;

      // Copy auth credentials
      if (adapterCreds['accessToken'] != null) {
        credentials['accessToken'] = adapterCreds['accessToken'].toString();
      }
      if (adapterCreds['refreshToken'] != null) {
        credentials['refreshToken'] = adapterCreds['refreshToken'].toString();
      }
      if (adapterCreds['userId'] != null) {
        credentials['userId'] = adapterCreds['userId'].toString();
      }
      if (adapterCreds['userLogin'] != null) {
        credentials['userLogin'] = adapterCreds['userLogin'].toString();
      }
      if (adapterCreds['tokenExpiresAt'] != null) {
        credentials['tokenExpiresAt'] = adapterCreds['tokenExpiresAt'].toString();
      }
    }

    // Serialize time settings as JSON string
    credentials['timeSettingsJson'] = _serializeTimeSettings(_twitchTimeSettings);

    final config = ServiceConfig(
      serviceName: 'Twitch',
      enabled: _twitchEnabled,
      credentials: credentials,
    );

    await donationService.updateServiceConfig(config);

    if (mounted) {
      NesSnackbar.show(
        context,
        text: 'Twitch OK!',
        type: NesSnackbarType.success,
      );
    }
  }

  String _serializeTimeSettings(TwitchTimeSettings settings) {
    return '${settings.channelPointsSeconds},'
           '${settings.tier1SubSeconds},'
           '${settings.tier2SubSeconds},'
           '${settings.tier3SubSeconds},'
           '${settings.giftedSubSeconds},'
           '${settings.resubSeconds},'
           '${settings.countResubs ? 1 : 0}';
  }

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
}


/// Вкладка настройки таймера.
class TimerSettingsTab extends StatefulWidget {
  const TimerSettingsTab({super.key});

  @override
  State<TimerSettingsTab> createState() => _TimerSettingsTabState();
}

class _TimerSettingsTabState extends State<TimerSettingsTab> {
  final _rateController = TextEditingController();
  final _httpPortController = TextEditingController();
  final _wsPortController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final settings = donationService.settings;
    _rateController.text = settings.minutesPerAmount.toString();
    _httpPortController.text = settings.httpPort.toString();
    _wsPortController.text = settings.wsPort.toString();
  }

  @override
  void dispose() {
    _rateController.dispose();
    _httpPortController.dispose();
    _wsPortController.dispose();
    super.dispose();
  }

  Future<void> _saveTimerSettings() async {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final rate = double.tryParse(_rateController.text);
    final httpPort = int.tryParse(_httpPortController.text);
    final wsPort = int.tryParse(_wsPortController.text);

    if (rate == null || rate <= 0) {
      NesSnackbar.show(
        context,
        text: 'Invalid rate value',
        type: NesSnackbarType.error,
      );
      return;
    }

    if (httpPort == null || httpPort < 1 || httpPort > 65535) {
      NesSnackbar.show(
        context,
        text: context.read<LocalizationProvider>().tr('invalid_port'),
        type: NesSnackbarType.error,
      );
      return;
    }

    if (wsPort == null || wsPort < 1 || wsPort > 65535) {
      NesSnackbar.show(
        context,
        text: context.read<LocalizationProvider>().tr('invalid_port'),
        type: NesSnackbarType.error,
      );
      return;
    }

    final newSettings = donationService.settings.copyWith(
      minutesPerAmount: rate,
      httpPort: httpPort,
      wsPort: wsPort,
    );

    await donationService.updateSettings(newSettings);

    if (mounted) {
      NesSnackbar.show(
        context,
        text: context.read<LocalizationProvider>().tr('settings_saved'),
        type: NesSnackbarType.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localization = context.watch<LocalizationProvider>();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rate settings
          NesContainer(
            label: localization.tr('minutes_per_amount'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Сколько рублей = 1 час (60 минут)',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _rateController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: '600',
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            suffixText: 'RUB = 60 min',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Пример: при 600 → донат 600₽ = 60 мин, 1200₽ = 120 мин',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Port settings
          NesContainer(
            label: localization.tr('port_settings'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // HTTP Port
                  Text('${localization.tr('http_port')}:'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _httpPortController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: '8080',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // WebSocket Port
                  Text('${localization.tr('ws_port')}:'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _wsPortController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: '4040',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Save button
          NesButton.text(
            type: NesButtonType.success,
            text: localization.tr('save'),
            onPressed: _saveTimerSettings,
          ),
        ],
      ),
    );
  }
}


/// Вкладка настройки звуков.
class SoundsSettingsTab extends StatefulWidget {
  const SoundsSettingsTab({super.key});

  @override
  State<SoundsSettingsTab> createState() => _SoundsSettingsTabState();
}

class _SoundsSettingsTabState extends State<SoundsSettingsTab> {
  bool _soundEnabled = true;
  bool _randomSoundEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final donationService = context.read<DonationService?>();
    final soundService = context.read<SoundService?>();
    if (donationService == null) return;

    final settings = donationService.settings;
    _soundEnabled = settings.soundEnabled;
    _randomSoundEnabled = settings.randomSoundEnabled;
    
    // Sync with sound service if available
    if (soundService != null) {
      _soundEnabled = soundService.soundEnabled;
      _randomSoundEnabled = soundService.randomSoundEnabled;
    }
    
    setState(() {});
  }

  Future<void> _saveSoundSettings() async {
    final donationService = context.read<DonationService?>();
    final soundService = context.read<SoundService?>();
    if (donationService == null) return;

    final newSettings = donationService.settings.copyWith(
      soundEnabled: _soundEnabled,
      randomSoundEnabled: _randomSoundEnabled,
    );

    await donationService.updateSettings(newSettings);
    
    // Update sound service settings
    if (soundService != null) {
      soundService.soundEnabled = _soundEnabled;
      soundService.randomSoundEnabled = _randomSoundEnabled;
    }

    if (mounted) {
      NesSnackbar.show(
        context,
        text: context.read<LocalizationProvider>().tr('settings_saved'),
        type: NesSnackbarType.success,
      );
    }
  }

  Future<void> _refreshSounds() async {
    final soundService = context.read<SoundService?>();
    if (soundService != null) {
      await soundService.refreshSounds();
    }
    
    if (mounted) {
      final soundService = context.read<SoundService?>();
      final count = soundService?.soundCount ?? 0;
      NesSnackbar.show(
        context,
        text: '${context.read<LocalizationProvider>().tr('sounds_loaded')} ($count)',
        type: NesSnackbarType.success,
      );
    }
  }
  
  Future<void> _openSoundFolder() async {
    final soundService = context.read<SoundService?>();
    if (soundService != null) {
      await soundService.openSoundFolder();
    }
  }
  
  Future<void> _testSound() async {
    final soundService = context.read<SoundService?>();
    if (soundService != null) {
      await soundService.playSound();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localization = context.watch<LocalizationProvider>();
    final soundService = context.watch<SoundService?>();
    final soundCount = soundService?.soundCount ?? 0;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NesContainer(
            label: localization.tr('sounds'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sound enabled checkbox
                  Row(
                    children: [
                      NesCheckBox(
                        value: _soundEnabled,
                        onChange: (value) {
                          setState(() => _soundEnabled = value);
                        },
                      ),
                      const SizedBox(width: 12),
                      Text(localization.tr('sound_notification')),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Random sound checkbox
                  Row(
                    children: [
                      NesCheckBox(
                        value: _randomSoundEnabled,
                        onChange: _soundEnabled 
                            ? (value) {
                                setState(() => _randomSoundEnabled = value);
                              }
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        localization.tr('random_sound'),
                        style: TextStyle(
                          color: _soundEnabled ? null : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  
                  // Sound files info
                  Text(
                    '${localization.tr('sound_files')}: $soundCount',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),

                  // Buttons row
                  Row(
                    children: [
                      // Refresh sounds button
                      Expanded(
                        child: NesButton.text(
                          type: NesButtonType.normal,
                          text: localization.tr('refresh_sounds'),
                          onPressed: _soundEnabled ? _refreshSounds : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Open folder button
                      Expanded(
                        child: NesButton.text(
                          type: NesButtonType.normal,
                          text: localization.tr('open_folder'),
                          onPressed: _openSoundFolder,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  
                  // Test sound button
                  NesButton.text(
                    type: NesButtonType.normal,
                    text: localization.tr('test_sound'),
                    onPressed: _soundEnabled && soundCount > 0 ? _testSound : null,
                  ),
                  const SizedBox(height: 8),
                  
                  Text(
                    'Place .mp3, .wav, .ogg files in the "sound" folder',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Save button
          NesButton.text(
            type: NesButtonType.success,
            text: localization.tr('save'),
            onPressed: _saveSoundSettings,
          ),
        ],
      ),
    );
  }
}


/// Вкладка управления данными (сброс статистики, настроек, логирование).
class DataSettingsTab extends StatefulWidget {
  const DataSettingsTab({super.key});

  @override
  State<DataSettingsTab> createState() => _DataSettingsTabState();
}

class _DataSettingsTabState extends State<DataSettingsTab> {
  bool _loggingEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final donationService = context.read<DonationService?>();
    if (donationService != null) {
      _loggingEnabled = donationService.settings.loggingEnabled;
    }
    // Also sync with LogManager
    _loggingEnabled = LogManager.enabled;
    setState(() {});
  }

  Future<void> _saveLoggingSettings() async {
    final donationService = context.read<DonationService?>();
    if (donationService == null) return;

    final newSettings = donationService.settings.copyWith(
      loggingEnabled: _loggingEnabled,
    );

    await donationService.updateSettings(newSettings);
    LogManager.enabled = _loggingEnabled;

    if (mounted) {
      NesSnackbar.show(
        context,
        text: context.read<LocalizationProvider>().tr('saved'),
        type: NesSnackbarType.success,
      );
    }
  }

  Future<void> _resetStatistics(BuildContext context) async {
    final localization = context.read<LocalizationProvider>();
    
    final confirmed = await NesConfirmDialog.show(
      context: context,
      message: localization.tr('reset_statistics_confirm'),
      confirmLabel: localization.tr('reset'),
      cancelLabel: localization.tr('cancel'),
    );

    if (confirmed == true && context.mounted) {
      final donationService = context.read<DonationService?>();
      donationService?.clearStatistics();
      
      NesSnackbar.show(
        context,
        text: localization.tr('statistics_reset'),
        type: NesSnackbarType.success,
      );
    }
  }

  Future<void> _resetAllSettings(BuildContext context) async {
    final localization = context.read<LocalizationProvider>();
    
    final confirmed = await NesConfirmDialog.show(
      context: context,
      message: localization.tr('reset_all_confirm'),
      confirmLabel: localization.tr('reset'),
      cancelLabel: localization.tr('cancel'),
    );

    if (confirmed == true && context.mounted) {
      final donationService = context.read<DonationService?>();
      final timerProvider = context.read<TimerProvider?>();
      
      // Reset to default settings
      if (donationService != null) {
        await donationService.updateSettings(const AppSettings());
        donationService.clearStatistics();
      }
      
      // Reset timer
      timerProvider?.reset();
      
      NesSnackbar.show(
        context,
        text: localization.tr('all_reset'),
        type: NesSnackbarType.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localization = context.watch<LocalizationProvider>();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Logging settings
          NesContainer(
            label: localization.tr('logging'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      NesCheckBox(
                        value: _loggingEnabled,
                        onChange: (value) {
                          setState(() => _loggingEnabled = value);
                          LogManager.enabled = value;
                        },
                      ),
                      const SizedBox(width: 12),
                      Text(localization.tr('logging_enabled')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    localization.tr('logging_desc'),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  NesButton.text(
                    type: NesButtonType.normal,
                    text: localization.tr('save'),
                    onPressed: _saveLoggingSettings,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Statistics reset
          NesContainer(
            label: localization.tr('statistics'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    localization.tr('reset_statistics_desc'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  NesButton.text(
                    type: NesButtonType.warning,
                    text: localization.tr('reset_statistics'),
                    onPressed: () => _resetStatistics(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Full reset
          NesContainer(
            label: localization.tr('danger_zone'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    localization.tr('reset_all_desc'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  NesButton.text(
                    type: NesButtonType.error,
                    text: localization.tr('reset_all'),
                    onPressed: () => _resetAllSettings(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
