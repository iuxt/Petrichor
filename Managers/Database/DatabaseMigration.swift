//
// DatabaseMigration.swift
//
// Database migration entry point for Petrichor using GRDB's migration system.
//
// The schema is fully defined in `DatabaseManager.setupDatabaseSchema` (DMSetup.swift)
// and represents the latest baseline. The single `v1_initial_schema` migration either
// creates that schema on a fresh database or treats an existing database as already
// baseline (every released database has been carried to the current schema by the
// historical v2..v16 migrations, which were squashed here).
//

import Foundation
import GRDB

/// Registers database migrations using GRDB's built-in migration system
enum DatabaseMigrator {
    /// Creates and configures the database migrator with all migrations
    static func setupMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()

        // MARK: - Baseline Schema
        migrator.registerMigration("v1_initial_schema") { db in
            // Fresh database — build the current schema from the static setup methods.
            // Existing databases are already at baseline (legacy v2..v16 migrations were
            // applied in prior releases and have been squashed into setupDatabaseSchema).
            let tablesExist = try db.tableExists("tracks")
                || db.tableExists("folders")
                || db.tableExists("artists")

            if !tablesExist {
                try DatabaseManager.setupDatabaseSchema(in: db)
            } else {
                Logger.info("Existing database detected, marking as v1 baseline")
            }
        }

        // MARK: - Future Migrations
        // Add new migrations here as: migrator.registerMigration("v2_description") { db in ... }

        return migrator
    }

    /// Apply all pending migrations to the database
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        let migrator = setupMigrator()
        try migrator.migrate(dbQueue)

        Logger.info("Database migrations completed")
    }

    /// Check if there are unapplied migrations
    static func hasUnappliedMigrations(_ dbQueue: DatabaseQueue) -> Bool {
        do {
            let migrator = setupMigrator()
            return try dbQueue.read { db in
                try migrator.hasBeenSuperseded(db)
            }
        } catch {
            Logger.error("Failed to check migration status: \(error)")
            return false
        }
    }

    /// Get list of applied migrations
    static func appliedMigrations(_ dbQueue: DatabaseQueue) -> [String] {
        // Return empty array for now - can be implemented if needed
        []
    }
}

// MARK: - Migration Helpers

extension Database {
    /// Helper to create an index if it doesn't exist
    func createIndexIfNotExists(
        name: String,
        table: String,
        columns: [String],
        unique: Bool = false
    ) throws {
        let indexExists = try self.indexes(on: table).contains { $0.name == name }

        if !indexExists {
            try self.create(
                index: name,
                on: table,
                columns: columns,
                unique: unique,
                ifNotExists: true
            )
        }
    }

    /// Helper to create a table only if it doesn't exist
    func createTableIfNotExists(
        _ name: String,
        body: (TableDefinition) throws -> Void
    ) throws {
        try self.create(table: name, ifNotExists: true, body: body)
    }
}
