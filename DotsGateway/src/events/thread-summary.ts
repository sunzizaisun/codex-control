// Stable indexed list projection. Updates occur in the same SQLite statement
// and transaction as the message, including rollback on later outbox errors.
export function initializeThreadSummaries(storage: DurableObjectStorage) {
  storage.transactionSync(() => {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS thread_summaries (
      thread_id TEXT PRIMARY KEY, first_sequence INTEGER NOT NULL,
      title TEXT NOT NULL, updated_at INTEGER NOT NULL)`);
    storage.sql.exec("CREATE INDEX IF NOT EXISTS thread_summary_page ON thread_summaries(updated_at, thread_id)");
    storage.sql.exec("CREATE TABLE IF NOT EXISTS thread_summary_migrations (version INTEGER PRIMARY KEY)");
    storage.sql.exec(`CREATE TRIGGER IF NOT EXISTS thread_summary_insert AFTER INSERT ON messages BEGIN
      INSERT INTO thread_summaries VALUES (NEW.thread_id, NEW.sequence, NEW.text, MAX(NEW.created_at, COALESCE(NEW.replied_at, 0)))
      ON CONFLICT(thread_id) DO UPDATE SET
        title = CASE WHEN excluded.first_sequence < first_sequence THEN excluded.title ELSE title END,
        first_sequence = MIN(first_sequence, excluded.first_sequence),
        updated_at = MAX(updated_at, excluded.updated_at);
    END`);
    storage.sql.exec(`CREATE TRIGGER IF NOT EXISTS thread_summary_reply AFTER UPDATE OF replied_at ON messages BEGIN
      UPDATE thread_summaries SET updated_at = MAX(updated_at, MAX(NEW.created_at, COALESCE(NEW.replied_at, 0)))
      WHERE thread_id = NEW.thread_id;
    END`);
    if (!storage.sql.exec("SELECT version FROM thread_summary_migrations WHERE version = 1").toArray().length) {
      // One additive migration over existing history; normal reads never
      // regroup that history. The marker is committed with the projection.
      storage.sql.exec(`INSERT OR REPLACE INTO thread_summaries
        SELECT m.thread_id, m.sequence, m.text, latest.updated FROM messages m
        JOIN (SELECT thread_id, MIN(sequence) AS first, MAX(MAX(created_at, COALESCE(replied_at, 0))) AS updated
          FROM messages GROUP BY thread_id) latest ON m.sequence = latest.first`);
      storage.sql.exec("INSERT INTO thread_summary_migrations VALUES (1)");
    }
  });
}

export const threadSummaryPageQuery = `SELECT thread_id AS id, title, updated_at AS updatedAt
  FROM thread_summaries WHERE (updated_at, thread_id) < (?, ?)
  ORDER BY updated_at DESC, thread_id DESC LIMIT 21`;
