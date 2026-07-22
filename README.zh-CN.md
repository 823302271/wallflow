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
- 原生 Metal 动画与可复用的 Canvas 2D-to-Metal 渲染器
- 全局跟踪鼠标，同时不拦截桌面点击
- 平滑的鼠标视差、弯曲线条和交互波纹
- 交互时自适应为 60 FPS，空闲时降低为 24 FPS
- 内置抽象场景使用 75% 逻辑渲染比例
- Canvas-Metal 壁纸使用显示器完整原生像素分辨率
- 使用双缓冲 Metal 交换链，减少默认三缓冲带来的内存占用
- 可见应用窗口联合遮住某台显示器的桌面时暂停该显示器的渲染
- 系统睡眠或登录会话非活动时自动暂停
- 显示器变化时增量复用已有渲染器，不重启仍连接的屏幕
- Space 切换期间由同一个渲染器暂停并保留最后一帧
- 菜单栏暂停和继续控制
- 默认仅在某块显示器的桌面完全不可见时暂停，并提供菜单开关
- 持久化壁纸库，支持切换、Finder 定位和卸载
- 每张壁纸独立保存自动、填充裁切、完整显示和拉伸模式
- 可在 English 与简体中文之间即时切换界面语言
- 通过 AVFoundation 原生播放 MP4、M4V 和 MOV
- 自动使用 Metal 渲染能力范围内的纯脚本 Canvas 2D 壁纸
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

- 自动识别能力范围内的本地 Canvas 2D 壁纸
- 通过 JavaScriptCore 原样执行壁纸脚本，不修改项目文件
- 使用 Metal 渲染路径、完整圆形、纯色填充、圆头线段、简单阴影和 overlay 效果
- 支持 Canvas 动画帧、尺寸变化、鼠标事件、页面背景色和属性回调
- 项目使用未支持的 Canvas、DOM、图片、媒体或网络 API 时保守回退到 WebKit
- 通过 WebKit 加载本地 HTML、CSS、JavaScript、媒体和项目相对路径资源
- `window.wallpaperPropertyListener.applyUserProperties`
- 通过 `applyGeneralProperties` 传递宿主目标帧率
- `setPaused`，渲染暂停时保留最后一帧
- 合成 DOM 鼠标移动、指针移动、左键和右键点击事件
- 媒体自动播放和远程网页内容访问
- 音频与媒体监听器注册兼容层
- 原生属性编辑器，支持复选框、滑块、颜色、选项、文本、文件和目录
- 增量属性回调，并按项目持久化属性值
- 自动识别单一主图片或视频并铺满，同时保留复杂网页原始布局
- 全局 HTML 媒体静音，且只允许主显示器播放声音

尚未实现：

- Metal Canvas 路径尚未转换图片、文字、渐变、非完整圆弧、复杂变换、裁剪和复杂 DOM/CSS；这些项目会使用 WebKit
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
- 根据场景原始画布应用填充、完整显示和非等比拉伸
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
- 本地文件、项目目录和 ZIP 导入后都会复制到 `~/Library/Application Support/Wallflow/ImportedWallpapers`，不依赖原始路径或临时目录；已有的 Wallflow 受管导入目录也会在启动时自动发现。
- 导入成功后会自动加入 **壁纸管理...**；移除本地壁纸时只删除 Wallflow 的安装副本，不会删除原始文件。URL 壁纸只会移除库记录。
- 旧版本留下的失效路径会标记为 **文件不可用**；选中后点击 **重新定位壁纸...** 即可选择原项目并重新安装。
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

每张已导入壁纸还可以在 **壁纸属性...** 中独立保存 **显示方式**：

- **自动**：原生视频以及能够识别出单一主图片或视频的简单网页使用填充裁切；复杂网页保持作者原始布局。
- **填充裁切**：保持宽高比并铺满显示器，超出部分会被裁切。
- **完整显示**：保持宽高比并显示完整画面，周围可能出现留空区域。
- **拉伸**：不保持宽高比，直接拉伸到整个显示器。

显示方式保存在 Wallflow 的壁纸库记录中，不会修改第三方壁纸的 `project.json` 或源文件。

场景动画调节将分阶段实现，顺序为播放速度和 FPS 限制、相机与视差、特效开关、逐图层属性，最后是粒子和音频响应参数。只有对应渲染绑定真正完成后，Scene 控件才会显示。

生成可以双击运行的 app：

```sh
./scripts/package-app.sh
open dist/Wallflow.app
```

生成的 app 使用临时签名，仅用于本机运行。Wallflow 是菜单栏应用，因此不会显示 Dock 图标。

## 性能设计

Wallflow 仅面向 Apple 芯片，并以 Metal 作为统一渲染主干。Canvas-Metal 壁纸使用显示器完整原生像素分辨率，只有内置抽象场景保留较低的渲染比例。渲染器使用较短的命令缓冲，并暂停桌面完全不可见的显示器。兼容的 Canvas 2D 壁纸会在进程内执行原始 JavaScript，并以 24 FPS 将绘制命令批量提交给 Metal；其他 HTML 壁纸回退到 24 FPS、1 倍设备像素比的 WebKit。原生视频通过 AVFoundation 播放，使用短缓冲和 1080p 解码上限。

默认开启 **桌面不可见时暂停**：Wallflow 会计算所有可见应用窗口的联合覆盖区域，只有某块显示器已经没有桌面区域暴露时，才暂停对应的渲染、媒体、音频和壁纸输入。这也能识别由多个窗口共同组成全屏画面的浏览器。普通应用窗口不会导致暂停，只要仍有桌面区域暴露，动画就继续运行。鼠标输入采用全局旁路监听，不会拦截原应用；原应用收到点击的同时，交互壁纸也会收到同一次点击。

在全屏或 Space 切换过程中，Wallflow 始终保留同一个桌面窗口、WebKit 表面和渲染器，并固定在系统壁纸之上、桌面图标之下。桌面不可见前会保存最后一帧；返回桌面时先显示这张冻结帧，底层渲染器恢复出图后再继续动画，避免 Metal 或 WebKit 重新挂接时露出白色空表面。Wallflow 还会把最近一帧同步为 macOS 静态桌面兜底，避免 WindowServer 短暂露出旧壁纸。连接或断开其他显示器时，仍连接显示器上的渲染器会被复用，不再重新启动壁纸。

## 架构方向

Metal 是 Apple 芯片专用目标的统一渲染基础。Canvas 兼容层现在通过 JavaScriptCore 执行原始壁纸脚本，并把支持的 Canvas 2D 命令转换为可复用的 Metal 图元。选择依据是壁纸使用的能力，而不是壁纸名称，因此兼容项目不需要逐个修改源码。独立视频使用 AVFoundation，未支持的网页能力回退到 WebKit；当前场景图片图层仍暂时由 Core Animation 合成，后续再接入 Metal 转换器。

## 验证

项目包含不依赖第三方测试框架的自测，因此仅安装 Apple Command Line Tools 也可以运行：

```sh
swift run Wallflow --self-test
swift run Wallflow --canvas-metal-self-test /path/to/project.json
swift run Wallflow --web-self-test
swift run Wallflow --video-self-test /path/to/video.mp4
swift run Wallflow --library-self-test
```

第一条命令验证项目加载、渲染器选择、壁纸库、桌面可见性、包、纹理和场景构建。第二条命令会通过 Metal 执行未修改的 Canvas 壁纸，并验证绘制、属性、输入、暂停和恢复。第三条命令启动真实 WKWebView。第四条验证原生视频播放与静态帧抓取。第五条会把中英文壁纸管理窗口渲染为 PNG 测试图。

## 项目结构

- `Sources/Wallflow`：AppKit、Metal、WebKit、场景解码和音频代码
- `Fixtures/web-wallpaper`：本地 HTML 兼容性测试项目
- `scripts/package-app.sh`：Release app 打包脚本
- `AppBundle/Info.plist`：macOS 应用元数据
- `THIRD_PARTY_NOTICES.md`：第三方格式和实现说明

## 参与贡献

提交问题时，请附上 macOS 版本、Mac 型号、壁纸类型，并在授权允许的情况下提供最小可复现项目。请勿上传未经再分发许可的付费或受版权保护的 Workshop 资源。
