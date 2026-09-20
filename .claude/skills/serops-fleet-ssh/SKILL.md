---
name: serops-fleet-ssh
description: >-
  Reaching other units from ser.ops tasks — which SSH aliases work, why cron's environment differs from yours, and why unit3 reports "unreachable" when it is merely asleep. Use when a ser.ops task fails to reach a remote host, when adding a task that copies to another unit, or when asked "why did the offload defer" / "is unit3 up". Not for the ser.ops repo map (use serops-architecture).
---

# Fleet access from ser.ops

**The expensive mistake this prevents:** reading
`WARN: unit3-tailscale unreachable` and concluding the SSH config is broken or
unit3 is down. On 2026-09-20 the config was correct and unit3 was reachable —
it had simply been **asleep at 02:00**, the exact minute the task ran. Agents
that "fix" the config here break a working setup.

## Live fleet (2026-09-20)

Reachable: **unit2, unit3, unit5, unit6, unit7, unit9**.
**unit4 and unit8 are decommissioned.** Do not SSH to them or deploy to them.

## Working routes — verified

From **unit6**:

| target | command |
|---|---|
| unit7 | `ssh -i ~/.ssh/unit7 swoopg111@100.99.131.20` |
| unit3 | `ssh -i ~/.ssh/unit3 swoopggainz@100.78.95.13` |
| unit5 | `ssh -i ~/.ssh/unit5 swoopg111@100.82.246.57` |
| unit9 | `ssh unit9` (alias works as-is) |

From **unit7** (where ser.ops runs): the alias `unit3-tailscale` is correct —
`HostName 100.78.95.13`, `User swoopggainz`, `IdentityFile ~/.ssh/id_ed25519`.

**Use Tailscale IPs, not hostnames.** `~/.ssh/config` on unit6 carries stale LAN
addresses (`172.31.18.95` for unit7, `10.68.117.30` for unit3) that hang until
timeout. MagicDNS is also unreliable: `getent hosts blacksheepart.tail31ee5e.ts.net`
returns nothing from unit7, and unit6's DNS is intercepted — **never verify DNS
from unit6**, run `dig` on unit9.

## unit6's Tailscale/DNS conflict — plan around it

SwoopG's warning, 2026-09-20: **Claude Code on unit6 will not run when
Tailscale is on.** Tailscale's own health check on unit6 reports
`Tailscale can't reach the configured DNS servers. Internet connectivity may be
affected.` — MagicDNS takes over resolution and answers for nameservers that
cannot exist, so outbound name resolution (including the API this agent needs)
breaks.

Consequences for any ser.ops work driven from unit6:

- **Tailnet access and agent connectivity can be mutually exclusive.** Do not
  design a workflow that needs both simultaneously without checking.
- Verify the state before assuming either way — it is not always broken:
  `tailscale status | tail -3` and a plain `curl -s -o /dev/null -w '%{http_code}' https://downloads.claude.ai/claude-code-releases/latest`.
- **Prefer running verification ON unit7 itself** (`curl` from inside the box
  over SSH) rather than pulling a tailnet address into unit6's browser. Reserve
  browser checks for when Tailscale is confirmed up and the agent is still
  responsive.
- If work must be done from unit6 with Tailscale down, use the `-pub` public-IP
  SSH aliases instead of the `100.x` tailnet addresses.

Never verify DNS from unit6 under any circumstances — run `dig` on unit9.

## cron's environment is not your shell

`archive-offload.sh` probes with:

```bash
ssh -o ConnectTimeout=8 -o BatchMode=yes "$BACKUP_HOST" "mkdir -p '$REMOTE_DIR'"
```

`BatchMode=yes` means **no prompts and no agent fallback to a passphrase**.
Cron has **no `SSH_AUTH_SOCK`**. Always reproduce a cron-context failure with
the agent stripped, or you will "confirm" a route that only works interactively:

```bash
env -u SSH_AUTH_SOCK ssh -o ConnectTimeout=8 -o BatchMode=yes unit3-tailscale \
  "mkdir -p backups/volume-archive/unit7 && echo PROBE_OK"
```
`PROBE_OK` means the route is genuinely cron-viable. Anything else is a real
failure worth investigating.

Also beware: `command -v` over a non-interactive SSH can false-negative because
the PATH differs. Check explicit binary paths (`/usr/bin/ionice`) instead.

## unit3 sleeps — design around it, don't fight it

unit3 is a Mac mini. It sleeps, and the fleet rule *"archives live on unit3"*
means every offload depends on a host that is intermittently absent. A task that
treats one failed probe as terminal will defer forever.

**Correct handling:** probe, and on failure record a `skip` with
`detail.reason="peer_asleep"` and **retry on the next opportunity** rather than
consuming the task's interval. A deferral must not count as a run — if it
touches `<task>.last`, the task waits its full interval before trying again, and
a sleeping peer turns into a permanent stall. This is exactly how
`volume-archive` reached 88% disk.

Before declaring a peer down, probe **twice, minutes apart**. A single failed
probe against a sleeping Mac proves nothing.

## Never inline credentials

A GitLab PAT was found in plaintext in shell history from a past command line.
Pass secrets via env files (`$LOKEY_ENV`) or OpenBao/Vaultwarden references —
never as literal arguments, which persist in logs, `ps` output and transcripts.
