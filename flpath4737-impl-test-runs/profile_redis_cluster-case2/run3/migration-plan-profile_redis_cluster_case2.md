---
source-path: .
---

# Migration Plan: profile_redis_cluster_case2

**TLDR**: This Puppet module configures a Redis cluster node. It installs and configures Redis via an external `redis` class (bind `0.0.0.0`, port `6379`, password-protected, `2048mb` maxmemory with `allkeys-lru` eviction, append-only persistence), creates a log directory, deploys a companion application artifact (`myapp` v2.1.0) to `/opt/myapp`, registers the node in a proprietary Enterprise Scheduler platform, fetches a health-check JSON payload from a local HTTP endpoint and writes it to disk, and queries PuppetDB to discover all peer nodes running this profile. Two custom components (`mySecretType1` and `mySecretFunction1`) are **not safely convertible** due to proprietary/opaque backends and require developer investigation before migration can proceed.

## Service Type and Instances

**Service Type**: Cache / In-Memory Data Store (Redis cluster node)

**Configured Instances**:
- **Redis node**:
  - Bind: `0.0.0.0` (all interfaces)
  - Port: `6379`
  - Authentication password: `CHANGEME` (plaintext placeholder — **must be vault-encrypted**)
  - Max memory: `2048mb`
  - Eviction policy: `allkeys-lru`
  - Persistence: append-only (`appendonly: true`, `appendfsync: everysec`)
  - Log directory: `/var/log/redis`

- **myapp deployment**:
  - Version: `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`
  - Idempotency sentinel: `/opt/myapp/version.txt`

- **Enterprise Scheduler registration**:
  - Name: `redis-node`
  - Schedule: `daily`
  - Tool: `schedulerctl` at `/usr/local/bin/schedulerctl` (**NOT SAFELY CONVERTIBLE**)

- **Health check file**:
  - Source: HTTP GET `http://localhost:8080/health` (JSON response)
  - Destination: `/var/lib/redis/health_check.json`
  - Owner: `redis:redis`, mode: `0644`

## File Structure

```
profile_redis_cluster_case2/
├── data/
│   ├── common.yaml
│   └── environment/
│       ├── production.yaml
│       └── staging.yaml
├── lib/
│   ├── facter/
│   │   └── redis_role.rb
│   └── puppet/
│       ├── functions/
│       │   ├── myFunction1.rb
│       │   └── mySecretFunction1.rb
│       ├── provider/
│       │   ├── myDeploy1/
│       │   │   └── myDeployProvider.rb
│       │   └── mySecretType1/
│       │       └── mySecretProvider1.rb
│       └── type/
│           ├── myDeploy1.rb
│           └── mySecretType1.rb
└── manifests/
    ├── init.pp
    └── install.pp
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case2** (`manifests/init.pp`):
   - Class parameters (all resolved from manifest defaults; Hiera data files contain the same keys but no override values are set):
     - `redis_port` = `6379`
     - `redis_password` = `'CHANGEME'` (**plaintext — must be replaced with vault-encrypted value**)
     - `maxmemory_mb` = `2048`
     - `maxmemory_policy` = `'allkeys-lru'`
   - **PuppetDB query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }` — collects all certnames of nodes in the cluster into `$redis_nodes` for peer discovery (see PuppetDB Dependencies section)
   - **Custom function call**: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body as a Hash/Array (or raw String if JSON parse fails)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `myFunction1('http://localhost:8080/health')`
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider behavior: checks `/opt/myapp/version.txt`; if it contains `2.1.0`, skips deployment (idempotent); otherwise downloads `http://artifacts.internal/myapp-2.1.0.tar.gz` as `artifact.tar.gz`, extracts into `/opt/myapp`, writes `2.1.0` to `/opt/myapp/version.txt`
     - On `ensure: absent`: removes `/opt/myapp` directory recursively
   - **Custom function call**: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from `CompanyInternal::SecretStore` (**NOT SAFELY CONVERTIBLE** — see Custom Component Conversion Decisions)
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present`
     - Provider behavior: calls `/usr/local/bin/schedulerctl query redis-node`; if not registered, calls `/usr/local/bin/schedulerctl register redis-node --schedule daily`; on `ensure: absent`, calls `/usr/local/bin/schedulerctl unregister redis-node` (**NOT SAFELY CONVERTIBLE** — see Custom Component Conversion Decisions)
   - `contain profile_redis_cluster_case2::install` — contained subclass (ordering guaranteed)

2. **profile_redis_cluster_case2::install** (`manifests/install.pp`):
   - `class 'redis'` (external class, not analyzed) → parameters passed:
     - `bind`: `'0.0.0.0'`
     - `port`: `6379`
     - `requirepass`: `'CHANGEME'` (**plaintext placeholder**)
     - `maxmemory`: `'2048mb'`
     - `appendonly`: `true`
     - `appendfsync`: `'everysec'`
     - `manage_package`: `true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 variables across 1 Hiera level (module `data/common.yaml`). No environment-level overrides exist. All effective values come from manifest-level class parameter defaults.

### Variable Definitions

**data/common.yaml (module defaults — no override values set; manifest defaults are authoritative)** → Migration note: Base defaults for all nodes; all four keys are present but carry no values that differ from manifest defaults
- `profile_redis_cluster_case2::redis_port`: `6379` (type: integer)
- `profile_redis_cluster_case2::redis_password`: `'CHANGEME'` (type: string — **plaintext, insecure**)
- `profile_redis_cluster_case2::maxmemory_mb`: `2048` (type: integer)
- `profile_redis_cluster_case2::maxmemory_policy`: `'allkeys-lru'` (type: string)

**data/environment/production.yaml** → Migration note: No keys from this module present; no overrides

**data/environment/staging.yaml** → Migration note: No keys from this module present; no overrides

### Variable Migration Summary

- **Common defaults**: 4 variables (all resolved from manifest defaults)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (no overrides in production or staging)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable requiring secure storage (`redis_password` — currently plaintext `'CHANGEME'`)

### Cross-Level Overrides

No cross-level overrides exist. All four parameters are defined only at the manifest default level. The Hiera keys in `data/common.yaml` are present but carry no override values that differ from the manifest defaults.

### Merge Strategy Notes

- All four variables use `first` (default) merge strategy — first value found wins, no merging across levels

## Custom Types and Providers

### myDeploy1 (type + provider)

**Type file**: `lib/puppet/type/myDeploy1.rb`
**Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`

**Parameters**:
- `name` (String, namevar): application name — `'myapp'`
- `version` (String, required, non-empty): desired version — `'2.1.0'`
- `url` (String, must match `^https?://`): artifact download URL — `'http://artifacts.internal/myapp-2.1.0.tar.gz'`
- `install_dir` (String): installation directory — `'/opt/myapp'`
- `ensure` (Enum[present, absent], default: `present`)

**Provider lifecycle**:
- `exists?`: reads `/opt/myapp/version.txt`; returns `true` if content equals `'2.1.0'`
- `create`: creates `/opt/myapp` (mkdir -p), downloads artifact to `/opt/myapp/artifact.tar.gz`, extracts tar.gz in place, writes `'2.1.0'` to `/opt/myapp/version.txt`
- `destroy`: removes `/opt/myapp` recursively (rm -rf)

### mySecretType1 (type + provider)

**Type file**: `lib/puppet/type/mySecretType1.rb`
**Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`

**Parameters**:
- `name` (String, namevar): server identifier — `'redis-node'`
- `schedule` (String): schedule assignment — `'daily'`
- `ensure` (Enum[present, absent])

**Provider lifecycle** (via `/usr/local/bin/schedulerctl`):
- `exists?`: runs `schedulerctl query redis-node`
- `create`: runs `schedulerctl register redis-node --schedule daily`
- `destroy`: runs `schedulerctl unregister redis-node`

## Dependencies

**External module dependencies**: None (no Puppetfile found). The `redis` class referenced in `manifests/install.pp` is an external dependency that must be identified and replaced with an Ansible role (e.g., `geerlingguy.redis` or equivalent).

**System package dependencies**: Redis package (managed by the external `redis` class with `manage_package: true`)

**Service dependencies**:
- `profile_redis_cluster_case2::install` is `contain`-ed inside `profile_redis_cluster_case2`, ensuring it completes before the parent class is considered done
- The external `redis` class is included (not contained) inside `profile_redis_cluster_case2::install` — ordering relative to `file['/var/log/redis']` is not explicitly declared

## Puppet Facts Used

- **`redis_role`** (custom fact, `lib/facter/redis_role.rb`): determines whether the node is a Redis `'primary'` or `'replica'` by:
  1. Checking if `/etc/redis/conf.d/replica.conf` exists
  2. If it exists, checking whether it contains the string `'replicaof'`
  - Returns `'replica'` if both conditions are true, `'primary'` otherwise
  - Confined to Linux kernel only
  - **Note**: This fact is defined in the module but not explicitly referenced in the execution tree manifests. It may be consumed by the external `redis` class or by other profiles.

- **`kernel`** (built-in Facter fact): used as a confine constraint in `redis_role` — fact only runs on `Linux`

## Custom Types Used

- **`myDeploy1 'myapp'`** — declared in `manifests/init.pp` with: `version => '2.1.0'`, `url => 'http://artifacts.internal/myapp-2.1.0.tar.gz'`, `install_dir => '/opt/myapp'`
- **`mySecretType1 'redis-node'`** — declared in `manifests/init.pp` with: `schedule => 'daily'`

## Custom Providers Used

- **`myDeployProvider`** — implements `myDeploy1`; used for the `myDeploy1['myapp']` resource in `manifests/init.pp`
- **`mySecretProvider1`** — implements `mySecretType1`; used for the `mySecretType1['redis-node']` resource in `manifests/init.pp`

## Custom Functions Used

- **`myFunction1('http://localhost:8080/health')`** — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON (Hash/Array) or raw String; result stored in `$health_check` and serialized as JSON content of `file['/var/lib/redis/health_check.json']`
- **`mySecretFunction1('redis_service_token')`** — called in `manifests/init.pp`; fetches secret named `'redis_service_token'` from `CompanyInternal::SecretStore`; result stored in `$service_token` (usage of `$service_token` beyond assignment is not visible in the execution tree — it may be passed to `mySecretType1` or the `redis` class implicitly)

## Custom Component Conversion Decisions

### myDeploy1 type + myDeployProvider provider
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping**:
  - `ansible.builtin.file` (state: `directory`) → create `/opt/myapp`
  - `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to `/opt/myapp/artifact.tar.gz`
  - `ansible.builtin.unarchive` → extract `/opt/myapp/artifact.tar.gz` into `/opt/myapp`
  - `ansible.builtin.stat` → read `/opt/myapp/version.txt` to implement idempotency check
  - `ansible.builtin.copy` (content: `'2.1.0'`) → write `/opt/myapp/version.txt`
  - `ansible.builtin.file` (state: `absent`) → handle `ensure: absent` path (remove `/opt/myapp`)
  - Idempotency: wrap download/extract/write tasks in a `when: not version_file.stat.exists or installed_version != '2.1.0'` conditional

### mySecretType1 type + mySecretProvider1 provider
- **Decision**: **NOT SAFELY CONVERTIBLE — flagged for developer review**
- **Reason**: The provider relies exclusively on `/usr/local/bin/schedulerctl`, a proprietary CLI tool for an undocumented Enterprise Scheduler platform. The semantics of `schedulerctl query`, `schedulerctl register`, and `schedulerctl unregister` — including output format, exit codes, idempotency guarantees, and side effects — are entirely opaque. No existing Ansible module or combination of modules can reproduce this behavior without knowing the full contract of `schedulerctl`. The automation developer must:
  1. Obtain documentation or source code for `schedulerctl`
  2. Determine the exit codes for "already registered" vs "not registered" states
  3. Determine whether `schedulerctl query` output can be parsed reliably
  4. Only then decide between `ansible.builtin.command` tasks with `changed_when`/`failed_when` guards, or a custom Ansible module wrapping the CLI

### redis_role fact
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping** (inline or as a custom fact script):
  - Option A (inline): `ansible.builtin.stat` on `/etc/redis/conf.d/replica.conf` + `ansible.builtin.command` (`grep -q replicaof /etc/redis/conf.d/replica.conf`) + `ansible.builtin.set_fact` to set `redis_role: primary` or `redis_role: replica`
  - Option B (custom fact): deploy a script to `/etc/ansible/facts.d/redis_role.fact` that replicates the same logic; result surfaces as `ansible_local.redis_role`

### myFunction1 function
- **Decision**: Existing Ansible modules — no custom module required
- **Mapping**: `ansible.builtin.uri` module with `method: GET`, `url: 'http://localhost:8080/health'`, `return_content: true`; parsed JSON is available via the `json` return key; raw body via `content` return key. Register the result and use `set_fact` to store it for downstream tasks.

### mySecretFunction1 function
- **Decision**: **NOT SAFELY CONVERTIBLE — flagged for developer review**
- **Reason**: The function delegates entirely to `CompanyInternal::SecretStore.fetch`, a method from the proprietary `company_internal_lib` Ruby library. The library is not available in source; its authentication mechanism, backend store, and error handling are fully opaque. The actual secret backend (HashiCorp Vault, AWS Secrets Manager, an internal proprietary store, etc.) is unknown. The automation developer must:
  1. Identify what backend `company_internal_lib` wraps
  2. Only then select the appropriate Ansible lookup plugin (e.g., `community.hashi_vault.hashi_vault`, `amazon.aws.aws_secret`, a custom lookup plugin, or `ansible.builtin.uri` against a REST secrets API)
  3. Treat the fetched value as sensitive (`no_log: true`, `ansible.builtin.set_fact` with `no_log: true`)

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
```
resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }
```
- **Purpose**: Discovers all cluster peer nodes that have this profile applied, enabling dynamic cluster membership awareness (stored in `$redis_nodes`)
- **Usage**: The result (`$redis_nodes`) is available within the class scope. It is not explicitly passed to a template in the visible execution tree, but it may be consumed by the external `redis` class or used for cluster configuration
- **Migration notes**: PuppetDB queries have no direct Ansible equivalent. Migration options:
  - Use Ansible inventory groups: all hosts in the Redis cluster group are already known at play time via `groups['redis_cluster']`
  - Use `ansible.builtin.set_fact` with `groups['redis_cluster'] | map('extract', hostvars) | list` to build a peer list
  - If dynamic discovery is required at runtime (not inventory time), use the AWX/AAP inventory or a dynamic inventory plugin

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned `redis:redis`, mode `0644`, contains valid JSON from health endpoint
- `/var/log/redis` — exists as directory, owned `redis:redis`, mode `0755`
- `/opt/myapp/version.txt` — exists, contains `2.1.0`
- `/opt/myapp/artifact.tar.gz` — present (or cleaned up post-extract depending on provider behavior)
- `/etc/redis/conf.d/replica.conf` — presence/content determines `redis_role` fact value

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check source: `curl -s http://localhost:8080/health` → should return valid JSON

**Templates rendered**: No ERB/EPP templates are used in this module. All file content is either managed by the external `redis` class or generated dynamically (health check JSON via `myFunction1`).

## Pre-flight checks:
```bash
# Redis instance
redis-cli -p 6379 -a CHANGEME ping
# Verify Redis log directory
stat /var/log/redis

# myapp deployment
curl -s --head http://artifacts.internal/myapp-2.1.0.tar.gz | head -n 1
cat /opt/myapp/version.txt

# Enterprise Scheduler (redis-node)
test -x /usr/local/bin/schedulerctl && echo "schedulerctl present" || echo "schedulerctl MISSING"
/usr/local/bin/schedulerctl query redis-node

# Health check endpoint
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health
cat /var/lib/redis/health_check.json

# Secret backend pre-flight
# Confirm the backend behind mySecretFunction1('redis_service_token') before migrating secret retrieval
# Identify what CompanyInternal::SecretStore wraps and select the appropriate Ansible lookup plugin

# External redis class mapping
# Confirm the external redis Puppet class maps to a known Ansible role (e.g., geerlingguy.redis)
# Verify parameter mapping: bind, port, requirepass, maxmemory, appendonly, appendfsync

# Security pre-flight: replace plaintext redis_password before any production run
# group_vars/all/vault.yml (ansible-vault encrypted):
#   vault_redis_cluster_case2_password: "<actual-password>"
# group_vars/all/main.yml:
#   redis_cluster_case2_password: "{{ vault_redis_cluster_case2_password }}"
# All tasks referencing redis_cluster_case2_password must use no_log: true
```