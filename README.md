# cis-cat-awx

Ansible project for running **CIS-CAT Pro Assessor** monthly assessments via **AWX / Ansible Tower**.

---

## Repository Layout

```
cis-cat-awx/
├── playbooks/
│   └── cis_cat_monthly.yml           # Main assessment playbook
├── scripts/
│   └── run_assessor.sh               # Assessor wrapper — deployed by playbook
├── config/
│   ├── targets_windows.conf          # Windows Server targets
│   ├── targets_linux_group1.conf     # Linux Group 1 targets (web/app)
│   ├── targets_linux_group2.conf     # Linux Group 2 targets (db/infra)
│   └── awx_job_template.yml          # AWX Job Template reference (3 templates)
├── docs/
│   └── setup.md                      # Detailed setup guide
├── .gitignore
└── README.md
```

> **Note:** The CIS-CAT Pro Assessor binaries, JRE, and benchmark XMLs live at
> `/var/lib/awx/projects/cis_assessor/Assessor/` and are **not** tracked here.
> This repo manages the orchestration playbook, the wrapper script, and all target configuration.

### Deployment model

```
Git repo (this)                      AWX node (runtime)
───────────────────────────────      ──────────────────────────────────────────
scripts/run_assessor.sh        →     /var/lib/awx/projects/cis_assessor/
  (synced by playbook on             Assessor/run_assessor.sh
   every Job Template run)

config/targets_*.conf                /var/lib/awx/projects/cis_assessor/
  (read directly from the      →     Assessor/config/targets_*.conf
   AWX project mount)                (path injected via AWX survey)
```

> ⚠️ **`awx_project_dir` must match the real on-disk folder, not the Project's display name.**
> AWX mounts every Project under `/var/lib/awx/projects/` using an internal,
> auto-generated folder name — typically `_<project_id>__<repo_name>` (e.g.
> `_87__cis_assessor_reporting`) — which does **not** match what you typed
> as the Project name in the AWX UI. Verify the actual path with:
> ```
> ls /var/lib/awx/projects/ | grep -i <part of your repo name>
> ```
> and set `awx_project_dir` in `playbooks/cis_cat_monthly.yml` to match exactly.
> This ID changes if the Project is ever deleted and recreated, so re-verify
> after doing so. A mismatch here causes the `Verify Git project source
> script exists` task to fail with a clear error — if you don't see that
> task fail, the path is correct.

---

## Prerequisites

| Requirement | Details |
|---|---|
| AWX / Ansible Tower | 4.x or later |
| CIS-CAT Pro Assessor | Installed and tested at `assessor_dir` |
| Java | Bundled JRE at `assessor_dir/jre/` |
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

Edit the appropriate `config/targets_*.conf` file and add one pipe-delimited line per target:

```
# <config_xml>|<label>|<profile>|<boolean_encrypted>
targets_ubuntu22_prod.xml|web-prod-01|Level 1 - Server|TRUE
targets_win2022.xml|dc01|Level 1 - Domain Controller|FALSE
```

Commit and push the change — AWX pulls the latest on each run.

### 3. Create the AWX Job Templates

Three templates share one playbook. See `config/awx_job_template.yml` for full settings.

| Template Name | Survey Default | Schedule |
|---|---|---|
| CIS-CAT Pro \| Windows Servers | `targets_windows.conf` | 1st @ 02:00 UTC |
| CIS-CAT Pro \| Linux Servers — Group 1 | `targets_linux_group1.conf` | 1st @ 03:00 UTC |
| CIS-CAT Pro \| Linux Servers — Group 2 | `targets_linux_group2.conf` | 1st @ 04:00 UTC |

Each template requires a **Survey** with one question:

| Field | Value |
|---|---|
| Variable name | `survey_targets_config` |
| Type | Text |
| Default | Full path to the matching `targets_*.conf` |

### 4. Attach the Credential

Create a custom AWX credential type that injects `ASSESSOR_ENCRYPT_PASSWORD` as an env var, and attach it to all three Job Templates.

---

## Variables

| Variable | Source | Description |
|---|---|---|
| `assessor_dir` | Playbook default | Path to the Assessor installation on the AWX node |
| `assessor_script` | Playbook default | Points to the deployed `run_assessor.sh` |
| `assessor_log_base` | Playbook default | Log directory (auto-rotated after 90 days) |
| `survey_targets_config` | **AWX Survey** | Full path to the targets `.conf` for this run |
| `ASSESSOR_ENCRYPT_PASSWORD` | AWX Credential | Report encryption password |
| `TARGETS_CONFIG` | Set by playbook | Passed to `run_assessor.sh` from `survey_targets_config` |

---

## Script Management

`scripts/run_assessor.sh` is version-controlled here and **automatically deployed** to the
Assessor directory at the start of every playbook run. This means:

- Script changes are reviewed via Git (PRs / commits)
- The AWX node is always running the latest approved version
- No manual file transfers needed after the initial deploy

---

## Security Notes

- `.assessor_pass` is excluded from Git via `.gitignore` — **never commit secrets**
- Use AWX custom credentials to inject `ASSESSOR_ENCRYPT_PASSWORD`
- The debug password echo (`DEBUG len=... md5=...`) has been removed from the script
- Reports are generated in encrypted form by the Assessor tool

---

## Roadmap

- [ ] Reporting integration (email / dashboard)
- [ ] Per-host benchmark override support
- [ ] Slack / Teams notification on failure
- [ ] Report archival to S3 or network share
