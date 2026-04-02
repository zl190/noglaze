# noGlaze!

[![License](https://img.shields.io/github/license/zl190/noglaze?style=flat-square)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-orange?style=flat-square)](https://claude.ai/code)

[English](README.md) | 中文

**PUA让AI更努力。noGlaze!让它别自己夸自己。**

你的AI会说代码"健壮"、"处理了边界情况"、"生产级别"——然后偷偷忽略一半需求。noGlaze!在系统层审计每一次Write/Edit。不合格的输出直接拦截，不是警告，是block。

---

## 原理

每次Claude写文件或改文件，noGlaze!自动spawn一个全新的对抗审查员——没有共享记忆，不知道Claude刚说了什么，没有任何动机说好话。审查员跑一条反向诊断链：

```
结果 ← 执行 ← 设计 ← 声明 ← 目标
```

过不了？`exit 2`，Claude Code直接block这次工具调用。

**安装前**
```
你: 写一个CSV解析器
AI: 这是一个健壮的CSV解析器，完整的错误处理！[写了30行]
    ✅ 处理了格式错误的行
    ✅ 边界情况全覆盖
    # (以上全是编的)
```

**安装后**
```
你: 写一个CSV解析器
AI: [写了代码]
noGlaze! 🚫 标记 — 没有格式错误处理，没有边界测试，
          docstring写了"健壮"但处理了0个边界情况。证明或重写。
AI: [重写，加了真正的错误处理]
noGlaze! ✅ 通过 — 3个边界情况已处理，docstring与行为一致
```

---

## 安装

```bash
# 一行搞定（Claude Code插件）
echo '{"plugins": ["github:zl190/noglaze"]}' >> ~/.claude/plugins.json

# 或者手动clone
git clone https://github.com/zl190/noglaze ~/.claude/plugins/noglaze
```

不需要配置。下次启动CC自动生效。

---

## 三个Hook

| Hook | 触发条件 | 做什么 |
|------|----------|--------|
| `PreToolUse` | `git push`、`gh repo create`、`gh pr create` | 没有测试证据就拦截外部操作。基于注册表——可以加自定义模式。 |
| `PostToolUse` | 每次`Write`或`Edit` | spawn对抗审查员。不通过就`exit 2` block。 |
| `PreCompact` | 上下文压缩前 | 保存审计状态到磁盘，确保审计记录不被压缩掉。 |

所有审计写入 `~/.noglaze/audit.jsonl`——时间戳、文件、结论、原因。

---

## 配合PUA使用 🔁

[PUA](https://github.com/tanweai/pua)（10k ⭐）管输入端——逼Claude不要放弃。

noGlaze!管输出端——逼Claude证明自己。

```
[PUA]      → "你有能力，继续干，别放弃"
[Claude]   → 努力写了一版
[noGlaze!] → "证明一下。exit 2。"
[Claude]   → 真的改好了
```

一起用：PUA让Claude不敢摆烂，noGlaze!让Claude不敢糊弄。

---

## 审计记录

每次检查都append到 `~/.noglaze/audit.jsonl`：

```json
{
  "ts": "2025-04-02T14:23:01Z",
  "file": "src/parser.py",
  "verdict": "FLAGGED",
  "claims": ["健壮的CSV解析器", "处理了边界情况"],
  "gaps": ["没有格式错误处理", "docstring未验证"],
  "exit_code": 2
}
```

运行 `cat ~/.noglaze/audit.jsonl | jq` 查看你的AI的表现记录。

---

## 路线图

- [x] PostToolUse hook — Write/Edit审计
- [x] PreToolUse hook — 推送前检查（拦截未测试的push）
- [x] PreCompact hook — 状态持久化
- [x] JSONL审计记录
- [x] 基于注册表的外部操作检测
- [ ] `noglaze stats` — 审计摘要CLI
- [ ] 可配置严格等级（严格/默认/宽松）
- [ ] 项目级 `.noglaze` 配置覆盖
- [ ] GitHub Action用于CI/CD审计门控

---

## 贡献

欢迎提issue报告误报——审查员应该是对抗性的，不是偏执的。PR欢迎。

---

## 协议

MIT

---

## 起源

Hook不是新东西——git、CI/CD、web中间件用了几十年。我们在[Claude Code的源码](https://github.com/anthropics/claude-code)中重新发现了这个模式：`exit 2`在系统层拦截工具调用，即使模型上下文退化也不受影响。noGlaze!就是把这个模式用在了输出质量上。

属于 [nano-agent-anatomy](https://github.com/zl190/nano-agent-anatomy) 项目的一部分：读生产级Agent源码，逐层重建，把学到的东西做成产品。

---

*[tanweai/pua](https://github.com/tanweai/pua) 的伴侣项目。Glazing不被接受。🚫🍯*
