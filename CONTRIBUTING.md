# 参与贡献 / Contributing

欢迎提交问题、文档改进和 Pull Request。中文或英文均可。

## 报告问题

请通过 [Issues](https://github.com/linzihong594/lift-macos/issues) 描述：

- macOS 版本、Mac 架构和轻退版本。
- DMG 的布局、应用是否保持原名、实际安装位置。
- 最小复现步骤、预期结果和实际结果。
- 必要时附上 `python3 manage.py status` 的相关输出片段。

日志可能包含应用名称和个人文件路径。提交前请删去用户名、私人路径和其他无关信息，无需附上整个本地数据目录。

## 本地开发

需要 macOS 14+、兼容的 Xcode Command Line Tools 或 Xcode，以及 Python 3.9+。无需安装第三方库。

```sh
git clone https://github.com/linzihong594/lift-macos.git
cd lift-macos
python3 manage.py build
```

应用输出为 `build/轻退.app`。`build` 不安装或注册登录服务；`install` 才会安装。

### 核心与历史记录测试

```sh
mkdir -p build
xcrun swiftc Sources/GuardCore.swift Tests/GuardTests.swift -o build/guard-tests
build/guard-tests
xcrun swiftc Sources/LiftState.swift Tests/HistoryTests.swift -o build/history-tests
build/history-tests
python3 Tests/ManagerTests.py
```

### 集成与内存回归

```sh
python3 manage.py build
python3 Tests/integration.py
python3 Tests/performance.py
```

集成测试创建并挂载自己的临时 DMG，在 `/private/tmp` 下使用隔离的应用目录和测试后台，不操作真实已安装应用或其他磁盘。结果保存在 `build/last-integration.log`。

性能测试连续核对三次包含 64 MiB 大文件和 2,000 个小文件的模拟应用，输出 `build/performance.json`。如需比较历史实现：

```sh
python3 Tests/performance.py --baseline /path/to/old/GuardCore.swift
```

## 提交变更

- 让每次变更解决一个明确问题，并说明触发条件和最终行为。
- 修改复制判断或弹出逻辑时，验证未开始复制、慢速复制、取消复制、同版本已安装和磁盘被占用等情况。
- 仅使用正常弹出；新增安装方式必须有可复核的完成判断。
- 对行为变更补充相应测试；文档或资源调整只做必要验证。
- 共享用户可见信息时同步中英文 README，必要时更新 `CHANGELOG.md`。
- 不提交 `build/`、编译应用、安装映像、运行日志、个人安装历史、缓存图标或凭据。

提交 Pull Request 时，简述问题、变更后的行为及已完成的验证。贡献内容按本项目 [MIT License](LICENSE) 分发。

## English

Issues and pull requests are welcome in Chinese or English. Include your macOS version, architecture, Lift version, DMG layout, destination and minimal reproduction steps. Redact private paths from logs before posting them.

Use the commands above to build and test. Integration tests mount only their own temporary DMGs and use isolated application folders. Keep changes focused, preserve normal non-forced ejection, and test incomplete copies, cancellation, already-installed versions and busy disks when changing completion detection. Update both READMEs for shared user-facing information and submit contributions under the project's MIT License.
