---
source-path: .
---

# Migration Plan: profile_redis_cluster_case2

**TLDR**: This module deploys and configures a Redis cluster node. It installs Redis via a community `redis` class with specific bind/port/auth/memory settings, creates a log directory, writes a health-check JSON file populated by a live HTTP GET call, deploys an application artifact (`myapp` v2.1.0) using a custom deployment type, fetches a service token from a proprietary internal secret store, and registers the node in a proprietary Enterprise Scheduler platform. It also performs a PuppetDB query to discover all nodes in the same cluster. The module carries a hardcoded plaintext default password (`CHANGEME`) that must be replaced with a secure secret before migration.

## Service Type and Instances

**Service Type**: Cache / In-Memory Data Store (Redis Cluster Node)

**Configured Instances**:
- **redis-node**: Single Redis instance per host, acting as either primary or replica (determined at runtime by the `redis_role` custom fact)
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Auth password: `CHANGEME` (plaintext default — **must be replaced before deployment**)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Persistence: AOF enabled (`appendonly: true`, `appendfsync: everysec`)
  - Package management: `manage_package: true`

- **myapp**: Application artifact deployed to `/opt/myapp` at version `2.1.0`
  - Source URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Version tracked via: `/opt/myapp/version.txt`

- **redis-node (scheduler)**: Enterprise Scheduler registration for this node
  - Schedule: `daily`
  - Managed via: `/usr/local/bin/schedulerctl`

## File Structure

```
profile_redis_cluster_case2/
├── manifests/
│   ├── init.pp
│   └── install.pp
├── lib/
│   ├── facter/
│   │   └── redis_role.rb
│   ├── puppet/
│   │   ├── functions/
│   │   │   ├── myFunction1.rb
│   │   │   └── mySecretFunction1.rb
│   │   ├── provider/
│   │   │   ├── myDeploy1/
│   │   │   │   └── myDeployProvider.rb
│   │   │   └── mySecretType1/
│   │   │       └── mySecretProvider1.rb
│   │   └── type/
│   │       ├── myDeploy1.rb
│   │       └── mySecretType1.rb
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case2** (`manifests/init.pp`):
   - Resolves class parameters: `$redis_port = 6379`, `$redis_password = 'CHANGEME'`, `$maxmemory_mb = 2048`, `$maxmemory_policy = 'allkeys-lru'`
   - Executes PuppetDB query at catalog compile time: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }` → stores result in `$redis_nodes` (Array of certname Hashes)
   - Calls `myFunction1('http://localhost:8080/health')` → performs HTTP GET, returns parsed JSON Hash/Array or raw String → stored in `$health_check`
   - Declares `file '/var/lib/redis/health_check.json'`: ensure `file`, owner `redis`, group `redis`, mode `0644`, content is JSON-serialized result of the health check HTTP response
   - Declares `myDeploy1 'myapp'`: version `2.1.0`, url `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir `/opt/myapp`, ensure `present`
     - Provider `exists?`: reads `/opt/myapp/version.txt`, returns true if content equals `2.1.0`
     - Provider `create`: downloads artifact via `net/http`, extracts with system `tar` to `/opt/myapp`, writes `2.1.0` to `/opt/myapp/version.txt`
     - Provider `destroy`: removes `/opt/myapp` entirely via `FileUtils.rm_rf`
   - Calls `mySecretFunction1('redis_service_token')` → fetches secret from `CompanyInternal::SecretStore` → stored in `$service_token`
   - Declares `mySecretType1 'redis-node'`: schedule `daily`, ensure `present`
     - Provider `exists?`: runs `/usr/local/bin/schedulerctl status redis-node`
     - Provider `create`: runs `/usr/local/bin/schedulerctl register redis-node --schedule daily`
     - Provider `destroy`: runs `/usr/local/bin/schedulerctl unregister redis-node`
   - Calls `contain profile_redis_cluster_case2::install` — enforces ordering: all resources in `init.pp` are ordered relative to the subclass as a unit

2. **profile_redis_cluster_case2::install** (`manifests/install.pp`):
   - Includes external class `redis` with parameters: bind `0.0.0.0`, port `6379`, requirepass `CHANGEME`, maxmemory `2048mb`, appendonly `true`, appendfsync `everysec`, manage_package `true`
     - This class installs the `redis` package, writes `/etc/redis/redis.conf` (or equivalent), and manages the `redis` service
   - Declares `file '/var/log/redis'`: ensure `directory`, owner `redis`, group `redis`, mode `0755`

## Variables

**Variable Flow Summary**: 4 class parameters (all manifest-level defaults, no Hiera data files present) plus 3 runtime-resolved variables.

### Variable Definitions

**Class parameter defaults (`manifests/init.pp`)** → Migration note: All values are hardcoded manifest defaults; no Hiera hierarchy exists for this module. Each must be mapped to Ansible variables or vault entries.
- `profile_redis_cluster_case2::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case2::redis_password`: `'CHANGEME'` (type: String) ⚠️ plaintext insecure default — must be replaced with a vault-encrypted value before deployment
- `profile_redis_cluster_case2::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster_case2::maxmemory_policy`: `'allkeys-lru'` (type: String)

**Runtime-resolved variables** → Migration note: These are computed at Puppet catalog compile time and have no static Hiera equivalent; each requires a dedicated Ansible replacement strategy.
- `$redis_nodes`: result of PuppetDB query — Array of Hashes containing certnames of all nodes with this class applied (type: Array[Hash])
- `$health_check`: result of HTTP GET to `http://localhost:8080/health` — parsed JSON Hash/Array or raw String (type: Variant)
- `$service_token`: secret fetched from `CompanyInternal::SecretStore` under key `redis_service_token` (type: String) — value unknown at analysis time; must use `no_log: true` in any consuming Ansible task

### Variable Migration Summary

- **Common defaults**: 4 variables (all manifest-level, no Hiera)
- **OS-specific**: 0 variables
- **Environment-specific**: 0 variables
- **Host-specific**: 0 variables
- **Encrypted**: 1 variable requiring secure storage (`redis_password` — currently plaintext `CHANGEME`; migrate to Ansible Vault or external secret manager)
- **Runtime-fetched**: 2 variables (`$redis_nodes` via PuppetDB query; `$service_token` via proprietary `CompanyInternal::SecretStore`)

### Cross-Level Overrides

No cross-level overrides detected — no Hiera data files are present in this module.

### Merge Strategy Notes

- No Hiera merge strategies apply — all variables are manifest-level defaults with no hierarchy.

## Custom Types and Providers

### myDeploy1 (artifact deployment)

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Parameters**:
  - `name` (namevar)
  - `version` (non-empty String)
  - `url` (String, must match `^https?://`)
  - `install_dir` (String)
  - `ensure` (present/absent, default: `present`)
- **Provider logic**:
  - `exists?` → reads `/opt/myapp/version.txt`; returns true if content equals `2.1.0`
  - `create` → downloads `http://artifacts.internal/myapp-2.1.0.tar.gz` via `net/http`, extracts with system `tar` to `/opt/myapp`, writes `2.1.0` to `/opt/myapp/version.txt`
  - `destroy` → `FileUtils.rm_rf('/opt/myapp')`
- **Ansible equivalent**: `ansible.builtin.get_url` + `ansible.builtin.unarchive` + `ansible.builtin.copy` (for `version.txt`), or a custom Ansible module for strict behavioral parity

### mySecretType1 (Enterprise Scheduler registration)

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Parameters**:
  - `name` (namevar)
  - `ensure` (present/absent, default: `present`)
  - `schedule` (String)
- **Provider logic**:
  - `exists?` → runs `/usr/local/bin/schedulerctl status redis-node`
  - `create` → runs `/usr/local/bin/schedulerctl register redis-node --schedule daily`
  - `destroy` → runs `/usr/local/bin/schedulerctl unregister redis-node`
- **Ansible equivalent**: Custom Ansible module wrapping the `schedulerctl` CLI; no Ansible Galaxy collection covers this proprietary tool

### redis_role (custom fact)

- **Fact file**: `lib/facter/redis_role.rb`
- **Confined to**: Linux only (via `kernel` fact)
- **Logic**: If `/etc/redis/conf.d/replica.conf` exists AND contains the string `replicaof` → returns `'replica'`; otherwise returns `'primary'`
- **Ansible equivalent**: Use `ansible.builtin.stat` + `ansible.builtin.slurp` + `ansible.builtin.set_fact`, or deploy a script to `/etc/ansible/facts.d/redis_role.fact`

### myFunction1 (HTTP GET helper)

- **Function file**: `lib/puppet/functions/myFunction1.rb`
- **Behavior**: HTTP GET to a given URL; returns parsed JSON (Hash or Array) if response body is valid JSON, otherwise returns raw String; raises `Puppet::Error` on any non-2xx HTTP response
- **Used with**: `http://localhost:8080/health`
- **Ansible equivalent**: `ansible.builtin.uri` module with `return_content: true`; parsed JSON available via `http_response.json`

### mySecretFunction1 (proprietary secret fetch)

- **Function file**: `lib/puppet/functions/mySecretFunction1.rb`
- **Behavior**: Calls `CompanyInternal::SecretStore.fetch('redis_service_token')`, returns the secret as a String
- **Ansible equivalent**: Custom Ansible lookup plugin (e.g., `lookup('company_secret_store', 'redis_service_token')`); if the backend is a known product (HashiCorp Vault, CyberArk), use the corresponding Galaxy collection. Apply `no_log: true` on any task consuming this value.

## Dependencies

**External module dependencies**:
- `redis` community class — no Puppetfile found; source unspecified. Likely `puppet/redis` from Puppet Forge. Ansible equivalent: `geerlingguy.redis` role or `ansible.builtin.package` + manual config templating.

**System package dependencies**:
- `redis` package (managed by the `redis` class with `manage_package: true`)
- `/usr/local/bin/schedulerctl` — proprietary Enterprise Scheduler CLI binary; must be pre-installed on all target nodes before catalog apply

**Service dependencies**:
- `profile_redis_cluster_case2::install` is `contain`-ed inside `profile_redis_cluster_case2`; all resources in `init.pp` are ordered relative to the subclass as a unit
- The `redis` class (inside `install.pp`) manages the Redis service
- `file['/var/log/redis']` is a peer resource within `install.pp` with no explicit ordering relative to the `redis` class

## Puppet Facts Used

- `kernel` — used by the `redis_role` fact for confinement; ensures the fact only executes on Linux nodes
- `redis_role` (custom fact, `lib/facter/redis_role.rb`) — returns `'primary'` or `'replica'` based on presence of `replicaof` string in `/etc/redis/conf.d/replica.conf`; available to manifests at catalog compile time (defined and available for conditional logic; not directly referenced by name in the analyzed manifest resources)

## Template Conversion Notes

No ERB/EPP templates are used in this module. All file content is either:
- Dynamically generated at runtime: `/var/lib/redis/health_check.json` — content is the JSON-serialized result of the `myFunction1` HTTP GET response, produced via `stdlib::to_json`
- Managed by the external `redis` class: Redis configuration files (template details unavailable without analyzing the `redis` community module source)

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
- **Query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }`
- **Purpose**: Discovers all nodes in the cluster that have this profile applied; result stored in `$redis_nodes` (Array[Hash] of certnames)
- **Usage**: `$redis_nodes` is declared but not directly consumed by any resource in the analyzed manifests — likely intended for Redis cluster peer configuration or to be passed into the `redis` class
- **Ansible migration impact**: This is a significant migration blocker. Ansible has no native PuppetDB equivalent. Recommended replacements:
  - Use a **dynamic inventory group** (e.g., `redis_cluster`) to enumerate cluster members; reference via `groups['redis_cluster']`
  - Query an external CMDB or service discovery system (Consul, AWS SSM, etc.) using `ansible.builtin.uri` or a lookup plugin
  - Pre-populate a static inventory group and maintain it as infrastructure changes

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — must exist, owner `redis`, group `redis`, mode `0644`, valid JSON content
- `/var/log/redis` — must exist as a directory, owner `redis`, group `redis`, mode `0755`
- `/opt/myapp/version.txt` — must contain exactly `2.1.0`
- `/opt/myapp/` — must exist and contain the extracted artifact from `http://artifacts.internal/myapp-2.1.0.tar.gz`
- `/usr/local/bin/schedulerctl` — must be present and executable (pre-requisite, not managed by this module)
- `/etc/redis/conf.d/replica.conf` — inspected by `redis_role` fact; presence plus `replicaof` string determines node role

**Service endpoints to check**:
- Redis instance `redis-node`: `redis-cli -p 6379 -a CHANGEME ping` → must return `PONG`
- Health endpoint: `curl -sf http://localhost:8080/health` → must return a valid HTTP 2xx response (used to populate `health_check.json`)
- Scheduler registration `redis-node`: `/usr/local/bin/schedulerctl status redis-node` → must return registered status

**Templates rendered**: None (no ERB/EPP templates in this module)

## Pre-flight checks:
```bash
# Verify schedulerctl binary is installed and executable
test -x /usr/local/bin/schedulerctl && echo "schedulerctl OK" || echo "MISSING: schedulerctl not found"

# Verify Redis health endpoint is reachable before catalog apply
curl -sf http://localhost:8080/health && echo "Health endpoint OK" || echo "FAIL: health endpoint unreachable"

# Verify artifact download URL is reachable
curl -sfI http://artifacts.internal/myapp-2.1.0.tar.gz && echo "Artifact URL OK" || echo "FAIL: artifact URL unreachable"

# Confirm redis_password has been replaced from the CHANGEME default
# (check your Ansible vault or secret manager — do NOT deploy with CHANGEME)

# Confirm CompanyInternal::SecretStore equivalent is available for redis_service_token retrieval

# Post-apply: verify Redis instance redis-node is responding
redis-cli -p 6379 -a CHANGEME ping

# Post-apply: validate Redis maxmemory configuration for redis-node
redis-cli -p 6379 CONFIG GET maxmemory

# Post-apply: verify health_check.json was written correctly
stat /var/lib/redis/health_check.json && python3 -m json.tool /var/lib/redis/health_check.json

# Post-apply: verify log directory exists with correct ownership
stat /var/log/redis

# Post-apply: verify myapp artifact version
cat /opt/myapp/version.txt

# Post-apply: verify scheduler registration for redis-node
/usr/local/bin/schedulerctl status redis-node

# Post-apply: check redis_role fact value on this node
facter redis_role
```