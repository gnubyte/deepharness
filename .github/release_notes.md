## Download

- **`DeepHarness.dmg`** — open it and drag **DSH** into **Applications**.

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/DSH.app
```

## What's new in 0.12.0 — background subagents and background tasks

- **Background subagents.** The agent can launch a subagent with
  `run_in_background` and keep working while it runs; up to four run in
  parallel per chat. It checks on them with `agent_status` (optionally
  waiting) and stops one with `agent_stop`. Reports arrive automatically when
  an agent finishes, and a chat that went idle picks the work back up by
  itself once its background agents are done.
- **A bar above the composer** shows running background agents, with a menu
  to stop one or all. Stop in the chat (and Stop All) stops them too.
- **Background tasks.** The agent can put follow-up work on the Task Queue
  with `queue_task` (and start the queue), so it runs unattended in its own
  chat, in the same project. At most 20 per chat.
- A foreground subagent may now run for up to an hour (was 5 minutes).

## Earlier

- **0.11.0** — the Credentials Vault: API keys and passwords in the Keychain that
  the agent uses as `{{vault:NAME}}` without ever seeing them.
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
