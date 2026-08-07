/// 阿里云图形认证（Alicom4）成功后回传的四字段，供登录/注册与 [verifyCaptchaChallenge] 使用。
class GraphCaptchaResult {
  const GraphCaptchaResult({
    required this.lotNumber,
    required this.captchaOutput,
    required this.passToken,
    required this.genTime,
  });

  final String lotNumber;
  final String captchaOutput;
  final String passToken;
  final String genTime;
}
