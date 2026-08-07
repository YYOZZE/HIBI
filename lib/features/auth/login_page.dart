import 'package:flutter/material.dart';
import '../../app/frosted_background.dart';
import '../../config/api_config.dart';
import 'auth_form_styles.dart';
import 'register_page.dart';
import 'services/auth_repository.dart';
import 'services/auth_captcha_platform.dart';
import 'services/graph_captcha_service.dart';
import 'services/http_auth_api.dart';

/// 登录页：与主壳 FrostedBackground + 浅前景色统一；毛玻璃卡片内表单，简约
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _lotNumberController = TextEditingController();
  final _captchaOutputController = TextEditingController();
  final _passTokenController = TextEditingController();
  final _genTimeController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  bool _captchaRequired = false;
  String _captchaAppId = '';
  String _captchaSdkUrl = '';
  bool _captchaPassed = false;
  String _captchaChallengeId = '';

  String get _captchaPlatform => authCaptchaPlatformForDevice();

  @override
  void initState() {
    super.initState();
    if (ApiConfig.isAuthApiConfigured) {
      AuthRepository.instance.authApi = HttpAuthApi(baseUrl: ApiConfig.authApiBaseUrl);
      _checkCaptchaConfig();
    }
  }

  Future<void> _checkCaptchaConfig() async {
    final api = AuthRepository.instance.authApi;
    if (api == null) return;
    try {
      final cfg = await api.getCaptchaConfig(platform: _captchaPlatform);
      if (!mounted) return;
      setState(() {
        _captchaRequired = cfg?['configured'] == true;
        _captchaAppId = (cfg?['app_id'] ?? '').toString();
        _captchaSdkUrl = (cfg?['sdk_url'] ?? '').toString();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _lotNumberController.dispose();
    _captchaOutputController.dispose();
    _passTokenController.dispose();
    _genTimeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _loading) return;
    if (_captchaRequired && _captchaChallengeId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先完成图形认证')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthRepository.instance.login(
        _accountController.text.trim(),
        _passwordController.text,
        captchaPlatform: _captchaPlatform,
        captchaChallengeId: _captchaChallengeId,
        lotNumber: _lotNumberController.text.trim(),
        captchaOutput: _captchaOutputController.text.trim(),
        passToken: _passTokenController.text.trim(),
        genTime: _genTimeController.text.trim(),
      );
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        return;
      }
    } catch (e) {
      if (_captchaRequired) {
        setState(() {
          _captchaPassed = false;
          _captchaChallengeId = '';
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runCaptcha() async {
    if (_loading || !_captchaRequired) return;
    final api = AuthRepository.instance.authApi;
    if (api == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('认证服务未初始化')),
      );
      return;
    }
    if (!GraphCaptchaService.isSupported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前端暂不支持图形认证弹窗')),
      );
      return;
    }
    try {
      final challenge = await api.createCaptchaChallenge(platform: _captchaPlatform);
      if (!mounted) return;
      final challengeId = (challenge?['challenge_id'] ?? '').toString().trim();
      final appId = (challenge?['app_id'] ?? _captchaAppId).toString().trim();
      final sdkUrl = (challenge?['sdk_url'] ?? _captchaSdkUrl).toString().trim();
      if (challengeId.isEmpty) {
        throw Exception('图形认证挑战创建失败');
      }
      final res = await GraphCaptchaService.verify(
        appId: appId,
        sdkUrl: sdkUrl,
        context: context,
        captchaPlatform: _captchaPlatform,
      );
      if (res == null || !mounted) return;
      final ok = await api.verifyCaptchaChallenge(
        challengeId: challengeId,
        platform: _captchaPlatform,
        lotNumber: res.lotNumber,
        captchaOutput: res.captchaOutput,
        passToken: res.passToken,
        genTime: res.genTime,
      );
      if (!ok) {
        throw Exception('图形认证校验失败');
      }
      if (!mounted) return;
      _lotNumberController.text = res.lotNumber;
      _captchaOutputController.text = res.captchaOutput;
      _passTokenController.text = res.passToken;
      _genTimeController.text = res.genTime;
      setState(() {
        _captchaPassed = true;
        _captchaChallengeId = challengeId;
        if (appId.isNotEmpty) _captchaAppId = appId;
        if (sdkUrl.isNotEmpty) _captchaSdkUrl = sdkUrl;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图形认证通过，请继续提交登录')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final existingUser = AuthRepository.instance.currentUser;
    if (existingUser != null) {
      // 已登录仍进入登录页时：提供返回，避免重复登录
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const FrostedBackground(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (Navigator.of(context).canPop())
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    const Spacer(),
                    Text(
                      '当前已登录',
                      style: theme.textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      existingUser.displayName,
                      style: theme.textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回'),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (Navigator.of(context).canPop())
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        color: colorScheme.onSurface,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: DecoratedBox(
                          decoration: AuthFormStyles.glassPanel(context),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                            child: Form(
                              key: _formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    '欢迎使用希比',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall?.copyWith(
                                      color: colorScheme.onSurface,
                                      fontWeight: FontWeight.w400,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '登录以同步数据',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  TextFormField(
                                    controller: _accountController,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '手机号 / 邮箱',
                                      hint: '请输入',
                                      prefixIcon: Icon(Icons.person_outline, color: colorScheme.onSurfaceVariant),
                                    ),
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    validator: (v) {
                                      if (v == null || v.trim().isEmpty) return '请输入账号';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _passwordController,
                                    obscureText: _obscurePassword,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '密码',
                                      hint: '请输入',
                                      prefixIcon: Icon(Icons.lock_outline, color: colorScheme.onSurfaceVariant),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                          color: colorScheme.onSurfaceVariant,
                                          size: 20,
                                        ),
                                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                      ),
                                    ),
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _submit(),
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return '请输入密码';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 28),
                                  if (_captchaRequired) ...[
                                    Text(
                                      '提交前请完成图形验证',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    OutlinedButton.icon(
                                      onPressed: _loading ? null : _runCaptcha,
                                      icon: const Icon(Icons.verified_user_outlined, size: 20),
                                      label: Text(_captchaPassed ? '已通过（可重新验证）' : '开始图形验证'),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _captchaPassed ? '认证状态：已通过' : '认证状态：未完成',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: _captchaPassed ? Colors.greenAccent : colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  FilledButton(
                                    onPressed: _loading ? null : _submit,
                                    style: AuthFormStyles.primaryButton(context),
                                    child: _loading
                                        ? SizedBox(
                                            height: 22,
                                            width: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimary),
                                            ),
                                          )
                                        : const Text('登录'),
                                  ),
                                  const SizedBox(height: 20),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '还没有账号？',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _loading
                                            ? null
                                            : () {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) => const RegisterPage(),
                                                  ),
                                                );
                                              },
                                        child: const Text('去注册'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
