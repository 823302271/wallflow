# Wallflow

[English](README.md) | [简体中文](README.zh-CN.md)

Wallflow 是一个处于早期开发阶段的 macOS 原生交互式壁纸渲染器。目前的原型重点是以较低的 CPU、内存和能耗运行原生视频与 Metal 动画，并逐步兼容 Wallpaper Engine 的网页和场景壁纸。

> [!IMPORTANT]
> Wallflow 仍在持续开发，尚未完整兼容 Wallpaper Engine。导入项目前，请先查看下方的兼容性说明。

## 环境要求

- macOS 13 Ventura 或更高版本
- Swift 5.10 或更高版本（Xcode 或 Apple Command Line Tools）
- Apple 芯片 Mac；项目明确不支持 Intel 和 Universal 通用架构构建

## 当前原型功能

- 为每台显示器创建 AppKit 桌面层级窗口
- 使用 Metal 渲染动画，不在 CPU 侧进行粒子模拟
- 全局跟踪鼠标，同时不拦截桌面点击
- 平滑的鼠标视差、弯曲线条和交互波纹
- 交互时自适应为 60 FPS，空闲时降低为 24 FPS
- 使用 75% 逻辑渲染比例，降低 Retina 显示器的像素填充开销
- 使用双缓冲 Metal 交换链，减少默认三缓冲带来的内存占用
- 前台窗口完全覆盖某台显示器时暂停该显示器的渲染
- 系统睡眠或登录会话非活动时自动暂停
- 显示器变化时增量复用已有渲染器，不重启仍连接的屏幕
- 全屏和 Space 切换期间使用 Wallflow 静态帧作为系统桌面回退
- 菜单栏暂停和继续控制
- 默认在其他应用有可见窗口时暂停，并提供菜单开关
- 可在 English 与简体中文之间即时切换界面语言
- 通过 AVFoundation 原生播放 MP4、M4V 和 MOV
- 可从视频、目录、`project.json`、`index.html` 或 `scene.pkg` 导入项目

## 原生视频壁纸

MP4 **不需要**转换成 HTML。Wallflow 通过 AVFoundation 直接打开 MP4、M4V
和 MOV，在可用时使用系统硬件视频解码，原生循环播放，并且视频壁纸不会
启动 WebKit 进程。支持本地文件、Finder 拖拽/打开、HTTP(S) 视频 URL，
以及在 Wallpaper Engine 风格的 `project.json` 中声明 `"type": "video"`。

为了控制内存、GPU 和能耗，视频使用较短的播放缓冲，并把解码工作分辨率
限制在 1920 x 1080。更高分辨率的视频仍会铺满屏幕，但按限制后的工作
分辨率解码。

## Wallpaper Engine 网页壁纸兼容性

已实现：

- 通过 WebKit 加载本地 HTML、CSS、JavaScript、媒体和项目相对路径资源
- `window.wallpaperPropertyListener.applyUserProperties`
- 通过 `applyGeneralProperties` 传递宿主目标帧率
- `setPaused`，渲染暂停时保留最后一帧
- 合成 DOM 鼠标移动、指针移动、左键和右键点击事件
- 媒体自动播放和远程网页内容访问
- 音频与媒体监听器注册兼容层
- 原生属性编辑器，支持复选框、滑块、颜色、选项、文本、文件和目录
- 增量属性回调，并按项目持久化属性值
- 全局 HTML 媒体静音，且只允许主显示器播放声音

尚未实现：

- 实时音频频谱数据
- macOS 媒体播放器元数据转发
- 随机文件目录回调目前返回空路径
- Web Audio API 节点尚未接入全局媒体静音控制

## Wallpaper Engine 场景壁纸兼容性

已实现：

- 原生且带边界检查的 `PKGVxxxx` 包文件表解析
- 无需解压整个归档即可随机读取包内文件
- 解析 `scene.json` 常规设置和对象分类
- 解析图片描述文件和材质 JSON
- 静态图片图层的原点、缩放、旋转、透明度和全屏布局
- 相机视差和逐图层视差深度
- 解码 `.tex` 中的 RGBA8888、R8、RG88、DXT1、DXT3 和 DXT5
- 解码 LZ4 压缩的纹理数据
- 通过 ImageIO 加载内嵌 PNG、JPEG、GIF、BMP、TIFF 和 WebP
- 解析 `TEXS0001` 至 `TEXS0003` 精灵帧表，并通过系统合成器播放
- 暂停和继续精灵动画时不从头播放
- 使用 AVFoundation 播放包内受支持格式的声音对象
- 支持循环、随机和单次声音播放，以及暂停和全局静音
- 场景图层无法渲染时回退显示项目预览图

尚未实现：

- Wallpaper Engine 着色器转换和多通道特效
- 粒子系统、SceneScript、骨骼网格和灯光
- 视频纹理和由脚本触发的声音控制
- 未包含在 `scene.pkg` 中的 Wallpaper Engine 内置资源包

## 运行

```sh
git clone git@github.com:823302271/wallflow.git
cd wallflow
swift run -c release
```

使用菜单栏中的波形图标暂停或退出 Wallflow。

通过菜单栏的 **Open Wallpaper...** 选择 Wallpaper Engine 项目。仓库在 `Fixtures/web-wallpaper` 中提供了一个网页兼容性测试项目。

## 导入壁纸

- **打开壁纸...** 支持 MP4/M4V/MOV、项目文件夹、`project.json`、`index.html`、`scene.pkg` 和完整 ZIP。
- **从 URL 导入...** 支持 HTTP(S) MP4/M4V/MOV 地址、网页壁纸地址，或完整壁纸项目的 ZIP 地址。
- 可以在 Finder 中使用 Wallflow 打开受支持文件，也可以把文件或 ZIP 拖到 `Wallflow.app` 上。
- ZIP 在加载前会检查路径穿越、符号链接、文件数量和解压体积。

包含本地资源的项目必须导入完整目录或完整 ZIP。单独提供远程 `project.json` 或 `scene.pkg` 无法包含同目录下的纹理、脚本、材质和媒体文件，因此会被明确拒绝。

### 导入失败原因

| 原因 | 处理方式 |
| --- | --- |
| 没有受支持的项目入口 | 加入 MP4/M4V/MOV、`project.json`、`index.html` 或 `scene.pkg`。 |
| `project.json` 格式错误 | 校验 JSON，并检查 `file` 和 `type` 字段。 |
| 入口文件缺失或位于项目外 | 把入口文件和所有资源放在项目目录内部。 |
| 壁纸类型不支持 | 应用壁纸和其他视频封装格式尚未实现。请将视频封装转换为 MP4、M4V 或 MOV，无需转换为 HTML。 |
| 远程 `.json` 或 `.pkg` 不完整 | 将整个项目打包为 ZIP，再导入 ZIP 地址。 |
| Steam Workshop URL | 导入本机已下载的 Workshop 文件夹，或作者提供的完整 ZIP。 |
| ZIP 路径不安全或包含符号链接 | 只使用普通文件和相对路径重新打包。 |
| 压缩包过大 | 下载上限 512 MB；解压上限 1 GB 和 100,000 个文件。 |
| ZIP 同层包含多个项目 | 每个 ZIP 只保留一个壁纸项目。 |

导入成功不代表所有场景特效均已兼容。独立视频壁纸已经支持，但场景包内部的视频纹理尚未支持；其他限制请查看场景兼容性章节。

## 动画调节

网页壁纸可以声明 Wallpaper Engine 用户属性。Wallflow 当前支持复选框、滑块、颜色、选项、文本、文件和目录，并按项目持久化设置。

场景动画调节将分阶段实现，顺序为播放速度和 FPS 限制、相机与视差、特效开关、逐图层属性，最后是粒子和音频响应参数。只有对应渲染绑定真正完成后，Scene 控件才会显示。

生成可以双击运行的 app：

```sh
./scripts/package-app.sh
open dist/Wallflow.app
```

生成的 app 使用临时签名，仅用于本机运行。Wallflow 是菜单栏应用，因此不会显示 Dock 图标。

## 性能设计

Wallflow 仅面向 Apple 芯片，并以 Metal 作为统一渲染主干。程序避免持续进行 CPU 侧模拟，会在空闲时降低帧率、以低于 Retina 原生分辨率的比例渲染、使用双缓冲交换链，并暂停被窗口完全覆盖的显示器。网页壁纸限制为 24 FPS 和 1 倍设备像素比，并且只有选择网页项目时才启动 WebKit。原生视频通过 AVFoundation 播放，使用短缓冲和 1080p 解码上限。

默认开启 **其他应用在前台时暂停**：当前 Space 中有浏览器等应用的可见窗口时，Wallflow 会立即停止渲染、媒体、音频和全局壁纸输入。只有确实需要在普通窗口周围的桌面区域继续显示动画时，才建议关闭该选项。

当 WindowServer 在全屏或 Space 切换过程中短暂显示系统桌面时，Wallflow 会让最后一帧窗口常驻在实时渲染器后方，同时把系统桌面临时设置为该静态帧，并在正常退出时恢复原桌面。连接或断开其他显示器时，仍连接显示器上的渲染器会被复用，不再重新启动壁纸。

## 架构方向

Metal 是 Apple 芯片专用目标的统一渲染基础。独立视频使用 AVFoundation；WebKit 仅作为 HTML 项目的隔离兼容宿主；当前支持的场景图片图层暂时由 Core Animation 合成。随着转换器逐步实现，着色器特效、粒子和场景图层会统一进入共享 Metal 管线。

## 验证

项目包含不依赖第三方测试框架的自测，因此仅安装 Apple Command Line Tools 也可以运行：

```sh
swift run Wallflow --self-test
swift run Wallflow --web-self-test
swift run Wallflow --video-self-test /path/to/video.mp4
```

第一条命令验证项目加载、包边界检查、场景解析、LZ4、内嵌图片、DXT 和场景图层构建。第二条命令会启动真实的 WKWebView，验证 Wallpaper Engine 属性和鼠标 API。第三条命令会打开真实视频，验证播放、暂停/恢复和静态帧抓取。

## 项目结构

- `Sources/Wallflow`：AppKit、Metal、WebKit、场景解码和音频代码
- `Fixtures/web-wallpaper`：本地 HTML 兼容性测试项目
- `scripts/package-app.sh`：Release app 打包脚本
- `AppBundle/Info.plist`：macOS 应用元数据
- `THIRD_PARTY_NOTICES.md`：第三方格式和实现说明

## 参与贡献

提交问题时，请附上 macOS 版本、Mac 型号、壁纸类型，并在授权允许的情况下提供最小可复现项目。请勿上传未经再分发许可的付费或受版权保护的 Workshop 资源。
