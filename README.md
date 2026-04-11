<p align="center">
  <b>lil agents — merit & muse</b><br>
  <sub>a fork. tiny ai friends on your mac dock.</sub>
</p>

---

built on **[lil agents](https://github.com/ryanstephen/lil-agents)** · upstream app & idea · **[lilagents.xyz](https://lilagents.xyz)**

this repo is my branch: **main** = day-to-day fork work · **upstream-main** = line kept near upstream for merges

### what’s different here

- **merit & muse** — our two characters, copy, and onboarding voice (instead of the original pair).
- **animation** — custom **hevc + alpha** loops (idle, walk, popover wave, combined hero clips, victory one-shot), plus timing json alongside the pipeline we used.
- **popover & chat** — multi **pop-out** windows per character (so you can detach more than one chat). that work is also **contributed back** to upstream; this fork keeps it merged with our other tweaks.
- **extra polish** — completion sounds & little celebration clips, thinking bubbles, menu bar flavor, themes — small cute layers on top of the base app.

### demo & process

_add your video link or embed._

_notes on how you built the animation / sprites / export — your space._

### sync with upstream

`origin` → this fork · `upstream` → [ryanstephen/lil-agents](https://github.com/ryanstephen/lil-agents)

```bash
git fetch upstream
git checkout upstream-main && git merge upstream/main && git push origin upstream-main
git checkout main && git merge upstream-main   # when you want their updates here
```

### build

open `lil-agents.xcodeproj` in xcode and run the **LilAgents** scheme. cli setup & privacy: [upstream readme](https://github.com/ryanstephen/lil-agents/blob/main/README.md).

### license

mit — see [license](LICENSE).
