# 传输功能 · 发现服务问题与方案说明

## 一、问题现象

- **Windows 端**：进入传输页后「附近设备」为空，控制台出现 `SocketException: Failed to create datagram socket (OS Error: ... errno = 10013), address = 0.0.0.0, port = 62637`。
- **手机端**：同一 WiFi 下可正常发现设备；Windows 端无法发现手机，手机也看不到 Windows 设备。

## 二、原理简述

### 2.1 发现协议（基于 LANDrop）

- 使用 **UDP 62637** 在局域网内广播/接收设备信息（JSON：`device_name`、`device_type`、`port` 等）。
- 接收端用 **TCP 动态端口**（如 56457）接收文件/文本；发现时广播的是该 TCP 端口，对方连接此端口发送数据。

### 2.2 为何 Windows 上容易出问题

1. **防火墙**  
   未放行时，系统禁止绑定 UDP 62637 或收发该端口流量，报错 **errno 10013 (WSAEACCES)**。需同时放行**入站 + 出站**，或直接允许本应用通过防火墙（专用网络）。

2. **系统保留端口**  
   Windows 会为 Hyper-V、WSL 等保留一段 UDP 端口。若 62637 落在保留范围内，即使防火墙已放行也无法绑定，同样报权限/访问错误。

3. **发现失败不弹窗**  
   错误仅在传输页内以提示条展示，不自动弹窗，避免一打开 App 就打断用户。

## 三、最终处理方案

### 3.0 跨版本与 Android 兼容（V3.0.9）

- 发现协议不再依赖 App 显示版本或 `device_type` 名称，只要传输协议兼容即可互通。
- 新版同时监听/广播当前 **62637–62639** 与早期 **52637–52639**，并保留用户自定义发现端口。
- 每次设备广播都更新最新 IP、TCP 接收端口与最后在线时间；10 秒未再出现的设备自动从列表移除，避免连接陈旧端口。
- Android 获取 Wi-Fi multicast lock，降低部分厂商系统过滤局域网广播的问题；App 进入后台时释放、恢复前台时重新获取。
- 主动刷新在短时间内发送三次请求，对端除广播外还会按 `reply_port` 单播回复，改善“PC 能看到手机、手机看不到 PC”的非对称发现。
- 私网广播增加 10.x、172.16–31.x 的 `/24` 定向广播地址，改善企业 Wi-Fi、手机热点和非 192.168 网段发现。
- TCP 连接使用 8 秒超时，首次失败后短延迟自动重试一次，并显示目标 IP/端口用于排障。

### 3.1 端口回退（62637 → 62638 → 62639）

- 发现服务启动时**依次尝试**绑定 62637、62638、62639，任一成功即用该端口。
- 广播时向**三个端口都发**，保证使用回退端口的设备也能互相发现。
- 防火墙脚本为 62637/62638/62639 **都**添加入站、出站规则。

### 3.2 防火墙一键修复

- **一键执行**：将完整脚本写入临时 `.bat`，通过 PowerShell `Start-Process -Verb RunAs` 以管理员身份运行，触发 UAC 后自动添加规则（UDP 三端口 + 本程序入站/出站）。
- **复制命令**：在「详情」弹窗中提供整段 CMD 脚本，支持一键复制，便于用户手动以管理员 CMD 执行。
- 执行完成后需**点击「重试发现」或重启应用**，发现服务才会重新绑定端口。

### 3.3 传输页内提示与操作

- 发现失败时仅在**传输页**「附近设备」上方展示信息条（非整屏红、不自动弹窗）。
- 提供入口：**详情**（完整说明 + 脚本 + 复制/一键执行）、**重试发现**、**一键执行**、**检查端口**（诊断 62637 是否在系统保留范围内）。

### 3.4 通过 IP 发送（发现不可用时的兜底）

- 用户可手动输入对方 **IP + 接收端口**（即对方界面上的「本机接收端口」），不依赖发现服务即可发送文件/文本。

## 四、相关代码位置

| 内容           | 路径 |
|----------------|------|
| 发现服务与端口回退 | `lib/features/transfer/service/lan_discovery_service.dart` |
| 防火墙脚本与一键执行 | `lib/features/transfer/transfer_page.dart`（`_fullFirewallScript`、`_runFirewallScriptAsAdmin`） |
| 传输页提示与按钮   | `lib/features/transfer/transfer_page.dart`（发现错误卡片、详情弹窗） |
| 设备模型         | `lib/features/transfer/models/transfer_device.dart` |

## 五、附近设备图标

发现广播中增加 `platform` 字段（`windows` / `android` / `ios` / `ipad`），接收端据此在「附近设备」列表及选择设备弹窗中显示对应图标：

- **windows** → 电脑图标
- **android** → 手机图标（Android）
- **ios** → 手机图标（iPhone）
- **ipad** → 平板图标（iPad，由 iOS 端根据最短边 ≥ 600 判定）

实现位置：`TransferDevice.platform`、`LanDiscoveryService` 广播/解析、`transfer_page.dart` 中 `_deviceIcon(TransferDevice)`。

## 六、接收与传输记录

### 6.1 接收空文件修复

- **原因**：接收 body 曾用 broadcast 流，用户点「接受」后才订阅；broadcast 不会给后订阅者补发已发生的数据，导致写入 0 字节。
- **方案**：在 `transfer_server.dart` 改为**内存缓冲**：用 `List<Uint8List> bodyChunks` 收集 body（首包 restBytes + 后续 socket 数据），用 `Completer<void> bodyComplete` 在 socket `onDone` 时完成；点「接受」时调用 `_acceptWithBuffer`，先 `await bodyComplete` 再按 chunks 顺序写入文件。

### 6.2 接收进度与传输记录

- **接收进度**：待接收文件卡片上始终显示进度条 + 文案「接收中 X%」/「已接收 100%」；服务端在接收时按已收长度 / totalSize 推送进度。
- **接收也记传输记录**：`TransferRecord` 增加 `isReceive`；收到文件点「接受」或收到文本点「复制文字」后，在传输记录中插入一条（显示为「← 来自 对方设备名」）；发出仍为「→ 对方设备名」。

相关代码：`lib/features/transfer/transfer_server.dart`（缓冲与 `_acceptWithBuffer`）、`lib/features/transfer/transfer_page.dart`（进度展示、记录插入、`TransferRecord.isReceive`）。

---

## 七、用户侧操作小结

1. 若发现服务未启动：在传输页按提示点 **「一键执行」**，在 UAC 中确认后等待 CMD 执行完成。
2. 执行完成后点 **「重试发现」** 或关闭并重新打开应用。
3. 若仍失败：点 **「检查端口」** 查看 62637 是否在保留范围；若是，可重启电脑或关闭 Hyper-V/WSL 后再试。
4. 不依赖发现时：使用 **「通过 IP 发送」**，输入对方 IP 与「本机接收端口」即可传输。
