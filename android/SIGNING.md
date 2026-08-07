# Android 发布签名（TSINGCOOP / HIBI-2024）

## 密钥库信息（与本机 jks 一致）

| 项 | 值 |
|----|-----|
| 组织 | TSINGCOOP |
| 开发者 | BALE |
| 城市 | SHANGHAI |
| 国家 | CN |
| 应用名 | HIBI-2024（体现在证书 OU） |
| 有效期 | 100 年（36500 天） |
| 别名 | `hibi_2024_key` |
| 文件 | `hibi_2024_key.jks`（JKS，可后续迁移 PKCS12） |

证书 DN：`CN=BALE, OU=HIBI-2024, O=TSINGCOOP, L=SHANGHAI, ST=SHANGHAI, C=CN`

## 本机路径

- **JKS**：`C:\Users\a1306\Desktop\hibi-2024\android_KEY\hibi_2024_key.jks`
- **Gradle 配置**：`android/key.properties`（已在 `android/.gitignore`，勿提交）
- **APK 输出**：`flutter build apk --release` 后复制到  
  `C:\Users\a1306\Desktop\hibi-2024\LVvaovaoZ100B\HIBI-2024_release_signed.apk`

## 打包命令

```bash
flutter build apk --release
```

若未配置 `key.properties`，release 仍会用 debug 签名（仅本地调试用）。

## 安全

- **不要**把 `key.properties`、`.jks` 提交到 Git。
- 密钥库密码与密钥密码请仅在安全渠道保存；泄漏后需重做密钥并更换上架应用签名（同一 `applicationId` 下签名不一致将无法覆盖安装）。
