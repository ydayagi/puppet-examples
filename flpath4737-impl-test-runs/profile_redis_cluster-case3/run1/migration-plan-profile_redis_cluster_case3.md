---
source-path: manifests
---

# Migration Plan: redis_cluster

**TLDR**: This module provisions a Redis cluster node on Linux. It applies a base OS profile (utilities, NTP via chrony, syslog via rsyslog), then deploys a Redis server via the `profile_redis_cluster` module. The Redis deployment installs and configures the Redis service (port 6379, password-protected, 2 GB memory cap with `allkeys-lru` eviction, AOF persistence), creates a log directory, writes a health-check JSON file, deploys a versioned application artifact (`myapp` v2.1.0), and registers the node with a proprietary Enterprise Scheduler. Two custom functions are called at catalog compile time: one to fetch a health-check endpoint response and one to retrieve a secret token from a proprietary secret store. The module contains a hardcoded plaintext Redis password (`CHANGEME`) that must be replaced with a secure secret before migration.

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **redis** (single instance per node):
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Password: `CHANGEME` (hardcoded plaintext — must be replaced)
  - Max memory: `2048mb` with policy `allkeys-lru`
  - Persistence: AOF enabled, `appendfsync everysec`
  - Log directory: `/var/log/redis`

- **myapp** (versioned artifact deployment):
  - Version: `2.1.0`
  - Source URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`

- **redis-node** (Enterprise Scheduler registration):
  - Schedule: `daily`

- **chronyd** (NTP service):
  - Package: `chrony`
  - Service: `chronyd`, running and enabled

- **rsyslog** (syslog service):
  - Package: `rsyslog`
  - Service: `rsyslog`, running and enabled

## File Structure

```
../../site/role/manifests/redis_cluster.pp
../../site/profile/manifests/cache/redis.pp
../../site/profile/manifests/base/base.pp
../../site/modules/linux/profile_redis_cluster/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/install.pp
../../site/modules/common/base_utils/manifests/init.pp
../../site/modules/common/base_utils/data/common.yaml
../../site/modules/common/base_utils/data/os/Debian.yaml
../../site/modules/common/base_utils/data/os/RedHat.yaml
../../data/common.yaml
../../data/environment/production.yaml
../../data/environment/staging.yaml
lib/puppet/type/myDeploy1.rb
lib/puppet/provider/myDeploy1/myDeployProvider.rb
lib/puppet/type/mySecretType1.rb
lib/puppet/provider/mySecretType1/mySecretProvider1.rb
lib/puppet/type/myCronType1.rb
lib/puppet/provider/myCronType1/myCronProvider1.rb
lib/puppet/type/myFormatType1.rb
lib/puppet/provider/myFormatType1/myFormatProvider1.rb
lib/facter/redis_role.rb
lib/puppet/functions/myFunction1.rb
lib/puppet/functions/mySecretFunction1.rb
```

## Module Explanation

The module performs operations in this order:

1. **role::redis_cluster** (`../../site/role/manifests/redis_cluster.pp`):
   - Conditional (`$facts['kernel'].downcase == 'linux'` → true on Linux): sets `Exec[default]` path to `/usr/bin:/bin:/usr/sbin:/sbin` (applies to all `exec` resources in catalog)
   - `include ::profile::base::base` (no containment — runs independently)
   - `contain ::profile::cache::redis` (contained)
   - Ordering: `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base profile completes before Redis profile starts

2. **profile::base::base** (`../../site/profile/manifests/base/base.pp`):
   - Parameters resolved from Hiera (all `first` merge, no environment-level overrides): `$manage_utils = true`, `$manage_ntp = true`, `$manage_syslog = true`
   - Conditional (`$manage_utils == true` → true): `include base_utils` → walks into **base_utils** class (see step 3)
   - Conditional (`$manage_ntp == true AND $facts['kernel'] == 'Linux'` → true):
     - `package 'chrony'` → ensure: `installed`
     - `service 'chronyd'` → ensure: `running`, enable: `true`
   - Conditional (`$manage_syslog == true AND $facts['kernel'] == 'Linux'` → true):
     - `package 'rsyslog'` → ensure: `installed`
     - `service 'rsyslog'` → ensure: `running`, enable: `true`

3. **base_utils** (`../../site/modules/common/base_utils/manifests/init.pp`):
   - Parameters resolved from Hiera: `$manage_motd = true`, `$motd_template = 'base_utils/motd.erb'`, `$utility_packages` = OS-family dependent
   - Conditional (`$manage_motd == true` → true):
     - `file '/etc/motd'` → ensure: `file`, content: rendered from template `base_utils/motd.erb`, owner: `root`, group: `root`, mode: `0644`
   - Loop `$utility_packages.each |$pkg|`:
     - **On Debian-family hosts** — loop runs 5 times:
       - `package 'vim'` → ensure: `installed`
       - `package 'wget'` → ensure: `installed`
       - `package 'curl'` → ensure: `installed`
       - `package 'jq'` → ensure: `installed`
       - `package 'dnsutils'` → ensure: `installed`
     - **On RedHat-family hosts** — loop runs 5 times:
       - `package 'vim-enhanced'` → ensure: `installed`
       - `package 'wget'` → ensure: `installed`
       - `package 'curl'` → ensure: `installed`
       - `package 'jq'` → ensure: `installed`
       - `package 'bind-utils'` → ensure: `installed`
     - **On other OS families** — loop runs 0 times (default `$utility_packages = []`)

4. **profile::cache::redis** (`../../site/profile/manifests/cache/redis.pp`):
   - `$environment_name` resolved via `fact('environment')` at catalog compile time (e.g., `production`, `staging`)
   - `class { 'profile_redis_cluster': }` → walks into **profile_redis_cluster** class (see step 5)

5. **profile_redis_cluster** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
   - Parameters (all defaults, no Hiera overrides found): `$redis_port = 6379`, `$redis_password = 'CHANGEME'` ⚠️ **SECURITY: hardcoded plaintext password**, `$maxmemory_mb = 2048`, `$maxmemory_policy = 'allkeys-lru'`
   - PuppetDB query: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }")` — queries PuppetDB for all nodes running this class; result used for cluster membership awareness
   - Custom function: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET, returns parsed JSON or raw string
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `myFunction1('http://localhost:8080/health')`
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
   - Custom function: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary `CompanyInternal::SecretStore`; result stored in `$service_token` (used implicitly, not surfaced to a visible resource)
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present` (registers node with Enterprise Scheduler via `schedulerctl register --schedule daily redis-node`)
   - `contain profile_redis_cluster::install` → walks into **profile_redis_cluster::install** (see step 6)

6. **profile_redis_cluster::install** (`../../site/modules/linux/profile_redis_cluster/manifests/install.pp`):
   - `class { 'redis': }` (external/unanalyzed class) called with:
     - `bind = '0.0.0.0'`
     - `port = 6379`
     - `requirepass = 'CHANGEME'` ⚠️
     - `maxmemory = '2048mb'`
     - `appendonly = true`
     - `appendfsync = 'everysec'`
     - `manage_package = true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 8 variables across 3 Hiera levels (module common, module OS-family, environment). No environment-level overrides for any module keys.

### Variable Definitions

**base_utils/data/common.yaml (module defaults — lowest priority)** → Migration note: Base defaults for all nodes
- `base_utils::manage_motd`: `true` (type: boolean)
- `base_utils::motd_template`: `'base_utils/motd.erb'` (type: string)
- `base_utils::utility_packages`: `[]` (type: array — overridden on Debian and RedHat)

**base_utils/data/os/Debian.yaml (OS-family override)** → Migration note: OS-specific variables, loaded conditionally based on OS family (Debian); higher priority than module common on Debian hosts
- `base_utils::utility_packages`: `['vim', 'wget', 'curl', 'jq', 'dnsutils']` (type: array)

**base_utils/data/os/RedHat.yaml (OS-family override)** → Migration note: OS-specific variables, loaded conditionally based on OS family (RedHat); higher priority than module common on RedHat hosts
- `base_utils::utility_packages`: `['vim-enhanced', 'wget', 'curl', 'jq', 'bind-utils']` (type: array)

**profile_redis_cluster manifest defaults (no Hiera backing)**
- `profile_redis_cluster::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster::redis_password`: `'CHANGEME'` (type: String) ⚠️ **plaintext, no Hiera override, no Sensitive[] annotation**
- `profile_redis_cluster::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster::maxmemory_policy`: `'allkeys-lru'` (type: String)

**profile::base::base manifest defaults (no Hiera backing found in scanned files)**
- `profile::base::manage_ntp`: `true` (type: Boolean)
- `profile::base::manage_syslog`: `true` (type: Boolean)
- `profile::base::manage_utils`: `true` (type: Boolean)

### Variable Migration Summary

- **Module common defaults**: 3 variables (`manage_motd`, `motd_template`, `utility_packages`) from `base_utils/data/common.yaml`
- **OS-specific overrides**: 2 variables (`utility_packages` for Debian and RedHat)
- **Environment-specific**: 0 variables (no relevant keys in `production.yaml` or `staging.yaml`)
- **Host-specific**: 0 variables
- **Encrypted**: 0 variables — **1 plaintext secret** (`redis_password = 'CHANGEME'`) requiring secure storage migration

### Cross-Level Overrides

- **`base_utils::utility_packages`**: defined at module common (`[]`), overridden at OS-family level for Debian (`['vim', 'wget', 'curl', 'jq', 'dnsutils']`) and RedHat (`['vim-enhanced', 'wget', 'curl', 'jq', 'bind-utils']`); merge strategy: `first` (OS-family value wins entirely, no array merge)

### Merge Strategy Notes

- Variables using `first` (default) — First value found wins, no merging. All variables in this module use `first` merge strategy.

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Used in execution tree**: No — `myCronType1` does not appear in the execution tree for `role::redis_cluster`. Defined in the module but not instantiated.
- **Parameters**: `name` (namevar), `command` (required, non-empty), `hour` (default `'2'`), `minute` (default `'30'`), `ensure` (present/absent)
- **Provider behavior**: shells out to `crontab -l` (read) and `crontab -` (write) for root cron entries

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Used in execution tree**: Yes — `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }`
- **Parameters**: `name` (namevar), `version` (required, non-empty), `url` (must match `^https?://`), `install_dir`, `ensure` (default `present`)
- **Provider behavior**: checks `/opt/myapp/version.txt` for idempotency; creates `/opt/myapp`, downloads `artifact.tar.gz` from URL, extracts with `tar -xzf`, writes version to `/opt/myapp/version.txt`; destroy removes `/opt/myapp` entirely

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Used in execution tree**: No — not instantiated in `role::redis_cluster`
- **Parameters**: `entry` (namevar, non-empty), `file` (default `/etc/company/app.conf`), `value`, `ensure`
- **Provider behavior**: manages `!key=value` lines in a proprietary CompanyApp settings file

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Used in execution tree**: Yes — `mySecretType1 { 'redis-node': schedule => 'daily' }`
- **Parameters**: `name` (namevar), `schedule`, `ensure`
- **Provider behavior**: wraps `schedulerctl query`, `schedulerctl register --schedule <schedule> <name>`, `schedulerctl unregister <name>`

## Dependencies

**External module dependencies**: None (no Puppetfile found)

**Internal module dependencies**:
- `redis` class (called from `profile_redis_cluster::install`) — not analyzed; assumed to be a community Redis module managing package install, service, and configuration file
- `base_utils` — internal common module at `../../site/modules/common/base_utils`
- `profile_redis_cluster` — internal Linux module at `../../site/modules/linux/profile_redis_cluster`

**System package dependencies**:
- `chrony` (NTP)
- `rsyslog` (syslog)
- `redis` (managed by the unanalyzed `redis` class via `manage_package => true`)
- Debian utility packages: `vim`, `wget`, `curl`, `jq`, `dnsutils`
- RedHat utility packages: `vim-enhanced`, `wget`, `curl`, `jq`, `bind-utils`

**Service dependencies** (ordering):
- `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — all base OS setup (chrony, rsyslog, utilities) must complete before Redis cluster setup begins

## Puppet Facts Used

- `$facts['kernel']` — used in `role::redis_cluster` to set `Exec` path defaults (condition: `downcase == 'linux'`); used in `profile::base::base` to gate NTP and syslog management (condition: `== 'Linux'`)
- `fact('environment')` — used in `profile::cache::redis` to populate `$environment_name`; returns the Puppet environment name (e.g., `production`, `staging`)
- **Custom fact `redis_role`** (from `lib/facter/redis_role.rb`) — determines whether the node is a Redis `primary` or `replica` by checking existence of `/etc/redis/conf.d/replica.conf` and whether it contains the string `replicaof`; confined to Linux only

## Custom Types Used

- `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }` — declared in `profile_redis_cluster` (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`)
- `mySecretType1 { 'redis-node': schedule => 'daily' }` — declared in `profile_redis_cluster` (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`)
- `myCronType1` — defined in `lib/puppet/type/myCronType1.rb` but **not instantiated** in the execution tree
- `myFormatType1` — defined in `lib/puppet/type/myFormatType1.rb` but **not instantiated** in the execution tree

## Custom Providers Used

- `myDeployProvider` (`lib/puppet/provider/myDeploy1/myDeployProvider.rb`) — implements `myDeploy1`; used via `myDeploy1 { 'myapp': ... }` in `profile_redis_cluster`
- `mySecretProvider1` (`lib/puppet/provider/mySecretType1/mySecretProvider1.rb`) — implements `mySecretType1`; used via `mySecretType1 { 'redis-node': ... }` in `profile_redis_cluster`
- `myCronProvider1` (`lib/puppet/provider/myCronType1/myCronProvider1.rb`) — implements `myCronType1`; **not used** in the execution tree
- `myFormatProvider1` (`lib/puppet/provider/myFormatType1/myFormatProvider1.rb`) — implements `myFormatType1`; **not used** in the execution tree

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `profile_redis_cluster` (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`); performs HTTP GET, returns parsed JSON or raw string; result serialized to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `profile_redis_cluster` (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`); fetches secret named `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token` (used implicitly, not surfaced to a visible resource)

## Custom Component Conversion Decisions

This section covers all custom components defined in this module: custom types, providers, functions, and facts (including the custom Facter fact `redis_role`).

### myCronType1 + myCronProvider1
- **Conversion**: Existing Ansible modules
- **Mapping**: `ansible.builtin.cron` — `name` → `name`, `command` → `job`, `hour` → `hour` (default `'2'`), `minute` → `minute` (default `'30'`), `ensure: present/absent` → `state: present/absent`. The provider's `crontab -l`/`crontab -` shell-out is fully replaced by the Ansible module's native crontab management.
- **Note**: Not instantiated in this execution tree; include only if other roles use it.

### myDeploy1 + myDeployProvider
- **Conversion**: Existing Ansible modules
- **Mapping** (multi-step, conditioned on version-check idempotency):
  1. `ansible.builtin.stat` + read `/opt/myapp/version.txt` to check current version
  2. `ansible.builtin.file` with `state: directory` on `/opt/myapp` when version differs
  3. `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to `/opt/myapp/artifact.tar.gz`
  4. `ansible.builtin.unarchive` → `src: /opt/myapp/artifact.tar.gz`, `dest: /opt/myapp`, `remote_src: true`
  5. `ansible.builtin.copy` → `content: "2.1.0"`, `dest: /opt/myapp/version.txt`
  6. For `ensure: absent`: `ansible.builtin.file` with `state: absent` on `/opt/myapp`
- **URL validation**: enforce via `ansible.builtin.assert` that `url` matches `^https?://` before download tasks

### myFormatType1 + myFormatProvider1
- **Conversion**: CUSTOM ANSIBLE MODULE NEEDED
- **Not instantiated** in this execution tree, but the module is defined and may be used in other roles.
- **Required module behavior**: Manages `!key=value` entries in a proprietary CompanyApp settings file at `/etc/company/app.conf` (configurable via `file` parameter).
  - **Parameters**: `file` (str, required), `entry` (str, required), `value` (str, required when `state=present`), `state` (str, default `present`)
  - **Read**: parse file line by line; valid entries start with `!`, contain `=`
  - **state=present**: if matching key exists with correct value → no change; otherwise remove all lines matching key, append `!entry=value`
  - **state=absent**: remove all lines matching key; no-op if absent
  - **Write**: overwrite file preserving all non-matching lines, comments, and blank lines
  - **Returns**: `changed: true/false` plus optional diff
  - **Error handling**: raise on non-writable path or missing required parameters

### mySecretType1 + mySecretProvider1
- **Conversion**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The provider wraps `schedulerctl` (`/usr/local/bin/schedulerctl`), a proprietary Enterprise Scheduler CLI. The semantics of `schedulerctl query <name>`, `schedulerctl register --schedule <schedule> <name>`, and `schedulerctl unregister <name>` — including output format, exit codes, error conditions, and idempotency guarantees — are entirely undocumented and opaque. A custom Ansible module wrapping `ansible.builtin.command` for `schedulerctl` subcommands could be written, but only after the full CLI contract is documented or reverse-engineered. The automation developer must obtain the Enterprise Scheduler platform documentation or provider source before proceeding.

### Custom fact: redis_role
- **Conversion**: Existing Ansible modules
- **Mapping**: Deploy a static fact script to `/etc/ansible/facts.d/redis_role.fact` on target hosts (Ansible picks it up automatically via `setup` as `ansible_local.redis_role`). Alternatively, inline the logic:
  1. `ansible.builtin.stat` on `/etc/redis/conf.d/replica.conf` → register result
  2. `ansible.builtin.slurp` or `ansible.builtin.shell` to read file contents when it exists
  3. `ansible.builtin.set_fact` → `redis_role: "replica"` if file exists and contains `replicaof`, else `redis_role: "primary"`

### myFunction1
- **Conversion**: Existing Ansible modules
- **Mapping**: `ansible.builtin.uri` with `method: GET`, `url: "http://localhost:8080/health"`, `return_content: true`. The `json` return key provides parsed JSON automatically; `content` provides the raw body as fallback. Non-2xx responses raise an error by default (`status_code: [200]`).

### mySecretFunction1
- **Conversion**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The function delegates to `CompanyInternal::SecretStore.fetch`, a method from the proprietary `company_internal_lib` Ruby library. The backend (Vault, AWS Secrets Manager, internal DB, etc.), authentication mechanism, and return format are entirely opaque. The automation developer must obtain `company_internal_lib` source or documentation to determine the correct Ansible equivalent (e.g., `community.hashi_vault.hashi_vault_kv_get`, `amazon.aws.secretsmanager_secret`, or a custom lookup plugin). The fetched value (`redis_service_token`) is used in the catalog but not surfaced to a visible resource — its downstream consumer must also be identified.

## Template Conversion Notes

### `base_utils/motd.erb`
- **Destination**: `/etc/motd`
- **Render count**: 1 (per node)
- **Variables used**: resolved from `base_utils` class scope; exact variables within the template are not visible without reading the template file, but the template is referenced as `base_utils/motd.erb` (module-relative path)
- **Ansible equivalent**: `ansible.builtin.template` with a Jinja2 `.j2` version of the MOTD template, rendered to `/etc/motd`

## PuppetDB Dependencies

**Context**: PuppetDB provides a centralized data store for cross-node resource sharing, node facts, and infrastructure queries.

- **Query in `profile_redis_cluster`** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
  - Exact query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Returned data: list of all certnames (hostnames) that have the `profile_redis_cluster` class applied; stored in `$redis_nodes`
  - Purpose: cluster membership awareness (e.g., building a list of peer nodes)
  - Migration note: PuppetDB queries have no direct Ansible equivalent. The cluster node list must be managed via Ansible inventory groups (e.g., `[redis_cluster]`), dynamic inventory scripts, or a service discovery mechanism. Use `groups['redis_cluster']` or `hostvars` to replicate the peer-list behavior. The automation developer must decide whether to use static inventory, a dynamic inventory plugin (e.g., AWS EC2, Consul), or a custom script.

## Checks for the Migration

**Files to verify**:
- `/etc/motd` — MOTD rendered from `base_utils/motd.erb`
- `/var/lib/redis/health_check.json` — JSON content from health-check endpoint
- `/var/log/redis` — directory, owner `redis`, group `redis`, mode `0755`
- `/opt/myapp/version.txt` — contains `2.1.0`
- `/opt/myapp/` — artifact extracted
- `/etc/redis/conf.d/replica.conf` — presence/content determines `redis_role` fact

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check: `curl http://localhost:8080/health` → should return JSON

**Templates rendered**:
- `base_utils/motd.erb` → `/etc/motd` (1 render per node)

## Pre-flight checks:
```bash
# Security pre-flight — confirm password has been replaced before deploying to any environment
grep -r 'CHANGEME' /etc/redis/ && echo "WARNING: default password still in use"

# NTP service (chronyd)
systemctl status chronyd

# Syslog service (rsyslog)
systemctl status rsyslog

# Redis service
systemctl status redis

# Redis connectivity and replication role
redis-cli -p 6379 -a CHANGEME ping
redis-cli -p 6379 -a CHANGEME info replication

# Verify redis_role fact matches replication config
cat /etc/redis/conf.d/replica.conf 2>/dev/null || echo "replica.conf not present — node is primary"

# myapp artifact deployment
cat /opt/myapp/version.txt

# Health-check endpoint
curl -sf http://localhost:8080/health

# Health-check JSON file written by myFunction1
cat /var/lib/redis/health_check.json

# Enterprise Scheduler registration (redis-node)
# WARNING: blocked pending schedulerctl CLI documentation — see mySecretType1 conversion decision
schedulerctl query redis-node

# Log directory ownership and permissions
stat /var/log/redis
```