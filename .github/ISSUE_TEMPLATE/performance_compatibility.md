---
name: 性能或设备兼容性
about: 报告帧 pacing、温度、内存、音频时序或设备相关问题。
title: "perf: "
labels: [performance, compatibility]
assignees: []
---

<!-- player-support:guidance -->
性能或兼容性问题可先按[日志导出说明](https://github.com/Nishikori-Yui/lordran-native/blob/main/README.zh-CN.md#排查问题)收集报告，再把日志、场景和复现操作交给 agent。读取[玩家辅助 skill](https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md)后，agent 可以帮助脱敏并生成可粘贴的反馈。请区分出错时的数据与导出瞬间的快照；也可以直接手动填写。
<!-- /player-support:guidance -->

## 问题概述

<!-- player-support:summary -->

## 运行环境

- 设备：<!-- player-support:device -->
- 系统版本：<!-- player-support:os -->
- Lordran Native 版本、commit 或 IPA 构建版本：<!-- player-support:build -->
- 游戏版本 / 更新版本：<!-- player-support:game_version -->
- 屏幕刷新率：<!-- player-support:refresh_rate -->
- 手柄 / 音频输出路径：<!-- player-support:controller -->

## 测量数据

- 目标帧率：<!-- player-support:target_fps -->
- 实际帧率或帧时间范围：<!-- player-support:actual_fps -->
- 运行多久后出现问题：<!-- player-support:duration -->
- 测量时间 / 时区：<!-- player-support:time -->
- 测量场景、画质及分辨率 / MSAA 设置：<!-- player-support:settings -->
- 温度状态（如已知）：<!-- player-support:thermal -->
- 内存占用（如已知）：<!-- player-support:memory -->

<!-- Keep full reports private. Paste only a short sanitized excerpt; remove personal paths, identifiers, machine addresses and access details while preserving timing, units and counters. Distinguish physical-device and Simulator results. -->

<!-- player-support:logs -->
```text
请粘贴简短、脱敏后的测量数据或诊断日志片段；没有数据时请说明。
```
<!-- /player-support:logs -->

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

## 对比情况

<!-- Does another device, mode, graphics setting, or build behave differently? -->
<!-- player-support:comparison -->

## 定位情况

- 已确认的现象：
<!-- player-support:observed -->
- 疑似原因（尚未证实）：<!-- player-support:suspected -->
- 缺失信息 / 待验证事项：<!-- player-support:missing -->
- 相关 issue / PR（如有）：
<!-- player-support:related -->

## 检查清单

- [ ] 我测试了全新启动，并记录了使用的构建版本和设备。
- [ ] 在可能的情况下，我提供了测量数据。
- [ ] 我已删除私钥、NSP、存档和无关的个人数据。
- [ ] 我区分了已确认现象、疑似原因和尚未验证的结论。
