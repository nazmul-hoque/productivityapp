import GRDB

/// The SQLite schema, following the data model in the spec (§8.3).
///
/// Every row carries `user_id`, `created_at` and `updated_at` so it can sync later.
/// Timestamps are seconds since 2001-01-01 (`Date`'s reference date); days are `yyyy-mm-dd` text.
/// Ordering uses fractional-index strings in `sort_key` (`order` is an SQL keyword).
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE area (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    sort_key TEXT NOT NULL,
                    user_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE tag (
                    id TEXT PRIMARY KEY NOT NULL,
                    parent_id TEXT REFERENCES tag(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    sort_key TEXT NOT NULL,
                    user_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE area_tag (
                    area_id TEXT NOT NULL REFERENCES area(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (area_id, tag_id)
                );

                CREATE TABLE project (
                    id TEXT PRIMARY KEY NOT NULL,
                    area_id TEXT REFERENCES area(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    notes TEXT NOT NULL,
                    start_bucket TEXT NOT NULL,      -- inbox | anytime | someday | scheduled
                    start_date TEXT,                 -- yyyy-mm-dd when scheduled
                    deadline TEXT,
                    status TEXT NOT NULL,            -- open | completed | canceled
                    sort_key TEXT NOT NULL,
                    user_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    deleted_at REAL
                );

                CREATE TABLE project_tag (
                    project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (project_id, tag_id)
                );

                CREATE TABLE heading (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    sort_key TEXT NOT NULL,
                    user_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE todo (
                    id TEXT PRIMARY KEY NOT NULL,
                    area_id TEXT REFERENCES area(id) ON DELETE SET NULL,
                    project_id TEXT REFERENCES project(id) ON DELETE SET NULL,
                    heading_id TEXT REFERENCES heading(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    notes TEXT NOT NULL,
                    start_bucket TEXT NOT NULL,
                    start_date TEXT,
                    is_evening BOOLEAN NOT NULL,
                    deadline TEXT,
                    reminder TEXT,                   -- HH:MM
                    repeat_series_id TEXT,
                    repeat_rule TEXT,                -- JSON-encoded RepeatRule
                    repeat_occurrence TEXT,
                    repeat_index INTEGER,
                    status TEXT NOT NULL,
                    sort_key TEXT NOT NULL,
                    today_sort_key TEXT,
                    user_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    deleted_at REAL
                );
                CREATE INDEX todo_project ON todo(project_id);
                CREATE INDEX todo_area ON todo(area_id);
                CREATE INDEX todo_start ON todo(start_bucket, start_date);

                CREATE TABLE checklist_item (
                    id TEXT PRIMARY KEY NOT NULL,
                    todo_id TEXT NOT NULL REFERENCES todo(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    is_done BOOLEAN NOT NULL,
                    position INTEGER NOT NULL
                );
                CREATE INDEX checklist_item_todo ON checklist_item(todo_id);

                CREATE TABLE todo_tag (
                    todo_id TEXT NOT NULL REFERENCES todo(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (todo_id, tag_id)
                );
                CREATE INDEX todo_tag_tag ON todo_tag(tag_id);
                """)
        }
        migrator.registerMigration("v2: meta") { db in
            // Store-level flags. A store that already holds data has been initialized; mark it so
            // emptying it later doesn't bring the first-launch content back.
            try db.execute(sql: """
                CREATE TABLE meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT INTO meta (key, value)
                    SELECT 'initialized', '1'
                    WHERE EXISTS (SELECT 1 FROM todo) OR EXISTS (SELECT 1 FROM project)
                       OR EXISTS (SELECT 1 FROM area) OR EXISTS (SELECT 1 FROM tag);
                """)
        }
        return migrator
    }
}
