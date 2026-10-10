# FnMusic for Mac

一个使用 SwiftUI、Swift Concurrency 和 AVFoundation 构建的**非官方飞牛音乐 macOS 原生客户端**。

FnMusic 直接连接用户提供的飞牛音乐服务器，读取真实的歌曲、专辑、艺人、歌单和封面数据；它不是网页套壳、Electron 应用，也不包含服务器、示例账号或内置音乐库。

> **项目状态**：个人开源项目，功能仍在持续验证中。当前没有提供公共演示服务器，也没有完成 Mac App Store 分发配置。使用前请确认你拥有目标服务器及媒体内容的访问权限。

## 功能概览

- 原生 macOS 界面：NavigationSplitView、可缩放窗口、浅色/深色模式、SF Symbols 和 Liquid Glass 风格回退。
- 主页、资料库、歌曲、专辑、艺人和服务器歌单浏览；支持分页、排序、独立搜索和键盘导航。
- AVPlayer 播放原文件流：播放/暂停、进度定位、音量、随机、循环、队列和系统媒体控制。
- AirPlay / 音频输出选择器，以及 macOS Now Playing 信息同步。
- 普通歌词、LRC 时间戳歌词和部分 JSON 歌词格式解析，支持高亮、滚动和点击跳转。
- 封面缓存、收藏、歌曲下载和播放列表操作。
- 登录会话保存在 Keychain；服务器地址、账号和必要的会话信息按账户隔离。
- 歌单创建、重命名、删除及歌曲增删属于**默认关闭的实验性写入功能**，需要在设置中显式开启并由用户逐次触发。

## 应用截图


## 系统要求

- macOS 14.0 或更高版本（Apple Silicon 与 Intel）。
- Xcode 26+ SDK；项目使用 Swift 6 language mode 和严格并发检查。
- 当前开发验证工具链为 Xcode 27.0 / Swift 6.4。部分 Liquid Glass 效果在较旧系统上会回退为系统材质。
- 无第三方 Swift Package、npm、CocoaPods 或额外播放器依赖。


## 快速开始

1. 克隆仓库并用 Xcode 打开 [FnMusic.xcodeproj](FnMusic.xcodeproj)。
2. 选择共享 Scheme `FnMusic`，运行目标选择 `My Mac`，按 `⌘R`。
3. 首次启动时输入飞牛音乐服务器的 **origin**，例如：

   ```text
   https://music.example.com:8443
   http://192.168.1.10:5666
   ```

4. 点击“测试连接”，再输入用户名和密码登录。
5. 登录后从主页、资料库或搜索入口开始浏览和播放。

客户端会自动请求 `/music/api/v1`，地址栏中不要附加 API 路径、token、用户名或密码。`/music/` 入口会被规范化为服务器 origin；其它反向代理子路径暂不支持。客户端拒绝 HTTP 重定向，请直接填写最终地址。

### 命令行构建

```bash
xcodebuild -project FnMusic.xcodeproj -scheme FnMusic \
  -configuration Debug -derivedDataPath .build/DerivedData build
```

## API 兼容性与证据边界

本项目API由官方网页端逆向得到，不包含后端实现。接口文档和实现以 `serverVersion 1.0.10` / `mediasrvVersion 0.8.43` 的验证范围为基础，不保证其它服务器版本、反向代理配置或权限模型完全兼容。

接口证据等级不等于所有版本都稳定；低证据等级的接口不会被当作当前成功证据。客户端也不会自动执行扫描、purge、管理、上传、改密或播放事件上报。

## 安全与隐私

- 密码只在登录期间使用并转换为 SHA-256，不持久化密码；会话 token、服务器 origin 和必要用户资料写入 Keychain。
- 默认使用 ephemeral `URLSession`，不使用系统 CookieStorage / URLCache；不绕过 TLS 验证，拒绝重定向。
- 不收集遥测，不把 token、Cookie、请求体或认证头写入 Debug 日志；Release 构建不启用 Debug API 日志。
- HTTP 仅为局域网兼容而保留，推荐始终使用 HTTPS。SHA-256 不能替代传输加密。
- 播放音频不作为离线缓存持久化；下载必须由用户在保存面板中明确选择目标位置。
- 本工程尚未启用 App Sandbox，也未配置 Mac App Store 分发；请在你自己的环境中评估权限和签名策略。


## 已知限制

- 未提供真实服务器或账号；本项目现有验证不能替代特定 NAS、代理、非空收藏/历史和写接口的验收。
- 音频格式兼容性由 macOS 决定；真实 NAS 上的 FLAC/MP3 Range 播放仍需自行验证。CUE 虚拟分轨、HLS 和转码会话暂不支持。
- 当前要求服务器正确返回音频 Range `206`；忽略 Range 并返回整文件 `200` 的服务端会被拒绝。
- 搜索、歌单分页和部分历史/收藏接口的服务端上限尚未完全确认。
- 队列不跨重启持久化；歌单封面上传、批量编辑、历史删除和跨用户共享管理尚未实现。
- authx 签名、OAuth、首次初始化、管理员能力、完整流派模型等未验证功能不会被客户端臆测实现。

## 工程结构

```text
FnMusic.xcodeproj/        Xcode 应用工程
FnMusic/
  App/                    应用状态、会话和依赖容器
  Core/                   网络、认证、Keychain 和图片缓存
  Models/                 API 实体和歌词解析
  Services/               目录、搜索、歌词和实验性写入
  Player/                 AVPlayer、Range 资源加载和播放队列
  ViewModels/             分页、连接、搜索和动作状态
  Views/                  macOS 原生页面、设置和播放器
  Resources/              Info.plist 和原创图标资源
```


## 许可证

本项目以 [MIT License](LICENSE) 开源，完整文本见仓库根目录的 [LICENSE](LICENSE) 文件。

## 免责声明

FnMusic 是非官方第三方客户端，与飞牛及其相关产品无隶属或背书关系。请遵守服务器软件、媒体内容和所在地区的许可条款，并在生产账号或重要资料库上谨慎启用实验性写入功能。
