# lil agents · Merit & Muse fork

Personal fork of **[lil agents](https://github.com/ryanstephen/lil-agents)** — tiny AI companions on the macOS dock. This repo is **built on top of that project**; upstream owns the core app idea, architecture, and baseline features.

**Upstream repository:** [github.com/ryanstephen/lil-agents](https://github.com/ryanstephen/lil-agents)  
**This fork:** custom characters (**Merit** & **Muse**), animation assets, UI experiments. Day-to-day work lives on **`main`** (the default branch here). The original project’s release line is tracked separately as **`upstream-main`** (see below).

Official downloads and product site for the original app: [lilagents.xyz](https://lilagents.xyz).

## Demo

_Add a link or embed for your demo video here._

## Process

_Notes on how you created the animation, iteration workflow, tools, etc._

## Git remotes & workflow

| Remote | Points to |
| ---------- | --------- |
| `origin`   | **Your fork** (this GitHub repo — push your branches here). |
| `upstream` | **Original repo** — [ryanstephen/lil-agents](https://github.com/ryanstephen/lil-agents). |

If `upstream` is not set yet:

```bash
git remote add upstream https://github.com/ryanstephen/lil-agents.git
git fetch upstream
```

**Branches on this fork**

| Branch | Role |
| ------ | ---- |
| `main` | **Your** primary line — Merit & Muse, merges, experiments. This is the GitHub **default** branch. |
| `upstream-main` | Stays aligned with **upstream’s** `main` for easy diffs and merges. Not your day-to-day branch. |

**Keeping up with upstream**

1. `git fetch upstream`
2. Check out `upstream-main` and merge (or rebase) **`upstream/main`** into it, then push to `origin`.
3. Merge **`upstream-main`** into **`main`** when you want those upstream changes in your fork, and fix conflicts on `main`.

Optional feature branches (`pr/...`) work the same as before; open PRs against **`main`** on your fork.

## Building

Open `lil-agents.xcodeproj` in Xcode and run the **LilAgents** scheme.

Requirements and provider CLIs match upstream; see the [upstream README](https://github.com/ryanstephen/lil-agents/blob/main/README.md) for CLI install links and privacy notes.

## License

MIT — see [LICENSE](LICENSE) (same license family as upstream; refer to upstream for their exact terms).
