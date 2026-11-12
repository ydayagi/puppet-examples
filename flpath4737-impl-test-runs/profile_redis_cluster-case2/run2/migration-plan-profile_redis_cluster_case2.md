---
source-path: .
---

# Migration Plan: profile_redis_cluster_case2

**TLDR**: This Puppet profile configures a Redis node (primary or replica) with authentication, memory limits, and AOF persistence. It installs Redis via the `puppet-redis` community module, manages a log directory, deploys a companion application artifact (`myapp` v2.1.0), registers the node in a proprietary Enterprise Scheduler via `mySecretType1`/`mySecretProvider1`, writes a health-check JSON file populated by a live HTTP call, and discovers peer Redis nodes via a PuppetDB query. The module carries one plaintext credential (`redis_password`) that must be vaulted before Ansible deployment, one proprietary scheduler integration that cannot be safely converted without further investigation, and one proprietary secret-store function (`mySecretFunction1`) whose backend is unknown.

## Service Type and Instances

**Service Type**: In-memory Cache / Data Store (Redis)

**Configured Instances**:
- **redis** (single node, primary or replica determined at runtime by `redis_role` custom fact):
  - Listen address: `0.0.0.0`
  - Port: `6379`
  - Auth password: `CHANGEME` (plaintext placeholder — must be replaced with vault secret)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Persistence: AOF enabled, `appendfsync everysec`; RDB snapshots at 900/300/60 s thresholds
  - Log file: `/var/log/redis/redis-server.log`
  - Data dir: `/var/lib/redis`
  - PID file: `/var/run/redis/redis-server.pid`

- **myapp** (companion application deployment):
  - Version: `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`

## File Structure

```
manifests/
  init.pp                                          — entry class, top-level resources and custom type declarations
  install.pp                                       — Redis package/service configuration and log directory

templates/
  redis.conf.erb                                   — Redis configuration file (rendered once by puppet-redis module)

lib/
  puppet/
    type/
      myDeploy1.rb                                 — application deployment type
      mySecretType1.rb                             — Enterprise Scheduler registration type
    provider/
      myDeploy1/
        myDeployProvider.rb                        — download + extract + version-file workflow
      mySecretType1/
        mySecretProvider1.rb                       — schedulerctl CLI wrapper
    functions/
      myFunction1.rb                               — HTTP GET returning parsed JSON
      mySecretFunction1.rb                         — secret retrieval from proprietary store
  facter/
    redis_role.rb                                  — determines primary or replica from /etc/redis/conf.d/replica.conf
```

## Module Explanation

The module performs operations in this order:

**IMPORTANT: Full paths from the File Structure section are used throughout.**

1. **profile_redis_cluster_case2** (`manifests/init.pp`):
   - Declares class parameters: `$redis_port = 6379`, `$redis_password = 'CHANGEME'`, `$maxmemory_mb = 2048`, `$maxmemory_policy = 'allkeys-lru'`
   - Executes PuppetDB query: `puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }")` — discovers all Redis cluster member certnames; result stored in `$redis_nodes`
   - Calls `myFunction1('http://localhost:8080/health')` — performs HTTP GET, returns parsed JSON; result stored in `$health_check`
   - Calls `mySecretFunction1('redis_service_token')` — fetches secret from `CompanyInternal::SecretStore`; result stored in `$service_token`
   - Declares `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: `stdlib::to_json($health_check)`
   - Declares `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
   - Declares `mySecretType1 'redis-node'` → schedule: `daily`, ensure: `present`
   - Contains `profile_redis_cluster_case2::install` via `contain`

2. **profile_redis_cluster_case2::install** (`manifests/install.pp`):
   - Calls `class 'redis'` (from `puppet-redis` ≥ 11.0.0) with parameters: `bind = '0.0.0.0'`, `port = 6379`, `requirepass = 'CHANGEME'`, `maxmemory = '2048mb'`, `appendonly = true`, `appendfsync = 'everysec'`, `manage_package = true`; the `puppet-redis` module renders `templates/redis.conf.erb` to `/etc/redis/redis.conf` and manages the `redis` service (ensure: running, enable: true)
   - Declares `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 variables, all sourced from manifest class parameter defaults. No Hiera data files define any of these keys. No cross-level overrides exist.

### Variable Definitions

**Class parameter defaults in `manifests/init.pp`** → Migration note: All defaults map to `defaults/main.yml` in Ansible; no Hiera hierarchy levels are involved
- `profile_redis_cluster_case2::redis_port`: `6379` (type: integer)
- `profile_redis_cluster_case2::redis_password`: `'CHANGEME'` (type: string — **plaintext credential, must be vaulted before deployment**)
- `profile_redis_cluster_case2::maxmemory_mb`: `2048` (type: integer; used as `'2048mb'` via string interpolation in the Redis config)
- `profile_redis_cluster_case2::maxmemory_policy`: `'allkeys-lru'` (type: string)

### Variable Migration Summary

- **Common defaults**: 4 variables (all from manifest defaults, map to `defaults/main.yml` in Ansible)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (no production.yaml or staging.yaml keys relevant to this module)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable (`redis_password`) — currently plaintext `'CHANGEME'`, must be replaced with an `ansible-vault` encrypted value before deployment

### Cross-Level Overrides

No cross-level overrides exist for any variable in this module.

### Merge Strategy Notes

- No variables in this module use hash or deep merge strategies; all four variables use first-match (default) semantics with a single definition source (manifest defaults).

## Custom Types and Providers

### myDeploy1 (type: `lib/puppet/type/myDeploy1.rb`, provider: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`)

**What it does**: Manages an application deployment tracked by a `version.txt` file inside `install_dir`. The provider:
1. Checks `{{ install_dir }}/version.txt` — if it contains the desired version, skips all steps (idempotency)
2. Creates `install_dir` with `mkdir -p`
3. Downloads `{{ url }}` to a temp path as `artifact.tar.gz`
4. Extracts the tarball into `install_dir`
5. Writes the version string to `{{ install_dir }}/version.txt`
6. On `ensure: absent`, removes `install_dir` recursively

**Parameters used in this module**:
- `name` = `'myapp'`
- `version` = `'2.1.0'`
- `url` = `'http://artifacts.internal/myapp-2.1.0.tar.gz'`
- `install_dir` = `'/opt/myapp'`
- `ensure` = `present` (default)

### mySecretType1 (type: `lib/puppet/type/mySecretType1.rb`, provider: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`)

**What it does**: Registers or unregisters a server in a proprietary Enterprise Scheduler platform using the `schedulerctl` CLI at `/usr/local/bin/schedulerctl`. The provider maps:
- `exists?` → `schedulerctl query <name>`
- `create` → `schedulerctl register --schedule <schedule> <name>`
- `destroy` → `schedulerctl unregister <name>`

**Parameters used in this module**:
- `name` = `'redis-node'`
- `schedule` = `'daily'`
- `ensure` = `present` (default)

## Dependencies

**External module dependencies** (from `metadata.json`):
- `puppetlabs-stdlib` ≥ 9.0.0 < 10.0.0 — provides `stdlib::to_json()` used to serialise health-check content
- `puppet-redis` ≥ 11.0.0 < 12.0.0 — manages Redis package, configuration, and service

**System package dependencies**:
- `redis` (installed and managed by `puppet-redis` with `manage_package: true`)

**Service dependencies**:
- `profile_redis_cluster_case2::install` is contained within `profile_redis_cluster_case2`; the `redis` class (external) manages the `redis` service internally
- No explicit `->` or `~>` chains are declared at the top level between `file`, `myDeploy1`, `mySecretType1`, and the contained install class

## Puppet Facts Used

- **`$facts['networking']['fqdn']`** — used in `templates/redis.conf.erb` as a comment header identifying the node; provides the fully-qualified domain name of the managed host
- **`redis_role`** (custom fact, `lib/facter/redis_role.rb`) — returns `'primary'` or `'replica'` by checking existence of `/etc/redis/conf.d/replica.conf` and whether it contains the string `replicaof`; confined to Linux kernels; not directly consumed by a visible resource in the execution tree but available for conditional logic in the `puppet-redis` class or downstream profiles

## Custom Types Used

- **`myDeploy1 'myapp'`** — declared in `manifests/init.pp`; parameters: `version='2.1.0'`, `url='http://artifacts.internal/myapp-2.1.0.tar.gz'`, `install_dir='/opt/myapp'`
- **`mySecretType1 'redis-node'`** — declared in `manifests/init.pp`; parameters: `schedule='daily'`

## Custom Providers Used

- **`myDeployProvider`** (`lib/puppet/provider/myDeploy1/myDeployProvider.rb`) — implements `myDeploy1`; used for the `myDeploy1 'myapp'` resource
- **`mySecretProvider1`** (`lib/puppet/provider/mySecretType1/mySecretProvider1.rb`) — implements `mySecretType1`; used for the `mySecretType1 'redis-node'` resource

## Custom Functions Used

- **`myFunction1('http://localhost:8080/health')`** — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string on parse failure; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- **`mySecretFunction1('redis_service_token')`** — called in `manifests/init.pp`; fetches secret named `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token` (consumed implicitly by `mySecretType1`)
- **`stdlib::to_json($health_check)`** — called inline in the `file` resource content attribute in `manifests/init.pp`; serialises the `$health_check` hash/array to a JSON string

## Custom Component Conversion Decisions

### myDeploy1 type + myDeployProvider provider
- **Conversion**: Existing Ansible modules — no custom module required.
- **Suggested mapping**:
  - `ansible.builtin.file` with `state: directory` → create `/opt/myapp`
  - `ansible.builtin.stat` + `ansible.builtin.slurp` → read `/opt/myapp/version.txt`; register result; condition subsequent tasks on `installed_version != '2.1.0'`
  - `ansible.builtin.get_url` → download `http://artifacts.internal/myapp-2.1.0.tar.gz` to a temp path (e.g., `/tmp/myapp-2.1.0.tar.gz`)
  - `ansible.builtin.unarchive` with `remote_src: true` → extract tarball into `/opt/myapp`
  - `ansible.builtin.copy` with `content: '2.1.0'` → write `/opt/myapp/version.txt`
  - `ensure: absent` path: `ansible.builtin.file` with `state: absent` on `/opt/myapp`

### mySecretType1 type + mySecretProvider1 provider
- **NOT SAFELY CONVERTIBLE — flagged for developer review.**
- The provider wraps a proprietary CLI tool (`/usr/local/bin/schedulerctl`) with undocumented subcommands (`query`, `register --schedule`, `unregister`), unknown exit codes, and unknown output formats. No existing Ansible module covers this scheduler. A custom Ansible module wrapping `schedulerctl` could be written, but its correctness depends entirely on the undocumented CLI contract. **The automation developer must obtain the `schedulerctl` documentation or source, verify exit codes and output formats for all three subcommands, and then either author a custom module or use `ansible.builtin.command` with explicit idempotency guards.**

### redis_role custom fact
- **Conversion**: Existing Ansible modules — no custom module required.
- **Suggested mapping**: Use `ansible.builtin.stat` to check existence of `/etc/redis/conf.d/replica.conf`, then `ansible.builtin.slurp` (or `ansible.builtin.command: grep -q replicaof /etc/redis/conf.d/replica.conf`) to check for the `replicaof` string. Register the result as `redis_role_value` (`'replica'` if file exists and contains `replicaof`, otherwise `'primary'`). Alternatively, deploy a script to `/etc/ansible/facts.d/redis_role.fact` for persistent `ansible_local.redis_role` availability.

### myFunction1 function
- **Conversion**: Existing Ansible modules — no custom module required.
- **Suggested mapping**: `ansible.builtin.uri` with `method: GET`, `url: 'http://localhost:8080/health'`, `return_content: true`, `status_code: [200, 201, 202, 204]`. The `json` key of the registered result contains the parsed JSON body automatically. Use `register: health_check_result` and reference `health_check_result.json` downstream. For the health-check file, pipe through `ansible.builtin.copy` with `content: "{{ health_check_result.json | to_json }}"`.

### mySecretFunction1 function
- **NOT SAFELY CONVERTIBLE — flagged for developer review.**
- The function delegates to `CompanyInternal::SecretStore.fetch`, a method from the proprietary `company_internal_lib` Ruby library. The backing secrets store, authentication mechanism, network dependencies, and error semantics are entirely opaque. There is no Ansible lookup plugin, Jinja2 filter, or standard secrets-management integration (HashiCorp Vault, AWS Secrets Manager, CyberArk, etc.) that can be confirmed as a drop-in replacement. **The automation developer must identify the underlying secrets backend used by `company_internal_lib` before choosing a migration path** (e.g., `community.hashi_vault.hashi_vault_kv_get`, `amazon.aws.aws_secret`, a custom lookup plugin, or environment-injected variables).

## Template Conversion Notes

### `templates/redis.conf.erb` (rendered once by `puppet-redis` module, destination: `/etc/redis/redis.conf`)

**Variables referenced**:
- `@facts['networking']['fqdn']` — node FQDN, used in comment header only; resolve in Ansible as `{{ ansible_fqdn }}`
- `@redis_port` → `6379`; resolve as `{{ redis_cluster_case2_redis_port }}`
- `@redis_password` → `'CHANGEME'` (vault-encrypted in Ansible); resolve as `{{ redis_cluster_case2_redis_password }}`
- `@maxmemory_mb` → `2048`; used as `<%= @maxmemory_mb %>mb` producing `2048mb`; resolve as `{{ redis_cluster_case2_maxmemory_mb }}mb`
- `@maxmemory_policy` → `'allkeys-lru'`; resolve as `{{ redis_cluster_case2_maxmemory_policy }}`

**Static values in template** (no variable substitution needed):
- `bind 0.0.0.0`, `daemonize yes`, `pidfile /var/run/redis/redis-server.pid`, `logfile /var/log/redis/redis-server.log`, `loglevel notice`
- `appendonly yes`, `appendfilename "appendonly.aof"`, `appendfsync everysec`, `auto-aof-rewrite-percentage 100`, `auto-aof-rewrite-min-size 64mb`
- `save 900 1`, `save 300 10`, `save 60 10000`, `dbfilename dump.rdb`, `dir /var/lib/redis`
- `tcp-backlog 511`, `timeout 0`, `tcp-keepalive 300`

**No Ruby logic blocks, conditionals, or iterations** — the template is straightforward variable substitution and converts directly to a Jinja2 template.

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
- Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case2' }`
- Purpose: Discovers all certnames (hostnames) in the Puppet infrastructure that have this class applied — i.e., all Redis cluster members
- Result stored in: `$redis_nodes`
- Usage: The variable is available within the class scope but is not consumed by any explicitly visible resource in the execution tree; likely used for cluster topology awareness (e.g., passed to a template or used in conditional logic not shown)
- **Ansible migration note**: PuppetDB queries have no direct Ansible equivalent. Replace with one of:
  - An Ansible inventory group (e.g., `redis_cluster`) — all hosts in the group are the cluster members; reference as `{{ groups['redis_cluster'] }}`
  - A dynamic inventory plugin querying the same source of truth
  - A `set_fact` task that builds the node list from `{{ ansible_play_hosts }}` if all cluster members are targeted in the same play

## Checks for the Migration

**Files to verify**:
- `/etc/redis/redis.conf` — Redis configuration (rendered from `templates/redis.conf.erb`)
- `/var/log/redis/` — log directory, owner `redis`, group `redis`, mode `0755`
- `/var/lib/redis/health_check.json` — health-check JSON, owner `redis`, group `redis`, mode `0644`
- `/opt/myapp/` — application install directory
- `/opt/myapp/version.txt` — must contain `2.1.0`

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a <password> PING` → expect `PONG`
- Health endpoint: `curl -s http://localhost:8080/health` → expect 2xx JSON response

**Templates rendered**:
- `templates/redis.conf.erb` → `/etc/redis/redis.conf` (rendered once per node)

## Pre-flight checks:
```bash
# Redis service status
systemctl status redis

# Redis connectivity and configuration (redis instance)
redis-cli -p 6379 -a CHANGEME INFO server

# Log directory ownership and permissions
ls -la /var/log/redis

# Health-check file content
cat /var/lib/redis/health_check.json

# myapp deployment version
cat /opt/myapp/version.txt

# myapp install directory contents
ls -la /opt/myapp/

# Enterprise Scheduler registration (mySecretType1 / mySecretProvider1)
# Verify schedulerctl binary is present before migrating mySecretType1
ls -la /usr/local/bin/schedulerctl
/usr/local/bin/schedulerctl query redis-node

# Secret store investigation (mySecretFunction1)
# Identify the CompanyInternal::SecretStore backend before migrating mySecretFunction1('redis_service_token')
# No automated check available — manual investigation required

# Redis role detection (redis_role custom fact)
cat /etc/redis/conf.d/replica.conf 2>/dev/null || echo "replica.conf not present — node is primary"
grep -q replicaof /etc/redis/conf.d/replica.conf 2>/dev/null && echo "replica" || echo "primary"
```