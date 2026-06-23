# Codex `logs_2.sqlite` 持续写盘问题及临时修复

## 问题概述

部分 Codex CLI、桌面应用和 IDE 扩展会把大量 `TRACE`/`DEBUG` 诊断事件持续写入 `~/.codex/logs_2.sqlite`。数据库采用 WAL 模式，因此即使主数据库文件大小看似稳定，`logs_2.sqlite-wal` 仍可能被频繁改写；Codex 同时插入并清理旧记录，容易造成明显的 SQLite 写放大、性能下降和不必要的 SSD 磨损。

公开报告显示，SQLite 持久化日志曾对所有 target 默认启用 `TRACE`，并记录 WebSocket payload、底层网络库日志以及重复的 OpenTelemetry 镜像事件。设置 `RUST_LOG=warn`、关闭 analytics 或关闭 OTel 导出不能可靠阻止这些本地 SQLite 写入。

相关资料：

- [原始问题 #17320](https://github.com/openai/codex/issues/17320)
- [SSD 写入量汇总 #28224](https://github.com/openai/codex/issues/28224)
- [停止逐条记录 WebSocket 事件 #29432](https://github.com/openai/codex/pull/29432)
- [过滤主要噪声 target #29457](https://github.com/openai/codex/pull/29457)
- [Codex CLI 0.142.0 发布说明](https://github.com/openai/codex/releases/tag/rust-v0.142.0)

## 已确认的版本范围

截至 2026-06-23，公开资料没有给出该问题首次引入的精确 CLI 版本，因此不能把某个版本写成确定下界。已确认受影响的版本/构建包括：

| 产品 | 已确认受影响版本或构建 |
| --- | --- |
| IDE 扩展 | `openai.chatgpt-26.406.31014-linux-x64` |
| Codex Desktop | `26.616.6631.0` |
| Codex CLI | `0.128.0`、本机实测的 `0.137.0` |

官方在 Codex CLI `0.142.0` 中合入了 #29432 和 #29457，移除了逐 WebSocket 事件的 payload 日志，并过滤 `target=log` 与两个重复 OTel target。发布说明将其描述为“减少 persistent-log churn”。该版本仍保留其他 target 的 TRACE 持久化，因此：

- `< 0.142.0`：若存在 `logs_2.sqlite`，建议检查，已确认的旧版本可使用本脚本止血。
- `>= 0.142.0`：主要噪声源已显著减少，应先运行 `check` 实测；只有仍存在不可接受的持续写入时才使用 `fix`。
- Desktop/IDE 构建号与 CLI 版本不一一对应，应以脚本检测结果为准。

## 脚本原理和影响

两个脚本使用 Python 3 标准库中的 `sqlite3`，在 `logs` 表上创建以下触发器：

```sql
CREATE TRIGGER IF NOT EXISTS block_log_inserts
BEFORE INSERT ON logs
BEGIN
  SELECT RAISE(IGNORE);
END;
```

该触发器会静默忽略新的持久化诊断日志，不修改会话记录。代价是出现 Codex 故障时，这个数据库不再提供新的诊断日志。脚本不会删除现有日志，也不会执行 `VACUUM`，从而避免对大型数据库进行一次性全量重写。

Codex 更新或数据库迁移可能删除触发器。更新后可再次运行 `status` 和 `check`。

## 前置条件

- Python 3：Windows 脚本依次查找 `py -3`、`python`；shell 脚本依次查找 `python3`、`python`。
- 默认数据库路径为 `%USERPROFILE%\.codex\logs_2.sqlite` 或 `$HOME/.codex/logs_2.sqlite`。
- 若使用自定义目录，请提前设置 `CODEX_HOME`。
- 建议在执行 `fix` 或 `undo` 前完全退出 Codex Desktop、CLI 和 IDE 扩展，避免数据库锁冲突。

## Windows 使用方法

在命令提示符或 PowerShell 中执行：

```bat
codex-log-fix.bat status
codex-log-fix.bat check 10
codex-log-fix.bat fix
codex-log-fix.bat check 10
```

`check 10` 会采样 10 秒。检测问题时，应让 Codex 正在生成并流式返回内容。最大日志 ID 增长表示确有新日志持久化；只有 WAL 修改时间变化、但最大 ID 不变，表示存在 WAL 活动，但触发器已阻止新日志行。

恢复持久化诊断日志：

```bat
codex-log-fix.bat undo
```

## Linux/macOS 使用方法

首次使用时增加执行权限：

```sh
chmod +x ./codex-log-fix.sh
```

然后执行：

```sh
./codex-log-fix.sh status
./codex-log-fix.sh check 10
./codex-log-fix.sh fix
./codex-log-fix.sh check 10
```

恢复持久化诊断日志：

```sh
./codex-log-fix.sh undo
```

## 命令说明

| 命令 | 作用 |
| --- | --- |
| `status` | 显示 Codex 版本、数据库/WAL 大小、日志级别统计和触发器状态 |
| `check [秒数]` | 对日志最大 ID 与 WAL 状态进行定时采样，默认 5 秒 |
| `fix` | 创建 `block_log_inserts`，阻止新的持久化诊断日志写入 |
| `undo` | 删除触发器，恢复持久化诊断日志写入 |

`check` 在空闲期可能得出“未检测到写入”，这不能排除流式响应期间存在问题。应在 Codex 活跃输出时检测，并在应用修复后用相同负载复测。判断触发器是否有效应以最大日志 ID 不再增长为准；WAL 修改时间可能因 SQLite 事务或检查点操作变化。
