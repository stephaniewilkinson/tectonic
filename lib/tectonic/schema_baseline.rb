# frozen_string_literal: true

class Tectonic < Roda
  # Whether a database already carries the squashed baseline schema, and what to record
  # if it does.
  #
  # Migrations 001-024 were folded into a single 001, so a database migrated under the
  # old numbering records a version far above anything the directory can produce. Left
  # alone the migrator would try to roll it back, so such a database is stamped at the
  # baseline instead of migrated to it.
  #
  # The stamp is only safe when the schema really is the baseline, and that has to be
  # checked rather than assumed. Inferring it from the accounts table alone was wrong:
  # a database predating part of the baseline has accounts too, and stamping one skips
  # 001 entirely, leaving it recorded as migrated while the tables 001 creates are simply
  # missing. That happened to a development database and nothing raised at any point --
  # it read as version 5 with no oauth_applications and a legacy api_tokens still there.
  module SchemaBaseline
    # A table 001 creates, and one the old numbering dropped. Together they separate a
    # database carrying the baseline from one that stopped somewhere before it.
    PROOF_OF_BASELINE = :oauth_applications
    PROOF_OF_LEGACY = :api_tokens

    module_function

    # Whether there is anything here at all. An empty database is migrated normally.
    def populated?(db)
      db.table_exists?(:accounts)
    end

    # Whether what is here matches the schema the baseline produces.
    def carries_baseline?(db)
      db.table_exists?(PROOF_OF_BASELINE) && !db.table_exists?(PROOF_OF_LEGACY)
    end

    # Why a populated database cannot be adopted, or nil when it can. Said in terms of
    # what is actually wrong, because the answer is always "rebuild it" and an operator
    # deserves to know what they are rebuilding away from.
    def refusal(db)
      return if carries_baseline?(db)

      missing = "no #{PROOF_OF_BASELINE} table" unless db.table_exists?(PROOF_OF_BASELINE)
      legacy = "a legacy #{PROOF_OF_LEGACY} table" if db.table_exists?(PROOF_OF_LEGACY)
      "This database has accounts but not the baseline schema (#{[missing, legacy].compact.join(', ')}). " \
        'It predates the squashed migration and cannot be adopted; rebuild it with db:reset.'
    end

    # Whether a recorded version is one the current directory could have produced. Inside
    # the sequence it is left exactly as it is -- adopting on anything but the baseline
    # was harmless while the baseline was the only migration, and became a bug the moment
    # a second existed, replaying it on every run.
    def current?(recorded, baseline, latest)
      recorded&.between?(baseline, latest) || false
    end
  end
end

