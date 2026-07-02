# Features

This document consolidates all password management and task management features for the Tip platform.

## Password Manager Features

### Overview

The Password Manager is Tip's core secure storage component for managing passwords with encryption, flexible organization, and team sharing capabilities.

### Data Model

#### Password Structure
```go
type Password struct {
    ID           string            `json:"id"`            // Unique identifier
    Name         string            `json:"name"`          // Service/app name
    Username     string            `json:"username"`      // Login username/email
    Password     string            `json:"password"`      // Encrypted password
    URL          string            `json:"url"`           // Associated website/app
    Notes        string            `json:"notes"`         // Additional notes (encrypted)
    Category     string            `json:"category"`      // Work, Personal, Development, Finance
    Tags         []string          `json:"tags"`          // Custom tags
    CreatedAt    time.Time         `json:"created_at"`    // Creation timestamp
    UpdatedAt    time.Time         `json:"updated_at"`    // Last modification
    LastUsed     time.Time         `json:"last_used"`     // Last accessed
    LastModifiedBy string          `json:"last_modified_by"` // (remote mode)
    CustomFields map[string]string `json:"custom_fields"` // Extra fields (encrypted)
    History      []PasswordVersion `json:"history"`       // Password history (5 versions)
}

type PasswordVersion struct {
    Password  string    `json:"password"`
    UpdatedAt time.Time `json:"updated_at"`
}
```

### Core Features

#### 1. Password CRUD Operations

##### Create Passwords
```bash
# Basic password entry (prompts for password)
tip password add --name=github

# With username
tip password add --name=github --username=alice

# With all details
tip password add --name=github \
  --username=alice@example.com \
  --url=https://github.com/login \
  --category=development \
  --notes="Personal GitHub account"

# Auto-open browser after adding (future)
tip password add --name=github --url=https://github.com --open
```

##### Read/Get Passwords
```bash
# Get password details (returns decrypted)
tip password get --name=github

# List all passwords
tip password list

# List passwords in specific category
tip password list --category=work
tip password list --category=development

# Show only passwords (not full details)
tip password list --format=compact
```

##### Update Passwords
```bash
# Edit password entry
tip password edit --name=github --username=newuser

# Update password
tip password edit --name=github --password-prompt  # Interactive prompt

# Update other fields
tip password edit --name=github --notes="Updated notes"
tip password edit --name=github --category=work
tip password edit --name=github --url="https://new-url.com"

# Update custom fields
tip password edit --name=github --custom field1=value1 field2=value2
```

##### Delete Passwords
```bash
# Delete single password
tip password delete --name=github --confirm

# Delete without confirmation prompt
tip password delete --name=github --force

# Bulk delete by category
tip password delete --category=finance --confirm
```

#### 2. Password Generation

Password generation with customizable rules:

##### Basic Generation
```bash
# Generate default password (16 chars, mixed case, numbers, symbols)
tip password generate

# Specify length
tip password generate --length=32
tip password generate --length=64

# Only letters
tip password generate --no-numbers --no-symbols

# Passphrase (easier to remember)
tip password generate --passphrase --words=4
# Example: "correct-horse-battery-staple"

# PIN/numeric only
tip password generate --digits-only --length=6

# Copy to clipboard directly
tip password generate --length=24 --copy
```

##### Advanced Generation Options
```bash
# No ambiguous characters (avoid 0/O, 1/l, etc.)
tip password generate --no-ambiguous

# Exclude specific characters
tip password generate --exclude="!@#"

# Require specific character types
tip password generate --require-uppercase --require-numbers

# Symbol-heavy (for complex requirements)
tip password generate --special --length=20

# Use specific character sets
tip password generate --charset="abcdefghijklmnopqrstuvwxyz0123456789"
```

##### Generate and Save
```bash
# Generate and immediately save to password entry
tip password add --name=github --generate --username=alice

# Generate and copy to clipboard
tip password generate --copy | tip password add --name=github --stdin

# Interactive generation and save
tip password generate --interactive
```

#### 3. Password Strength Evaluation

##### Strength Analysis
```bash
# Check password strength
tip password strength --password="myPassword123!"
# Output: Strong (Score: 85/100)

# Analyze saved password
tip password get --name=github --strength

# Check against common breaches
tip password check --name=github  # Warns if in known breach databases

# Password requirements
tip password requirements --name=github  # Shows specific requirements for service
```

##### Strength Criteria
- Length (8-16-20+ characters)
- Character variety (upper, lower, numbers, symbols)
- Not in common password lists
- Not matching username
- No dictionary words
- No sequential patterns (123, abc, etc.)

#### 4. Password History

Keep track of password changes:

```bash
# View password history
tip password history --name=github

# Show last 5 password changes
tip password history --name=github --limit=5

# Restore previous password
tip password restore --name=github --version=2

# Clear history
tip password clear-history --name=github --confirm

# View change dates
tip password history --name=github --timestamps
```

#### 5. Search and Discovery

Search capabilities:

```bash
# Search by name
tip password search --query=github

# Search by username
tip password search --username=alice

# Search by URL/domain
tip password search --url="github.com"

# Search by category
tip password list --category=work

# Search by tags
tip password list --tag=important

# Advanced search (all matches)
tip password search --query="auth" --search-notes --search-usernames

# Case-insensitive fuzzy matching
tip password search --query=git
# Returns: github, gitlab, gitea, etc.

# Multiple criteria
tip password search --query="api" --category=development --tag=deprecated
```

#### 6. Categories

Organize passwords by type:

Predefined categories:
- **Work** - Work-related credentials
- **Personal** - Personal accounts
- **Development** - Dev tools, APIs, SDKs
- **Finance** - Banking, payment services

##### Category Management
```bash
# List categories
tip password category list

# Add custom category
tip password category add --name=freelance
tip password category add --name=healthcare
tip password category add --name=legal

# Assign category when adding
tip password add --name=google --category=personal

# Move password to category
tip password edit github --category=development

# List all passwords in category
tip password list --category=work

# Rename category
tip password category rename --old=personal --new=home

# Delete category
tip password category delete --name=freelance --move-to=personal
```

#### 7. Tags

Flexible labeling beyond categories:

```bash
# Add tags when creating
tip password add --name=github --tag="mfa" --tag="important"

# Add tags to existing password
tip password tag add --name=github --tag=security
tip password tag add --name=github --tag=2fa

# Remove tag
tip password tag remove --name=github --tag=deprecated

# List all tags
tip password tag list

# Filter by tag
tip password list --tag="mfa"
tip password list --tag="backup"

# Multiple tags
tip password list --tag="important,security"
```

Common tags:
- `mfa` - Multi-factor authentication enabled
- `shared` - Password shared with team
- `expiring` - Password needs to be changed soon
- `security` - Security-critical account
- `backup` - Backup account
- `deprecated` - Old/unused account
- `important` - Critical account
- `review` - Needs review/update

#### 8. Custom Fields

Add custom information to passwords:

```bash
# Add custom fields when creating
tip password add --name=aws \
  --custom account-id=123456789 \
  --custom mfa-device=arn:aws:iam::...

# Add custom field to existing
tip password edit --name=github --custom field-name="field value"

# View custom fields
tip password get --name=github --verbose

# Remove custom field
tip password edit --name=github --remove-custom field-name

# Examples of custom fields
--custom security_question="Your mother's maiden name?"
--custom backup_codes="code1, code2, code3..."
--custom recovery_email="backup@example.com"
--custom phone_number="555-1234"
```

#### 9. Clipboard Integration

Secure clipboard handling:

```bash
# Copy password to clipboard
tip password copy --name=github
# Message: "Password copied to clipboard. Expires in 30 seconds."

# Copy with extended timeout
tip password copy --name=github --timeout=60

# Copy username
tip password copy --name=github --username

# Copy custom field
tip password copy --name=github --field=account-id

# Paste and add password
tip password add --paste-username --paste-password

# Clear clipboard
tip password clear-clipboard

# Auto-clear on app exit
# Configured in security settings
```

#### 10. Secure Notes

Store encrypted notes with passwords:

```bash
# Add notes when creating
tip password add --name=bank \
  --notes="Branch: Downtown, Account: 12345"

# Edit notes
tip password edit --name=github --notes="2FA: SMS to 555-0123"

# View notes
tip password get --name=github --notes

# Notes are fully encrypted and separate from passwords

# Examples
tip password add --name=corporate-vpn \
  --notes="VPN Key: <key>\nServer: vpn.corp.com:443"

tip password add --name=email \
  --notes="Recovery email: backup@example.com\nSecond email: secondary@example.com"
```

#### 11. Sharing (Remote Mode Only)

Share passwords securely with team members:

```bash
# Share with single user
tip password share --name=github --user=alice@example.com

# Share with multiple users
tip password share --name=github --user=alice@example.com --user=bob@example.com

# Share with read-only access
tip password share --name=github --user=alice@example.com --read-only

# Share with time limit
tip password share --name=github --user=alice@example.com --expires="7 days"

# View who has access
tip password access --name=github

# Revoke access
tip password share --name=github --revoke --user=alice@example.com

# Shared passwords show indicator
tip password list --shared
```

##### Sharing Workflow
1. Password owner initiates share
2. Recipient receives notification
3. Recipient can view/use password
4. Owner can revoke at any time
5. All access is logged

#### 12. Import/Export

Move passwords in and out:

##### Export
```bash
# Export all passwords (encrypted JSON)
tip export passwords --format=json > backup.json

# Export specific category
tip export passwords --category=work --format=json

# Export as CSV (with warning about security)
tip export passwords --format=csv --warning

# Export with password history
tip export passwords --include-history

# Encrypt export with second password
tip export passwords --encrypt-with="export-password"
```

##### Import
```bash
# Import from backup
tip import --file=backup.json

# Import from CSV
tip import --file=passwords.csv

# Import from other password managers
tip import --from=1password --file=backup.agilekeychain
tip import --from=bitwarden --file=export.json
tip import --from=lastpass --file=export.csv

# Merge with existing (skip duplicates)
tip import --file=backup.json --merge

# Merge and override
tip import --file=backup.json --merge --override

# Preview before importing
tip import --file=backup.json --dry-run
```

##### Supported Import Formats
- JSON (Tip format)
- CSV (standard format)
- 1Password `.agilekeychain`
- Bitwarden JSON
- LastPass CSV
- Firefox exported passwords

#### 13. Security Analysis

##### Audit and Compliance
```bash
# Check for weak passwords
tip password audit --strength=low

# Find duplicate passwords (security risk)
tip password audit --duplicates

# Check for credentials in breaches
tip password audit --breach-check

# Passwords not changed recently
tip password audit --last-changed="more than 90 days"

# Unused passwords
tip password audit --unused="more than 6 months"

# Generate audit report
tip password audit --report > security_audit.txt
```

#### 14. Vault Management

Organize passwords and tasks into separate isolated containers:

##### Vault Data Model
```go
type Vault struct {
    ID          string      `json:"id"`           // Unique identifier
    Name        string      `json:"name"`         // Vault name (e.g., "work", "personal")
    CreatedAt   time.Time   `json:"created_at"`  // Creation timestamp
    UpdatedAt   time.Time   `json:"updated_at"`  // Last modification
    Description string      `json:"description"`  // Optional description
    IsDefault   bool        `json:"is_default"`  // Default vault flag
    Metadata    VaultMeta   `json:"metadata"`     // Vault settings and info
    Passwords   []Password  `json:"passwords"`   // Encrypted passwords
    Tasks       []Task      `json:"tasks"`        // Tasks in vault
}

type VaultMeta struct {
    Version         int               `json:"version"`          // Vault format version
    LastBackup      time.Time         `json:"last_backup"`     // Last backup timestamp
    AutoLockTimeout int               `json:"auto_lock"`       // Auto-lock timeout in minutes
    Tags            []string          `json:"tags"`            // Vault tags
    CustomFields    map[string]string `json:"custom_fields"`   // User-defined fields
}
```

##### Create Vaults
```bash
# Create a new vault
tip vault init --name=work

# Create vault with description
tip vault init --name=work --description="Work-related passwords and tasks"

# Create vault with tags
tip vault init --name=finance --tag=banking --tag=important

# Create default vault
tip vault init --name=personal --default
```

##### List Vaults
```bash
# List all vaults
tip vault list

# Show vault details
tip vault list --verbose
# Output:
# NAME       | DEFAULT | PASSWORDS | TASKS | LAST UPDATED
# -----------|---------|-----------|-------|--------------
# personal   | *       | 45        | 12    | 2025-02-15
# work       |         | 23        | 8     | 2025-02-14
# finance    |         | 15        | 3     | 2025-02-10
```

##### Switch Vaults
```bash
# Switch to a different vault
tip vault switch --name=work

# Verify current vault
tip vault info

# Switch using global flag (without changing default)
tip --vault=finance password list
```

##### Delete Vaults
```bash
# Delete empty vault
tip vault delete --name=old-project --confirm

# Delete vault and move contents to another
tip vault delete --name=archive --move-to=personal

# Force delete (with warning)
tip vault delete --name=test-vault --force
```

##### Vault Info
```bash
# Show current vault details
tip vault info
# Output:
# Vault: personal
# Default: yes
# Created: 2025-01-01
# Updated: 2025-02-15
# Passwords: 45
# Tasks: 12
# Auto-lock: 15 minutes
# Last backup: 2025-02-10
```

##### Vault Backup and Restore
```bash
# Backup vault to file
tip vault backup --path=personal --output=~/.tip/backups/personal-2025-02-15.bak

# Backup all vaults
tip vault backup --path=all --output=~/.tip/backups/

# Restore vault from backup
tip vault restore --path=~/.tip/backups/personal-2025-02-15.bak

# Restore with new name
tip vault restore --path=~/.tip/backups/personal.bak --name=personal-restored
```

##### Move Items Between Vaults
```bash
# Move password to another vault
tip password move --name=github --from=personal --to=work

# Move multiple passwords
tip password move --category=personal --to=archive

# Move tasks between vaults
tip task move --status=completed --from=personal --to=archive
```

##### Vault Metadata Management
```bash
# Set vault description
tip vault edit --name=work --description="Client projects and credentials"

# Add tags to vault
tip vault tag add --name=work --tag=client-project

# Remove tags
tip vault tag remove --name=work --tag=old-tag

# Set auto-lock timeout
tip vault edit --name=personal --auto-lock=30

# View vault metadata
tip vault info --metadata
```

##### Advanced Vault Settings
```bash
# Set vault as default
tip vault edit --name=work --default

# Unset default vault
tip vault edit --name=work --no-default

# Enable/disable vault
tip vault disable --name=archive  # Temporarily hide vault
tip vault enable --name=archive   # Re-enable vault

# Export vault metadata
tip vault export-metadata --name=work --format=json

# Import vault settings
tip vault import-metadata --file=settings.json
```

##### Vault Security
```bash
# Each vault has its own encryption key derived from master password
# Vaults are isolated - switching vaults requires re-authentication
# All vault data is encrypted at rest using AES-256-GCM

# Change vault password (re-encrypts all contents)
tip vault change-password

# Verify vault integrity
tip vault verify

# Check for compromised passwords across vaults
tip password audit --all-vaults --breach-check
```

##### Vault Sharing (Remote Mode)
```bash
# Note: Vaults themselves are not shared - individual passwords are shared
# See Password Sharing section for sharing specific credentials

# View vault access (remote mode)
tip vault access --name=work

# Export vault for sharing (encrypted export)
tip vault export --name=work --encrypt-with=shared-password

# Import shared vault
tip vault import --file=shared-vault.bak --decrypt-with=shared-password
```

##### Use Cases
```bash
# Personal organization
tip vault init --name=personal
tip vault init --name=finance
tip vault init --name=health

# Work organization
tip vault init --name=work
tip vault init --name=client-alpha
tip vault init --name=client-beta

# Project-based
tip vault init --name=project-alpha
tip vault init --name=project-beta
tip vault init --name=archived
```

##### Vault Commands Quick Reference
```bash
# Vault operations
tip vault init --name=<name>              # Create new vault
tip vault list                     # List all vaults
tip vault switch --name=<name>            # Switch to vault
tip vault info                     # Show vault details
tip vault edit --name=<name>              # Edit vault settings
tip vault delete --name=<name>            # Delete vault
tip vault backup --path=<path>     # Backup vault
tip vault restore --path=<path>           # Restore vault

# Vault metadata
tip vault tag add --name=<name> --tag=<tag>    # Add tag to vault
tip vault tag remove --name=<name> --tag=<tag> # Remove tag
tip vault verify                  # Verify vault integrity

# Item movement
tip password move --name=<name> --from=<vault> --to=<vault>
tip task move --from=<vault> --to=<vault>
```

### Encryption and Security

#### Encryption Standards
- **Algorithm**: AES-256-GCM
- **Key Derivation**: Argon2id (NIST recommended)
- **Authentication**: Authenticated encryption
- **Data at Rest**: Encrypted in storage
- **Data in Transit**: TLS 1.3
- **Encryption**: End-to-end encryption for all sensitive data
- **Token Security**: Expiring tokens with revocation capability
- **Memory Protection**: Secure handling of sensitive information
- **Audit Trail**: Complete logging of all operations

#### Master Password
```bash
# Set master password
tip unlock
# Enter master password: [hidden input]

# Change master password
tip password change-master

# Master password never stored, only derived key
# 20-second delay between wrong attempts (brute-force protection)
```

#### Auto-Lock Feature
```bash
# Auto-lock timeout in minutes
tip config set --key=security.auto_lock_timeout --value=15

# Lock vault manually
tip lock

# Unlock vault
tip unlock

# Check lock status
tip auth status
```

### Advanced Features

#### Duplicate Detection

```bash
# Check for duplicate passwords (risky)
tip password audit --duplicates

# Find accounts with same password as specified
tip password find-same-as --name=github

# Change duplicate passwords (guided)
tip password deduplicate
```

#### Breach Detection

```bash
# Check if password is in known breaches
# Uses haveibeenpwned.com API (anonymous checking)
tip password check --name=github

# Scan all passwords
tip password audit --breach-check

# Automatic breach checking (background)
# Enabled with: tip config set --key=security.breach_check --value=true
```

#### Password Expiration

```bash
# Set password expiration date
tip password edit --name=github --expires="2025-04-15"

# Mark password as expiring soon
tip password edit --name=github --tag=expiring

# Show expiring passwords
tip password list --expiring

# Automatic reminders (future)
# tip config set --key=security.password_expiration_reminder --value="30 days"
```

### Output and Formatting

#### List View Options
```bash
# Default table view
tip password list

# Show only names
tip password list --format=names

# Compact view
tip password list --format=compact

# JSON output (for scripting)
tip password list --format=json

# CSV export
tip password list --format=csv > passwords.csv

# Count only
tip password list --count

# Show creation dates
tip password list --created

# Show last used
tip password list --last-used
```

#### Detailed View
```bash
# Full details with all fields
tip password get --name=github --verbose

# Hide sensitive info
tip password get --name=github --mask-password

# Show in different formats
tip password get --name=github --format=json
tip password get --name=github --format=yaml
```

### Statistics and Reporting

```bash
# Password count by category
tip password stats

# Passwords by strength
tip password stats --by=strength

# Passwords by age
tip password stats --by=age

# Security report
tip password report --security

# Compliance report
tip password report --compliance
```

### Best Practices

1. **Unique Passwords** - Use different password for each service
2. **Strong Master Password** - 20+ characters, mixed case, numbers, symbols
3. **Regular Updates** - Change passwords every 90 days
4. **Backup Regularly** - `tip export` weekly
5. **Review Sharing** - Remove unnecessary shared access
6. **Audit Periodically** - `tip password audit` monthly
7. **Secure Notes** - Store recovery codes and 2FA setup info
8. **Use Generation** - Let Tip generate complex passwords
9. **Enable MFA** - Tag accounts with MFA enabled
10. **Delete Unused** - Remove old/duplicate accounts

### Storage Modes

#### Local Mode (JSON)
- Passwords stored in `~/.tip/vaults/<vault>/passwords.json`
- Encrypted at rest with master password
- No server required
- Manual backups needed

#### Local Mode (SQLite)
- Passwords in local SQLite database
- Better performance
- Full-text search
- Better data integrity

#### Remote Mode
- Passwords synced to server
- End-to-end encrypted
- Access from multiple devices
- Team sharing capability
- Automatic backups
- Collaborative management

### Command Reference Quick List

```bash
# Add/Remove
tip password add --name=<name>
tip password delete --name=<name>

# View
tip password get --name=<name>
tip password list [--category=<cat>]
tip password search --query=<query>

# Update
tip password edit --name=<name>
tip password copy --name=<name>

# Organization
tip password category add --name=<name>
tip password tag add --name=<name> --tag=<tag>

# Security
tip password generate
tip password strength --password=<password>
tip password audit
tip password history --name=<name>

# Sharing (remote)
tip password share --name=<name> --user=<user>

# Import/Export
tip export passwords --format=json
tip import --file=backup.json
```

### Future Enhancements

- [ ] Browser extension auto-fill
- [ ] TOTP/2FA integration
- [ ] Hardware security key support
- [ ] Password strength meter in real-time
- [ ] Automatic password rotation
- [ ] Passwordless authentication
- [ ] API key management
- [ ] SSH key management
- [ ] Credit card secure storage
- [ ] Identity document storage
- [ ] Integration with identity providers

## Task Manager Features

### Overview

The Task Manager handles task and workflow management. It supports personal task tracking, team collaboration, and integration with password management workflows.

### Data Model

#### Task Structure
```go
type Task struct {
    ID          string    `json:"id"`           // Unique identifier
    Title       string    `json:"title"`        // Task title/description
    Description string    `json:"description"` // Detailed description
    Status      string    `json:"status"`      // pending, in_progress, completed
    Priority    string    `json:"priority"`    // low, medium, high, critical
    DueDate     time.Time `json:"due_date"`    // When task is due
    AssignedTo  string    `json:"assigned_to"` // User assignment (remote mode)
    Category    string    `json:"category"`    // Work, Personal, Development, Finance
    Tags        []string  `json:"tags"`        // Custom tags for organization
    CreatedAt   time.Time `json:"created_at"`  // Creation timestamp
    UpdatedAt   time.Time `json:"updated_at"`  // Last modification
    CompletedAt time.Time `json:"completed_at"`// When task was completed
}
```

### Core Features

#### 1. Task CRUD Operations

##### Create Tasks
```bash
# Basic task creation
tip task add --description="Fix login bug"

# With priority
tip task add --description="Fix security issue" --priority=critical

# With due date
tip task add --description="Quarterly review" --due="2025-03-31"

# With category
tip task add --description="Refactor auth module" --category=development

# With all attributes
tip task add --description="Deploy to production" \
  --priority=high \
  --due=tomorrow \
  --category=work
```

##### Read/Get Tasks
```bash
# Get specific task details
tip task get --id=1

# List all tasks (default: all statuses)
tip task list

# List with filters
tip task list --status=pending
tip task list --priority=high
tip task list --category=work
tip task list --due=today
tip task list --status=in_progress --priority=critical
```

##### Update Tasks
```bash
# Edit task
tip task edit --id=1 --title="Updated title"
tip task edit --id=1 --description="New description"
tip task edit --id=1 --priority=high
tip task edit --id=1 --due="next Monday"
tip task edit --id=1 --category=development
```

##### Delete Tasks
```bash
# Delete single task
tip task delete --id=1

# Bulk delete completed tasks (future)
tip task delete --status=completed

# Delete by category
tip task delete --category=finance
```

#### 2. Task Status Management

##### Status Lifecycle
- **pending** - Task created but not started
- **in_progress** - Currently being worked on
- **completed** - Task finished

##### Status Commands
```bash
# Start working on a task
tip task start --id=1       # Marks as in_progress

# Complete a task
tip task complete --id=1    # Marks as completed

# Update status directly
tip task edit --id=1 --status=pending
```

#### 3. Priority System

##### Priority Levels
- **low** - Background work, non-urgent
- **medium** - Standard priority (default)
- **high** - Important, needs attention soon
- **critical** - Urgent, blocking other work

##### Usage
```bash
# Set priority when adding
tip task add --description="Critical security patch" --priority=critical

# Update priority
tip task edit --id=1 --priority=high

# Filter by priority
tip task list --priority=critical
tip task list --priority=high,critical  # Multiple priorities

# Sort by priority (default in list view)
# Critical and High appear first
```

#### 4. Due Dates and Reminders

##### Date Format Support
```bash
# Absolute dates
tip task add --description="Release v1.0" --due="2025-02-15"
tip task add --description="Meeting" --due="2025-01-15 14:30"

# Relative dates (smart parsing)
tip task add --description="Daily standup" --due=today
tip task add --description="Sprint review" --due=tomorrow
tip task add --description="Project kickoff" --due="next Monday"
tip task add --description="Quarterly planning" --due="in 2 weeks"
```

##### Filtering by Due Date
```bash
# Tasks due today
tip task list --due=today

# Overdue tasks
tip task list --due=overdue

# Tasks due this week
tip task list --due="this week"

# Tasks due in specific period
tip task list --due="next 7 days"

# Combined filters
tip task list --status=in_progress --due=today --priority=high
```

#### 5. Categories

Predefined categories for organization:
- **Work** - Job-related tasks
- **Personal** - Personal life tasks
- **Development** - Technical/coding tasks
- **Finance** - Money and billing related

##### Category Commands
```bash
# List available categories
tip password category list

# Add custom category
tip password category add --name=freelance
tip password category add --name=health
tip password category add --name=legal

# Use category when adding task
tip task add --description="Doctor appointment" --category=health

# Filter by category
tip task list --category=work
tip task list --category=development
```

#### 6. Tags

Flexible tagging system for additional organization:

```bash
# Add tags to task (when creating)
tip task add --description="Implement API" --tag=backend --tag=api

# Add tags to existing task
tip task tag add --id=1 --tag=urgent
tip task tag add --id=1 --tag=documentation

# Remove tags
tip task tag remove --id=1 --tag=urgent

# List tags
tip task tag list

# Filter by tag
tip task list --tag=backend
tip task list --tag=urgent
```

#### 7. Search and Filtering

Search capabilities:

```bash
# Search by title/description
tip task search --query="login bug"
tip task search --query="database migration"

# Search with filters
tip task search --query="auth" --status=in_progress
tip task search --query="deploy" --priority=high
tip task search --query="api" --category=development

# Advanced filters
tip task list \
  --status=in_progress \
  --priority=high \
  --category=work \
  --due=today \
  --tag=urgent

# Search in specific category
tip task search --query="refactor" --category=development
```

#### 8. Team Collaboration (Remote Mode)

##### Task Assignment
```bash
# Assign task to team member
tip task assign --id=1 --user=alice@example.com
tip task assign --id=1 --user=bob@example.com

# Reassign task
tip task edit --id=1 --assigned=bob@example.com

# List tasks assigned to me
tip task list --assigned=me

# List tasks assigned to specific user
tip task list --assigned=alice@example.com

# Tasks by assignee
tip task list --assigned="Bob Smith"
```

##### Comments and Updates (Future)
```bash
# Add comment to task
tip task comment --id=1 --message="Added database indexes for performance"

# View comments
tip task get --id=1 --verbose  # Shows all comments

# @mention team members
tip task comment --id=1 --message="@alice please review when ready"
```

#### 9. Task History and Timestamps

##### Tracked Timestamps
- **CreatedAt** - When task was created
- **UpdatedAt** - When task was last modified
- **CompletedAt** - When task was marked complete
- **LastModifiedBy** - Who last modified (remote mode)

##### View History
```bash
# See when task was created/updated
tip task get --id=1 --verbose

# Show all task changes (future)
tip task history --id=1

# Changes in time range
tip task history --id=1 --from="2 weeks ago" --to=today
```

### Advanced Features

#### 1. Task Templates

Reusable task patterns:

```bash
# Create task from template
tip task template use --name=weekly-standup

# Define custom templates
tip task template create --name=daily-checklist \
  --items="Review emails,Check messages,Plan day"

# Available built-in templates
tip task template list
```

#### 2. Recurring Tasks (Future)

Automatic task creation:

```bash
# Create recurring task
tip task add --description="Weekly standup" --recur=weekly --due=Friday

# Daily tasks
tip task add --description="Morning review" --recur=daily

# Custom recurrence
tip task add --description="Sprint planning" --recur="every other week"
```

#### 3. Task Dependencies (Future)

Link related tasks:

```bash
# Mark task depends on another
tip task depends --id=2 --on=1  # Task 2 depends on Task 1

# View task dependencies
tip task get --id=1 --dependencies

# Filter by blocking/blocked
tip task list --blocked   # Tasks waiting on others
tip task list --blocking  # Tasks blocking others
```

#### 4. Progress Tracking

##### Subtasks (Future)
```bash
# Add subtask
tip task subtask add --id=1 --description="Unit tests"
tip task subtask add --id=1 --description="Integration tests"
tip task subtask add --id=1 --description="Deploy to staging"

# Complete subtask
tip task subtask complete --id=1 --subtask=2  # Complete subtask 2 of task 1

# View task with subtasks
tip task get --id=1 --verbose  # Shows progress: 2/3 complete
```

### Integration Features

#### Password-Task Linking

Link tasks to password-protected resources:

```bash
# Task related to password
tip task add --description="Update github" --related=password:github

# View related items
tip task get --id=1 --related
```

#### Calendar Integration

View tasks on calendar:

```bash
# Show calendar for current month
tip task calendar

# Show tasks in week view
tip task calendar --view=week

# Show tasks in day view
tip task calendar --view=day
```

### Output Formatting

#### List View
```bash
# Default table format
tip task list

# Compact format
tip task list --format=compact

# JSON format (for scripting)
tip task list --format=json

# CSV format
tip task list --format=csv

# Count only
tip task list --count
```

#### Details View
```bash
# Full task details
tip task get --id=1 --verbose

# Show in different formats
tip task get --id=1 --format=json
tip task get --id=1 --format=yaml
```

### Statistics and Reporting

#### Task Statistics
```bash
# Count tasks by status
tip task stats

# Completion rate
tip task stats --metric=completion

# Priority distribution
tip task stats --metric=priority

# Burndown chart (future)
tip task chart --type=burndown --from="2 weeks ago"
```

#### Filtering Examples
```bash
# Show all overdue tasks
tip task list --due=overdue

# Show this week's high priority items
tip task list --priority=high --due="this week"

# Show my in-progress work
tip task list --status=in_progress --category=work

# Show all tasks tagged urgent
tip task list --tag=urgent

# Show tasks from specific assignee
tip task list --assigned=alice
```

### Command Aliases

Shorthand commands:

```bash
# List alias for `task list`
tip t list

# Add alias
tip t add --description="New feature"

# Complete alias
tip t complete --id=1

# Get alias
tip t get --id=1

# Search alias
tip t search --query="bug"
```

### Storage Modes

#### Local Mode (JSON)
- All tasks stored in `~/.tip/vaults/<vault>/tasks.json`
- No encryption (optional)
- Fast for personal use

#### Local Mode (SQLite)
- Tasks in local SQLite database
- Better performance with many tasks
- Full-text search capability

#### Remote Mode
- Tasks synced with server
- Enabled collaboration
- Conflict resolution
- Accessible from multiple devices

### Best Practices

1. **Use Categories Consistently** - Keep tasks organized by type
2. **Set Realistic Due Dates** - Use smart date parsing for natural language
3. **Tag for Flexibility** - Add custom tags for filtering and reporting
4. **Update Status Regularly** - Keep task status current for accurate reporting
5. **Use Priority Wisely** - Don't mark everything as high priority
6. **Add Descriptions** - Include context for future reference
7. **Regular Review** - Weekly task review and updates
8. **Archive Completed** - Clear completed tasks periodically

### Testing

The Task Manager includes tests:

```bash
# Run all tests
zig build test

# With verbose output
zig build test --summary all

```

### Future Enhancements

- [ ] Recurring task automation
- [ ] Task dependencies and blocking
- [ ] Subtasks and milestones
- [ ] Time tracking integration
- [ ] Calendar integration
- [ ] Slack/Teams notifications
- [ ] Email reminders
- [ ] Mobile app support
- [ ] Task templates library
