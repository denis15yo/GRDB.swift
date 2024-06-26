/// SQLForeignKeyRequest looks for the foreign keys associations need to
/// join tables.
///
/// Columns mapping come from foreign keys, when they exist in the
/// database schema.
///
/// When the schema does not define any foreign key, we can still infer complete
/// mapping from partial information and primary keys.
struct SQLForeignKeyRequest {
    let originTable: String
    let destinationTable: String
    let originColumns: [String]?
    let destinationColumns: [String]?
    
    init(originTable: String, destinationTable: String, foreignKey: ForeignKey?) {
        self.originTable = originTable
        self.destinationTable = destinationTable
        
        self.originColumns = foreignKey?.originColumns
        self.destinationColumns = foreignKey?.destinationColumns
    }
    
    /// The (origin, destination) column pairs that join a left table to a right table.
    func fetchForeignKeyMapping(_ db: Database) throws -> ForeignKeyMapping {
        if let originColumns, let destinationColumns {
            // Total information: no need to query the database schema.
            GRDBPrecondition(originColumns.count == destinationColumns.count, "Number of columns don't match")
            let mapping = zip(originColumns, destinationColumns).map {
                (origin: $0, destination: $1)
            }
            return mapping
        }
        
        // Incomplete information: let's look for schema foreign keys
        //
        // But maybe the tables are views. In this case, don't throw
        // "no such table" error, because this is confusing for the user,
        // as discovered in <https://github.com/groue/GRDB.swift/discussions/1481>.
        // Instead, we'll crash with a clear message.
        
        guard let originType = try tableType(db, for: originTable) else {
            throw DatabaseError.noSuchTable(originTable)
        }
        
        if originType.isView {
            if originColumns == nil {
                fatalError("""
                    Could not infer foreign key from '\(originTable)' \
                    to '\(destinationTable)'. To fix this error, provide an \
                    explicit `ForeignKey` in the association definition.
                    """)
            }
        } else {
            let foreignKeys = try db.foreignKeys(on: originTable).filter { foreignKey in
                if destinationTable.lowercased() != foreignKey.destinationTable.lowercased() {
                    return false
                }
                if let originColumns {
                    let originColumns = Set(originColumns.lazy.map { $0.lowercased() })
                    let foreignKeyColumns = Set(foreignKey.mapping.lazy.map { $0.origin.lowercased() })
                    if originColumns != foreignKeyColumns {
                        return false
                    }
                }
                if let destinationColumns {
                    // TODO: test
                    let destinationColumns = Set(destinationColumns.lazy.map { $0.lowercased() })
                    let foreignKeyColumns = Set(foreignKey.mapping.lazy.map { $0.destination.lowercased() })
                    if destinationColumns != foreignKeyColumns {
                        return false
                    }
                }
                return true
            }
            
            // Matching foreign key(s) found
            if let foreignKey = foreignKeys.first {
                if foreignKeys.count == 1 {
                    // Non-ambiguous
                    return foreignKey.mapping
                } else {
                    // Ambiguous: can't choose
                    fatalError("""
                    Ambiguous foreign key from '\(originTable)' to \
                    '\(destinationTable)'. To fix this error, provide an \
                    explicit `ForeignKey` in the association definition.
                    """)
                }
            }
        }
        
        // No matching foreign key found: use the destination primary key
        if let originColumns {
            guard let destinationType = try tableType(db, for: destinationTable) else {
                throw DatabaseError.noSuchTable(destinationTable)
            }
            if destinationType.isView {
                fatalError("""
                    Could not infer foreign key from '\(originTable)' \
                    to '\(destinationTable)'. To fix this error, provide an \
                    explicit `ForeignKey` in the association definition, \
                    with both origin and destination columns.
                    """)
            }
            let destinationColumns = try db.primaryKey(destinationTable).columns
            if originColumns.count == destinationColumns.count {
                let mapping = zip(originColumns, destinationColumns).map {
                    (origin: $0, destination: $1)
                }
                return mapping
            }
        }
        
        fatalError("""
            Could not infer foreign key from '\(originTable)' to \
            '\(destinationTable)'. To fix this error, provide an \
            explicit `ForeignKey` in the association definition.
            """)
    }
    
    private struct TableType {
        var isView: Bool
    }
    
    private func tableType(_ db: Database, for name: String) throws -> TableType? {
        for schemaID in try db.schemaIdentifiers() {
            if try db.schema(schemaID).containsObjectNamed(name, ofType: .table) {
                return TableType(isView: false)
            }
            if try db.schema(schemaID).containsObjectNamed(name, ofType: .view) {
                return TableType(isView: true)
            }
        }
        
        return nil
    }
}

// Foreign key columns mapping
typealias ForeignKeyMapping = [(origin: String, destination: String)]

// Join columns mapping
typealias JoinMapping = [(left: String, right: String)]

extension ForeignKeyMapping {
    /// Orient the foreign key mapping for a SQL join.
    ///
    /// - parameter originIsLeft: Whether the table at the origin of a
    ///   foreign key is on the left of a JOIN clause.
    ///
    ///     For example, the two requests below use the same
    ///     `ForeignKeyMapping` from `book.authorID` (origin of the foreign key)
    ///     to `author.id` (destination).
    ///
    ///     In the first request, the book origin is on the left of the
    ///     join clause:
    ///
    ///         // SELECT book.*, author.*
    ///         // FROM book
    ///         // JOIN author ON author.id = book.authorID
    ///         Book.including(required: Book.author)
    ///
    ///     In the second request, the book origin is on the right of the
    ///     join clause:
    ///
    ///         // SELECT author.*, book.*
    ///         // FROM author
    ///         // JOIN book ON book.authorID = author.id
    ///         Author.including(required: Author.books)
    func joinMapping(originIsLeft: Bool) -> JoinMapping {
        if originIsLeft {
            return map { (left: $0.origin, right: $0.destination) }
        } else {
            return map { (left: $0.destination, right: $0.origin) }
        }
    }
}
