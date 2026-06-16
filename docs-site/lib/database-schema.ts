/**
 * RubyAuth database schema helpers for docs-site MDX tooling.
 * Core table shapes mirror `packages/better_auth/lib/better_auth/schema.rb`.
 */

export interface SchemaField {
	name: string;
	type: string;
	description: string;
	isPrimaryKey?: boolean;
	isForeignKey?: boolean;
	isOptional?: boolean;
	isUnique?: boolean;
	references?: {
		model: string;
		field: string;
		onDelete?: string;
	};
}

export type SqlDialect = "postgresql" | "mysql" | "sqlite";

const typeAliases: Record<string, string> = {
	text: "string",
	integer: "number",
	int: "number",
	bigint: "number",
	float: "number",
	double: "number",
	decimal: "number",
	bool: "boolean",
	object: "json",
	timestamp: "date",
	datetime: "date",
	date: "date",
};

function normalizeType(type: string): string {
	const raw = type.toLowerCase().replace("[]", "");
	return typeAliases[raw] ?? raw;
}

function sqlColumnType(type: string, dialect: SqlDialect): string {
	const t = normalizeType(type);
	switch (t) {
		case "string":
			return dialect === "mysql" ? "VARCHAR(255)" : "TEXT";
		case "number":
			return dialect === "postgresql" ? "INTEGER" : "INT";
		case "boolean":
			return dialect === "postgresql" ? "BOOLEAN" : "TINYINT(1)";
		case "date":
			return dialect === "sqlite" ? "TEXT" : "TIMESTAMP";
		case "json":
			return dialect === "postgresql" ? "JSONB" : "JSON";
		default:
			return "TEXT";
	}
}

function rubyColumnType(type: string): string {
	const t = normalizeType(type);
	switch (t) {
		case "string":
			return ":string";
		case "number":
			return ":integer";
		case "boolean":
			return ":boolean";
		case "date":
			return ":datetime";
		case "json":
			return ":json";
		default:
			return ":string";
	}
}

function physicalTableName(name: string): string {
	const map: Record<string, string> = {
		user: "users",
		session: "sessions",
		account: "accounts",
		verification: "verifications",
		rateLimit: "rate_limits",
		organization: "organizations",
		member: "members",
		invitation: "invitations",
		apikey: "api_keys",
		passkey: "passkeys",
	};
	return map[name] ?? name.replace(/([A-Z])/g, "_$1").toLowerCase();
}

export function generateCreateTableSql(
	tableName: string,
	fields: SchemaField[],
	dialect: SqlDialect = "postgresql",
): string {
	const table = physicalTableName(tableName);
	const lines = fields.map((field) => {
		const col = field.name.replace(/([A-Z])/g, "_$1").toLowerCase();
		let def = `  ${col} ${sqlColumnType(field.type, dialect)}`;
		if (field.isPrimaryKey) def += " PRIMARY KEY";
		if (field.isUnique) def += " UNIQUE";
		if (!field.isOptional && !field.isPrimaryKey) def += " NOT NULL";
		return def;
	});

	return `CREATE TABLE ${table} (\n${lines.join(",\n")}\n);`;
}

export function generateRubySchemaSnippet(
	tableName: string,
	fields: SchemaField[],
): string {
	const table = physicalTableName(tableName);
	const lines = fields.map((field) => {
		const col = field.name.replace(/([A-Z])/g, "_$1").toLowerCase();
		const parts = [`t.${rubyColumnType(field.type).slice(1)} :${col}`];
		if (field.isPrimaryKey) parts.push("primary_key: true");
		if (field.isUnique) parts.push("unique: true");
		if (!field.isOptional && !field.isPrimaryKey) parts.push("null: false");
		if (field.references) {
			parts.push(
				`foreign_key: { to_table: :${physicalTableName(field.references.model)}, on_delete: :${field.references.onDelete ?? "cascade"} }`,
			);
		}
		return `    ${parts.join(", ")}`;
	});

	return `# ActiveRecord-style columns for ${table}\ncreate_table :${table} do |t|\n${lines.join("\n")}\n  t.timestamps\nend`;
}

/** Core auth tables from BetterAuth schema.rb (reference for docs authors). */
export const coreTables: Record<string, SchemaField[]> = {
	user: [
		{
			name: "id",
			type: "string",
			description: "Primary key",
			isPrimaryKey: true,
		},
		{ name: "name", type: "string", description: "Display name" },
		{ name: "email", type: "string", description: "Unique email", isUnique: true },
		{
			name: "emailVerified",
			type: "boolean",
			description: "Whether email is verified",
		},
		{ name: "image", type: "string", description: "Avatar URL", isOptional: true },
		{ name: "createdAt", type: "date", description: "Created timestamp" },
		{ name: "updatedAt", type: "date", description: "Updated timestamp" },
	],
	session: [
		{
			name: "id",
			type: "string",
			description: "Primary key",
			isPrimaryKey: true,
		},
		{ name: "expiresAt", type: "date", description: "Session expiry" },
		{ name: "token", type: "string", description: "Session token", isUnique: true },
		{ name: "ipAddress", type: "string", description: "Client IP", isOptional: true },
		{
			name: "userAgent",
			type: "string",
			description: "Client user agent",
			isOptional: true,
		},
		{
			name: "userId",
			type: "string",
			description: "FK to user",
			isForeignKey: true,
			references: { model: "user", field: "id", onDelete: "cascade" },
		},
	],
	account: [
		{
			name: "id",
			type: "string",
			description: "Primary key",
			isPrimaryKey: true,
		},
		{ name: "accountId", type: "string", description: "Provider account id" },
		{ name: "providerId", type: "string", description: "OAuth provider id" },
		{
			name: "userId",
			type: "string",
			description: "FK to user",
			isForeignKey: true,
			references: { model: "user", field: "id", onDelete: "cascade" },
		},
		{
			name: "password",
			type: "string",
			description: "Hashed password (credential provider)",
			isOptional: true,
		},
	],
	verification: [
		{
			name: "id",
			type: "string",
			description: "Primary key",
			isPrimaryKey: true,
		},
		{ name: "identifier", type: "string", description: "Lookup key" },
		{ name: "value", type: "string", description: "Verification value" },
		{ name: "expiresAt", type: "date", description: "Expiry timestamp" },
	],
};

export const tables = coreTables;
