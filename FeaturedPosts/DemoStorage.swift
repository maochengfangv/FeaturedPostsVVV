import Foundation
import SQLite3

/// SQLite 原生句柄的轻量封装。
/// 负责连接生命周期、SQL 执行与 statement 预编译。
final class SQLiteDatabase {
    private let db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw NSError(domain: "SQLiteDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(err)
            throw NSError(domain: "SQLiteDatabase", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return stmt
    }

    func beginTransaction() throws { try execute("BEGIN;") }
    func commit() throws { try execute("COMMIT;") }
    func rollback() throws { try execute("ROLLBACK;") }
}

/// 帖子持久层实现。
/// 通过串行队列保证线程安全，对外提供帖子缓存读写能力。
final class SQLitePostStore {
    private let db: SQLiteDatabase
    private let queue = DispatchQueue(label: "SQLitePostStore.queue")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try! self.init(directory: dir)
    }

    init(directory: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let path = directory.appendingPathComponent("feed.sqlite").path
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    /// 初始化数据库表结构与索引。
    /// 当前版本仅包含 posts 表，后续可在这里继续扩展迁移逻辑。
    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS posts (
            id TEXT PRIMARY KEY NOT NULL,
            author TEXT NOT NULL,
            text TEXT NOT NULL,
            image_urls TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC);")
    }

    /// 批量保存帖子。
    /// 使用事务保证一批数据要么全部成功，要么全部回滚，避免脏数据。
    func save(posts: [Post]) throws {
        try queue.sync {
            try db.beginTransaction()
            do {
                let sql = """
                INSERT INTO posts (id, author, text, image_urls, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    author=excluded.author,
                    text=excluded.text,
                    image_urls=excluded.image_urls,
                    created_at=excluded.created_at;
                """
                for p in posts {
                    try autoreleasepool {
                        let stmt = try db.prepare(sql)
                        defer { sqlite3_finalize(stmt) }

                        sqlite3_bind_text(stmt, 1, (p.id as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (p.author as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 3, (p.text as NSString).utf8String, -1, nil)

                        let urlsData = try encoder.encode(p.imageURLs.map(\.absoluteString))
                        let urlsString = String(data: urlsData, encoding: .utf8) ?? "[]"
                        sqlite3_bind_text(stmt, 4, (urlsString as NSString).utf8String, -1, nil)

                        sqlite3_bind_double(stmt, 5, p.createdAt.timeIntervalSince1970)

                        if sqlite3_step(stmt) != SQLITE_DONE {
                            throw NSError(domain: "SQLitePostStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "SQLite step failed"])
                        }
                    }
                }
                try db.commit()
            } catch {
                try? db.rollback()
                throw error
            }
        }
    }

    /// 按创建时间倒序读取最新帖子，用于冷启动缓存回填与离线降级展示。
    func fetchLatest(limit: Int) throws -> [Post] {
        try queue.sync {
            let sql = """
            SELECT id, author, text, image_urls, created_at
            FROM posts
            ORDER BY created_at DESC
            LIMIT ?;
            """
            let stmt = try db.prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var result: [Post] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let author = String(cString: sqlite3_column_text(stmt, 1))
                let text = String(cString: sqlite3_column_text(stmt, 2))
                let urlsString = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

                let urlData = urlsString.data(using: .utf8) ?? Data("[]".utf8)
                let urlStrings = (try? decoder.decode([String].self, from: urlData)) ?? []
                let urls = urlStrings.compactMap(URL.init(string:))

                result.append(Post(id: id, author: author, text: text, imageURLs: urls, createdAt: createdAt))
            }
            return result
        }
    }
}

/// 通过协议暴露持久化能力，避免上层直接依赖具体 SQLite 实现。
extension SQLitePostStore: PostStoring {}