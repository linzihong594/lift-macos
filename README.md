# 轻退 · Lift

<img src="docs/icon.png" alt="轻退图标" width="96">

保持原来的操作：双击 DMG，把应用拖到“应用程序”。轻退确认应用复制完整后，正常弹出对应安装盘。

在“应用程序”中打开 **轻退.app**，可以查看后台内存、等待中的安装盘和最近完成记录，并通过主开关暂停或恢复。管理窗口关闭后会自动退出，轻量后台服务继续工作；暂停状态会保留到下次登录。

界面采用原生 SwiftUI、系统材质与字体，图标以薄荷色弹出符号和磁盘为主题，支持系统浅色与深色外观。

## 1.2 更快弹出与应用图标

复制结束后的固定长等待已缩短，通常约 **2–5 秒**自动弹出；仍逐文件核对完整内容，并检查最后的文件状态。大型应用还需要额外核对时间。磁盘被占用时每 2 秒重试正常弹出。

历史记录使用应用的实际图标，旧记录按应用名称补找，新记录保存准确安装路径并复制原有图标资源，保存过的图标在卸载应用后仍可显示。未能提取到资源且应用已被移除时使用默认图标。图像只在管理窗口中解码，缓存随当前四条记录清理，不增加后台图像处理。

## 1.1 内存优化

旧版的 Foundation 分块读取会在长期工作队列中积累临时对象，并留下大量分配器缓存。新版使用两个 128 KB 固定缓冲区比较文件内容，工作结束时释放临时对象、目录快照和空闲分配器页面。后台改为 Disk Arbitration 挂载通知，不再加载 AppKit 界面框架。

本机回归测试：64 MB 大文件及 2,000 个小文件，连续完整核对三次，旧实现约 **418 MB**，新版约 **7.5 MB**；新版多次实际弹盘后后台约 **5 MB**。这些数值来自这组测试，实际占用还会随文件数量变化。[历史测量数据](docs/performance-baseline.json)已随源码保存；运行 `python3 Tests/performance.py` 可验证当前实现并生成 `build/performance.json`。如有旧版源码，可用 `--baseline /path/to/GuardCore.swift` 做同场对比。

## 判断方式

- 从系统的磁盘映像记录读取实际卷名和设备，不根据 DMG 文件名猜测。
- 只处理只读、单个卷、根目录只有一个 `.app` 的 `.dmg`。
- 只检查 `/Applications` 和 `~/Applications` 中同名应用。
- 记录安装前的状态，避免你刚打开 DMG、尚未复制就被弹出。已经装好同一版本时，必须观察到应用目录被替换。
- 文件变化安静约 1 秒后，核对完整目录、每个文件的内容、可执行权限及符号链接，并再检查文件状态稳定。
- 只调用正常的 `diskutil eject`；被占用时等待重试，不强制弹出、不终止进程。
- 不移动、删除 DMG，也不安装应用、不更改系统安全设置。

通常在复制完成后约 2–5 秒弹出，较大的应用还需要文件核对时间。`.pkg`、多应用、多卷、可写映像、改名安装及无法完整核对的情况保留挂载，继续手动弹出。这是保守的完成检测，不能通用于所有安装器。

## 后台行为

使用原生文件事件与挂载通知。没有相关操作时停止定时检查；复制期间才进行检查。不常驻菜单栏，不需要管理员、辅助功能、录屏或完全磁盘访问权限。

登录后自动运行。应用：`/Applications/轻退.app`（系统应用目录不可写时安装到 `~/Applications`）；后台程序：应用包内的 `Contents/Library/LaunchServices/LiftAgent`。运行记录仍保存在 `~/Library/Application Support/DMG Auto Eject/`，保留旧目录是为了继承历史记录。登录服务：`~/Library/LaunchAgents/local.suis.dmg-auto-eject.plist`。日志最多保留两个约 1 MB 文件。

## 管理

需要 macOS 14 或更高版本，以及 Xcode Command Line Tools（包含 Swift 编译器）。项目无需第三方依赖。

```sh
git clone https://github.com/linzihong594/lift-macos.git
cd lift-macos
python3 manage.py install
```

本机编译并安装后，打开“应用程序 → 轻退”。应用使用本地 ad-hoc 签名，没有经过 Apple 公证。

在此目录运行：

```sh
python3 manage.py status     # 查看状态和最近日志
python3 manage.py pause      # 暂停，重启后仍暂停
python3 manage.py resume     # 恢复
python3 manage.py uninstall  # 移除轻退、后台服务及运行记录，保留源码
```

源码不依赖第三方库，使用 macOS 自带框架。`python3 manage.py install` 使用本机 Swift 编译器编译并安装应用和当前用户的登录服务；运行时不需要 Python 或编译器。升级前的程序和配置备份在 `build/upgrade-backup-*` 中。

## LiftAgent 是什么

`Lift` 是管理窗口进程，`LiftAgent` 是本项目编译生成的后台可执行文件。后者负责监测安装盘、核对复制结果和正常弹出磁盘；管理窗口关闭后它继续运行。在界面中关闭“自动弹出”开关，可以停止后台并暂停登录启动。

仓库不包含本机运行日志、安装历史、缓存图标或编译备份，只有源码、测试和项目资源。

## 验证

```sh
mkdir -p build
swiftc Sources/GuardCore.swift Tests/GuardTests.swift -o build/guard-tests
build/guard-tests
swiftc Sources/LiftState.swift Tests/HistoryTests.swift -o build/history-tests
build/history-tests
python3 manage.py build
python3 Tests/integration.py
python3 Tests/performance.py
```

集成测试只挂载自行创建的临时 DMG，并使用临时“Applications”目录，不操作真实已安装应用或其他磁盘。
