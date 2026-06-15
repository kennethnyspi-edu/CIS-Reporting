# cis-cat-awx

Ansible project for running **CIS-CAT Pro Assessor** monthly assessments via **AWX / Ansible Tower**.

---

## Repository Layout

```
cis-cat-awx/
├── playbooks/
│   └── cis_cat_monthly.yml       # Main assessment playbook
├── config/
│   ├── assessor_targets.conf     # Target hosts + benchmark mappings
│   └── awx_job_template.yml      # AWX Job Template reference config
├── docs/
│   └── setup.md                  # Detailed setup guide
├── .gitignore
└── README.md
```

> **Note:** The CIS-CAT Pro Assessor tool itself lives in a separate path on the AWX node (`/var/lib/awx/projects/cis_assessor/Assessor/`) and is **not** tracked in this repository. Only the orchestration playbook and target configuration are managed here.

---

## Prerequisites

| Requirement | Details |
|---|---|
| AWX / Ansible Tower | 4.x or later |
| CIS-CAT Pro Assessor | Installed and tested at `assessor_dir` |
| Java | Required by Assessor-CLI.sh (on AWX node) |
| AWX Custom Credential | Injects `ASSESSOR_ENCRYPT_PASSWORD` env var |

---

## Quick Start

### 1. Add this repo as an AWX Project

In AWX → **Projects → Add**:

| Field | Value |
|---|---|
| Name | `cis-cat-awx` |
| SCM Type | Git |
| SCM URL | `<your-repo-url>` |
| SCM Branch | `main` |
| Update on Launch | ✅ |

### 2. Configure Target Hosts

Edit `config/assessor_targets.conf` and add one line per target:

```
# HOST                  BENCHMARK XML                              PROFILE
webserver01.corp.lan    CIS_Ubuntu_Linux_22.04_LTS_Benchmark.xml   Level 1 - Server
winserver02.corp.lan    CIS_Microsoft_Windows_Server_2022.xml       Level 1 - Member Server
```

Commit and push the change.

### 3. Create the AWX Job Template

Refer to `config/awx_job_template.yml` for all recommended settings. Key fields:

- **Playbook:** `playbooks/cis_cat_monthly.yml`
- **Inventory:** `localhost` (built-in)
- **Credential:** Custom credential that injects `ASSESSOR_ENCRYPT_PASSWORD`

### 4. Set the Monthly Schedule

In the Job Template → **Schedules → Add**:

- **Name:** `Monthly — 1st of month 02:00 UTC`
- **Start date/time:** first of next month, 02:00 UTC
- **Repeat:** Monthly

---

## Variables

All variables are defined in the playbook. Override via AWX **Extra Variables** if needed.

| Variable | Default | Description |
|---|---|---|
| `assessor_dir` | `/var/lib/awx/projects/cis_assessor/Assessor` | Absolute path to the Assessor installation |
| `assessor_script` | `{{ assessor_dir }}/run_assessor.sh` | Wrapper script called by the playbook |
| `assessor_log_base` | `{{ assessor_dir }}/logs` | Log directory (rotated after 90 days) |
| `targets_config` | `{{ assessor_dir }}/../config/assessor_targets.conf` | Target host config file |

---

## Log Rotation

Logs older than **90 days** are automatically deleted at the end of each successful run. Log directories are expected to be named by date (e.g. `2024-01-01/`) under `assessor_log_base`.

---

## Security Notes

- The `.assessor_pass` file is excluded from Git via `.gitignore` — **never commit secrets**.
- Use AWX custom credentials to inject `ASSESSOR_ENCRYPT_PASSWORD` rather than hardcoding it.
- Reports are generated in encrypted form by the Assessor tool and stored locally on the AWX node.

---

## Roadmap

- [ ] Reporting integration (email / dashboard)
- [ ] Per-host benchmark override support
- [ ] Slack / Teams notification on failure
- [ ] Report archival to S3 or network share
