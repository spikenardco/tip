# JSON Storage

Persists vault data as human-readable JSON files. Uses atomic writes (write to temp, rename) to avoid corruption. Best for single-user local use. This is the only storage backend that works today.
