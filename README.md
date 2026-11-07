# 单向历 KOReader 插件

这是一个面向 Kindle 版 KOReader 的插件。它会从 OWSPACE（单向历）图片地址获取当天的单向历壁纸，并可将这张图片设为 KOReader 的锁屏屏保。

## 功能

- 按北京时间确定“今天”，下载当天的单向历图片。
- 支持自动检查，也可以从 KOReader 菜单手动下载；手动下载可跳过 404 冷却，已有有效今日图片时直接复用。
- 提供「全屏」和「圆角白卡」两种壁纸。两种都会清理原图留白处识别到的四角直角线，圆角白卡会将完整日历等比例放在白色卡片中。
- 自动配置屏保：使用随机图片模式、指向插件专用图片目录、开启图片拉伸，并隐藏屏保文字。
- 开启自动配置前保存原有屏保选项；关闭该功能时恢复原设置。
- 下载在后台执行，等待服务器响应时仍可操作阅读界面，无需开启 KOReader 的 Turbo 实验选项。
- 同一 KOReader 进程中同一时间只保留一个下载请求；界面切换后，旧请求的结果不会覆盖新日期的图片。
- 下载到临时文件后检查 JPEG 文件并尝试解码，确认可读后再替换正式图片。有效的今日图片不会重复下载；无法解码的缓存会重新下载。
- 图片下载成功后，清理插件专用目录中的旧 `.jpg` 图片。
- 启动时清理专用目录内中断下载遗留的日期格式 `.jpg.tmp` 文件；有下载进程仍在运行时，会等待进程退出后再清理。
- 提供诊断菜单，显示今日图片、网络状态、屏保配置和最近一次请求状态。
- 支持从 Kindle 上手动检查并安装 GitHub 正式版更新。

## 安装

### 下载发布版安装包（推荐）

1. 打开 [最新发布版](https://github.com/iamzhangjinpeng/danxiangli.koplugin/releases/latest)，在 **Assets（附件）** 中下载 `danxiangli.koplugin-v版本号.zip` 安装包。
2. 解压后会直接得到 `danxiangli.koplugin` 文件夹，无需改名。安装包只包含运行文件和使用说明，目录结构如下：

   ```text
   danxiangli.koplugin/
   ├── main.lua
   ├── _meta.lua
   ├── danxiangli_wallpaper.lua
   ├── danxiangli_update.lua
   ├── assets/
   │   └── card-background.png
   └── README.md
   ```

3. 用 USB 将 Kindle 连接到电脑，把整个 `danxiangli.koplugin` 文件夹复制到 Kindle 盘中的 `koreader/plugins/` 下。设备上的完整路径是：

   ```text
   /mnt/us/koreader/plugins/danxiangli.koplugin/
   ```

4. 安全弹出 Kindle，然后完全退出并重新打开 KOReader。
5. 打开 KOReader 的“工具”菜单，找到“单向历”。如果菜单没有出现，确认插件目录层级正确，并检查 KOReader 的插件管理中该插件是否已启用。

请下载上面命名的安装包；GitHub 自动提供的 **Source code (zip)** 和 **Source code (tar.gz)** 是源码归档。若使用源码归档安装，需要手动将解压后的文件夹改名为 `danxiangli.koplugin`，确保 `main.lua` 和 `_meta.lua` 直接位于其中。

### 更新已有插件

- **在线更新（v1.5.0 起）**：连接 Wi-Fi，在「工具 → 单向历 → 检查插件更新」查看正式版。发现新版时点「下载安装」，完成后重启 KOReader。插件只在点击菜单时检查版本。
- **USB 更新**：完全退出 KOReader，再用新版安装包中的 `danxiangli.koplugin` 文件夹覆盖旧插件目录，安全弹出 Kindle 后重新打开 KOReader。v1.4.0 及更早版本需用 USB 安装首个支持在线更新的版本。

两种方式都会保留已有图片和 KOReader 中的插件设置。在线更新先核对安装包的 SHA-256 并检查文件，再替换插件目录。如果设备未能确认磁盘写入，插件会提示并保留旧版备份。重启后，有缓存原图时会先用新版重新生成一次壁纸。壁纸初始化无错误且插件目录写入得到确认后，才会清理旧版备份。

如果安装中断、重启后单向历菜单消失，可退出 KOReader 后通过 USB 恢复。打开 `koreader/plugins/`，如果已有 `danxiangli.koplugin` 目录，先将它移出，再把 `danxiangli.koplugin.previous` 改回 `danxiangli.koplugin`。

KOReader 的插件目录通常位于 KOReader 安装目录下的 `plugins/` 文件夹。Kindle 上本插件使用上面的 `/mnt/us/koreader/plugins/` 路径。其他平台的安装说明可参照 [KOReader 用户指南](https://koreader.rocks/user_guide/)。

## 使用

在 KOReader 中打开“工具 → 单向历”，可以使用以下项目：

| 菜单项 | 作用 |
| --- | --- |
| 自动配置屏保 | 开启或关闭自动屏保配置。首次安装默认开启；关闭时恢复启用前保存的屏保设置。 |
| 下载今日单向历 | 如果今日图片有效则提示已存在；否则立即尝试下载，即使当前处于 404 冷却中。 |
| 壁纸类型 | 选择「全屏」（默认）或「圆角白卡」。已有缓存时可离线切换，选择会在重启后保留。 |
| 检查插件更新 | 手动检查 GitHub 最新正式版。确认后在后台下载安装，重启 KOReader 生效。 |
| 诊断 | 查看图片目录、今日图片状态、最近请求状态、网络连接和屏保设置。 |

插件启动后会稍作等待再检查；KOReader 唤醒后也会检查，并每隔一段时间进行本地状态检查。今日图片已经有效时，这些检查不会再次请求图片服务器。若 Wi-Fi 已开启但尚未连通，插件会短暂退避重试；服务器返回“未发布”（HTTP 404）时，自动检查会对当天图片暂停请求两小时。这个冷却在文件管理器和阅读器切换时仍有效，跨到新的一天后不再阻挡新日期的请求；完全重启 KOReader 后冷却状态会重置。想在冷却期间立即再试，可点击“下载今日单向历”；手动下载的网络失败重试也可跳过此前的冷却，再次收到 404 则重新进入冷却。

## 图片和设置保存位置

今日图片保存在：

```text
/mnt/us/koreader/screenshots/danxiangli/YYYYMMDD.jpg
```

其中日期按北京时间计算。插件只会清理这个专用 `danxiangli/` 目录里的旧 JPG，不会扫描或清理 `screenshots/` 根目录以及其他目录中的图片。

KOReader 从 `danxiangli/wallpaper/display/` 读取已验证的屏保图。插件在 `danxiangli/wallpaper/` 保留生成缓存，暂时无法验证的文件可以稍后重试。新屏保图通过验证后才替换上一张。发现 PNG 损坏时，会尝试用缓存的 JPG 离线重建。也可点「下载今日单向历」重新校验壁纸。原始 JPG 用于离线重建和切换样式。

壁纸类型、自动屏保开关和原屏保设置备份保存在 KOReader 的设置中，不会另外创建插件设置文件。关闭“自动配置屏保”会恢复原来的屏保类型、图片目录、拉伸选项和屏保文字选项，并清除原设置备份。

## 卸载与清理

建议按下面顺序操作：

1. 在“工具 → 单向历”中关闭“自动配置屏保”。看到“屏保设置已恢复”提示后，原屏保选项已恢复，备份也已清除。
2. 删除插件：如果使用 KOReader 的插件管理，请在 KOReader 仍打开时操作；如果手动删除文件夹，请先完全退出 KOReader。Kindle 上的插件目录是：

   ```text
   /mnt/us/koreader/plugins/danxiangli.koplugin/
   ```

3. 如果还要删除已经下载的图片，删除插件专用目录：

   ```text
   /mnt/us/koreader/screenshots/danxiangli/
   ```

   这不会删除 `screenshots/` 中的其他文件。

如果 KOReader 的插件管理界面提供“删除插件和设置”，可以使用它清除插件设置。如果界面只有“删除插件”，KOReader 可能会保留插件设置。若仍要彻底移除设置，可在 KOReader 完全退出后备份并编辑其 `settings.reader.lua`，只删除名称为 `danxiangli_auto_screensaver`、`danxiangli_screensaver_backup`、`danxiangli_wallpaper_style` 或旧版遗留的 `danxiangli_last_date` 的设置项。不要删除整个设置文件。

## 兼容性与网络

- 当前代码面向 Kindle 版 KOReader；图片目录和设备支持声明均针对 Kindle。
- 下载需要设备可以访问 OWSPACE 图片服务器。若图片地址改变、服务器未发布当天图片或网络不可用，插件无法保证当天图片可用；可以稍后重试或使用“诊断”查看状态。
- 在线更新需要 Kindle 直连 `api.github.com`、`github.com` 以及 GitHub 的发布附件下载域名。若启用了 KOReader 的 HTTP 代理，插件会提示可使用 USB 更新。
- 单张原图的下载上限为 4 MiB，解码前还会检查尺寸（单边不超过 4096 像素，总面积不超过 4,194,304 像素）。
- 单次下载设有 20 秒总时限，超时会终止后台任务并按退避间隔重试。切换阅读器界面或停用插件时会取消当前下载；待后台进程退出后清理临时文件，再允许新请求开始，已有有效图片会保留。
- 自动配置屏保会修改 KOReader 的屏保选项。关闭该功能前不要手动清除设置备份；正常关闭开关会负责恢复原值。
