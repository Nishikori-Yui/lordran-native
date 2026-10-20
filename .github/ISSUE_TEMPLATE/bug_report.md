---
name: 问题报告
about: 报告可复现的运行、构建、图形、音频、输入或闪退问题。
title: "bug: "
labels: [bug]
assignees: []
---

<!-- player-support:guidance -->
遇到 bug 时，可先按[日志导出说明](https://github.com/Nishikori-Yui/lordran-native/blob/main/README.zh-CN.md#排查问题)导出报告，再把日志和复现操作交给 Codex、Claude Code 等 agent。让 agent 读取[玩家辅助 skill](https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md)，帮助脱敏并填写本模板，你可以预览后直接粘贴反馈。也可以自行填写；请勿公开原始私有日志、密钥或游戏文件。
<!-- /player-support:guidance -->

## 问题概述

<!-- Describe the problem in one or two sentences. -->
<!-- player-support:summary -->

## 运行环境

- 设备 / Mac：<!-- player-support:device -->
- 系统版本：<!-- player-support:os -->
- Lordran Native 版本、commit 或 IPA 构建版本：<!-- player-support:build -->
- 游戏版本 / 更新版本：<!-- player-support:game_version -->
- 安装方式：<!-- player-support:install -->
- 手柄型号（如适用）：<!-- player-support:controller -->

## 复现步骤

<!-- player-support:steps -->
1.
2.
3.
<!-- /player-support:steps -->

## 预期行为

<!-- player-support:expected -->

## 实际行为

<!-- player-support:actual -->

## 诊断信息

<!-- Paste a short sanitized excerpt with useful timestamps, error codes and units. Keep full reports private; remove personal paths, usernames, device identifiers, machine addresses, access details and private game data. -->

- 日志时间 / 时区：<!-- player-support:time -->
- 复现频率：<!-- player-support:frequency -->
- 最后一个正常工作的版本：<!-- player-support:last_good -->
- 重启 App 后是否仍然出现：<!-- player-support:restart -->

<!-- player-support:logs -->
```text
请粘贴脱敏后的相关日志片段；没有日志时请说明。
```
<!-- /player-support:logs -->

## 定位情况

- 已确认的现象：
<!-- player-support:observed -->
- 疑似原因（尚未证实）：<!-- player-support:suspected -->
- 缺失信息 / 待验证事项：<!-- player-support:missing -->
- 相关 issue / PR（如有）：
<!-- player-support:related -->

## 其他信息

<!-- Do not attach NSP files, keys, or private game data. -->

## 检查清单

- [ ] 我测试了最新构建，或注明了实际测试的 commit / IPA。
- [ ] 我已删除私钥、NSP、存档和无关的个人数据。
- [ ] 我提供了复现步骤和相关诊断信息。
- [ ] 我区分了已确认现象、疑似原因和尚未验证的结论。
