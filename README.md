# Codex `logs_2.sqlite` 写盘问题修复与瘦身

## 问题概述

Codex CLI、桌面应用和 IDE 扩展会把 TRACE/DEBUG 诊断事件持续写入一个 WAL 模式的 SQLite 数据库。早期版本把库放在 `~/.codex/sqlite/logs_2.sqlite`，新版本迁移到了 `~/.codex/logs_2.sqlite`。这带来两类问题：

1. 写放大。Codex 边插入边清理旧记录，WAL 被频繁改写。早期版本甚至对所有 target 默认开 TRACE，逐条记录 WebSocket payload、网络库日志和重复的 OpenTelemetry 镜像事件。设置 `RUST_LOG=warn`、关闭 analytics 或关闭 OTel 导出都不能阻止这些本地写入。
2. 膨胀残留。日志被清理后，SQLite 不会把空闲页还给文件系统。本机实测旧库在 `logs` 表清零后仍占 592.5 MiB：151,689 页里 151,495 页是空闲页。版本迁移后这个空壳留在 `~/.codex/sqlite/` 里，Codex 不再碰它。

相关资料：

- [原始问题 #17320](https://github.com/openai/codex/issues/17320)
- [SSD 写入量汇总 #28224](https://github.com/openai/codex/issues/28224)
- [停止逐条记录 WebSocket 事件 #29432](https://github.com/openai/codex/pull/29432)
- [过滤主要噪声 target #29457](https://github.com/openai/codex/pull/29457)
- [Codex CLI 0.142.0 发布说明](https://github.com/openai/codex/releases/tag/rust-v0.142.0)

## 数据库位置迁移

2026-08-26 本机实测：codex-cli 升级到 `0.150.0-alpha.8` 后，活跃库变为 `~/.codex/logs_2.sqlite`（WAL 持续活动），`~/.codex/sqlite/logs_2.sqlite` 停止写入。两个文件同时存在，所以脚本会同时探测两个路径。

## 脚本做什么

逻辑集中在 `codex_log_fix.py`，`codex-log-fix.bat` 和 `codex-log-fix.sh` 只是薄封装。

`fix` 在 `logs` 表上创建触发器：

```sql
CREATE TRIGGER IF NOT EXISTS block_log_inserts
BEFORE INSERT ON logs
BEGIN
  SELECT RAISE(IGNORE);
END;
```

新的诊断日志会被静默丢弃，会话记录不受影响。代价是 Codex 出故障时，这个库不再提供新的诊断材料。脚本不删除已有日志。

`vacuum` 先做 WAL 检查点，再执行 VACUUM 收回空闲页占用的空间。上面那个 592.5 MiB 的空库用它收缩到了 40 KiB。`status` 会显示每个库的可回收空间，有可回收量再执行。

触发器会在 Codex 更新或数据库迁移后丢失，升级后重新跑一次 `status` 和 `fix`。

## 前置条件

- Python 3。Windows 依次查找 `py -3`、`python`；shell 依次查找 `python3`、`python`。
- 探测路径：`~/.codex/logs_2.sqlite` 和 `~/.codex/sqlite/logs_2.sqlite`。设置 `CODEX_HOME` 可覆盖主目录。
- 不要求先退出 Codex；`fix` 在运行中执行即可。遇到锁冲突时退出 Codex 重试。

## 使用方法

Windows（命令提示符或 PowerShell）：

```bat
codex-log-fix.bat status
codex-log-fix.bat check 10
codex-log-fix.bat fix
codex-log-fix.bat vacuum
```

Linux/macOS，首次先加执行权限：

```sh
chmod +x ./codex-log-fix.sh
./codex-log-fix.sh status
./codex-log-fix.sh check 10
./codex-log-fix.sh fix
./codex-log-fix.sh vacuum
```

恢复持久化诊断日志：

```bat
codex-log-fix.bat undo
```

`fix`、`undo`、`vacuum` 末尾可追加数据库路径，只操作指定文件；不带参数时作用于所有探测到的库。

## 命令说明

| 命令 | 作用 |
| --- | --- |
| `status` | 列出所有探测到的 `logs_2.sqlite`：文件与 WAL 大小、行数、空闲页与可回收空间、触发器状态 |
| `check [秒数]` | 对最大日志 ID 和 WAL 状态定时采样，默认 5 秒 |
| `fix [db]` | 安装 `block_log_inserts`，阻止新的持久化诊断日志 |
| `undo [db]` | 删除触发器，恢复持久化日志写入 |
| `vacuum [db]` | WAL 检查点 + VACUUM，收回空闲页空间 |

`check` 期间让 Codex 保持活跃输出，空闲采样说明不了问题。最大 ID 增长表示仍有新日志落盘；只有 WAL 变化而 ID 不动，说明触发器已生效。

## 已确认受影响的版本

截至 2026-06-23，公开资料没有给出问题首次引入的精确版本。已确认受影响的构建：

| 产品 | 版本或构建 |
| --- | --- |
| IDE 扩展 | `openai.chatgpt-26.406.31014-linux-x64` |
| Codex Desktop | `26.616.6631.0` |
| Codex CLI | `0.128.0`、`0.137.0`（本机实测） |

Codex CLI `0.142.0` 合入了 #29432 和 #29457，移除逐 WebSocket 事件的 payload 日志，过滤 `target=log` 与两个重复 OTel target，发布说明称其为减少 persistent-log churn。该版本仍保留其他 target 的 TRACE 持久化，所以：

- 低于 `0.142.0`：存在 `logs_2.sqlite` 就值得检查，旧版本可直接用本脚本止血。
- `0.142.0` 及以上：主要噪声源少了很多，先跑 `check` 实测，写入量仍不可接受再 `fix`。
- Desktop/IDE 构建号与 CLI 版本不对应，以脚本检测结果为准。

本机实测 `0.150.0-alpha.8` 已迁移到 `~/.codex/logs_2.sqlite`，旧位置只剩膨胀残留。
