#import "PBStorageManager.h"
#import "../Shared/PBPathUtilities.h"
#import <sqlite3.h>
#import <rootless.h>

#if DEBUG_LOG
#import "../Shared/PBDiagnosticLogger.h"
#endif

#define kDatabaseDirectory PBIOSCopyDataDirectoryPath()
static NSString * const kDatabaseName = @"clipboard.db";

#if DEBUG_LOG
#define PBStorageDiagnosticLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"Storage", __VA_ARGS__)
#else
#define PBStorageDiagnosticLog(...) do { } while (0)
#endif

@interface PBStorageManager ()
@property (nonatomic, assign) sqlite3 *database;
@property (nonatomic, strong) dispatch_queue_t dbQueue;
- (PBClipboardItem *)itemFromStatement:(sqlite3_stmt *)stmt;
@end

@implementation PBStorageManager

+ (instancetype)sharedManager {
    static PBStorageManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PBStorageManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dbQueue = dispatch_queue_create("com.ssdsl.ioscopy.db", DISPATCH_QUEUE_SERIAL);
        [self setupDatabase];
    }
    return self;
}

- (NSString *)databasePath {
    return [kDatabaseDirectory stringByAppendingPathComponent:kDatabaseName];
}

- (BOOL)columnExists:(NSString *)columnName {
    BOOL exists = NO;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.database, "PRAGMA table_info(clipboard_items)", -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(stmt, 1);
            if (name && [columnName isEqualToString:[NSString stringWithUTF8String:name]]) {
                exists = YES;
                break;
            }
        }
    }
    if (stmt) {
        sqlite3_finalize(stmt);
    }
    return exists;
}

- (BOOL)addColumnIfNeeded:(NSString *)columnName definition:(const char *)definition {
    if ([self columnExists:columnName]) {
        return YES;
    }

    char *errMsg = NULL;
    BOOL success = sqlite3_exec(self.database, definition, NULL, NULL, &errMsg) == SQLITE_OK;
    if (!success) {
        PBStorageDiagnosticLog(@"failed to add column %@: %s", columnName, errMsg ?: "unknown");
    }
    if (errMsg) {
        sqlite3_free(errMsg);
    }
    return success;
}

- (BOOL)migrateDatabaseIfNeeded {
    return [self addColumnIfNeeded:@"ocr_text"
                        definition:"ALTER TABLE clipboard_items ADD COLUMN ocr_text TEXT DEFAULT ''"] &&
           [self addColumnIfNeeded:@"ocr_status"
                        definition:"ALTER TABLE clipboard_items ADD COLUMN ocr_status INTEGER DEFAULT 0"] &&
           [self addColumnIfNeeded:@"ocr_revision"
                        definition:"ALTER TABLE clipboard_items ADD COLUMN ocr_revision INTEGER DEFAULT 0"] &&
           [self addColumnIfNeeded:@"ocr_updated_at"
                        definition:"ALTER TABLE clipboard_items ADD COLUMN ocr_updated_at REAL DEFAULT 0"] &&
           [self addColumnIfNeeded:@"ocr_error"
                        definition:"ALTER TABLE clipboard_items ADD COLUMN ocr_error TEXT DEFAULT ''"];
}

- (void)closeDatabase {
    if (self.database) {
        sqlite3_close(self.database);
        self.database = NULL;
    }
}

- (BOOL)openDatabaseIfNeeded {
    if (self.database) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[self databasePath]]) {
            return YES;
        }
        [self closeDatabase];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kDatabaseDirectory]) {
        NSError *directoryError = nil;
        [fm createDirectoryAtPath:kDatabaseDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&directoryError];
        if (directoryError) {
            PBStorageDiagnosticLog(@"failed to create database directory %@: %@",
                                   kDatabaseDirectory,
                                   directoryError);
            return NO;
        }
    }

    NSString *dbPath = [self databasePath];
    sqlite3 *database = NULL;
    int openResult = sqlite3_open_v2([dbPath UTF8String],
                                     &database,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                     NULL);
    if (openResult != SQLITE_OK) {
        PBStorageDiagnosticLog(@"failed to open database at %@: %s",
                               dbPath,
                               database ? sqlite3_errmsg(database) : "unknown");
        if (database) {
            sqlite3_close(database);
        }
        self.database = NULL;
        return NO;
    }

    self.database = database;

    const char *createTable =
        "CREATE TABLE IF NOT EXISTS clipboard_items ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  content TEXT,"
        "  content_type INTEGER DEFAULT 0,"
        "  source_bundle_id TEXT DEFAULT '',"
        "  source_app_name TEXT DEFAULT 'Unknown',"
        "  timestamp REAL,"
        "  is_pinned INTEGER DEFAULT 0,"
        "  is_favorite INTEGER DEFAULT 0,"
        "  thumbnail_path TEXT DEFAULT '',"
        "  data_size INTEGER DEFAULT 0,"
        "  ocr_text TEXT DEFAULT '',"
        "  ocr_status INTEGER DEFAULT 0,"
        "  ocr_revision INTEGER DEFAULT 0,"
        "  ocr_updated_at REAL DEFAULT 0,"
        "  ocr_error TEXT DEFAULT ''"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp DESC);"
        "CREATE INDEX IF NOT EXISTS idx_pinned ON clipboard_items(is_pinned);";

    char *errMsg = NULL;
    if (sqlite3_exec(_database, createTable, NULL, NULL, &errMsg) != SQLITE_OK) {
        PBStorageDiagnosticLog(@"failed to create table: %s", errMsg);
        sqlite3_free(errMsg);
        sqlite3_close(self.database);
        self.database = NULL;
        return NO;
    }

    if (![self migrateDatabaseIfNeeded]) {
        sqlite3_close(self.database);
        self.database = NULL;
        return NO;
    }

    const char *createOCRIndex =
        "CREATE INDEX IF NOT EXISTS idx_ocr_pending "
        "ON clipboard_items(content_type, ocr_status, timestamp DESC);";
    if (sqlite3_exec(_database, createOCRIndex, NULL, NULL, &errMsg) != SQLITE_OK) {
        PBStorageDiagnosticLog(@"failed to create ocr index: %s", errMsg);
        sqlite3_free(errMsg);
        sqlite3_close(self.database);
        self.database = NULL;
        return NO;
    }

    return YES;
}

- (void)setupDatabase {
    [self openDatabaseIfNeeded];
}

- (void)dealloc {
    [self closeDatabase];
}

- (BOOL)isManagedMediaPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    NSString *standardPath = [path stringByStandardizingPath];
    NSArray<NSString *> *directories = @[
        [PBIOSCopyDataPath(@"images") stringByStandardizingPath],
        [PBIOSCopyDataPath(@"thumbnails") stringByStandardizingPath]
    ];

    for (NSString *directory in directories) {
        NSString *directoryPrefix = [directory hasSuffix:@"/"]
            ? directory
            : [directory stringByAppendingString:@"/"];
        if (![standardPath isEqualToString:directory] &&
            [standardPath hasPrefix:directoryPrefix]) {
            return YES;
        }
    }
    return NO;
}

- (NSArray<PBClipboardItem *> *)itemsForDeletionWithSQL:(const char *)sql
                                                  bind:(void (^)(sqlite3_stmt *stmt))bindBlock {
    NSMutableArray<PBClipboardItem *> *items = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (bindBlock) {
            bindBlock(stmt);
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            [items addObject:[self itemFromStatement:stmt]];
        }
        sqlite3_finalize(stmt);
    } else {
        PBStorageDiagnosticLog(@"failed to prepare deletion select statement: %s",
                               sqlite3_errmsg(self.database));
    }
    return items;
}

- (NSSet<NSString *> *)managedMediaPathsForItems:(NSArray<PBClipboardItem *> *)items {
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (PBClipboardItem *item in items) {
        if (item.contentType == PBContentTypeImage &&
            item.content.length > 0 &&
            ![item.content isEqualToString:@"[Image]"] &&
            [self isManagedMediaPath:item.content]) {
            [paths addObject:item.content];
        }
        if (item.thumbnailPath.length > 0 &&
            [self isManagedMediaPath:item.thumbnailPath]) {
            [paths addObject:item.thumbnailPath];
        }
    }
    return [paths copy];
}

- (BOOL)mediaPathIsStillReferenced:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    BOOL referenced = NO;
    const char *sql =
        "SELECT 1 FROM clipboard_items "
        "WHERE (content_type = ? AND content = ?) OR thumbnail_path = ? "
        "LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, (int)PBContentTypeImage);
        sqlite3_bind_text(stmt, 2, [path UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [path UTF8String], -1, SQLITE_TRANSIENT);
        referenced = sqlite3_step(stmt) == SQLITE_ROW;
        sqlite3_finalize(stmt);
    }
    return referenced;
}

- (void)removeManagedMediaFilesForDeletedItems:(NSArray<PBClipboardItem *> *)items {
    NSSet<NSString *> *paths = [self managedMediaPathsForItems:items];
    if (paths.count == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if (![self isManagedMediaPath:path] || [self mediaPathIsStillReferenced:path]) {
            continue;
        }

        NSError *error = nil;
        if (![fileManager removeItemAtPath:path error:&error] && error) {
            PBStorageDiagnosticLog(@"failed to remove media file %@: %@",
                                   path,
                                   error);
        }
    }
}

#pragma mark - CRUD

- (BOOL)saveItem:(PBClipboardItem *)item {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "INSERT INTO clipboard_items "
            "(content, content_type, source_bundle_id, source_app_name, "
            "timestamp, is_pinned, is_favorite, thumbnail_path, data_size) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [item.content UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmt, 2, (int)item.contentType);
            sqlite3_bind_text(stmt, 3, [item.sourceBundleId UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 4, [item.sourceAppName UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(stmt, 5, item.timestamp);
            sqlite3_bind_int(stmt, 6, item.isPinned ? 1 : 0);
            sqlite3_bind_int(stmt, 7, item.isFavorite ? 1 : 0);
            sqlite3_bind_text(stmt, 8, [item.thumbnailPath UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmt, 9, (int)item.dataSize);

            success = (sqlite3_step(stmt) == SQLITE_DONE);
            if (success) {
                item.itemId = (NSInteger)sqlite3_last_insert_rowid(self.database);
            }
            sqlite3_finalize(stmt);
        } else {
            PBStorageDiagnosticLog(@"failed to prepare save statement: %s", sqlite3_errmsg(self.database));
        }
    });
    return success;
}

- (PBClipboardItem *)itemFromStatement:(sqlite3_stmt *)stmt {
    PBClipboardItem *item = [[PBClipboardItem alloc] init];
    item.itemId = sqlite3_column_int64(stmt, 0);

    const char *content = (const char *)sqlite3_column_text(stmt, 1);
    item.content = content ? [NSString stringWithUTF8String:content] : @"";

    item.contentType = (PBContentType)sqlite3_column_int(stmt, 2);

    const char *bundleId = (const char *)sqlite3_column_text(stmt, 3);
    item.sourceBundleId = bundleId ? [NSString stringWithUTF8String:bundleId] : @"";

    const char *appName = (const char *)sqlite3_column_text(stmt, 4);
    item.sourceAppName = appName ? [NSString stringWithUTF8String:appName] : @"Unknown";

    item.timestamp = sqlite3_column_double(stmt, 5);
    item.isPinned = sqlite3_column_int(stmt, 6) == 1;
    item.isFavorite = sqlite3_column_int(stmt, 7) == 1;

    const char *thumbPath = (const char *)sqlite3_column_text(stmt, 8);
    item.thumbnailPath = thumbPath ? [NSString stringWithUTF8String:thumbPath] : @"";

    item.dataSize = sqlite3_column_int64(stmt, 9);
    if (sqlite3_column_count(stmt) >= 14) {
        const char *ocrText = (const char *)sqlite3_column_text(stmt, 10);
        item.ocrText = ocrText ? [NSString stringWithUTF8String:ocrText] : @"";
        item.ocrStatus = (PBOCRStatus)sqlite3_column_int(stmt, 11);
        item.ocrRevision = sqlite3_column_int(stmt, 12);
        item.ocrUpdatedAt = sqlite3_column_double(stmt, 13);
        if (sqlite3_column_count(stmt) >= 15) {
            const char *ocrError = (const char *)sqlite3_column_text(stmt, 14);
            item.ocrError = ocrError ? [NSString stringWithUTF8String:ocrError] : @"";
        } else {
            item.ocrError = @"";
        }
    } else {
        item.ocrText = @"";
        item.ocrError = @"";
        item.ocrStatus = PBOCRStatusPending;
        item.ocrRevision = 0;
        item.ocrUpdatedAt = 0;
    }

    return item;
}

- (NSArray<PBClipboardItem *> *)allItemsWithLimit:(NSInteger)limit {
    __block NSMutableArray *items = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        // Pinned items first, then by timestamp descending
        const char *sql = "SELECT * FROM clipboard_items "
            "ORDER BY is_pinned DESC, timestamp DESC LIMIT ?";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)limit);

            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [items addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return items;
}

- (NSArray<PBClipboardItem *> *)searchItemsWithQuery:(NSString *)query limit:(NSInteger)limit {
    return [self searchItemsWithQuery:query limit:limit includeOCR:YES];
}

- (NSArray<PBClipboardItem *> *)searchItemsWithQuery:(NSString *)query
                                               limit:(NSInteger)limit
                                          includeOCR:(BOOL)includeOCR {
    __block NSMutableArray *items = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = includeOCR
            ? "SELECT * FROM clipboard_items "
              "WHERE content LIKE ? OR source_app_name LIKE ? OR ocr_text LIKE ? "
              "ORDER BY is_pinned DESC, timestamp DESC LIMIT ?"
            : "SELECT * FROM clipboard_items "
              "WHERE content LIKE ? OR source_app_name LIKE ? "
              "ORDER BY is_pinned DESC, timestamp DESC LIMIT ?";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            NSString *pattern = [NSString stringWithFormat:@"%%%@%%", query];
            sqlite3_bind_text(stmt, 1, [pattern UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, [pattern UTF8String], -1, SQLITE_TRANSIENT);
            if (includeOCR) {
                sqlite3_bind_text(stmt, 3, [pattern UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmt, 4, (int)limit);
            } else {
                sqlite3_bind_int(stmt, 3, (int)limit);
            }

            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [items addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return items;
}

- (NSArray<PBClipboardItem *> *)imageItemsNeedingOCRWithLimit:(NSInteger)limit {
    return [self imageItemsNeedingOCRWithLimit:limit includeFailed:NO];
}

- (NSArray<PBClipboardItem *> *)imageItemsNeedingOCRWithLimit:(NSInteger)limit
                                                includeFailed:(BOOL)includeFailed {
    __block NSMutableArray *items = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = includeFailed
            ? "SELECT * FROM clipboard_items "
              "WHERE content_type = ? AND ocr_status IN (?, ?) AND IFNULL(content, '') != '' "
              "ORDER BY timestamp DESC LIMIT ?"
            : "SELECT * FROM clipboard_items "
              "WHERE content_type = ? AND ocr_status = ? AND IFNULL(content, '') != '' "
              "ORDER BY timestamp DESC LIMIT ?";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)PBContentTypeImage);
            sqlite3_bind_int(stmt, 2, (int)PBOCRStatusPending);
            if (includeFailed) {
                sqlite3_bind_int(stmt, 3, (int)PBOCRStatusFailed);
                sqlite3_bind_int(stmt, 4, (int)limit);
            } else {
                sqlite3_bind_int(stmt, 3, (int)limit);
            }

            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [items addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return items;
}

- (BOOL)updateOCRText:(NSString *)text
               status:(PBOCRStatus)status
             revision:(NSInteger)revision
                error:(NSString *)error
            forItemId:(NSInteger)itemId {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "UPDATE clipboard_items "
            "SET ocr_text = ?, ocr_status = ?, ocr_revision = ?, ocr_updated_at = ?, ocr_error = ? "
            "WHERE id = ?";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            NSString *ocrText = text ?: @"";
            sqlite3_bind_text(stmt, 1, [ocrText UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmt, 2, (int)status);
            sqlite3_bind_int(stmt, 3, (int)revision);
            sqlite3_bind_double(stmt, 4, [[NSDate date] timeIntervalSince1970]);
            sqlite3_bind_text(stmt, 5, [(error ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmt, 6, itemId);
            success = sqlite3_step(stmt) == SQLITE_DONE;
            sqlite3_finalize(stmt);
        }
    });
    return success;
}

- (NSArray<PBClipboardItem *> *)pinnedItems {
    __block NSMutableArray *items = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "SELECT * FROM clipboard_items WHERE is_pinned = 1 ORDER BY timestamp DESC";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [items addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return items;
}

- (NSArray<PBClipboardItem *> *)favoriteItems {
    __block NSMutableArray *items = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "SELECT * FROM clipboard_items WHERE is_favorite = 1 ORDER BY timestamp DESC";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [items addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return items;
}

- (BOOL)deleteItem:(PBClipboardItem *)item {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        NSArray<PBClipboardItem *> *deletedItems =
            [self itemsForDeletionWithSQL:"SELECT * FROM clipboard_items WHERE id = ?"
                                     bind:^(sqlite3_stmt *selectStmt) {
            sqlite3_bind_int64(selectStmt, 1, item.itemId);
        }];

        const char *sql = "DELETE FROM clipboard_items WHERE id = ?";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, item.itemId);
            success = (sqlite3_step(stmt) == SQLITE_DONE);
            int changedRows = sqlite3_changes(self.database);
            sqlite3_finalize(stmt);
            if (success && changedRows > 0) {
                [self removeManagedMediaFilesForDeletedItems:deletedItems];
            }
        }
    });
    return success;
}

- (BOOL)deleteAllItems {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        NSArray<PBClipboardItem *> *deletedItems =
            [self itemsForDeletionWithSQL:"SELECT * FROM clipboard_items"
                                     bind:nil];

        const char *sql = "DELETE FROM clipboard_items";
        char *errMsg = NULL;
        success = (sqlite3_exec(self.database, sql, NULL, NULL, &errMsg) == SQLITE_OK);
        if (errMsg) sqlite3_free(errMsg);
        if (success) {
            [self removeManagedMediaFilesForDeletedItems:deletedItems];
        }
    });
    return success;
}

- (BOOL)togglePinForItem:(PBClipboardItem *)item {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, item.isPinned ? 0 : 1);
            sqlite3_bind_int64(stmt, 2, item.itemId);
            success = (sqlite3_step(stmt) == SQLITE_DONE);
            if (success) item.isPinned = !item.isPinned;
            sqlite3_finalize(stmt);
        }
    });
    return success;
}

- (BOOL)toggleFavoriteForItem:(PBClipboardItem *)item {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, item.isFavorite ? 0 : 1);
            sqlite3_bind_int64(stmt, 2, item.itemId);
            success = (sqlite3_step(stmt) == SQLITE_DONE);
            if (success) item.isFavorite = !item.isFavorite;
            sqlite3_finalize(stmt);
        }
    });
    return success;
}

#pragma mark - Maintenance

- (void)cleanupOldItemsWithMaxCount:(NSInteger)maxCount {
    dispatch_async(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        // Keep pinned items, delete oldest non-pinned items exceeding max count
        const char *selectSQL = "SELECT * FROM clipboard_items "
            "WHERE is_pinned = 0 AND id NOT IN ("
            "  SELECT id FROM ("
            "    SELECT id FROM clipboard_items "
            "    WHERE is_pinned = 0 "
            "    ORDER BY timestamp DESC LIMIT ?"
            "  )"
            ")";
        NSArray<PBClipboardItem *> *deletedItems =
            [self itemsForDeletionWithSQL:selectSQL
                                     bind:^(sqlite3_stmt *selectStmt) {
            sqlite3_bind_int(selectStmt, 1, (int)maxCount);
        }];
        if (deletedItems.count == 0) {
            return;
        }

        const char *sql = "DELETE FROM clipboard_items "
            "WHERE is_pinned = 0 AND id NOT IN ("
            "  SELECT id FROM ("
            "    SELECT id FROM clipboard_items "
            "    WHERE is_pinned = 0 "
            "    ORDER BY timestamp DESC LIMIT ?"
            "  )"
            ")";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)maxCount);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                PBStorageDiagnosticLog(@"failed to cleanup old items: %s", sqlite3_errmsg(self.database));
            } else {
                [self removeManagedMediaFilesForDeletedItems:deletedItems];
            }
            sqlite3_finalize(stmt);
        } else {
            PBStorageDiagnosticLog(@"failed to prepare cleanup statement: %s", sqlite3_errmsg(self.database));
        }
    });
}

- (void)cleanupItemsOlderThanDays:(NSInteger)days {
    if (days <= 0) {
        return;
    }

    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)days * 24.0 * 60.0 * 60.0;
    dispatch_async(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *selectSQL = "SELECT * FROM clipboard_items "
            "WHERE is_pinned = 0 AND timestamp < ?";

        // 置顶内容通常是用户明确保留的，按天数清理时跳过。
        NSArray<PBClipboardItem *> *deletedItems =
            [self itemsForDeletionWithSQL:selectSQL
                                     bind:^(sqlite3_stmt *selectStmt) {
            sqlite3_bind_double(selectStmt, 1, cutoff);
        }];
        if (deletedItems.count == 0) {
            return;
        }

        const char *sql = "DELETE FROM clipboard_items "
            "WHERE is_pinned = 0 AND timestamp < ?";

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_double(stmt, 1, cutoff);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                PBStorageDiagnosticLog(@"failed to cleanup expired items: %s", sqlite3_errmsg(self.database));
            } else {
                [self removeManagedMediaFilesForDeletedItems:deletedItems];
            }
            sqlite3_finalize(stmt);
        } else {
            PBStorageDiagnosticLog(@"failed to prepare expired cleanup statement: %s", sqlite3_errmsg(self.database));
        }
    });
}

- (NSInteger)totalItemCount {
    __block NSInteger count = 0;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "SELECT COUNT(*) FROM clipboard_items";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                count = sqlite3_column_int64(stmt, 0);
            }
            sqlite3_finalize(stmt);
        }
    });
    return count;
}

- (BOOL)isDuplicateContent:(NSString *)content {
    __block BOOL duplicate = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        // Check if the most recent item has the same content
        const char *sql = "SELECT content FROM clipboard_items ORDER BY timestamp DESC LIMIT 1";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *lastContent = (const char *)sqlite3_column_text(stmt, 0);
                if (lastContent) {
                    duplicate = [content isEqualToString:[NSString stringWithUTF8String:lastContent]];
                }
            }
            sqlite3_finalize(stmt);
        }
    });
    return duplicate;
}

- (BOOL)getLatestItemType:(PBContentType *)outType size:(NSInteger *)outSize content:(NSString **)outContent {
    __block BOOL success = NO;
    __block PBContentType type = PBContentTypeText;
    __block NSInteger size = 0;
    __block NSString *content = nil;
    dispatch_sync(self.dbQueue, ^{
        if (![self openDatabaseIfNeeded]) return;

        const char *sql = "SELECT content_type, data_size, content FROM clipboard_items ORDER BY timestamp DESC LIMIT 1";
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.database, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                type = (PBContentType)sqlite3_column_int(stmt, 0);
                size = sqlite3_column_int64(stmt, 1);
                const char *contentVal = (const char *)sqlite3_column_text(stmt, 2);
                if (contentVal) {
                    content = [NSString stringWithUTF8String:contentVal];
                }
                success = YES;
            }
            sqlite3_finalize(stmt);
        }
    });
    if (outType) *outType = type;
    if (outSize) *outSize = size;
    if (outContent) *outContent = content;
    return success;
}

@end
