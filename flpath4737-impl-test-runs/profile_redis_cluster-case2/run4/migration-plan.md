# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version 3.1.0, authored by the Platform Team, and targets Red Hat Enterprise Linux 8/9 and Ubuntu 22.04/24.04.

The migration scope is moderate in size (one module, two manifests, one template) but carries **above-average complexity** due to four non-standard extension points that have no direct Ansible equivalents:

| Extension Point | Type | Migration Complexity |
|---|---|---|
| `myFunction1` | Custom Puppet function — HTTP health-check poller | Medium |
| `mySecretFunction1` | Custom Puppet function — internal secret store client | High |
| `myDeploy1` type + provider | Custom Puppet resource — artifact download & install | Medium |
| `mySecretType1` type + provider | Custom Puppet resource — proprietary scheduler registration | High |

The two "secret" extensions depend on a proprietary internal library (`company_internal_lib`) and a proprietary CLI (`schedulerctl`). These integrations must be resolved with the owning teams before migration can be completed.

**Estimated timeline**: 3–5 sprints (6–10 weeks) for a single engineer, accounting for the proprietary integration discovery work.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**:
  - **Description**: Redis cluster node profile that installs and configures a Redis server via the `puppet-redis` Forge module, performs PuppetDB-based cluster node discovery, runs an HTTP health check against a local application endpoint, deploys a versioned application artifact (`myapp 2.1.0`) from an internal artifact server, retrieves a Redis service token from a proprietary internal secret store, and registers the node with a proprietary Enterprise Scheduler platform.
  - **Path**: `.` (module root — `manifests/init.pp`, `manifests/install.pp`, `templates/redis.conf.erb`)
  - **Technology**: Puppet 7/8
  - **Key Features**:
    - PuppetDB live node discovery (`puppetdb_query`) to enumerate cluster peers
    - Redis installation and configuration via `puppet-redis` (bind `0.0.0.0`, port, password, maxmemory, AOF persistence, RDB snapshots)
    - Parameterised `redis.conf.erb` template (port, password, maxmemory, maxmemory-policy, persistence, network tuning)
    - Custom Facter fact `redis_role` — detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf`
    - Custom function `myFunction1` — HTTP GET poller that writes a JSON health-check result to `/var/lib/redis/health_check.json`
    - Custom function `mySecretFunction1` — fetches `redis_service_token` from `CompanyInternal::SecretStore` (proprietary Ruby library `company_internal_lib`)
    - Custom type/provider `myDeploy1` — downloads a `.tar.gz` artifact from an internal URL and installs it to `/opt/myapp`, tracking version via `version.txt`
    - Custom type/provider `mySecretType1` — registers the node with a proprietary Enterprise Scheduler via the `schedulerctl` CLI (`/usr/local/bin/schedulerctl`)
    - Log directory management (`/var/log/redis`, owner `redis:redis`, mode `0755`)

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be replaced by Ansible Galaxy `requirements.yml` and/or OS package management.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraints, dependency version ranges). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and will guide Ansible role `meta/main.yml`.
- `templates/redis.conf.erb`: ERB template for `redis.conf`. Directly portable to an Ansible Jinja2 template (`.j2`) with minor variable-syntax changes (`<%= @var %>` → `{{ var }}`).
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica`. Must be re-implemented as an Ansible fact (e.g., a `set_fact` task that reads `/etc/redis/conf.d/replica.conf`, or a custom `facts.d` script).
- `lib/puppet/functions/myFunction1.rb`: Custom HTTP GET function. Replace with Ansible `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Custom secret-retrieval function backed by `company_internal_lib`. Replace with an Ansible secrets-management lookup plugin (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.) — **requires coordination with the secret-store owning team**.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom artifact-deployment resource. Replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom Enterprise Scheduler registration resource backed by `schedulerctl` CLI. Replace with Ansible `command`/`shell` tasks wrapping `schedulerctl`, or a purpose-built Ansible module — **requires coordination with the scheduler platform team**.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary targets per `metadata.json`); Ubuntu 22.04 and 24.04 also supported. Package management differs between families — the `puppetlabs-apt` dependency confirms Debian/Ubuntu handling is in scope.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The internal artifact URL (`http://artifacts.internal/`) and internal secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides `stdlib::to_json()` used in `init.pp`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community Ansible role `geerlingguy.redis` (Galaxy) or equivalent, supplemented by the migrated `redis.conf.j2` template.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu/Debian targets. Replace with the Ansible `ansible.builtin.apt_repository` module or the `geerlingguy.repo-*` roles for Ubuntu targets.
- **PuppetDB (`puppetdb_query`)**: Used for live cluster node discovery. Replace with Ansible dynamic inventory (static group vars, an inventory plugin, or a custom script querying a CMDB/service registry). This is the most architecturally significant dependency to resolve.
- **`company_internal_lib` (Ruby gem)**: Proprietary secret-store client used by `mySecretFunction1`. The Ansible equivalent lookup plugin or integration method must be determined with the owning team. Candidate replacements: `community.hashi_vault.hashi_vault` lookup, `azure_rm_keyvault`, or a custom lookup plugin wrapping the same internal API.
- **`schedulerctl` CLI**: Proprietary binary at `/usr/local/bin/schedulerctl` used by the `mySecretType1` provider. Must remain available on managed nodes, or the registration logic must be moved to a control-plane task using an API call. Coordinate with the Enterprise Scheduler platform team.

---

### Security Considerations

- **Hardcoded default password**: `init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default. In Ansible, this must be replaced with a variable sourced from Ansible Vault or an external secrets manager — the plaintext default must never appear in role defaults or inventory.
- **Redis `requirepass`**: The password flows from the Puppet parameter into both the `puppet-redis` class call and the `redis.conf.erb` template. In Ansible, it must be injected via a vaulted variable and rendered into `redis.conf.j2` at deploy time.
- **`mySecretFunction1` / `redis_service_token`**: A service token is fetched at catalog compile time from a proprietary secret store. The Ansible replacement must integrate with the same (or an equivalent) secrets backend. The token must never be logged or stored in plain text in playbooks, inventory, or role variables.
- **Internal artifact URL**: `myDeploy1` downloads from `http://artifacts.internal/myapp-2.1.0.tar.gz` over plain HTTP. The Ansible `get_url` replacement should enforce HTTPS and checksum validation (`checksum` parameter) to prevent supply-chain tampering.
- **Redis binding to `0.0.0.0`**: The module explicitly binds Redis to all interfaces. This should be reviewed during migration — consider restricting to specific interface addresses via an Ansible variable and firewall rules (`ansible.posix.firewalld` / `ufw`).
- **AOF + RDB persistence credentials**: Persistence files (`appendonly.aof`, `dump.rdb`) are written to `/var/lib/redis` owned by the `redis` user. Ensure the Ansible role enforces the same ownership and that backup procedures handle these files securely.
- **`schedulerctl` registration**: The CLI runs with whatever privileges the Ansible connection user has. Ensure the task uses `become: false` or a least-privilege account, and that the scheduler API credentials (if any) are vaulted.

---

### Technical Challenges

- **PuppetDB node discovery → Ansible dynamic inventory**: `puppetdb_query` is called at catalog compile time to enumerate all cluster peers. Ansible has no equivalent compile-time query. This must be redesigned as a dynamic inventory source (e.g., a CMDB query, a cloud provider inventory plugin, or a static group) executed before the play runs. This is the most significant architectural change in the migration.
- **Custom Puppet types/providers → Ansible tasks**: `myDeploy1` and `mySecretType1` are idempotent Puppet resources with `exists?`/`create`/`destroy` semantics. Replicating idempotency in Ansible requires careful use of `stat`, `get_url`, `unarchive`, and `command` tasks with `creates` or `changed_when` guards. The logic is straightforward but must be explicitly re-implemented.
- **Proprietary `company_internal_lib` integration**: This Ruby library has no published API documentation in the repository. The migration team must obtain the API contract from the owning team and implement an equivalent Ansible lookup plugin or use an existing secrets-manager integration. This is a potential long-lead-time blocker.
- **`schedulerctl` CLI dependency**: The proprietary scheduler CLI must be present on managed nodes (or on the Ansible control node if the registration is a control-plane operation). Its availability, authentication model, and idempotency guarantees must be confirmed with the platform team before the Ansible `command` wrapper is written.
- **ERB → Jinja2 template conversion**: `redis.conf.erb` uses `<%= @facts['networking']['fqdn'] %>` and `<%= @var %>` syntax. The conversion to Jinja2 (`{{ ansible_fqdn }}`, `{{ redis_port }}`) is mechanical but must be validated against all variable names used in the template and their Ansible equivalents.
- **Custom Facter fact → Ansible fact**: `redis_role` is set at agent run time by inspecting a file. In Ansible, this can be a `set_fact` task or a `facts.d` script, but it must run early in the play (before any task that consumes it) and be explicitly included in the play's fact-gathering phase.
- **Multi-OS support**: The module targets both RHEL (yum/dnf) and Ubuntu (apt). The Ansible role must use `ansible_os_family` conditionals or separate task files for package installation and service management across both families. The `puppetlabs-apt` dependency confirms that APT repository configuration is required for Ubuntu targets.
- **Internal artifact server (HTTP)**: The artifact URL uses plain HTTP. If the internal server does not support HTTPS, the migration team must either enforce a network-level control or accept the risk and document it. Ansible's `get_url` supports checksum verification as a compensating control.

---

### Migration Order

1. **Redis configuration template** (`redis.conf.erb` → `redis.conf.j2`): Low risk, purely mechanical ERB-to-Jinja2 conversion. Delivers an immediately testable artifact and validates the variable mapping early.
2. **Redis installation and base configuration** (`manifests/install.pp` → Ansible tasks + `geerlingguy.redis` role): Replaces the `puppet-redis` Forge dependency. Can be developed and tested in isolation on a single node before cluster concerns are introduced.
3. **Custom Facter fact** (`lib/facter/redis_role.rb` → Ansible `set_fact` task): Simple file-inspection logic; implement as an early task in the play so downstream tasks can consume `redis_role`.
4. **Health-check HTTP poller** (`myFunction1` → `ansible.builtin.uri` task): Straightforward replacement; write the result to `/var/lib/redis/health_check.json` using the `copy` module with `content: "{{ health_result | to_json }}"`.
5. **Artifact deployment** (`myDeploy1` type/provider → `get_url` + `unarchive` tasks): Implement idempotency via `stat` on `version.txt` and `get_url` with `force: false`. Resolve the HTTP→HTTPS and checksum concerns at this step.
6. **Dynamic inventory / cluster node discovery** (PuppetDB query → Ansible inventory): Requires the most architectural design work. Engage the CMDB/infrastructure team early; this step gates any multi-node cluster play.
7. **Secret store integration** (`mySecretFunction1` / `company_internal_lib` → Ansible lookup plugin): Requires external team coordination. Begin discovery in parallel with steps 1–4 to avoid a late-stage blocker.
8. **Enterprise Scheduler registration** (`mySecretType1` / `schedulerctl` → Ansible `command` tasks): Requires platform team coordination. Implement last, after the scheduler API contract and idempotency model are confirmed.

---

### Assumptions

1. **Single module scope**: The repository tree contains no `environment.conf`, `hiera.yaml`, or additional module directories. It is assumed this is a standalone module repository, not a Puppet control repo. If a broader control repo exists, the inventory of modules to migrate will be larger.
2. **`company_internal_lib` API**: The proprietary Ruby gem's API, authentication mechanism, and the secrets backend it connects to are unknown from the repository alone. It is assumed the owning team can provide this information and that an Ansible-compatible equivalent (lookup plugin or external secrets manager) exists or can be built.
3. **`schedulerctl` availability**: It is assumed that `/usr/local/bin/schedulerctl` will remain available on managed nodes during and after migration, and that its CLI interface is stable. If the scheduler platform is also being migrated, this assumption must be revisited.
4. **Internal artifact server**: It is assumed that `http://artifacts.internal/` is a stable, internally managed artifact repository (e.g., Nexus, Artifactory) that will remain accessible from Ansible-managed nodes. The HTTP (non-TLS) URL is flagged as a security concern.
5. **PuppetDB replacement**: It is assumed that an alternative node-discovery mechanism (CMDB, cloud inventory, static groups) exists or can be established. If PuppetDB is the only source of truth for cluster membership, a new inventory source must be built before the cluster-aware play can be written.
6. **Redis password management**: The `CHANGEME` default password is assumed to be overridden in all real environments via Hiera or an external node classifier. The Ansible migration must enforce that no plaintext password default is carried forward.
7. **Target Ansible version**: Ansible Core 2.15+ is assumed, which provides all required built-in modules (`uri`, `get_url`, `unarchive`, `ansible.builtin.template`, `set_fact`) and supports the `community.general` and `ansible.posix` collections needed for this role.
8. **OS parity**: Both RHEL 8/9 and Ubuntu 22.04/24.04 are in scope per `metadata.json`. It is assumed the Ansible role must support all four OS versions, requiring conditional task logic for package management.
9. **No Hiera data**: No `data/` directory or `hiera.yaml` is present in the repository. It is assumed all configuration is passed as class parameters (mapped to Ansible role variables) and that no Hiera hierarchy needs to be replicated.
10. **`myapp` artifact**: The artifact URL `http://artifacts.internal/myapp-2.1.0.tar.gz` is hardcoded in `init.pp`. It is assumed the version (`2.1.0`) and URL pattern are representative and that the Ansible role will parameterise the version as a variable rather than hardcoding it.
