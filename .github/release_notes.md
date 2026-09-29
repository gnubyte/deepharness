## Download

- **`DeepHarness.dmg`** — open it and drag **DSH** into **Applications**.

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/DSH.app
```

## What's new in 0.11.0 — the Credentials Vault

Keep API keys, tokens and passwords where the agent can use them without ever
seeing them.

- **Credentials Vault** (key button in the toolbar, or ⌘⇧K): add, search,
  edit and delete credentials — name, kind, description, username, URL, tags.
  Values are encrypted in your macOS Keychain; the list shows each value as a
  SHA-256 fingerprint. **Reveal** or **Copy** the real value after Touch ID or
  your login password.
- **The agent uses credentials by name.** It finds them with `vault_search`
  and writes `{{vault:NAME}}` where the value goes — a shell command
  (`export OPENAI_API_KEY={{vault:OPENAI_API_KEY}}`), a `.env` file it writes,
  a URL or a header. The harness puts the real value in only when the tool
  runs, and replaces every vault value in every tool result with
  `[vault:NAME]`. The value never reaches the model, the chat or the logs.
- **Per-credential access:** *Agent may use*, *Ask first* (once per chat), or
  *Never*. Use counts and last-used times are shown.
- **Works with skills:** skills can refer to `{{vault:NAME}}`, and generated
  skills are told to do so instead of embedding secrets. Subagents use the
  vault the same way.

## Earlier

- **0.10.0** — the queue works unattended: model outages retry until the model
  is back, `/goal` runs with no round cap until the model says it's done, and
  a long list of Task Queue fixes.
- **0.9.0** — the Task Queue: queue up work and let the harness run it
  unattended, one task at a time, with a timestamped log.

- **0.8.1** — SGLang 400 fix: tool parameter schemas are always valid JSON
  objects (five specs shipped corrupted in 0.8.0).
- **0.8.0** — Interact with live processes and the machine: `process_*` tools
  (start/read/write/stop/list with streaming, until-matching, named keys),
  `screenshot` / `list_windows` / `screen_watch` / `ui_tree` /
  `inspect_process` / `mouse` / `keyboard` / `focus_app` / `view_image`, and
  the baked-in godot-debugging skill.
- **0.7.0** — Skills: generate, approve, import, export, per-chat selection.
