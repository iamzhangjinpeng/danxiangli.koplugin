# 单向历 KOReader 插件

这是一个面向 Kindle 版 KOReader 的插件。它会从 OWSPACE（单向历）图片地址获取当天的单向历壁纸，并可将这张图片设为 KOReader 的锁屏屏保。

## 功能

- 按北京时间确定“今天”，下载当天的单向历图片。
- 支持自动检查，也可以从 KOReader 菜单手动下载或强制重新下载。
- 自动配置屏保：使用随机图片模式、指向插件专用图片目录、开启图片拉伸，并隐藏屏保文字。
- 开启自动配置前保存原有屏保选项；关闭该功能时恢复原设置。
- 网络请求采用 KOReader 的异步 HTTP 接口，等待服务器响应时不会一直占住阅读界面。
- 同一 KOReader 进程中同一时间只保留一个下载请求；界面切换后，旧请求的结果不会覆盖新日期的图片。
- 下载到临时文件后检查 JPEG 文件，再替换正式图片；有效的今日图片不会重复下载。
- 图片下载成功后，清理插件专用目录中的旧 `.jpg` 图片。
- 提供诊断菜单，显示今日图片、网络状态、屏保配置和最近一次请求状态。

## 安装

### 从 GitHub 安装

1. 在电脑上打开本仓库：[iamzhangjinpeng/danxiangli.koplugin](https://github.com/iamzhangjinpeng/danxiangli.koplugin)，下载仓库 ZIP 并解压。
2. 将插件文件夹命名为 `danxiangli.koplugin`。确认 `main.lua` 和 `_meta.lua` 直接位于这个文件夹内，不要多套一层同名目录。
3. 用 USB 将 Kindle 连接到电脑，把整个 `danxiangli.koplugin` 文件夹复制到 Kindle 的：

   ```text
   /mnt/us/koreader/plugins/danxiangli.koplugin/
   ```

4. 安全弹出 Kindle，然后完全退出并重新打开 KOReader。
5. 打开 KOReader 的“工具”菜单，找到“单向历”。如果菜单没有出现，确认插件目录层级正确，并检查 KOReader 的插件管理中该插件是否已启用。

KOReader 的插件目录通常位于 KOReader 安装目录下的 `plugins/` 文件夹。Kindle 上本插件使用上面的 `/mnt/us/koreader/plugins/` 路径。其他平台的安装说明可参照 [KOReader 用户指南](https://koreader.rocks/user_guide/)。

## 使用

在 KOReader 中打开“工具 → 单向历”，可以使用以下项目：

| 菜单项 | 作用 |
| --- | --- |
| 自动配置屏保 | 开启或关闭自动屏保配置。首次安装默认开启；关闭时恢复启用前保存的屏保设置。 |
| 下载今日单向历 | 检查今日图片；如果尚无有效图片则下载。 |
| 强制重新下载今日 | 忽略已有图片并重新下载；新图片校验成功后才替换旧图。 |
| 诊断 | 查看图片目录、今日图片状态、最近请求状态、网络连接和屏保设置。 |

插件启动后会稍作等待再检查；KOReader 唤醒后也会检查，并每隔一段时间进行本地状态检查。今日图片已经有效时，这些检查不会再次请求图片服务器。若 Wi-Fi 已开启但尚未连通，插件会短暂退避重试；服务器返回“未发布”（HTTP 404）时，会对当天图片暂停请求两小时。这个冷却在文件管理器和阅读器切换时仍有效，跨到新的一天后不再阻挡新日期的请求；完全重启 KOReader 后冷却状态会重置。

## 图片和设置保存位置

今日图片保存在：

```text
/mnt/us/koreader/screenshots/danxiangli/YYYYMMDD.jpg
```

其中日期按北京时间计算。插件只会清理这个专用 `danxiangli/` 目录里的旧 JPG，不会扫描或清理 `screenshots/` 根目录以及其他目录中的图片。

自动屏保开关和原屏保设置备份保存在 KOReader 的设置中，不会另外创建插件设置文件。关闭“自动配置屏保”会恢复原来的屏保类型、图片目录、拉伸选项和屏保文字选项，并清除原设置备份。

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

如果 KOReader 的插件管理界面提供“删除插件和设置”，可以使用它清除插件设置。如果界面只有“删除插件”，KOReader 可能会保留一个已关闭的开关值；该值不会在插件删除后运行或影响屏保。若仍要彻底移除设置，可在 KOReader 完全退出后备份并编辑其 `settings.reader.lua`，只删除名称为 `danxiangli_auto_screensaver`、`danxiangli_screensaver_backup` 或旧版遗留的 `danxiangli_last_date` 的设置项。不要删除整个设置文件。

## 兼容性与网络

- 当前代码面向 Kindle 版 KOReader；图片目录和设备支持声明均针对 Kindle。
- 下载需要设备可以访问 OWSPACE 图片服务器。若图片地址改变、服务器未发布当天图片或网络不可用，插件无法保证当天图片可用；可以稍后重试或使用“诊断”查看状态。
- 自动配置屏保会修改 KOReader 的屏保选项。关闭该功能前不要手动清除设置备份；正常关闭开关会负责恢复原值。
