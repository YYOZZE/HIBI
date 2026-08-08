import 'package:flutter/material.dart';
import '../../app/frosted_background.dart';
import '../../config/api_config.dart';
import 'auth_form_styles.dart';
import 'services/auth_repository.dart';
import 'services/auth_captcha_platform.dart';
import 'services/graph_captcha_service.dart';
import 'services/http_auth_api.dart';

/// 注册页：无 AppBar（避免 Windows 等端标题栏黑底），顶部用 Stack 自定义返回栏 + 标题，与背景一体
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _inviteController = TextEditingController();
  final _lotNumberController = TextEditingController();
  final _captchaOutputController = TextEditingController();
  final _passTokenController = TextEditingController();
  final _genTimeController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
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
    _confirmController.dispose();
    _nicknameController.dispose();
    _inviteController.dispose();
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
      await AuthRepository.instance.register(
        phoneOrEmail: _accountController.text.trim(),
        password: _passwordController.text,
        nickname: _nicknameController.text.trim().isEmpty ? null : _nicknameController.text.trim(),
        inviteCode: _inviteController.text.trim().isEmpty ? null : _inviteController.text.trim(),
        captchaPlatform: _captchaPlatform,
        captchaChallengeId: _captchaChallengeId,
        lotNumber: _lotNumberController.text.trim(),
        captchaOutput: _captchaOutputController.text.trim(),
        passToken: _passTokenController.text.trim(),
        genTime: _genTimeController.text.trim(),
      );
      if (!mounted) return;
      // 已在主壳内：关闭注册页（及下层登录页若有）
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).popUntil((route) => route.isFirst);
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
        const SnackBar(content: Text('图形认证通过，请继续提交注册')),
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
                // 自定义顶栏：透明底，无 Material AppBar 黑条
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        color: colorScheme.onSurface,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          '注册',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48), // 与左侧 IconButton 对称
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: DecoratedBox(
                          decoration: AuthFormStyles.glassPanel(context),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                            child: Form(
                              key: _formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TextFormField(
                                    controller: _inviteController,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '邀请码',
                                      hint: '选填',
                                      prefixIcon: Icon(Icons.vpn_key_outlined, color: colorScheme.onSurfaceVariant),
                                    ),
                                    textInputAction: TextInputAction.next,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _accountController,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '手机号 / 邮箱',
                                      hint: '用于登录',
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
                                      hint: '至少 6 位',
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
                                    textInputAction: TextInputAction.next,
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return '请输入密码';
                                      if (v.length < 6) return '密码至少 6 位';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _confirmController,
                                    obscureText: _obscureConfirm,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '确认密码',
                                      hint: '再次输入',
                                      prefixIcon: Icon(Icons.lock_outline, color: colorScheme.onSurfaceVariant),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                          color: colorScheme.onSurfaceVariant,
                                          size: 20,
                                        ),
                                        onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                                      ),
                                    ),
                                    textInputAction: TextInputAction.next,
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return '请确认密码';
                                      if (v != _passwordController.text) return '两次密码不一致';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _nicknameController,
                                    decoration: AuthFormStyles.inputDecoration(
                                      context,
                                      label: '昵称',
                                      hint: '选填',
                                      prefixIcon: Icon(Icons.badge_outlined, color: colorScheme.onSurfaceVariant),
                                    ),
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _submit(),
                                  ),
                                  const SizedBox(height: 24),
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
                                    const SizedBox(height: 14),
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
                                        : const Text('注册'),
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
