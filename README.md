# Research Roundtable Skill

一个由 Codex 主持、Kimi Code 与 DeepSeek 只读复核的科研圆桌 Skill。Codex 是唯一执行者、裁决者和文件修改者。

## 工作流

- `Plan`：研究问题、创新性、基线、泄漏、统计和发表可行性。
- `Procedure`：实验流程、参数冻结、记录、安全、停止条件和复现性；不执行实验。
- `Experiment`：Codex 唯一执行和调试，两位 reviewer 只审查执行摘要与证据。

任何修改都必须先形成 `Pending Change Set`，等待用户明确授权。

## 模式与范围

| 模式 | 用途 | Reviewer | 输出 |
|---|---|---:|---|
| BudgetLean | 日常快速检查 | 1 | MUST_FIX |
| Lean | 普通双评审 | 2 | MUST_FIX |
| Standard | 定稿、正式实验或投稿前 | 2 | MUST_FIX + RECOMMENDED |

- `Full`：首次审查、结构大改和最终检查。
- `Diff`：只复查小范围修改及上一轮未解决的 MUST_FIX，不能冒充全文审查。

## 稳健性与额度控制

- 调用前 preflight；材料严重缺失时不调用模型。
- 隔离烟测采用24小时配置指纹缓存。
- 完全相同输入使用 exact review cache，不做相似内容复用。
- 支持锚点式压缩和 reviewer-specific packet。
- 完整 raw 输出永不截断；normalized 使用 JSONL。
- 每轮生成 `roundtable-manifest.json` 和 `roundtable-issue-ledger.jsonl`。
- Lean/BudgetLean 不自动重试格式；默认只读 manifest、JSONL 和 ledger。
- reviewer 失败或格式异常时明确降级为 partial，不生成伪圆桌结论。

## 依赖

- Windows PowerShell 5.1+
- Codex
- Kimi Code CLI：`kimi`
- Claude Code CLI：`claude.cmd`

## 安装

```text
请从 GitHub 仓库 fuxiao13/research-roundtable-skills 的 research-roundtable 子目录安装 Skill。
```

或：

```powershell
git clone https://github.com/fuxiao13/research-roundtable-skills.git
Copy-Item -Recurse -Force `
  .\research-roundtable-skills\research-roundtable `
  "$HOME\.codex\skills\research-roundtable"
```

首次配置 Kimi：

```powershell
& "$HOME\.codex\skills\research-roundtable\scripts\Initialize-RoundtableKimi.ps1"
```

## 使用示例

```text
使用 $research-roundtable，以 Lean + Full 审查这份研究方案。
```

```text
使用 $research-roundtable，以 Procedure + BudgetLean 检查这份实验流程能否直接执行。
```

```text
依据研究方案执行实验，然后使用 Experiment + Standard 审查执行证据；裁决后等待我授权再修改。
```

## 安全边界

- Reviewer 只能读取提供的 packet，不得读取项目、运行命令或修改文件。
- 不发送密钥、完整私有数据、模型权重或冗长日志。
- Reviewer 意见按证据和职责裁决，不按多数票自动采纳。
- 未经用户授权，Codex 不得应用评审后的修改。

## 目录结构

```text
research-roundtable/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── packet 与裁决模板
│   └── 模块化 reviewer 规则
└── scripts/
    ├── Initialize-RoundtableKimi.ps1
    └── Invoke-ResearchRoundtable.ps1
```

## 许可证

[MIT License](LICENSE)
