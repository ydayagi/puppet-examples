# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version **3.1.0**, authored by the Platform Team, and targets **Red Hat Enterprise Linux 8/9** and **Ubuntu 22.04/24.04**.

The migration scope is moderate in size (one module, two manifests, one template) but carries **above-average complexity** due to four non-trivial custom extensions that have no direct Ansible equivalents:

| Extension | Type | Migration Complexity |
|---|---|---|
| `myFunction1` | HTTP health-check Puppet function | Medium — replace with Ansible `uri` module |
| `mySecretFunction1` | Internal secret-store Puppet function | **High** — depends on proprietary `company_internal_lib` |
| `myDeploy1` / `myDeployProvider` | Custom artifact-deployment type/provider | Medium — replace with Ansible `get_url` + `unarchive` |
| `mySecretType1` / `mySecretProvider1` | Enterprise Scheduler registration type/provider | **High** — wraps proprietary `schedulerctl` CLI |

The hardcoded default password (`CHANGEME`) and the proprietary secret-store integration are the two most critical items to resolve before any Ansible role can be considered production-ready.

**Estimated migration timeline: 2–3 sprints (4–6 weeks)** for a single engineer, accounting for secret-store integration research, scheduler CLI wrapping, and testing on both OS families.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**
  - **Description**: Redis cluster node profile that installs and configures a Redis server via the `puppet-redis` Forge module, performs PuppetDB-based cluster node discovery, runs an HTTP health check against a local application endpoint, deploys a versioned application artifact from an internal artifact server, retrieves a service token from a proprietary internal secret store, and registers the node with a proprietary Enterprise Scheduler platform.
  - **Path**: `.` (repository root — the module IS the repository)
  - **Technology**: Puppet (module version 3.1.0, requires Puppet >= 7.0.0 < 9.0.0)
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (bind `0.0.0.0`, port 6379, `requirepass`, AOF persistence with `appendfsync everysec`, RDB snapshots, `maxmemory` + `maxmemory-policy`)
    - PuppetDB live node discovery (`puppetdb_query`) to enumerate all cluster members at catalog compile time
    - Custom Facter fact `redis_role` — detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf` at runtime
    - HTTP health-check function (`myFunction1`) that GETs `http://localhost:8080/health` and writes the JSON result to `/var/lib/redis/health_check.json`
    - Versioned artifact deployment (`myDeploy1` custom type/provider) — downloads a `.tar.gz` from an internal artifact server, extracts it to `/opt/myapp`, and tracks the installed version via `version.txt`
    - Proprietary secret retrieval (`mySecretFunction1`) via `company_internal_lib` — fetches `redis_service_token` at catalog compile time
    - Enterprise Scheduler registration (`mySecretType1` custom type/provider) — calls `/usr/local/bin/schedulerctl register/unregister` to register the node on a daily schedule
    - ERB template (`redis.conf.erb`) rendering a full `redis.conf` with FQDN comment, security, persistence, memory, and network settings

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). These must be replaced with equivalent Ansible collections or roles.
- `metadata.json`: Module metadata declaring OS support (RHEL 8/9, Ubuntu 22.04/24.04), Puppet version constraints, and Forge dependencies. Serves as the authoritative source for target OS matrix during Ansible role scaffolding.
- `templates/redis.conf.erb`: ERB template for the full Redis configuration file. Must be converted to a Jinja2 template (`redis.conf.j2`) for use with the Ansible `template` module. Variable names map directly: `@redis_port` → `{{ redis_port }}`, `@redis_password` → `{{ redis_password }}`, etc.
- `lib/facter/redis_role.rb`: Custom Facter fact that determines node role (`primary`/`replica`) by inspecting a local config file. Must be re-implemented as an Ansible task using `stat` + `lineinfile`/`slurp` to set a host variable or fact (`set_fact`).
- `lib/puppet/functions/myFunction1.rb`: Puppet function performing an HTTP GET at catalog compile time. Replace with the Ansible `uri` module at task execution time.
- `lib/puppet/functions/mySecretFunction1.rb`: Puppet function calling `CompanyInternal::SecretStore.fetch()` via `company_internal_lib`. Requires investigation of the internal secret store's API/CLI to determine the correct Ansible Vault or secrets-manager integration path.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom type/provider for versioned artifact deployment (download → extract → version-track). Replace with Ansible `get_url` + `unarchive` + `copy`/`template` for version tracking.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom type/provider wrapping the proprietary `schedulerctl` CLI for Enterprise Scheduler registration. Replace with Ansible `command`/`shell` tasks or a custom Ansible module that wraps `schedulerctl`.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary), Ubuntu 22.04 and 24.04 (secondary) — explicitly declared in `metadata.json`. The `puppetlabs-apt` dependency in the `Puppetfile` confirms active Ubuntu support. Ansible tasks must use `ansible_os_family` conditionals (`RedHat` vs `Debian`) where package names or paths differ.
- **Virtual Machine Technology**: Not specified in the repository. No cloud-init configs, VM tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud provider SDKs, metadata endpoint references, or cloud-specific configurations are present. The internal artifact URL (`http://artifacts.internal/`) and scheduler CLI suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no additional collection required.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community `community.general` collection or the dedicated `geerlingguy.redis` Ansible role from Ansible Galaxy. Evaluate feature parity for bind address, password, AOF, and maxmemory parameters before selecting.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu. Replace with the `ansible.builtin.apt_repository` module for Ubuntu targets; no equivalent needed for RHEL (use `ansible.builtin.dnf`).
- **puppetdb_query (PuppetDB)**: Used for live cluster node discovery at catalog compile time. This is a **Puppet-specific capability with no direct Ansible equivalent**. Replace with Ansible dynamic inventory (e.g., a custom inventory plugin, an existing cloud/CMDB inventory source, or a static group populated by a CI/CD pipeline). This is the most architecturally significant dependency to resolve.
- **company_internal_lib (proprietary)**: Ruby gem used by `mySecretFunction1` to fetch secrets. The Ansible replacement depends entirely on what backend this library wraps (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.). This must be investigated with the Platform/Security team before migration begins.
- **schedulerctl CLI (proprietary)**: Binary at `/usr/local/bin/schedulerctl` used by `mySecretType1`. Wrap with an Ansible `command` task or write a lightweight custom Ansible module. Idempotency must be implemented explicitly (query before register/unregister).

---

### Security Considerations

- **Hardcoded default Redis password**: `manifests/init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default. This plaintext default must be eliminated. In Ansible, this variable must be sourced exclusively from Ansible Vault or an external secrets manager — never stored in plaintext in role defaults or inventory.
- **Redis password in `redis.conf.erb`**: The `requirepass` directive is rendered directly from `@redis_password` into the configuration file. The Ansible `template` task writing `redis.conf.j2` must ensure the destination file has restrictive permissions (`mode: '0600'`, `owner: redis`, `group: redis`) to prevent world-readable credentials on disk.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` is fetched at Puppet catalog compile time from an internal secret store. The migration team must identify the underlying secret store backend and implement the equivalent Ansible lookup plugin (e.g., `community.hashi_vault.hashi_vault`, `azure.azcollection.azure_keyvault_secret`, or a custom lookup). Credentials for the secret store itself must also be managed securely.
- **Artifact download over plain HTTP**: The `myDeploy1` resource fetches `http://artifacts.internal/myapp-2.1.0.tar.gz` over unencrypted HTTP. When replacing with `ansible.builtin.get_url`, the URL should be upgraded to HTTPS and checksum validation (`checksum` parameter) should be added to prevent tampering.
- **`schedulerctl` CLI trust**: The `mySecretType1` provider executes `/usr/local/bin/schedulerctl` with node name and schedule arguments. When wrapping in Ansible, ensure the binary path is validated and that no user-controlled input is passed unsanitized to avoid command injection.
- **Redis bound to `0.0.0.0`**: Both `manifests/install.pp` and `redis.conf.erb` bind Redis to all interfaces. This should be reviewed during migration — if the cluster operates on a dedicated network interface, the bind address should be parameterized and restricted accordingly in the Ansible role.

---

### Technical Challenges

- **PuppetDB cluster node discovery**: `puppetdb_query()` provides dynamic, compile-time cluster membership that has no native Ansible equivalent. This is the most significant architectural gap. Mitigation: implement a dynamic inventory source (CMDB, cloud tags, or a dedicated inventory service) that populates an Ansible group with all Redis cluster members before playbook execution. Alternatively, use Ansible `add_host` with a pre-task that queries an available API.
- **Custom Puppet type/provider for artifact deployment (`myDeploy1`)**: The provider implements idempotent version-tracked deployment logic (check `version.txt`, download, extract). Ansible's `get_url` + `unarchive` combination is stateless by default. Idempotency must be re-implemented explicitly using `stat` to check the version file and `when` conditionals to skip download/extraction if the correct version is already installed.
- **Proprietary `schedulerctl` integration (`mySecretType1`)**: The Enterprise Scheduler registration has no Ansible module. A custom Ansible module or a carefully guarded `command` task with explicit idempotency (`changed_when`, `failed_when`) must be written. The team must obtain `schedulerctl` documentation and test environment access before this task can be completed.
- **Proprietary secret store integration (`mySecretFunction1`)**: The `company_internal_lib` Ruby gem is entirely internal. Without knowing its backend, the correct Ansible lookup plugin cannot be selected. This is a **blocking dependency** — the migration cannot be finalized until the secret store backend is identified and an Ansible-compatible integration path is confirmed with the Security team.
- **Compile-time vs. run-time secret retrieval**: In Puppet, `mySecretFunction1` is called at catalog compile time (on the Puppet server). In Ansible, secrets are resolved at playbook execution time on the control node. This timing difference may affect how the `redis_service_token` is used downstream and must be validated with the application team.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact is available to all Puppet resources at catalog compile time. In Ansible, the equivalent must be gathered as a task-level fact using `set_fact` after inspecting the replica config file. Any tasks that conditionally branch on `redis_role` must be restructured to run after the fact-gathering task.
- **Dual OS family support**: The module targets both RHEL (dnf/yum) and Debian/Ubuntu (apt) families. The Ansible role must use `ansible_os_family` or `ansible_distribution` conditionals for package installation, service names, and any path differences. The `puppetlabs-apt` dependency confirms that APT-specific logic is actively used and must not be overlooked.

---

### Migration Order

1. **ERB → Jinja2 template conversion** (`redis.conf.erb` → `redis.conf.j2`): Zero-risk, purely mechanical translation. Establishes the role's variable interface and confirms all configuration parameters before any logic is migrated.
2. **Redis installation and base configuration** (replaces `profile_redis_cluster_case2::install` / `puppet-redis`): Install the Redis package, deploy `redis.conf.j2`, manage the service, and create `/var/log/redis`. Use `community.general` or `geerlingguy.redis` as a base. Validates the core role on both OS families before adding complexity.
3. **`redis_role` fact** (replaces `lib/facter/redis_role.rb`): Implement as an Ansible `set_fact` task using `stat` + `slurp` on `/etc/redis/conf.d/replica.conf`. Low risk; enables role-conditional logic in later tasks.
4. **HTTP health check** (replaces `myFunction1`): Implement with `ansible.builtin.uri` writing the JSON response to `/var/lib/redis/health_check.json` via `copy`. Straightforward replacement with well-supported Ansible modules.
5. **Artifact deployment** (replaces `myDeploy1` / `myDeployProvider`): Implement with `get_url` + `unarchive` + `stat`/`copy` for version tracking. Upgrade the artifact URL to HTTPS and add checksum validation. Medium complexity due to idempotency re-implementation.
6. **Cluster node discovery** (replaces `puppetdb_query`): Design and implement the dynamic inventory strategy. This is an architectural decision that must be agreed upon with the broader infrastructure team before implementation. High coordination effort.
7. **Secret store integration** (replaces `mySecretFunction1` / `company_internal_lib`): Implement the correct Ansible lookup plugin once the backend is identified. **Blocked until the Security team confirms the secret store backend and provides Ansible integration guidance.**
8. **Enterprise Scheduler registration** (replaces `mySecretType1` / `mySecretProvider1` / `schedulerctl`): Implement as a custom Ansible module or idempotent `command` task wrapping `schedulerctl`. **Blocked until `schedulerctl` documentation and a test environment are available.**

---

### Assumptions

1. **Secret store backend is unknown**: `company_internal_lib` is a proprietary Ruby gem with no documentation in this repository. It is assumed that the Platform/Security team can identify the underlying backend (Vault, CyberArk, cloud KMS, etc.) and provide integration guidance. The migration cannot be completed without this information.
2. **`schedulerctl` is available on target nodes**: It is assumed that `/usr/local/bin/schedulerctl` will continue to be present on managed nodes after the migration to Ansible. If the scheduler platform itself is being decommissioned or replaced, the `mySecretType1` migration task becomes a decommission task instead.
3. **Artifact server remains accessible**: The internal artifact URL (`http://artifacts.internal/`) is assumed to remain available during and after migration. The URL scheme should be upgraded to HTTPS; it is assumed the artifact server supports HTTPS.
4. **PuppetDB will not be available post-migration**: Ansible does not natively integrate with PuppetDB. It is assumed that an alternative inventory source (CMDB, cloud tags, or a dedicated service) will be established to replace `puppetdb_query`-based cluster discovery.
5. **`redis_service_token` usage is limited to this module**: The token fetched by `mySecretFunction1` is stored in `$service_token` but its downstream use is not visible in the reviewed files. It is assumed it is consumed only within this module. If it is passed to other systems, additional migration scope may be required.
6. **Single-module repository**: The repository tree shows no additional Puppet modules, roles, or profiles beyond `profile_redis_cluster_case2`. It is assumed this is a standalone module repository, not a Puppet control repo with an `environment.conf` or a `site/` directory.
7. **`puppetlabs-apt` is used only for Ubuntu package sources**: Given the module's focus on Redis, it is assumed `puppetlabs-apt` is used solely to manage the Redis APT repository on Ubuntu targets. No other APT-managed resources are assumed to exist outside the reviewed files.
8. **Target Ansible version**: It is assumed Ansible Core 2.15 or later will be used, which provides full support for the `uri`, `get_url`, `unarchive`, `template`, and `set_fact` modules relied upon in this plan.
9. **Redis password will be migrated to a secrets manager**: The `CHANGEME` default is a placeholder. It is assumed the actual production password is already managed externally (via the same secret store as `redis_service_token`) and will be injected via Ansible Vault or a lookup plugin — not hardcoded in role variables.
10. **No Hiera data files exist**: The repository contains no `data/` directory or `hiera.yaml`. It is assumed all module parameters are passed via Puppet class declarations in a higher-level control repo and will be translated to Ansible role variables (`defaults/main.yml` + inventory group/host vars).
