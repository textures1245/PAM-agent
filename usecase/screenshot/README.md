# CIS PAM Capture Agent - Usage Guide

## Overview

Automated evidence collection tool for CIS compliance validation across multiple Ubuntu VMs.

## Scripts

1. **data-adapter.sh** - Converts `user_credentials_clean.json` to bash variables
2. **termshot.sh** - Utility functions for SSH and termshot operations
3. **cis-pam-capture-agent.sh** - Main orchestration script

## Prerequisites

- `jq` - JSON processor (auto-installed if missing)
- `ssh` / `scp` - SSH client
- `python3` with `pip`
- SSH access to target VMs

## Quick Start

### 1. Prepare JSON File

Ensure `user_credentials_clean.json` exists in project root:
```
/pam-automation/user_credentials_clean.json
```

### 2. Run Capture Agent

```bash
cd /Users/phakh/Desktop/shell-scripts/pam-automation/usecase/screenshot
./cis-pam-capture-agent.sh
```

### 3. Provide Inputs

- **SSH Username**: Username for connecting to VMs (required)
- **SSH Key Path**: Path to private key (optional, press Enter to skip)

Example:
```
SSH Username: root
SSH Key Path: ~/.ssh/lab_cnx_key_03
```

## What It Does

### Phase 1: Initialization
- Checks prerequisites
- Runs data adapter to parse JSON
- Loads utility functions

### Phase 2: VM Processing (Sequential)

For each VM:
1. Tests SSH connection
2. Gets VM hostname (using `hostname -f`)
3. Creates folder: `{VM_NAME},{PRIVATE_IP}`
4. Installs termshot binary
5. Captures 5 screenshots:
   - `01_chage_all_users.png` - Password expiry for all users
   - `02_home_list.png` - Home directory listing
   - `03_ssh_pwd_policy.png` - SSH config & password policy
   - `04_publickey_logs.png` - SSH key authentication logs
   - `05_sudo_logs.png` - Sudo session logs
6. Uninstalls termshot
7. Downloads screenshots to local machine
8. Cleans up remote folder

### Phase 3: Report Generation
- Creates Excel file with embedded screenshots
- Maps images to appropriate columns
- Saves as `cis_pam_evidence_{timestamp}.xlsx`

## Output Files

```
/usecase/screenshot/
├── VM1,192.168.1.31/              # Screenshot folders (kept)
│   ├── 01_chage_all_users.png
│   ├── 02_home_list.png
│   ├── 03_ssh_pwd_policy.png
│   ├── 04_publickey_logs.png
│   └── 05_sudo_logs.png
├── VM2,192.168.1.32/
│   └── ...
├── cis_pam_evidence_20251118_143022.xlsx  # Excel report
├── cis_capture_20251118_143022.log        # Execution log
└── termshot-data.sh                        # Generated data (temporary)
```

## Excel Report Structure

| Column | Content | Screenshot |
|--------|---------|------------|
| A | VM Name | - |
| B | OS | - |
| C | Private IP | - |
| D | Public IP | - |
| E | Password policy (Expired) | 01_chage_all_users.png |
| F | List users | 02_home_list.png |
| G | Permit root login | 03_ssh_pwd_policy.png |
| H | Log Login ด้วย Private Key | 04_publickey_logs.png |
| I | Log sudo su | 05_sudo_logs.png |
| J | Remark | - |

## Commands Captured

1. **Password Expiry (Chained)**:
   ```bash
   chage -l user1 || true && chage -l user2 || true && ...
   ```

2. **Home Directories**:
   ```bash
   ls -l /home
   ```

3. **SSH & Password Policy**:
   ```bash
   sudo grep -E "PermitRootLogin|PasswordAuthentication|..." /etc/ssh/sshd_config &&
   grep -E "minlen|dcredit|..." /etc/security/pwquality.conf
   ```

4. **Publickey Auth Logs**:
   ```bash
   sudo zgrep -h 'Accepted publickey' /var/log/auth.log* |
   sed 's/RSA SHA256:[^ ]*/RSA/' | sed 's/ED25519 SHA256:[^ ]*/ED25519/' |
   awk '!seen[$7]++' | grep -E 'user1|user2|...'
   ```

5. **Sudo Session Logs**:
   ```bash
   sudo zgrep 'sudo:session' /var/log/auth.log* |
   grep 'root(uid=0) by' |
   awk '{split($NF, a, "("); if (!seen[a[1]]++) print}' |
   grep -E 'user1|user2|...'
   ```

## Termshot Installation

- **Source**: https://github.com/homeport/termshot/releases/latest
- **Version**: v0.6.0
- **Binary**: `termshot_linux_amd64` or `termshot_linux_arm64`
- **Install Path**: `/usr/local/bin/termshot`
- **Auto-cleanup**: Removed after each VM

## Error Handling

- **SSH Failure**: Skips VM, continues to next
- **Command Failure**: Uses `|| true` pattern to continue
- **Missing Screenshots**: Logs warning, continues processing
- **SCP Failure**: Logs error, continues to next VM

## Testing

Test with provided VM:
```bash
ssh -i ~/.ssh/lab_cnx_key_03 root@34.126.138.222
```

## Troubleshooting

### Issue: "Cannot connect to VM"
- Verify SSH credentials
- Check network connectivity
- Ensure VM is running

### Issue: "termshot installation failed"
- Check internet connectivity on VM
- Verify `/usr/local/bin` is writable
- Check VM architecture (amd64/arm64)

### Issue: "No screenshot folders found"
- Verify SSH connection succeeded
- Check log file for errors
- Ensure termshot captured images

### Issue: "Python dependencies missing"
```bash
pip3 install openpyxl pillow
```

## Manual Execution

### Run Data Adapter Only:
```bash
./data-adapter.sh ../../user_credentials_clean.json
```

### Test Termshot Functions:
```bash
source termshot.sh
test_ssh_connection "root" "192.168.1.31" "~/.ssh/key"
```

## Integration with pam-agent-v4.sh

Add to main menu:
```bash
9) 📸 ตรวจสอบความถูกต้องตามมาตรฐาน CIS (Future)
10) 📷 แคปหลักฐานตามมาตรฐาน CIS
```

## Log Files

All operations logged to:
```
cis_capture_{timestamp}.log
```

View logs:
```bash
tail -f cis_capture_20251118_143022.log
```

## Security Notes

- SSH keys should have 600 permissions
- Never commit SSH keys to repository
- Review screenshots before sharing
- Clean up sensitive data after compliance check

## Support

For issues or questions, refer to:
- SPEC.md - Complete technical specification
- Project documentation
- Execution logs

---

**Version**: 1.0  
**Last Updated**: November 18, 2025  
**Author**: PAM Automation Team
