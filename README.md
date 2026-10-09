# FnMusic for Mac

**Unofficial Fn Music Client** — 基于 SwiftUI、Swift Concurrency 与 AVFoundation 的 macOS 原生飞牛音乐客户端。

不是网页、Electron 或 WebView。默认只连接用户指定的真实服务器；歌曲、专辑、艺人、歌单与封面不使用内置示例数据。

## 系统与开发环境

- 部署目标：**macOS 14.0+**，Apple Silicon / Intel。
- Swift **6** language mode，严格并发检查。
- 构建需要 **Xcode 26+ SDK**（使用公开 Liquid Glass API）；当前验证工具链为 **Xcode 27.0 / Swift 6.4**。运行目标仍为 macOS 14+，旧系统走材质回退。
- 无第三方 Swift 包依赖，无需 npm、CocoaPods、后端重建或额外播放器程序。
- 本地开发使用 ad-hoc 签名，不需要把账号/服务器凭据写进工程。正式分发应配置自己的 Team、Developer ID、签名与公证；当前产物不是已公证的正式发行版。

## 打开与运行

1. 在 Xcode 打开 [FnMusic.xcodeproj](<FnMusic.xcodeproj>)。
2. 选择共享 Scheme **FnMusic**，目标 **My Mac**，按 **⌘R**。
3. 首次打开显示“连接服务器”。输入服务器 origin，例如 `https://music.example.com:8443` 或局域网 `http://192.168.1.10:5666`。
4. 点击“测试连接”，再输入用户名和密码并登录。
5. 默认进入“主页”。侧栏按“搜索 / 主页、资料库、播放列表”分组；广播、商店和 iTunes Store 已移除。点击“艺人”进入三栏浏览：中间选择艺人，右侧按专辑查看和播放歌曲；用户歌单始终来自服务器。风格、共享音乐库和播放历史保留在搜索框左侧选项按钮的“导航 → 其他资料库”中。

客户端自动拼接 `/music/api/v1`；不要在地址里附加 API 路径、token 或账号密码。`/music/` 入口地址可规范化为 origin；其它反向代理子路径尚不支持。重定向一律拒绝，请填写最终 origin。

```bash
xcodebuild -project FnMusic.xcodeproj -scheme FnMusic \
  -configuration Debug -derivedDataPath .build/DerivedData build

xcodebuild -project FnMusic.xcodeproj -scheme FnMusic \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test
```

**不要打开根目录原有的 Playgrounds 模板作为应用入口。** 原来的 [MyApp.swift](<MyApp.swift>)、[ContentView.swift](<ContentView.swift>) 与根目录旧 Assets 均保留，但不参与新 Xcode target。真实入口在 [FnMusicApp.swift](<FnMusic/App/FnMusicApp.swift>)。

## 功能

### 已实现

- 原生 NavigationSplitView / AppKit 侧栏、可缩放窗口、自适应专辑网格、浅/深色模式与 SF Symbols。
- 居中的 700×54 pt 紧凑悬浮胶囊播放器：macOS 26+ 使用原生 Liquid Glass，macOS 14–15 材质回退，尊重“降低透明度/减少动态效果”。点击歌曲查看完整进度，扬声器按钮弹出音量滑块；细进度线支持拖动。
- 原生 AVKit AirPlay/音频输出选择器，绑定实际 AVPlayer；未验证具体外部设备，兼容性取决于系统和设备。
- SHA-256 密码登录；32 位稳定 deviceId；Keychain 会话保存；启动 `/user/me` 验证恢复；401 / 99999 失效处理及退出。
- 系统配置、系统连接信息、初始化状态检测。未知状态按原始值处理，不猜权限枚举。
- 主页最近添加、专辑、艺人、歌曲、详情关联列表、动态歌单、收藏与历史。艺人页改为 206 pt 全局导航 + 300 pt 艺人目录 + 自适应专辑作品详情，不再使用大头像网格。
- 所有主页面/详情页统一 52 pt Liquid Glass 顶栏：左标题、右侧选项按钮和胶囊搜索框。排序、范围、刷新、视图切换、前进返回及设置入口均集中在该按钮内；⌘F 聚焦当前页面查找。
- 艺人目录支持选择、前进/返回、分页、独立搜索和键盘导航。合唱只按真实多艺人署名筛选已加载曲目，范围在顶部选项菜单切换。歌词/队列也使用相同工具栏，并保留 Escape 关闭。
- 专辑分组只包含当前艺人的曲目，使用真实类型/年份；歌曲行支持播放、收藏、下载、队列、歌单和更多操作。
- 风格接入 `/genre/list` 与 `/track/genre-detail/list`；保留未验证非空模型的原始 JSON，仅真实返回有效 GUID 才可进入歌曲列表，不使用 E 级 `/genre/detail`。
- 音乐库在顶部选项菜单切换“所有歌曲 / 共享音乐库”；共享库读取 list/detail，只读展示服务器配置，不猜测按库筛歌或管理接口。
- 歌单分组“＋”打开真实新建流程（仍受实验写入开关保护）；歌单区与歌单网格共享状态，新增/改名/删除后同步刷新。
- 常规列表每页 60，去重与重复页停止；歌单列表不伪造分页，批量详情每批 100 GUID。
- 四类独立搜索：歌曲/专辑/艺人/歌单；300ms debounce、结构化任务取消、客户端逐步展示已收到结果。
- AVPlayer 原文件流播放；播放/暂停、上一首/下一首、进度定位、音量、随机、单曲/列表循环、队列删除和下一首插入。
- AVAssetResourceLoader 将媒体请求交给统一 APIClient，检查 MIME、Range 206 和 Content-Range；媒体块最多 512 KiB；不访问服务器本地 `AudioSpec.path`。
- macOS Now Playing 文本/时长/进度及系统媒体控制；切换页面或最小化后继续播放。
- 普通歌词、LRC 多时间戳、offset、部分逐行 JSON `t/c/tx`、版本选择、高亮、滚动与点击跳转；无歌词空态。
- 封面 NSCache + 账户/服务器隔离磁盘缓存、160→600 渐进加载、取消、请求去重与失败重试。
- 收藏切换；歌单创建、重命名、删除、加歌、移歌：**默认关闭的实验性 H 级写操作**，显式启用后每次由用户触发，并检查业务码及读回。
- 设置：账户、服务器、默认音量、自动续播、循环、外观、缓存清理、实验功能及关于。

### 快捷键与操作

| 操作 | 快捷键 / 入口 |
|---|---|
| 搜索 | ⌘F |
| 播放 / 暂停 | Space；Playback 菜单 |
| 上一首 / 下一首 | ⌘← / ⌘→ |
| 歌曲选择 | ↑ / ↓ |
| 播放选中歌曲 | Enter |
| 设置 / 退出应用 | ⌘, / ⌘Q |
| 歌曲更多动作 | 原生右键菜单 |
| 侧栏折叠 | 顶部选项菜单中的“显示/隐藏侧栏” |

随机播放仅覆盖当前队列，不会为洗牌一次下载全库。添加到队列本身不会自动开始播放。

## API 来源与证据边界

唯一 API 输入是用户提供的 [FnMusicAPI.md](<FnMusicAPI.md>)，非官方逆向说明，文档验证范围为 `serverVersion 1.0.10` / `mediasrvVersion 0.8.43`。

- [API Endpoint Matrix](<Docs/APIEndpointMatrix.md>)：90 个 method/path 组合、87 条路径，包含权限、参数、响应、证据等级及拟用功能。
- [Feature → API Mapping](<Docs/FeatureAPIMapping.md>)：全部功能能力/延期策略。
- [架构与模型契约](<Docs/Architecture.md>)。
- [分阶段开发记录](<Docs/DevelopmentLog.md>)。
- [验证报告](<Docs/Verification.md>)。
- [新侧栏功能与 API 映射](<Docs/SidebarUpdate.md>)。
- [Liquid Glass 播放栏说明](<Docs/GlassPlayerUpdate.md>)。
- [艺人三栏重构、下载与验证说明](<Docs/ArtistPageRebuild.md>)。
- [全页面统一玻璃工具栏与搜索范围](<Docs/UnifiedToolbar.md>)。

**V 不等于全版本稳定；H/F/E 不会被当作当前成功证据。** JSON 成功接受文档约定 `[0, 200]`（200 本身仅 F 级）；HTTP 200 但业务码失败仍抛错，HTML 兜底页也不是成功。

### 实验性写入

在“设置 → 缓存与安全”手动启用并确认风险后，才能修改收藏/歌单。所有写入无自动重试，删除歌单需再次确认。先检查 JSON code，再用 metadata / 详情 / 关联列表读回。读回不确定时明确报告“请求已发送、状态未确认”，**不能据此断言没有产生修改**。

没有自动执行扫描、purge、任务控制、管理、上传、改密或播放事件上报。播放历史只展示服务器已存在的记录，本客户端暂不创建服务端播放历史。

## 安全与缓存

- 密码与 SHA-256 登录材料不持久化。仅会话 token、origin 和必要用户资料写 Keychain；普通偏好保存在 UserDefaults。
- 会话恢复不等于保存密码的静默重登录：token 过期必须重新输入密码。
- 默认 URLSession 为 ephemeral，无系统 CookieStorage / URLCache；Cookie 不进入 URL。重定向拒绝，不绕过 TLS 验证。
- HTTP 为局域网兼容而允许，界面明确提示明文风险；推荐 HTTPS。SHA-256 不能替代传输加密。
- Debug 日志仅 method、无 query 的 path、HTTP 状态和 business code；不打印请求体、token、Cookie、认证头、完整服务端错误正文或服务器本地路径。Release 无 Debug API 日志。
- 图片内存 64 MB / 256 张；磁盘每账户 200 MB；解码离开主 actor。清理前校验目标是本应用的具体 namespace，拒绝 symlink 跳转。
- 详情 JSON：按 client 会话隔离、最多 48 项 / 8 MB，歌曲 15 秒、专辑/艺人 20 秒；写入后失效，读回始终走网络。
- 搜索最多 12 个关键词、30 秒；过大结果不缓存。图片响应最多 20 MB、JSON 最多 32 MB，超限报错。音乐流不持久化。
- 登出停止播放器、关闭旧 transport、清除钥匙串和当前账户封面；服务器注销失败会如实提示。
- 本工程为本地原生开发配置，**未启用 App Sandbox，也未完成 Mac App Store 分发配置**。无需全盘访问/辅助功能授权。

## 已知限制与 TODO

1. **未提供真实服务器或账号，本次没有端到端真实服务器联调。** 本地测试通过不证明特定 NAS、反向代理、非空收藏/历史或 H 级写接口可用。请按验证报告完成授权实例验收；勿在现有重要库上自动跑写入测试。
2. 原生播放器格式支持由 macOS 决定。已验证本地 WAV 解码链；文档提供 FLAC/MP3 Range 样本，但本客户端尚未在真实 NAS 上验证这些格式。CUE 虚拟分轨、HLS、转码生命周期均明确延期，不静默建立转码会话。
3. 当前严格要求音频 Range 206。忽略 Range 返回整文件 200 的服务器会被拒绝，不下载整曲到内存作为隐式降级。系统 Now Playing 尚未附带封面。
4. “最近 3/6 个月”按专辑记录 `createdAt` 分组，**不是最近往现有专辑加入歌曲的时间**；API 只确认 `newTrackAddedAt` 可排序，未确认对应响应字段。分组覆盖已加载数据，未知时间单独展示。
5. 搜索 page/size 未验证有效，仅展示服务端实际结果；可能存在隐藏结果上限。歌单列表分页、非空收藏/历史等也存在文档证据限制。
6. 按最新要求移除广播、商店及 iTunes Store，不保留空分组或占位页。不硬编码 ACG：只有服务器实际存在的歌单才显示。
7. TODO: API 未确认 — OAuth、首次初始化操作、管理员成功模型、真实流派模型、任务控制等，不实现臆测 API。
8. authx 未启用：文档中只读/登录/退出不带签名成功；部分写入或未来服务器若要求签名会失败，不承诺免签永久有效。
9. 歌词服务端 offset 正负语义待校准；当前采用 LRC 正值提前约定，仅本地展示，不上报。未知富文本结构保留文字或降级，未完整实现逐字卡拉 OK。
10. 支持用户明确选择保存位置的单曲原文件下载（Range 分段、原子提交），不是自动离线缓存或内置离线音乐库。CUE 暂不下载，未知格式使用 `.audio` 名称提示，符号链接保存路径会被拒绝。队列不跨重启持久化；歌单上传封面、批量编辑、历史删除和跨用户共享管理未实现。
11. 部分操作采用共享参数化详情页/TrackList，而非复制多份几乎相同的 View。测试夹具仅存在 Tests，不会进入生产 target。

## 测试

测试覆盖 JSON 业务失败、HTML 兜底、null 响应、会话失效、参数大小写、模型可空字段、SHA-256、Range、分页/取消竞态、歌词、队列、艺人分组/合唱/搜索/历史，以及下载完整字节、取消、原文件保护和目标变更。Debug 的 XCTest 宿主启动不会恢复真实 Keychain/NAS 会话；测试使用注入客户端。

播放集成测试使用内存生成的静音 PCM WAV 和注入的本地 URLProtocol，验证 AVPlayer 解码、播放进度、暂停、定位、恢复以及错误路径。没有访问真实服务器，也不会修改用户资料库。

UI 测试通过真实 NSHostingView/NSWindow 渲染连接页和 820 / 1280 点资料库布局，快照写入 `.build/Snapshots`。音乐库截图上的“布局测试专辑”和“UI 测试账户”是**测试专用数据**，不能作为服务器联调证据。

## 工程结构

```text
FnMusic.xcodeproj/        原生 application + XCTest targets
FnMusic/
  App/                   应用、会话、依赖容器
  Core/                  统一网络、认证、Keychain、图片缓存
  Models/                Codable API 实体与歌词解析
  Services/              只读目录、搜索、歌词、实验性写入
  Player/                AVPlayer、Range资源加载、队列、系统媒体控制
  ViewModels/            分页、连接、搜索、歌词与动作状态
  Views/                 macOS原生侧栏、网格、详情、设置与播放器
  Resources/             Info.plist、原创图标Asset Catalog
Tests/                   单元测试、本地媒体集成与UI快照
Docs/                    契约矩阵、架构、阶段记录与验证说明
Tools/generate_icon.py   原创几何耳机图标生成源（运行需Pillow）
```

应用图标为项目原创几何图案，没有复用 Apple Music Logo、商业封面或参考截图素材。
