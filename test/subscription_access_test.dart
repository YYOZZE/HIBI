import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/profile/subscription_access_service.dart';

void main() {
  group('SubscriptionAccessService 助理权限', () {
    test('助理功能对全部用户放开：hasAssistantChatAccess 恒为 true', () async {
      expect(await SubscriptionAccessService.hasAssistantChatAccess(), isTrue);
      expect(
        await SubscriptionAccessService.hasAssistantChatAccess(
            forceRefresh: true),
        isTrue,
      );
    });

    test('主题设置权限保持放开', () async {
      expect(await SubscriptionAccessService.hasThemeSettingsAccess(), isTrue);
    });
  });
}
