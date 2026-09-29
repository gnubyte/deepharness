## Download

- **`DeepHarness.dmg`** — open it and drag **DSH** into **Applications**.

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/DSH.app
```

## What's new in 0.9.0 — the Task Queue

Queue up work and let the harness grind through it unattended, all week:

- **Task Queue panel** (toolbar button or ⌘⇧Q): a long, ordered checklist.
  Add tasks (title + details, or to the front), edit, delete, and drag to
  reorder. Each task is worked as an autonomous `/goal` until the model
  declares it complete.
- **Runs one task at a time, top to bottom** — when a task finishes, the next
  queued task is picked up automatically. Press Stop to pause (the current
  task goes back in line); an interrupted queue (crash, restart) resumes on
  launch, a deliberately stopped one stays stopped.
- **Unattended goal protocol**: queued tasks run with an "no user present"
  instruction set — the model decides things it can decide itself and only
  reports `GOAL_BLOCKED` for true walls. Permission prompts on queue tasks
  auto-deny after 5 minutes instead of stalling the whole queue.
- **Readable timestamped log** (💬 in the panel header, or /copy from the
  sheet): per task, when it entered the queue, started, and finished — with
  rounds, duration, total tokens, and **average tokens/s** for the run.
- **Blocked/failed tasks stay resumable**: open the task's chat, fix the
  problem, and press Resume to retry it in place with the same transcript.
- **Dynamic archiving**: finished tasks keep their (auto-compacted) chat on
  disk but release their in-memory transcript and engine, so 100 tasks over a
  week don't pile up in RAM. `/queue` starts the queue from any chat.

## Earlier

- **0.8.1** — SGLang 400 fix: tool parameter schemas are always valid JSON
  objects (five specs shipped corrupted in 0.8.0).
- **0.8.0** — Interact with live processes and the machine: `process_*` tools
  (start/read/write/stop/list with streaming, until-matching, named keys),
  `screenshot` / `list_windows` / `screen_watch` / `ui_tree` /
  `inspect_process` / `mouse` / `keyboard` / `focus_app` / `view_image`, and
  the baked-in godot-debugging skill.
- **0.7.0** — Skills: generate, approve, import, export, per-chat selection.
