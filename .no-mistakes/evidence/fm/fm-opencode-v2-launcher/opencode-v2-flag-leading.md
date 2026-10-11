# opencode v2.0.26 launch-flag live-validation

Installed binary: `/home/azureuser/.opencode/bin/opencode` (`opencode v2.0.26`).

## 1) Pre-fix shape is rejected (root cause reproduced)

`opencode --model openai/gpt-5 --prompt "hi"` -> exit code 1, stderr:

```
ERROR
  Unrecognized flag: --model in command opencode
```

stdout is the `--help` usage text (no TUI is rendered). A lane launched with the
old `--model` flag cannot start.

## 2) Post-fix shape is accepted (lane actually starts)

`env OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"},"model":"anthropic/claude-sonnet-4-5"}' opencode --standalone --prompt "hi"`
-> still-running at the 6s timeout (exit 124) with no "Unrecognized flag".
The captured TUI renders `New session` and `Build · Claude Sonnet 4.5 (latest)`
before hitting the unrelated auth error `OAuth access token has been revoked`
(an environment credential, not a launch-shape failure).
