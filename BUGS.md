
## Medium priority (auto-fix pending)

### Codex (2026-08-03T02:06Z)
- [ ] MEDIUM: `skills/plan-codex/SKILL.md:51` gives `codex exec --sandbox read-only` as the mandatory fallback without supplying a prompt or analyzer instructions. The CLI reads stdin when no prompt is supplied, so this retry can hang or return output that does not follow the required verdict grammar.
  - New copy throughout the diff uses em dashes despite the repository copy-voice mandate prohibiting them.
