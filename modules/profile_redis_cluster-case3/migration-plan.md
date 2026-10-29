# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. It provisions a Redis cluster node with PuppetDB-driven peer discovery, a custom application deployment, proprietary secrets retrieval, a proprietary config-file format manager, and an enterprise scheduler registration.

The migration scope is **one Puppet module** with **moderate-to-high complexity**, driven primarily by four proprietary extensions (a custom Puppet function, a custom Facter fact, and three custom Puppet types/providers) that have no direct Ansible equivalents and will each require bespoke replacement work. The Redis provisioning itself is straightforward to migrate; the surrounding proprietary integrations are the critical-path items.

**Estimated timeline**: 3–5 sprints (6–10 weeks) for a single team, assuming the proprietary back-end systems (secret store, scheduler CLI, artifact registry, CompanyApp config format) are accessible and documented.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

- **profile_redis_cluster_case3**:
  - **Description**: Redis cluster node profile for RedHat 8/9 and Ubuntu 22.04/24.04. Installs and configures Redis via the `puppet-redis` Forge module (bind `0.0.0.0`, password auth, AOF + RDB persistence, configurable `maxmemory` and eviction policy). Uses PuppetDB to discover all cluster peers at catalog compile time. Performs an HTTP health-check call against a local sidecar (`localhost:8080/health`) and writes the result as JSON. Deploys a versioned application artifact (`myapp v2.1.0`) from an internal artifact registry. Retrieves a `redis_service_token` from a proprietary internal secret store. Registers the node in an enterprise scheduler platform on a daily schedule. Manages two entries (`app-mode`, `health-port`) in a proprietary `!key=value` settings file at `/etc/company/app.conf`.
  - **Path**: `.` (repository root — the module itself is the root of this repo)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (port, password, maxmemory, AOF/RDB persistence)
    - ERB template (`templates/redis.conf.erb`) rendering FQDN, port, password, maxmemory, and eviction policy
    - PuppetDB peer-discovery query (`puppetdb_query`) for cluster node enumeration
    - Custom Puppet function `myFunction1` — HTTP GET helper returning parsed JSON or raw body
    - Custom Puppet function `mySecretFunction1` — fetches named credentials from `CompanyInternal::SecretStore` (proprietary Ruby gem `company_internal_lib`)
    - Custom Facter fact `redis_role` — detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf`
    - Custom type/provider `myDeploy1` — downloads a versioned `.tar.gz` artifact from an internal HTTP URL, extracts it, and tracks the installed version via `version.txt`
    - Custom type/provider `myFormatType1` — idempotently manages `!key=value` entries in the proprietary CompanyApp settings file
    - Custom type/provider `mySecretType1` — registers/unregisters nodes in an enterprise scheduler via the `/usr/local/bin/schedulerctl` CLI
    - Log directory management (`/var/log/redis`, owner `redis:redis`, mode `0755`)

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be translated into Ansible Galaxy `requirements.yml` and/or direct role dependencies.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraint). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency version ranges for migration planning.
- `templates/redis.conf.erb`: ERB template producing the full `redis.conf`. Must be rewritten as a Jinja2 template (`redis.conf.j2`) in the Ansible role. Variable names map directly: `@redis_port` → `redis_port`, `@redis_password` → `redis_password`, `@maxmemory_mb` → `maxmemory_mb`, `@maxmemory_policy` → `maxmemory_policy`; the FQDN fact (`@facts['networking']['fqdn']`) maps to `{{ ansible_fqdn }}`.
- `lib/facter/redis_role.rb`: Custom Facter fact detecting Redis role from `/etc/redis/conf.d/replica.conf`. Must be replaced with an Ansible task that reads the same file and sets a host fact (`set_fact`) or a dynamic inventory group variable.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper. Replace with Ansible's built-in `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval via `CompanyInternal::SecretStore` (requires `company_internal_lib` gem). Must be replaced with an Ansible Vault lookup, HashiCorp Vault lookup plugin, or a custom lookup plugin wrapping the same back-end API.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Versioned artifact deployment (download → extract → version-track). Replace with a combination of Ansible `get_url`, `unarchive`, and `copy`/`template` tasks, or a dedicated Ansible role.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` config-file format manager. No built-in Ansible module handles this format; requires a custom Ansible module or `lineinfile`/`replace` tasks with carefully crafted regexes.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise scheduler registration via `/usr/local/bin/schedulerctl`. Replace with Ansible `command`/`shell` tasks (with idempotency guards) or a custom Ansible module wrapping `schedulerctl`.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9; Ubuntu 22.04 (Jammy) and 24.04 (Noble) — explicitly declared in `metadata.json` `operatingsystem_support`. Primary package management is `yum`/`dnf` on RHEL and `apt` on Ubuntu (confirmed by `puppetlabs-apt` dependency).
- **Virtual Machine Technology**: Not specified in this repository.
- **Cloud Platform**: Not specified in this repository. The internal artifact URL (`http://artifacts.internal/`) and secret-store gem suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides `stdlib::to_json()` used in `init.pp`. Replace with Ansible's built-in `to_json` Jinja2 filter (`{{ health_check_result | to_json }}`). No external role needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community Ansible role [`geerlingguy.redis`](https://galaxy.ansible.com/geerlingguy/redis) or [`community.general`](https://docs.ansible.com/ansible/latest/collections/community/general/) tasks. Map parameters: `bind`, `port`, `requirepass`, `maxmemory`, `appendonly`, `appendfsync`, `manage_package`.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu. Replace with Ansible's built-in `ansible.builtin.apt_repository` module for Ubuntu targets; no action needed for RHEL targets.
- **PuppetDB (`puppetdb_query`)**: Used for dynamic cluster peer discovery at compile time. Replace with Ansible dynamic inventory (e.g., a script or plugin querying your CMDB/cloud inventory) or Ansible's `add_host` / group-based inventory to enumerate Redis cluster members at playbook runtime.
- **company_internal_lib (Ruby gem)**: Proprietary gem backing `mySecretFunction1`. The Ansible replacement depends on what back-end this gem wraps — the team must document the secret-store API before migration can proceed.
- **schedulerctl CLI (`/usr/local/bin/schedulerctl`)**: Proprietary binary used by `mySecretType1`. Must be present on the Ansible control node or managed hosts at migration time; the team must confirm availability and idempotency semantics.

---

### Security Considerations

- **Hardcoded default password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp`. This value is also rendered verbatim into `redis.conf.erb`. In the Ansible role, this parameter must be sourced exclusively from Ansible Vault or an external secrets manager — never stored in plaintext in variables files or inventory.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` credential is fetched at Puppet catalog compile time from `CompanyInternal::SecretStore`. The migration team must identify the underlying secret-store technology (e.g., HashiCorp Vault, CyberArk, AWS Secrets Manager) and implement an equivalent Ansible lookup plugin. Until this is resolved, the token's handling in Ansible is undefined and represents a **migration blocker**.
- **Redis password in template**: `redis.conf.erb` renders `requirepass <%= @redis_password %>` in plaintext on disk. The Jinja2 replacement must use `no_log: true` on any task that writes or displays this value, and file permissions on the rendered `redis.conf` should be `0640` (owner `redis`, group `redis`) to limit exposure.
- **Artifact download over plain HTTP**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (unencrypted). The Ansible `get_url` replacement should enforce HTTPS and validate a checksum (`checksum` parameter) to prevent tampering.
- **Enterprise scheduler registration (`mySecretType1` / `schedulerctl`)**: The CLI is invoked with the node name and schedule. Any authentication tokens or credentials required by `schedulerctl` are not visible in this repository and must be identified and vaulted before migration.
- **No TLS configuration for Redis**: The current template does not configure Redis TLS (`tls-port`, `tls-cert-file`, etc.). The migration is an opportunity to add TLS; this should be evaluated against the cluster's network security posture.

---

### Technical Challenges

- **PuppetDB cluster discovery → Ansible inventory**: `puppetdb_query` runs at Puppet compile time and returns all nodes classified with this profile. Ansible has no equivalent compile-time query. The team must design a dynamic inventory strategy (cloud inventory plugin, CMDB query, or static group) that replicates this peer-discovery behaviour before the Redis cluster can be correctly configured.
- **Proprietary `company_internal_lib` gem**: `mySecretFunction1` depends on a closed-source Ruby gem. The Ansible replacement cannot be designed until the team documents the gem's API and the underlying secret-store endpoint. This is the highest-risk unknown in the migration.
- **Custom `!key=value` config format (`myFormatType1`)**: The CompanyApp settings file uses a non-standard `!key=value` format. Ansible has no built-in module for this. Options are: (a) write a small custom Ansible module in Python, (b) use `lineinfile` with a regex pattern `^!{{ entry }}=`, or (c) manage the entire file as a template if all entries are known. Option (a) is the most robust but requires development effort.
- **`schedulerctl` idempotency (`mySecretType1`)**: The Puppet provider uses `schedulerctl query` to check existence before registering. An Ansible `command` task wrapping `schedulerctl` must replicate this idempotency check (e.g., `changed_when`, `failed_when`, or a `command` pre-check task). The exit-code semantics of `schedulerctl query` must be confirmed with the owning team.
- **Versioned artifact deployment (`myDeploy1`)**: The provider tracks the installed version via a `version.txt` file. The Ansible replacement must implement the same idempotency guard (read `version.txt`, skip download/extract if version matches) to avoid re-deploying on every run.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact is available to all Puppet resources at catalog compile time. In Ansible, the equivalent must be gathered as a task early in the play (e.g., `slurp` or `stat` + `set_fact`) and made available to subsequent tasks. Ensure the fact is gathered before any task that branches on primary vs. replica behaviour.
- **Multi-OS support**: The module targets both RHEL (dnf/yum) and Ubuntu (apt). The Ansible role must use `ansible_os_family` conditionals or separate task files (`tasks/RedHat.yml`, `tasks/Debian.yml`) to handle package manager differences, particularly for Redis installation and the APT repository setup currently handled by `puppetlabs-apt`.
- **`contain` vs. Ansible task ordering**: `contain profile_redis_cluster_case3::install` in Puppet enforces strict ordering and containment boundaries. In Ansible, task ordering is explicit and sequential; the team must ensure the install tasks (Redis package, log directory) are placed before the configuration and service tasks in the playbook/role.

---

### Migration Order

1. **Redis installation and configuration** (low risk, high value): Migrate `manifests/install.pp`, the `redis.conf.erb` template, and the log-directory resource first. This is the core deliverable and maps cleanly to `geerlingguy.redis` or `ansible.builtin` tasks. Validate on a single RHEL 9 node before expanding to all OS targets.
2. **Custom Facter fact → Ansible fact task** (low risk): Replace `lib/facter/redis_role.rb` with a `set_fact` task early in the play. This is self-contained and unblocks any downstream tasks that branch on Redis role.
3. **HTTP health-check → `uri` module** (low risk): Replace `myFunction1` with `ansible.builtin.uri` and write the result to `/var/lib/redis/health_check.json` via `copy` with `content: "{{ health_result.json | to_json }}"`.
4. **CompanyApp config format → `lineinfile` or custom module** (`myFormatType1`, moderate risk): Implement and unit-test the `!key=value` management approach before integrating it into the role. Deliver as a standalone custom module or a reusable task file.
5. **Artifact deployment → `get_url` + `unarchive`** (`myDeploy1`, moderate risk): Implement versioned artifact deployment with idempotency guard. Switch the download URL to HTTPS and add checksum validation at this stage.
6. **Enterprise scheduler registration → `command` wrapper** (`mySecretType1`, moderate risk): Confirm `schedulerctl` exit-code semantics with the owning team, then implement idempotent `command` tasks. Consider wrapping in a custom Ansible module if the CLI interface is complex.
7. **Secret store integration → Ansible Vault / lookup plugin** (`mySecretFunction1`, high risk — potential blocker): Resolve the `company_internal_lib` back-end first. Implement and test the Ansible lookup plugin or Vault integration in isolation before wiring it into the role. Replace the hardcoded `CHANGEME` password at this stage.
8. **PuppetDB peer discovery → dynamic inventory** (high risk — architectural decision): Design and validate the dynamic inventory strategy for cluster peer enumeration. This may require coordination with the infrastructure/platform team and is a prerequisite for any multi-node cluster testing.

---

### Assumptions

1. **Secret store back-end is accessible**: It is assumed that the system backing `CompanyInternal::SecretStore` (via `company_internal_lib`) is reachable from the Ansible control node and that its API or CLI can be wrapped in an Ansible lookup plugin. If the gem is the only supported interface, a Python re-implementation or REST API wrapper will be needed.
2. **`schedulerctl` will be available on managed hosts**: It is assumed that `/usr/local/bin/schedulerctl` is pre-installed on target nodes (or can be distributed as part of the play) and that its `query`/`register`/`unregister` subcommands are stable and documented.
3. **Internal artifact registry supports HTTPS**: The current URL (`http://artifacts.internal/`) uses plain HTTP. It is assumed the registry also exposes an HTTPS endpoint that can be used in the Ansible replacement.
4. **PuppetDB is not retained post-migration**: The migration assumes Ansible will replace PuppetDB-based node discovery with a different inventory mechanism. If PuppetDB is retained alongside Ansible, a PuppetDB dynamic inventory plugin could be used as a transitional measure.
5. **`redis_role` fact is used only within this module**: The `redis_role` Facter fact is defined in this repo but its consumers are not visible here. It is assumed no other Puppet code outside this module depends on it; if it is, those consumers must also be migrated or the fact must be published via a shared inventory mechanism.
6. **`myapp` deployment is in scope**: The `myDeploy1` resource deploys `myapp v2.1.0` as part of this profile. It is assumed this application deployment is intentionally bundled with the Redis profile and should remain in the same Ansible role. If `myapp` is a separate concern, it should be extracted into its own role.
7. **CompanyApp settings file is fully managed by this module**: Only two entries (`app-mode`, `health-port`) are managed here. It is assumed no other Puppet code writes to `/etc/company/app.conf`; if other modules do, a shared Ansible role or a merge strategy will be needed.
8. **Ansible version ≥ 2.14**: The plan assumes a modern Ansible core version that supports `ansible.builtin.uri`, `ansible.builtin.unarchive`, `ansible.builtin.get_url`, and Jinja2 filters such as `to_json`.
9. **Target hosts are already bootstrapped**: It is assumed that Python is available on all target nodes (required by Ansible) and that SSH access or WinRM is configured. No bootstrapping play is included in this plan.
10. **`puppetlabs-apt` is only used for Redis APT sources**: The `puppetlabs-apt` dependency is declared in the `Puppetfile` but its usage is implicit (via `puppet-redis` on Ubuntu). It is assumed no custom APT sources beyond the Redis repository are managed by this module.
