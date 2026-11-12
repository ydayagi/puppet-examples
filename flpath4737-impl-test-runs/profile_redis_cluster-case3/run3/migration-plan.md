# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. It provisions a Redis node that participates in a cluster, using PuppetDB for peer discovery, a proprietary internal secret store, a proprietary application-settings format, a proprietary Enterprise Scheduler registration mechanism, and a custom artifact-deployment workflow.

The migration scope is **one Puppet module** with **moderate-to-high complexity**, driven not by the Redis configuration itself (which is straightforward) but by four custom Puppet types/providers and two custom Puppet functions that wrap company-internal tooling. Each of those abstractions must be re-implemented as an Ansible module, lookup plugin, or task before the Redis role can be considered feature-complete in Ansible.

**Estimated timeline**: 4–7 weeks for a single experienced engineer, or 2–3 weeks with a two-person team, assuming the company-internal libraries (`company_internal_lib`, `schedulerctl`) are accessible and documented.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case3**
  - **Description**: Redis cluster node profile (v3.1.0) that installs and configures a Redis server via the `puppet-redis` Forge module, discovers peer nodes dynamically through a PuppetDB query, performs an HTTP health check against a local application endpoint, deploys a versioned application artifact from an internal artifact repository, retrieves a service token from a proprietary internal secret store, registers the node with a proprietary Enterprise Scheduler platform, manages two entries in a proprietary `!key=value` application configuration file, and schedules a nightly Redis backup cron job.
  - **Path**: `.` (repository root — this is a standalone Puppet module)
  - **Technology**: Puppet (≥ 7.0.0 < 9.0.0)
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (bind `0.0.0.0`, AOF persistence with `everysec` fsync, RDB snapshots, configurable `maxmemory` and eviction policy)
    - `redis.conf.erb` template rendering FQDN, port, password, memory limits, and persistence settings
    - Custom Facter fact `redis_role` — detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf` at runtime
    - PuppetDB peer-discovery query (`puppetdb_query`) to enumerate all cluster members
    - `myFunction1` — custom Puppet function that performs an HTTP GET and returns parsed JSON (health-check result written to `/var/lib/redis/health_check.json`)
    - `mySecretFunction1` — custom Puppet function that fetches a named credential (`redis_service_token`) from `CompanyInternal::SecretStore` via `company_internal_lib`
    - `myDeploy1` custom type/provider — downloads a versioned tarball from an internal artifact URL, extracts it to `/opt/myapp`, and tracks the installed version via `version.txt`
    - `myFormatType1` custom type/provider — manages `!key=value` entries in `/etc/company/app.conf` (sets `app-mode=cluster` and `health-port=8080`)
    - `mySecretType1` custom type/provider — registers the node with the Enterprise Scheduler platform via the `/usr/local/bin/schedulerctl` CLI (`register`/`unregister`/`query` subcommands)
    - `myCronType1` custom type/provider — manages root crontab entries via `crontab -l` / `crontab -` (schedules `/usr/local/bin/redis-backup.sh` at 02:30 daily)
    - `/var/log/redis` directory ownership and permissions management

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). The `puppetlabs-apt` dependency is pulled in transitively by `puppet-redis` for Debian/Ubuntu APT source management.
- `metadata.json`: Module metadata declaring OS support (RHEL 8/9, Ubuntu 22.04/24.04), Puppet version range (≥ 7 < 9), and runtime dependencies on `puppetlabs-stdlib ≥ 9.0.0` and `puppet-redis ≥ 11.0.0`.
- `templates/redis.conf.erb`: ERB template for `/etc/redis/redis.conf`. Embeds `@facts['networking']['fqdn']`, `@redis_port`, `@redis_password`, `@maxmemory_mb`, and `@maxmemory_policy`. Must be converted to a Jinja2 template (`redis.conf.j2`) in Ansible.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies the node as `primary` or `replica`. Must be replaced by an Ansible fact-gathering task (e.g., `stat` + `lineinfile` check or a `set_fact` block) or a custom Ansible fact script.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper returning parsed JSON. Replace with Ansible's built-in `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval from `CompanyInternal::SecretStore` via `company_internal_lib`. Requires a custom Ansible lookup plugin or integration with Ansible Vault / an external secrets backend (HashiCorp Vault, CyberArk, etc.).
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron management wrapping `crontab`. Replace with Ansible's native `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Artifact download, extraction, and version tracking. Replace with Ansible `get_url` + `unarchive` + `copy`/`template` for `version.txt`.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` config-file format manager. Replace with a custom Ansible module or `lineinfile`/`blockinfile` tasks targeting the `!key=value` syntax.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration via `schedulerctl` CLI. Replace with Ansible `command`/`shell` tasks wrapping `schedulerctl`, or a custom Ansible module if idempotency is required.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 or 9 (primary target per `metadata.json`); Ubuntu 22.04 / 24.04 also supported. Package management differs between families — the Ansible role must branch on `ansible_os_family` for package installation and APT/YUM source configuration.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified in the repository. The artifact URL (`http://artifacts.internal/`) and secret store reference (`company_internal_lib`) indicate an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Wraps Redis package installation, service management, and `redis.conf` rendering. Replace with the community Ansible role [`geerlingguy.redis`](https://galaxy.ansible.com/geerlingguy/redis) or [`community.general`](https://docs.ansible.com/ansible/latest/collections/community/general/) tasks, combined with the converted `redis.conf.j2` template.
- **puppetlabs-apt (9.4.0)**: Manages APT sources on Ubuntu. Replace with Ansible's `ansible.builtin.apt_repository` module for Debian/Ubuntu targets.
- **company_internal_lib (Ruby gem, internal)**: Used exclusively by `mySecretFunction1` to fetch credentials from `CompanyInternal::SecretStore`. This is the highest-risk dependency — its API, authentication mechanism, and network reachability from Ansible control nodes must be confirmed before designing the secrets integration. Candidate replacements: a custom Ansible lookup plugin wrapping the same library/API, HashiCorp Vault (`community.hashi_vault.hashi_vault` lookup), or CyberArk/AWS Secrets Manager depending on the actual backend.
- **schedulerctl CLI (/usr/local/bin/schedulerctl)**: Proprietary binary used by `mySecretType1`. Must be present on managed nodes. Wrap with `ansible.builtin.command` tasks and implement idempotency via a `query` pre-check, or write a lightweight custom Ansible module.
- **PuppetDB**: Used for cluster peer discovery (`puppetdb_query`). Ansible has no native equivalent. Replace with Ansible dynamic inventory (if nodes are registered in an inventory source such as an CMDB, cloud provider, or Netbox) or with an `ansible.builtin.uri` task querying the PuppetDB REST API directly during the play, storing results in a variable.

---

### Security Considerations

- **Hardcoded default password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp`. This value is also rendered directly into `redis.conf.erb` as `requirepass`. In Ansible, this parameter must be sourced exclusively from Ansible Vault or an external secrets backend — it must never appear as a plain-text default in `defaults/main.yml`.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` credential is fetched at Puppet catalog compile time from an internal secret store. The equivalent Ansible lookup plugin must authenticate securely to the same (or a replacement) backend. The token's purpose and downstream consumers must be documented before migration.
- **Artifact download over plain HTTP**: `myDeploy1` fetches `http://artifacts.internal/myapp-2.1.0.tar.gz` over unencrypted HTTP. The Ansible replacement (`get_url`) should enforce HTTPS and validate the artifact checksum (`checksum` parameter) to prevent tampering.
- **Redis password in config file**: `redis.conf` contains `requirepass` in plaintext on disk. File permissions (`mode 0600`, owned by `redis:redis`) should be enforced in the Ansible template task — the current Puppet code does not explicitly set these permissions on the config file itself.
- **Root crontab management**: `myCronType1` writes directly to the root user's crontab. Ansible's `cron` module should target `name: root` explicitly and the backup script path (`/usr/local/bin/redis-backup.sh`) should be validated to exist before the cron entry is created.
- **`mySecretType1` / schedulerctl**: The `schedulerctl register` command may transmit credentials or node identity to the Enterprise Scheduler. The communication channel and any secrets passed on the command line should be reviewed before wrapping in an Ansible task (command-line arguments are visible in process listings).

---

### Technical Challenges

- **PuppetDB peer-discovery replacement**: The `puppetdb_query` call dynamically enumerates all nodes running this profile at catalog compile time. Ansible has no direct equivalent. The migration must decide between: (a) querying PuppetDB's REST API via `uri` tasks during the play, (b) using a dynamic inventory plugin that reflects the same node set, or (c) accepting a static group variable listing cluster peers. Option (a) preserves the dynamic behavior but introduces a runtime dependency on PuppetDB remaining operational during the Ansible migration period.
- **Custom `myFormatType1` — proprietary config format**: The `!key=value` format used by `/etc/company/app.conf` is not handled by any standard Ansible module. `ansible.builtin.lineinfile` can manage individual lines with a carefully crafted regex (`^!app-mode=` etc.), but a custom Ansible module mirroring the provider logic is safer for idempotency and future entries.
- **`company_internal_lib` availability**: This Ruby gem is loaded at Puppet agent runtime. Its equivalent must be accessible from the Ansible control node (for a lookup plugin) or from managed nodes (for a task-based approach). If the library is not available outside the Puppet ecosystem, a REST API wrapper or CLI tool may need to be developed first.
- **`redis_role` Facter fact migration**: The `redis_role` fact is computed at agent run time by inspecting the filesystem. In Ansible, this must be replicated as a `set_fact` task early in the play (checking for `replicaof` in `/etc/redis/conf.d/replica.conf`) so that subsequent tasks can branch on `redis_role == 'replica'`.
- **Idempotency of `schedulerctl` wrapper**: The Puppet provider implements `exists?`/`create`/`destroy` for idempotency. A plain `ansible.builtin.command` task is not idempotent by default. Either a `changed_when`/`failed_when` guard based on `schedulerctl query` output, or a dedicated custom Ansible module, is required to preserve idempotent behavior.
- **OS-family branching**: The module supports both RHEL and Ubuntu. The Ansible role must use `when: ansible_os_family == 'RedHat'` / `'Debian'` guards for package names, service names, and repository configuration — particularly for the `puppetlabs-apt` equivalent tasks.
- **Artifact version pinning**: `myDeploy1` pins `myapp` at version `2.1.0` and tracks it via `version.txt`. The Ansible equivalent must replicate this version-tracking logic to avoid re-downloading and re-extracting on every run.

---

### Migration Order

1. **Redis installation and configuration** (low risk, high value): Convert `manifests/install.pp` and `templates/redis.conf.erb` to an Ansible role using `geerlingguy.redis` or direct package/template tasks. Validate on both RHEL 9 and Ubuntu 22.04. This is self-contained and has no dependency on internal tooling.
2. **`redis_role` fact and `/var/log/redis` directory** (low risk): Implement the `redis_role` detection as a `set_fact` task and add the log-directory task. These are simple and unblock role-branching logic.
3. **Cron job (`myCronType1` → `ansible.builtin.cron`)** (low risk): Straightforward replacement. Validate that `/usr/local/bin/redis-backup.sh` exists on target nodes.
4. **Artifact deployment (`myDeploy1` → `get_url` + `unarchive`)** (medium risk): Implement version-tracking idempotency and switch the artifact URL to HTTPS with checksum validation. Requires access to the internal artifact repository from the Ansible control node or managed nodes.
5. **Proprietary config file management (`myFormatType1` → `lineinfile` or custom module)** (medium risk): Implement `!key=value` line management. Write and unit-test a custom Ansible module if more than two entries are managed across the estate.
6. **Enterprise Scheduler registration (`mySecretType1` → `command` + idempotency guard)** (medium risk): Wrap `schedulerctl` with pre-check and register/unregister tasks. Requires `schedulerctl` to be present and documented.
7. **Health-check HTTP GET (`myFunction1` → `uri` module)** (low-medium risk): Replace with `ansible.builtin.uri`, write result to `/var/lib/redis/health_check.json` via `copy` with `content`. Straightforward once the endpoint is reachable.
8. **PuppetDB peer-discovery replacement** (high risk): Design and implement the dynamic inventory or in-play REST query strategy. This is an architectural decision that affects the entire cluster workflow and should be agreed upon with the Platform Team before implementation begins.
9. **Secret store integration (`mySecretFunction1` → Ansible Vault / lookup plugin)** (high risk): Highest-complexity item. Requires understanding `company_internal_lib`'s API, designing the Ansible secrets integration, and ensuring `redis_service_token` and any other credentials are never stored in plaintext. This should be prototyped in parallel with steps 1–4 to avoid blocking the final integration.

---

### Assumptions

1. The repository root **is** the Puppet module (no wrapping control repo or environment directory was provided). The Ansible equivalent will be a single role, likely named `redis_cluster`.
2. `company_internal_lib` is a company-internal Ruby gem. Its REST API, authentication scheme, and whether it can be called from outside a Puppet agent context are **unknown** and must be confirmed with the Platform Team before designing the Ansible secrets integration.
3. The `schedulerctl` binary is pre-installed on all managed nodes by a separate provisioning process not captured in this repository. The Ansible role will assume its presence and fail fast if it is absent.
4. The internal artifact server (`http://artifacts.internal/`) is reachable from managed nodes at Ansible run time. The migration plan assumes it will be upgraded to HTTPS before or during the Ansible rollout.
5. PuppetDB will remain operational during the migration transition period, making option (a) (querying PuppetDB via `uri`) viable as an interim peer-discovery strategy.
6. The `redis_service_token` fetched by `mySecretFunction1` is consumed downstream by the application (`myapp`) rather than by Redis itself — its exact usage is not visible in this module and must be clarified.
7. The `myapp` artifact deployed to `/opt/myapp` is a companion application co-located with Redis (possibly a sidecar or proxy). Its relationship to Redis and whether it has its own deployment pipeline is **unclear** from this repository alone.
8. The `!key=value` format in `/etc/company/app.conf` is used only for the two entries visible in `init.pp` (`app-mode` and `health-port`). If other modules also write to this file, a shared custom Ansible module (rather than per-role `lineinfile` tasks) will be needed to avoid conflicts.
9. Target Ansible version is assumed to be **2.15 or later** (compatible with all modules and collections referenced in this plan).
10. The migration will target **RHEL 9** as the primary OS, with Ubuntu 22.04 as a secondary target, consistent with `metadata.json`.
11. No Hiera data files, environment-level `hiera.yaml`, or `environment.conf` exist in this repository — all parameters are class-level defaults or passed by the caller. Ansible `defaults/main.yml` and `vars/main.yml` will be used accordingly.
