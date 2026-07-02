# Documentation Index

Complete documentation for the Tip password and task manager project.

## Project Overview

## Project Vision
A self-hosted password and task manager. Uses a multi-tier architecture with local-first storage and optional remote sync.

## Core Components

### 1. CLI Tool (`tip`)
Operates in local mode (direct file/database access) or remote mode (HTTP client to self-hosted server).
Uses JSON or SQLite storage with end-to-end encryption.

### 2. Web Server (`tip-server`)
Self-hosted backend with REST API, OAuth auth, multi-tenant vaults, SQLite storage, and sync.

### 3. Web Platform (`tip-web`)
Future browser interface (not yet started).

## Current Implementation Status

### Completed Components
- [x] **Task Manager Core** (`src/task.zig`)
  - [x] Complete CRUD operations for tasks
  - [x] JSON persistence with timestamps
  - [x] Comprehensive test suite (embedded in src/task.zig)
  - [x] Memory-efficient data structures (ArrayList)
- [x] **Build System** (`build.zig`)
  - [x] Auto-generated test runner using `addWriteFiles()` (lives in build cache, no disk artifacts)
  - [x] Iterative file collection across `src/` for test discovery

### Pending Components
- [ ] **Password Manager Core** - Encryption, CRUD, generation
- [ ] **Storage Layer** - JSON/SQLite adapters, remote client
- [ ] **CLI Interface** - Command parsing, configuration, modes
- [ ] **Web Server** - API, authentication, database
- [ ] **Web Platform** - Frontend, real-time features

## Key Design Principles

### Security First
- **Zero-Knowledge Architecture**: Server never sees unencrypted data
- **Master Password**: Single point of authentication with key derivation
- **End-to-End Encryption**: AES-256-GCM for data at rest and in transit
- **Secure Memory**: Automatic wiping of sensitive data from memory

### Flexibility & Choice
- **Storage Options**: JSON files for simplicity, SQLite for performance
- **Operation Modes**: Local for offline, Remote for collaboration
- **Deployment Options**: Self-hosted, Docker, or binary installation
- **Configuration**: Extensive customization via config files

## Technical Highlights

### Performance
- **Caching**: In-memory caching for frequently accessed data
- **Lazy Loading**: On-demand data retrieval
- **Compression**: Reduced storage and bandwidth usage

### Reliability
- **Atomic Operations**: Consistent data state
- **Backup/Restore**: Complete data export/import
- **Migration Tools**: Seamless upgrades and data migration
- **Health Monitoring**: Built-in diagnostics and metrics

## Feature Matrix

### Password Management
| Feature | Local Mode | Remote Mode | Web Platform |
|---------|------------|-------------|--------------|
| Add Password | ✅ | ✅ | ✅ |
| Edit Password | ✅ | ✅ | ✅ |
| Delete Password | ✅ | ✅ | ✅ |
| Search Passwords | ✅ | ✅ | ✅ |
| Generate Password | ✅ | ✅ | ✅ |
| Categories/Tags | ✅ | ✅ | ✅ |
| Secure Sharing | ❌ | ✅ | ✅ |
| Audit Logs | ✅ | ✅ | ✅ |
| Import/Export | ✅ | ✅ | ✅ |

### Task Management
| Feature | Local Mode | Remote Mode | Web Platform |
|---------|------------|-------------|--------------|
| Add Task | ✅ | ✅ | ✅ |
| Complete Task | ✅ | ✅ | ✅ |
| Delete Task | ✅ | ✅ | ✅ |
| List Tasks | ✅ | ✅ | ✅ |
| Due Dates | ✅ | ✅ | ✅ |
| Assignments | ❌ | ✅ | ✅ |
| Collaboration | ❌ | ✅ | ✅ |
| Reminders | ✅ | ✅ | ✅ |

### Security Features
| Feature | Implementation |
|---------|----------------|
| Master Password | PBKDF2/Argon2id key derivation |
| Data Encryption | AES-256-GCM |
| Secure Input | Terminal password masking |
| Memory Protection | Automatic sensitive data wiping |
| Transport Security | TLS 1.3 for all communications |
| Authentication | JWT with refresh tokens |
| Access Control | Role-based permissions |

## Quick Navigation

### Getting Started
- **[README.md](../README.md)** - Project overview and quick start
- **[PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md)** - Vision, features, and design principles
- **[ROADMAP.md](ROADMAP.md)** - Development timeline and milestones

### User Documentation
- **[CLI_REFERENCE.md](CLI_REFERENCE.md)** - Complete CLI command reference with examples
- **[FEATURES.md](FEATURES.md)** - Complete password and task management features

### Developer Documentation
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System design and technical architecture
- **[SERVER_API.md](SERVER_API.md)** - REST API endpoints and integration guide

## Document Descriptions

### README.md
**Purpose**: Project introduction and quick reference
**Contents**:
- Feature overview with emojis
- Quick start guide
- Installation instructions
- Configuration example
- Development setup
- Use cases and security notes
- Deployment information

**Read this if**: You're new to Tip or want a high-level overview

### CLI_REFERENCE.md
**Purpose**: Complete command-line interface documentation
**Contents**:
- Command structure and syntax
- Global flags
- All command categories:
  - Configuration
  - Vault management
  - Authentication
  - Password management
  - Task management
  - Synchronization
- Practical examples for all major workflows
- Configuration file format
- Security best practices
- Flags and options reference
- Error handling and troubleshooting

**Read this if**: You need to use Tip from the command line

### FEATURES.md
**Purpose**: Comprehensive password manager and task manager feature documentation
**Contents**:
- Password Management:
  - Data model (Password struct)
  - Core CRUD operations with examples
  - Password generation (multiple options)
  - Strength evaluation and breach detection
  - Password history and versioning
  - Search, discovery, and filtering
  - Categories and tags
  - Custom fields
  - Clipboard integration
  - Secure notes storage
  - Sharing capabilities (remote mode)
  - Import/export functionality
  - Security analysis and audit
  - Vault organization
  - Encryption standards
  - Advanced features (duplicates, expiration)
- Task Management:
  - Task data model (Task struct)
  - Core CRUD operations with examples
  - Status lifecycle (pending, in_progress, completed)
  - Priority system (low, medium, high, critical)
  - Due dates with smart parsing
  - Categories and tags
  - Search and filtering
  - Team collaboration and assignment
  - Task history and timestamps
  - Advanced features (templates, recurring tasks, dependencies, subtasks)
  - Password-task linking
  - Calendar integration
- Output formatting for both
- Statistics and reporting
- Best practices
- Future enhancements

**Read this if**: You want to master password and task management features

### ARCHITECTURE.md
**Purpose**: Technical system design and implementation details
**Contents**:
- Project structure and directory layout
- Current implementation status
- Detailed architecture sections:
  - Business logic layer (models, managers, crypto)
  - Storage abstraction (interfaces and implementations)
  - CLI architecture (flags.zig framework)
  - Server architecture (std.http)
  - API design and endpoints
  - Authentication and authorization
- Technology stack for CLI, Server, Database, Security, Development
- Deployment architecture (local, production, monitoring)
- Design decisions and rationale
- Implementation priorities
- OAuth integration flow
- Command philosophy and design
- Security features matrix

**Read this if**: You're a developer implementing Tip features

### SERVER_API.md
**Purpose**: REST API reference and integration guide
**Contents**:
- Base URL and versioning
- Standard response format
- Authentication methods:
  - OAuth (GitHub, Google)
  - Direct login
  - Token refresh
  - Token management
- User profile endpoints
- Token management (create, list, revoke, extend)
- Vault management endpoints
- Password management endpoints
  - CRUD operations
  - Search, generate, share
  - Access control
- Task management endpoints
  - CRUD operations
  - Status management
  - Assignment
- Synchronization endpoints
- Health check endpoints
- Error codes and handling
- Rate limiting
- Webhook definitions (future)

**Read this if**: You're integrating with Tip server or developing server features

### ROADMAP.md
**Purpose**: Development timeline and phase planning
**Contents**:
- 11 development phases with weekly breakdowns
- Phase 1-10 detailed tasks:
  - Foundation & Architecture
  - Core Business Logic
  - Cryptography & Security
  - Storage Layer Implementation
  - CLI Implementation
  - Web Server Implementation
  - Integration & Synchronization
  - Advanced Features & Polish
  - Testing & Quality Assurance
  - Deployment & Operations
- Phase 11: Web Platform Development
- Advanced Features & Future Development

- Implementation notes

**Read this if**: You want to understand the development plan and status

## By Role

### End Users
1. Start: [README.md](../README.md) - Quick overview
2. Learn: [CLI_REFERENCE.md](CLI_REFERENCE.md) - Command guide
3. Master: [FEATURES.md](FEATURES.md)
4. Advanced: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) for operational modes

### Administrators
1. Start: [README.md](../README.md)
2. Deploy: [ARCHITECTURE.md](ARCHITECTURE.md#deployment-architecture)
3. Maintain: [ROADMAP.md](ROADMAP.md) for version planning
4. Secure: [ARCHITECTURE.md](ARCHITECTURE.md#security-features) and [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#security-first)

### CLI Developers
1. Start: [ARCHITECTURE.md](ARCHITECTURE.md#cli-design)
2. Reference: [CLI_REFERENCE.md](CLI_REFERENCE.md)
3. Features: [FEATURES.md](FEATURES.md)
4. Plan: [ROADMAP.md](ROADMAP.md)

### Backend Developers
1. Start: [ARCHITECTURE.md](ARCHITECTURE.md)
2. API: [SERVER_API.md](SERVER_API.md)
3. Features: [FEATURES.md](FEATURES.md)
4. Plan: [ROADMAP.md](ROADMAP.md)

### Security Reviewers
1. Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#key-design-principles)
2. Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#technology-stack) and [ARCHITECTURE.md](ARCHITECTURE.md#security-features)
3. Features: [FEATURES.md](FEATURES.md#encryption-and-security)
4. API: [SERVER_API.md](SERVER_API.md#authentication)

## Feature Cross-Reference

### Password Management
- Commands: [CLI_REFERENCE.md](CLI_REFERENCE.md#password-management-commands)
- Features: [FEATURES.md](FEATURES.md)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#password-manager-passwordgo)
- API: [SERVER_API.md](SERVER_API.md#password-management)
- Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#password-management)

### Task Management
- Commands: [CLI_REFERENCE.md](CLI_REFERENCE.md#task-management-commands)
- Features: [FEATURES.md](FEATURES.md)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#task-manager-taskgo)
- API: [SERVER_API.md](SERVER_API.md#task-management)
- Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#task-manager-features-enhanced)

### Vault Management
- Commands: [CLI_REFERENCE.md](CLI_REFERENCE.md#vault-management)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#vault-management)
- API: [SERVER_API.md](SERVER_API.md#vault-management)
- Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#vault-management)

### Authentication
- Commands: [CLI_REFERENCE.md](CLI_REFERENCE.md#authentication-commands)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#oauth-integration-flow)
- API: [SERVER_API.md](SERVER_API.md#authentication)
- Features: [FEATURES.md](FEATURES.md#master-password)

### Synchronization
- Commands: [CLI_REFERENCE.md](CLI_REFERENCE.md#synchronization-commands)
- API: [SERVER_API.md](SERVER_API.md#synchronization)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#operation-modes)
- Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#operation-modes)

### Security
- Features: [FEATURES.md](FEATURES.md#encryption-and-security)
- Best Practices: [FEATURES.md](FEATURES.md#best-practices)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md#security-features)
- Overview: [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md#security-first)

## Examples and Workflows

### Quick Start Workflows
- Basic usage: [README.md](../README.md#quick-start)
- CLI examples: [CLI_REFERENCE.md](CLI_REFERENCE.md#examples)
- API examples: [SERVER_API.md](SERVER_API.md)

### Common Tasks
- Creating passwords: [FEATURES.md](FEATURES.md#password-manager-features)
- Managing tasks: [FEATURES.md](FEATURES.md#task-manager-features)
- Sharing passwords: [FEATURES.md](FEATURES.md#password-manager-features)
- Team collaboration: [FEATURES.md](FEATURES.md#task-manager-features)
- Backup and restore: [CLI_REFERENCE.md](CLI_REFERENCE.md#data-management)

### Advanced Workflows
- Multi-vault management: [CLI_REFERENCE.md](CLI_REFERENCE.md#working-with-multiple-vaults)
- Password security audit: [FEATURES.md](FEATURES.md#password-manager-features)
- Task reporting: [FEATURES.md](FEATURES.md#task-manager-features)
- Custom integration: [SERVER_API.md](SERVER_API.md)

## Document Maintenance

**Last Updated**: February 20, 2026

**Note**: This project is built with Zig (not Go as originally planned). The core task manager is implemented in `src/task.zig` with the Zig build system in `build.zig`.

**Structure**:
- docs/ directory contains all documentation
- FEATURES.md covers all password and task management features
- CLI_REFERENCE covers command-line usage
- ARCHITECTURE covers technical design
- SERVER_API covers REST API
- README provides quick reference
- ROADMAP tracks development

**Cross-linking**: All documents reference related content for easy navigation

**Keep Updated**:
- Update feature docs when new commands added
- Update CLI_REFERENCE with new CLI options
- Update SERVER_API when endpoints change
- Update ROADMAP as phases complete
- Update ARCHITECTURE with design decisions
