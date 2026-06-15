# Setup Guide — CIS-CAT AWX Integration

## Overview

This guide walks through the full setup of the CIS-CAT Pro monthly assessment pipeline in AWX, from first-time configuration through scheduling and credential management.

---

## 1. Verify the Assessor Installation

SSH onto the AWX node and confirm the Assessor is functional:

```bash
ls -la /var/lib/awx/projects/cis_assessor/Assessor/
# Expected: Assessor-CLI.sh, run_assessor.sh, config/, logs/, reports/

# Confirm scripts are executable
test -x /var/lib/awx/projects/cis_assessor/Assessor/Assessor-CLI.sh && echo "OK"
test -x /var/lib/awx/projects/cis_assessor/Assessor/run_assessor.sh && echo "OK"

# Confirm the password file exists
ls /var/lib/awx/projects/cis_assessor/Assessor/config/.assessor_pass
```

---

## 2. Populate the Targets File

Edit `config/assessor_targets.conf` in this repository. Each non-comment line defines one assessment target:

```
# <hostname_or_ip>  <benchmark_xml>  <profile>
192.168.1.10   CIS_Ubuntu_Linux_22.04_LTS_Benchmark.xml   Level 1 - Server
192.168.1.20   CIS_Microsoft_Windows_Server_2022.xml       Level 1 - Member Server
```

After editing, commit and push:

```bash
git add config/assessor_targets.conf
git commit -m "Add initial assessment targets"
git push origin main
```

---

## 3. Create the AWX Custom Credential Type (if not already present)

In AWX → **Credential Types → Add**:

**Name:** `CIS-CAT Assessor`

**Input Configuration (YAML):**
```yaml
fields:
  - id: password
    type: string
    label: Assessor Encrypt Password
    secret: true
required:
  - password
```

**Injector Configuration (YAML):**
```yaml
env:
  ASSESSOR_ENCRYPT_PASSWORD: "{{ password }}"
```

---

## 4. Create the Credential

In AWX → **Credentials → Add**:

| Field | Value |
|---|---|
| Name | `CIS-CAT Assessor Password` |
| Credential Type | `CIS-CAT Assessor` (created above) |
| Assessor Encrypt Password | `<your encrypt password>` |

---

## 5. Add the AWX Project

In AWX → **Projects → Add**:

| Field | Value |
|---|---|
| Name | `cis-cat-awx` |
| Organization | `<your org>` |
| SCM Type | Git |
| SCM URL | `<your Git repo URL>` |
| SCM Branch/Tag/Commit | `main` |
| SCM Update Options | ✅ Clean, ✅ Delete on Update, ✅ Update Revision on Launch |

Save, then click **Sync** to pull the repo.

---

## 6. Create the Job Template

In AWX → **Job Templates → Add**:

| Field | Value |
|---|---|
| Name | `CIS-CAT Pro \| Monthly Assessment` |
| Job Type | Run |
| Inventory | `Demo Inventory` (localhost) or a dedicated localhost inventory |
| Project | `cis-cat-awx` |
| Playbook | `playbooks/cis_cat_monthly.yml` |
| Credentials | `CIS-CAT Assessor Password` |
| Verbosity | `1 (Verbose)` |
| Timeout | `7800` |
| Allow Simultaneous | ❌ |

---

## 7. Add the Monthly Schedule

In the Job Template → **Schedules → Add**:

| Field | Value |
|---|---|
| Name | `Monthly — 1st at 02:00 UTC` |
| Start Date | First of next month |
| Start Time | 02:00:00 UTC |
| Time Zone | UTC |
| Repeat Frequency | Month |
| Run on Day | 1 |

---

## 8. Test Run

Before relying on the schedule, launch the Job Template manually and verify:

1. All pre-flight checks (stat, writable, executable) pass.
2. `run_assessor.sh` runs to completion (watch the async task poll).
3. Reports are generated in `{{ assessor_dir }}/reports/`.
4. Logs are written to `{{ assessor_log_base }}/`.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Assessor-CLI.sh not found` | Wrong `assessor_dir` | Override `assessor_dir` in Extra Vars |
| `not executable` failure | Permissions lost after git sync | `chmod +x` the scripts on the AWX node |
| `ASSESSOR_ENCRYPT_PASSWORD not set` | Credential not attached | Attach the custom credential to the Job Template |
| Assessor exits non-zero | Target unreachable or benchmark mismatch | Check logs in `assessor_log_base` |
| Async timeout | Too many targets for 7200s window | Split targets into multiple Job Templates |
