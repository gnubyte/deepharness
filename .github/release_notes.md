## Download

- **`DeepHarness.dmg`** — open it and drag **DSH** into **Applications**.

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/DSH.app
```

## What's new in 0.13.0 — several model servers, and Amazon Bedrock

- **Use more than one server at once.** Add a second DGX Spark (or any other
  OpenAI-compatible server, or Bedrock) in Settings ▸ Models and turn on **Use
  for subagents**. The route you chat with is the *main model* — the conductor —
  and the `agent`, `delegate` and background agents run on the other servers,
  least busy first and several at a time. A server that stops answering is
  skipped for a minute and its task moves to another one. Each server is asked
  which model it is serving *right now*, so a Spark that swapped models is still
  used correctly.
- **Swap who leads in one click.** **Make Main** on any route (or the model
  menu in the toolbar and under the composer). The previous main model stays in
  the fleet as a subagent server, so two Sparks and Bedrock are still three
  servers afterwards. **Test All** asks every route whether it answers.
- **See where subagents run.** The bar above the composer says "Spark 2 ×2 ·
  Amazon Bedrock ×1" and, expanded, what each subagent is doing. `/agents` lists
  the servers with how busy each is.
- **Amazon Bedrock.** A guide for people who have never used the AWS CLI:
  it installs the CLI (Amazon's signed package, no administrator prompt),
  signs you in with your browser (or an existing SSO/CLI profile), lists the
  Region's chat models — recommended first, searchable, the Region switchable in
  place, each badged *Ready / One short form / Terms to accept / Setting up* —
  does what a model needs (Anthropic's one-time form, or a Marketplace model's
  terms after showing price and licence), and connects. Requests use the
  Converse API with streaming, tools, images, prompt caching and Claude's
  extended thinking. When the AWS session ends, the banner offers **Sign in to
  AWS…**. Reach it from the setup wizard, Settings ▸ Models, or the model
  menu's **Choose a Bedrock Model…**.
- **Kinds of subagent, and fan-out.** `agent` takes an `agent_type`
  (`general`, `explore`, `plan`, `review`, `worker`, or your own Claude
  Code-style agent files); `delegate` hands a list of independent tasks out and
  returns every report together; several `agent` calls in one turn run at the
  same time. A step-limited subagent still hands back a report.
- Finished background agents' reports are no longer lost when the request that
  should have carried them fails.

## Earlier

- **0.12.0** — background subagents and background tasks: `agent` with
  `run_in_background` (up to four per chat, `agent_status` / `agent_stop`, an
  idle chat picks the work back up), a bar above the composer, and
  `queue_task` for unattended follow-up work.
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
