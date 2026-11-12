---
source-path: .
---

# Migration Plan: profile_redis_cluster_case2

**TLDR**: This Puppet module configures a Redis cluster node. It installs and configures Redis (bound to all interfaces, port 6379, with AOF persistence), creates a log directory, deploys a companion application artifact (`myapp` v2.1.0), registers the node with a proprietary Enterprise Scheduler via `schedulerctl`, fetches a health-check endpoint and writes the result to a JSON file, and retrieves a service token from an internal secret store. The module also performs a PuppetDB query to discover all nodes in the cluster. Two of its custom components (`mySecretType1`/`mySecretProvider1` and `mySecretFunction1`) are **not safely convertible** without additional documentation.

## Service Type and Instances

**Service Type**: In-memory Cache / Data Store (Redis Cluster Node)

**Configured Instances**:
- **redis** (single instance per node):
  - Bind address: `0.0.0.0` (all interfaces)
  - Port: `6379`
  - Auth password: `CHANGEME` (plain-text default — must be replaced)
  - Max memory: `2048mb`
  - Max memory policy: `allkeys-lru`
  - AOF persistence: enabled (`appendonly: true`, `appendfsync: everysec`)
  - Log directory: `/var/log/redis`

- **myapp** (companion application deployment):
  - Version: `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`

- **redis-node** (Enterprise Scheduler registration):
  - Schedule: `daily`
  - Managed via proprietary `schedulerctl` CLI — **not safely convertible**

## File Structure

```
profile_redis_cluster_case2/
├── manifests/
│   ├── init.pp
│   └── install.pp
└── lib/
    ├── facter/
    │   └── redis_role.rb
    └── puppet/
        ├── functions/
        │   ├── myFunction1.rb
        │   └── mySecretFunction1.rb
        ├── type/
        │   ├── myDeploy1.rb
        │   └── mySecretType1.rb
        └── provider/
            ├── myDeploy1/
            │   └── myDeployProvider.rb
            └── mySecretType1/
                └── mySecretProvider1.rb
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case2** (`manifests/init.pp`):
   - Class parameters (resolved defaults, no Hiera overrides found):
     - `$redis_port` = `6379`
     - `$redis_password` = `'CHANGEME'` ⚠️ plain-text, no encryption
     - `$maxmemory_mb` = `2048`
     - `$maxmemory_policy` = `'allkeys-lru'`
   - **PuppetDB query**: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }")` — collects the list of all certnames that have this class applied; result is used implicitly (cluster membership awareness)
   - **Custom function call**: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body (or raw string on parse failure)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `myFunction1` call above
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider logic: checks `/opt/myapp/version.txt` for `2.1.0`; if absent/mismatch → creates `/opt/myapp`, downloads `http://artifacts.internal/myapp-2.1.0.tar.gz`, extracts with `tar -xzf`, writes `/opt/myapp/version.txt` containing `2.1.0`; destroy path removes `/opt/myapp` recursively
   - **Custom function call**: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary `CompanyInternal::SecretStore` ⚠️ **not safely convertible**
   - `mySecretType1 'redis-node'` → schedule: `daily`, ensure: `present`
     - Provider logic: calls `schedulerctl query redis-node`; if not found → calls `schedulerctl register redis-node --schedule daily`; destroy path calls `schedulerctl unregister redis-node` ⚠️ **not safely convertible**
   - `contain profile_redis_cluster_case2::install` — contained subclass (ordering enforced)

2. **profile_redis_cluster_case2::install** (`manifests/install.pp`):
   - `class 'redis'` (external, not analyzed) → configured with:
     - `bind`: `0.0.0.0`
     - `port`: `6379`
     - `requirepass`: `CHANGEME`
     - `maxmemory`: `2048mb`
     - `appendonly`: `true`
     - `appendfsync`: `everysec`
     - `manage_package`: `true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 class parameters, no Hiera data files found (all values are manifest-level defaults).

### Variable Definitions

**Class parameter defaults (`manifests/init.pp`)** → Migration note: All values are manifest-level defaults; no Hiera hierarchy is present. Migrate to Ansible group/host vars or Ansible Vault as appropriate.
- `profile_redis_cluster_case2::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case2::redis_password`: `'CHANGEME'` (type: String) ⚠️ plain-text credential — must be migrated to Ansible Vault or an external secrets manager
- `profile_redis_cluster_case2::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster_case2::maxmemory_policy`: `'allkeys-lru'` (type: String)

### Variable Migration Summary

- **Common defaults**: 4 variables (all from manifest-level parameter defaults)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables (the Redis password is stored as plain-text `'CHANGEME'` — must be migrated to Ansible Vault or an external secrets manager before running)

### Cross-Level Overrides

No cross-level overrides — no Hiera data files are present. All values come from manifest-level parameter defaults.

### Merge Strategy Notes

- No Hiera merge strategies apply — no Hiera hierarchy is present in this module.

## Custom Types and Providers

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Used at**: `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }` in `manifests/init.pp`
- **Parameters**: name (`myapp`), version (`2.1.0`), url (`http://artifacts.internal/myapp-2.1.0.tar.gz`), install_dir (`/opt/myapp`), ensure (`present`)

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Used at**: `mySecretType1 { 'redis-node': schedule => 'daily' }` in `manifests/init.pp`
- **Parameters**: name (`redis-node`), schedule (`daily`), ensure (`present`)

## Dependencies

**External module dependencies**: None (no Puppetfile found). The `redis` class referenced in `manifests/install.pp` is an unanalyzed external dependency — likely `puppet/redis` from the Puppet Forge.

**System package dependencies**: Redis server package (managed by the `redis` class with `manage_package: true`). The `schedulerctl` binary is expected at `/usr/local/bin/schedulerctl` on the target host.

**Service dependencies**: Redis service (managed by the `redis` class). No explicit `->` or `~>` ordering arrows are declared between top-level resources in `manifests/init.pp` and the contained `install` class — Puppet's default unordered evaluation applies except where `contain` enforces class boundary.

## Puppet Facts Used

- **`$facts['kernel']`** (via `lib/facter/redis_role.rb`): Confines the `redis_role` custom fact to Linux hosts only. The fact itself returns `'primary'` or `'replica'` based on the presence and content of `/etc/redis/conf.d/replica.conf`.

## Custom Types Used

- **`myDeploy1`** — declared in `lib/puppet/type/myDeploy1.rb`; instantiated in `manifests/init.pp` with: name=`myapp`, version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`
- **`mySecretType1`** — declared in `lib/puppet/type/mySecretType1.rb`; instantiated in `manifests/init.pp` with: name=`redis-node`, schedule=`daily`

## Custom Providers Used

- **`myDeployProvider`** — implements `myDeploy1`; file: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`; used via the `myDeploy1 { 'myapp': ... }` resource in `manifests/init.pp`
- **`mySecretProvider1`** — implements `mySecretType1`; file: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`; used via the `mySecretType1 { 'redis-node': ... }` resource in `manifests/init.pp`

## Custom Functions Used

- **`myFunction1('http://localhost:8080/health')`** — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- **`mySecretFunction1('redis_service_token')`** — called in `manifests/init.pp`; fetches secret `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token` (usage of `$service_token` beyond assignment is not visible in the analyzed tree)

## Custom Component Conversion Decisions

### myDeploy1 (type) + myDeployProvider (provider)
- **Decision**: Existing Ansible modules — no custom module required.
- **Suggested mapping**:
  - `ansible.builtin.stat` on `/opt/myapp/version.txt` → register result
  - `ansible.builtin.slurp` on `/opt/myapp/version.txt` → read current version
  - `ansible.builtin.file` with `state: directory` → create `/opt/myapp`
  - `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to a temp path
  - `ansible.builtin.unarchive` with `remote_src: yes` → extract into `/opt/myapp`
  - `ansible.builtin.copy` with `content: "2.1.0"` → write `/opt/myapp/version.txt`
  - All download/extract/write tasks guarded by `when: current_version != '2.1.0'` for idempotency
  - Destroy path: `ansible.builtin.file` with `state: absent` on `/opt/myapp`

### mySecretType1 (type) + mySecretProvider1 (provider)
- **Decision**: ⚠️ NOT SAFELY CONVERTIBLE — flagged for developer review.
- **Reason**: The provider wraps the proprietary `schedulerctl` CLI (`/usr/local/bin/schedulerctl`) with `query`, `register`, and `unregister` subcommands. The CLI's expected output format, exit codes, `--schedule` flag semantics, and side effects are entirely undocumented. Without this information it is impossible to write idempotent `ansible.builtin.command` tasks or a custom Ansible module that faithfully reproduces the behavior. **The automation developer must obtain `schedulerctl` documentation or source code before attempting conversion.**

### redis_role (custom fact)
- **Decision**: Existing Ansible modules — no custom module required.
- **Suggested mapping**:
  - `ansible.builtin.stat` on `/etc/redis/conf.d/replica.conf` → register `replica_conf_stat`
  - `ansible.builtin.slurp` on `/etc/redis/conf.d/replica.conf` (when `replica_conf_stat.stat.exists`) → register `replica_conf_content`
  - `ansible.builtin.set_fact` → `redis_role: "{{ 'replica' if replica_conf_stat.stat.exists and 'replicaof' in (replica_conf_content.content | b64decode) else 'primary' }}"`
  - Alternatively, deploy a script to `/etc/ansible/facts.d/redis_role.fact` to surface as `ansible_local.redis_role`
  - Guard with `when: ansible_system == 'Linux'`

### myFunction1 (custom function)
- **Decision**: Existing Ansible modules — no custom module required.
- **Suggested mapping**:
  - `ansible.builtin.uri` with `url: 'http://localhost:8080/health'`, `method: GET`, `return_content: yes`
  - Parsed JSON is available via the `json` return key; raw body via `content`
  - Non-2xx responses raise an error automatically (controlled by `status_code` parameter)
  - Register result and use `result.json` wherever `$health_check` is consumed

### mySecretFunction1 (custom function)
- **Decision**: ⚠️ NOT SAFELY CONVERTIBLE — flagged for developer review.
- **Reason**: The function delegates to `CompanyInternal::SecretStore.fetch` from the proprietary `company_internal_lib` Ruby gem. The secret store's backend (Vault, database, internal API, file, etc.), authentication mechanism, and API contract are entirely opaque. No Ansible lookup plugin (`community.hashi_vault`, `amazon.aws.aws_secret`, etc.) can be safely proposed without knowing what system backs this store. **The automation developer must identify the secret store backend and its authentication method before a conversion can be attempted.**

## PuppetDB Dependencies

- **Query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }` — called in `manifests/init.pp`, result stored in `$redis_nodes`
- **Purpose**: Discovers all cluster member hostnames that have this profile applied. The result is used for cluster membership awareness (exact downstream usage of `$redis_nodes` is not visible in the analyzed tree beyond the assignment).
- **Migration note**: PuppetDB queries have no direct Ansible equivalent. The recommended approach is to use an Ansible **dynamic inventory** or an **inventory group** (`redis_cluster`) that enumerates all Redis nodes. Within a play, `groups['redis_cluster']` provides the equivalent list of hostnames. If runtime discovery is required, `ansible.builtin.add_host` combined with a pre-play fact-gathering step can approximate the behavior.

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned by `redis:redis`, mode `0644`, contains valid JSON from health endpoint
- `/var/log/redis` — exists as directory, owned by `redis:redis`, mode `0755`
- `/opt/myapp/version.txt` — exists, contains `2.1.0`
- `/opt/myapp` — directory exists, application artifact extracted

**Service endpoints to check**:
- Redis on port `6379`: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health endpoint: `curl -s http://localhost:8080/health` → should return valid JSON

**Templates rendered**: None — this module uses no ERB/EPP templates. The only dynamic file content is the JSON-serialized health check result written inline via `content => stdlib::to_json($health_check)`.

## Pre-flight checks:
```bash
# --- redis instance ---
# Verify Redis service is running after play
redis-cli -p 6379 -a CHANGEME ping
# Verify Redis log directory
stat /var/log/redis

# --- myapp instance ---
# Verify artifact URL is reachable from the target host
curl -sI http://artifacts.internal/myapp-2.1.0.tar.gz
# Verify installed version
cat /opt/myapp/version.txt

# --- redis-node (Enterprise Scheduler) instance ---
# Verify schedulerctl binary exists and is executable
test -x /usr/local/bin/schedulerctl && echo "schedulerctl present" || echo "MISSING"
# Verify node registration (once schedulerctl docs are obtained)
# /usr/local/bin/schedulerctl query redis-node

# --- Health check endpoint ---
# Verify health endpoint is reachable at play time
curl -s http://localhost:8080/health

# --- Credential pre-flight ---
# Confirm redis_password has been replaced with a real credential in Ansible Vault
# (default 'CHANGEME' must NOT be used in production)

# --- Secret store pre-flight ---
# Confirm the backend for mySecretFunction1('redis_service_token') has been identified
# and the redis_service_token value is available via the chosen Ansible lookup plugin
```