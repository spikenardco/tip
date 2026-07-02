# Server API Reference

## Overview

The Tip Server provides a RESTful API for remote mode operations with team collaboration, multi-device sync, and web platform access. The API uses JSON for request/response and requires authentication via JWT tokens.

## Base URL and Versioning

```
Base URL: https://tip.example.com/api/v1
Headers:
  Authorization: Bearer <jwt_token>
  Content-Type: application/json
  Accept: application/json
```

## Response Format

All API responses follow a standard format:

### Success Response (200, 201)
```json
{
  "success": true,
  "data": {
    // Response data
  },
  "meta": {
    "timestamp": "2025-01-08T10:00:00Z",
    "request_id": "req_abc123def456",
    "version": "v1"
  }
}
```

### Error Response (4xx, 5xx)
```json
{
  "success": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid request",
    "details": [
      {
        "field": "password",
        "message": "Password is required"
      }
    ]
  },
  "meta": {
    "timestamp": "2025-01-08T10:00:00Z",
    "request_id": "req_abc123def456",
    "version": "v1"
  }
}
```

## Authentication

### OAuth Integration

Users can authenticate using GitHub or Google OAuth:

```
GET /auth/oauth/github
GET /auth/oauth/google
GET /auth/oauth/callback?code=<code>&state=<state>
```

### Direct Login (Email/Password)

```
POST /auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "master_password"
}

Response:
{
  "success": true,
  "data": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "eyJhbGciOiJIUzI1NiIs...",
    "expires_in": 3600,
    "user": {
      "id": "usr_abc123",
      "email": "user@example.com",
      "name": "Alice Smith"
    }
  }
}
```

### Token Refresh

```
POST /auth/refresh
Content-Type: application/json

{
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}

Response:
{
  "success": true,
  "data": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "expires_in": 3600
  }
}
```

### Logout

```
POST /auth/logout
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Successfully logged out"
  }
}
```

## User Profile

### Get Current User Profile

```
GET /auth/profile
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "usr_abc123",
    "email": "user@example.com",
    "name": "Alice Smith",
    "created_at": "2024-12-01T10:00:00Z",
    "updated_at": "2025-01-08T10:00:00Z"
  }
}
```

### Update User Profile

```
PUT /auth/profile
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "Alice Johnson",
  "email": "alice.johnson@example.com"
}

Response:
{
  "success": true,
  "data": {
    "id": "usr_abc123",
    "email": "alice.johnson@example.com",
    "name": "Alice Johnson",
    "updated_at": "2025-01-08T10:05:00Z"
  }
}
```

## Token Management

### Create CLI Token

Used for scripted access to the API:

```
POST /auth/tokens
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "backup-script",
  "expires_in": 7776000  // 90 days in seconds
}

Response:
{
  "success": true,
  "data": {
    "id": "tok_abc123",
    "token": "tip_xxxxxxxxxxxxxxxxxxxxx",
    "name": "backup-script",
    "created_at": "2025-01-08T10:00:00Z",
    "expires_at": "2025-04-08T10:00:00Z"
  }
}
```

### List CLI Tokens

```
GET /auth/tokens
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": [
    {
      "id": "tok_abc123",
      "name": "backup-script",
      "created_at": "2025-01-08T10:00:00Z",
      "expires_at": "2025-04-08T10:00:00Z",
      "last_used": "2025-01-08T09:30:00Z"
    }
  ]
}
```

### Get Token Details

```
GET /auth/tokens/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "tok_abc123",
    "name": "backup-script",
    "created_at": "2025-01-08T10:00:00Z",
    "expires_at": "2025-04-08T10:00:00Z",
    "last_used": "2025-01-08T09:30:00Z"
  }
}
```

### Update Token (Extend Expiry)

```
PUT /auth/tokens/:id
Authorization: Bearer <token>
Content-Type: application/json

{
  "expires_in": 7776000  // Extend by 90 days
}

Response:
{
  "success": true,
  "data": {
    "id": "tok_abc123",
    "expires_at": "2025-04-08T10:00:00Z"
  }
}
```

### Revoke CLI Token

```
DELETE /auth/tokens/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Token revoked successfully"
  }
}
```

## Vault Management

### Create Vault

```
POST /vaults
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "personal",
  "description": "Personal vault"
}

Response:
{
  "success": true,
  "data": {
    "id": "vlt_abc123",
    "name": "personal",
    "description": "Personal vault",
    "created_at": "2025-01-08T10:00:00Z"
  }
}
```

### List User Vaults

```
GET /vaults
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": [
    {
      "id": "vlt_abc123",
      "name": "personal",
      "description": "Personal vault",
      "passwords_count": 42,
      "tasks_count": 15,
      "created_at": "2024-12-01T10:00:00Z",
      "updated_at": "2025-01-08T10:00:00Z"
    }
  ]
}
```

### Get Vault Details

```
GET /vaults/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "vlt_abc123",
    "name": "personal",
    "description": "Personal vault",
    "passwords_count": 42,
    "tasks_count": 15,
    "members": [
      {
        "user_id": "usr_abc123",
        "email": "alice@example.com",
        "role": "owner"
      }
    ],
    "created_at": "2024-12-01T10:00:00Z",
    "updated_at": "2025-01-08T10:00:00Z"
  }
}
```

### Update Vault

```
PUT /vaults/:id
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "personal-updated",
  "description": "Updated personal vault"
}

Response:
{
  "success": true,
  "data": {
    "id": "vlt_abc123",
    "name": "personal-updated",
    "updated_at": "2025-01-08T10:05:00Z"
  }
}
```

### Delete Vault

```
DELETE /vaults/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Vault deleted successfully"
  }
}
```

### Backup Vault

```
POST /vaults/:id/backup
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "backup_id": "bak_abc123",
    "vault_id": "vlt_abc123",
    "created_at": "2025-01-08T10:00:00Z",
    "file_size": 12345,
    "download_url": "https://tip.example.com/downloads/bak_abc123"
  }
}
```

### Restore Vault

```
POST /vaults/:id/restore
Authorization: Bearer <token>
Content-Type: application/json

{
  "backup_id": "bak_abc123"
}

Response:
{
  "success": true,
  "data": {
    "message": "Vault restored successfully",
    "restored_items": {
      "passwords": 42,
      "tasks": 15
    }
  }
}
```

## Password Management

### Create Password

```
POST /vaults/:vaultId/passwords
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "github",
  "username": "alice",
  "password": "encrypted_password_here",  // Pre-encrypted by client
  "url": "https://github.com",
  "category": "development",
  "tags": ["important", "2fa"],
  "notes": "Personal GitHub account"
}

Response:
{
  "success": true,
  "data": {
    "id": "pwd_abc123",
    "name": "github",
    "username": "alice",
    "category": "development",
    "tags": ["important", "2fa"],
    "created_at": "2025-01-08T10:00:00Z"
  }
}
```

### List Passwords

```
GET /vaults/:vaultId/passwords
Authorization: Bearer <token>

Query Parameters:
  ?category=development
  ?tag=important
  ?search=github
  ?skip=0
  ?limit=50

Response:
{
  "success": true,
  "data": [
    {
      "id": "pwd_abc123",
      "name": "github",
      "username": "alice",
      "category": "development",
      "tags": ["important"],
      "created_at": "2025-01-08T10:00:00Z",
      "updated_at": "2025-01-08T10:00:00Z"
    }
  ],
  "meta": {
    "total": 42,
    "skip": 0,
    "limit": 50
  }
}
```

### Get Password

```
GET /vaults/:vaultId/passwords/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "pwd_abc123",
    "name": "github",
    "username": "alice",
    "password": "encrypted_password_here",
    "url": "https://github.com",
    "category": "development",
    "tags": ["important", "2fa"],
    "notes": "Personal GitHub account",
    "created_at": "2025-01-08T10:00:00Z",
    "updated_at": "2025-01-08T10:00:00Z",
    "last_used": "2025-01-08T09:30:00Z"
  }
}
```

### Update Password

```
PUT /vaults/:vaultId/passwords/:id
Authorization: Bearer <token>
Content-Type: application/json

{
  "username": "alice.smith",
  "category": "work",
  "tags": ["important"]
}

Response:
{
  "success": true,
  "data": {
    "id": "pwd_abc123",
    "updated_at": "2025-01-08T10:05:00Z"
  }
}
```

### Delete Password

```
DELETE /vaults/:vaultId/passwords/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Password deleted successfully"
  }
}
```

### Search Passwords

```
GET /vaults/:vaultId/passwords/search
Authorization: Bearer <token>

Query Parameters:
  ?q=github
  ?category=development
  ?tag=important

Response:
{
  "success": true,
  "data": [
    {
      "id": "pwd_abc123",
      "name": "github",
      "score": 0.95  // Relevance score
    }
  ]
}
```

### Generate Password

```
POST /vaults/:vaultId/passwords/generate
Authorization: Bearer <token>
Content-Type: application/json

{
  "length": 32,
  "special_chars": true,
  "numbers": true,
  "uppercase": true
}

Response:
{
  "success": true,
  "data": {
    "password": "Xy9zK@mL2pQ!vW3nR&tY5sU8jF"
  }
}
```

### Share Password

```
POST /vaults/:vaultId/passwords/:id/share
Authorization: Bearer <token>
Content-Type: application/json

{
  "user_email": "bob@example.com",
  "permission": "view",  // view, use, edit
  "expires_in": 604800   // 7 days in seconds
}

Response:
{
  "success": true,
  "data": {
    "share_id": "shr_abc123",
    "shared_with": "bob@example.com",
    "permission": "view",
    "expires_at": "2025-01-15T10:00:00Z"
  }
}
```

### Get Password Access List

```
GET /vaults/:vaultId/passwords/:id/access
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": [
    {
      "user_email": "bob@example.com",
      "permission": "view",
      "shared_at": "2025-01-08T10:00:00Z",
      "expires_at": "2025-01-15T10:00:00Z"
    }
  ]
}
```

### Revoke Password Access

```
DELETE /vaults/:vaultId/passwords/:id/access/:userId
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Access revoked successfully"
  }
}
```

## Task Management

### Create Task

```
POST /vaults/:vaultId/tasks
Authorization: Bearer <token>
Content-Type: application/json

{
  "title": "Review code",
  "description": "Review PR #123",
  "status": "pending",  // pending, in_progress, completed
  "priority": "high",   // low, medium, high, critical
  "due_date": "2025-01-15T10:00:00Z",
  "category": "work",
  "tags": ["urgent"]
}

Response:
{
  "success": true,
  "data": {
    "id": "tsk_abc123",
    "title": "Review code",
    "status": "pending",
    "priority": "high",
    "created_at": "2025-01-08T10:00:00Z"
  }
}
```

### List Tasks

```
GET /vaults/:vaultId/tasks
Authorization: Bearer <token>

Query Parameters:
  ?status=in_progress
  ?priority=high
  ?category=work
  ?due_date=2025-01-15
  ?skip=0
  ?limit=50

Response:
{
  "success": true,
  "data": [
    {
      "id": "tsk_abc123",
      "title": "Review code",
      "status": "in_progress",
      "priority": "high",
      "due_date": "2025-01-15T10:00:00Z",
      "created_at": "2025-01-08T10:00:00Z"
    }
  ],
  "meta": {
    "total": 15,
    "skip": 0,
    "limit": 50
  }
}
```

### Get Task

```
GET /vaults/:vaultId/tasks/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "tsk_abc123",
    "title": "Review code",
    "description": "Review PR #123",
    "status": "in_progress",
    "priority": "high",
    "due_date": "2025-01-15T10:00:00Z",
    "category": "work",
    "tags": ["urgent"],
    "assigned_to": "bob@example.com",
    "created_at": "2025-01-08T10:00:00Z",
    "updated_at": "2025-01-08T10:05:00Z",
    "completed_at": null
  }
}
```

### Update Task

```
PUT /vaults/:vaultId/tasks/:id
Authorization: Bearer <token>
Content-Type: application/json

{
  "status": "completed",
  "priority": "medium"
}

Response:
{
  "success": true,
  "data": {
    "id": "tsk_abc123",
    "updated_at": "2025-01-08T10:10:00Z"
  }
}
```

### Delete Task

```
DELETE /vaults/:vaultId/tasks/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "message": "Task deleted successfully"
  }
}
```

### Complete Task

```
POST /vaults/:vaultId/tasks/:id/complete
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "id": "tsk_abc123",
    "status": "completed",
    "completed_at": "2025-01-08T10:10:00Z"
  }
}
```

### Assign Task

```
POST /vaults/:vaultId/tasks/:id/assign
Authorization: Bearer <token>
Content-Type: application/json

{
  "user_email": "bob@example.com"
}

Response:
{
  "success": true,
  "data": {
    "id": "tsk_abc123",
    "assigned_to": "bob@example.com"
  }
}
```

## Synchronization

### Get Sync Status

```
GET /sync/status
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "synced": true,
    "last_sync": "2025-01-08T10:00:00Z",
    "pending_changes": 0,
    "vault_statuses": [
      {
        "vault_id": "vlt_abc123",
        "last_modified": "2025-01-08T10:00:00Z",
        "pending": false
      }
    ]
  }
}
```

### Get Last Modified Timestamp

```
GET /sync/last-modified/:vaultId
Authorization: Bearer <token>

Response:
{
  "success": true,
  "data": {
    "vault_id": "vlt_abc123",
    "last_modified": "2025-01-08T10:00:00Z"
  }
}
```

### Full Synchronization

```
POST /sync/full
Authorization: Bearer <token>
Content-Type: application/json

{
  "vault_id": "vlt_abc123"
}

Response:
{
  "success": true,
  "data": {
    "synced_passwords": 42,
    "synced_tasks": 15,
    "conflicts_resolved": 2,
    "last_sync": "2025-01-08T10:05:00Z"
  }
}
```

### Incremental Synchronization

```
POST /sync/incremental
Authorization: Bearer <token>
Content-Type: application/json

{
  "vault_id": "vlt_abc123",
  "since": "2025-01-08T09:00:00Z"
}

Response:
{
  "success": true,
  "data": {
    "new_items": [...],
    "updated_items": [...],
    "deleted_items": [...],
    "last_sync": "2025-01-08T10:05:00Z"
  }
}
```

## Health Check

### Server Health

```
GET /health
No authentication required

Response:
{
  "success": true,
  "data": {
    "status": "healthy",
    "version": "1.0.0",
    "uptime": 86400,
    "database": "connected"
  }
}
```

### Readiness Check

```
GET /ready
No authentication required

Response:
{
  "success": true,
  "data": {
    "ready": true
  }
}
```

## Error Codes

Common error codes returned by the API:

```
200 OK - Request successful
201 Created - Resource created
204 No Content - Successful deletion
400 Bad Request - Invalid request
401 Unauthorized - Missing/invalid authentication
403 Forbidden - Insufficient permissions
404 Not Found - Resource not found
409 Conflict - Conflict with existing resource
429 Too Many Requests - Rate limit exceeded
500 Internal Server Error - Server error
503 Service Unavailable - Server maintenance
```

## Rate Limiting

API endpoints are rate-limited:

- **Default**: 100 requests per minute per user
- **Auth endpoints**: 5 requests per minute per IP
- **Token endpoints**: 50 requests per minute per user

Headers returned:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 87
X-RateLimit-Reset: 1641654000
```

## Webhooks (Future)

Webhooks for real-time notifications:

```
- password.created
- password.updated
- password.deleted
- password.shared
- task.created
- task.updated
- task.completed
- task.assigned
- vault.synced
```
