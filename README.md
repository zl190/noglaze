# noglaze!

[![License](https://img.shields.io/github/license/zl190/noglaze?style=flat-square)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-orange?style=flat-square)](https://claude.ai/code)

**PUA makes your AI work harder. noglaze! makes sure it's not just glazing you back.**

Your AI will tell you the code is robust, handles edge cases, and is production-ready — right before it silently ignores half your requirements. noglaze! audits every Write/Edit at the system level. Bad output gets blocked. Not warned. Blocked.

---

## How it works

Every time Claude writes or edits a file, noglaze! spawns an adversarial reviewer in a clean context — no memory of what Claude just said, no motivation to be nice. The reviewer runs a backward diagnosis chain:

```
Results ← Execution ← Design ← Claims ← Target
```

If the output doesn't survive, `exit 2` fires and Claude Code blocks the tool call.

**Before noglaze!**
```
You: Write a function to parse CSV files
AI: Here's a robust CSV parser with full error handling! [writes 30 lines]
    ✅ Handles malformed rows
    ✅ Edge cases covered
    # (none of this is true)
```

**After noglaze!**
```
You: Write a function to parse CSV files
AI: [writes function]
noglaze! 🚫 FLAGGED — no error handling for malformed rows,
          no test for edge cases, claims "robust" in docstring
          but handles 0 edge cases. Prove it or revise.
AI: [rewrites with actual error handling]
noglaze! ✅ passed — 3 edge cases handled, docstring matches behavior
```

---

## Install

```bash
# One-liner (Claude Code plugin)
echo '{"plugins": ["github:zl190/noglaze"]}' >> ~/.claude/plugins.json

# Or clone and link manually
git clone https://github.com/zl190/noglaze ~/.claude/plugins/noglaze
```

That's it. No config required. Hooks activate on the next Claude Code session.

---

## What it does

| Hook | Trigger | Action |
|------|---------|--------|
| `PostToolUse` | Every `Write` or `Edit` | Spawns adversarial reviewer in clean context. `exit 2` blocks if it fails. |
| `PreCompact` | Before context compression | Saves audit state to disk so findings survive the compaction. |

Every audit is logged to `~/.noglaze/audit.jsonl` — timestamp, file, verdict, reason.

---

## Works with PUA 🔁

[PUA](https://github.com/tanweai/pua) (10k ⭐) pressures the input side — it makes Claude try harder before giving up.

noglaze! closes the loop on the output side.

```
[PUA]      → "You have the skills, push through, try harder"
[Claude]   → tries harder, writes something
[noglaze!] → "Prove it. Exit 2."
[Claude]   → actually proves it
```

Use them together: PUA to stop Claude from giving up, noglaze! to stop Claude from bullshitting.

---

## Audit trail

Every check appends a structured entry to `~/.noglaze/audit.jsonl`:

```json
{
  "ts": "2025-04-02T14:23:01Z",
  "file": "src/parser.py",
  "verdict": "FLAGGED",
  "claims": ["robust CSV parser", "handles edge cases"],
  "gaps": ["no error handling for malformed rows", "docstring unverified"],
  "exit_code": 2
}
```

Run `cat ~/.noglaze/audit.jsonl | jq` to see your AI's track record.

---

## Roadmap

- [x] PostToolUse hook — Write/Edit audit
- [x] PreCompact hook — state persistence
- [x] JSONL audit trail
- [ ] `noglaze stats` — audit summary CLI
- [ ] Configurable strictness levels (strict / default / lenient)
- [ ] Per-project `.noglaze` config override
- [ ] GitHub Action for CI/CD audit gate

---

## Contributing

Open issues for false positives — the auditor should be adversarial, not paranoid. PRs welcome.

---

## License

MIT — use it, fork it, enforce it on your teammates.

---

## Origin

Hooks aren't new — git, CI/CD, and web middleware have used them forever. We rediscovered the pattern inside [Claude Code's source](https://github.com/anthropics/claude-code): `exit 2` blocks tool calls at the system level, surviving even when the model's context degrades. noglaze! is that pattern applied to output quality.

Part of the [nano-agent-anatomy](https://github.com/zl190/nano-agent-anatomy) project: reading production agent source, rebuilding each layer, shipping what we learn.

---

*Companion to [tanweai/pua](https://github.com/tanweai/pua). Glazing not accepted. 🚫🍯*
