public struct MySQLType: Equatable {
    public var base: String      // uppercased, e.g. "VARCHAR", "ENUM"
    public var args: [String]    // "(10)" -> ["10"]; ENUM args keep their quotes
    public var isUnsigned: Bool

    public init(base: String, args: [String] = [], isUnsigned: Bool = false) {
        self.base = base
        self.args = args
        self.isUnsigned = isUnsigned
    }
}

public struct IndexedColumn: Equatable {
    public var name: String
    public var prefixLength: Int?
    public var descending: Bool

    public init(name: String, prefixLength: Int? = nil, descending: Bool = false) {
        self.name = name
        self.prefixLength = prefixLength
        self.descending = descending
    }
}

public struct Column: Equatable {
    public var name: String
    public var type: MySQLType
    public var isNotNull: Bool
    public var isAutoIncrement: Bool
    public var defaultSQL: String?          // raw MySQL default text, requoted
    public var collation: String?           // e.g. "utf8mb4_general_ci"
    public var generatedExpression: String? // requoted expression
    public var generatedIsStored: Bool

    public init(name: String, type: MySQLType, isNotNull: Bool = false,
                isAutoIncrement: Bool = false, defaultSQL: String? = nil,
                collation: String? = nil, generatedExpression: String? = nil,
                generatedIsStored: Bool = false) {
        self.name = name
        self.type = type
        self.isNotNull = isNotNull
        self.isAutoIncrement = isAutoIncrement
        self.defaultSQL = defaultSQL
        self.collation = collation
        self.generatedExpression = generatedExpression
        self.generatedIsStored = generatedIsStored
    }
}

public enum IndexKind: Equatable { case normal, fulltext, spatial }

public struct Index: Equatable {
    public var name: String?
    public var columns: [IndexedColumn]
    public var isUnique: Bool
    public var kind: IndexKind

    public init(name: String?, columns: [IndexedColumn], isUnique: Bool = false,
                kind: IndexKind = .normal) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.kind = kind
    }
}

public struct ForeignKey: Equatable {
    public var columns: [String]
    public var referencedTable: String
    public var referencedColumns: [String]
    public var onDelete: String?    // e.g. "CASCADE"
    public var onUpdate: String?

    public init(columns: [String], referencedTable: String, referencedColumns: [String],
                onDelete: String? = nil, onUpdate: String? = nil) {
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

public struct Table: Equatable {
    public var name: String
    public var columns: [Column]
    public var primaryKey: [IndexedColumn]
    public var indexes: [Index]
    public var foreignKeys: [ForeignKey]
    public var checks: [String]     // requoted CHECK expressions

    public init(name: String, columns: [Column] = [], primaryKey: [IndexedColumn] = [],
                indexes: [Index] = [], foreignKeys: [ForeignKey] = [], checks: [String] = []) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.checks = checks
    }
}

extension Table {
    public func column(named name: String) -> Column? {
        columns.first { $0.name == name }
    }
}
