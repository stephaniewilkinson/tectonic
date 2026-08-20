# frozen_string_literal: true

# The whole schema, as one baseline. This replaces migrations 001-024, which had
# accumulated a permanently missing 015 that the migrator was told to tolerate --
# meaning a genuinely lost migration would have gone unnoticed.
#
# One deliberate difference from what those migrations produced. `accounts.created_on`,
# `workouts.date`, and `workouts.created_on` were declared `default: Time.now.utc`, which
# Sequel evaluates when the migration runs and freezes into the column as a literal.
# Every database therefore carried a different default, fixed to whenever it happened to
# be migrated, and a row inserted without a date got that long-past instant rather than
# today. They use CURRENT_TIMESTAMP here, which is what the declaration was reaching for
# and what makes this file produce the same schema everywhere.
#
# The tables are grouped only to keep each definition readable; they run in the order
# called below, which is the order the foreign keys require.
# The optional metadata dynamic client registration (RFC 7591) records, all free-form
# strings rodauth-oauth stores verbatim.
SCHEMA_REGISTRATION_METADATA = %i[
  description homepage_url registration_access_token token_endpoint_auth_method
  grant_types response_types client_uri logo_uri tos_uri policy_uri jwks_uri jwks
  contacts software_id software_version
].freeze

SCHEMA_ACCOUNTS = lambda do |db|
  db.create_table(:accounts) do
    primary_key :id
    File :profile_picture
    String :email, null: false
    String :password_hash, null: false
    Time :created_on, null: false, default: Sequel::CURRENT_TIMESTAMP
  end
end

# Rodauth's remember-me keys: one row per account, keyed by the account itself.
SCHEMA_REMEMBER_KEYS = lambda do |db|
  db.create_table(:account_remember_keys) do
    foreign_key :id, :accounts, primary_key: true, type: :Bignum
    String :key, null: false
    DateTime :deadline, null: false,
                        default: Sequel.date_add(Sequel::CURRENT_TIMESTAMP, days: 14)
  end
end

# An OAuth client. rodauth-oauth owns this table's shape.
SCHEMA_OAUTH_APPLICATIONS = lambda do |db|
  db.create_table(:oauth_applications) do
    primary_key :id
    foreign_key :account_id, :accounts
    String :name, null: false
    String :redirect_uri
    String :scopes, null: false
    String :client_id, null: false
    String :client_secret, null: false
    Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    SCHEMA_REGISTRATION_METADATA.each { |column| String column }

    index :client_id, unique: true
    index :client_secret, unique: true
  end
end

# One authorization grant: the code, then the tokens it was exchanged for. `resource`
# binds it to the MCP audience (RFC 8707) and the code_challenge columns carry PKCE.
SCHEMA_OAUTH_GRANTS = lambda do |db|
  db.create_table(:oauth_grants) do
    primary_key :id
    foreign_key :account_id, :accounts
    foreign_key :oauth_application_id, :oauth_applications
    String :type
    String :code
    String :token
    String :refresh_token
    DateTime :expires_in, null: false
    String :redirect_uri
    DateTime :revoked_at
    String :scopes, null: false
    DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    String :access_type, null: false, default: 'offline'
    String :code_challenge
    String :code_challenge_method
    String :resource

    index %i[oauth_application_id code], unique: true
    index :token, unique: true
    index :refresh_token, unique: true
  end
end
# A movement. A null account_id marks a shared library row every account can see,
# which is why the name is unique only among those.
SCHEMA_EXERCISES = lambda do |db|
  db.create_table(:exercises) do
    primary_key :id
    foreign_key :account_id, :accounts
    String :name, null: false
    String :icon_url
    Time :created_at, default: Sequel::CURRENT_TIMESTAMP
    foreign_key :created_by_oauth_application_id, :oauth_applications

    index :name, unique: true, where: { account_id: nil }, name: :exercises_library_name_key
  end
end

SCHEMA_WORKOUTS = lambda do |db|
  db.create_table(:workouts) do
    primary_key :id
    foreign_key :account_id, :accounts, null: false
    File :photo
    Time :date, null: false, default: Sequel::CURRENT_TIMESTAMP
    Time :created_on, null: false, default: Sequel::CURRENT_TIMESTAMP
    Integer :rpe
    Time :created_at, default: Sequel::CURRENT_TIMESTAMP
    foreign_key :created_by_oauth_application_id, :oauth_applications
  end
end

# planned_weight/planned_reps keep what the program prescribed, so a set lifted
# differently from the plan can still be told apart from one entered by hand.
SCHEMA_SETS = lambda do |db|
  db.create_table(:sets) do
    primary_key :id
    foreign_key :exercise_id, :exercises, null: false
    foreign_key :workout_id, :workouts, null: false
    TrueClass :is_completed, default: false
    TrueClass :is_warmup, null: false, default: false
    Integer :reps, null: false
    Integer :weight, null: false
    Integer :planned_weight
    Integer :planned_reps
    TrueClass :is_barbell, null: false, default: false
    Time :created_at, default: Sequel::CURRENT_TIMESTAMP
    foreign_key :created_by_oauth_application_id, :oauth_applications
  end
end
SCHEMA_PROGRAMS = lambda do |db|
  db.create_table(:programs) do
    primary_key :id
    foreign_key :account_id, :accounts, null: false
    String :name, null: false
    Integer :block
    Integer :week
    String :notes
    Integer :preferred_reps
    TrueClass :is_ascending, null: false, default: true
  end
end

SCHEMA_PROGRAM_DAYS = lambda do |db|
  db.create_table(:program_days) do
    primary_key :id
    foreign_key :program_id, :programs, null: false
    Integer :weekday, null: false
    String :focus
  end
end

SCHEMA_PROGRAM_LIFTS = lambda do |db|
  db.create_table(:program_lifts) do
    primary_key :id
    foreign_key :program_day_id, :program_days, null: false
    foreign_key :exercise_id, :exercises, null: false
    Integer :position, null: false, default: 0
    Integer :sets, null: false
    Integer :reps, null: false
    Integer :top_weight, null: false
    TrueClass :is_barbell, null: false, default: false
    TrueClass :is_main, null: false, default: false
    String :note
  end
end

# Every MCP tool call an assistant makes, so a bad session can be reconstructed.
SCHEMA_MCP_AUDIT_LOG = lambda do |db|
  db.create_table(:mcp_audit_log) do
    primary_key :id
    foreign_key :account_id, :accounts, null: false
    String :tool_name, null: false
    jsonb :arguments, null: false, default: Sequel.pg_jsonb({})
    String :result_status, null: false
    String :error_message
    Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    foreign_key :oauth_application_id, :oauth_applications

    index :account_id
  end
end
Sequel.migration do
  # Explicit up/down rather than `change`: the table definitions are reached through
  # constants, and the migrator cannot infer the reverse of a call it cannot see into.
  up do
    SCHEMA_ACCOUNTS.call(self)
    SCHEMA_REMEMBER_KEYS.call(self)
    SCHEMA_OAUTH_APPLICATIONS.call(self)
    SCHEMA_OAUTH_GRANTS.call(self)
    SCHEMA_EXERCISES.call(self)
    SCHEMA_WORKOUTS.call(self)
    SCHEMA_SETS.call(self)
    SCHEMA_PROGRAMS.call(self)
    SCHEMA_PROGRAM_DAYS.call(self)
    SCHEMA_PROGRAM_LIFTS.call(self)
    SCHEMA_MCP_AUDIT_LOG.call(self)
  end

  # Dropped in reverse dependency order, so no foreign key outlives what it points at.
  down do
    drop_table(:mcp_audit_log, :program_lifts, :program_days, :programs, :sets,
               :workouts, :exercises, :oauth_grants, :oauth_applications,
               :account_remember_keys, :accounts)
  end
end

