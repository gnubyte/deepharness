## Download

- **`DeepHarness.dmg`** — open it and drag **DSH** into **Applications**.

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/DSH.app
```

## What's new in 0.10.0 — the queue works unattended, goals run to the end

**Model outages no longer kill work.** A request that times out, a server
that's down, restarting, overloaded, or mid-swap on the Spark — the harness
waits and retries (2s, 4s, 8s, 16s, then every 30s) until the model answers
or you press Stop. The status line shows the reason and the next attempt, the
cut-off partial reply is discarded (no doubled text), and after a swap the
retry follows the model the server now serves. Requests that can't fix
themselves (bad key, malformed request) still fail right away.

**`/goal` has no round cap.** A goal keeps working, round after round, until
the model writes `GOAL_COMPLETE` (or `GOAL_BLOCKED`). The end marker is read
reliably — under markdown, after a "Status:" label, or as the reply's first
line — and ignored in code blocks, inline thinking and mid-reply recaps. A
bare `/goal` resumes the chat's unfinished goal.

**Task Queue fixes:**
- You can add the first task to an empty queue (the add form never appeared).
- Stop → Start can't run a task twice or overlap two runs; the header shows
  "Stopping…" while the current task winds down.
- Resume on a blocked/failed task runs through the queue (just that task when
  the queue is idle, next in line when it's running) and keeps its history.
- A stopped or interrupted task resumes in the same chat; each task runs in
  the project it was queued in.
- A round that fails on an error is retried; three tasks in a row failing on
  errors pause the queue instead of failing the rest.
- Only a queue that was running when the app quit resumes on launch — tasks
  you merely added never start by themselves.
- The Mac stays awake while the queue or a goal runs.
- Put a blocked/failed/skipped task back in line, drag any task to any
  position, absolute timestamps in the log, and an unreadable queue file is
  set aside instead of being overwritten.

**Also:** work done before an error or Stop stays in the model's memory;
SGLang's overflow wording and nginx's 413 trigger compaction; conversation
logs are written in coalesced batches off the main thread and loaded on
demand (long runs stay fast and light); permission prompts can't collide
across chats; screen approvals survive engine rebuilds.

## Earlier

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
