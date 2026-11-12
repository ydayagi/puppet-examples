---
source-path: .
---

# Migration Plan: profile_redis_cluster (role::redis_cluster)

**TLDR**: This module configures a Redis cluster node on Linux. It applies a base OS profile (NTP via chrony, syslog via rsyslog, and optional utility packages), then installs and configures a Redis instance via the `profile_redis_cluster` module. The module also deploys a companion application artifact (`myapp`), registers the node with a proprietary Enterprise Scheduler, performs a health-check HTTP call at catalog compile time, and writes the result to a JSON file. It uses PuppetDB to discover peer cluster members. Several custom types and functions are not safely convertible without additional documentation.

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **Redis**: single Redis instance per node, acting as a cluster member
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Password: `CHANGEME` (hardcoded default — must be rotated)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Append-only persistence: enabled, fsync: `everysec`
- **myapp**: companion application deployed to `/opt/myapp`
  - Version: `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
- **Enterprise Scheduler registration**: node `redis-node` registered on a `daily` schedule via `schedulerctl`
- **Health check JSON**: `/var/lib/redis/health_check.json` — populated from HTTP GET to `http://localhost:8080/health`

## File Structure

```
../../site/role/manifests/redis_cluster.pp
../../site/profile/manifests/cache/redis.pp
../../site/profile/manifests/base/base.pp
../../site/modules/linux/profile_redis_cluster/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/install.pp
../../site/modules/linux/profile_redis_cluster/lib/puppet/type/myDeploy1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/type/mySecretType1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/type/myCronType1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/type/myFormatType1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/provider/myDeploy1/myDeployProvider.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/provider/mySecretType1/mySecretProvider1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/provider/myCronType1/myCronProvider1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/provider/myFormatType1/myFormatProvider1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/functions/myFunction1.rb
../../site/modules/linux/profile_redis_cluster/lib/puppet/functions/mySecretFunction1.rb
../../site/modules/linux/profile_redis_cluster/lib/facter/redis_role.rb
```

## Module Explanation

The module performs operations in this order:

1. **role::redis_cluster** (`../../site/role/manifests/redis_cluster.pp`):
   - Conditional `if $facts['kernel'].downcase == 'linux'` (evaluates `true` on Linux nodes): sets `Exec[default]` path to `/usr/bin:/bin:/usr/sbin:/sbin` for all `exec` resources in the catalog
   - `include ::profile::base::base` — included (not contained; runs independently)
   - `contain ::profile::cache::redis` — contained
   - Ordering: `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base profile completes before Redis profile starts

2. **profile::base::base** (`../../site/profile/manifests/base/base.pp`):
   - Class parameters resolved via Hiera `lookup()` (all default to `true` when no Hiera key is present):
     - `$manage_utils` = `true` (lookup `profile::base::manage_utils`, default `true`)
     - `$manage_ntp` = `true` (lookup `profile::base::manage_ntp`, default `true`)
     - `$manage_syslog` = `true` (lookup `profile::base::manage_syslog`, default `true`)
   - Conditional `if $manage_utils` → `true`: `include base_utils` — installs OS utility packages (exact list unknown)
   - Conditional `if $manage_ntp and $facts['kernel'] == 'Linux'` → `true` on Linux:
     - `package 'chrony'` → ensure: `installed`
     - `service 'chronyd'` → ensure: `running`, enable: `true`
   - Conditional `if $manage_syslog and $facts['kernel'] == 'Linux'` → `true` on Linux:
     - `package 'rsyslog'` → ensure: `installed`
     - `service 'rsyslog'` → ensure: `running`, enable: `true`

3. **profile::cache::redis** (`../../site/profile/manifests/cache/redis.pp`):
   - `$environment_name` = result of `fact('environment')` — resolves to the Puppet environment name at runtime (e.g., `production`, `staging`)
   - `class { 'profile_redis_cluster': }` — instantiates the main Redis cluster class with no parameter overrides (all defaults apply)

4. **profile_redis_cluster** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
   - Class parameters (all defaults, no Hiera overrides found for these keys):
     - `$redis_port` = `6379`
     - `$redis_password` = `'CHANGEME'` ⚠️ hardcoded plaintext credential
     - `$maxmemory_mb` = `2048`
     - `$maxmemory_policy` = `'allkeys-lru'`
   - PuppetDB query (compile-time): `$redis_nodes` = result of `puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }")` — returns list of all certnames that have the `profile_redis_cluster` class applied; used to discover cluster peers
   - Custom function call (compile-time): `$health_check` = `myFunction1('http://localhost:8080/health')` — performs HTTP GET, returns parsed JSON body or raw String on parse failure
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized `$health_check` response body
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider behavior: checks `/opt/myapp/version.txt` for `2.1.0`; if absent/mismatched: downloads tarball, extracts to `/opt/myapp`, writes `version.txt`
   - Custom function call (compile-time): `$service_token` = `mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary `CompanyInternal::SecretStore` ⚠️ NOT SAFELY CONVERTIBLE
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present`
     - Provider behavior: calls `schedulerctl register --schedule daily redis-node` if not already registered ⚠️ NOT SAFELY CONVERTIBLE
   - `contain profile_redis_cluster::install` — contained sub-class

5. **profile_redis_cluster::install** (`../../site/modules/linux/profile_redis_cluster/manifests/install.pp`):
   - `class { 'redis': }` (external/not-analyzed class) with parameters:
     - `bind` = `'0.0.0.0'`
     - `port` = `6379` (from `$profile_redis_cluster::redis_port`)
     - `requirepass` = `'CHANGEME'` (from `$profile_redis_cluster::redis_password`) ⚠️ hardcoded plaintext
     - `maxmemory` = `'2048mb'` (from `$profile_redis_cluster::maxmemory_mb`)
     - `appendonly` = `true`
     - `appendfsync` = `'everysec'`
     - `manage_package` = `true`
     - Installs the `redis` package and manages the `redis` service and its configuration file
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 class-level parameters for `profile_redis_cluster`, 3 for `profile::base::base`. No Hiera data files contain the target lookup keys for this module — all values resolve to manifest-level defaults. Two credentials are hardcoded in the manifest.

### Variable Definitions

**profile_redis_cluster class defaults (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`)** → Migration note: All values are manifest-level defaults; no Hiera overrides exist. Migrate to Ansible group/host vars or Ansible Vault as appropriate.
- `profile_redis_cluster::redis_port`: `6379` (type: integer)
- `profile_redis_cluster::redis_password`: `'CHANGEME'` (type: string) ⚠️ hardcoded plaintext — must be vaulted in Ansible Vault before deployment
- `profile_redis_cluster::maxmemory_mb`: `2048` (type: integer)
- `profile_redis_cluster::maxmemory_policy`: `'allkeys-lru'` (type: string)

**profile::base::base Hiera lookups (`../../site/profile/manifests/base/base.pp`)** → Migration note: All three keys are absent from every Hiera data file; values fall through to manifest defaults. Set explicitly in Ansible group vars to preserve intent.
- `profile::base::manage_ntp`: not set in any Hiera file → default `true` (type: boolean)
- `profile::base::manage_syslog`: not set in any Hiera file → default `true` (type: boolean)
- `profile::base::manage_utils`: not set in any Hiera file → default `true` (type: boolean)

**Runtime-resolved values** → Migration note: These are resolved at Puppet compile time via external calls; Ansible equivalents require task-level resolution.
- `profile::cache::redis::environment_name`: resolved at runtime via `fact('environment')` — value is the Puppet environment string (e.g., `production`)
- `profile_redis_cluster::redis_nodes`: resolved at runtime via PuppetDB query — list of certnames running `profile_redis_cluster`; replace with Ansible inventory group membership
- `profile_redis_cluster::health_check`: resolved at runtime via HTTP GET to `http://localhost:8080/health`; replace with `ansible.builtin.uri` task result
- `profile_redis_cluster::service_token`: resolved at runtime via `mySecretFunction1('redis_service_token')` ⚠️ opaque secrets backend — NOT SAFELY CONVERTIBLE without identifying the underlying secrets store

### Variable Migration Summary

- **Common defaults**: 4 variables (`redis_port`, `redis_password`, `maxmemory_mb`, `maxmemory_policy`) from manifest-level defaults (base configuration for all nodes)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables in Hiera eyaml for this module; however `redis_password` is a **hardcoded plaintext** credential that must be migrated to Ansible Vault

### Cross-Level Overrides

- No cross-level Hiera overrides exist for any `profile_redis_cluster::*` keys — all values come from manifest parameter defaults

### Merge Strategy Notes

- No Hiera merge strategies are in use for this module; all variables resolve via `first` (default) lookup or manifest defaults

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Parameters**: `name` (namevar), `command` (String, required non-empty), `hour` (String, default `'2'`), `minute` (String, default `'30'`)
- **Provider behavior**: shells out to `crontab -l` to read and `crontab -` to write; supports `exists?`, `create`, `destroy`
- **Usage in this module**: `myCronType1` is defined but **not instantiated** in the execution tree of `role::redis_cluster`

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Parameters**: `name` (namevar), `version` (String, required), `url` (String, must match `^https?://`), `install_dir` (String), `ensure` (present/absent, default present)
- **Provider behavior**: checks `{install_dir}/version.txt`; if missing or content ≠ `version`, downloads tarball from `url`, extracts to `install_dir`, writes `version.txt`; destroy removes directory and version file
- **Usage**: `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }`

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Parameters**: `entry` (namevar), `file` (String, default `/etc/company/app.conf`), `value` (String), `ensure` (present/absent)
- **Provider behavior**: manages `!key=value` entries in a proprietary CompanyApp settings file
- **Usage in this module**: `myFormatType1` is defined but **not instantiated** in the execution tree of `role::redis_cluster`

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Parameters**: `name` (namevar), `schedule` (String), `ensure` (present/absent, default present)
- **Provider behavior**: calls `schedulerctl query <name>` to check existence, `schedulerctl register --schedule <schedule> <name>` to create, `schedulerctl unregister <name>` to destroy
- **Usage**: `mySecretType1 { 'redis-node': schedule => 'daily' }`

## Dependencies

**External module dependencies**:
- `redis` class (not analyzed) — installs Redis package, manages Redis service and configuration; called from `profile_redis_cluster::install`
- `base_utils` class (not analyzed) — installs OS utility packages; called from `profile::base::base`

**System package dependencies**:
- `chrony` — NTP daemon package
- `rsyslog` — syslog daemon package
- `redis` — installed by the `redis` class (exact package name OS-dependent)

**Service dependencies**:
- `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base OS setup must complete before Redis cluster configuration

## Puppet Facts Used

- `$facts['kernel']` — used in `role::redis_cluster` to set default `Exec` path (Linux only) and in `profile::base::base` to gate NTP and syslog management; provides OS kernel name (e.g., `Linux`)
- `fact('environment')` — used in `profile::cache::redis` to capture the Puppet environment name at compile time (e.g., `production`, `staging`)
- `redis_role` (custom fact, `lib/facter/redis_role.rb`) — determines whether the node is a Redis `replica` or `primary` by checking for `/etc/redis/conf.d/replica.conf` and the presence of the string `replicaof` within it; confined to Linux only

## Custom Types Used

- `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`
- `mySecretType1 { 'redis-node': schedule => 'daily' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`

## Custom Providers Used

- `myDeployProvider` — implements `myDeploy1`; used via `myDeploy1 { 'myapp': ... }` in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`
- `mySecretProvider1` — implements `mySecretType1`; used via `mySecretType1 { 'redis-node': ... }` in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; fetches secret `redis_service_token` from proprietary `CompanyInternal::SecretStore`; result stored in `$service_token` (used implicitly, likely passed to `mySecretType1` or the `redis` class)

## Custom Component Conversion Decisions

### myCronType1 + myCronProvider1
- **Decision**: Existing Ansible modules
- **Mapping**: `ansible.builtin.cron` — maps `name` → `name`, `command` → `job`, `hour` → `hour`, `minute` → `minute`; `state: present/absent` replaces `ensure`; default `hour: 2`, `minute: 30` must be set explicitly if no override is provided
- **Note**: Not instantiated in this role's execution tree; include only if other roles using `myCronType1` are in scope

### myDeploy1 + myDeployProvider
- **Decision**: Existing Ansible modules (combination)
- **Mapping**:
  1. `ansible.builtin.stat` + `ansible.builtin.slurp` on `{{ install_dir }}/version.txt` to check current version (idempotency gate)
  2. `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to a temp path
  3. `ansible.builtin.file` → ensure `install_dir: /opt/myapp` exists (`state: directory`)
  4. `ansible.builtin.unarchive` → extract tarball to `/opt/myapp` with `remote_src: true`
  5. `ansible.builtin.copy` → write `2.1.0` to `/opt/myapp/version.txt`
  6. For `ensure: absent`: `ansible.builtin.file` with `state: absent` on `/opt/myapp` and `/opt/myapp/version.txt`

### myFormatType1 + myFormatProvider1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: Manages entries in a proprietary `!key=value` CompanyApp settings format. No Ansible built-in module (`ini_file`, `lineinfile`, `blockinfile`) natively understands or enforces the `!`-prefixed key syntax with its strict preservation rules for unrecognized `!`-lines. A **custom Ansible module** is required. The module must: read the file line by line; parse lines matching `!key=value`; for `state=present`, remove all lines matching the key and append `!entry=value`; for `state=absent`, remove all matching lines; preserve all comments, blanks, and unrecognized `!`-lines in original order; report `changed=true` only when content is actually modified; raise an error if the file path is not writable or the directory does not exist. Parameters: `file` (str, required), `entry` (str, required), `value` (str, required when state=present), `state` (str, default `present`).
- **Note**: Not instantiated in this role's execution tree; include only if other roles using `myFormatType1` are in scope

### mySecretType1 + mySecretProvider1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: Registers a server in a proprietary Enterprise Scheduler platform via `schedulerctl` CLI (`/usr/local/bin/schedulerctl`). The semantics of `schedulerctl query`, `schedulerctl register --schedule`, and `schedulerctl unregister` — including exit codes, output format, error conditions, and side effects — are undocumented and opaque. A custom Ansible module could only be written once the full `schedulerctl` CLI interface and/or the Enterprise Scheduler's REST API documentation are available. The automation developer must locate and review the `schedulerctl` documentation or source before attempting conversion.

### redis_role (custom fact)
- **Decision**: Existing Ansible modules
- **Mapping**: Reproduce in Ansible using:
  1. `ansible.builtin.stat` on `/etc/redis/conf.d/replica.conf` → register result
  2. `ansible.builtin.slurp` on the file (when it exists) → decode and search for `replicaof`
  3. Set `redis_role` as a host variable: `replica` if file exists and contains `replicaof`, otherwise `primary`
  - Alternatively, deploy a static fact script to `/etc/ansible/facts.d/redis_role.fact`; Ansible's `setup` module will expose it as `ansible_local.redis_role`

### myFunction1
- **Decision**: Existing Ansible modules
- **Mapping**: `ansible.builtin.uri` — `method: GET`, `url: http://localhost:8080/health`, `return_content: true`; parsed JSON is available via the `json` return key; raw body via `content`; non-2xx responses raise errors natively via `status_code` parameter

### mySecretFunction1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: Delegates entirely to `CompanyInternal::SecretStore.fetch` from the proprietary closed-source `company_internal_lib` Ruby library. The secrets backend, authentication mechanism, network dependencies, and error semantics are completely unknown. No Ansible lookup plugin (`community.hashi_vault.hashi_vault_kv2_get`, `amazon.aws.aws_secret`, etc.) can be assumed as a drop-in replacement without knowing what `company_internal_lib` actually connects to. The automation developer must identify the underlying secrets backend before any Ansible equivalent can be selected or written. The returned secret (`redis_service_token`) must never be logged or stored in plain text in Ansible vars/facts.

## PuppetDB Dependencies

- **Query in `profile_redis_cluster`** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Returns: list of all certnames that have the `profile_redis_cluster` class applied
  - Usage: result stored in `$redis_nodes` and used for cluster peer discovery
  - Migration note: PuppetDB queries have no direct Ansible equivalent. Replace with Ansible dynamic inventory groups (nodes in the `redis_cluster` group are the peers), `ansible.builtin.add_host` + group membership, or a static/dynamic inventory file listing all Redis cluster members. The `$redis_nodes` variable result should be replaced by `groups['redis_cluster']` in Ansible inventory.

- **Query in `profile_redis_cluster_case3`** (×2):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }`
  - Returns: same pattern for an alternate class variant
  - Usage: not in the primary execution tree of `role::redis_cluster` but present in the codebase
  - Migration note: Same replacement strategy as above; use a dedicated `redis_cluster_case3` inventory group if this variant is migrated.

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — must exist, owned `redis:redis`, mode `0644`, valid JSON content
- `/opt/myapp/version.txt` — must contain `2.1.0`
- `/opt/myapp/` — directory must exist with extracted artifact contents
- `/var/log/redis` — must be a directory, owned `redis:redis`, mode `0755`
- `/etc/redis/conf.d/replica.conf` — presence determines `redis_role` fact value

**Service endpoints to check**:
- Redis on port `6379`: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check endpoint: `curl http://localhost:8080/health` → should return valid JSON
- Enterprise Scheduler: `schedulerctl query redis-node` → should return registered status

**Templates rendered**: None — no ERB/EPP templates are used in this module; the only dynamic file content is `stdlib::to_json($health_check)` written inline to `/var/lib/redis/health_check.json`

## Pre-flight checks:
```bash
# Redis instance pre-flight
redis-cli -p 6379 -a CHANGEME ping
# Verify Redis service is running
systemctl status redis

# myapp artifact pre-flight
curl -I http://artifacts.internal/myapp-2.1.0.tar.gz
# Verify current deployed version
cat /opt/myapp/version.txt

# Enterprise Scheduler (redis-node) pre-flight
test -x /usr/local/bin/schedulerctl && echo "schedulerctl present" || echo "schedulerctl MISSING"
/usr/local/bin/schedulerctl query redis-node

# Health check endpoint pre-flight
curl -sf http://localhost:8080/health && echo "health endpoint OK" || echo "health endpoint UNREACHABLE"

# Secrets backend pre-flight
# Identify and verify the CompanyInternal::SecretStore backend is reachable
# and that the credential 'redis_service_token' exists before running migration tasks

# Credential rotation check
# Confirm redis_password has been rotated from 'CHANGEME' and stored in Ansible Vault
grep -r 'CHANGEME' /etc/redis/ && echo "WARNING: default password still in use" || echo "Password rotated"

# File and directory ownership checks
stat /var/lib/redis/health_check.json
stat /var/log/redis
stat /opt/myapp/

# NTP service pre-flight
systemctl status chronyd

# Syslog service pre-flight
systemctl status rsyslog
```