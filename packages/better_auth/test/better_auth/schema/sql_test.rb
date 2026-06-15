# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthSchemaSQLTest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_postgres_ddl_uses_postgres_types_constraints_and_indexes
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "users"'
    assert_includes sql, '"id" text PRIMARY KEY'
    assert_includes sql, '"email_verified" boolean NOT NULL DEFAULT false'
    assert_includes sql, '"created_at" timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP'
    assert_includes sql, 'UNIQUE ("email")'
    assert_includes sql, 'FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_sessions_on_user_id" ON "sessions" ("user_id")'
  end

  def test_postgres_ddl_uses_custom_table_and_field_names
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      user: {
        model_name: "app_users",
        fields: {
          email: "email_address"
        }
      },
      session: {
        model_name: "app_sessions",
        fields: {
          userId: "owner_id"
        }
      }
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "app_users"'
    assert_includes sql, '"email_address" text NOT NULL'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "app_sessions"'
    assert_includes sql, '"owner_id" text NOT NULL'
    assert_includes sql, 'FOREIGN KEY ("owner_id") REFERENCES "app_users" ("id") ON DELETE CASCADE'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_app_sessions_on_owner_id" ON "app_sessions" ("owner_id")'
  end

  def test_mysql_ddl_uses_mysql_types_constraints_indexes_and_engine
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).join("\n")

    assert_includes sql, "CREATE TABLE IF NOT EXISTS `users`"
    assert_includes sql, "`id` varchar(191) PRIMARY KEY"
    assert_includes sql, "`email_verified` tinyint(1) NOT NULL DEFAULT 0"
    assert_includes sql, "`created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)"
    assert_includes sql, "UNIQUE KEY `uniq_users_email` (`email`)"
    assert_includes sql, "CONSTRAINT `fk_sessions_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE"
    assert_includes sql, "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
  end

  def test_mysql_ddl_bounds_string_columns_with_defaults
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      user: {
        additional_fields: {
          role: {type: "string", required: false, default_value: "member"}
        }
      }
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).join("\n")

    assert_includes sql, "`role` varchar(191) DEFAULT 'member'"
    refute_includes sql, "`role` text NULL DEFAULT 'member'"
  end

  def test_sqlite_ddl_uses_sqlite_types_constraints_and_indexes
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "users"'
    assert_includes sql, '"id" text PRIMARY KEY'
    assert_includes sql, '"email_verified" integer NOT NULL DEFAULT 0'
    assert_includes sql, '"created_at" date NOT NULL DEFAULT CURRENT_TIMESTAMP'
    assert_includes sql, 'UNIQUE ("email")'
    assert_includes sql, 'FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_sessions_on_user_id" ON "sessions" ("user_id")'
  end

  def test_mssql_ddl_uses_mssql_types_constraints_and_indexes
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mssql).join("\n")

    assert_includes sql, "IF OBJECT_ID(N'[users]', N'U') IS NULL"
    assert_includes sql, "[id] varchar(255) PRIMARY KEY"
    assert_includes sql, "[email_verified] smallint NOT NULL DEFAULT 0"
    assert_includes sql, "[image] varchar(8000) NULL"
    assert_includes sql, "[created_at] datetime2(3) NOT NULL DEFAULT CURRENT_TIMESTAMP"
    assert_includes sql, "CONSTRAINT [uniq_users_email] UNIQUE ([email])"
    assert_includes sql, "CONSTRAINT [fk_sessions_user_id] FOREIGN KEY ([user_id]) REFERENCES [users] ([id]) ON DELETE CASCADE"
    assert_includes sql, "CREATE INDEX [index_sessions_on_user_id] ON [sessions] ([user_id])"
  end

  def test_mssql_nullable_unique_fields_use_filtered_indexes
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [BetterAuth::Plugins.phone_number]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mssql).join("\n")

    refute_includes sql, "CONSTRAINT [uniq_users_phone_number] UNIQUE ([phone_number])"
    assert_includes sql, "CREATE UNIQUE INDEX [uniq_users_phone_number] ON [users] ([phone_number]) WHERE [phone_number] IS NOT NULL"
  end

  def test_plugin_sql_schema_includes_organization_tables
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [
        BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true})
      ]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "organizations"'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "members"'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "invitations"'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "teams"'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "team_members"'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "organization_roles"'
    assert_includes sql, '"active_organization_id" text'
    assert_includes sql, '"active_team_id" text'
  end

  def test_plugin_tables_without_explicit_id_receive_primary_key_columns
    plugin = BetterAuth::Plugin.new(
      id: "idless-plugin",
      schema: {
        apiKey: {
          model_name: "api_keys",
          fields: {
            key: {type: "string", required: true, index: true},
            referenceId: {type: "string", required: true}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [plugin],
      rate_limit: {storage: "database"}
    )

    tables = BetterAuth::Schema.auth_tables(config)
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert tables.fetch("apiKey").fetch(:fields).key?("id")
    assert tables.fetch("rateLimit").fetch(:fields).key?("id")
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "api_keys"'
    assert_includes sql, '"id" text PRIMARY KEY NOT NULL'
    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "rate_limits"'
  end

  def test_foreign_keys_reference_physical_target_field_names
    plugin = BetterAuth::Plugin.new(
      id: "oauth-like",
      schema: {
        oauthClient: {
          model_name: "oauth_clients",
          fields: {
            clientId: {type: "string", required: true, unique: true}
          }
        },
        oauthToken: {
          model_name: "oauth_tokens",
          fields: {
            clientId: {type: "string", required: true, references: {model: "oauthClient", field: "clientId"}}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'FOREIGN KEY ("client_id") REFERENCES "oauth_clients" ("client_id") ON DELETE CASCADE'
  end

  def test_recommended_lookup_fields_are_indexed_when_tables_are_created
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [
        BetterAuth::Plugins.organization,
        BetterAuth::Plugins.two_factor
      ]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'UNIQUE ("email")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_accounts_on_user_id" ON "accounts" ("user_id")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_sessions_on_user_id" ON "sessions" ("user_id")'
    assert_includes sql, 'UNIQUE ("token")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_verifications_on_identifier" ON "verifications" ("identifier")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_invitations_on_email" ON "invitations" ("email")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_invitations_on_organization_id" ON "invitations" ("organization_id")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_members_on_user_id" ON "members" ("user_id")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_members_on_organization_id" ON "members" ("organization_id")'
    assert_includes sql, 'UNIQUE ("slug")'
    refute_includes sql, 'CREATE INDEX IF NOT EXISTS "index_organizations_on_slug" ON "organizations" ("slug")'
    assert_includes sql, 'CREATE INDEX IF NOT EXISTS "index_two_factors_on_secret" ON "two_factors" ("secret")'
  end

  def test_indexed_plugin_fields_use_create_index_statements
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [
        {
          id: "indexed",
          schema: {
            user: {
              fields: {
                externalId: {type: "string", required: false, index: true}
              }
            }
          }
        }
      ]
    )

    sqlite = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n").downcase
    postgres = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n").downcase

    assert_includes sqlite, "create index"
    assert_includes postgres, "create index"
    refute_includes sqlite, "add index"
    refute_includes postgres, "add index"
  end

  def test_plugin_tables_without_declared_id_get_core_id_column
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [
        {
          id: "plugin-id",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                action: {type: "string", required: true}
              }
            }
          }
        }
      ]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "audit_logs"'
    assert_includes sql, '"id" text PRIMARY KEY NOT NULL'
    assert_includes sql, '"action" text NOT NULL'
  end

  def test_unique_indexed_fields_emit_only_unique_index
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [
        {
          id: "unique-index",
          schema: {
            auditLog: {
              model_name: "audit_logs",
              fields: {
                action: {type: "string", required: true, unique: true, index: true}
              }
            }
          }
        }
      ]
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n")

    assert_includes sql, 'UNIQUE ("action")'
    refute_includes sql, 'CREATE INDEX IF NOT EXISTS "index_audit_logs_on_action"'
  end

  # Ruby CLI generates SQL only; upstream Prisma/Drizzle schema output is not ported here.

  def test_omitted_required_on_plugin_fields_stays_nullable_in_ruby
    plugin = BetterAuth::Plugin.new(
      id: "required-default",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            action: {type: "string"}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, '"action" text'
    refute_includes sql, '"action" text NOT NULL'
  end

  def test_explicit_required_true_adds_not_null
    plugin = BetterAuth::Plugin.new(
      id: "required-true",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            action: {type: "string", required: true}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, '"action" text NOT NULL'
  end

  def test_explicit_required_false_stays_nullable
    plugin = BetterAuth::Plugin.new(
      id: "required-false",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            action: {type: "string", required: false}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, '"action" text'
    refute_includes sql, '"action" text NOT NULL'
  end

  def test_json_and_array_field_types_map_per_dialect
    plugin = BetterAuth::Plugin.new(
      id: "typed-fields",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            metadata: {type: "json", required: false},
            tags: {type: "string[]", required: false},
            scores: {type: "number[]", required: false}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])

    postgres = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")
    mysql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).join("\n")
    mssql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mssql).join("\n")
    sqlite = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n")

    assert_includes postgres, '"metadata" jsonb'
    assert_includes postgres, '"tags" jsonb'
    assert_includes mysql, "`metadata` json"
    assert_includes mysql, "`tags` json"
    assert_includes mssql, "[metadata] varchar(8000)"
    assert_includes sqlite, '"metadata" text'
    assert_includes sqlite, '"tags" text'
  end

  def test_unsupported_field_type_raises_clear_error
    plugin = BetterAuth::Plugin.new(
      id: "bad-type",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            payload: {type: "object", required: false}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])

    error = assert_raises(BetterAuth::Error) do
      BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres)
    end
    assert_includes error.message, "Unsupported field type: object"
  end

  def test_string_defaults_are_sql_escaped
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      user: {
        additional_fields: {
          nickname: {type: "string", required: false, default_value: "O'Brien"}
        }
      }
    )

    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, "DEFAULT 'O''Brien'"
  end

  def test_boolean_and_numeric_defaults_render_per_dialect
    plugin = BetterAuth::Plugin.new(
      id: "defaults",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            active: {type: "boolean", required: false, default_value: true},
            count: {type: "number", required: false, default_value: 42}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, plugins: [plugin])

    postgres = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")
    mysql = BetterAuth::Schema::SQL.create_statements(config, dialect: :mysql).join("\n")
    sqlite = BetterAuth::Schema::SQL.create_statements(config, dialect: :sqlite).join("\n")

    assert_includes postgres, '"active" boolean DEFAULT true'
    assert_includes postgres, '"count" integer DEFAULT 42'
    assert_includes mysql, "`active` tinyint(1) DEFAULT 1"
    assert_includes mysql, "`count` integer DEFAULT 42"
    assert_includes sqlite, '"active" integer DEFAULT 1'
    assert_includes sqlite, '"count" integer DEFAULT 42'
  end

  # Enum array SQL types are not supported in Ruby schema generation yet; use string/json instead.

  def test_generate_id_option_does_not_change_sql_id_column_type
    serial_sql = BetterAuth::Schema::SQL.create_statements(
      BetterAuth::Configuration.new(secret: SECRET, database: :memory, advanced: {database: {generate_id: "serial"}}),
      dialect: :postgres
    ).join("\n")
    uuid_sql = BetterAuth::Schema::SQL.create_statements(
      BetterAuth::Configuration.new(secret: SECRET, database: :memory, advanced: {database: {generate_id: "uuid"}}),
      dialect: :postgres
    ).join("\n")

    assert_includes serial_sql, '"id" text PRIMARY KEY'
    assert_includes uuid_sql, '"id" text PRIMARY KEY'
  end

  def test_additional_fields_via_plugin_match_user_options_physical_columns
    via_options = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      user: {
        additional_fields: {
          department: {type: "string", required: false}
        }
      }
    )
    via_plugin = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [BetterAuth::Plugins.additional_fields(user: {department: {type: "string", required: false}})]
    )

    options_sql = BetterAuth::Schema::SQL.create_statements(via_options, dialect: :postgres).join("\n")
    plugin_sql = BetterAuth::Schema::SQL.create_statements(via_plugin, dialect: :postgres).join("\n")

    assert_includes options_sql, '"department" text'
    assert_includes plugin_sql, '"department" text'
  end

  def test_plugins_omitted_from_config_do_not_affect_generated_sql
    # Plugin class can be defined in the app but omitted from config plugins:
    BetterAuth::Plugin.new(
      id: "unused",
      schema: {
        auditLog: {
          model_name: "audit_logs",
          fields: {
            action: {type: "string", required: true}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    refute_includes sql, 'CREATE TABLE IF NOT EXISTS "audit_logs"'
  end

  def test_custom_plugin_foreign_keys_target_correct_tables
    same_model_plugin = BetterAuth::Plugin.new(
      id: "same-model-refs",
      schema: {
        parent: {
          model_name: "parents",
          fields: {
            ownerId: {type: "string", required: true, references: {model: "user", field: "id"}},
            managerId: {type: "string", required: true, references: {model: "user", field: "id"}}
          }
        }
      }
    )
    cross_model_plugin = BetterAuth::Plugin.new(
      id: "cross-model-refs",
      schema: {
        project: {
          model_name: "projects",
          fields: {
            ownerId: {type: "string", required: true, references: {model: "user", field: "id"}}
          }
        },
        task: {
          model_name: "tasks",
          fields: {
            projectId: {type: "string", required: true, references: {model: "project", field: "id"}},
            assigneeId: {type: "string", required: true, references: {model: "user", field: "id"}}
          }
        }
      }
    )
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [same_model_plugin, cross_model_plugin]
    )
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'FOREIGN KEY ("owner_id") REFERENCES "users" ("id")'
    assert_includes sql, 'FOREIGN KEY ("manager_id") REFERENCES "users" ("id")'
    assert_includes sql, 'FOREIGN KEY ("project_id") REFERENCES "projects" ("id")'
    assert_includes sql, 'FOREIGN KEY ("assignee_id") REFERENCES "users" ("id")'
  end

  def test_two_factor_and_username_plugins_generate_expected_tables
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      database: :memory,
      plugins: [BetterAuth::Plugins.two_factor, BetterAuth::Plugins.username]
    )
    sql = BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).join("\n")

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS "two_factors"'
    assert_includes sql, '"two_factor_enabled" boolean'
    assert_includes sql, '"username" text'
    assert_includes sql, 'FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE'
  end
end
