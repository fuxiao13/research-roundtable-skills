# Research Roundtable Skill

一个由 **Codex 主持、Kimi Code 与 DeepSeek 复核**的研究方案与实验结果审查 Skill。

Codex 是唯一执行者、裁决者和文件修改者。Kimi Code 与通过 Claude Code 调用的 DeepSeek 只接收精炼文本材料，不直接访问或修改项目。

## 当前版本更新

- 分为 `Plan`（研究方案）和 `Experiment`（实验结果）两条工作流
- Codex 首轮意见统一编号为 `[CX#]`
- Kimi 与 DeepSeek 逐条复核 `[CX#]`，新增问题标记为 `NEW`
- 保留 `Lean` 与 `Standard` 两种评审模式
- 加入输入预算与去重规则，减少模型额度消耗
- 实验裁决后加入用户授权闸门：未经明确同意，Codex 不得修改程序或重跑
- 使用独立的方案评审包和实验评审包模板

## 工作流程

### 研究方案复核

```text
研究方案与用户想法
        ↓
Codex 独立分析并生成 [CX#] 意见
        ↓
Kimi：方法闭环、可执行性、验证路径
DeepSeek：证据、统计、泄漏、隐藏假设
        ↓
Codex 合并重复意见并裁决
        ↓
Codex 修订研究方案
```

### 实验结果复核

```text
研究方案与验收标准
        ↓
Codex 运行程序并生成 [CX#] 诊断
        ↓
Kimi 与 DeepSeek 复核诊断和实验证据
        ↓
Codex 裁决并向用户报告拟修改内容
        ↓
等待用户明确授权
        ↓
Codex 修改、重跑并比较前后证据
```

## 评审模式

| 模式 | 输出范围 | Plan 输入上限 | Experiment 输入上限 |
|---|---|---:|---:|
| Lean | 只报告必须修改；没有则返回 `NO_MATERIAL_CHANGE` | 8,000 字符 | 10,000 字符 |
| Standard | 报告必须修改和推荐修改 | 16,000 字符 | 18,000 字符 |

输入限制用于促使 Codex 生成精炼评审包，不允许因此遗漏必须修改的问题。

## 额度优化

- 长方案只传结构和与 `[CX#]` 相关的必要段落
- 实验只传关键指标和最短错误片段，不传完整日志或 trace
- 两位评审不输出没有新增价值的“纯同意”
- Codex 合并重复建议，不在最终回复中逐字粘贴两份评审
- 默认采用 Lean；需要推荐修改时再使用 Standard

## 依赖

- Windows PowerShell 5.1 或更高版本
- [Codex](https://openai.com/codex/)
- Kimi Code CLI：`kimi`
- Claude Code CLI：`claude.cmd`
- Claude Code 已配置为调用 DeepSeek 模型

## 安装

在 Codex 中使用 Skill Installer：

```text
请从 GitHub 仓库 fuxiao13/research-roundtable-skills 的 research-roundtable 子目录安装 Skill。
```

或手动安装：

```powershell
git clone https://github.com/fuxiao13/research-roundtable-skills.git
Copy-Item -Recurse -Force `
  .\research-roundtable-skills\research-roundtable `
  "$HOME\.codex\skills\research-roundtable"
```

安装后重启 Codex 或开启新线程。

## 首次配置 Kimi

```powershell
& "$HOME\.codex\skills\research-roundtable\scripts\Initialize-RoundtableKimi.ps1"
```

默认数据目录为 `~/.research-roundtable/kimi`。通常只需登录一次。清理时可删除 `sessions/`、`logs/`、`cache/` 和 `telemetry/`，但应保留登录凭据、`config.toml` 和 `device_id`。

## 使用示例

```text
使用 $research-roundtable，以 Lean 模式复核这份研究方案。
```

```text
依据研究方案运行实验，然后使用 $research-roundtable 的 Experiment + Standard 工作流复核结果。裁决后先向我汇报，等我确认再修改程序。
```

## 安全边界

- 不向评审模型发送密钥、原始私有数据、模型权重或完整日志
- 不向评审模型提供项目路径或编辑工具
- Kimi 和 DeepSeek 不能自动应用修改
- Codex 必须独立裁决，不能因两位评审一致而自动采纳
- 实验裁决后必须等待用户明确授权，才能修改代码、配置或参数

## 目录结构

```text
research-roundtable/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── decision-template.md
│   ├── plan-review-packet-template.md
│   ├── experiment-review-packet-template.md
│   ├── kimi-reviewer.txt
│   └── deepseek-reviewer.txt
└── scripts/
    ├── Initialize-RoundtableKimi.ps1
    └── Invoke-ResearchRoundtable.ps1
```

## 许可证

[MIT License](LICENSE)
