# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_postgresql` — responsible for deploying and managing a PostgreSQL 16 database server on Debian/Ubuntu systems. The module is self-contained but non-trivial: beyond standard package/repo/service management it relies on **four custom Puppet types/providers** and **two custom Puppet functions**, all of which encode proprietary company logic that has no direct Ansible equivalent and must be re-implemented during migration.

The migration scope is moderate in size but **high in complexity** due to:
- Custom Ruby-backed types and providers that must be replaced with native Ansible modules or custom Python modules/roles.
- A proprietary secret-retrieval function (`mySecretFunction1`) backed by an internal library (`company_internal_lib`) that requires a bespoke Ansible secrets integration.
- A proprietary Enterprise Scheduler CLI integration (`schedulerctl`) with no standard Ansible module.
- A custom application deployment workflow (artifact download + extraction + version tracking) that must be rebuilt as an Ansible task sequence.
- Hiera-driven parameterisation that must be translated into Ansible variables/inventory/group_vars.

**Estimated timeline**: 3–5 weeks for a single experienced engineer, or 2–3 weeks with a two-person team, accounting for testing and validation on a Debian/Ubuntu target environment.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_postgresql**:
  - **Description**: PostgreSQL 16 profile that configures the PGDG APT repository, installs versioned PostgreSQL packages (`postgresql-16`, `postgresql-contrib-16`, `libpq-dev`), manages the `postgresql` service, deploys a companion application artifact (`myapp` v2.1.0 from an internal artifact server), writes a health-check JSON file, manages proprietary `!key=value` config entries in `/etc/company/app.conf`, registers the node with an Enterprise Scheduler platform via `schedulerctl`, and schedules a nightly backup cron job at 02:30.
  - **Path**: `.` (module root — `manifests/`, `lib/`, `data/`, `hiera.yaml`, `metadata.json`)
  - **Technology**: Puppet 7/8 (profile pattern)
  - **Key Features**:
    - PGDG APT source management via `puppetlabs-apt` (`apt::source` with GPG key import)
    - Hiera 5 data hierarchy (`common.yaml` + `os/Debian.yaml`) for all parameters
    - PuppetDB live query (`puppetdb_query`) to enumerate all PostgreSQL nodes in the estate
    - Custom HTTP health-check function (`myFunction1`) — performs a `GET` against `http://localhost:8080/health` and writes the JSON response to `/var/lib/pgsql/health_check.json`
    - Custom secret-retrieval function (`mySecretFunction1`) — fetches `postgres_service_token` from a proprietary internal secret store (`CompanyInternal::SecretStore`)
    - Custom application deployment type/provider (`myDeploy1` / `myDeployProvider`) — downloads a `.tar.gz` artifact over HTTP, extracts it, and tracks the installed version via `version.txt`
    - Custom config-file management type/provider (`myFormatType1` / `myFormatProvider1`) — reads/writes `!key=value` lines in `/etc/company/app.conf` (sets `app-mode=cluster` and `health-port=8080`)
    - Custom Enterprise Scheduler registration type/provider (`mySecretType1` / `mySecretProvider1`) — calls `/usr/local/bin/schedulerctl register/unregister/query` to register `postgres-node` on a daily schedule
    - Custom cron management type/provider (`myCronType1` / `myCronProvider1`) — manages root crontab entries via `crontab -l` / `crontab -` shell commands
    - Custom Facter fact (`postgres_role`) — detects primary vs. replica by checking for `/var/lib/pgsql/standby.signal`

---

### Infrastructure Files

- `metadata.json`: Declares module name (`example-profile_postgresql` v1.0.0), author (Platform Team), two external Puppet module dependencies (`puppetlabs-stdlib ≥9`, `puppetlabs-apt ≥9`), and OS support matrix (Ubuntu 24.04, Debian 12). Migration consideration: OS support matrix directly informs Ansible target inventory; stdlib and apt dependencies map to built-in Ansible modules.
- `hiera.yaml`: Hiera 5 configuration with a two-level hierarchy — OS-family override (`data/os/Debian.yaml`) above a common default (`data/common.yaml`). Migration consideration: translate to Ansible `group_vars/` (e.g., `group_vars/debian.yml`) and `group_vars/all.yml`.
- `data/common.yaml`: Sets `profile_postgresql::version: '16'`. Maps to an Ansible variable `postgresql_version: "16"`.
- `data/os/Debian.yaml`: Provides all Debian-specific parameters — package names (interpolated with version), service name, PGDG repo URL, release codename interpolation, and GPG key ID/URL. Maps to Ansible `group_vars/debian.yml` or role `defaults/main.yml` with `ansible_distribution_release` substitution.
- `lib/facter/postgres_role.rb`: Custom Facter fact that sets `postgres_role` to `primary` or `replica` based on the presence of `/var/lib/pgsql/standby.signal`. Migration consideration: replace with an Ansible `stat` task that sets a variable, or a custom fact in `/etc/ansible/facts.d/`.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper that fetches a URL and parses JSON. Migration consideration: replace with Ansible `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Calls `CompanyInternal::SecretStore.fetch(credential_name)` via `company_internal_lib`. Migration consideration: requires a custom Ansible lookup plugin or integration with a supported secrets backend (HashiCorp Vault, CyberArk, AWS Secrets Manager) depending on what `CompanyInternal::SecretStore` wraps.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron type managing root crontab via shell. Migration consideration: replace with Ansible `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom artifact deployment type (download tarball, extract, write `version.txt`). Migration consideration: replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Custom `!key=value` config-file manager for `/etc/company/app.conf`. Migration consideration: replace with Ansible `lineinfile` (regex `^!key=`) or a custom Jinja2 template if the full file is owned by Ansible.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Wraps the proprietary `schedulerctl` CLI for Enterprise Scheduler registration. Migration consideration: replace with Ansible `command`/`shell` tasks guarded by a `command` check task, or write a custom Ansible module if idempotency is required.

---

### Target Details

- **Operating System**: Debian family — Ubuntu 24.04 LTS and Debian 12 (Bookworm), as declared in `metadata.json` and confirmed by `data/os/Debian.yaml`. APT package management is assumed throughout.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified in the repository. The internal artifact URL (`http://artifacts.internal/`) and internal secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (≥ 9.0.0 < 10.0.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter (`{{ variable | to_json }}`). No additional collection required.
- **puppetlabs-apt (≥ 9.0.0 < 10.0.0)**: Used for `apt::source` to configure the PGDG APT repository with GPG key import. Replace with the `ansible.builtin.deb822_repository` module (Ubuntu 24.04 / Debian 12 support) or `ansible.builtin.apt_key` + `ansible.builtin.apt_repository`. The `ansible.builtin` collection ships with Ansible Core — no extra install needed.
- **PuppetDB (`puppetdb_query`)**: Used to enumerate all `Profile_postgresql` nodes in the estate. There is no direct Ansible equivalent. Replace with a dynamic inventory plugin (e.g., querying a CMDB, AWX/AAP smart inventory, or a custom inventory script) or remove if the node list is only informational.
- **company_internal_lib (Ruby gem)**: Backing library for `mySecretFunction1`. The Ansible replacement depends on what secret backend this gem wraps — this must be clarified with the Platform Team before migration begins.
- **schedulerctl CLI (`/usr/local/bin/schedulerctl`)**: Proprietary binary for Enterprise Scheduler. Must be present on target nodes. Wrap with `ansible.builtin.command` tasks or write a custom Ansible module for full idempotency.
- **Internal artifact server (`http://artifacts.internal/`)**: Used by `myDeploy1` to download `myapp-2.1.0.tar.gz`. The Ansible `get_url` module can replace the download step; ensure network reachability and authentication (if any) are accounted for.

---

### Security Considerations

- **Secret token (`postgres_service_token`)**: Retrieved at catalog compile time by `mySecretFunction1` via `CompanyInternal::SecretStore`. The token is stored in the variable `$service_token` in `init.pp` but its downstream use is not visible in the reviewed files — it may be passed to templates or other resources not present in this module. **Action**: Audit all consumers of `$service_token` before migration; integrate with a supported Ansible secrets backend (HashiCorp Vault lookup plugin `community.hashi_vault.hashi_vault`, AWS Secrets Manager, or equivalent). Never hardcode the token in `group_vars` or playbooks.
- **GPG key for PGDG APT repository**: The key ID (`B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`) and source URL (`https://www.postgresql.org/media/keys/ACCC4CF8.asc`) are stored in plaintext in `data/os/Debian.yaml`. This is acceptable (public key), but the import mechanism must be replicated faithfully in Ansible to prevent unsigned-package warnings or failures.
- **Internal artifact download over plain HTTP**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (no TLS). **Action**: Switch to HTTPS in the Ansible `get_url` task and add a `checksum` parameter to verify artifact integrity.
- **Cron job runs as root**: `myCronProvider1` manages the root user's crontab. The Ansible `cron` module defaults to the current user — explicitly set `user: root` in the task.
- **File permissions on health_check.json**: The Puppet manifest sets `owner: postgres`, `group: postgres`, `mode: 0644`. These must be replicated in the Ansible `file`/`copy`/`template` task.
- **No encrypted data bags or Hiera eyaml detected**: All Hiera data is plaintext YAML. No Puppet-level encryption is in use, which simplifies migration but also means the `postgres_service_token` secret is entirely managed by the external `CompanyInternal::SecretStore` — its security posture is opaque from this repository alone.

---

### Technical Challenges

1. **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The biggest unknown. The Ruby gem `company_internal_lib` is not part of this repository. Its API, authentication mechanism, and backend are unknown. **Mitigation**: Engage the Platform Team to document the secret store's backend before writing any Ansible tasks. If it wraps HashiCorp Vault, use `community.hashi_vault`; if it wraps CyberArk, use `cyberark.conjur`; otherwise write a custom lookup plugin.

2. **PuppetDB live node query (`puppetdb_query`)**: `init.pp` queries PuppetDB at compile time to build `$postgres_nodes` (a list of all PostgreSQL nodes). This pattern has no native Ansible equivalent. **Mitigation**: Determine whether `$postgres_nodes` is actually used downstream (it is assigned but not consumed in the reviewed manifest). If unused, remove it. If needed, replace with an AWX/AAP dynamic inventory group or a custom inventory plugin.

3. **Custom `!key=value` config format (`myFormatType1`)**: The proprietary `/etc/company/app.conf` format uses `!key=value` lines. Ansible's `lineinfile` can manage individual lines with a regex like `^!app-mode=`, but full idempotency requires careful regexp anchoring. **Mitigation**: If Ansible owns the entire file, use a Jinja2 template. If the file is shared with other tools, use `lineinfile` with `regexp: '^!{{ key }}='` and `line: '!{{ key }}={{ value }}'`.

4. **Enterprise Scheduler registration (`mySecretType1` / `schedulerctl`)**: The `schedulerctl` binary is proprietary and must be present on target nodes. The provider implements `exists?`/`create`/`destroy` idempotency. **Mitigation**: Replicate idempotency in Ansible using a `command: schedulerctl query postgres-node` task with `register` + `failed_when`/`changed_when`, followed by a conditional `command: schedulerctl register ...` task. A custom Ansible module would provide cleaner idempotency.

5. **Custom artifact deployment (`myDeploy1`)**: The provider tracks installed version via `version.txt`. **Mitigation**: Use `ansible.builtin.stat` to read `version.txt`, compare with the desired version, and conditionally run `get_url` + `unarchive`. This is straightforward but must preserve the version-file write step for idempotency.

6. **Custom Facter fact (`postgres_role`)**: Downstream playbooks or templates may consume the `postgres_role` fact. **Mitigation**: Replace with an Ansible `stat` task on `/var/lib/pgsql/standby.signal` and set `postgresql_role: "{{ 'replica' if standby_stat.stat.exists else 'primary' }}"`. Alternatively, deploy a static custom fact file via `/etc/ansible/facts.d/postgres_role.fact`.

7. **Hiera hierarchy → Ansible variable precedence**: The two-level Hiera hierarchy (common → OS family) maps naturally to Ansible's `group_vars/all.yml` (common defaults) and `group_vars/debian.yml` (OS-family overrides). The Hiera interpolation `"%{facts.os.distro.codename}-pgdg"` must be replaced with `"{{ ansible_distribution_release }}-pgdg"`.

8. **OS support is Debian-family only**: The module explicitly supports Ubuntu 24.04 and Debian 12. There is no Red Hat / CentOS path. Ansible tasks must guard APT-specific steps with `when: ansible_os_family == "Debian"` if the role is ever extended to other platforms.

---

### Migration Order

1. **Hiera data → Ansible variables** *(low risk, foundational)*
   Translate `data/common.yaml` and `data/os/Debian.yaml` into `group_vars/all.yml` and `group_vars/debian.yml`. Establish variable naming conventions (`postgresql_version`, `postgresql_package_names`, etc.) that all subsequent tasks will consume.

2. **PGDG repository configuration** (`profile_postgresql::repo`) *(low risk)*
   Replace `apt::source` with `ansible.builtin.deb822_repository` (or `apt_key` + `apt_repository`). Validate GPG key import and repo availability on a test node.

3. **Package installation** (`profile_postgresql::install`) *(low risk)*
   Replace `package` resources with `ansible.builtin.apt`. Straightforward once the repo task is validated.

4. **Service management** (`profile_postgresql::service`) *(low risk)*
   Replace `service` resource with `ansible.builtin.service`. Trivial.

5. **Cron job** (`myCronType1`) *(low risk)*
   Replace custom cron type with `ansible.builtin.cron`. Set `user: root`, `hour: 2`, `minute: 30`.

6. **Custom config file management** (`myFormatType1`) *(medium risk)*
   Replace `!key=value` management with `ansible.builtin.lineinfile` tasks or a Jinja2 template for `/etc/company/app.conf`.

7. **Custom Facter fact** (`postgres_role`) *(medium risk)*
   Replace with `ansible.builtin.stat` + `set_fact` or a custom fact script in `/etc/ansible/facts.d/`.

8. **HTTP health-check and file write** (`myFunction1`) *(medium risk)*
   Replace with `ansible.builtin.uri` + `ansible.builtin.copy`/`template` to write `/var/lib/pgsql/health_check.json`.

9. **Artifact deployment** (`myDeploy1`) *(medium risk)*
   Replace with `ansible.builtin.stat` (version check) + `ansible.builtin.get_url` + `ansible.builtin.unarchive` + `ansible.builtin.copy` (version.txt). Switch artifact URL to HTTPS and add checksum verification.

10. **Enterprise Scheduler registration** (`mySecretType1` / `schedulerctl`) *(high risk)*
    Replace with `ansible.builtin.command` tasks (query → conditional register/unregister) or a custom Ansible module. Requires `schedulerctl` to be present on target nodes and its interface to be documented.

11. **Secret retrieval** (`mySecretFunction1`) *(high risk — resolve first, implement last)*
    Identify the backend of `CompanyInternal::SecretStore` and select the appropriate Ansible lookup plugin. Integrate secret retrieval into the role and validate that `postgres_service_token` is consumed correctly. This item should be **investigated in parallel with step 1** even though implementation comes last.

12. **PuppetDB node enumeration** (`puppetdb_query`) *(high risk — clarify scope)*
    Determine whether `$postgres_nodes` is used downstream. If not, remove. If needed, implement via AWX/AAP dynamic inventory or a custom inventory plugin.

---

### Assumptions

1. **`$postgres_nodes` is unused downstream**: The variable is assigned in `init.pp` but no further consumption is visible in the reviewed manifests. It is assumed to be vestigial or used only for logging/reporting. If it drives conditional logic elsewhere, additional investigation is required.

2. **`$service_token` downstream usage is out of scope for this module**: The token is fetched but not visibly consumed within the reviewed files. It is assumed to be passed to an external system or template not present in this repository. The migration plan flags it as a security concern but cannot fully resolve it without broader codebase access.

3. **`company_internal_lib` wraps a known secrets backend**: It is assumed that the Platform Team can identify the underlying secret store (Vault, CyberArk, AWS SSM, etc.) and that an Ansible-compatible integration exists. If the library is entirely proprietary with no standard backend, a custom lookup plugin will need to be developed.

4. **`schedulerctl` will be pre-installed on target nodes**: The binary at `/usr/local/bin/schedulerctl` is treated as a prerequisite. The migration plan does not include tasks to install it; if it must be deployed by Ansible, an additional task or role is required.

5. **The internal artifact server (`http://artifacts.internal/`) is reachable from Ansible control node or target nodes**: Network path and any required authentication are assumed to be handled outside this role.

6. **Single-module repository**: The repository tree shows no Puppetfile, no `environment.conf`, and no additional module directories. It is assumed this is a standalone module repository, not a Puppet control repo. If it is consumed by a control repo, the broader dependency graph of that control repo is out of scope here.

7. **Target Ansible version**: Ansible Core 2.15+ is assumed, which provides `ansible.builtin.deb822_repository` (available since 2.15) and all other built-in modules referenced in this plan.

8. **No Hiera eyaml or encrypted data**: All Hiera data files are plaintext. No decryption keys or eyaml plugins need to be migrated.

9. **PostgreSQL version will remain 16**: The migration targets the same PostgreSQL version as the Puppet module. A version upgrade is out of scope.

10. **The `myapp` artifact version (2.1.0) is hardcoded intentionally**: The version is hardcoded in `init.pp` rather than driven by Hiera. It is assumed this is intentional and will be parameterised as an Ansible variable (`myapp_version`) during migration to allow future updates without code changes.
