# 第一阶段功能测试

所有扫描、报告和容量读数必须来自真实文件系统。界面不得填入示例占用数据。第一阶段扫描只读，不包含删除或移至废纸篓功能。

## 环境与构建

支持 macOS 14 或更新版本、Apple Silicon。构建目录、编译缓存和默认自测夹具放在项目所在外置卷。内部磁盘紧张时不得把大文件夹具或编译缓存放到 `/tmp`。Swift 驱动在部分 exFAT 外置卷的临时目录中会崩溃，因此只允许少量短期编译文件进入内部临时目录；模块缓存明确放在外置卷。

```sh
cd '/Volumes/DOJA01/有亿点想法/DOJA-Mac-Doctor'
mkdir -p .build/ClangCache .build/ModuleCache
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ClangCache" TMPDIR=/private/tmp/ \
swift build --disable-sandbox --product doctor-scan --jobs 2 --disable-index-store --scratch-path .build \
  --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/ModuleCache"
.build/debug/doctor-scan --self-check
```

`--self-check` 是独立验证入口，不依赖 XCTest 或完整 Xcode。它会在外置卷创建自己的 UUID 子目录，在该子目录中建立少量真实文件。只删除它自己创建的子目录，不触碰授权扫描的用户数据。若外置文件系统不支持稀疏文件、硬链接或 POSIX 权限，会明确显示对应检查未执行。构建的 `--disable-sandbox` 仅关闭本项目 SwiftPM 清单进程的额外沙箱，以适配开发会话已有的外层沙箱，不改变应用或 macOS 的安全设置。

需要在内部 APFS 卷实际检查稀疏文件、硬链接和权限时，显式指定小夹具选项：

```sh
.build/debug/doctor-scan --self-check --fixture-root /private/tmp/doja-doctor-small-fixtures \
  --allow-small-internal-fixtures
```

常规测试文件内容合计不超过 256 KiB，内部卷最终已分配总量断言不超过 512 KiB。稀疏文件的逻辑大小是 8 MiB，另行断言内部卷实际分配不超过 64 KiB；它不是写入 8 MiB 的测试数据。测试结束后清理该次 UUID 子目录。

完整 Xcode 提供 XCTest 时也可以运行：

```sh
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ClangCache" TMPDIR=/private/tmp/ \
swift test --disable-sandbox --jobs 2 --disable-index-store --scratch-path .build \
  --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/ModuleCache"
```

## 真实文件自动验证

- 与已知字节长度的真实文件比较，确认逻辑大小准确。
- 大文件阈值和最近 7 天新增/修改条件；不能把刚创建但设置了旧修改日期的文件直接视为旧文件。
- 重复根目录、包含关系根目录不会重复扫描。
- 子目录符号链接、根目录符号链接和带符号链接的祖先路径不得越过授权边界。
- 硬链接逻辑大小按路径显示，物理大小按文件身份去重；目录元数据单独考虑。
- 稀疏文件逻辑长度与 `st_size` 一致，分配大小与 `st_blocks × 512` 一致。
- 无权限或不存在目录明确报告未扫描；不完整状态传播到父目录。
- 暂停阻止扫描推进；暂停时取消须在 2 秒内返回；恢复可以正常完成。
- Codex 会话、配置、工程代码、原始媒体不会获得绿色或黄色删除建议。
- Crashpad/pending、项目依赖提供带风险的建议，并且实际文件仍存在。
- 超过 50 个缓存文件中混入微小用户代码，保护判断仍检查所有文件，不能只依赖排名结果。
- 两次相同范围的真实扫描能看到新增文件引起的增长；取消、不同范围、反向时间和不完整目录不得构成错误基线。

## 本机只读验收

用用户授权的目录作参数，先做限定范围扫描，再按需要扩大授权范围。例：

```sh
.build/debug/doctor-scan --threshold-mb 100 \
  --project '/Volumes/DOJA01/有亿点想法/DOJA-Mac-Doctor' \
  --output '/Volumes/DOJA01/有亿点想法/DOJA-Mac-Doctor/scan-before.json' \
  '/Users/doja/.codex' '/Users/doja/Library/Application Support/Codex'
```

输出路径显式指定时会替换该文件。JSON 使用毫秒时间戳保存扫描时间，避免短间隔扫描丢失先后顺序。保存报告是唯一授权扫描结果写操作；未指定 `--output` 不写报告。

待实际工作一段时间后，对完全相同的目录再扫描并比较：

```sh
.build/debug/doctor-scan --compare '/Volumes/DOJA01/有亿点想法/DOJA-Mac-Doctor/scan-before.json' \
  --output '/Volumes/DOJA01/有亿点想法/DOJA-Mac-Doctor/scan-after.json' \
  '/Users/doja/.codex' '/Users/doja/Library/Application Support/Codex'
```

专项结果须核对真实路径、最后修改时间、逻辑大小、已分配大小和风险说明。目录大小存在包含关系，不可相加。授权范围之外的文件无法被诊断。

## 原生界面验收

启动应用后，首页容量、Swap、内存压力都来自本机系统；未经扫描时展示未取得或等待扫描。授权目录后查看进度、暂停、恢复、取消，确认界面持续响应。目录与文件排名、最近大文件、专项诊断中检查完整路径及 Finder 定位。无权限目录必须有明显的未扫描提示。菜单栏剩余空间须与首页一致。

第一阶段没有异常发生前的监控记录时，只能给出当前占用和可核实的增长线索，必须显示“原因待确认”。APFS 克隆、快照、扫描范围外硬链接和共享容器会影响真正可回收的物理空间，不能用逻辑总量或已分配总量承诺释放量。第二阶段的每分钟历史、10 分钟减少超过 3 GB 的事件阈值与数据库容量限制另行验收；第三阶段的用户确认、废纸篓和实际释放量另行验收。

## 本次实际执行记录

实际构建、自测、只读扫描与 UI 验证结果由执行者追加，不能以计划替代已完成的检查。未经执行的项目应标为待验证，不得报告为通过。
