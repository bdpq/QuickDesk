# quickdesk_android

QuickDesk Android 客户端（Flutter）：主控（控制桌面端/其它设备）与被控（被桌面端控制）双向。
代码覆盖 M1（主控跑通）、M2（主控完善）、M3（被控镜像）、M4（被控输入），待真机联调。

技术方案见 [`docs/dev/Android客户端技术方案.md`](../docs/dev/Android客户端技术方案.md)。

## 目录结构

```
lib/
├── main.dart                    # 入口（WebRTC field trial 注入 + 主题/语言）
├── core/                        # 公共工具：app_settings（服务器配置）/ rand_id / geometry
├── api/
│   ├── signaling_http.dart      # REST 公共层（ws→http、鉴权头、请求模板、ICE 解析）
│   ├── signaling_api.dart       # 主控 REST（access-code:verify / ice-config）
│   └── host_api.dart            # 被控 REST（provision / heartbeat / signal-tokens / access-code）
├── protocol/                    # 纯 Dart 协议栈（与 WebClient/js 对齐，可独立单测）
│   ├── auth/                    #   SPAKE2（edwards25519 + 认证状态机，Alice/Bob 双角色）
│   ├── proto/                   #   wire（protobuf 原语）+ Chromium Remoting 消息编解码
│   ├── signaling/               #   Jingle XML builder/parser + WS 传输（{client_id,payload} 封装）
│   ├── peer/                    #   会话公共构件：串行队列 / candidate 缓冲 / PC 工厂
│   ├── client_session.dart      #   主控端会话状态机（flutter_webrtc）
│   ├── host_session.dart        #   被控端会话状态机（Jingle responder + SPAKE2 Bob，两次协商）
│   ├── datachannel_handler.dart #   event/control DataChannel（client/host 角色共用）
│   ├── file_transfer.dart       #   文件传输（file_transfer.proto，独立 DataChannel）
│   └── host_input.dart          #   被控端输入事件模型
├── controller/                  # UI：连接页/被控页/首页 + 触控/键码/剪贴板/统计/历史
│   └── remote/                  #   远程桌面页（主页面/工具条/统计面板/传输弹层/光标）
├── host/                        # 被控端桥接：屏幕采集 / 输入注入 / 凭据 / 总控
├── l10n/                        # 轻量中英 i18n
└── theme/                       # Fluent 风格主题
```

被控端原生（Kotlin，`android/app/src/main/kotlin/...`）：屏幕采集前台服务、无障碍输入注入、
Shizuku 增强档（AIDL UserService + `injectInputEvent` 反射）、USB→Android 键码映射。

## 开发环境

- Flutter SDK stable 3.44+
- **JDK 17**：GraalVM / JDK 21 与 AGP 的 jlink 变换不兼容，需 `flutter config --jdk-dir "<jdk17>"` 指定
- Android SDK：platform-tools + platforms;android-36 + build-tools;36.0.0（NDK 由 Gradle 自动安装）
- 已内置 `compileSdk 36` / `minSdk 24`（插件依赖与被控输入 API 要求）

常用命令（在本目录执行）：

```bash
flutter pub get
flutter analyze            # 静态分析
flutter test               # 协议层单元测试（SPAKE2 / protobuf / Jingle）
flutter build apk --debug  # 构建 APK（产物在 build/app/outputs/flutter-apk/）
```

官方信令服务器 API Key 可在构建时注入，未注入时默认为空：

```bash
flutter build apk --release --dart-define=QUICKDESK_API_KEY=your-secret-key
```

> 注意：本工程不要放在网络映射盘（SMB/UNC 路径）上构建，Gradle/ninja/Kotlin
> 增量编译均无法在网络盘上正常工作。请将仓库克隆/复制到本地磁盘再构建。

## 使用

首页底部切换「主控 / 被控」：

- **主控**：填对端「设备 ID + 访问码」连接；服务器地址在「服务器设置」里配置。
  若服务器开启了 API-Key/Origin 保护，需在「API Key」填入服务器的 `QUICKDESK_API_KEY`
  （否则 REST 校验返回 FORBIDDEN）。服务器地址必须使用可信证书的 `wss://`。
- **被控**：点「开启被控」，依次引导开启无障碍服务、授权屏幕采集，随后展示本机
  设备 ID + 访问码供其他端连入。输入默认走无障碍档；装并授权 Shizuku 后自动切增强档。

### 自定义固定访问码

被控页「设备 ID / 访问码」卡片上有两个图标：

- **铅笔**：把访问码改成自己指定的 **6 位数字**（`000000` 也合法）。保存时先
  `PUT /v1/devices/:id/access-code` 上报服务器，成功后才写入本地 `shared_preferences`，
  避免离线时两端码不一致；下次开启被控即用新码做 SPAKE2 密钥派生。
- **刷新**：重新生成一个随机 6 位码，链路与上面相同。

两个操作都要求**先停止被控**（在线/连接中/采集中按钮会置灰），且并发调用会被
`_updatingAccessCode` 挡住。安卓端本来就没有定时刷新，所以自定义码天然长期有效；
Windows 端保存自定义码会把「访问码自动刷新」强制切到「永不」，两者行为一致。

> 固定 6 位数字只有 100 万种组合，服务器虽有防爆破限流，仍建议只在家庭/内网/
> 自托管环境使用；公网环境请保留随机码并定期刷新。

### 远程页输入模式

工具条的**手指图标**切换两种模式（选择会记到本机偏好，下次进入远程页自动恢复）：

- **触控板模式（默认）**：对齐 RustDesk 手机「鼠标模式」——单指滑动移动虚拟光标，
  轻点是在**光标当前位置**点击；双击、长按、拖拽、双指滚轮与缩放见工具条 ❓ 指南。
- **直接触摸模式**：单指按下先把光标定位到手指下的远程像素，轻点即「点哪点哪」；
  双击、长按右键、拖拽同样从手指位置开始。缩放、平移、letterbox 黑边都参与坐标换算，
  多显示器时自动叠加显示器原点。显式「拖拽就绪」状态下仍从原光标起拖，
  避免覆盖用户已经准备好的起点。
- **放大后拖动**（直接触摸模式）：双指捏合放大到 >1x 后，单指拖动改为 1:1 平移画面
  （与手机看放大照片一致），不移动远端鼠标、不触发点击或拖拽；轻点仍先定位手指下的远程像素再点击。
  平移幅度受放大后内容边界约束。放大状态下想拖远程窗口，先点工具条「拖拽」进入拖拽就绪再滑动
  （此时按住左键且不平移）；「双击后拖动」在放大状态下让位于平移，避免连续拖动浏览时误按住远程左键。
  触控板模式仍是拖光标 + 自动跟镜，点「适应屏幕」回到 1x 后两种模式都恢复原有手势。

两种模式发送的仍是 Chromium Remoting 的 `MouseEventMsg`（绝对坐标鼠标事件），
不是 Windows 原生触摸事件，因此依旧没有多点触控、压感或触摸键盘自动弹出。

## 真机联调关注点（尚未验证）

- 被控端与 Qt 桌面端 / WebClient 的两次协商互通
- Android 14 MediaProjection 前台服务时序、锁屏终止投影
- Shizuku `injectInputEvent` 在不同 ROM/版本的兼容性
- 旋转后主控端坐标对齐

## 账户、设备与收藏

首页新增「账户」页：沿用服务器设置，支持密码/SMS 登录、注册、会话恢复、
我的设备、云端收藏及云端历史查询。修改服务器配置后需点「保存」；账户令牌
使用安全存储并按服务器配置隔离，不会转移到另一台服务器。

请配置 `wss://` / `https://`；Release 构建不允许明文服务器。账户登录不等于
绑定本机：需开启被控完成注册后，在账户页明确确认本机 ID、账户、服务器及归属转移。
Host 凭据按服务器/API key 隔离；旧无来源凭据不迁移，升级后首次开启被控会生成新 ID。
退出时本地账户缓存立即清空；网络不可达时会提示服务端撤销未确认。

三端设备/收藏排序规则及尚未对齐项见
[App 账户设备功能对齐](../docs/dev/App账户设备功能对齐.md) 和
[排序契约](../docs/dev/Device-list-ordering.md)。

连接尝试会按当前账户/服务器记录成功、失败及已连接时长；未登录不写云记录。
后端不支持幂等键，网络/5xx 的不确定提交不自动重试，离线或进程退出可能丢记录。
忘记密码沿用服务器 preset 配置的 WebClient 页面，确认地址后由外部浏览器打开。
