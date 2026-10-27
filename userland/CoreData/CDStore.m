// SPDX-License-Identifier: MIT OR Apache-2.0
#import "CDInternal.h"

static NSString *CDQuote(NSString *value) {
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

NSString *CDTableName(NSEntityDescription *entity) {
    return [@"Z" stringByAppendingString:[entity.name uppercaseString]];
}

sqlite3 *CDStoreDatabase(NSPersistentStore *store) {
    NSValue *value = store ? CDGet(store, @"database") : nil;
    return value ? [value pointerValue] : NULL;
}

NSInteger CDEntityID(NSPersistentStore *store, NSEntityDescription *entity) {
    NSNumber *number = [CDGet(store, @"entityIDs") objectForKey:entity.name];
    return number ? [number integerValue] : 0;
}

static NSError *CDSQLiteError(sqlite3 *db, NSString *action) {
    NSString *reason = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"SQLite could not be opened";
    return CDError(134030, [NSString stringWithFormat:@"%@ (%@)", action, reason]);
}

static BOOL CDExec(sqlite3 *db, NSString *sql, NSError **error) {
    char *message = NULL;
    int result = sqlite3_exec(db, [sql UTF8String], NULL, NULL, &message);
    if (result == SQLITE_OK) return YES;
    NSString *detail = message ? [NSString stringWithUTF8String:message] : [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    if (message) sqlite3_free(message);
    return CDReturnError(error, CDError(134030, [NSString stringWithFormat:@"SQLite statement failed: %@", detail]));
}

static BOOL CDTableExists(sqlite3 *db, NSString *name) {
    sqlite3_stmt *statement = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
        found = sqlite3_step(statement) == SQLITE_ROW;
    }
    sqlite3_finalize(statement);
    return found;
}

static BOOL CDColumnExists(sqlite3 *db, NSString *table, NSString *column) {
    sqlite3_stmt *statement = NULL;
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", CDQuote(table)];
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(statement, 1);
            if (name && [column isEqualToString:[NSString stringWithUTF8String:name]]) { found = YES; break; }
        }
    }
    sqlite3_finalize(statement);
    return found;
}

static NSDictionary *CDReadMetadata(sqlite3 *db) {
    sqlite3_stmt *statement = NULL;
    NSDictionary *metadata = nil;
    if (sqlite3_prepare_v2(db, "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(statement, 0);
        int length = sqlite3_column_bytes(statement, 0);
        if (bytes && length > 0) {
            NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
            metadata = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
        }
    }
    sqlite3_finalize(statement);
    return metadata;
}

static BOOL CDWriteMetadata(sqlite3 *db, NSDictionary *metadata, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:metadata
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:error];
    if (!data) return NO;
    sqlite3_stmt *statement = NULL;
    const char *sql = "INSERT OR REPLACE INTO Z_METADATA (Z_VERSION, Z_UUID, Z_PLIST) VALUES (1, ?1, ?2)";
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"Could not write the store metadata"));
    NSString *uuid = [metadata objectForKey:NSStoreUUIDKey] ?: @"";
    sqlite3_bind_text(statement, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_blob(statement, 2, [data bytes], (int)[data length], SQLITE_TRANSIENT);
    int result = sqlite3_step(statement);
    sqlite3_finalize(statement);
    if (result != SQLITE_DONE) return CDReturnError(error, CDSQLiteError(db, @"Could not write the store metadata"));
    return YES;
}

static NSString *CDSQLiteType(NSAttributeDescription *attribute) {
    switch (attribute.attributeType) {
        case NSInteger16AttributeType:
        case NSInteger32AttributeType:
        case NSInteger64AttributeType:
        case NSBooleanAttributeType: return @"INTEGER";
        case NSFloatAttributeType:
        case NSDoubleAttributeType: return @"REAL";
        case NSDecimalAttributeType: return @"NUMERIC";
        case NSDateAttributeType: return @"REAL";
        case NSBinaryDataAttributeType:
        case NSTransformableAttributeType:
        case NSCompositeAttributeType: return @"BLOB";
        default: return @"TEXT";
    }
}

NSDictionary *CDModelMetadata(NSManagedObjectModel *model) {
    NSNumber *version = [NSNumber numberWithInt:1526];
    return [NSDictionary dictionaryWithObjectsAndKeys:
            version, @"NSPersistenceFrameworkVersion",
            version, @"NSPersistenceMaximumFrameworkVersion",
            model.versionChecksum ?: @"", @"NSStoreModelVersionChecksumKey",
            model.entityVersionHashesByName ?: [NSDictionary dictionary], @"NSStoreModelVersionHashes",
            [NSNumber numberWithInt:3], @"NSStoreModelVersionHashesVersion",
            [[model.versionIdentifiers allObjects] sortedArrayUsingSelector:@selector(compare:)] ?: [NSArray array], @"NSStoreModelVersionIdentifiers", nil];
}

static NSString *CDColumnName(NSString *propertyName) { return [@"Z" stringByAppendingString:[propertyName uppercaseString]]; }

// The column a property keeps in its entity's table, or nil for transient
// properties and to-many relationships.
static NSString *CDColumnDefinition(NSPropertyDescription *property) {
    if (property.isTransient) return nil;
    if ([property isKindOfClass:[NSAttributeDescription class]])
        return [NSString stringWithFormat:@"%@ %@", CDQuote(CDColumnName(property.name)), CDSQLiteType((NSAttributeDescription *)property)];
    if ([property isKindOfClass:[NSRelationshipDescription class]] && ![(NSRelationshipDescription *)property isToMany])
        return [NSString stringWithFormat:@"%@ INTEGER", CDQuote(CDColumnName(property.name))];
    return nil;
}

static BOOL CDCreateEntityTable(sqlite3 *db, NSEntityDescription *entity, NSError **error) {
    NSMutableArray *columns = [NSMutableArray arrayWithObjects:@"Z_PK INTEGER PRIMARY KEY", @"Z_ENT INTEGER", @"Z_OPT INTEGER", nil];
    for (NSPropertyDescription *property in entity.properties) {
        NSString *definition = CDColumnDefinition(property);
        if (definition) [columns addObject:definition];
    }
    NSString *create = [NSString stringWithFormat:@"CREATE TABLE %@ (%@)", CDQuote(CDTableName(entity)), [columns componentsJoinedByString:@", "]];
    if (!CDExec(db, create, error)) return NO;
    for (NSPropertyDescription *property in entity.properties) {
        if (!property.isIndexed || ![property isKindOfClass:[NSAttributeDescription class]]) continue;
        NSString *index = [NSString stringWithFormat:@"Z_%@_%@_INDEX", [entity.name uppercaseString], [property.name uppercaseString]];
        NSString *sql = [NSString stringWithFormat:@"CREATE INDEX %@ ON %@ (%@)", CDQuote(index), CDQuote(CDTableName(entity)), CDQuote(CDColumnName(property.name))];
        if (!CDExec(db, sql, error)) return NO;
    }
    return YES;
}

// A default value as an SQL literal for ALTER TABLE ... DEFAULT.
static NSString *CDDefaultLiteral(NSAttributeDescription *attribute) {
    id value = attribute.defaultValue;
    if (!value) return nil;
    if ([value isKindOfClass:[NSDate class]]) return [NSString stringWithFormat:@"%.17g", [value timeIntervalSinceReferenceDate]];
    if ([value isKindOfClass:[NSNumber class]]) {
        if (attribute.attributeType == NSFloatAttributeType || attribute.attributeType == NSDoubleAttributeType)
            return [NSString stringWithFormat:@"%.17g", [value doubleValue]];
        if (attribute.attributeType == NSDecimalAttributeType) return [NSString stringWithFormat:@"'%@'", [value description]];
        return [NSString stringWithFormat:@"%lld", [value longLongValue]];
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSMutableString *hex = [NSMutableString stringWithString:@"X'"];
        const unsigned char *bytes = [value bytes];
        for (NSUInteger i = 0; i < [value length]; i++) [hex appendFormat:@"%02X", bytes[i]];
        [hex appendString:@"'"];
        return hex;
    }
    NSString *text = [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : [value description];
    return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

static BOOL CDTableHasRows(sqlite3 *db, NSString *table) {
    sqlite3_stmt *statement = NULL;
    NSString *sql = [NSString stringWithFormat:@"SELECT 1 FROM %@ LIMIT 1", CDQuote(table)];
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) return NO;
    BOOL rows = sqlite3_step(statement) == SQLITE_ROW;
    sqlite3_finalize(statement);
    return rows;
}

// Brings an existing store's tables up to the model: new entities get tables,
// new attributes and to-one relationships get columns (filled with their
// default values), and renaming identifiers carry old tables and columns over.
// With apply NO it only reports whether anything would change.
static BOOL CDUpgradeSchema(sqlite3 *db, NSManagedObjectModel *model, BOOL apply, BOOL *changed, NSError **error) {
    NSMutableDictionary *ids = [NSMutableDictionary dictionary];
    NSInteger maxEntity = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY", -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"The store has no Core Data entity index"));
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(statement, 0);
        NSInteger entityID = sqlite3_column_int64(statement, 1);
        if (name) ids[[NSString stringWithUTF8String:name]] = [NSNumber numberWithInteger:entityID];
        maxEntity = MAX(maxEntity, entityID);
    }
    sqlite3_finalize(statement);
    *changed = NO;
    for (NSEntityDescription *entity in model.entities) {
        NSString *table = CDTableName(entity);
        if (!ids[entity.name] || !CDTableExists(db, table)) {
            *changed = YES;
            if (!apply) return YES;
            NSString *old = entity.renamingIdentifier;
            NSString *oldTable = old ? [@"Z" stringByAppendingString:[old uppercaseString]] : nil;
            if (old && ![old isEqualToString:entity.name] && ids[old] && CDTableExists(db, oldTable) && !CDTableExists(db, table)) {
                if (!CDExec(db, [NSString stringWithFormat:@"ALTER TABLE %@ RENAME TO %@", CDQuote(oldTable), CDQuote(table)], error)) return NO;
                if (!CDExec(db, [NSString stringWithFormat:@"UPDATE Z_PRIMARYKEY SET Z_NAME='%@' WHERE Z_NAME='%@'",
                                 [entity.name stringByReplacingOccurrencesOfString:@"'" withString:@"''"],
                                 [old stringByReplacingOccurrencesOfString:@"'" withString:@"''"]], error)) return NO;
                ids[entity.name] = ids[old];
                [ids removeObjectForKey:old];
            } else {
                if (!CDTableExists(db, table) && !CDCreateEntityTable(db, entity, error)) return NO;
                if (!ids[entity.name]) {
                    NSInteger superID = entity.superentity ? [ids[entity.superentity.name] integerValue] : 0;
                    ids[entity.name] = [NSNumber numberWithInteger:++maxEntity];
                    if (!CDExec(db, [NSString stringWithFormat:@"INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (%ld, '%@', %ld, 0)",
                                     (long)maxEntity, [entity.name stringByReplacingOccurrencesOfString:@"'" withString:@"''"], (long)superID], error)) return NO;
                }
            }
        }
        for (NSPropertyDescription *property in entity.properties) {
            NSString *definition = CDColumnDefinition(property);
            NSString *column = CDColumnName(property.name);
            if (!definition || CDColumnExists(db, table, column)) continue;
            *changed = YES;
            if (!apply) return YES;
            NSString *old = property.renamingIdentifier;
            if (old && ![old isEqualToString:property.name] && CDColumnExists(db, table, CDColumnName(old))) {
                if (!CDExec(db, [NSString stringWithFormat:@"ALTER TABLE %@ RENAME COLUMN %@ TO %@", CDQuote(table), CDQuote(CDColumnName(old)), CDQuote(column)], error)) return NO;
                continue;
            }
            NSString *literal = [property isKindOfClass:[NSAttributeDescription class]] ? CDDefaultLiteral((NSAttributeDescription *)property) : nil;
            if (!literal && !property.isOptional && [property isKindOfClass:[NSAttributeDescription class]] && CDTableHasRows(db, table))
                return CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The new required attribute %@.%@ has no default value for existing rows.", entity.name, property.name]));
            NSString *sql = [NSString stringWithFormat:@"ALTER TABLE %@ ADD COLUMN %@%@", CDQuote(table), definition, literal ? [@" DEFAULT " stringByAppendingString:literal] : @""];
            if (!CDExec(db, sql, error)) return NO;
        }
    }
    return YES;
}

static BOOL CDCreateSchema(sqlite3 *db, NSManagedObjectModel *model, NSString *uuid, NSString *type, NSError **error) {
    if (!CDExec(db, @"CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB)", error) ||
        !CDExec(db, @"CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER)", error)) return NO;

    NSMutableDictionary *entityIDs = [NSMutableDictionary dictionary];
    sqlite3_stmt *primary = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?1, ?2, ?3, 0)", -1, &primary, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"Could not prepare the entity index"));
    NSInteger nextEntity = 1;
    for (NSEntityDescription *entity in model.entities) {
        NSInteger superID = entity.superentity ? [entityIDs[[entity.superentity name]] integerValue] : 0;
        entityIDs[entity.name] = [NSNumber numberWithInteger:nextEntity];
        sqlite3_bind_int64(primary, 1, nextEntity++);
        sqlite3_bind_text(primary, 2, [entity.name UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(primary, 3, superID);
        if (sqlite3_step(primary) != SQLITE_DONE) {
            sqlite3_finalize(primary);
            return CDReturnError(error, CDSQLiteError(db, @"Could not record the entity index"));
        }
        sqlite3_reset(primary);
        sqlite3_clear_bindings(primary);

        if (!CDCreateEntityTable(db, entity, error)) { sqlite3_finalize(primary); return NO; }
    }
    sqlite3_finalize(primary);
    NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:CDModelMetadata(model)];
    [metadata setObject:uuid forKey:NSStoreUUIDKey];
    [metadata setObject:type forKey:NSStoreTypeKey];
    if (!CDWriteMetadata(db, metadata, error)) return NO;
    return YES;
}

static BOOL CDLoadEntityIDs(sqlite3 *db, NSManagedObjectModel *model, NSMutableDictionary *ids, NSError **error) {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY", -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"The store has no Core Data entity index"));
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(statement, 0);
        if (name) ids[[NSString stringWithUTF8String:name]] = [NSNumber numberWithInteger:sqlite3_column_int64(statement, 1)];
    }
    sqlite3_finalize(statement);
    for (NSEntityDescription *entity in model.entities) {
        NSNumber *identifier = [ids objectForKey:entity.name];
        NSString *table = CDTableName(entity);
        if (!identifier || !CDTableExists(db, table))
            return CDReturnError(error, CDError(134100, [NSString stringWithFormat:@"The store has no table for entity %@", entity.name]));
        for (NSString *required in @[@"Z_PK", @"Z_ENT", @"Z_OPT"])
            if (!CDColumnExists(db, table, required))
                return CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The store table for %@ does not match this model.", entity.name]));
        for (NSPropertyDescription *property in entity.properties) {
            if (property.isTransient) continue;
            if ([property isKindOfClass:[NSAttributeDescription class]] ||
                ([property isKindOfClass:[NSRelationshipDescription class]] && ![(NSRelationshipDescription *)property isToMany])) {
                NSString *column = [@"Z" stringByAppendingString:[property.name uppercaseString]];
                if (!CDColumnExists(db, table, column))
                    return CDReturnError(error, CDError(134110, [NSString stringWithFormat:@"The store is missing %@.%@; changed-model migration is not supported.", entity.name, property.name]));
            }
        }
    }
    return YES;
}

static NSString *CDNewUUID(void) {
    return [[NSUUID UUID] UUIDString];
}

static BOOL CDOpenStore(NSPersistentStore *store, NSManagedObjectModel *model, NSError **error) {
    NSString *type = store.type;
    if (![type isEqualToString:NSSQLiteStoreType] && ![type isEqualToString:NSInMemoryStoreType])
        return CDReturnError(error, CDError(134000, [NSString stringWithFormat:@"Store type %@ is not supported", type]));
    NSDictionary *options = store.options;
    NSArray *unsupportedOptions = @[
        @"NSPersistentStoreStagedMigrationManagerOptionKey",
        @"NSPersistentStoreDeferredLightweightMigrationOptionKey",
        @"NSCoreDataCoreSpotlightExporter",
        @"NSExternalRecordsDirectoryOption",
        @"NSPersistentStoreUbiquitousContentNameKey",
        @"NSPersistentStoreUbiquitousContentURLKey",
        @"NSPersistentStoreUbiquitousContainerIdentifierKey",
        @"NSSQLitePragmasOption",
        @"NSSQLiteAnalyzeOption",
        @"NSSQLiteManualVacuumOption",
        @"NSPersistentStoreFileProtectionKey"
    ];
    for (NSString *key in unsupportedOptions)
        if ([options objectForKey:key])
            return CDReturnError(error, CDError(134000, [NSString stringWithFormat:@"Store option %@ is not supported.", key]));
    if ([[options objectForKey:NSPersistentHistoryTrackingKey] boolValue] ||
        [[options objectForKey:NSPersistentStoreRemoteChangeNotificationPostOptionKey] boolValue])
        return CDReturnError(error, CDError(134000, @"Persistent history and remote-change notifications are not supported."));
    sqlite3 *db = NULL;
    if ([type isEqualToString:NSInMemoryStoreType]) {
        if (sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK)
            return CDReturnError(error, CDSQLiteError(db, @"Could not open the in-memory store"));
    } else {
        NSURL *url = store.URL;
        if (!url || !url.isFileURL) return CDReturnError(error, CDError(134100, @"A SQLite store needs a file URL"));
        NSString *parent = [[url path] stringByDeletingLastPathComponent];
        if (![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        int flags = store.isReadOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
        flags |= SQLITE_OPEN_FULLMUTEX;
        if (sqlite3_open_v2([[url path] fileSystemRepresentation], &db, flags, NULL) != SQLITE_OK) {
            NSError *failure = CDSQLiteError(db, @"Could not open the SQLite store");
            sqlite3_close(db);
            return CDReturnError(error, failure);
        }
    }
    sqlite3_busy_timeout(db, (int)(store.options ? [[store.options objectForKey:@"NSPersistentStoreTimeoutOption"] doubleValue] * 1000 : 5000));
    CDSet(store, @"database", [NSValue valueWithPointer:db]);
    if (!CDTableExists(db, @"Z_METADATA")) {
        if (store.isReadOnly) return CDReturnError(error, CDError(134100, @"The store is read-only and has no Core Data metadata."));
        if (CDTableExists(db, @"sqlite_sequence") || CDTableExists(db, @"Z_PRIMARYKEY"))
            return CDReturnError(error, CDError(134100, @"The database is not a supported Core Data SQLite store."));
        if (!CDCreateSchema(db, model, CDNewUUID(), type, error)) return NO;
        CDSet(store, @"metadata", CDReadMetadata(db));
    } else {
        NSDictionary *metadata = CDReadMetadata(db);
        if (!metadata) return CDReturnError(error, CDError(134100, @"The Core Data store metadata is unreadable."));
        BOOL changed = NO;
        if (!CDUpgradeSchema(db, model, NO, &changed, error)) return NO;
        BOOL allowed = [[options objectForKey:NSMigratePersistentStoresAutomaticallyOption] boolValue] &&
                       [[options objectForKey:NSInferMappingModelAutomaticallyOption] boolValue];
        if (!changed && allowed && !store.isReadOnly && ![model isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
            NSMutableDictionary *refreshed = [NSMutableDictionary dictionaryWithDictionary:metadata];
            [refreshed addEntriesFromDictionary:CDModelMetadata(model)];
            if (CDWriteMetadata(db, refreshed, NULL)) metadata = refreshed;
        }
        if (changed) {
            if (!allowed || store.isReadOnly) {
                NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                    @"The model used to open the store is incompatible with the one used to create the store", @"reason",
                    metadata, @"metadata",
                    @"The managed object model version used to open the persistent store is incompatible with the one that was used to create the persistent store.", NSLocalizedDescriptionKey, nil];
                return CDReturnError(error, [NSError errorWithDomain:NSCocoaErrorDomain code:134100 userInfo:info]);
            }
            if (!CDExec(db, @"BEGIN IMMEDIATE", error)) return NO;
            NSMutableDictionary *upgraded = [NSMutableDictionary dictionaryWithDictionary:metadata];
            [upgraded addEntriesFromDictionary:CDModelMetadata(model)];
            if (!CDUpgradeSchema(db, model, YES, &changed, error) || !CDWriteMetadata(db, upgraded, error)) {
                CDExec(db, @"ROLLBACK", NULL);
                return NO;
            }
            if (!CDExec(db, @"COMMIT", error)) return NO;
            metadata = upgraded;
        }
        CDSet(store, @"metadata", metadata);
        NSMutableDictionary *ids = [NSMutableDictionary dictionary];
        if (!CDLoadEntityIDs(db, model, ids, error)) return NO;
        CDSet(store, @"entityIDs", ids);
    }
    if (![CDGet(store, @"entityIDs") count]) {
        NSMutableDictionary *ids = [NSMutableDictionary dictionary];
        if (!CDLoadEntityIDs(db, model, ids, error)) return NO;
        CDSet(store, @"entityIDs", ids);
    }
    if ([type isEqualToString:NSInMemoryStoreType] && !CDGet(store, @"metadata"))
        CDSet(store, @"metadata", CDReadMetadata(db));
    store.identifier = [store.metadata objectForKey:NSStoreUUIDKey] ?: store.identifier;
    return YES;
}

// Transformable values go through their value transformer (secure
// unarchiving by default); composite values are kept as property lists.
static NSData *CDArchiveAttributeValue(NSAttributeDescription *attribute, id value) {
    if (attribute.attributeType == NSCompositeAttributeType)
        return [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    NSString *name = attribute.valueTransformerName;
    NSValueTransformer *transformer = name.length ? [NSValueTransformer valueTransformerForName:name] : nil;
    if (transformer) {
        id data = [transformer reverseTransformedValue:value];
        return [data isKindOfClass:[NSData class]] ? data : nil;
    }
    if ([value isKindOfClass:[NSData class]] && !name.length && !attribute.attributeValueClassName) return value;
    return [NSKeyedArchiver archivedDataWithRootObject:value requiringSecureCoding:NO error:NULL];
}

static id CDUnarchiveAttributeValue(NSAttributeDescription *attribute, NSData *data) {
    if (attribute.attributeType == NSCompositeAttributeType)
        return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL];
    NSString *name = attribute.valueTransformerName;
    NSValueTransformer *transformer = name.length ? [NSValueTransformer valueTransformerForName:name] : nil;
    if (transformer) return [transformer transformedValue:data];
    NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    if (!unarchiver) return data;
    unarchiver.requiresSecureCoding = NO;
    id value = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return value;
}

static void CDBindValue(sqlite3_stmt *statement, int index, NSAttributeDescription *attribute, id value) {
    if (!value || value == [NSNull null]) { sqlite3_bind_null(statement, index); return; }
    switch (attribute.attributeType) {
        case NSInteger16AttributeType:
        case NSInteger32AttributeType:
        case NSInteger64AttributeType:
        case NSBooleanAttributeType:
            sqlite3_bind_int64(statement, index, [value longLongValue]);
            break;
        case NSFloatAttributeType:
        case NSDoubleAttributeType:
            sqlite3_bind_double(statement, index, [value doubleValue]);
            break;
        case NSDecimalAttributeType:
            sqlite3_bind_text(statement, index, [[value description] UTF8String], -1, SQLITE_TRANSIENT);
            break;
        case NSDateAttributeType:
            sqlite3_bind_double(statement, index, [value timeIntervalSinceReferenceDate]);
            break;
        case NSBinaryDataAttributeType:
            sqlite3_bind_blob(statement, index, [value bytes], (int)[value length], SQLITE_TRANSIENT);
            break;
        case NSTransformableAttributeType:
        case NSCompositeAttributeType: {
            NSData *data = CDArchiveAttributeValue(attribute, value);
            if (data) sqlite3_bind_blob(statement, index, [data bytes], (int)[data length], SQLITE_TRANSIENT);
            else sqlite3_bind_null(statement, index);
            break;
        }
        case NSUUIDAttributeType:
            sqlite3_bind_text(statement, index, [([value isKindOfClass:[NSUUID class]] ? [value UUIDString] : [value description]) UTF8String], -1, SQLITE_TRANSIENT);
            break;
        case NSURIAttributeType:
            sqlite3_bind_text(statement, index, [([value isKindOfClass:[NSURL class]] ? [value absoluteString] : [value description]) UTF8String], -1, SQLITE_TRANSIENT);
            break;
        default:
            if ([value isKindOfClass:[NSNumber class]]) sqlite3_bind_double(statement, index, [value doubleValue]);
            else if ([value isKindOfClass:[NSData class]]) sqlite3_bind_blob(statement, index, [value bytes], (int)[value length], SQLITE_TRANSIENT);
            else sqlite3_bind_text(statement, index, [[value description] UTF8String], -1, SQLITE_TRANSIENT);
            break;
    }
}

static id CDReadValue(sqlite3_stmt *statement, int column, NSAttributeDescription *attribute) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
    switch (attribute.attributeType) {
        case NSInteger16AttributeType: return [NSNumber numberWithShort:(short)sqlite3_column_int(statement, column)];
        case NSInteger32AttributeType: return [NSNumber numberWithInt:sqlite3_column_int(statement, column)];
        case NSInteger64AttributeType: return [NSNumber numberWithLongLong:sqlite3_column_int64(statement, column)];
        case NSBooleanAttributeType: return [NSNumber numberWithBool:sqlite3_column_int(statement, column) != 0];
        case NSFloatAttributeType: return [NSNumber numberWithFloat:(float)sqlite3_column_double(statement, column)];
        case NSDoubleAttributeType: return [NSNumber numberWithDouble:sqlite3_column_double(statement, column)];
        case NSDecimalAttributeType: {
            const char *text = (const char *)sqlite3_column_text(statement, column);
            return text ? [NSDecimalNumber decimalNumberWithString:[NSString stringWithUTF8String:text]] : nil;
        }
        case NSDateAttributeType: return [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(statement, column)];
        case NSBinaryDataAttributeType: return [NSData dataWithBytes:sqlite3_column_blob(statement, column) length:(NSUInteger)sqlite3_column_bytes(statement, column)];
        case NSTransformableAttributeType:
        case NSCompositeAttributeType:
            return CDUnarchiveAttributeValue(attribute, [NSData dataWithBytes:sqlite3_column_blob(statement, column) length:(NSUInteger)sqlite3_column_bytes(statement, column)]);
        case NSUUIDAttributeType: {
            const unsigned char *text = sqlite3_column_text(statement, column);
            return text ? [[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:(const char *)text]] autorelease] : nil;
        }
        case NSURIAttributeType: {
            const unsigned char *text = sqlite3_column_text(statement, column);
            return text ? [NSURL URLWithString:[NSString stringWithUTF8String:(const char *)text]] : nil;
        }
        default: {
            if (attribute.attributeValueClassName && [attribute.attributeValueClassName isEqualToString:@"NSNumber"])
                return [NSNumber numberWithDouble:sqlite3_column_double(statement, column)];
            const unsigned char *text = sqlite3_column_text(statement, column);
            return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
        }
    }
}

static id CDRelationshipDatabaseValue(id value) {
    if ([value isKindOfClass:[NSManagedObject class]]) return [value objectID];
    if ([value isKindOfClass:[NSManagedObjectID class]]) return value;
    return nil;
}

static BOOL CDWriteObject(NSPersistentStore *store, NSManagedObject *object, BOOL insert, NSError **error) {
    sqlite3 *db = CDStoreDatabase(store);
    NSEntityDescription *entity = object.entity;
    NSMutableArray *columns = [NSMutableArray array];
    NSMutableArray *values = [NSMutableArray array];
    NSMutableArray *properties = [NSMutableArray array];
    for (NSPropertyDescription *property in entity.properties) {
        if (property.isTransient) continue;
        if ([property isKindOfClass:[NSAttributeDescription class]]) {
            [columns addObject:[@"Z" stringByAppendingString:[property.name uppercaseString]]];
            [values addObject:CDObjectValue(object, property.name) ?: [NSNull null]];
            [properties addObject:property];
        } else if (!insert && [property isKindOfClass:[NSRelationshipDescription class]] && ![(NSRelationshipDescription *)property isToMany]) {
            [columns addObject:[@"Z" stringByAppendingString:[property.name uppercaseString]]];
            [values addObject:CDRelationshipDatabaseValue(CDObjectValue(object, property.name)) ?: [NSNull null]];
            [properties addObject:property];
        }
    }
    NSString *sql = nil;
    if (insert) {
        NSMutableArray *allColumns = [NSMutableArray arrayWithObjects:@"Z_ENT", @"Z_OPT", nil];
        [allColumns addObjectsFromArray:columns];
        NSMutableArray *quoted = [NSMutableArray array];
        for (NSString *column in allColumns) [quoted addObject:CDQuote(column)];
        NSMutableArray *marks = [NSMutableArray array];
        for (NSUInteger i = 0; i < allColumns.count; i++) [marks addObject:@"?"];
        sql = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", CDQuote(CDTableName(entity)),
               [quoted componentsJoinedByString:@", "],
               [marks componentsJoinedByString:@", "]];
    } else {
        NSMutableArray *assignments = [NSMutableArray array];
        for (NSString *column in columns) [assignments addObject:[NSString stringWithFormat:@"%@=?", CDQuote(column)]];
        [assignments addObject:@"Z_OPT=Z_OPT+1"];
        sql = [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE Z_PK=?", CDQuote(CDTableName(entity)), [assignments componentsJoinedByString:@", "]];
    }
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"Could not prepare an object save"));
    int index = 1;
    if (insert) {
        sqlite3_bind_int64(statement, index++, CDEntityID(store, entity));
        sqlite3_bind_int(statement, index++, 1);
    }
    for (NSUInteger i = 0; i < columns.count; i++) {
        id value = [values objectAtIndex:i];
        if ([value isKindOfClass:[NSNull class]]) { sqlite3_bind_null(statement, index++); continue; }
        NSPropertyDescription *property = [properties objectAtIndex:i];
        if ([property isKindOfClass:[NSAttributeDescription class]]) CDBindValue(statement, index++, (NSAttributeDescription *)property, value);
        else if ([value isKindOfClass:[NSManagedObjectID class]]) {
            NSManagedObjectID *objectID = value;
            sqlite3_bind_int64(statement, index++, [CDGet(objectID, @"primaryKey") longLongValue]);
        } else sqlite3_bind_null(statement, index++);
    }
    if (!insert) sqlite3_bind_int64(statement, index, [CDGet(object.objectID, @"primaryKey") longLongValue]);
    int result = sqlite3_step(statement);
    sqlite3_finalize(statement);
    if (result != SQLITE_DONE) return CDReturnError(error, CDSQLiteError(db, @"Could not save an object"));
    if (insert) {
        NSInteger primaryKey = sqlite3_last_insert_rowid(db);
        CDSet(object.objectID, @"temporary", [NSNumber numberWithBool:NO]);
        CDSet(object.objectID, @"primaryKey", [NSNumber numberWithInteger:primaryKey]);
        sqlite3_stmt *primary = NULL;
        if (sqlite3_prepare_v2(db, "UPDATE Z_PRIMARYKEY SET Z_MAX=MAX(Z_MAX, ?1) WHERE Z_ENT=?2", -1, &primary, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(primary, 1, primaryKey);
            sqlite3_bind_int64(primary, 2, CDEntityID(store, entity));
            sqlite3_step(primary);
        }
        sqlite3_finalize(primary);
    }
    return YES;
}

static BOOL CDDeleteRow(NSPersistentStore *store, NSManagedObject *object, NSError **error) {
    sqlite3_stmt *statement = NULL;
    sqlite3 *db = CDStoreDatabase(store);
    NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE Z_PK=?", CDQuote(CDTableName(object.entity))];
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"Could not prepare an object delete"));
    sqlite3_bind_int64(statement, 1, [CDGet(object.objectID, @"primaryKey") longLongValue]);
    int result = sqlite3_step(statement);
    sqlite3_finalize(statement);
    return result == SQLITE_DONE ? YES : CDReturnError(error, CDSQLiteError(db, @"Could not delete an object"));
}

/* Core Data's object IDs come from stores and contexts; one made with -init is abstract. */
static void CDRaiseAbstract(id object, SEL selector) {
    [NSException raise:NSInvalidArgumentException format:@"*** -%@ cannot be sent to an abstract object of class %@: Create a concrete instance!",
     NSStringFromSelector(selector), NSStringFromClass([object class])];
}

@implementation NSManagedObjectID
- (instancetype)init {
    if ((self = [super init])) CDSet(self, @"abstract", [NSNumber numberWithBool:YES]);
    return self;
}
- (NSEntityDescription *)entity {
    if (CDGet(self, @"abstract")) CDRaiseAbstract(self, _cmd);
    return CDGet(self, @"entity");
}
- (NSPersistentStore *)persistentStore { return CDGet(self, @"persistentStore"); }
- (BOOL)isTemporaryID { return [CDGet(self, @"temporary") boolValue]; }
- (NSURL *)URIRepresentation {
    NSString *name = self.entity.name ?: @"Unknown";
    if (self.isTemporaryID)
        return [NSURL URLWithString:[NSString stringWithFormat:@"x-coredata:///%@/t%@", name, CDGet(self, @"temporaryToken") ?: @""]];
    NSString *storeID = self.persistentStore.identifier ?: @"";
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-coredata://%@/%@/p%@", storeID, name, CDGet(self, @"primaryKey")]];
}
- (NSString *)description { return [NSString stringWithFormat:@"%p <%@>", self, self.URIRepresentation]; }
- (NSUInteger)hash { return [[self.URIRepresentation absoluteString] hash]; }
- (BOOL)isEqual:(id)object { return [object isKindOfClass:[NSManagedObjectID class]] && [[self URIRepresentation] isEqual:[object URIRepresentation]]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation NSManagedObjectID (FinchInitializer)
- (instancetype)cd_init { return [super init]; }
@end

@implementation NSPersistentStore
+ (NSDictionary *)metadataForPersistentStoreWithURL:(NSURL *)url error:(NSError **)error {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([[url path] fileSystemRepresentation], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSError *failure = CDSQLiteError(db, @"Could not read store metadata"); sqlite3_close(db); CDReturnError(error, failure); return nil;
    }
    NSDictionary *metadata = CDReadMetadata(db);
    sqlite3_close(db);
    if (!metadata) CDReturnError(error, CDError(134100, @"Store metadata is missing or unreadable."));
    return metadata;
}
+ (BOOL)setMetadata:(NSDictionary *)metadata forPersistentStoreWithURL:(NSURL *)url error:(NSError **)error {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([[url path] fileSystemRepresentation], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSError *failure = CDSQLiteError(db, @"Could not open store metadata"); sqlite3_close(db); return CDReturnError(error, failure);
    }
    BOOL result = CDWriteMetadata(db, metadata, error);
    sqlite3_close(db);
    return result;
}
+ (Class)migrationManagerClass { return NSMigrationManager.class; }
- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator configurationName:(NSString *)name URL:(NSURL *)url options:(NSDictionary *)options {
    self = [super init];
    if (self) {
        CDSet(self, @"coordinator", [NSValue valueWithNonretainedObject:coordinator]);
        CDSet(self, @"configurationName", [name copy]);
        CDSet(self, @"url", url);
        CDSet(self, @"options", [options copy] ?: [NSDictionary dictionary]);
        CDSet(self, @"readOnly", [NSNumber numberWithBool:[[options objectForKey:NSReadOnlyPersistentStoreOption] boolValue]]);
        CDSet(self, @"identifier", CDNewUUID());
        CDSet(self, @"metadata", [NSDictionary dictionary]);
    }
    return self;
}
- (BOOL)loadMetadata:(NSError **)error {
    NSPersistentStoreCoordinator *coordinator = self.persistentStoreCoordinator;
    if (!coordinator || !coordinator.managedObjectModel)
        return CDReturnError(error, CDError(134100, @"The store has no managed object model."));
    return CDOpenStore(self, coordinator.managedObjectModel, error);
}
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator { return [[[CDGet(self, @"coordinator") nonretainedObjectValue] retain] autorelease]; }
- (NSString *)configurationName { return CDGet(self, @"configurationName"); }
- (NSDictionary *)options { return CDGet(self, @"options"); }
- (NSURL *)URL { return CDGet(self, @"url"); }
- (void)setURL:(NSURL *)url { CDSet(self, @"url", url); }
- (NSString *)identifier {
    if (CDGet(self, @"abstract")) CDRaiseAbstract(self, @selector(metadata));
    return CDGet(self, @"identifier");
}
- (void)setIdentifier:(NSString *)identifier { CDSet(self, @"identifier", [identifier copy]); }
- (NSString *)type { return CDGet(self, @"type"); }
- (BOOL)isReadOnly { return [CDGet(self, @"readOnly") boolValue]; }
- (void)setReadOnly:(BOOL)value { CDSet(self, @"readOnly", [NSNumber numberWithBool:value]); }
- (instancetype)init {
    if ((self = [super init]) && [self class] == [NSPersistentStore class]) CDSet(self, @"abstract", [NSNumber numberWithBool:YES]);
    return self;
}
- (NSDictionary *)metadata {
    if (CDGet(self, @"abstract")) CDRaiseAbstract(self, _cmd);
    return CDGet(self, @"metadata") ?: [NSDictionary dictionary];
}
- (void)setMetadata:(NSDictionary *)metadata {
    CDSet(self, @"metadata", [metadata copy] ?: [NSDictionary dictionary]);
    sqlite3 *db = CDStoreDatabase(self);
    if (db && !self.isReadOnly) CDWriteMetadata(db, self.metadata, NULL);
}
- (NSCoreDataCoreSpotlightDelegate *)coreSpotlightExporter { return nil; }
- (void)didAddToPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator {
    CDSet(self, @"coordinator", [NSValue valueWithNonretainedObject:coordinator]);
}
- (void)willRemoveFromPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator { (void)coordinator; }
- (void)dealloc {
    sqlite3 *db = CDStoreDatabase(self);
    if (db) sqlite3_close(db);
    [super dealloc];
}
@end

static NSMutableDictionary *CDStoreClasses(void) {
    static NSMutableDictionary *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes = [[NSMutableDictionary alloc] init];
        CDRegisterBuiltInStores(classes);
    });
    return classes;
}

@implementation NSPersistentStoreCoordinator
- (instancetype)init {
    NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
    return [self initWithManagedObjectModel:model];
}
- (instancetype)initWithManagedObjectModel:(NSManagedObjectModel *)model {
    self = [super init];
    if (self) {
        CDSet(self, @"model", [model retain]);
        CDSet(model, @"inUse", [NSNumber numberWithBool:YES]);
        CDSet(self, @"stores", [NSMutableArray array]);
        CDSet(self, @"lock", [[NSRecursiveLock alloc] init]);
    }
    return self;
}
- (NSManagedObjectModel *)managedObjectModel { return CDGet(self, @"model"); }
- (NSArray *)persistentStores { return [[CDGet(self, @"stores") copy] autorelease]; }
- (NSString *)name { return CDGet(self, @"name"); }
- (void)setName:(NSString *)value { CDSet(self, @"name", [value copy]); }
- (void)lock { [CDGet(self, @"lock") lock]; }
- (void)unlock { [CDGet(self, @"lock") unlock]; }
- (NSPersistentStore *)persistentStoreForURL:(NSURL *)url {
    for (NSPersistentStore *store in self.persistentStores) if ([store.URL isEqual:url]) return store;
    return nil;
}
- (NSURL *)URLForPersistentStore:(NSPersistentStore *)store { return store.URL; }
- (BOOL)setURL:(NSURL *)url forPersistentStore:(NSPersistentStore *)store {
    if (![self.persistentStores containsObject:store]) return NO;
    store.URL = url;
    return YES;
}
- (NSPersistentStore *)addPersistentStoreWithType:(NSString *)type configuration:(NSString *)configuration URL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    Class storeClass = Nil;
    @synchronized (CDStoreClasses()) { storeClass = [CDStoreClasses() objectForKey:type]; }
    if (storeClass && [type isEqualToString:NSSQLiteStoreType]) storeClass = Nil;
    NSPersistentStore *store = [[[(storeClass ?: [NSPersistentStore class]) alloc] initWithPersistentStoreCoordinator:self configurationName:configuration URL:url options:options] autorelease];
    CDSet(store, @"type", [type copy]);
    if (storeClass) {
        if (!CDLoadCustomStore(store, type, error)) return nil;
    } else if (!CDOpenStore(store, self.managedObjectModel, error)) return nil;
    [CDGet(self, @"stores") addObject:store];
    [store didAddToPersistentStoreCoordinator:self];
    return store;
}
- (void)addPersistentStoreWithDescription:(NSPersistentStoreDescription *)description completionHandler:(void (^)(NSPersistentStoreDescription *, NSError *))block {
    void (^load)(void) = ^{
        NSError *error = nil;
        NSMutableDictionary *options = [NSMutableDictionary dictionaryWithDictionary:description.options ?: [NSDictionary dictionary]];
        if (![options objectForKey:NSMigratePersistentStoresAutomaticallyOption])
            [options setObject:[NSNumber numberWithBool:description.shouldMigrateStoreAutomatically] forKey:NSMigratePersistentStoresAutomaticallyOption];
        if (![options objectForKey:NSInferMappingModelAutomaticallyOption])
            [options setObject:[NSNumber numberWithBool:description.shouldInferMappingModelAutomatically] forKey:NSInferMappingModelAutomaticallyOption];
        NSPersistentStore *store = [self addPersistentStoreWithType:description.type configuration:description.configuration URL:description.URL options:options error:&error];
        (void)store;
        if (block) block(description, error);
    };
    if (description.shouldAddStoreAsynchronously) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), load);
    else load();
}
- (BOOL)removePersistentStore:(NSPersistentStore *)store error:(NSError **)error {
    NSMutableArray *stores = CDGet(self, @"stores");
    if (![stores containsObject:store]) return CDReturnError(error, CDError(134080, @"The store is not attached to this coordinator."));
    [store willRemoveFromPersistentStoreCoordinator:self];
    [stores removeObject:store];
    sqlite3 *db = CDStoreDatabase(store);
    if (db) { sqlite3_close(db); CDSet(store, @"database", nil); }
    return YES;
}
- (void)setMetadata:(NSDictionary *)metadata forPersistentStore:(NSPersistentStore *)store { store.metadata = metadata; }
- (NSDictionary *)metadataForPersistentStore:(NSPersistentStore *)store { return store.metadata; }
- (NSManagedObjectID *)managedObjectIDForURIRepresentation:(NSURL *)url {
    NSArray *parts = [[url path] componentsSeparatedByString:@"/"];
    if (parts.count < 2) return nil;
    NSString *entityName = [parts objectAtIndex:parts.count - 2];
    NSString *key = [parts lastObject];
    if (![key hasPrefix:@"p"]) return nil;
    NSString *reference = [key substringFromIndex:1];
    NSEntityDescription *entity = [self.managedObjectModel.entitiesByName objectForKey:entityName];
    for (NSPersistentStore *store in self.persistentStores) {
        if ([store.identifier isEqualToString:[url host]] && entity) {
            NSManagedObjectID *objectID = [[[NSManagedObjectID alloc] cd_init] autorelease];
            CDSet(objectID, @"entity", entity); CDSet(objectID, @"persistentStore", store);
            id primaryKey = CDIsCustomStore(store) ? CDCustomReferenceFromURIKey(reference) : [NSNumber numberWithInteger:[reference integerValue]];
            CDSet(objectID, @"primaryKey", primaryKey); CDSet(objectID, @"temporary", [NSNumber numberWithBool:NO]);
            return objectID;
        }
    }
    return nil;
}
- (id)executeRequest:(NSPersistentStoreRequest *)request withContext:(NSManagedObjectContext *)context error:(NSError **)error {
    if ([request isKindOfClass:[NSBatchInsertRequest class]]) return CDExecuteBatchInsert(self, (NSBatchInsertRequest *)request, error);
    if ([request isKindOfClass:[NSPersistentCloudKitContainerEventRequest class]])
        return CDExecuteCloudKitEventRequest((NSPersistentCloudKitContainerEventRequest *)request);
    if ([request isKindOfClass:[NSBatchDeleteRequest class]]) {
        NSBatchDeleteRequest *deleteRequest = (NSBatchDeleteRequest *)request;
        NSArray *objects = [context executeFetchRequest:deleteRequest.fetchRequest error:error];
        if (!objects) return nil;
        NSMutableArray *ids = [NSMutableArray array];
        for (NSManagedObject *object in objects) { [ids addObject:object.objectID]; [context deleteObject:object]; }
        if (![context save:error]) return nil;
        NSBatchDeleteResult *result = [[[NSBatchDeleteResult alloc] init] autorelease];
        CDSet(result, @"resultType", [NSNumber numberWithUnsignedInteger:deleteRequest.resultType]);
        CDSet(result, @"result", deleteRequest.resultType == NSBatchDeleteResultTypeObjectIDs ? ids : [NSNumber numberWithUnsignedInteger:objects.count]);
        return result;
    }
    if ([request isKindOfClass:[NSBatchUpdateRequest class]]) {
        NSBatchUpdateRequest *update = (NSBatchUpdateRequest *)request;
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:update.entityName];
        fetch.predicate = update.predicate;
        NSArray *objects = [context executeFetchRequest:fetch error:error];
        if (!objects) return nil;
        NSMutableArray *ids = [NSMutableArray array];
        for (NSManagedObject *object in objects) {
            [ids addObject:object.objectID];
            for (id key in update.propertiesToUpdate) {
                NSString *name = [key isKindOfClass:[NSString class]] ? key : [key name];
                id value = [update.propertiesToUpdate objectForKey:key];
                if ([value isKindOfClass:[NSExpression class]]) value = [value expressionValueWithObject:object context:nil];
                [object setValue:value forKey:name];
            }
        }
        if (![context save:error]) return nil;
        NSBatchUpdateResult *result = [[[NSBatchUpdateResult alloc] init] autorelease];
        CDSet(result, @"resultType", [NSNumber numberWithUnsignedInteger:update.resultType]);
        CDSet(result, @"result", update.resultType == NSUpdatedObjectIDsResultType ? ids : [NSNumber numberWithUnsignedInteger:objects.count]);
        return result;
    }
    CDReturnError(error, CDError(134091, @"This persistent store request type is not supported."));
    return nil;
}
+ (NSDictionary *)registeredStoreTypes {
    NSMutableDictionary *types = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [NSValue valueWithNonretainedObject:[NSPersistentStore class]], NSSQLiteStoreType,
            [NSValue valueWithNonretainedObject:[NSPersistentStore class]], NSInMemoryStoreType, nil];
    @synchronized (CDStoreClasses()) {
        for (NSString *type in CDStoreClasses())
            [types setObject:[NSValue valueWithNonretainedObject:[CDStoreClasses() objectForKey:type]] forKey:type];
    }
    return types;
}
+ (void)registerStoreClass:(Class)storeClass forStoreType:(NSString *)type {
    if (!type) return;
    @synchronized (CDStoreClasses()) {
        if (storeClass) [CDStoreClasses() setObject:storeClass forKey:type];
        else [CDStoreClasses() removeObjectForKey:type];
    }
}
+ (NSDictionary *)metadataForPersistentStoreOfType:(NSString *)type URL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    (void)options;
    if (![type isEqualToString:NSSQLiteStoreType]) { CDReturnError(error, CDError(134000, @"Only SQLite store metadata can be read from a URL.")); return nil; }
    return [NSPersistentStore metadataForPersistentStoreWithURL:url error:error];
}
+ (BOOL)setMetadata:(NSDictionary *)metadata forPersistentStoreOfType:(NSString *)type URL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    (void)options;
    if (![type isEqualToString:NSSQLiteStoreType]) return CDReturnError(error, CDError(134000, @"Only SQLite store metadata can be written to a URL."));
    return [NSPersistentStore setMetadata:metadata forPersistentStoreWithURL:url error:error];
}
+ (NSDictionary *)metadataForPersistentStoreOfType:(NSString *)type URL:(NSURL *)url error:(NSError **)error {
    return [self metadataForPersistentStoreOfType:type URL:url options:nil error:error];
}
+ (BOOL)setMetadata:(NSDictionary *)metadata forPersistentStoreOfType:(NSString *)type URL:(NSURL *)url error:(NSError **)error {
    return [self setMetadata:metadata forPersistentStoreOfType:type URL:url options:nil error:error];
}
- (BOOL)tryLock { return [CDGet(self, @"lock") tryLock]; }
- (NSManagedObjectID *)managedObjectIDFromUTF8String:(const char *)utf8string length:(NSUInteger)length {
    if (!utf8string || !length) return nil;
    NSString *string = [[[NSString alloc] initWithBytes:utf8string length:length encoding:NSUTF8StringEncoding] autorelease];
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    return url ? [self managedObjectIDForURIRepresentation:url] : nil;
}
+ (NSDictionary *)metadataForPersistentStoreWithURL:(NSURL *)url error:(NSError **)error {
    return [self metadataForPersistentStoreOfType:NSSQLiteStoreType URL:url options:nil error:error];
}
+ (NSManagedObjectModel *)cachedModelForPersistentStoreAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    (void)url; (void)options;
    CDReturnError(error, CDError(134100, @"This SQLite format does not store a compiled managed object model."));
    return nil;
}
+ (NSDictionary *)elementsDerivedFromExternalRecordURL:(NSURL *)url {
    (void)url;
    return nil;
}
- (NSPersistentStore *)importStoreWithIdentifier:(NSString *)identifier fromExternalRecordsDirectory:(NSURL *)directory toURL:(NSURL *)url options:(NSDictionary *)options withType:(NSString *)type error:(NSError **)error {
    (void)identifier; (void)directory; (void)url; (void)options; (void)type;
    CDReturnError(error, CDError(134000, @"Importing Spotlight external records is not supported."));
    return nil;
}
+ (BOOL)removeUbiquitousContentAndPersistentStoreAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    (void)url; (void)options;
    return CDReturnError(error, CDError(134000, @"iCloud ubiquitous stores are not supported."));
}
- (NSPersistentStore *)migratePersistentStore:(NSPersistentStore *)store toURL:(NSURL *)url options:(NSDictionary *)options withType:(NSString *)type error:(NSError **)error {
    if (![self.persistentStores containsObject:store] || ![type isEqualToString:NSSQLiteStoreType] || !store.URL) {
        CDReturnError(error, CDError(134110, @"This store migration is not supported."));
        return nil;
    }
    if (![self removePersistentStore:store error:error]) return nil;
    if (![NSFileManager.defaultManager copyItemAtURL:store.URL toURL:url error:error]) return nil;
    return [self addPersistentStoreWithType:type configuration:store.configurationName URL:url options:options error:error];
}
- (BOOL)destroyPersistentStoreAtURL:(NSURL *)url withType:(NSString *)type options:(NSDictionary *)options error:(NSError **)error {
    (void)options;
    if (![type isEqualToString:NSSQLiteStoreType]) return CDReturnError(error, CDError(134000, @"Only SQLite stores can be destroyed."));
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        NSString *path = [[url path] stringByAppendingString:suffix];
        if ([NSFileManager.defaultManager fileExistsAtPath:path] && ![NSFileManager.defaultManager removeItemAtPath:path error:error]) return NO;
    }
    return YES;
}
- (BOOL)replacePersistentStoreAtURL:(NSURL *)destinationURL destinationOptions:(NSDictionary *)destinationOptions withPersistentStoreFromURL:(NSURL *)sourceURL sourceOptions:(NSDictionary *)sourceOptions storeType:(NSString *)type error:(NSError **)error {
    (void)destinationOptions; (void)sourceOptions;
    if (![type isEqualToString:NSSQLiteStoreType]) return CDReturnError(error, CDError(134000, @"Only SQLite stores can be replaced."));
    if ([NSFileManager.defaultManager fileExistsAtPath:[destinationURL path]] && ![NSFileManager.defaultManager removeItemAtURL:destinationURL error:error]) return NO;
    return [NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:destinationURL error:error];
}
- (void)performBlock:(void (^)(void))block { if (block) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), block); }
- (void)performBlockAndWait:(void (^NS_NOESCAPE NS_SWIFT_SENDABLE)(void))block { if (block) block(); }
- (NSPersistentHistoryToken *)currentPersistentHistoryTokenFromStores:(NSArray *)stores { (void)stores; return nil; }
- (BOOL)finishDeferredLightweightMigration:(NSError **)error {
    return CDReturnError(error, CDError(134110, @"Deferred lightweight migration is not supported."));
}
- (BOOL)finishDeferredLightweightMigrationTask:(NSError **)error {
    return CDReturnError(error, CDError(134110, @"Deferred lightweight migration is not supported."));
}
@end

static NSPersistentStore *CDStoreForObject(NSManagedObject *object, NSArray *stores) {
    NSPersistentStore *assigned = object.objectID.persistentStore;
    if (assigned && [stores containsObject:assigned]) return assigned;
    return [stores count] ? [stores objectAtIndex:0] : nil;
}

static BOOL CDWriteToOneRelationships(NSPersistentStore *store, NSManagedObject *object, NSError **error) {
    sqlite3 *db = CDStoreDatabase(store);
    for (NSRelationshipDescription *relationship in [object.entity.relationshipsByName allValues]) {
        if (relationship.isToMany) continue;
        NSString *column = [@"Z" stringByAppendingString:[relationship.name uppercaseString]];
        NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET %@=? WHERE Z_PK=?", CDQuote(CDTableName(object.entity)), CDQuote(column)];
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK)
            return CDReturnError(error, CDSQLiteError(db, @"Could not prepare a relationship save"));
        id value = CDRelationshipDatabaseValue(CDObjectValue(object, relationship.name));
        if ([value isKindOfClass:[NSManagedObjectID class]]) sqlite3_bind_int64(statement, 1, [CDGet(value, @"primaryKey") longLongValue]);
        else sqlite3_bind_null(statement, 1);
        sqlite3_bind_int64(statement, 2, [CDGet(object.objectID, @"primaryKey") longLongValue]);
        int result = sqlite3_step(statement);
        sqlite3_finalize(statement);
        if (result != SQLITE_DONE) return CDReturnError(error, CDSQLiteError(db, @"Could not save a relationship"));
    }
    for (NSRelationshipDescription *relationship in [object.entity.relationshipsByName allValues]) {
        if (!relationship.isToMany) continue;
        NSRelationshipDescription *inverse = relationship.inverseRelationship;
        if (!inverse || inverse.isToMany) {
            id value = CDObjectValue(object, relationship.name);
            if (value && [value count])
                return CDReturnError(error, CDError(134190, [NSString stringWithFormat:@"Many-to-many relationship %@.%@ is not supported by this store format.", object.entity.name, relationship.name]));
            continue;
        }
        id value = CDObjectValue(object, relationship.name);
        NSArray *related = [value isKindOfClass:[NSSet class]] ? [value allObjects] : ([value isKindOfClass:[NSArray class]] ? value : nil);
        for (NSManagedObject *other in related) {
            NSString *column = [@"Z" stringByAppendingString:[inverse.name uppercaseString]];
            NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET %@=? WHERE Z_PK=?", CDQuote(CDTableName(other.entity)), CDQuote(column)];
            sqlite3_stmt *statement = NULL;
            if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK)
                return CDReturnError(error, CDSQLiteError(db, @"Could not prepare an inverse relationship save"));
            sqlite3_bind_int64(statement, 1, [CDGet(object.objectID, @"primaryKey") longLongValue]);
            sqlite3_bind_int64(statement, 2, [CDGet(other.objectID, @"primaryKey") longLongValue]);
            int result = sqlite3_step(statement);
            sqlite3_finalize(statement);
            if (result != SQLITE_DONE) return CDReturnError(error, CDSQLiteError(db, @"Could not save an inverse relationship"));
        }
    }
    return YES;
}

// SELECT for an entity's rows: Z_PK, then the attributes and to-one
// relationships listed in properties.
static NSString *CDSelectRows(NSEntityDescription *entity, NSMutableArray *properties) {
    NSMutableArray *columns = [NSMutableArray arrayWithObjects:CDQuote(@"Z_PK"), nil];
    for (NSPropertyDescription *property in entity.properties) {
        if (property.isTransient) continue;
        if ([property isKindOfClass:[NSAttributeDescription class]] ||
            ([property isKindOfClass:[NSRelationshipDescription class]] && ![(NSRelationshipDescription *)property isToMany])) {
            [columns addObject:CDQuote([@"Z" stringByAppendingString:[property.name uppercaseString]])];
            [properties addObject:property];
        }
    }
    return [NSString stringWithFormat:@"SELECT %@ FROM %@", [columns componentsJoinedByString:@", "], CDQuote(CDTableName(entity))];
}

static void CDApplyRow(NSManagedObject *object, NSPersistentStore *store, sqlite3_stmt *statement, NSArray *properties, BOOL preserveChanges) {
    for (NSUInteger i = 0; i < properties.count; i++) {
        NSPropertyDescription *property = [properties objectAtIndex:i];
        if (preserveChanges && [[object changedValues] objectForKey:property.name]) continue;
        if ([property isKindOfClass:[NSAttributeDescription class]]) {
            CDObjectSetValue(object, CDReadValue(statement, (int)i + 1, (NSAttributeDescription *)property), property.name, NO);
        } else {
            NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
            if (sqlite3_column_type(statement, (int)i + 1) == SQLITE_NULL || !relationship.destinationEntity) {
                CDObjectSetValue(object, nil, property.name, NO);
            } else {
                NSInteger targetID = sqlite3_column_int64(statement, (int)i + 1);
                CDObjectSetValue(object, CDMakeObjectID(relationship.destinationEntity, store, targetID, NO), property.name, NO);
            }
        }
    }
}

// Loads a SQLite fault's row; NO when the row is gone.
BOOL CDFireSQLiteFault(NSManagedObject *object, NSError **error) {
    NSManagedObjectID *objectID = object.objectID;
    sqlite3 *db = CDStoreDatabase(objectID.persistentStore);
    if (!object.isFault || objectID.isTemporaryID || !db) return YES;
    NSMutableArray *properties = [NSMutableArray array];
    NSString *sql = [CDSelectRows(object.entity, properties) stringByAppendingString:@" WHERE Z_PK=?"];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK)
        return CDReturnError(error, CDSQLiteError(db, @"Could not prepare a fault"));
    sqlite3_bind_int64(statement, 1, [CDGet(objectID, @"primaryKey") longLongValue]);
    BOOL found = sqlite3_step(statement) == SQLITE_ROW;
    if (found) {
        CDApplyRow(object, objectID.persistentStore, statement, properties, NO);
        CDSet(object, @"committedValues", [[CDGet(object, @"values") copy] autorelease]);
        CDSet(object, @"fault", [NSNumber numberWithBool:NO]);
    }
    sqlite3_finalize(statement);
    if (!found) return CDReturnError(error, CDError(133000, @"The managed object no longer exists in the store."));
    [object awakeFromFetch];
    return YES;
}

// The objects on the far side of a saved object's to-many relationship,
// found through the inverse to-one column.
id CDLoadSQLiteToMany(NSManagedObject *object, NSRelationshipDescription *relationship) {
    NSManagedObjectID *objectID = object.objectID;
    NSPersistentStore *store = objectID.persistentStore;
    sqlite3 *db = CDStoreDatabase(store);
    NSRelationshipDescription *inverse = relationship.inverseRelationship;
    NSEntityDescription *destination = relationship.destinationEntity;
    if (!db || objectID.isTemporaryID || !inverse || inverse.isToMany || !destination) return nil;
    NSString *sql = [NSString stringWithFormat:@"SELECT Z_PK FROM %@ WHERE %@=? ORDER BY Z_PK", CDQuote(CDTableName(destination)),
                     CDQuote([@"Z" stringByAppendingString:[inverse.name uppercaseString]])];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) return nil;
    sqlite3_bind_int64(statement, 1, [CDGet(objectID, @"primaryKey") longLongValue]);
    id objects = relationship.isOrdered ? (id)[NSMutableOrderedSet orderedSet] : (id)[NSMutableSet set];
    NSManagedObjectContext *context = object.managedObjectContext;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSManagedObject *related = [context objectWithID:CDMakeObjectID(destination, store, sqlite3_column_int64(statement, 0), NO)];
        if (related) [objects addObject:related];
    }
    sqlite3_finalize(statement);
    return objects;
}

NSArray *CDStoreFetch(NSManagedObjectContext *context, NSFetchRequest *request, NSError **error) {
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    if (!coordinator && context.parentContext) return [context.parentContext executeFetchRequest:request error:error];
    if (!coordinator) { CDReturnError(error, CDError(134080, @"The context has no persistent store coordinator.")); return nil; }
    NSString *entityName = request.entityName;
    NSEntityDescription *entity = [coordinator.managedObjectModel.entitiesByName objectForKey:entityName];
    if (!entity) { CDReturnError(error, CDError(134060, [NSString stringWithFormat:@"No entity named %@ exists in the model.", entityName ?: @"(null)"])); return nil; }
    NSMutableArray *objects = [NSMutableArray array];
    NSArray *stores = request.affectedStores ?: coordinator.persistentStores;
    for (NSPersistentStore *store in stores) {
        if (CDIsCustomStore(store)) {
            NSArray *found = CDCustomStoreFetch(context, store, request, entity, error);
            if (!found) return nil;
            for (NSManagedObject *object in found) if (![objects containsObject:object]) [objects addObject:object];
            continue;
        }
        sqlite3 *db = CDStoreDatabase(store);
        if (!db) continue;
        NSMutableArray *properties = [NSMutableArray array];
        NSString *sql = CDSelectRows(entity, properties);
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
            CDReturnError(error, CDSQLiteError(db, @"Could not prepare a fetch"));
            return nil;
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSInteger primaryKey = sqlite3_column_int64(statement, 0);
            NSManagedObject *object = CDRegisterFetchedObject(context, entity, store, primaryKey);
            BOOL preserveChanges = object.isUpdated && !request.shouldRefreshRefetchedObjects;
            CDApplyRow(object, store, statement, properties, preserveChanges);
            CDSet(object, @"fault", [NSNumber numberWithBool:NO]);
            [object awakeFromFetch];
            if ((!request.predicate || [request.predicate evaluateWithObject:object]) && ![objects containsObject:object]) [objects addObject:object];
        }
        sqlite3_finalize(statement);
    }
    return objects;
}

// Derived attributes take their values when the object is saved.
static void CDComputeDerivedAttributes(NSManagedObject *object) {
    for (NSPropertyDescription *property in object.entity.properties) {
        if (![property isKindOfClass:[NSDerivedAttributeDescription class]]) continue;
        NSExpression *expression = [(NSDerivedAttributeDescription *)property derivationExpression];
        if (!expression) continue;
        id value = nil;
        @try { value = [expression expressionValueWithObject:object context:nil]; }
        @catch (NSException *exception) { value = nil; }
        CDObjectSetValue(object, value == [NSNull null] ? nil : value, property.name, NO);
    }
}

BOOL CDStoreSave(NSManagedObjectContext *context, NSError **error) {
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    NSArray *stores = coordinator.persistentStores;
    if (!stores.count) return CDReturnError(error, CDError(134080, @"No persistent store is attached to this context."));
    [coordinator lock];
    NSMutableSet *touched = [NSMutableSet set];
    NSArray *inserted = [context.insertedObjects allObjects];
    NSArray *updated = [context.updatedObjects allObjects];
    NSArray *deleted = [context.deletedObjects allObjects];
    for (NSManagedObject *object in [inserted arrayByAddingObjectsFromArray:updated]) CDComputeDerivedAttributes(object);
    BOOL ok = YES;
    for (NSManagedObject *object in [inserted arrayByAddingObjectsFromArray:[updated arrayByAddingObjectsFromArray:deleted]]) {
        NSPersistentStore *store = CDStoreForObject(object, stores);
        if (!store) { ok = NO; CDReturnError(error, CDError(134080, @"No store can hold this entity.")); break; }
        [touched addObject:store];
    }
    for (NSPersistentStore *store in touched) {
        if (CDIsCustomStore(store)) {
            NSMutableArray *parts[3] = { [NSMutableArray array], [NSMutableArray array], [NSMutableArray array] };
            NSArray *lists[3] = { inserted, updated, deleted };
            for (int i = 0; i < 3; i++)
                for (NSManagedObject *object in lists[i]) if (CDStoreForObject(object, stores) == store) [parts[i] addObject:object];
            if (!(ok = CDCustomStoreSave(context, store, parts[0], parts[1], parts[2], error))) break;
            continue;
        }
        sqlite3 *db = CDStoreDatabase(store);
        if (!db || store.isReadOnly) { ok = NO; CDReturnError(error, CDError(134030, @"The selected persistent store cannot be written.")); break; }
        if (!CDExec(db, @"BEGIN IMMEDIATE", error)) { ok = NO; break; }
        for (NSManagedObject *object in inserted) {
            if (CDStoreForObject(object, stores) != store) continue;
            CDSet(object.objectID, @"persistentStore", store);
            if (!CDWriteObject(store, object, YES, error)) { ok = NO; break; }
        }
        if (ok) for (NSManagedObject *object in inserted) {
            if (CDStoreForObject(object, stores) != store) continue;
            if (!CDWriteToOneRelationships(store, object, error)) { ok = NO; break; }
        }
        if (ok) for (NSManagedObject *object in updated) {
            if (CDStoreForObject(object, stores) != store) continue;
            if (!CDWriteObject(store, object, NO, error) || !CDWriteToOneRelationships(store, object, error)) { ok = NO; break; }
        }
        if (ok) for (NSManagedObject *object in deleted) {
            if (CDStoreForObject(object, stores) != store) continue;
            if (!CDDeleteRow(store, object, error)) { ok = NO; break; }
        }
        if (ok) ok = CDExec(db, @"COMMIT", error);
        else CDExec(db, @"ROLLBACK", NULL);
        if (!ok) break;
    }
    [coordinator unlock];
    if (!ok) return NO;
    NSMutableSet *insertedIDs = [NSMutableSet set];
    NSMutableSet *updatedIDs = [NSMutableSet set];
    NSMutableSet *deletedIDs = [NSMutableSet set];
    for (NSManagedObject *object in inserted) { [insertedIDs addObject:object.objectID]; CDObjectDidPersist(object, CDStoreForObject(object, stores)); }
    for (NSManagedObject *object in updated) { [updatedIDs addObject:object.objectID]; CDObjectDidPersist(object, CDStoreForObject(object, stores)); }
    for (NSManagedObject *object in deleted) { [deletedIDs addObject:object.objectID]; CDSet(object, @"deleted", [NSNumber numberWithBool:YES]); }
    NSDictionary *objectChanges = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSSet setWithArray:inserted], NSInsertedObjectsKey,
                                   [NSSet setWithArray:updated], NSUpdatedObjectsKey,
                                   [NSSet setWithArray:deleted], NSDeletedObjectsKey, nil];
    NSDictionary *idChanges = [NSDictionary dictionaryWithObjectsAndKeys:insertedIDs, NSInsertedObjectsKey,
                               updatedIDs, NSUpdatedObjectsKey, deletedIDs, NSDeletedObjectsKey, nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextDidSaveNotification object:context userInfo:objectChanges];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextDidSaveObjectIDsNotification object:context userInfo:idChanges];
    [CDGet(context, @"insertedObjects") removeAllObjects];
    [CDGet(context, @"updatedObjects") removeAllObjects];
    [CDGet(context, @"deletedObjects") removeAllObjects];
    CDRekeyRegisteredObjects(context);
    return YES;
}

BOOL CDStoreDelete(NSManagedObjectContext *context, NSManagedObject *object, NSError **error) {
    (void)context; (void)object; (void)error;
    return NO;
}
