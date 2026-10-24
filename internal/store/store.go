// Package store opens the SQLite database and applies schema migrations.
package store

import "embed"

// Migrations holds the versioned schema files, applied in filename order.
//
//go:embed migrations/*.sql
var Migrations embed.FS
