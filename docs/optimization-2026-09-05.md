# 0.1.27 优化与验证记录

0.1.27 包含场景能耗、暂停恢复、粒子兼容与素材导入修复，以及蓝紫色流动丝带图标。图标源文件和导出脚本一并保存在仓库中。

## 暂停和能耗

- 移除“点击 Dock / 激活普通应用立即暂停”的推断，按窗口实际可见性与应用覆盖区域决定每块显示器的状态。
- 排除 Dock、系统壁纸表面和明显透明窗口；覆盖阈值由 98.5% 提高到 99.9%，避免普通窗口留出桌面边缘时误判。
- 合并同一轮的 WindowServer 查询，应用事件合并采样；手动暂停、锁屏、睡眠时停止覆盖轮询。
- 可见性探测的代次不再在重置后复用，旧回调不能覆盖新一轮状态。
- 场景原有 60 Hz 鼠标轮询和 12 Hz 粒子定时器合为单个 30 Hz 时钟。纯视差使用鼠标事件；鼠标离屏且粒子消散后停止时钟。
- 任何暂停原因均停止场景输入与粒子计算，保留粒子位置、寿命和发射余量。复用粒子图层与颜色纹理，原位更新粒子数组。

## 花瓣与素材导入

“少女与猫”的配置中发射率为 20、数量倍率为 1.5。移除了 45% 发射率、每帧仅一片、48 片上限及额外画布放大的处理；应用原始数量倍率、尺寸与颜色，保留随机帧分布。粒子模拟有 4096 个的资源上限，颜色使用 32 档缓存。

淡入淡出按粒子生命周期比例计算；淡出值代表开始淡出的时点。修正 TEXS 的上下行和镜像 UV 处理，停止通过近似透明度去重删除不同精灵帧。

`particle.zip` 是共用粒子纹理素材包，不是独立壁纸。普通导入和“导入粒子资源”入口现在均支持文件夹与 ZIP，安装到 EngineAssets，随后仅重载场景壁纸，保留视频和网页渲染器。ZIP 的路径和体积校验保留；新素材完成复制后才替换旧目录。

## 已执行验证

- Release 编译、应用打包、临时签名验证及 `git diff --check` 通过。
- 核心自测通过，新增覆盖 Dock 动画/透明窗口、桌面露出边缘、旧探测回调、粒子数量/尺寸/颜色、暂停保留状态、图层复用、TEXS 上下行/镜像及资源 ZIP 安装。
- `particle.zip` 在隔离临时目录安装并成功解码花瓣纹理；`3309715910.zip` 仍识别为“少女与猫”完整壁纸。
- “少女与猫”实际渲染输出成功；真实运行循环测得 2 秒播放 60 次更新、2 秒暂停 0 次更新、2 秒恢复 59 次更新。
- 最终打包版本上述测试的进程 CPU 时间分别为播放 0.0235 秒、暂停 0.0003 秒。这是进程计时，并非整机能耗或与旧版的受控功耗对比。
- 原生视频、Canvas-Metal 和 WKWebView 的既有暂停/恢复自测通过。网页回归还修正了冒泡事件被再次分发给 document/window 导致的重复输入。
- 0.1.27 的应用包已验证签名、版本号与图标文件，并完成安装启动检查。

## 验证边界

没有 Windows 对照录屏，未验证所有 macOS Space 手势和真实多屏布局。粒子、SceneScript、多通道着色器仍不是完整兼容实现，不能保证逐像素一致。本机 rosepetals TEXS 的 5 条记录中有 1 条超出 512×128 图集，当前安全跳过，使用 4 个有效帧。

参数依据：[Wallpaper Engine 发射器文档](https://docs.wallpaperengine.io/en/scene/particles/component/emitter.html)、[粒子算子文档](https://docs.wallpaperengine.io/en/scene/particles/component/operator.html)。

## 复验

```sh
swift run -c release Wallflow --self-test --verify-import /path/to/particle.zip
swift run -c release Wallflow --scene-self-test /path/to/scene/project.json
swift run -c release Wallflow --web-self-test
swift run -c release Wallflow --video-self-test /path/to/video.mp4
swift run -c release Wallflow --canvas-metal-self-test /path/to/compatible/canvas/project.json
```
