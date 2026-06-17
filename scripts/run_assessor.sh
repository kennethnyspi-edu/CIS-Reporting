#!/bin/bash
# run_assessor.sh
#
# CIS-CAT Pro Assessor — wrapper script for AWX-driven monthly assessments.
#
# Managed in Git: cis-cat-awx/scripts/run_assessor.sh
# Deploy path:    /var/lib/awx/projects/cis_assessor/Assessor/run_assessor.sh
#
# Environment variables (injected by Ansible playbook):
#   ASSESSOR_ENCRYPT_PASSWORD  — report encryption password.
#                                Required only if at least one target line
#                                in TARGETS_FILE has <boolean_encrypted>=TRUE.
#   TARGETS_CONFIG             — full path to the targets .conf file (optional;
#                                falls back to CONFIG_DIR/assessor_targets.conf)
#   PER_TARGET_TIMEOUT_SECONDS — max seconds to wait for a single target's
#                                Assessor-CLI run before killing it and
#                                moving on to the next target. Defaults to
#                                1800 (30 minutes) if unset.
#
# Each targets file line format (pipe-delimited, 4 fields):
#   <config_xml>|<label>|<profile>|<boolean_encrypted>
#
#   <boolean_encrypted>  TRUE  -> this target's config_xml is encrypted;
#                                 Assessor is run with -fp <password>
#                         FALSE -> this target's config_xml is plain;
#                                 Assessor is run without -fp
#
# Example:
#   targets_ubuntu22_prod.xml|web-prod-01|Level 1 - Server|TRUE
#   targets_win2022.xml|dc01|Level 1 - Domain Controller|FALSE

# ── Paths ─────────────────────────────────────────────────────────────────
# Detect script location dynamically — works regardless of call location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSESSOR_DIR="$SCRIPT_DIR"
ASSESSOR_CLI="${ASSESSOR_DIR}/Assessor-CLI.sh"
CONFIG_DIR="${ASSESSOR_DIR}/config"

# ── Targets file ──────────────────────────────────────────────────────────
# Prefer TARGETS_CONFIG injected by the Ansible playbook (survey-driven).
# Fall back to the legacy default so the script works standalone too.
TARGETS_FILE="${TARGETS_CONFIG:-${CONFIG_DIR}/assessor_targets.conf}"

# ── Per-target timeout ───────────────────────────────────────────────────
# Caps how long Assessor-CLI is allowed to run against a single target
# before being killed, so one unreachable/hanging host (e.g. a WinRM
# connection that never completes) doesn't block the rest of the run.
# Defaults to 1800s (30 min) if unset or non-numeric.
PER_TARGET_TIMEOUT_SECONDS="${PER_TARGET_TIMEOUT_SECONDS:-1800}"
if ! [[ "$PER_TARGET_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  PER_TARGET_TIMEOUT_SECONDS=1800
fi

# ── Timestamp & logging ───────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${ASSESSOR_DIR}/logs/assessor_${TIMESTAMP}"
REPORT_FILE="${LOG_DIR}/assessor_summary_${TIMESTAMP}.txt"

# ── Password ──────────────────────────────────────────────────────────────
# Loaded once, up front. Whether it's actually *required* depends on whether
# any target line in TARGETS_FILE requests encryption (checked after the
# targets file is parsed, below).
# Prefer env var (injected by AWX custom credential).
# Fall back to the protected file for standalone/manual runs.
#
# File created with:
#   echo -n 'yourpassword' > config/.assessor_pass
#   chmod 640 config/.assessor_pass
#   chown root:1000 config/.assessor_pass
ENCRYPT_PASSWORD="${ASSESSOR_ENCRYPT_PASSWORD:-$(cat "${ASSESSOR_DIR}/config/.assessor_pass" 2>/dev/null)}"

# ── Java runtime ──────────────────────────────────────────────────────────
export JAVA_HOME="${ASSESSOR_DIR}/jre"
export PATH="${ASSESSOR_DIR}/jre/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── Counters ──────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ── Create log directory ──────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

# ── Logging helpers ───────────────────────────────────────────────────────
log_section() {
  echo ""                               | tee -a "$REPORT_FILE"
  echo "══════════════════════════════" | tee -a "$REPORT_FILE"
  echo "  $1"                           | tee -a "$REPORT_FILE"
  echo "══════════════════════════════" | tee -a "$REPORT_FILE"
}
log_pass() { echo "  ✅ PASS | $1" | tee -a "$REPORT_FILE"; ((PASS_COUNT++)); }
log_fail() { echo "  ❌ FAIL | $1" | tee -a "$REPORT_FILE"; ((FAIL_COUNT++)); }
log_skip() { echo "  ⚠️  SKIP | $1" | tee -a "$REPORT_FILE"; ((SKIP_COUNT++)); }
log_info() { echo "  ℹ️  INFO | $1" | tee -a "$REPORT_FILE"; }

# ── Header ────────────────────────────────────────────────────────────────
echo "========================================" | tee -a "$REPORT_FILE"
echo " CIS-CAT Pro Assessor — Monthly Run"     | tee -a "$REPORT_FILE"
echo " Started:      $(date)"                   | tee -a "$REPORT_FILE"
echo " Assessor dir: $ASSESSOR_DIR"             | tee -a "$REPORT_FILE"
echo " Targets file: $TARGETS_FILE"             | tee -a "$REPORT_FILE"
echo " Per-target timeout: ${PER_TARGET_TIMEOUT_SECONDS}s" | tee -a "$REPORT_FILE"
echo " Log dir:      $LOG_DIR"                  | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"

# ── Prerequisite checks ───────────────────────────────────────────────────
if [ ! -f "$ASSESSOR_CLI" ]; then
  echo "❌ FATAL: Assessor-CLI.sh not found at $ASSESSOR_CLI"
  exit 1
fi

if [ ! -x "$ASSESSOR_CLI" ]; then
  echo "❌ FATAL: Assessor-CLI.sh is not executable"
  exit 1
fi

if [ ! -f "${ASSESSOR_DIR}/jre/bin/java" ]; then
  echo "❌ FATAL: Bundled JRE not found at ${ASSESSOR_DIR}/jre/bin/java"
  exit 1
fi

if ! command -v timeout > /dev/null 2>&1; then
  echo "❌ FATAL: 'timeout' command not found (coreutils)."
  echo "   Per-target timeout enforcement requires it. Install coreutils"
  echo "   in the AWX execution environment, or remove the timeout wrapper"
  echo "   from this script if running unbounded is acceptable."
  exit 1
fi

if [ ! -f "$TARGETS_FILE" ]; then
  echo "❌ FATAL: Targets file not found at $TARGETS_FILE"
  echo "   Set TARGETS_CONFIG env var or ensure the default file exists."
  exit 1
fi

# ── Load targets ──────────────────────────────────────────────────────────
# Skip comment lines (# ...) and blank lines
mapfile -t TARGET_LINES < <(grep -v '^\s*#' "$TARGETS_FILE" | grep -v '^\s*$')

TOTAL=${#TARGET_LINES[@]}

if [ "$TOTAL" -eq 0 ]; then
  echo "❌ FATAL: No targets found in $TARGETS_FILE"
  exit 1
fi

# ── Pre-flight: verify password is available if ANY target needs it ────────
# Avoids burning through several targets before failing on a later one.
NEEDS_PASSWORD="FALSE"
for target_line in "${TARGET_LINES[@]}"; do
  encrypted_flag=$(echo "$target_line" | awk -F'|' '{print $4}' | tr -d ' \r' | tr '[:lower:]' '[:upper:]')
  if [ "$encrypted_flag" = "TRUE" ]; then
    NEEDS_PASSWORD="TRUE"
    break
  fi
done

if [ "$NEEDS_PASSWORD" = "TRUE" ] && [ -z "$ENCRYPT_PASSWORD" ]; then
  echo "❌ FATAL: At least one target requires encryption (4th field = TRUE),"
  echo "   but no encryption password is available."
  echo "   Set ASSESSOR_ENCRYPT_PASSWORD env var, or create:"
  echo "   ${ASSESSOR_DIR}/config/.assessor_pass"
  exit 1
fi

CURRENT=0

log_section "RUNNING ASSESSMENTS ($TOTAL targets)"

# ── Main assessment loop ──────────────────────────────────────────────────
for target_line in "${TARGET_LINES[@]}"; do
  ((CURRENT++))

  config_file=$(echo "$target_line" | awk -F'|' '{print $1}' | tr -d ' \r')
  label=$(echo "$target_line"       | awk -F'|' '{print $2}' | tr -d ' \r')
  profile=$(echo "$target_line"     | awk -F'|' '{print $3}' | tr -d ' \r')
  encrypted_flag=$(echo "$target_line" | awk -F'|' '{print $4}' | tr -d ' \r' | tr '[:lower:]' '[:upper:]')

  CONFIG_PATH="${CONFIG_DIR}/${config_file}"
  TARGET_LOG="${LOG_DIR}/${label}_${TIMESTAMP}.log"

  log_section "[$CURRENT/$TOTAL] $label — $profile"
  log_info "Config:    $config_file"
  log_info "Encrypted: ${encrypted_flag:-<missing>}"
  log_info "Log:       $TARGET_LOG"

  if [ ! -f "$CONFIG_PATH" ]; then
    log_skip "Config file not found: $CONFIG_PATH"
    continue
  fi

  if [ "$encrypted_flag" != "TRUE" ] && [ "$encrypted_flag" != "FALSE" ]; then
    log_skip "Invalid or missing <boolean_encrypted> value ('$encrypted_flag') — expected TRUE or FALSE"
    continue
  fi

  log_info "Starting at $(date)"

  # Build the Assessor command — only add -fp when this target is encrypted.
  # Wrapped with `timeout` so a hung/unreachable host (e.g. WinRM never
  # completing the handshake) doesn't block the rest of the targets list.
  # --kill-after gives a 30s grace period: timeout sends SIGTERM first,
  # then SIGKILL if the process (or any child Java process) ignores it.
  if [ "$encrypted_flag" = "TRUE" ]; then
    log_info "Mode:      encrypted (-fp)"
    log_info "Timeout:   ${PER_TARGET_TIMEOUT_SECONDS}s"
    timeout --kill-after=30 "${PER_TARGET_TIMEOUT_SECONDS}s" \
      bash "$ASSESSOR_CLI" \
      -v \
      -cfg "$CONFIG_PATH" \
      -fp "$ENCRYPT_PASSWORD" \
      > "$TARGET_LOG" 2>&1
  else
    log_info "Mode:      plain (no -fp)"
    log_info "Timeout:   ${PER_TARGET_TIMEOUT_SECONDS}s"
    timeout --kill-after=30 "${PER_TARGET_TIMEOUT_SECONDS}s" \
      bash "$ASSESSOR_CLI" \
      -v \
      -cfg "$CONFIG_PATH" \
      > "$TARGET_LOG" 2>&1
  fi

  EXIT_CODE=$?
  log_info "Finished at $(date) — exit code: $EXIT_CODE"

  # `timeout` exits 124 specifically when it had to kill the process for
  # running past the deadline — distinguish that from a normal failure.
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "  ⏱️  TIMEOUT (>${PER_TARGET_TIMEOUT_SECONDS}s) for ${label}; process killed, continuing to next target" >> "$TARGET_LOG"
  fi

  if [ $EXIT_CODE -eq 0 ]; then
    log_pass "$label assessment completed successfully"

    # Extract scoring summary from the assessment log
    SCORE_EARNED=$(grep "Score Earned:"        "$TARGET_LOG" | tail -1 | awk -F: '{print $2}' | tr -d ' \r')
    SCORE_MAX=$(grep "Maximum Available:"      "$TARGET_LOG" | tail -1 | awk -F: '{print $2}' | tr -d ' \r')
    SCORE_PCT=$(grep "Total:" "$TARGET_LOG"    | grep "%" | tail -1 | awk '{print $2}' | tr -d ' \r')
    TOTAL_PASS=$(grep "Total Pass:"            "$TARGET_LOG" | tail -1 | awk -F: '{print $2}' | tr -d ' \r')
    TOTAL_FAIL=$(grep "Total Fail:"            "$TARGET_LOG" | tail -1 | awk -F: '{print $2}' | tr -d ' \r')
    TOTAL_RESULTS=$(grep "Total # of Results:" "$TARGET_LOG" | tail -1 | awk -F: '{print $2}' | tr -d ' \r')

    log_info "Score:     ${SCORE_EARNED} / ${SCORE_MAX} (${SCORE_PCT})"
    log_info "Pass:      ${TOTAL_PASS}  |  Fail: ${TOTAL_FAIL}  |  Total rules: ${TOTAL_RESULTS}"

  else
    if [ "$EXIT_CODE" -eq 124 ]; then
      log_fail "$label assessment TIMED OUT after ${PER_TARGET_TIMEOUT_SECONDS}s — process killed, check $TARGET_LOG"
    else
      log_fail "$label assessment FAILED — check $TARGET_LOG"
    fi
    echo "  --- Last 10 lines of log ---" | tee -a "$REPORT_FILE"
    tail -10 "$TARGET_LOG" | while read -r line; do
      echo "  $line" | tee -a "$REPORT_FILE"
    done
  fi

done

# ── Final summary ─────────────────────────────────────────────────────────
log_section "SUMMARY"
echo "  Targets file : $TARGETS_FILE"  | tee -a "$REPORT_FILE"
echo "  Total        : $TOTAL"         | tee -a "$REPORT_FILE"
echo "  ✅ Passed    : $PASS_COUNT"    | tee -a "$REPORT_FILE"
echo "  ❌ Failed    : $FAIL_COUNT"    | tee -a "$REPORT_FILE"
echo "  ⚠️  Skipped   : $SKIP_COUNT"   | tee -a "$REPORT_FILE"
echo "  Completed    : $(date)"        | tee -a "$REPORT_FILE"
echo "  Report       : $REPORT_FILE"   | tee -a "$REPORT_FILE"

[ $FAIL_COUNT -gt 0 ] && exit 1 || exit 0
