# frozen_string_literal: true

require_relative "../../spec_helper"
require "better_auth/sql_migration"

RSpec.describe BetterAuth::Hanami::Migration do
  let(:config) { BetterAuth::Configuration.new(secret: secret, database: :memory) }

  it "renders a ROM SQL migration from the core Better Auth schema" do
    migration = described_class.render(config)

    expect(migration).to include("ROM::SQL.migration do")
    expect(migration).to include("create_table :users do")
    expect(migration).to include("column :id, String, null: false")
    expect(migration).to include("primary_key [:id]")
    expect(migration).to include("column :email_verified, TrueClass, null: false, default: false")
    expect(migration).to include("index :email, unique: true")
    expect(migration).to include("foreign_key :user_id, :users, type: String, null: false, on_delete: :cascade")
  end

  it "renders plugin tables, defaults, indexes, and foreign keys" do
    plugin = BetterAuth::Plugin.new(
      id: "audit",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            id: {type: "string", required: true},
            userId: {type: "string", references: {model: "user", field: "id", on_delete: "cascade"}, index: true},
            action: {type: "string", required: true, unique: true},
            attempts: {type: "number", required: true, default_value: 0},
            createdAt: {type: "date", required: true}
          }
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(secret: secret, database: :memory, plugins: [plugin])

    migration = described_class.render(plugin_config)

    expect(migration).to include("create_table :audit_logs do")
    expect(migration).to include("foreign_key :user_id, :users, type: String, on_delete: :cascade")
    expect(migration).to include("column :action, String, null: false")
    expect(migration).to include("column :attempts, Integer, null: false, default: 0")
    expect(migration).to include("column :created_at, DateTime, null: false")
    expect(migration).to include("index :user_id")
    expect(migration).to include("index :action, unique: true")
  end

  it "omits plugin tables with migrations disabled" do
    plugin = BetterAuth::Plugin.new(
      id: "external-audit",
      schema: {
        auditLog: {
          disableMigration: true,
          fields: {userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true}}
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(secret: secret, database: :memory, plugins: [plugin])

    migration = described_class.render(plugin_config)

    expect(migration).not_to include("create_table :audit_logs")
  end

  it "renders non-id foreign key targets with explicit keys" do
    plugin = BetterAuth::Plugin.new(
      id: "profile",
      schema: {
        profile: {
          model_name: "profiles",
          fields: {
            id: {type: "string", required: true},
            ownerEmail: {type: "string", required: true, field_name: "owner_email", references: {model: "user", field: "email"}}
          }
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(secret: secret, database: :memory, plugins: [plugin])

    migration = described_class.render(plugin_config)

    expect(migration).to include("foreign_key :owner_email, :users, type: String, null: false, key: :email, on_delete: :cascade")
  end

  it "merges logical plugin models that share one physical table" do
    plugin = BetterAuth::Plugin.new(
      id: "profile-collision",
      schema: {
        auditProfile: {
          model_name: "users",
          fields: {
            auditFlag: {type: "boolean", required: false, index: true}
          }
        },
        billingProfile: {
          model_name: "users",
          fields: {
            billingRef: {type: "string", required: false}
          }
        },
        profileLink: {
          model_name: "profile_links",
          fields: {
            auditFlag: {type: "boolean", required: false, references: {model: "auditProfile", field: "auditFlag"}}
          }
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(secret: secret, database: :memory, plugins: [plugin])

    migration = described_class.render(plugin_config)

    expect(migration.scan("create_table :users")).to eq(["create_table :users"])
    expect(migration).to include("column :audit_flag, TrueClass")
    expect(migration).to include("column :billing_ref, String")
    expect(migration).to include("index :audit_flag")
    expect(migration).to include("foreign_key :audit_flag, :users, type: TrueClass, key: :audit_flag, on_delete: :cascade")
  end

  it "renders bigint number fields for database rate limit millisecond timestamps" do
    rate_limit_config = BetterAuth::Configuration.new(secret: secret, database: :memory, rate_limit: {storage: "database"})

    migration = described_class.render(rate_limit_config)

    expect(migration).to include("create_table :rate_limits do")
    expect(migration).to include("column :last_request, :Bignum, null: false")
  end

  it "renders json and array schema field types" do
    plugin = BetterAuth::Plugin.new(
      id: "typed",
      schema: {
        typedRecord: {
          model_name: "typed_records",
          fields: {
            id: {type: "string", required: true},
            metadata: {type: "json", required: false},
            tags: {type: "string[]", required: false},
            scores: {type: "number[]", required: false}
          }
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(secret: secret, database: :memory, plugins: [plugin])

    migration = described_class.render(plugin_config)

    expect(migration).to include("column :metadata, JSON")
    expect(migration).to include("column :tags, JSON")
    expect(migration).to include("column :scores, JSON")
  end

  it "renders official external plugin tables with core-table field plugins" do
    plugin_config = BetterAuth::Configuration.new(
      secret: secret,
      database: :memory,
      plugins: [
        external_schema_plugin,
        BetterAuth::Plugins.username
      ]
    )

    migration = described_class.render(plugin_config)

    expect(migration).to include("create_table :external_credentials do")
    expect(migration).to include("column :credential_id, String, null: false")
    expect(migration).to include("index :user_id")
    expect(migration).to include("column :username, String")
  end

  it "renders pending ROM migrations from the shared migration plan" do
    plugin = BetterAuth::Plugin.new(
      id: "audit",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            id: {type: "string", required: true},
            userId: {type: "string", references: {model: "user", field: "id"}, index: true},
            action: {type: "string", required: true, unique: true}
          }
        }
      }
    )
    plugin_config = BetterAuth::Configuration.new(
      secret: secret,
      database: :memory,
      plugins: [plugin],
      user: {
        additional_fields: {
          role: {type: "string", required: false, index: true}
        }
      }
    )
    existing = {
      "users" => {
        name: "users",
        columns: {"id" => "varchar", "email" => "varchar", "name" => "varchar", "email_verified" => "boolean", "image" => "text", "created_at" => "datetime", "updated_at" => "datetime"},
        indexes: {names: Set.new(["index_users_on_email"]), columns: Set.new(["email"]), unique_columns: Set.new(["email"])}
      },
      "sessions" => {name: "sessions", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}},
      "accounts" => {name: "accounts", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}},
      "verifications" => {name: "verifications", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}}
    }
    plan = BetterAuth::SQLMigration.plan_from_existing(plugin_config, existing: existing, dialect: :postgres)

    migration = described_class.render_pending(plan)

    expect(migration).to include("ROM::SQL.migration do")
    expect(migration).to include("create_table :audit_logs do")
    expect(migration).to include("alter_table :users do")
    expect(migration).to include("add_column :role, String")
    expect(migration).to include("add_index :role")
    expect(migration).not_to include("create_table :users")
  end

  it "renders pending reference fields as foreign keys" do
    plugin_config = BetterAuth::Configuration.new(
      secret: secret,
      database: :memory,
      user: {
        additional_fields: {
          managerEmail: {type: "string", required: false, field_name: "manager_email", references: {model: "user", field: "email", on_delete: "set_null"}, index: true}
        }
      }
    )
    existing = {
      "users" => {
        name: "users",
        columns: {"id" => "varchar", "email" => "varchar", "name" => "varchar", "email_verified" => "boolean", "image" => "text", "created_at" => "datetime", "updated_at" => "datetime"},
        indexes: {names: Set.new(["index_users_on_email"]), columns: Set.new(["email"]), unique_columns: Set.new(["email"])}
      },
      "sessions" => {name: "sessions", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}},
      "accounts" => {name: "accounts", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}},
      "verifications" => {name: "verifications", columns: {}, indexes: {names: Set.new, columns: Set.new, unique_columns: Set.new}}
    }
    plan = BetterAuth::SQLMigration.plan_from_existing(plugin_config, existing: existing, dialect: :postgres)

    migration = described_class.render_pending(plan)

    expect(migration).to include("add_foreign_key :manager_email, :users, type: String, key: :email, on_delete: :set_null")
    expect(migration).not_to include("add_column :manager_email")
    expect(migration).to include("add_index :manager_email")
  end

  def secret
    "test-secret-that-is-long-enough-for-validation"
  end

  def external_schema_plugin
    BetterAuth::Plugin.new(
      id: "external-schema",
      schema: {
        externalCredential: {
          model_name: "external_credentials",
          fields: {
            credentialId: {type: "string", required: true, unique: true},
            userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true}
          }
        }
      }
    )
  end
end
