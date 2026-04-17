# database-rotation.tf — Vault Database Secrets Engine for PostgreSQL
# Configures dynamic credential generation with automatic rotation.
# Vault creates short-lived database credentials on demand, eliminating
# the need for long-lived static passwords.

# ─── Database Secrets Engine Mount ────────────────────────────────────────────
resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Dynamic database credential generation"

  default_lease_ttl_seconds = var.db_default_ttl
  max_lease_ttl_seconds     = var.db_max_ttl
}

# ─── PostgreSQL Connection Configuration ──────────────────────────────────────
resource "vault_database_secret_backend_connection" "postgresql" {
  backend       = vault_mount.database.path
  name          = "postgresql"
  allowed_roles = ["app-readonly", "app-readwrite", "migration"]

  postgresql {
    connection_url          = var.db_connection_url
    max_open_connections    = var.db_max_open_connections
    max_idle_connections    = var.db_max_idle_connections
    max_connection_lifetime = var.db_max_connection_lifetime
    username                = var.db_admin_username
    password                = var.db_admin_password
  }

  # Rotate the root credential after initial setup so even the admin
  # password is managed by Vault and not stored anywhere else
  verify_connection = true
}

# ─── Dynamic Role: Read-Only Access ──────────────────────────────────────────
# Used by application services that only need SELECT permissions.
resource "vault_database_secret_backend_role" "app_readonly" {
  backend = vault_mount.database.path
  name    = "app-readonly"
  db_name = vault_database_secret_backend_connection.postgresql.name

  default_ttl = var.db_role_readonly_ttl
  max_ttl     = var.db_role_readonly_max_ttl

  creation_statements = [
    <<-SQL
      CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "{{name}}";
    SQL
  ]

  revocation_statements = [
    <<-SQL
      REASSIGN OWNED BY "{{name}}" TO postgres;
      DROP OWNED BY "{{name}}";
      DROP ROLE IF EXISTS "{{name}}";
    SQL
  ]

  renew_statements = [
    <<-SQL
      ALTER ROLE "{{name}}" VALID UNTIL '{{expiration}}';
    SQL
  ]
}

# ─── Dynamic Role: Read-Write Access ─────────────────────────────────────────
# Used by application services that need full CRUD operations.
resource "vault_database_secret_backend_role" "app_readwrite" {
  backend = vault_mount.database.path
  name    = "app-readwrite"
  db_name = vault_database_secret_backend_connection.postgresql.name

  default_ttl = var.db_role_readwrite_ttl
  max_ttl     = var.db_role_readwrite_max_ttl

  creation_statements = [
    <<-SQL
      CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
      GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{name}}";
      GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{{name}}";
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "{{name}}";
    SQL
  ]

  revocation_statements = [
    <<-SQL
      REASSIGN OWNED BY "{{name}}" TO postgres;
      DROP OWNED BY "{{name}}";
      DROP ROLE IF EXISTS "{{name}}";
    SQL
  ]

  renew_statements = [
    <<-SQL
      ALTER ROLE "{{name}}" VALID UNTIL '{{expiration}}';
    SQL
  ]
}

# ─── Dynamic Role: Migration Access ──────────────────────────────────────────
# Used by CI/CD pipelines for schema migrations. Has DDL permissions
# but a very short TTL to minimize exposure window.
resource "vault_database_secret_backend_role" "migration" {
  backend = vault_mount.database.path
  name    = "migration"
  db_name = vault_database_secret_backend_connection.postgresql.name

  default_ttl = var.db_role_migration_ttl
  max_ttl     = var.db_role_migration_max_ttl

  creation_statements = [
    <<-SQL
      CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
      GRANT ALL PRIVILEGES ON DATABASE {{database}} TO "{{name}}";
      GRANT ALL PRIVILEGES ON SCHEMA public TO "{{name}}";
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "{{name}}";
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";
    SQL
  ]

  revocation_statements = [
    <<-SQL
      REASSIGN OWNED BY "{{name}}" TO postgres;
      DROP OWNED BY "{{name}}";
      DROP ROLE IF EXISTS "{{name}}";
    SQL
  ]
}

# ─── Static Role: Root Credential Rotation ────────────────────────────────────
# Rotates the admin/root database password on a schedule.
# After rotation, only Vault knows the current password.
resource "vault_database_secret_backend_static_role" "root_rotation" {
  backend  = vault_mount.database.path
  name     = "root-rotation"
  db_name  = vault_database_secret_backend_connection.postgresql.name
  username = var.db_admin_username

  rotation_period  = var.db_root_rotation_period
  rotation_window {
    hour_of_day    = var.db_rotation_window_hour
    minute_of_hour = var.db_rotation_window_minute
  }
}

# ─── Vault Policy: Database Consumers ─────────────────────────────────────────
# Policy that allows applications to request dynamic database credentials.
resource "vault_policy" "database_consumer" {
  name   = "database-consumer"
  policy = <<-HCL
    # Request read-only database credentials
    path "database/creds/app-readonly" {
      capabilities = ["read"]
    }

    # Request read-write database credentials
    path "database/creds/app-readwrite" {
      capabilities = ["read"]
    }

    # Renew leases for database credentials
    path "sys/leases/renew" {
      capabilities = ["update"]
    }

    # Revoke own leases (clean shutdown)
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  HCL
}

# ─── Vault Policy: Migration Runner ──────────────────────────────────────────
# Restricted policy for CI/CD migration jobs.
resource "vault_policy" "database_migration" {
  name   = "database-migration"
  policy = <<-HCL
    # Request migration-level database credentials
    path "database/creds/migration" {
      capabilities = ["read"]
    }

    # Revoke credentials after migration completes
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  HCL
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "db_connection_url" {
  description = "PostgreSQL connection URL for Vault (e.g., postgresql://{{username}}:{{password}}@host:5432/dbname)"
  type        = string
  default     = "postgresql://{{username}}:{{password}}@postgres:5432/app?sslmode=disable"
}

variable "db_admin_username" {
  description = "Database admin username for initial connection"
  type        = string
  default     = "vault_admin"
}

variable "db_admin_password" {
  description = "Database admin password for initial connection"
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_default_ttl" {
  description = "Default lease TTL for database secrets engine (seconds)"
  type        = number
  default     = 3600 # 1 hour

  validation {
    condition     = var.db_default_ttl >= 300
    error_message = "Default TTL must be at least 300 seconds (5 minutes)."
  }
}

variable "db_max_ttl" {
  description = "Maximum lease TTL for database secrets engine (seconds)"
  type        = number
  default     = 86400 # 24 hours

  validation {
    condition     = var.db_max_ttl >= 3600
    error_message = "Max TTL must be at least 3600 seconds (1 hour)."
  }
}

variable "db_max_open_connections" {
  description = "Maximum number of open connections to the database"
  type        = number
  default     = 5
}

variable "db_max_idle_connections" {
  description = "Maximum number of idle connections to the database"
  type        = number
  default     = 3
}

variable "db_max_connection_lifetime" {
  description = "Maximum time a connection may be reused (seconds)"
  type        = number
  default     = 0 # unlimited
}

variable "db_role_readonly_ttl" {
  description = "Default TTL for read-only database credentials (seconds)"
  type        = number
  default     = 3600 # 1 hour
}

variable "db_role_readonly_max_ttl" {
  description = "Maximum TTL for read-only database credentials (seconds)"
  type        = number
  default     = 28800 # 8 hours
}

variable "db_role_readwrite_ttl" {
  description = "Default TTL for read-write database credentials (seconds)"
  type        = number
  default     = 1800 # 30 minutes
}

variable "db_role_readwrite_max_ttl" {
  description = "Maximum TTL for read-write database credentials (seconds)"
  type        = number
  default     = 14400 # 4 hours
}

variable "db_role_migration_ttl" {
  description = "Default TTL for migration database credentials (seconds)"
  type        = number
  default     = 600 # 10 minutes
}

variable "db_role_migration_max_ttl" {
  description = "Maximum TTL for migration database credentials (seconds)"
  type        = number
  default     = 1800 # 30 minutes
}

variable "db_root_rotation_period" {
  description = "Root credential rotation period (seconds)"
  type        = number
  default     = 2592000 # 30 days
}

variable "db_rotation_window_hour" {
  description = "Hour of day (UTC) for root credential rotation window"
  type        = number
  default     = 4 # 4:00 AM UTC

  validation {
    condition     = var.db_rotation_window_hour >= 0 && var.db_rotation_window_hour <= 23
    error_message = "Hour must be between 0 and 23."
  }
}

variable "db_rotation_window_minute" {
  description = "Minute of hour for root credential rotation window"
  type        = number
  default     = 0

  validation {
    condition     = var.db_rotation_window_minute >= 0 && var.db_rotation_window_minute <= 59
    error_message = "Minute must be between 0 and 59."
  }
}
