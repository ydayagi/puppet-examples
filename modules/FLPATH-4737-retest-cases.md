# FLPATH-4737 retest cases — profile_redis_cluster

Two copies of the `profile_redis_cluster` module, one per retest execution for
FLPATH-4737 (custom code detection in Puppet). Class names inside the copies
are renamed (`profile_redis_cluster_case1` / `_case2`) so the control-repo
discovery resolves each run unambiguously to its own copy — the original
module exists twice in this repo (`modules/` and `site/modules/linux/`) under
the same name, which made earlier runs analyze the stale site copy.

| Copy | State | Original result | Converter |
|---|---|---|---|
| `profile_redis_cluster-case1` | initial embed: `myFunction1` (function), `myType1` + `myProvider1` (HTTP check type/provider), both used in `init.pp` | definitions converted to standalone task files, the usages in `init.pp` dropped from plan and role | unmodified (`main`) |
| `profile_redis_cluster-case2` | final state: `myFunction1`, `myDeploy1` + provider (multi-module case), `mySecretFunction1` (internal gem), `mySecretType1` + provider (proprietary CLI), all used in `init.pp` | usages present in plan and role; `myDeploy1` composed from five Ansible modules; secret components mapped by invention instead of flagging (FLPATH-4737 bullet 4) | `flpath4737` branch (per-kind extraction: type/function references) |

Both copies contain only source files — no migration plans or generated
Ansible output.

## Retest results (2026-10-28)

- **case2** reproduced the original run: all usages in the plan walkthrough and
  the role; `myDeploy1` composed from version-check/download/extract tasks;
  the secret components mapped by invention (schedulerctl command wrapping,
  AAP credential) instead of being flagged.
- **case1** did **not** reproduce the original drop: with the unmodified
  converter, this run recorded the `myFunction1` call and `myType1`
  declaration in the plan and converted both to `ansible.builtin.uri` tasks.
  The original failure was nondeterministic — the schema on `main` has no
  fields to carry type/function references, so whether the usages survive
  depends on the LLM volunteering them in free text. The per-kind fix removes
  that dependence; it does not change what the LLM is capable of.
