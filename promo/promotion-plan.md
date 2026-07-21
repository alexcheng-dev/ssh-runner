# Promotion Plan: SSH Runner + Worker Agents

Date: 2026-07-21
Project root: `/Users/igor/Documents/sshworker`

## 1. Product positioning

### Primary pitch

Run disposable cloud worker machines from GitHub Actions, get live SSH access through tmate, and optionally launch a browser-accessible worker dashboard for Codex/agent tools.

### What to promote

- **SSH Runner**: a minimal GitHub Actions workflow that starts a short-lived Ubuntu worker and publishes an SSH link as an artifact.
- **Worker Agents**: a generic Node.js dashboard for starting/restarting local agent UIs and worker processes on the remote worker.
- **Local launcher scripts**: one-command flows for starting the runner, uploading Worker Agents, exposing it with Cloudflare Tunnel, and saving connection details.

### Core audiences

1. Developers who need a temporary Linux box without renting a VPS.
2. AI-agent/Codex users who want a remote browser-accessible worker.
3. OSS maintainers who need reproducible support/debug sessions.
4. Automation builders who want a lightweight alternative to managing long-lived servers.

## 2. Proof points to use in copy

Ground all public posts in repo-verifiable facts:

- `scripts/ssh-runner-link.sh` triggers the workflow, waits for the `ssh-link` artifact, and prints SSH/Web details.
- `scripts/run-worker-agents-worker.sh` uploads `workerAgents`, runs `npm install`, starts it in tmux, exposes it with `cloudflared`, and saves `outputs/*-worker-agents.json`.
- `scripts/list-running-workers.sh` lists live workflow runs and connection details when artifacts are ready.
- Worker lifetime is approximately 6 hours after the workflow artifact upload step.
- `workerAgents` can supervise Codex Web Local, OpenCode, OpenClaw, 9Router, Hermes WebUI, or arbitrary commands configured in `workers.json`.

Avoid claiming:

- production hosting, persistence, uptime guarantees, secret isolation, or unlimited compute;
- that GitHub endorses this use case;
- that tmate web links are reliable here. Repo notes say SSH is the reliable surface.

## 3. Promo workspace layout

Recommended files under `./promo/`:

```text
promo/
├── promotion-plan.md          # this plan
├── messaging.md               # canonical short/long copy blocks
├── reddit/
│   ├── targets.md             # subreddits, search queries, rules, candidate threads
│   ├── drafts.md              # context-specific reply drafts
│   └── posted.md              # permalink, date, account, exact text posted
├── twitter/
│   ├── posts.md               # X/Twitter post queue
│   └── posted.md              # URLs and metrics snapshots
├── linkedin/
│   ├── posts.md               # LinkedIn post queue
│   └── posted.md              # URLs and metrics snapshots
└── socpublic/
    ├── task-drafts.md         # Russian task copy before creating paid tasks
    └── task-log.md            # task IDs, spend, status, verification
```

## 4. Channel strategy

### Reddit via Composio

Goal: answer existing high-intent threads where this project genuinely solves a problem. Do not spam generic launch posts.

Target communities / query themes:

- `r/githubactions`: temporary runner SSH, debugging workflows, tmate, artifact links.
- `r/selfhosted`: temporary dev boxes, tunnels, remote control planes, short-lived workers.
- `r/devops`: ephemeral CI workers, remote debugging, GitHub Actions operations.
- `r/commandline`: useful shell automation, tmux/tmate/cloudflared scripts.
- `r/OpenAI`, `r/LocalLLaMA`, `r/ChatGPTCoding`: remote agent/Codex worker workflows, only when thread is about running agents/tools remotely.

Composio workflow:

1. Check auth before work: `composio whoami`.
2. Confirm Reddit connection: `composio connections list --toolkit reddit` or run a harmless Reddit read tool.
3. Discover available tools if needed: `composio search "search reddit posts" --toolkits reddit`.
4. Inspect tool schemas before writes: `composio execute <REDDIT_WRITE_TOOL> --get-schema`.
5. Draft replies into `promo/reddit/drafts.md` first.
6. Post only when the reply references the thread's exact problem and includes a transparent project link.
7. Log every posted reply in `promo/reddit/posted.md` with permalink and exact text.
8. Sleep at least 4-5 seconds between Reddit write/edit calls to avoid rate limits.

Reply style:

- Lead with the problem solved, not the project name.
- Mention limitations: short-lived GitHub runner, no persistence, use SSH not tmate web when web is flaky.
- Include one concise link to the repo or relevant script.
- Avoid hype words like "revolutionary", "game-changing", or "autonomous cloud".

### X/Twitter via Composio

Goal: ship concise demos and technical clips/screenshots.

Post formats:

1. Launch thread: problem -> command -> live result -> caveats.
2. Single tip: "If GitHub Actions logs are annoying for tmate links, upload the link as an artifact."
3. Demo clip/screenshot: Worker Agents dashboard running on a GitHub Actions worker via Cloudflare Tunnel.
4. Build-in-public update: explain one script improvement and why it exists.

Composio workflow:

1. Verify connection: `composio whoami` then `composio connections list --toolkit twitter`.
2. If missing, connect with `composio link twitter`.
3. Discover/confirm post tool: `composio search "create tweet" --toolkits twitter`.
4. Use `--dry-run` or `--get-schema` before first post.
5. Store drafts in `promo/twitter/posts.md`; after publishing, store post URLs in `promo/twitter/posted.md`.

Suggested first post:

> I made a tiny GitHub Actions SSH worker: run a workflow, get a tmate SSH link from an artifact, and use the runner as a disposable Linux box for ~6 hours.  
> Optional script uploads a Worker Agents dashboard and exposes it through Cloudflare Tunnel.  
> Repo: <repo-url>

### LinkedIn via Composio

Goal: position as a pragmatic developer tooling case study, not a meme launch.

Post formats:

1. Short case study: "Turning GitHub Actions into a disposable remote agent workstation."
2. Engineering notes: artifact-based connection retrieval, tmux isolation, Cloudflare Tunnel exposure.
3. Lessons learned: why SSH is the reliable interface; why the tmate web link was not enough.

Composio workflow:

1. Verify connection: `composio connections list --toolkit linkedin`.
2. If missing, connect with `composio link linkedin`.
3. Discover/confirm post tool: `composio search "create linkedin post" --toolkits linkedin`.
4. Draft in `promo/linkedin/posts.md` and publish only reviewed copy.
5. Log post URL and early reactions in `promo/linkedin/posted.md`.

Suggested first post:

> I packaged a small workflow for disposable remote development workers on GitHub Actions.  
>  
> It starts a runner, publishes a tmate SSH link as a workflow artifact, and can upload a Node.js "Worker Agents" dashboard that supervises Codex/OpenCode/other local agent UIs behind a Cloudflare Tunnel.  
>  
> The useful design lesson: artifacts are a better retrieval surface than live logs for connection details, and detached tmux sessions keep the exposed service alive after setup.

### Socpublic

Goal: use paid microtasks only for human QA/onboarding feedback, not fake engagement.

Recommended task types:

1. **GitHub repo review task**: visit repo, read README, answer 3 questions about whether the setup is understandable.
2. **Install/run feedback task**: run `workerAgents` locally or on a Linux VM and submit screenshots/log output.
3. **Documentation clarity task**: identify confusing steps in README/wiki and suggest fixes.

Do not create tasks for fake stars, fake comments, fake LinkedIn likes, fake Twitter engagement, or Reddit manipulation.

Socpublic workflow:

1. Use the Socpublic CLI only after credentials are confirmed: `python3 /Users/igor/.codex/skills/socpublic-cli/scripts/socpublic_cli.py auth show`.
2. Draft Russian task copy in `promo/socpublic/task-drafts.md`.
3. Use `price_user=5` or higher for tasks requiring install/test/screenshot work.
4. Keep new tasks inactive until the saved HTML description and approval instructions are verified.
5. After create/edit, immediately run `task info <id>` and log the advertiser edit link in `promo/socpublic/task-log.md`.

Example Russian Socpublic task concept:

```text
Название: Проверить понятность инструкции GitHub Actions SSH Runner
Цель: открыть репозиторий, прочитать README и wiki/workflow.md, ответить на вопросы по инструкции.
Подтверждение: 1) кратко описать, что делает проект; 2) написать, какой шаг непонятен; 3) приложить скриншот страницы README.
```

## 5. Assets to prepare

- One terminal screenshot showing `scripts/run-worker-agents-worker.sh` output with sensitive URLs/passwords redacted.
- One Worker Agents dashboard screenshot.
- One diagram: GitHub Actions -> tmate SSH -> tmux service -> Cloudflare Tunnel -> browser.
- A 30-second demo GIF/video if available.

## 6. Execution checklist

### Phase 0: Prepare

- [ ] Confirm public repo URL.
- [ ] Update README with one-command launcher examples if missing.
- [ ] Capture fresh screenshots with secrets redacted.
- [ ] Create `promo/messaging.md` with canonical copy blocks.
- [ ] Create tracking files for each channel.

### Phase 1: Organic technical posts

- [ ] Publish one X/Twitter launch post.
- [ ] Publish one LinkedIn case-study post.
- [ ] Search Reddit for 20-50 relevant threads and shortlist only high-intent ones.
- [ ] Draft 5-10 Reddit replies tailored to specific thread context.
- [ ] Post at most a few Reddit replies per day; track every one.

### Phase 2: Feedback loop

- [ ] Run a Socpublic documentation-review task with a small budget.
- [ ] Convert repeated feedback into README/wiki improvements.
- [ ] Share improvements as follow-up posts.

### Phase 3: Maintenance

- [ ] Weekly: refresh Reddit search targets and remove stale/low-fit communities.
- [ ] Weekly: update metrics in each `posted.md` file.
- [ ] After every posted claim, verify it still matches repo behavior.

## 7. Metrics

Track manually in `posted.md` files:

- Reddit: comments posted, replies received, useful conversations, removed/downvoted posts.
- X/Twitter: impressions, likes, reposts, profile clicks, repo clicks if available.
- LinkedIn: impressions, reactions, comments, profile views.
- Socpublic: cost, completions, useful feedback count, README/wiki issues found.
- Repo: stars, forks, issues, external mentions, and real users asking setup questions.

## 8. Immediate next tasks

1. Create the remaining `promo/` tracking files.
2. Fill `promo/messaging.md` with short, medium, and long copy variants.
3. Confirm Composio connections for Reddit, Twitter, and LinkedIn.
4. Draft first Reddit search queries and first X/LinkedIn posts.
5. Draft one Socpublic Russian documentation-review task but do not activate it until reviewed.
