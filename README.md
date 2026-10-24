# ShotTool · V0.1「能截」

第一阶段骨架。对应 `../产品迭代计划-第一阶段.md` 里的 **V0.1**：能截。
标注（V0.2）和贴图（V0.3）还没做。

---

## 现在能做什么

| 能力 | 状态 | 说明 |
|---|---|---|
| **全局快捷键唤起** | 完成 | 默认 `⇧⌘2`，Carbon 热键，**不需要辅助功能权限** |
| **全屏遮罩** | 完成 | 层级 `.screenSaver`，能盖住菜单栏、Dock、全屏 App |
| **多屏覆盖** | 完成 | 每块屏一个遮罩；选区锁在起始屏内（与系统截图、iShot 行为一致） |
| **拖动框选** | 完成 | 支持反向拖、8pt 边缘吸附、方向键 1px 微调（`⌥`+方向键移动整体） |
| **窗口识别** | 完成 | 悬停高亮整窗，单击直接截该窗口 |
| **放大镜 + 像素坐标** | 完成 | 4 倍最近邻放大，显示屏内像素坐标 |
| **复制到剪贴板** | 完成 | 同时写 PNG 和 TIFF，粘微信 / 企微 / 飞书 / Figma 都不丢 |
| **另存为** | 完成 | 工具条 ⤓ 弹系统保存面板自己选位置；菜单栏「保存最近一张」仍直接存桌面 |
| **标注：矩形 / 椭圆 / 箭头 / 文字** | 完成 | V0.2。选区定好后按 `1`–`4` 切工具，在选区内拖拽绘制 |
| **选中与移动** | 完成 | 单击选中（虚线框 + 四个把手），拖拽整体移动，`Delete` 删除 |
| **撤销 / 重做** | 完成 | `⌘Z` / `⇧⌘Z`，最多 60 步 |
| **导出合成** | 完成 | 标注在导出时画到原图上，不靠截屏（否则会把遮罩和工具条拍进去） |
| **贴图（钉住）** | 完成 | V0.3。工具条「钉」把当前图钉在屏幕上；可拖动、滚轮缩放、右键调透明度 |
| **长截图** | 完成 | 工具条「⇕」。选区中心出现按钮，鼠标移上去开始滚、移开暂停、点按钮完成 |
| 画笔 / 马赛克 / 序号 / 裁剪 | 未做 | V0.2 的 P1 |

## 操作

> **行为变化（V0.2）**：框选松手后**不再直接复制**，而是进入标注态。
> 要出图请按工具条的 ⧉ / ⤓，或直接按回车。

| 操作 | 按键 |
|---|---|
| 唤起截图 | `⇧⌘2` |
| 框选 | 按住拖动 |
| 截某个窗口 | 单击该窗口 |
| 切工具（矩形/椭圆/箭头/文字） | `1` `2` `3` `4`，或点工具条 |
| 画标注 | 选好工具后在选区内拖拽（文字为单击） |
| 选中已有标注 | 单击它，然后可拖动 |
| 删除选中标注 | `Delete` |
| 撤销 / 重做 | `⌘Z` / `⇧⌘Z` |
| 出图并复制到剪贴板 | 回车，或工具条 ⧉ |
| 另存为（弹面板选位置） | `⇧回车`，或工具条 ⤓ |
| 钉在屏幕上 | 工具条「钉」 |
| 长截图 | 工具条「⇕」，然后鼠标移到选区中心的按钮上 |
| 矩形出正方形、椭圆出正圆 | 拖动时按住 `Shift` |
| 关闭全部贴图 | 菜单栏图标 → 关闭全部贴图（`⌥⌘W`） |

### 贴图怎么用

贴出来后：**拖动**移动、**滚轮**缩放、**右键**可以复制 / 另存为 / 调不透明度（100/75/50/25）/ 关闭。

贴图窗口是 `.nonactivatingPanel` 且不抢焦点 —— 贴出来的瞬间，你原来在打字的输入框不会失焦，
下拉菜单也不会收起来。这点和普通窗口不一样，是刻意的。

### 长截图：怎么用，以及为什么这么做

1. 框选 → 点工具条「⇕」
2. 选区中心出现按钮「鼠标移上来开始滚动」
3. 鼠标移上去开始滚，**移开就暂停**（方便停在想要的位置）
4. 滚到底按钮变绿「到底了 · 点这里完成」，点一下出图，也可按回车

**这个方案是 REA 反编译 iShot 得来的，不是自己想当然。**

iShot 的滚动截图分两处：

```objc
// ① 遮罩接收滚动事件，记账 + 转发（-[MXClipView scrollWheel:]）
CGFloat deltaY = [event deltaY];
DAT_1001dde20 += deltaY;                    // 累积真实滚动量
[DAT_1001ddee0 invalidate];                 // 停掉旧定时器（防抖）
DAT_1001ddee0 = [NSTimer scheduledTimer... @selector(scrollFinished)];
[handler handleMouseEvent:event];            // 转发给下层，页面才会滚

// ② 按钮做成遮罩的子视图（-[MXClipView scrollScreenShot]）
[window setBackgroundColor:[NSColor clearColor]];   // 遮罩背景透明
[window setIgnoresMouseEvents:YES];
[self addSubview:autoScrollScreenShotButton];
CGRectMake(borderFrame.midX - w/2, borderFrame.midY - 11, w + 30, 22);
```

**关键结论：它是按「累积滚动量」算偏移拼接的，不用图像匹配。**
图像匹配只能用来修小误差，绝不能当成前提——否则内容相似或没有特征时必然失败。

我们照这个做：遮罩接收 `scrollWheel` → 记账 → `postToPid` 转发给鼠标下的窗口；
每段用实测滚动量算重叠，图像匹配只在 ±50% 内微调，**匹配不上照拼**。

**踩过的弯路**：第一版按自己的想法建了独立浮动窗口，`isVisible=true` 但**完全不上屏**
（试了 `NSPanel` 两种配置和 `NSWindow`，连不透明红底都不显示）。
换成「遮罩透明 + 子视图按钮」后一次就出来了。

**和 iShot 的差异**：它是「点一下开始自动滚、再点停止」，所以需要 `ignoresMouseEvents` 让鼠标穿透。
这里按要求改成**悬停驱动**，必须持续接收鼠标事件，所以没有穿透——
事件判定用画布的 `mouseMoved` + 局部事件监听双保险，另外进入长截图时会检查一次鼠标是否已在按钮上
（否则用户不动鼠标就没有 mouseMoved，会误以为没反应）。

### 已知限制

- **需要「辅助功能」权限**（模拟滚轮），和屏幕录制是两个独立授权；
- 鼠标会被自动滚到选区中心，滚的是**鼠标下面那个可滚动区域**，所以框选时要框住内容区；
- 页面若有**固定表头 / 固定底栏**，拼接后会出现重复（这是所有长截图工具的通病）；
- 单次最多 40 帧，两帧完全一样就判定到底了；
- 结果直接进剪贴板，不会有中间预览。
| 取消整个截图 | `Esc`（有选中标注时先取消选中） |
| 调选区右下角 | `方向键`（`⇧` 加速 10px） |
| 整体移动选区 | `⌥` + `方向键` |

---

## 编译与运行

```bash
cd shot-plan/ShotTool
./build.sh                  # 编译 + 组装 .app + ad-hoc 签名
open dist/ShotTool.app
```

跑起来后**先授权**：菜单栏图标 → 「检查屏幕录制权限」→ 点「打开系统设置」，
在「隐私与安全性 → 屏幕录制」里勾上 ShotTool，然后**退出并重新打开本 App**。

> 这一步不做的话，按下热键不会有任何反应 —— 这不是卡死，是系统在等授权。
> 代码里已经加了 5 秒超时，超时会弹窗明确告诉你原因。

### 签名：必须用真实证书，不能用 ad-hoc

**这一条踩过坑，别改回去。**

ad-hoc 签名（`codesign --sign -`）的 designated requirement 里**带 cdhash**。
cdhash 是从二进制内容算的，每次重新编译都会变，于是 macOS 的 TCC 认为「这是另一个程序」，
屏幕录制授权立即失效——**但系统设置里的开关还显示是打开的**，表现为「明明授权了一直提示没权限」，
极难自查（我在这上面浪费了一轮排查）。

改用 `Apple Development` 证书签名后，requirement 变成：

```
identifier "com.yangran.shottool" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..."
```

不含 cdhash，所以重新编译不再掉授权。`build.sh` 会自动找本机的 Apple Development 证书，
找不到才退回 ad-hoc 并打印警告。

几个相关命令：

```bash
# 看当前签名
codesign -dvvv /Applications/ShotTool.app 2>&1 | grep -E "Authority|TeamIdentifier"

# 看 designated requirement（重点确认里面没有 cdhash）
codesign -d -r- /Applications/ShotTool.app
```

万一还是掉授权（比如换了证书重新签），处理办法：在「系统设置 → 隐私与安全性 → 屏幕录制」
里用减号把 ShotTool 移除，再按一次热键重新授权。

---

## 自检（不用手动按键）

```bash
# 1. 坐标换算 + 系统能力，15 项断言
./.build/release/ShotTool --selftest

# 2. 真的截一张图，验证像素尺寸 1:1、画面有内容
./.build/release/ShotTool --capture-test
#    产物：/tmp/shottool-test/display-<id>.png

# 3. 启动后自动唤出遮罩（验证遮罩层、放大镜）
./dist/ShotTool.app/Contents/MacOS/ShotTool --auto-capture

# 4. 启动后自动摆一个选区（验证挖空、描边、尺寸标签），15 秒后自动收场
./dist/ShotTool.app/Contents/MacOS/ShotTool --demo-selection

# 5. 标注合成：抓屏 → 裁切 → 加标注 → 合成 → 逐像素校验
#    这条能发现「标注画到镜像位置」和「整张图上下颠倒」，肉眼很容易漏
./.build/release/ShotTool --annotate-test

# 6. 标注界面：进入标注态并摆几条示例标注，验证工具条与渲染
./dist/ShotTool.app/Contents/MacOS/ShotTool --demo-annotations

# 7. 长截图拼接算法：造两张有已知重叠(200px)的图，验证能否还原成原图
#    纯算法，不需要任何权限，也不会真的滚动屏幕
./.build/release/ShotTool --longshot-test

# 8. 贴图：走完整流程把一张图钉到屏幕上
./dist/ShotTool.app/Contents/MacOS/ShotTool --demo-pin
```

`--capture-test` 除了看尺寸，还会算画面亮度的标准差：**纯色图会被判为「疑似空图」**。
因为没权限时 ScreenCaptureKit 不报错，而是安静返回一张空桌面 —— 这是最容易漏掉的一种失败。

---

## 目录

```
ShotTool/
├── Sources/ShotTool/
│   ├── App/AppDelegate.swift        菜单栏、热键绑定、权限引导
│   ├── HotKey/GlobalHotKey.swift    Carbon 全局热键
│   ├── Capture/
│   │   ├── ScreenGeometry.swift     ★ 全项目唯一的坐标换算入口
│   │   ├── ScreenCaptureService.swift  ScreenCaptureKit + 超时兜底
│   │   └── WindowEnumerator.swift   窗口 z 序枚举
│   ├── Overlay/
│   │   ├── OverlayWindow.swift      遮罩窗（层级 / 焦点 / 全屏行为）
│   │   ├── OverlayCoordinator.swift 会话状态与多屏调度
│   │   └── SelectionCanvasView.swift 遮罩、选区、放大镜的全部绘制
│   ├── Output/ImageOutput.swift     剪贴板 / PNG 落盘
│   ├── Diagnostics/                 自检与捕获测试
│   └── main.swift
├── Resources/Info.plist             LSUIElement=true（菜单栏常驻）
└── build.sh
```

---

## 实测踩到的四个坑（都已修，别再踩一遍）

1. **`SCDisplay.width` 给的是逻辑点，不是物理像素。**
   直接拿来设 `SCStreamConfiguration.width`，会截出半分辨率图（1470×956 而不是 2940×1912），
   **不报错、不崩溃**，只是文字发虚。正确做法：`逻辑尺寸 × backingScaleFactor`。
   这个问题是靠 `--capture-test` 的尺寸断言抓到的。

2. **ScreenCaptureKit 没权限时不抛错，而是挂起。**
   用户看到的现象是「按了热键毫无反应」，比报错难查十倍。
   已改成 5 秒超时 + 明确提示。

3. **`NSWindow` 那个带 `screen:` 的初始化器是 convenience initializer。**
   子类的 designated init 不能 `super.init(...screen:)`，只能去掉 screen 参数、靠
   `contentRect` 定位。

4. **SwiftPM 在受限环境里需要 `--disable-sandbox`。**
   否则编译 manifest 时直接报 `sandbox_apply: Operation not permitted`。
   `build.sh` 里已经带上。

---

## 给下一版（V0.2 标注）预留的位置

- `SelectionCanvasView` 的 `draw` 已经按「底图 / 遮罩 / 覆盖物」分层画，
  标注只要再加一层，不需要重写渲染。
- `OverlayCoordinator.crop(_:)` 是唯一的出图口，标注合成也应该挂在这里。
- 建议按计划文档 4.3 的 `Annotation` 结构落模型 —— **带一个可选的 `semantic` 字段**，
  第二阶段做「导出成需求清单」时就不用返工。

---

## 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。

