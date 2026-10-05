# Drift engine (`cosmic-drift`) — design

**Status: approved when this design's pull request merges (drafted 2026-10-04, revised
2026-10-05 after review).** Replaces the report-only drift step (spec O1). Spec rows: O2
(new, replaces O1) and F11 (new) in `docs/end-state.md`. Implementation comes later, in
planned sprints; their requirements are set at sprint planning. Deferred items: section 16.

## 1. Purpose

The machine must stay rebuildable from its declarations: the image, the dotfiles, the
spec. Today the nightly job only *reports* what differs. A report is easy to ignore, and
the reason behind a change is lost by the next day.

The engine turns every difference into a decision that is recorded:

- **Detect** every difference between the machine and its declarations, automatically.
- **Capture intent**, while you still remember it when possible.
- **Force a deliberate verdict** on each difference (adopt, revert, except, propose).
  Every verdict costs the same small effort: a key, then a typed reason. A change that is
  never decided fails acceptance after a short grace period.
- **Keep it declarative:** an adopted change becomes a line in a declaration file,
  committed with its reason. The ledger and `git log` answer "why is this here?"

Success looks like this:

- Every item `cosmic-drift scan` finds is declared, excepted with a live reason, proposed
  for the image, or still inside its grace period.
- Adopting and excepting cost the same: one key and one sentence. Neither is a shortcut.
- Acceptance and the nightly report say so when drift goes undefended.

## 2. Prior art (surveyed 2026-10-04)

| Tool | What it covers | Why it is not used |
| --- | --- | --- |
| [metapac](https://github.com/ripytide/metapac) | Declarative package lists for 20 backends (brew, dnf, flatpak, apt…); `unmanaged`, `sync`, `clean`; per-host groups | Reconciles but records no intent, exceptions or expiry. No `/etc`, dotfiles or units. It would add a third declaration format beside the Brewfile and `distrobox.ini`, and its dnf backend has no meaning on an Atomic host |
| [homebrew-file](https://github.com/rcmdnk/homebrew-file) (`brew-wrap`) | Rewrites the Brewfile after every `brew install`; git sync | Homebrew only, no reason captured. It writes the rendered `~/.config/homebrew/Brewfile`, not the chezmoi source, which would create drift of its own |
| [aconfmgr](https://github.com/CyberShadow/aconfmgr) | Closest in spirit: `save` writes undeclared packages and `/etc` changes into the config, `apply` does the reverse; explicit installs only | Arch / pacman only |
| [home-manager](https://github.com/nix-community/home-manager) (Nix) | User environment declarative by construction | A lane change: it would replace Homebrew and chezmoi (spec C1, D-rows). It covers neither `/etc` on ostree, nor the boxes, nor intent |

Ideas taken over: "explicitly installed packages only, ignore dependencies"
(aconfmgr) and per-machine lists (metapac; here, `.chezmoidata/machines.yaml`).

## 3. Concepts

### 3.1 Items

An **item** is one difference between the machine and its declarations. Its ID is
`<source>:<key>` and stays the same across scans, so a decision sticks to it.

| Source | ID | Change | Declared in | Lane |
| --- | --- | --- | --- | --- |
| Homebrew | `brew:<formula>` | extra / missing | the Brewfile (all machines); `brew_extra` in `machines.yaml` (one machine) | dotfiles |
| Rootless boxes (`dev`, `claude`, `rocm`) | `box:<box>:<pkg>` | added / removed | creation baseline + `additional_packages` in `distrobox.ini` (all machines) or `box_extra` in `machines.yaml` (one machine) | dotfiles |
| Rootful `net` box | `box:net:<pkg>` | added / removed | creation baseline + `net-box.ini` + its vendor patterns | image |
| chezmoi | `chezmoi:<target path>` | modified / missing | the chezmoi source | dotfiles |
| User units | `unit-user:<unit>` | enabled / disabled, not declared | an enable link (`symlink_` in `.config/systemd/user/*.wants/`) or unit file that chezmoi manages | dotfiles |
| `/etc` | `etc:<path>` | added / modified / deleted vs the image | the image | image |
| Layered packages | `layered:<pkg>` | layered / overridden / removed | the image | image |
| Flatpaks | `flatpak:<app id>` | extra / missing (system); any user flatpak | the image's `flatpaks.list` | image |

Notes:

- **System units are not a separate source.** Enabling one writes a symlink under
  `/etc/systemd/system/`, which the `/etc` source reports. Review labels those items as
  units.
- **`/etc` items carry a content hash.** An exception covers that content only; editing
  the file again brings it back up.
- **Box packages are explicit installs only:** `dnf repoquery --userinstalled` (Fedora
  boxes), `apt-mark showmanual` (Ubuntu boxes). Dependencies never appear.

### 3.2 The rootful `net` box

The `net` box is created and kept by the image (`cosmic-net-box.service`, N4). Covering
it adds four things:

- **Baseline:** `cosmic-net-box` records `apt-mark showmanual` once, when it creates the
  box (`/var/lib/net-box/baseline`).
- **Vendor patterns:** the Cisco and Windscribe clients update themselves (the Cisco
  headend upgrades its client on connect). Package **names** are compared, never
  versions. Names matching the vendor patterns declared in `net-box.ini` (for example
  `cisco-secure-client-*`, `windscribe*`) count as declared, so vendor updates and
  new vendor sub-packages never show as drift.
- **Collection by root:** `podman exec net apt-mark showmanual`. The scan already runs
  as root; review shows the last nightly result.
- **Lane:** `net-box.ini` is in the public image, so adopting means **propose**. Except
  and revert work as usual.

What stays out:

- Files the vendors write inside the box (profiles, certificates): private, changed by
  the headend, not declarable.
- The box's own `/etc`.
- Watchers (5.3). The box is entered rarely and by hand, and the nightly scan is enough.

### 3.3 Verdicts

| Verdict | Meaning | Lanes |
| --- | --- | --- |
| **adopt** | Make it declared: the engine edits the declaration and commits | dotfiles |
| **revert** | Undo it with the source's own tool, after showing the command | all |
| **except** | Keep it undeclared for now: a reason and an expiry (default 30 days, at most 365). Expired means back in the queue | all |
| **propose** | Ask for the image (or the spec) to declare it: a guided, leak-checked GitHub issue on this repo, or a saved draft (7.4) | image, new capability |

**Every verdict applies to this machine by default.** The engine then asks whether it
should also cover all machines, or another one by name. A decision is made per machine
unless you widen it.

### 3.4 Item states

| State | Meaning |
| --- | --- |
| `undecided` | No ledger entry |
| `excepted` | Exception or posted proposal, not expired |
| `draft` | Proposal saved but not posted (offline, no `gh`); counts as defended for 7 days |
| `expired` | The exception or proposal ran out |
| `pending-apply` | Adopted, but the machine does not match yet (e.g. `chezmoi apply` not run) |
| `unknown` | Its collector could not run; never treated as clean |

`first_seen` is carried forward between scans, so grace periods count from when a change
first appeared.

### 3.5 Lists versus lanes (new spec F11)

The spec decides **lanes and capabilities**. The declaration files hold the **lists**:
the Brewfile, each box's `additional_packages`, `flatpaks.list`, `net-box.ini`. Adding
another formula, or another package to `dev`, needs a ledger reason, not a spec row.

A spec change is needed only when an item fits no existing row: a new box, a new lane, a
host service, a new capability. Adopting such an item starts the guided proposal (7.4)
with a `spec:` issue.

## 4. The ledger

`.drift/ledger.toml` lives in the dotfiles repo and is listed in `.chezmoiignore`, so it
never lands in `~`. It holds one `[[entry]]` per ID and machine, sorted by ID.
`cosmic-drift` writes it; hand edits are fine.

```toml
# Why this machine differs from its declarations, or was changed to match them.
[[entry]]
id = "brew:ripgrep"
verdict = "adopt"
why = "fast search through the agent logs"
machine = "frmwrk"       # frmwrk | dsktp | all
date = 2026-10-05

[[entry]]
id = "etc:/etc/example.conf"
verdict = "except"
why = "temporary while the VPN trial runs"
machine = "frmwrk"
date = 2026-10-05
expires = 2026-11-04
hash = "sha256:…"        # /etc items only

[[entry]]
id = "layered:htop"
verdict = "propose"
why = "needed on the host before any box exists"
machine = "frmwrk"
date = 2026-10-05
expires = 2026-11-04
ref = "fedora-cosmic-bluebuild#42"   # or the draft path while unposted
```

Each verdict is also one commit in the dotfiles. The commit contains the ledger entry and
any declaration edit, and carries these trailers:

```
drift: adopt brew:ripgrep

Why: fast search through the agent logs
Drift-Id: brew:ripgrep
Drift-Verdict: adopt
Drift-Machine: frmwrk
```

`git log --grep 'Drift-Id: brew:ripgrep'` is the history; `cosmic-drift why <id>` shows
the entry, that history, and when the item was first and last seen (section 9).

Python's `tomllib` reads the ledger. `cosmic-drift` writes it with a small serializer for
this fixed schema (strings, dates, the fields above), so no third-party module is needed.

## 5. Detection

### 5.1 The nightly scan (the authority)

`cosmic-drift scan` replaces `drift()` as step 2 of the nightly job, running as root:

1. Run every collector. Collectors that need the user (Homebrew, rootless boxes,
   chezmoi, user units) run as the user, as the job already does.
2. Read the ledger from `$UHOME/.local/share/chezmoi/.drift/ledger.toml`, and the watcher
   events (5.3), as **data only**. Nothing in the user's home is executed (this keeps
   J1's rule).
3. Classify each item (3.4), carrying `first_seen` forward from the previous scan.
4. Write `/var/lib/cosmic-nightly/drift.json` (0644) and the readable `drift.txt` for
   the nightly report. Keep a dated copy (section 9).

`drift-ignore.regex` (generic `/etc` noise, public) stays in the image. Personal noise
is handled with ledger exceptions.

`drift.json` holds:

- `scanned` (a timestamp);
- `sources`: per source, `ok` or `unknown` with the error;
- `items`: each with `id`, `source`, `lane`, `change`, `detail`, `first_seen`, `state`,
  and `entry` (the ledger entry, if any).

### 5.2 The live rescan

`cosmic-drift review` and `list` rescan the user-lane sources live, with no sudo. For the
image-lane sources (including `net`) they use the last nightly result and show its age.
`sudo cosmic-drift scan` refreshes everything on demand.

### 5.3 Watchers (intent at the moment)

The watchers notice a change right after it happens, without wrapping or replacing any
command (5.4 explains why). There are two parts.

**1. Package-manager hooks inside the rootless boxes.** These record every install and
removal, whoever or whatever ran it (you, a script, an agent):

- **Fedora boxes (`dev`, `rocm`):** dnf5's actions plugin (`libdnf5-plugin-actions`)
  with a `post_transaction:*:in` / `:out` action file.
- **Ubuntu box (`claude`):** an apt `DPkg::Post-Invoke` hook.
- **What the hook does:** both call `/run/host/usr/libexec/cosmic-drift-hook`, a
  root-owned, read-only file from the image. It appends one event to
  `~/.local/state/cosmic-drift/events-<YYYY-MM>.jsonl`:
  - time and box;
  - packages in and out, with the action (install or erase only; upgrades are ignored);
  - the command line and the name of the process that ran the package manager (for
    example `claude` or `hermes`).
- **Ownership:** it writes as the invoking user (`SUDO_UID`), never as root into your
  home.
- **Declared like everything else:** the hook files are added by each box's
  `pre_init_hooks` in `distrobox.ini`.

**2. A prompt hook in interactive shells.** `~/.config/bash/drift.bash`, sourced by
`.bashrc`, adds one function to `PROMPT_COMMAND` (bash's per-prompt hook list, added to
whatever starship set, never replacing it):

- **Cheap check:** before each prompt it compares a few modification times with the
  last seen values: the Homebrew Cellar, the system and user flatpak app directories,
  `~/.config/systemd/user`, the staged ostree deployment, and the events file. That's
  six `stat` calls, which cost no noticeable time.
- **Only on a change** does it run that one source's quick collector and ask. Each
  change is asked once: the first shell to reach a prompt claims it (a lock on the state
  file), and the others stay quiet.
- **Attribution:**
  - a change made during this shell's last command shows that command;
  - any other change shows "not from this shell", plus the recorded command line and
    process for box events.

```
drift: brew ripgrep installed  (your last command: brew install ripgrep)
  [a]dopt  [e]xcept  [r]evert  [p]ropose  [Enter] decide later  › a
  why › fast search through the agent logs
  machine › [Enter] frmwrk, A all, or a name ›
✓ adopted for frmwrk — committed, pushing in background
```

- **`e`** asks for a reason, then the expiry: `expires in days [30] ›` (Enter keeps 30).
- **`p`** starts the guided proposal (7.4).
- **Enter** leaves the item for review, with its event attached.
- **No verdict without a key and a reason.** A typed sentence alone does nothing.

**Scripts and agents are never prompted.** The prompt hook runs only in interactive
bash. A script or an agent's changes are still recorded at once by the box hooks, or
found by the stat check, and you are asked at your next prompt, with the command line
and the process that made them.

An agent can also leave its intent: `cosmic-drift note <id> --why "…" --by <agent>`. This
is saved as a **note, not a verdict**, and pre-fills the reason when you decide.

The nightly scan remains the authority. A change the watchers miss (an `/etc` edit, the
`net` box) is found that night.

### 5.4 Why watchers, not wrappers

The first draft wrapped `brew`, `flatpak`, `systemctl`, `rpm-ostree` and `sudo` in shell
functions. The risks that led to watchers instead:

| Wrapper risk | Watchers |
| --- | --- |
| A function shadows the real command. Quoting, exit codes, TTY handling and completions can break, and `sudo` is the worst place to add code | Nothing is wrapped; every command runs exactly as installed |
| `command brew`, `/usr/bin/…`, aliases, scripts and agents bypass wrappers silently | Box hooks see every package transaction; the stat check sees any change, however it was made |
| Changes by agents carry no intent until the nightly scan, a day later | Recorded at once with the process that made them; asked at your next prompt |
| `sudo dnf` inside boxes needed a `sudo` wrapper | The dnf5 / apt hooks run inside the package manager |

What watchers cost:

- One `PROMPT_COMMAND` entry, which must coexist with starship. Tested in CI with a
  starship stub, and on the 2TB.
- Hook files in each box, declared in `distrobox.ini`.
- For Homebrew, flatpak and units, attribution relies on timing ("during your last
  command"); there is no hook to name the process.

## 6. Review and the command line

`cosmic-drift review` (alias `drift`) shows the items needing a decision:

- **Order:** expiring exceptions first, then oldest undecided, grouped by source.
- **Each item shows:** what changed, when it was first seen, its watcher event (command,
  process), and any agent note.

Keys:

| Key | Action |
| --- | --- |
| `a` | adopt |
| `r` | revert |
| `e` | except |
| `p` | propose |
| `d` | diff (`/etc` against `/usr/etc`; `chezmoi diff`) |
| `s` | skip |
| `q` | quit |

`a`, `e` and `p` each ask for a reason. `e` also asks for the expiry (default 30 days).
All of them ask about the machine scope (default: this machine).

Verdicts are given **one item at a time**. Applying one verdict to a whole group is
deferred until you've tested this (section 16), so every decision stays deliberate.

Every action also has a non-interactive form, so nothing depends on the screen or on an
AI session:

```
cosmic-drift scan [--json]                     # root; the nightly job runs it
cosmic-drift status [--short|--json]           # counts and the oldest item; used by acceptance and the nightly report
cosmic-drift list [--all]
cosmic-drift adopt|revert|except|propose <id> --why "…" [--days N] [--machine <name>|all]
cosmic-drift note <id> --why "…" --by <who>    # intent only, not a verdict
cosmic-drift why <id>
```

`--machine` defaults to this machine. Pass `all` or a machine name to widen it.

## 7. Verdict mechanics

All dotfiles edits go to the chezmoi source (`chezmoi source-path`). Each verdict then
runs:

1. `git pull --rebase` (stop on a real conflict);
2. the edit, plus `chezmoi apply <that path>`;
3. the collector again, as a check;
4. a commit of the touched paths only;
5. `git push` in the background.

**If the check still sees the item, the edit is rolled back** (`git checkout -- <paths>`)
and the reason is printed. Nothing is ever half-adopted.

### 7.1 Adopt

| Item | Edit (this machine / all machines) |
| --- | --- |
| `brew:` extra | add to `brew_extra` for this machine in `machines.yaml` / add `brew "<f>"` to the Brewfile |
| `brew:` missing | remove it from where it is declared |
| `box:` added (rootless) | add to `box_extra.<box>` for this machine in `machines.yaml` / add `additional_packages="<pkg>"` under the box in `distrobox.ini` |
| `box:` removed (rootless) | remove the name where it is declared |
| `chezmoi:` modified | `chezmoi re-add <path>`. Templates: open the source in `$EDITOR`, then check |
| `unit-user:` | add the enable link (`symlink_` entry), plus the unit file if it is your own; per-machine through `.chezmoiignore` |
| image lane (`etc:`, `layered:`, `flatpak:`, `box:net:`) | guided proposal (7.4) |
| fits no spec row (F11) | guided proposal (7.4) with a `spec:` issue |

`box_extra` is new. `distrobox.ini.tmpl` renders each box's per-machine packages from
`machines.yaml`, the way the Brewfile renders `brew_extra`.

### 7.2 Revert

Revert always shows the exact command and waits for `y`.

| Item | Command |
| --- | --- |
| `brew:` | `brew uninstall <f>`, or `brew bundle install` for missing ones |
| `box:` rootless | `distrobox enter <box> -- sudo dnf remove` / `sudo apt remove` (or install, for removed) |
| `box:net:` | `sudo podman exec net apt-get remove` (or install) |
| `chezmoi:` | `chezmoi apply --force <path>` |
| `unit-user:` | `systemctl --user disable` / `enable` |
| `flatpak:` | `flatpak uninstall` / `install` |
| `layered:` | `sudo rpm-ostree uninstall` / `override reset` (staged; applies at your next reboot) |
| `etc:` modified / deleted | show the diff, then `sudo cp -a /usr/etc/<path> /etc/<path>` |
| `etc:` added | show it, then `sudo rm` |

### 7.3 Except

A reason, then the expiry: `expires in days [30] ›`. Enter keeps 30; at most 365. The
entry records the content hash for `/etc` items.

### 7.4 Propose: the guided proposal

Pressing `a` on an item that can't be adopted locally doesn't just refuse. It explains
why, and offers the proposal:

```
drift: layered htop — can't be adopted here.
  Layered packages are declared by the image (public repo, spec F9), so the image has to
  change. I can draft a proposal for it.  [p]ropose  [e]xcept instead  [Enter] back ›
```

The proposal then walks through what a spec row needs. Each question shows a default
taken from the item and the spec:

1. **Which spec row covers it?** The rows that apply to this source are listed (e.g.
   F9 for layered packages, the A-rows for flatpaks, N4 for `net`). Choose one, or
   **none: a new capability** (a `spec:` issue).
2. **Need:** what it is for, in one line (pre-filled from your reason).
3. **Why it can't live in a lower lane** (brew, a box, a flatpak). F9 requires this for
   anything layered.
4. **When:** day-1, week-1 or later.
5. **How we know it works:** the Check, one line.

The engine composes the issue from the answers:

- title `drift: propose <id> for the image`, or `spec: <need>`;
- the item and its scrubbed detail;
- the draft spec row in the spec's table format;
- your reason.

It opens the issue in `$EDITOR` for a final edit, then:

1. **Leak check:**
   - masks `$HOME`, the user name (as `$SITE_USER`), the hostname, the tailnet name
     (from `tailscale status --json`), UUIDs and IP addresses;
   - refuses to post while any `/home/<name>`, `/var/home/<name>` or `/run/media/<name>`
     pattern remains (as `scripts/check-leaks.sh` does).
2. **Posts** with `gh issue create --repo samwick07/fedora-cosmic-bluebuild --label drift`.
   The ledger entry gets `ref` and a 30-day expiry. When it expires, the engine checks
   the issue: if the image now declares the item, the item is gone anyway; if not, you
   decide again.
3. **Offline, or `gh` not signed in:** saves the draft to `.drift/drafts/<id>.md` in the
   dotfiles. The item becomes `draft` (7 days). The draft can be pasted into GitHub's web
   form by hand.

## 8. Enforcement and integration

**Acceptance check O2** (`cosmic-acceptance`, run nightly by J1):

| Result | When |
| --- | --- |
| PASS | Nothing open |
| WAIT | Every open item is inside its grace period: "2 to decide, oldest 1 day: run `drift`" |
| FAIL | Any `undecided`, `expired` or `unknown` item older than 3 days; any `draft` older than 7 days; any `pending-apply` older than 1 day; an unreadable ledger |

A FAIL makes acceptance incomplete. So the known-good pin (L3) does not move forward, and
the nightly report lists it first. Nothing is blocked.

Elsewhere:

- **The nightly report** is where drift is reported: J1's report gets a drift section
  from `cosmic-drift status`. No separate login notification is added.
- **Monthly box rebuild (O1 today):** unchanged, with "a box without changes" meaning a
  box with no open or excepted `box:` items.
- **Manifest and backups (R1):** unchanged. The ledger is part of the dotfiles and of
  `$HOME`; the records in section 9 sit inside the backup scope.

## 9. Records and retention

| Record | Where | Kept |
| --- | --- | --- |
| Current state (`drift.json`, `drift.txt`) | `/var/lib/cosmic-nightly/` | Replaced by each scan (written atomically) |
| Daily snapshots | `/var/lib/cosmic-nightly/drift/<YYYY-MM-DD>.json` | 90 days; pruned by the scan. A few KB each |
| Watcher events | `~/.local/state/cosmic-drift/events-<YYYY-MM>.jsonl` | 12 months; one file per month, the oldest removed |
| Decisions and reasons | the dotfiles ledger and its commits | Forever (git) |
| Proposals | GitHub issues; `.drift/drafts/` | Issues forever; a draft until posted or decided |

The snapshots and events also answer "what came and went": something installed and
removed before a scan leaves an event but no item.

Both locations are in the nightly backups (S2d: `$HOME` and `/var` state), so the
backups keep them longer than the table.

`cosmic-drift why <id>` combines all of them: first and last seen, the events, the
decisions.

## 10. Privilege and privacy boundaries

- `scan` runs as root. It **parses** the ledger, events and notes, and never executes
  anything from the user's home.
- **The box hooks:**
  - call a root-owned file from the image (`/run/host/usr/libexec/cosmic-drift-hook`);
  - write as the invoking user;
  - only record. They never block or change a transaction.
- `review` and the verdict commands run as the user. `sudo` is used only for a revert
  you confirm (`layered:`, `etc:`, `box:net:`).
- The ledger, events and drafts are private (dotfiles, `~/.local/state`). Only a
  proposal you have read, and that passed the leak check, reaches the public repo.

## 11. Failure handling

| Failure | Behaviour |
| --- | --- |
| Ledger unreadable | One item with the line number. Every other item counts as undecided, not clean. Verdict commands refuse to write until it is fixed |
| A collector fails (podman down, chezmoi missing) | That source is `unknown` (FAIL after 3 days) |
| A box hook fails | The transaction is unaffected (the hook's exit status is ignored); the nightly scan still finds the change |
| The prompt hook fails | It prints one line and disables itself for that shell; the scan is unaffected |
| Push fails | The commit stays local; `status`, review and the report show "N commits not pushed" |
| Unrelated changes in the dotfiles | Only the paths the verdict touched are committed |
| Concurrent edits from dsktp | `git pull --rebase` first; one block per ID keeps conflicts rare and readable; a real conflict stops with a message |
| Adopt check fails | Roll back the edit, print why, leave the item open |

## 12. Layout

| Where | What |
| --- | --- |
| image `files/scripts/cosmic-drift.py` → `/usr/bin/cosmic-drift` | the engine (Python 3, standard library only) |
| image `files/scripts/cosmic-drift-hook.sh` → `/usr/libexec/cosmic-drift-hook` | the box hooks' event writer |
| image `files/scripts/cosmic-nightly.sh` | step 2 calls `cosmic-drift scan`; `drift()` retires; the report gets the drift section |
| image `files/scripts/cosmic-acceptance.sh` | O2 check from `cosmic-drift status --json` |
| image `files/scripts/cosmic-net-box.sh`, `files/share/net-box.ini` | baseline at creation; vendor patterns |
| image `files/share/drift-ignore.regex` | unchanged |
| repo `tests/drift/` | unit tests and fixtures |
| dotfiles `.drift/ledger.toml`, `.drift/drafts/` | the ledger and unposted proposals (in `.chezmoiignore`) |
| dotfiles `dot_config/bash/drift.bash` | the prompt hook, sourced by `.bashrc` |
| dotfiles `distrobox.ini.tmpl`, `.chezmoidata/machines.yaml` | the box hooks (`pre_init_hooks`); `box_extra` |

## 13. Testing

Python `unittest` in `tests/drift/`, run in CI before the image build:

- **Collectors:** fed recorded output of `brew bundle check` / `cleanup`, `dnf repoquery
  --userinstalled`, `apt-mark showmanual` (including the `net` box with vendor packages
  at new versions), `ostree admin config-diff`, `rpm-ostree status --json`, `flatpak
  list`, `chezmoi status`, `systemctl --user list-unit-files`.
- **Ledger:** read and write round trip; malformed input reported with its line.
- **States:** with a fixed clock (grace, expiry, draft, `pending-apply`, `unknown`).
- **Adopt edits:** this-machine and all-machines targets, against reference Brewfile,
  `distrobox.ini.tmpl` and `machines.yaml` files (golden output).
- **Guided proposal:** the composed issue from fixed answers; the leak scrubber's
  masking cases, and cases that must be refused.
- **Retention:** snapshot and event pruning.
- **Watchers:**
  - the prompt hook in bash with stubs: the stat check triggers only on change; one
    claim per change across two shells; it coexists with a starship-style
    `PROMPT_COMMAND`; non-interactive shells are untouched;
  - the hook writer: its event format, and that it writes as `SUDO_UID`.

On hardware, `cosmic-acceptance --exercise` adds a drift trial:

1. a harmless formula installed in an interactive shell is asked about, and `a` plus a
   reason produces an adopt commit for this machine;
2. a package installed in `dev` by a non-interactive script produces an event with that
   script's command line, and is asked about at the next prompt;
3. reverting it removes it;
4. the trial's commits are reverted at the end.

## 14. Rollout

1. This design is approved; O2 and F11 are `confirmed`, and O1 folds into O2 when O2 is
   built. J1 step 2, L5 and section 6 change in the implementation PRs.
2. Build in planned sprints, starting after the 2TB **user-layer** step passes. Sprint
   scope and requirements are decided at sprint planning. The current O1 report covers
   the gap.
3. Test on the 2TB during the migration step. Tune the noise filters and collector rules
   against a real machine.
4. The 4TB install gets the finished image with no changes (F6).

## 15. Out of scope (v1)

- Automatic reverts of any kind.
- A GUI, and a separate login notification (the nightly report covers it).
- The Win11 VM and its guest.
- Bottles prefixes (section 16).
- Files inside boxes (each box's `/etc`, vendor profiles in `net`); only packages are
  tracked.
- Language-level global installs (`uv tool`, `npm -g` in `dev`): a later collector if
  they turn out to matter.
- dsktp-specific sources (it inherits the engine when its spec section is written).

## 16. Deferred

- **Applying one verdict to a whole group:** deferred until you've tested the
  one-at-a-time flow.
- **Bottles prefixes** (decided 2026-10-05: not in v1). Notes for the follow-up:
  - **Detection is small:** each bottle's `bottle.yml` names its runner, installed
    dependencies and programs.
  - **Making it declarative is the larger part:** a declared bottle list (name, runner,
    dependencies, installer URL per F10) and a user-layer step that creates missing
    bottles with `bottles-cli`. This moves creation out of the migration (M8) and needs
    a change to spec row A11 first.
  - **Parsing:** `bottle.yml` is YAML, which Python's standard library can't read; use a
    minimal parser or the Bottles flatpak's own Python.
  - **Revert inside a prefix is weak:** the practical verdicts are adopt, except, or
    recreate the bottle.
