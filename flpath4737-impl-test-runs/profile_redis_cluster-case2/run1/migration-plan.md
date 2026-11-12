# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version **3.1.0**, authored by the Platform Team, and targets **Red Hat Enterprise Linux 8/9** and **Ubuntu 22.04/24.04**.

The migration scope is moderate in size (one module, two manifests, one template) but carries **above-average complexity** due to four non-trivial custom extensions that have no direct Ansible equivalents and will each require a bespoke migration strategy:

| Custom Extension | Type | Migration Complexity |
|---|---|---|
| `myFunction1` | HTTP health-check Puppet function | Medium |
| `mySecretFunction1` | Internal secret-store Puppet function | High |
| `myDeploy1` type + provider | Artifact download & versioned deployment | Medium |
| `mySecretType1` type + provider | Proprietary `schedulerctl` CLI integration | High |

Additionally, the module relies on **PuppetDB live queries** for cluster node discovery — a Puppet-native capability that must be replaced with an Ansible inventory strategy.

**Estimated migration timeline: 3–5 sprints (6–10 weeks)** for a single engineer, accounting for the custom-extension rewrites, secrets-integration work, and end-to-end testing on both supported OS families.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**
  - **Description**: Redis cluster node profile that installs and configures a Redis server via the `puppet-redis` Forge module, manages persistence (AOF + RDB snapshots), enforces memory limits and eviction policy, performs a live HTTP health check against a local sidecar endpoint, deploys a versioned application artifact (`myapp 2.1.0`) from an internal artifact server, retrieves a service token from a proprietary internal secret store, and registers the node with a proprietary Enterprise Scheduler platform via the `schedulerctl` CLI.
  - **Path**: `.` (module root — `manifests/init.pp`, `manifests/install.pp`, `templates/redis.conf.erb`)
  - **Technology**: Puppet 7/8
  - **Key Features**:
    - PuppetDB-driven cluster node discovery (`puppetdb_query`)
    - Redis installation and full configuration via `puppet-redis` Forge module (bind, port, password, maxmemory, AOF persistence)
    - ERB template (`redis.conf.erb`) rendering FQDN, port, password, maxmemory, and eviction policy
    - Custom Facter fact (`redis_role`) that detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf`
    - HTTP health-check function (`myFunction1`) that GETs `http://localhost:8080/health` and writes the JSON result to `/var/lib/redis/health_check.json`
    - Versioned artifact deployment (`myDeploy1` custom type/provider) — downloads a `.tar.gz` from an internal URL, extracts it, and tracks the installed version via `version.txt`
    - Secret retrieval (`mySecretFunction1`) via `company_internal_lib` / `CompanyInternal::SecretStore`
    - Enterprise Scheduler registration (`mySecretType1` custom type/provider) via `/usr/local/bin/schedulerctl` CLI with a `daily` schedule
    - Log directory management (`/var/log/redis`, owner `redis:redis`, mode `0755`)

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). In Ansible, these are replaced by collection dependencies in `requirements.yml`.
- `metadata.json`: Module metadata declaring OS support (RHEL 8/9, Ubuntu 22.04/24.04), Puppet version constraints (>= 7.0.0 < 9.0.0), and Forge dependencies. Informs the Ansible role's `meta/main.yml`.
- `templates/redis.conf.erb`: ERB template for `redis.conf`. Must be converted to a Jinja2 template (`.j2`) in the Ansible role's `templates/` directory. Variable references (`@redis_port`, `@redis_password`, `@maxmemory_mb`, `@maxmemory_policy`, `@facts['networking']['fqdn']`) map directly to Ansible variables and `ansible_fqdn`.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica` by checking for `replicaof` in `/etc/redis/conf.d/replica.conf`. Must be replaced with an Ansible task that sets a `redis_role` fact using `ansible.builtin.stat` + `ansible.builtin.slurp` or `set_fact`.
- `lib/puppet/functions/myFunction1.rb`: Custom Puppet function performing an HTTP GET and returning parsed JSON. Replace with `ansible.builtin.uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Custom Puppet function fetching secrets from `CompanyInternal::SecretStore` via `company_internal_lib`. Requires integration with an Ansible-compatible secrets backend (see Security Considerations).
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom type/provider for versioned artifact deployment (download → extract → version-track). Replace with `ansible.builtin.get_url` + `ansible.builtin.unarchive` + `ansible.builtin.copy` (for `version.txt`).
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom type/provider wrapping the proprietary `schedulerctl` CLI for Enterprise Scheduler registration. Replace with `ansible.builtin.command` tasks or a custom Ansible module if idempotency is required.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary), Ubuntu 22.04 and 24.04 (secondary) — explicitly declared in `metadata.json` `operatingsystem_support`.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified; the artifact server (`artifacts.internal`) and scheduler CLI suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external collection required.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the `community.general` collection or a dedicated Redis Ansible role (e.g., `geerlingguy.redis` from Ansible Galaxy), or implement directly with `ansible.builtin.package`, `ansible.builtin.template`, and `ansible.builtin.service`.
- **puppetlabs-apt (9.4.0)**: Manages APT repository configuration on Ubuntu. Replace with `ansible.builtin.apt_repository` and `ansible.builtin.apt_key` tasks, gated by `when: ansible_os_family == 'Debian'`.
- **PuppetDB (`puppetdb_query`)**: Used to discover all cluster nodes at catalog-compile time. Replace with a dynamic Ansible inventory plugin (e.g., `ansible.builtin.constructed`, an LDAP/CMDB inventory source, or a static group in the inventory file) that groups Redis cluster members.
- **company_internal_lib / CompanyInternal::SecretStore**: A proprietary Ruby gem used by `mySecretFunction1`. The secrets integration path must be determined with the Platform Team before migration begins (see Security Considerations).
- **schedulerctl CLI (`/usr/local/bin/schedulerctl`)**: Proprietary binary used by the `mySecretType1` provider. The binary must be present on managed nodes, or the registration step must be delegated to a host that has it. Confirm availability and API stability with the scheduler platform team.

---

### Security Considerations

- **Hardcoded Redis password**: `init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default, and the ERB template renders `requirepass <%= @redis_password %>` directly into `redis.conf`. In Ansible, this value must be stored in **Ansible Vault** (or the chosen enterprise secrets backend) and never committed in plaintext. The variable should be referenced as `{{ redis_password }}` in the Jinja2 template.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The module fetches a `redis_service_token` at catalog-compile time via an internal Ruby library. The Ansible equivalent must integrate with the same (or a replacement) secrets backend. Candidate solutions: **HashiCorp Vault** (`community.hashi_vault.vault_read`), **CyberArk** (`cyberark.conjur`), **AWS Secrets Manager** (`amazon.aws.aws_secret`), or Ansible Vault for static secrets. The migration team must confirm which backend `CompanyInternal::SecretStore` maps to and whether an Ansible collection already exists for it.
- **Artifact download over plain HTTP**: The `myDeploy1` provider downloads `http://artifacts.internal/myapp-2.1.0.tar.gz` over unencrypted HTTP. When replacing with `ansible.builtin.get_url`, enforce HTTPS and add a `checksum` parameter to verify artifact integrity.
- **Redis `requirepass` in template**: The rendered `redis.conf` contains the password in plaintext on disk. Ensure the file is owned `redis:redis` with mode `0600` in the Ansible task (the current Puppet code does not explicitly set these permissions on the config file itself).
- **`schedulerctl` credential handling**: The `mySecretType1` provider invokes `schedulerctl register` — if this CLI requires authentication tokens or API keys, those must be surfaced and managed via Ansible Vault or the secrets backend.
- **Health-check result written to disk**: `/var/lib/redis/health_check.json` is written with mode `0644`. If the health-check response contains sensitive data, tighten the file permissions in the Ansible task.

---

### Technical Challenges

- **PuppetDB node discovery → Ansible inventory**: `puppetdb_query` is called at Puppet catalog-compile time to enumerate all Redis cluster members. Ansible has no equivalent compile-time query. This must be replaced with a dynamic inventory source or a pre-play task that populates a group. This is the most architecturally significant change and should be designed before any other work begins.
- **Custom Puppet functions → Ansible modules/tasks**: `myFunction1` (HTTP GET) and `mySecretFunction1` (secret fetch) are Puppet-native Ruby functions. Both must be re-implemented as Ansible tasks. `myFunction1` is straightforward (`ansible.builtin.uri`); `mySecretFunction1` depends on resolving the secrets-backend question above.
- **Custom Puppet types/providers → Ansible tasks or custom modules**: `myDeploy1` and `mySecretType1` encapsulate idempotency logic in Ruby. The deployment provider (`myDeployProvider`) checks `version.txt` to avoid re-deploying — this idempotency must be explicitly reproduced in Ansible (e.g., `ansible.builtin.stat` on `version.txt` + `when` conditions). The scheduler provider wraps a CLI with `exists?`/`create`/`destroy` — if full idempotency is required, a custom Ansible module in Python is the cleanest replacement; otherwise, `ansible.builtin.command` with `changed_when` and `failed_when` guards is acceptable.
- **Custom Facter fact → Ansible fact**: `redis_role.rb` sets a `redis_role` fact used for node classification. In Ansible, this must be set via a task early in the play (using `set_fact` after inspecting the replica config file) so that subsequent tasks and conditionals can reference `{{ redis_role }}`.
- **ERB → Jinja2 template conversion**: The `redis.conf.erb` template is straightforward to convert, but the `@facts['networking']['fqdn']` reference must be replaced with `{{ ansible_fqdn }}`, and all `@variable` references must become `{{ variable }}`. Validate the rendered output against the original on both RHEL and Ubuntu before cutover.
- **OS-family divergence**: The module supports both RHEL (yum/dnf) and Ubuntu (apt). Ansible tasks that manage packages and repositories must include `when: ansible_os_family == 'RedHat'` / `when: ansible_os_family == 'Debian'` guards, mirroring the implicit branching that `puppet-redis` and `puppetlabs-apt` handle today.
- **`company_internal_lib` Ruby gem availability**: This gem is a compile-time dependency on the Puppet master. It will not exist in the Ansible control node environment. The secrets integration must be fully re-architected before the `mySecretFunction1` equivalent can be implemented.
- **`schedulerctl` binary distribution**: The CLI at `/usr/local/bin/schedulerctl` must be present on target nodes (or a jump host) for the scheduler registration task to succeed. Confirm deployment and versioning of this binary as a prerequisite.

---

### Migration Order

1. **Template and base Redis configuration** *(low risk, high value)*
   Convert `redis.conf.erb` to a Jinja2 template and implement the core Redis install/configure/service tasks using `ansible.builtin.package`, `ansible.builtin.template`, and `ansible.builtin.service`. Validate on both RHEL 9 and Ubuntu 22.04. This delivers the primary value of the module with no dependency on custom extensions.

2. **Custom Facter fact → Ansible fact task** *(low risk)*
   Implement a `set_fact` task that replicates `redis_role.rb` logic (stat + slurp `/etc/redis/conf.d/replica.conf`). This unblocks any downstream tasks that branch on `redis_role`.

3. **Log directory and health-check file management** *(low risk)*
   Replace the `file` resources for `/var/log/redis` and `/var/lib/redis/health_check.json` with `ansible.builtin.file` and `ansible.builtin.uri` + `ansible.builtin.copy` tasks.

4. **Artifact deployment (`myDeploy1` replacement)** *(medium risk)*
   Implement versioned artifact deployment using `ansible.builtin.get_url` (switch to HTTPS), `ansible.builtin.unarchive`, and a `version.txt`-based idempotency check. Requires coordination with the artifact server team to confirm HTTPS availability and checksum publication.

5. **Secrets integration (`mySecretFunction1` replacement)** *(high risk — prerequisite: secrets backend decision)*
   Integrate with the chosen Ansible-compatible secrets backend to retrieve `redis_service_token`. This step is blocked until the Platform Team confirms which backend `CompanyInternal::SecretStore` maps to and an Ansible collection is selected or developed.

6. **Enterprise Scheduler registration (`mySecretType1` replacement)** *(high risk — prerequisite: `schedulerctl` availability confirmed)*
   Implement scheduler registration using `ansible.builtin.command` with idempotency guards, or write a custom Ansible module in Python if full `present`/`absent` lifecycle management is required. Requires the `schedulerctl` binary to be available on target nodes and its API to be documented.

7. **PuppetDB node discovery → dynamic inventory** *(architectural — should be designed early, implemented last)*
   Design and implement the dynamic inventory strategy that replaces `puppetdb_query`. Although this is listed last (because it is an inventory-layer concern rather than a role-level concern), the **design decision must be made in Sprint 1** so that the inventory structure is available for integration testing of all preceding steps.

---

### Assumptions

1. **Single module repository**: The repository tree contains no `environment.conf`, `hiera.yaml`, or additional module directories. It is assumed this is a standalone profile module, not a Puppet control repo. If a control repo exists elsewhere, additional modules may be in scope.
2. **`company_internal_lib` gem identity**: The gem name and the secrets backend it wraps are not documented in the repository. It is assumed the Platform Team can identify the backend and provide migration guidance. If the backend is being decommissioned, a full secrets re-architecture is required.
3. **`schedulerctl` CLI stability**: It is assumed the proprietary `schedulerctl` binary will remain available on managed nodes post-migration and that its CLI interface (`register`, `unregister`, `query` subcommands) will not change during the migration window.
4. **Artifact server HTTPS availability**: The artifact URL in `init.pp` uses plain HTTP (`http://artifacts.internal/...`). It is assumed the artifact server supports HTTPS and that checksums (SHA256) are available, enabling a secure `ansible.builtin.get_url` call.
5. **`redis_role` fact usage scope**: The `redis_role` custom fact is defined in this module but its consumers (other profiles, Hiera lookups) are not visible in this repository. It is assumed the fact is only used within this module or in the broader control repo's Hiera data. If other modules depend on it, those modules are out of scope for this plan.
6. **PuppetDB replacement scope**: It is assumed the dynamic inventory replacement for `puppetdb_query` will be implemented at the Ansible inventory layer (not inside the role itself), and that the inventory will expose a group (e.g., `redis_cluster`) containing all cluster members.
7. **Target Ansible version**: Ansible Core 2.15+ is assumed, which provides all built-in modules referenced in this plan (`ansible.builtin.uri`, `ansible.builtin.get_url`, `ansible.builtin.unarchive`, `ansible.builtin.template`, etc.).
8. **No Hiera data in this repository**: There is no `data/` directory or `hiera.yaml` in the repository tree. It is assumed all Hiera data for this module lives in the control repo and will be migrated to Ansible group/host variables separately.
9. **Redis version**: The `puppet-redis 11.0.0` Forge module targets a specific Redis version, but the version is not pinned in this repository. It is assumed the target Redis version will be confirmed with the Platform Team before the Ansible role is written, so the correct package name and repository can be used on both RHEL and Ubuntu.
10. **`myapp` artifact ownership**: The `myDeploy1` resource deploys `myapp 2.1.0` from an internal artifact server. It is assumed the application team will confirm the current target version and artifact URL at migration time, as the hardcoded `2.1.0` may be stale.
