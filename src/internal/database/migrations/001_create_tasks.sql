CREATE TABLE tasks (
  id           TEXT PRIMARY KEY NOT NULL,
  title        TEXT NOT NULL CHECK (length(trim(title)) > 0),
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'in_progress', 'completed')),
  priority     TEXT CHECK (priority IS NULL OR priority IN ('low', 'medium', 'high')),
  due_date     INTEGER,
  assigned_to  TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER,
  completed_at INTEGER
);

PRAGMA user_version = 1;
