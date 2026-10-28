# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version 3.1.0, authored by the Platform Team, and targets Red Hat Enterprise Linux 8/9 and Ubuntu 22.04/24.04.

The migration scope is moderate in size but carries **above-average complexity** due to three non-standard extension points that have no direct Ansible equivalents:

1. A **custom Puppet function** (`myFunction1`) that performs an HTTP health-check call at catalog compile time.
2. A **proprietary secret-store function** (`mySecretFunction1`) backed by an internal Ruby library (`company_internal_lib`) that fetches credentials at compile time.
3. A **custom Puppet type/provider pair** (`mySecretType1` / `mySecretProvider1`) that registers nodes in a proprietary Enterprise Scheduler platform via the `schedulerctl` CLI.
4. A second **custom type/provider pair** (`myDeploy1` / `myDeployProvider`) that downloads and installs a versioned application artifact.

The core Redis configuration work is straightforward to migrate; the blockers are the proprietary integrations above. Assuming the proprietary CLI and secret-store are accessible from Ansible control nodes, a realistic timeline is **3–5 weeks**: ~1 week for the Redis role, ~1–2 weeks for the custom integrations, and ~1 week for testing and validation.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**
  - **Description**: Redis cluster node profile that installs and configures a Redis server via the `puppet-redis` Forge module, manages persistence (AOF + RDB snapshots), enforces memory limits and eviction policy, performs an HTTP health-check against a local application endpoint at catalog compile time, fetches a Redis service token from a proprietary internal secret store, deploys a versioned application artifact (`myapp 2.1.0`) from an internal artifact server, and registers the node in a proprietary Enterprise Scheduler platform via the `schedulerctl` CLI. Node discovery for cluster membership is driven by a live PuppetDB query.
  - **Path**: `.` (root of repository — the module IS the repository)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (bind `0.0.0.0`, configurable port/password/maxmemory)
    - Templated `redis.conf` with AOF persistence (`appendfsync everysec`), RDB snapshots, and memory policy
    - Custom Facter fact (`redis_role`) that detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf`
    - PuppetDB-driven cluster node discovery (`puppetdb_query`)
    - HTTP health-check function (`myFunction1`) — calls `http://localhost:8080/health` at compile time and writes result to `/var/lib/redis/health_check.json`
    - Proprietary secret retrieval (`mySecretFunction1`) — fetches `redis_service_token` via `company_internal_lib::SecretStore`
    - Custom application deployment type (`myDeploy1`) — downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal`, extracts to `/opt/myapp`, tracks version via `version.txt`
    - Enterprise Scheduler registration type (`mySecretType1`) — registers the node with a daily schedule via `/usr/local/bin/schedulerctl`

---

### Infrastructure Files

- `Puppetfile`: Declares Forge module pins (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be translated into Ansible Galaxy `requirements.yml` and/or direct package tasks.
- `metadata.json`: Module metadata (version 3.1.0, OS support matrix, Puppet version constraints). Informs the Ansible role's `meta/main.yml`.
- `manifests/init.pp`: Main class — orchestrates all resources, PuppetDB query, health-check, secret fetch, artifact deploy, and scheduler registration.
- `manifests/install.pp`: Subclass — delegates to `puppet-redis` class and ensures `/var/log/redis` directory.
- `templates/redis.conf.erb`: ERB template for `redis.conf`; maps directly to an Ansible Jinja2 template (`redis.conf.j2`).
- `lib/facter/redis_role.rb`: Custom Facter fact detecting primary/replica role. Must be replaced with an Ansible fact task (e.g., `stat` + `lineinfile` check, or a custom `set_fact`).
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper using Ruby `net/http`. Replace with Ansible `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Proprietary secret-store client using `company_internal_lib`. Requires integration with Ansible Vault or a supported secrets backend (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.).
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom artifact deployment type/provider. Replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration type/provider wrapping `schedulerctl`. Replace with Ansible `command`/`shell` tasks or a custom module calling `schedulerctl`.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary), Ubuntu 22.04 and 24.04 (secondary), as declared in `metadata.json`. Package management differs between families — the `puppetlabs-apt` dependency confirms Ubuntu support is active.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The artifact URL (`http://artifacts.internal`) and scheduler CLI suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Wraps Redis package installation and service management. Replace with direct Ansible tasks: `package` (redis / redis-server), `template` for `redis.conf.j2`, `service` for `redis` / `redis-server`. Consider the community `geerlingguy.redis` Galaxy role as a starting point.
- **puppetlabs-apt (9.4.0)**: Manages APT sources on Ubuntu. Replace with Ansible `apt_repository` and `apt_key` tasks, gated by `when: ansible_os_family == 'Debian'`.
- **company_internal_lib (internal Ruby gem)**: Backs `mySecretFunction1`. This library has no Ansible equivalent — the secrets integration must be re-implemented against a supported Ansible secrets lookup plugin (see Security Considerations).
- **schedulerctl CLI (/usr/local/bin/schedulerctl)**: Proprietary binary used by `mySecretType1`. Must be present on managed nodes; wrap with Ansible `command` tasks or a custom Ansible module for idempotency.
- **PuppetDB**: Used for live cluster node discovery. Replace with Ansible dynamic inventory, group variables, or a custom inventory plugin that queries the same data source.

---

### Security Considerations

- **Hardcoded default password**: `init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default. This credential must be stored in Ansible Vault or a secrets manager and never committed to source control. Confirm whether the real value is supplied via Hiera (not present in this repo) or is genuinely left as the default.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` is fetched at Puppet compile time from an internal secret store. The migration must map this to an Ansible-compatible lookup plugin. The target secrets backend (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.) must be identified and the lookup plugin configured before the role can be used in production.
- **Redis `requirepass` in template**: The `redis.conf.erb` template writes the Redis password in plaintext into the configuration file on disk. The Ansible equivalent (`redis.conf.j2`) must ensure the file is owned by `redis:redis` with mode `0600` (tighter than the current `0644` on the health-check JSON) to prevent credential exposure.
- **Artifact download over plain HTTP**: `myDeploy1` fetches `http://artifacts.internal/myapp-2.1.0.tar.gz` over unencrypted HTTP. The Ansible `get_url` replacement should use HTTPS and validate a checksum (`checksum` parameter) to prevent tampering.
- **Redis bound to all interfaces**: `bind 0.0.0.0` is set both in `install.pp` and `redis.conf.erb`. Confirm whether network-level controls (firewall, security groups) restrict access; if not, the Ansible role should add a firewall task.
- **Health-check JSON world-readable**: `/var/lib/redis/health_check.json` is written with mode `0644`. If the health-check response contains sensitive data, tighten permissions in the Ansible equivalent.

---

### Technical Challenges

- **PuppetDB cluster discovery → Ansible dynamic inventory**: `init.pp` uses `puppetdb_query` to discover all nodes running this profile at catalog compile time. Ansible has no compile-time equivalent. This must be replaced with a dynamic inventory source (e.g., a PuppetDB inventory plugin, a CMDB query, or static group membership). The cluster topology logic must be re-evaluated.
- **Compile-time HTTP health-check (`myFunction1`)**: The health-check runs during Puppet catalog compilation, before any resources are applied. In Ansible, the equivalent `uri` task runs during play execution — the ordering semantics differ. The health-check task must be placed explicitly in the play and its failure handling (currently a hard `Puppet::Error`) must be translated to `failed_when` / `ignore_errors` logic.
- **Proprietary secret-store integration**: `mySecretFunction1` depends on `company_internal_lib`, an internal Ruby gem with no public documentation in this repository. The Ansible migration team must obtain the API contract for this library and map it to a supported lookup plugin. This is the highest-risk item in the migration.
- **Custom type/provider idempotency (`myDeploy1`)**: The provider implements idempotency by comparing `version.txt` against the desired version. The Ansible replacement (`get_url` + `unarchive`) must replicate this logic — likely via a `stat` task on `version.txt` followed by conditional download/extract tasks.
- **Enterprise Scheduler registration (`mySecretType1` / `schedulerctl`)**: The `schedulerctl` CLI is proprietary. Its `query`, `register`, and `unregister` subcommands must be wrapped in Ansible tasks with proper idempotency guards (`changed_when`, `failed_when`). If the CLI is not idempotent by default, a custom Ansible module may be required.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact (primary/replica) is available to all Puppet resources at catalog time. In Ansible, this must be gathered as a custom fact task early in the play (using `set_fact` after a `stat`/`slurp` check) and referenced by subsequent tasks.
- **Cross-OS package name differences**: Redis is `redis` on RHEL and `redis-server` on Ubuntu/Debian. The Ansible role must use `ansible_os_family` conditionals or a `vars/` file per OS family, mirroring what `puppet-redis` and `puppetlabs-apt` handled automatically.

---

### Migration Order

1. **Redis core role** — Translate `install.pp` and `redis.conf.erb` into an Ansible role with `package`, `template`, `file`, and `service` tasks. This is self-contained, well-understood, and delivers immediate value. Covers OS-family conditionals for RHEL vs. Ubuntu.
2. **Custom Facter fact → Ansible fact task** — Replace `lib/facter/redis_role.rb` with a `set_fact` task block early in the play. Low risk, required by later tasks.
3. **HTTP health-check (`myFunction1`)** — Replace with an Ansible `uri` task writing output to `/var/lib/redis/health_check.json` via `copy`. Straightforward, but ordering semantics relative to Redis startup must be validated.
4. **Artifact deployment (`myDeploy1`)** — Replace with `get_url` + `unarchive` + version-tracking tasks. Moderate complexity; requires switching the artifact URL to HTTPS and adding checksum validation.
5. **Secrets integration (`mySecretFunction1`)** — Identify the target secrets backend, configure the Ansible lookup plugin, and replace the `redis_service_token` fetch. This is the highest-risk item and should be unblocked early even if implemented later.
6. **Enterprise Scheduler registration (`mySecretType1`)** — Wrap `schedulerctl` in Ansible `command` tasks with idempotency guards. Depends on `schedulerctl` being available on managed nodes and its API being documented.
7. **Cluster node discovery (PuppetDB query)** — Replace with a dynamic inventory plugin or static group. This is an infrastructure-level concern that affects how the role is invoked, not the role itself; address it during integration testing.

---

### Assumptions

1. **Hiera not present**: No `hiera.yaml` or `data/` directory exists in this repository. It is assumed that class parameters (especially `$redis_password`) are supplied via an external Hiera hierarchy not included here. The actual production password must be located and migrated to Ansible Vault before go-live.
2. **`company_internal_lib` API is accessible**: It is assumed the Platform Team can provide documentation or source for `company_internal_lib::SecretStore.fetch` so that the equivalent Ansible lookup can be implemented. If this library wraps HashiCorp Vault, CyberArk, or a similar product, the migration path is well-defined; if it is a fully bespoke system, a custom lookup plugin may need to be written.
3. **`schedulerctl` will remain available on managed nodes**: The migration assumes `/usr/local/bin/schedulerctl` continues to be installed on target nodes independently of this role. If the CLI itself is deployed by another Puppet module, that deployment must also be migrated or pre-staged.
4. **PuppetDB remains queryable during transition**: The cluster discovery mechanism relies on PuppetDB. It is assumed PuppetDB will remain operational during the migration period so that the existing Puppet-managed nodes continue to function while the Ansible replacement is being developed and tested.
5. **Artifact server supports HTTPS**: It is assumed `artifacts.internal` can serve artifacts over HTTPS. If it cannot, the security improvement (HTTP → HTTPS) noted above will require infrastructure work outside this role's scope.
6. **Single module per repository**: The repository root is the module itself (no `site/`, `modules/`, or `roles/` subdirectory). It is assumed this is a standalone profile repository and not a fragment of a larger control repo.
7. **`myapp` deployment is in scope**: The `myDeploy1` resource deploys `myapp 2.1.0` as part of this profile. It is assumed this application deployment is intentionally bundled with the Redis profile and should remain so in the Ansible role, rather than being split into a separate role.
8. **Target Ansible version**: Ansible 2.15+ (or `ansible-core` 2.15+) is assumed, which provides the `uri`, `get_url`, `unarchive`, `ansible.builtin.template`, and community lookup plugins referenced in this plan.
9. **No environment.conf or r10k config**: No control-repo-level files (`environment.conf`, `.r10k/`) are present. It is assumed this module is consumed via r10k or Code Manager from a separate control repo that is not part of this migration scope.
10. **Redis version not pinned**: Neither `install.pp` nor `metadata.json` specifies a Redis version. The Ansible role should pin a specific Redis package version to ensure reproducibility; the correct version must be confirmed with the Platform Team.
