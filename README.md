# 刷题课堂 · iOS 原生版

个人使用的课程刷题 App。基于 **Swift + AVPlayer 自定义播放控制层**，一套数据层设计，先交付 iOS。

## 功能

### 播放器（自定义控制层，非系统播放器）
- 单击：显示/隐藏控件
- 双击左/右半屏：快退/快进 10 秒
- 长按：递进倍速快进（2x → 3x → 4x），松手恢复
- 左半屏上下滑：调节屏幕亮度
- 右半屏上下滑：调节系统音量
- 横向滑动：拖动播放进度
- 倍速按钮：1.0 / 1.25 / 1.5 / 2.0 循环
- 全屏切换、锁屏（锁定后屏蔽所有手势）
- 播到 95% 或播完自动标记「已看」，退出自动保存播放位置

### 课程管理
- 首页三段：**最近计划**（按日期排，含昨天/今天/未来 7 天）/ **继续学习**（最近 5 条）/ **全部课程**
- 每章三态：未看（灰）/ 在看（蓝）/ 已看（绿），显示「已播/总时长」与百分比
- 每门课显示总体完成百分比
- 左滑章节：标记已看/未看、设置计划日期、改名加/去 `✅` 前缀（真实改动 NAS 文件）
- 数据存每门课的 `.course_state.json`，本地缓存秒开 + Alist 云同步（跨设备）

## 编译 IPA（GitHub Actions）

本地无 macOS，编译交给 GitHub Actions 的 macOS runner。

### 1. 准备签名材料
从你的 Apple 开发者账号导出：
- **证书 `.p12`**（Development 或 Ad Hoc，含私钥），记住导入时设的密码
- **描述文件 `.mobileprovision`**（Bundle ID 必须是 `com.peilongtang.studyplayer`，且包含你的设备 UDID，Development 类型）

> Bundle ID 若要改，同步改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 和 build-ios.yml 里 ExportOptions 的 key。

### 2. 转成 Base64（在 Mac 上执行）
```bash
base64 -i cert.p12 -o cert_p12.txt
base64 -i studyplayer.mobileprovision -o provision.txt
```

### 3. 建 GitHub 仓库并推送
```bash
git remote add origin https://github.com/<你的账号>/study-player.git
git add . && git commit -m "init: iOS 刷题课堂"
git push -u origin main
```

### 4. 配置 Secrets
仓库 → Settings → Secrets and variables → Actions → New repository secret，添加：

| Secret | 值 |
|---|---|
| `CERT_P12_BASE64` | cert_p12.txt 的内容（一整行） |
| `CERT_PASSWORD` | .p12 导入密码 |
| `PROVISION_BASE64` | provision.txt 的内容（一整行） |
| `PROVISION_NAME` | 描述文件的 Name（在 Apple Developer 页面看到的，如 `StudyPlayer Dev`） |
| `KEYCHAIN_PASSWORD` | 随意设一个临时密码，如 `temp123456` |

### 5. 触发编译
Actions 页 → **Build Signed IPA** → Run workflow。或 `git tag v1.0 && git push --tags`。

完成后在 Artifacts 下载 **StudyPlayer-IPA**，用你的签名工具/爱思/AltStore 安装到 iPhone。

## 已知限制
- FLV 依赖 NAS 上的 6090 转码服务（`transcode_server.py` 已配 systemd 自启）；外网观看需 Tailscale 或反向代理
- 首次进入课程从 Alist 拉全量章节列表，之后本地缓存
- 多端同时写同一门课按 `updatedAt` 后写覆盖（单人使用基本不会触发）
- 鸿蒙/Windows 版本下一轮做（数据层可复用，UI 需另写）
