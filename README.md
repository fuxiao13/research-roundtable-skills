# Research Roundtable Skill

一个由 **Codex 主持、Kimi Code 与 DeepSeek 评审**的多模型研究与技术审查 Skill。

Codex 是唯一执行者和文件修改者；Kimi Code 与通过 Claude Code 调用的 DeepSeek 只接收精炼文本评审包，不能直接修改项目。

## 核心流程

```text
用户目标与项目结果
        ↓
Codex 独立首轮判断
        ↓
Kimi：方法闭环、工程可行性、验证路径
DeepSeek：证据强度、统计缺陷、数据泄漏、隐藏假设
        ↓
Codex 合并重复意见并逐条裁决
        ↓
仅由 Codex 修改项目并重新验证
```

## 特性

- Codex 保持唯一写入权限
- Kimi 与 DeepSeek 在隔离工作目录运行
- DeepSeek 通过 Claude Code 客户端调用，禁用工具和会话持久化
- Kimi 使用一次性提示模式，不接收项目文件路径
- `Lean` 与 `Standard` 两档评审门槛
- 不按固定条数截断评审意见
- Kimi 缓存集中保存，方便定期清理
- 支持研究方案、实验结果、程序输出、指标、日志摘要和代码修改方案评审

## 依赖

- Windows PowerShell 5.1 或更高版本
- [Codex](https://openai.com/codex/)
- Kimi Code CLI，命令名为 `kimi`
- Claude Code CLI，命令名为 `claude.cmd`
- Claude Code 已配置为调用 DeepSeek 模型

## 安装

在 Codex 中使用 Skill Installer：

```text
请从 GitHub 仓库 fuxiao13/research-roundtable-skills 的 research-roundtable 子目录安装 Skill。
```

也可以手动复制：

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

默认数据目录：

```text
~/.research-roundtable/kimi
```

通常只需登录一次。清理缓存时可删除 `sessions/`、`logs/` 和 `cache/`，但应保留认证配置。

## 使用

在任意项目中告诉 Codex：

```text
使用 $research-roundtable 执行当前项目，整理结果，交给 Kimi 和 DeepSeek 评审；逐条裁决，只由 Codex 修改并重新验证。
```

默认使用 `Lean` 模式。也可以指定：

```text
使用 $research-roundtable，以 Standard 模式评审当前实验结果。
```

### 模式

| 模式 | 适用场景 | 输入上限 | 输出范围 |
|---|---|---:|---|
| Lean | 轻量检查、日常迭代 | 16,000 字符 | 只报告必须修改的问题；没有则返回 `NO_MATERIAL_CHANGE` |
| Standard | 研究方案和实验结果的正常评审 | 24,000 字符 | 报告全部必须修改与推荐修改，并明确分级 |

模式按问题对结论和决策的影响划分，不按固定条数划分。任何“必须修改”问题都不得因长度或额度考虑被省略。

## 安全边界

- 不向评审模型发送密钥、原始私有数据、模型权重或完整日志
- 不向评审模型提供项目路径
- 不允许评审模型自动应用修改
- Codex 必须在修改前记录接受、部分接受或拒绝及理由
- 修改后必须重新执行与验证

## 目录结构

```text
research-roundtable/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   ├── decision-template.md
│   ├── review-packet-template.md
│   ├── kimi-reviewer.txt
│   └── deepseek-reviewer.txt
└── scripts/
    ├── Initialize-RoundtableKimi.ps1
    └── Invoke-ResearchRoundtable.ps1
```

## 许可证

[MIT License](LICENSE)
