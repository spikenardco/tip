CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY NOT NULL,
  title        TEXT NOT NULL,
  description  TEXT,
  status       TEXT NOT NULL DEFAULT 'pending',
  priority     TEXT,
  due_date     INTEGER,
  assigned_to  TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER,
  completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);

INSERT OR IGNORE INTO _schema_version (version) VALUES (2);
