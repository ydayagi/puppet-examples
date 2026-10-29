---
source-path: .
---

# Migration Plan: profile_redis_cluster_case2

**TLDR**: This Puppet module configures a Redis cluster node. It installs and configures Redis via the `redis` class (bind all interfaces, port 6379, password-protected, 2 GB memory limit with `allkeys-lru` eviction, append-only persistence), ensures a log directory exists, deploys a companion application artifact (`myapp` v2.1.0) from an internal artifact server, registers the node with a proprietary Enterprise Scheduler via `schedulerctl`, fetches a live health-check JSON payload from a local HTTP endpoint and writes it to disk, and retrieves a service token from a proprietary internal secret store. It also performs a PuppetDB query to discover all nodes in the same cluster. Several components rely on proprietary or undocumented systems that require developer investigation before Ansible equivalents can be implemented.

## Service Type and Instances

**Service Type**: In-memory Cache / Data Store (Redis cluster node)

**Configured Instances**:
- **Redis node**: single Redis server instance per host
  - Port: `6379`
  - Bind: `0.0.0.0` (all interfaces)
  - Password: `CHANGEME` (plaintext hardcoded default — must be vaulted)
  - Max memory: `2048mb` with `allkeys-lru` eviction policy
  - Persistence: append-only log, fsync `everysec`
- **myapp**: companion application deployment
  - Version: `2.1.0`
  - Source URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`
  - Version tracking file: `/opt/myapp/version.txt`
- **Enterprise Scheduler registration**: node registered as `redis-node` with schedule `daily`
- **Health check snapshot**: `/var/lib/redis/health_check.json` — JSON body from `http://localhost:8080/health`

## File Structure

```
profile_redis_cluster_case2/
├── manifests/
│   ├── init.pp
│   └── install.pp
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
└── data/
    ├── common.yaml
    ├── environment/
    │   ├── production.yaml
    │   └── staging.yaml
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case2** (`manifests/init.pp`):
   - Class parameters (all resolved from manifest defaults — no Hiera overrides exist at any level):
     - `$redis_port` = `6379`
     - `$redis_password` = `'CHANGEME'` ⚠️ plaintext hardcoded
     - `$maxmemory_mb` = `2048`
     - `$maxmemory_policy` = `'allkeys-lru'`
   - **PuppetDB query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }` — collects all certnames that have this class applied, stored in `$redis_nodes`. Used for cluster-awareness (peer discovery). Result is a list of hostnames at catalog-compile time.
   - **Custom function call**: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body as a Hash/Array (or raw String if JSON parse fails). Result stored in `$health_check`.
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized `$health_check` (output of the HTTP GET above)
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider logic: checks `/opt/myapp/version.txt` for `2.1.0`; if absent/mismatched: creates `/opt/myapp`, downloads `artifact.tar.gz` from URL, extracts with `tar -xzf`, writes `2.1.0` to `/opt/myapp/version.txt`
   - **Custom function call**: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from `CompanyInternal::SecretStore` (proprietary, undocumented backend). ⚠️ NOT SAFELY CONVERTIBLE.
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present`
     - Provider logic: runs `schedulerctl query redis-node`; if not registered: runs `schedulerctl register --schedule daily redis-node`; destroy runs `schedulerctl unregister redis-node`. ⚠️ NOT SAFELY CONVERTIBLE.
   - `contain profile_redis_cluster_case2::install`

2. **profile_redis_cluster_case2::install** (`manifests/install.pp`):
   - Includes (not contained) `class 'redis'` with the following parameters:
     - `bind` = `'0.0.0.0'`
     - `port` = `6379` (resolved from `$profile_redis_cluster_case2::redis_port`)
     - `requirepass` = `'CHANGEME'` (resolved from `$profile_redis_cluster_case2::redis_password`) ⚠️ plaintext
     - `maxmemory` = `'2048mb'` (resolved from `"${maxmemory_mb}mb"`)
     - `appendonly` = `true`
     - `appendfsync` = `'everysec'`
     - `manage_package` = `true`
     - The `redis` class is an external/unanalyzed class — it is expected to install the Redis package, write `/etc/redis/redis.conf` (or equivalent), and manage the `redis` service.
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 variables, all resolved from class parameter defaults in `manifests/init.pp`. No Hiera overrides exist at common, production, or staging levels.

### Variable Definitions

**Class parameter defaults (`manifests/init.pp`)** → Migration note: All variables are defined only at the manifest default level; no Hiera data files override any of these values.
- `profile_redis_cluster_case2::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case2::redis_password`: `'CHANGEME'` (type: String) ⚠️ plaintext, never encrypted — must be migrated to Ansible Vault or equivalent secrets backend
- `profile_redis_cluster_case2::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster_case2::maxmemory_policy`: `'allkeys-lru'` (type: String)

**common.yaml (`../../data/common.yaml`)** → Migration note: No `profile_redis_cluster_case2::*` keys defined at this level.

**environment/production.yaml (`../../data/environment/production.yaml`)** → Migration note: No `profile_redis_cluster_case2::*` keys defined at this level.

**environment/staging.yaml (`../../data/environment/staging.yaml`)** → Migration note: No `profile_redis_cluster_case2::*` keys defined at this level.

### Variable Migration Summary

- **Common defaults**: 4 variables (all from manifest defaults)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (no production or staging overrides)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables currently encrypted — `redis_password` is plaintext and **must** be migrated to Ansible Vault or an equivalent secrets backend

### Cross-Level Overrides

No cross-level overrides. All four variables are defined only at the manifest default level and are never overridden in any Hiera data file.

### Merge Strategy Notes

- No merge strategies apply — all variables are scalar types (Integer or String) resolved via `first` (default) lookup. No hash or array merging occurs in this module.

## Custom Types and Providers

### myDeploy1 / myDeployProvider

**Type file**: `lib/puppet/type/myDeploy1.rb`
**Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`

**Parameters**:
- `name`: `'myapp'` — application identifier (namevar)
- `version`: `'2.1.0'` — desired version; validated non-empty
- `url`: `'http://artifacts.internal/myapp-2.1.0.tar.gz'` — artifact download URL; validated `^https?://`
- `install_dir`: `'/opt/myapp'` — target installation directory
- `ensure`: `present` (default)

**Provider behavior**:
- `exists?`: reads `/opt/myapp/version.txt`; returns true if content equals `'2.1.0'`
- `create`: creates `/opt/myapp`, downloads `artifact.tar.gz` from URL, extracts with `tar -xzf`, writes `'2.1.0'` to `/opt/myapp/version.txt`
- `destroy`: removes `/opt/myapp` recursively

### mySecretType1 / mySecretProvider1

**Type file**: `lib/puppet/type/mySecretType1.rb`
**Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`

**Parameters**:
- `name`: `'redis-node'` — server identifier (namevar)
- `schedule`: `'daily'` — schedule string passed to `schedulerctl register --schedule`
- `ensure`: `present` (default)

**Provider behavior**:
- `exists?`: runs `/usr/local/bin/schedulerctl query redis-node`
- `create`: runs `/usr/local/bin/schedulerctl register --schedule daily redis-node`
- `destroy`: runs `/usr/local/bin/schedulerctl unregister redis-node`

## Dependencies

**External module dependencies**: None (no Puppetfile found). The `redis` class referenced in `manifests/install.pp` is unanalyzed — it is likely a community module (e.g., `puppet-redis` from Puppet Forge) that must be identified and its Ansible equivalent sourced (e.g., `community.general` or a dedicated Redis role).

**System package dependencies**:
- Redis server package (managed by the `redis` class with `manage_package => true`)
- `/usr/local/bin/schedulerctl` — proprietary Enterprise Scheduler CLI binary; must be pre-installed on target hosts

**Service dependencies**:
- Redis service must be running before `myFunction1('http://localhost:8080/health')` can return a valid response (the health endpoint is on port 8080, implying a sidecar or proxy process must also be running)
- `myDeploy1` and `mySecretType1` have no explicit ordering relative to `profile_redis_cluster_case2::install` in the execution tree — they run in catalog-declared order

## Puppet Facts Used

- **`redis_role`** (custom fact, `lib/facter/redis_role.rb`): Returns `'replica'` if `/etc/redis/conf.d/replica.conf` exists and contains the string `replicaof`; returns `'primary'` otherwise. Confined to Linux. Used to distinguish cluster role at catalog-compile time. Note: this fact is defined in the module but is **not directly referenced** in the analyzed manifests — it may be consumed by the `redis` class or by other profiles.
- **`kernel`**: Built-in Facter fact used as a confinement guard in `redis_role.rb` — fact only evaluates on Linux systems.

## Custom Types Used

- **`myDeploy1 'myapp'`** — declared in `manifests/init.pp`; parameters: version=`'2.1.0'`, url=`'http://artifacts.internal/myapp-2.1.0.tar.gz'`, install_dir=`'/opt/myapp'`
- **`mySecretType1 'redis-node'`** — declared in `manifests/init.pp`; parameters: schedule=`'daily'`

## Custom Providers Used

- **`myDeployProvider`** — implements `myDeploy1`; used for the `'myapp'` resource in `manifests/init.pp`
- **`mySecretProvider1`** — implements `mySecretType1`; used for the `'redis-node'` resource in `manifests/init.pp`

## Custom Functions Used

- **`myFunction1('http://localhost:8080/health')`** — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result written to `/var/lib/redis/health_check.json`
- **`mySecretFunction1('redis_service_token')`** — called in `manifests/init.pp`; fetches secret `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token` (used implicitly — likely passed to `mySecretType1` or the `redis` class, though not shown explicitly in the execution tree)

## Custom Component Conversion Decisions

### myDeploy1 (type) + myDeployProvider (provider)
- **Decision**: Existing Ansible modules — no custom module needed.
- **Mapping**:
  - `ansible.builtin.file` with `state: directory` → create `/opt/myapp`
  - `ansible.builtin.stat` → read `/opt/myapp/version.txt` for idempotency check
  - `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to a temp path
  - `ansible.builtin.unarchive` with `remote_src: true` → extract into `/opt/myapp`
  - `ansible.builtin.copy` with `content: '2.1.0'` → write `/opt/myapp/version.txt`
  - `ansible.builtin.file` with `state: absent` → destroy path (ensure: absent)
  - `ansible.builtin.assert` → validate version non-empty and URL matches `^https?://` before download

### mySecretType1 (type) + mySecretProvider1 (provider)
- **Decision**: ⚠️ NOT SAFELY CONVERTIBLE — flagged for developer review.
- **Reason**: The provider wraps `/usr/local/bin/schedulerctl`, a proprietary Enterprise Scheduler CLI. The subcommands (`query`, `register --schedule`, `unregister`), their exit codes, output format, and side effects are entirely undocumented in the source. There is no known Ansible module or Galaxy collection for this platform. A migration developer must obtain the `schedulerctl` documentation or binary specification before any Ansible equivalent (e.g., `ansible.builtin.command` tasks with `changed_when`/`failed_when` guards, or a custom Ansible module) can be implemented reliably.

### redis_role (custom fact)
- **Decision**: Existing Ansible modules — no custom module needed.
- **Mapping**:
  - `ansible.builtin.stat` → check existence of `/etc/redis/conf.d/replica.conf`
  - `ansible.builtin.slurp` or `ansible.builtin.shell` → read file contents and check for `replicaof` string
  - Register result as a host variable (e.g., `redis_role: primary|replica`)
  - Alternatively, deploy a static fact script to `/etc/ansible/facts.d/redis_role.fact`; Ansible's `setup` module will expose it as `ansible_local.redis_role`

### myFunction1 (custom function)
- **Decision**: Existing Ansible modules — no custom module needed.
- **Mapping**:
  - `ansible.builtin.uri` with `method: GET`, `url: 'http://localhost:8080/health'`, `return_content: true`
  - The `json` return key provides the parsed JSON body automatically
  - The `content` return key provides the raw body if JSON parsing is not needed
  - Register the result and pass to subsequent tasks (e.g., write to `/var/lib/redis/health_check.json` via `ansible.builtin.copy`)

### mySecretFunction1 (custom function)
- **Decision**: ⚠️ NOT SAFELY CONVERTIBLE — flagged for developer review.
- **Reason**: The function delegates entirely to `CompanyInternal::SecretStore.fetch`, a method from the proprietary `company_internal_lib` Ruby library. No source code for this library is available. Its secret-store backend (HashiCorp Vault? AWS Secrets Manager? a proprietary database?), authentication mechanism, network dependencies, and error semantics are all unknown. A migration developer must first identify the underlying secrets backend before selecting an Ansible equivalent — candidates include `community.hashi_vault.hashi_vault_kv2_get`, `amazon.aws.aws_secret`, `azure.azcollection.azure_keyvault_secret`, or a custom lookup plugin. Until the backend is identified, no mapping can be confirmed.

## Template Conversion Notes

No ERB templates are present in this module. The only dynamic file content is:
- `/var/lib/redis/health_check.json`: content is the JSON-serialized output of `myFunction1('http://localhost:8080/health')`. In Ansible, use `ansible.builtin.uri` to fetch the response, then `ansible.builtin.copy` with `content: "{{ health_check_result.json | to_nice_json }}"` to write the file.

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
- **Query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }`
- **Purpose**: Discovers all cluster peer hostnames that have this profile applied. Result stored in `$redis_nodes`.
- **Usage**: `$redis_nodes` is assigned but not explicitly consumed in the analyzed execution tree — it is likely passed to the `redis` class for cluster peer configuration or used in a template not visible in this module.
- **Migration notes**: PuppetDB queries for peer discovery have no direct Ansible equivalent. Options:
  - Use Ansible inventory groups — all hosts in the `redis_cluster` group are peers; iterate with `groups['redis_cluster']`
  - Use `ansible.builtin.add_host` or dynamic inventory scripts to replicate runtime discovery
  - If the `redis` class uses `$redis_nodes` for cluster topology config, the Ansible role must replicate this by templating peer lists from inventory group membership

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned `redis:redis`, mode `0644`, valid JSON content
- `/opt/myapp/version.txt` — exists, contains exactly `2.1.0`
- `/opt/myapp/` — directory exists, artifact extracted
- `/var/log/redis` — directory exists, owned `redis:redis`, mode `0755`
- `/etc/redis/conf.d/replica.conf` — presence/absence determines `redis_role` fact value
- `/usr/local/bin/schedulerctl` — binary must be present on target hosts before play runs

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME PING` → expect `PONG`
- Health endpoint: `curl -s http://localhost:8080/health` → expect valid JSON response

**Templates rendered**: None (no ERB templates in this module)

## Pre-flight checks:
```bash
# Verify schedulerctl binary exists and is executable
test -x /usr/local/bin/schedulerctl

# Verify Redis health endpoint is reachable before writing health check file
curl -sf http://localhost:8080/health

# Verify artifact server is reachable and myapp artifact exists
curl -sI http://artifacts.internal/myapp-2.1.0.tar.gz

# Verify Redis is listening on port 6379
redis-cli -p 6379 -a CHANGEME PING

# Verify myapp version file matches expected version
grep -qx '2.1.0' /opt/myapp/version.txt && echo "OK" || echo "MISMATCH"

# Verify health check JSON file exists and is valid JSON
python3 -m json.tool /var/lib/redis/health_check.json > /dev/null && echo "Valid JSON" || echo "Invalid JSON"

# Verify log directory ownership and permissions
stat -c '%U %G %a' /var/log/redis

# Confirm secret store backend identity before implementing mySecretFunction1 equivalent
# ACTION REQUIRED: identify CompanyInternal::SecretStore backend (Vault, AWS, Azure, etc.)

# Confirm schedulerctl CLI documentation before implementing mySecretType1 equivalent
# ACTION REQUIRED: obtain schedulerctl subcommand spec (query/register/unregister exit codes and output format)

# Replace redis_password default 'CHANGEME' with a vaulted value in group_vars/ before any deployment
# ACTION REQUIRED: vault the redis_password value before running against any environment
```