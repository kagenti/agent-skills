# rossoctl Agent Skills

Agent Skills for automated maintenance of GitHub organizations. Each skill teaches an AI agent how to perform a specific task using shell scripts and structured instructions.

Built to the [Agent Skills specification](https://agentskills.io/specification).

## Skills

| Skill | Description |
|-------|-------------|
| [link-health-scanner](skills/link-health-scanner/) | Scan repos for broken links, create GitHub issues for findings |
| [link-health-fixer](skills/link-health-fixer/) | Re-verify and fix broken links, open PRs for fixes |
| [dep-bump-scanner](skills/dep-bump-scanner/) | Monitor Dependabot PRs, classify by severity, flag SLA breaches |
| [dep-bump-fixer](skills/dep-bump-fixer/) | Analyze stale Dependabot PRs and post commentary to accelerate review |
| [automation-health-dashboard](skills/automation-health-dashboard/) | Generate executive-facing dashboard combining all program metrics |
| [github-weekly-report](skills/github-weekly-report/) | Generate weekly org activity reports with merged PRs, CI health, and active-epic tracking |
| [github-pr-review](skills/github-pr-review/) | Automated PR review: conventions, security, CI status, inline comments |
| [byo-rossoctl-cortex](skills/byo-rossoctl-cortex/) | Bring up a local rossoctl cortex (AuthBridge plugin pipeline) to host an agent; per-agent LiteLLM budget tracking isolated by env var |

## Installation

### Claude Code (plugin marketplace)

```
/plugin marketplace add rossoctl/agent-skills
/plugin install link-health@rossoctl-agent-skills
```

### Manual

Copy the desired skill directory into your project's `.claude/skills/` directory:

```bash
cp -r skills/link-health-scanner /path/to/project/.claude/skills/
```

## Prerequisites

All skills in this repo require:

- `bash` 4+
- `gh` (GitHub CLI, authenticated)
- `jq`

Individual skills may have additional requirements documented in their `SKILL.md`.

## License

Apache-2.0. See [LICENSE](LICENSE).
