---
source-path: .
---

# Migration Plan: profile_redis_cluster (role::redis_cluster)

**TLDR**: This module provisions a Redis cluster node on Linux. It applies a base OS profile (NTP via chrony, syslog via rsyslog, and optional utility packages), then installs and configures a Redis instance via the `profile_redis_cluster` module. The Redis setup includes: installing the Redis package with a bound address, password, memory policy, and append-only persistence; creating a log directory; writing a health-check JSON file populated by an HTTP call; deploying a companion application artifact (`myapp` v2.1.0); and registering the node with a proprietary Enterprise Scheduler. Two custom functions are called — one for HTTP health-check data and one to retrieve a service token from a closed-source internal secret store. The `redis_password` defaults to the insecure plaintext value `CHANGEME` with no Hiera override detected in any environment.

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **Redis node** (single instance per host):
  - Port: `6379`
  - Bind address: `0.0.0.0`
  - Password: `CHANGEME` (plaintext default — no Hiera override detected) ⚠️
  - Max memory: `2048mb`
  - Max memory policy: `allkeys-lru`
  - Append-only persistence: `true`, fsync: `everysec`
  - Log directory: `/var/log/redis`

- **myapp companion deployment**:
  - Version: `2.1.0`
  - Install directory: `/opt/myapp`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`

- **Enterprise Scheduler registration**:
  - Name: `redis-node`
  - Schedule: `daily`

## File Structure

```
../../site/role/manifests/redis_cluster.pp
../../site/profile/manifests/cache/redis.pp
../../site/profile/manifests/base/base.pp
../../site/modules/linux/profile_redis_cluster/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/install.pp
lib/puppet/type/myDeploy1.rb
lib/puppet/type/mySecretType1.rb
lib/puppet/provider/myDeploy1/myDeployProvider.rb
lib/puppet/provider/mySecretType1/mySecretProvider1.rb
lib/facter/redis_role.rb
lib/puppet/functions/myFunction1.rb
lib/puppet/functions/mySecretFunction1.rb
../../data/common.yaml
../../data/environment/production.yaml
../../data/environment/staging.yaml
```

## Module Explanation

The module performs operations in this order:

**IMPORTANT: Full paths from the File Structure section are used throughout.**

1. **role::redis_cluster** (`../../site/role/manifests/redis_cluster.pp`):
   - Conditional `if $facts['kernel'].downcase == 'linux'` (evaluates `true` on Linux targets):
     - `Exec[default]` → sets default `path` attribute to `/usr/bin:/bin:/usr/sbin:/sbin` for all `exec` resources in the catalog
   - `include ::profile::base::base` — included (not contained; runs independently)
   - `contain ::profile::cache::redis` — contained
   - Ordering: `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base profile completes before Redis profile begins

2. **profile::base::base** (`../../site/profile/manifests/base/base.pp`):
   - Parameters resolved (all fall through to manifest defaults; no Hiera overrides found):
     - `$manage_ntp` → `true`
     - `$manage_syslog` → `true`
     - `$manage_utils` → `true`
   - Conditional `if $manage_utils` (true):
     - `include base_utils` — class not analyzed; installs OS utility packages (exact list unknown)
   - Conditional `if $manage_ntp and $facts['kernel'] == 'Linux'` (true on Linux):
     - `package 'chrony'` → ensure: `installed`
     - `service 'chronyd'` → ensure: `running`, enable: `true`
   - Conditional `if $manage_syslog and $facts['kernel'] == 'Linux'` (true on Linux):
     - `package 'rsyslog'` → ensure: `installed`
     - `service 'rsyslog'` → ensure: `running`, enable: `true`

3. **profile::cache::redis** (`../../site/profile/manifests/cache/redis.pp`):
   - Parameters:
     - `$environment_name` → resolved at runtime via `fact('environment')` (e.g., `production` or `staging`)
   - `class { 'profile_redis_cluster': }` — instantiates the module with all defaults (no parameter overrides passed)
   - Walks into `profile_redis_cluster` — see step 4 below

4. **profile_redis_cluster** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
   - Parameters resolved (all manifest defaults; no Hiera overrides):
     - `$redis_port` → `6379`
     - `$redis_password` → `'CHANGEME'` ⚠️ insecure plaintext default
     - `$maxmemory_mb` → `2048`
     - `$maxmemory_policy` → `'allkeys-lru'`
   - PuppetDB query (executed at catalog compile time):
     - `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }")` — returns all certnames with the `profile_redis_cluster` class applied; used to discover all Redis cluster members
   - Custom function call:
     - `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET, returns parsed JSON body (or raw string if JSON parse fails)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: `stdlib::to_json($health_check)`
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider behavior: checks `/opt/myapp/version.txt` for idempotency; if absent or version mismatch — creates `/opt/myapp`, downloads `artifact.tar.gz` from URL, extracts archive, writes `2.1.0` to `/opt/myapp/version.txt`
   - Custom function call:
     - `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from `CompanyInternal::SecretStore` ⚠️ NOT SAFELY CONVERTIBLE
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present`
     - Provider behavior: calls `/usr/local/bin/schedulerctl query redis-node`; if not registered — calls `/usr/local/bin/schedulerctl register redis-node --schedule daily` ⚠️ NOT SAFELY CONVERTIBLE
   - `contain profile_redis_cluster::install` — contained subclass; see step 5

5. **profile_redis_cluster::install** (`../../site/modules/linux/profile_redis_cluster/manifests/install.pp`):
   - `class { 'redis': }` — external Redis class (source unresolved; assumed `puppet-redis` from Forge):
     - bind: `0.0.0.0`
     - port: `6379` (from `$profile_redis_cluster::redis_port`)
     - requirepass: `'CHANGEME'` (from `$profile_redis_cluster::redis_password`) ⚠️
     - maxmemory: `'2048mb'` (from `"${profile_redis_cluster::maxmemory_mb}mb"`)
     - appendonly: `true`
     - appendfsync: `'everysec'`
     - manage_package: `true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 8 variables referenced across manifests; 0 defined in any Hiera data file. All values resolve from manifest-level parameter defaults.

### Variable Definitions

**Manifest defaults (all environments — no Hiera overrides)**
- `profile_redis_cluster::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster::redis_password`: `'CHANGEME'` (type: String) ⚠️ insecure plaintext
- `profile_redis_cluster::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster::maxmemory_policy`: `'allkeys-lru'` (type: String)
- `profile::base::manage_ntp`: `true` (type: Boolean, Hiera lookup key: `profile::base::manage_ntp`, falls back to default)
- `profile::base::manage_syslog`: `true` (type: Boolean, Hiera lookup key: `profile::base::manage_syslog`, falls back to default)
- `profile::base::manage_utils`: `true` (type: Boolean, Hiera lookup key: `profile::base::manage_utils`, falls back to default)
- `profile::cache::redis::environment_name`: resolved at runtime via `fact('environment')` (type: Optional[String])

### Variable Migration Summary

- **Common defaults**: 0 variables (no Hiera data found; `common.yaml` contains no relevant keys)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (`production.yaml` and `staging.yaml` both empty for these keys)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables (no eyaml found)
- **Manifest defaults active in all environments**: 8 variables

### Cross-Level Overrides

No cross-level overrides detected. All variables resolve from manifest defaults only.

### Merge Strategy Notes

- No Hiera merge strategies are in use; all values are manifest-level defaults resolved via `first` (default) lookup behavior.

## Custom Types and Providers

### myDeploy1 (type + provider)
- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Used at**: `../../site/modules/linux/profile_redis_cluster/manifests/init.pp` — `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }`
- **Behavior**: idempotency via `/opt/myapp/version.txt`; creates directory, downloads tarball, extracts, writes version file; destroy removes `/opt/myapp`

### mySecretType1 (type + provider)
- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Used at**: `../../site/modules/linux/profile_redis_cluster/manifests/init.pp` — `mySecretType1 { 'redis-node': schedule => 'daily' }`
- **Behavior**: registers/unregisters a server in a proprietary Enterprise Scheduler via `/usr/local/bin/schedulerctl`; subcommands: `query`, `register`, `unregister`; `--schedule` parameter format undocumented ⚠️ NOT SAFELY CONVERTIBLE

## Dependencies

**External module dependencies**: None (no Puppetfile found)

**Internal module dependencies**:
- `redis` class — called inside `../../site/modules/linux/profile_redis_cluster/manifests/install.pp`; source not present in the analyzed tree; assumed to be a standard Redis Puppet module (e.g., `puppet-redis` from Forge)
- `base_utils` class — called inside `../../site/profile/manifests/base/base.pp`; source not analyzed

**System package dependencies**:
- `chrony` — NTP daemon
- `rsyslog` — syslog daemon
- Redis package (managed by the `redis` class with `manage_package => true`)
- `schedulerctl` binary expected at `/usr/local/bin/schedulerctl` (proprietary)

**Service dependencies** (ordering):
- `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base OS setup must complete before Redis is configured

## Puppet Facts Used

- `$facts['kernel']` — used in `../../site/role/manifests/redis_cluster.pp` to set default `Exec` path and in `../../site/profile/manifests/base/base.pp` to gate NTP and syslog management; value `'Linux'` on Linux hosts
- `fact('environment')` — used in `../../site/profile/manifests/cache/redis.pp` to populate `$environment_name`; returns the Puppet environment name (e.g., `production`, `staging`)
- `redis_role` (custom fact, `lib/facter/redis_role.rb`) — returns `'primary'` or `'replica'` based on presence and content of `/etc/redis/conf.d/replica.conf`; confined to Linux kernel; not directly referenced in the analyzed execution tree but deployed with the module

## Custom Types Used

- **`myDeploy1`** — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp` with: name=`myapp`, version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`
- **`mySecretType1`** — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp` with: name=`redis-node`, schedule=`daily`

## Custom Providers Used

- **`myDeployProvider`** — implements `myDeploy1` type; handles exists?/create/destroy lifecycle for artifact deployment; used via the `myDeploy1 { 'myapp': }` resource in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`
- **`mySecretProvider1`** — implements `mySecretType1` type; wraps `/usr/local/bin/schedulerctl` CLI; used via the `mySecretType1 { 'redis-node': }` resource in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`

## Custom Functions Used

- **`myFunction1('http://localhost:8080/health')`** — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result serialized to `/var/lib/redis/health_check.json`
- **`mySecretFunction1('redis_service_token')`** — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; fetches secret from `CompanyInternal::SecretStore`; result stored in `$service_token` (usage of `$service_token` beyond assignment is not visible in the analyzed tree — may be passed to `mySecretType1` implicitly or used in an unanalyzed resource) ⚠️ NOT SAFELY CONVERTIBLE

## Custom Component Conversion Decisions

### myDeploy1 type + myDeployProvider provider
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping**:
  - Idempotency check: `ansible.builtin.stat` on `/opt/myapp/version.txt` + `ansible.builtin.slurp` to read and compare content against `2.1.0`
  - Create directory: `ansible.builtin.file` with `state: directory`, path: `/opt/myapp`
  - Download artifact: `ansible.builtin.get_url` with `url: http://artifacts.internal/myapp-2.1.0.tar.gz`, `dest: /opt/myapp/artifact.tar.gz`
  - Extract archive: `ansible.builtin.unarchive` with `src: /opt/myapp/artifact.tar.gz`, `dest: /opt/myapp`, `remote_src: true`
  - Write version file: `ansible.builtin.copy` with `content: "2.1.0"`, `dest: /opt/myapp/version.txt`
  - Destroy (ensure absent): `ansible.builtin.file` with `state: absent`, `path: /opt/myapp`
  - Gate all create steps with `when: version_file.stat.exists == false or current_version != '2.1.0'`

### mySecretType1 type + mySecretProvider1 provider
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The provider wraps `/usr/local/bin/schedulerctl`, a proprietary CLI tool for an undocumented Enterprise Scheduler platform. The subcommands (`query`, `register`, `unregister`) and `--schedule` parameter format are not documented in the source. There is no known Ansible module or Galaxy collection for this platform. The automation developer must obtain `schedulerctl` documentation or the binary's help output to determine whether an `ansible.builtin.command`/`ansible.builtin.shell` task set or a custom Ansible module can safely replicate the `query`/`register`/`unregister` lifecycle with correct idempotency and error handling.

### redis_role custom fact
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping**:
  - `ansible.builtin.stat` on `/etc/redis/conf.d/replica.conf` → register `replica_conf`
  - `ansible.builtin.command: grep -q replicaof /etc/redis/conf.d/replica.conf` (when file exists) → register `grep_result`, `ignore_errors: true`
  - `ansible.builtin.set_fact: redis_role: "{{ 'replica' if (replica_conf.stat.exists and grep_result.rc == 0) else 'primary' }}"`
  - Alternatively, deploy a script to `/etc/ansible/facts.d/redis_role.fact` to surface as `ansible_local.redis_role`

### myFunction1 custom function
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping**: `ansible.builtin.uri` with `method: GET`, `url: http://localhost:8080/health`, `return_content: true`; parsed JSON available via `result.json`; non-2xx responses raise errors natively via `status_code` validation; raw body available via `result.content`

### mySecretFunction1 custom function
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The function calls `CompanyInternal::SecretStore.fetch('redis_service_token')` from a closed-source proprietary Ruby library (`company_internal_lib`). The underlying secret backend (e.g., HashiCorp Vault, CyberArk, an internal database) is entirely unknown. Without identifying the backend, it is impossible to select the correct Ansible lookup plugin or secrets module. The automation developer must:
  1. Identify what secret backend `company_internal_lib` wraps
  2. Replace with the appropriate mechanism — e.g., `community.hashi_vault.hashi_vault` lookup, `azure_keyvault`, `ansible.builtin.env` for env-injected secrets, or a custom lookup plugin
  3. Apply `no_log: true` to any task that handles the resolved secret value to prevent exposure in logs

## Template Conversion Notes

No ERB templates are used in this module. The only dynamic file content is:
- `/var/lib/redis/health_check.json` — content generated inline via `stdlib::to_json($health_check)` where `$health_check` is the return value of `myFunction1('http://localhost:8080/health')`. In Ansible, use `ansible.builtin.uri` to fetch the health endpoint, then `ansible.builtin.copy` with `content: "{{ health_check_result.json | to_json }}"` to write the file.

## PuppetDB Dependencies

**Context**: PuppetDB is used in this module for cluster topology discovery at catalog compile time. All queries identify Redis cluster members by class membership.

- **PuppetDB Query 1** (in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`, active in execution tree):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Returns: all certnames (hostnames) that have the `profile_redis_cluster` class applied
  - Used as: `$redis_nodes` — the list of all Redis cluster members for cluster topology population
  - Migration note: No direct Ansible equivalent. Replace with a static inventory group (e.g., `[redis_cluster]`), a dynamic inventory plugin grouped by role, an `add_host` task in a pre-play discovery step, or explicit group variables. The Ansible equivalent of `$redis_nodes` is `groups['redis_cluster']`.

- **PuppetDB Query 2** (in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`, second reference):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Same query as Query 1; used in a different context, likely for generating a cluster peers list for configuration rendering
  - Migration note: Same replacement strategy as Query 1 applies.

- **PuppetDB Query 3** (in `profile_redis_cluster_case2` — alternate class, not in active execution tree):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }`
  - Returns: certnames running the case2 variant of the Redis cluster profile
  - Migration note: Not in the active execution path for this role. If the case2 variant is migrated separately, apply the same inventory-group replacement strategy.

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned by `redis:redis`, mode `0644`, valid JSON content
- `/var/log/redis` — exists as directory, owned by `redis:redis`, mode `0755`
- `/opt/myapp/version.txt` — exists, contains `2.1.0`
- `/opt/myapp/` — directory exists with extracted artifact contents
- `/etc/redis/conf.d/replica.conf` — presence determines `redis_role` fact value

**Service endpoints to check**:
- Redis on port `6379`: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health endpoint: `curl http://localhost:8080/health` → should return JSON (used to populate `health_check.json`)

**Templates rendered**: None (no ERB templates in this module)

## Pre-flight checks:
```bash
# Redis instance
systemctl status redis || systemctl status redis-server

# Redis connectivity and replication role
redis-cli -p 6379 -a CHANGEME ping
redis-cli -p 6379 -a CHANGEME info replication

# NTP daemon (chrony)
systemctl status chronyd

# Syslog daemon (rsyslog)
systemctl status rsyslog

# myapp companion deployment
cat /opt/myapp/version.txt
# Expected output: 2.1.0
ls /opt/myapp/

# Health check endpoint (used to populate health_check.json)
curl -sf http://localhost:8080/health

# Health check JSON file
test -f /var/lib/redis/health_check.json && python3 -m json.tool /var/lib/redis/health_check.json

# Redis log directory
ls -ld /var/log/redis
# Expected: drwxr-xr-x redis redis

# Enterprise Scheduler CLI presence (required before mySecretType1 equivalent tasks)
test -f /usr/local/bin/schedulerctl && echo "schedulerctl present" || echo "WARNING: schedulerctl missing"

# Enterprise Scheduler registration status
/usr/local/bin/schedulerctl query redis-node

# Redis role fact (primary vs replica)
test -f /etc/redis/conf.d/replica.conf && echo "replica config present" || echo "no replica config — node is primary"

# SECURITY WARNING: Replace CHANGEME password before any production deployment.
# No Hiera override is currently active in any environment.
```