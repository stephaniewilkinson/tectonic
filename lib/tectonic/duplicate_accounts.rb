# frozen_string_literal: true

class Tectonic < Roda
  # Which of two accounts sharing an address is the account, and which is a row nobody
  # can reach. #345.
  #
  # Nothing enforced uniqueness on `accounts.email`, so the same address could sign up
  # twice. Migration 027 adds the index that stops it, and cannot add it while duplicates
  # are still there -- so something has to decide what happens to them first.
  #
  # 027 originally refused outright on any duplicate at all, on the reasoning that one of
  # the two rows owns training somebody did and which one survives is a question about a
  # person rather than about data. That reasoning is still right, and it is why the refusal
  # below is kept. What it got wrong was assuming the premise always holds: run against the
  # production database it names eleven addresses, and twenty-one of those twenty-two rows
  # own nothing anywhere in the schema -- no sets, no programs, no exercises, no training
  # maxes, no goals, no plates, no grants, no audit rows. There was no question about a
  # person to answer. The deploy was stopped on a pair of empty rows.
  #
  # So the rule is narrowed to the case it was written for. An account that owns nothing is
  # not somebody's training, it is a failed second sign-up, and deleting it costs nobody
  # anything. An account that owns something is never touched. Two that both own something
  # is the genuinely ambiguous case, and that still stops the deploy and names the address.
  #
  # Ownership is asked of the database rather than listed here, because listing it is how
  # this goes wrong quietly: `account_remember_keys` refers to an account through its `id`
  # column rather than `account_id`, and a hand-written list is one rename away from calling
  # a row empty because it looked in the wrong place. See `owned_ids` below.
  module DuplicateAccounts
    module_function

    # Every table referring to `accounts`, paired with the column that does the referring,
    # read out of the catalog rather than written down. The catalog already knows the whole
    # set and knows which column carries it, and it stays right as the schema moves.
    def references(db)
      db.fetch(<<~SQL).map { |row| [row[:table_name].to_sym, row[:column_name].to_sym] }
        SELECT c.conrelid::regclass::text AS table_name, a.attname::text AS column_name
          FROM pg_constraint c
          JOIN unnest(c.conkey) AS k(attnum) ON true
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
         WHERE c.confrelid = 'accounts'::regclass AND c.contype = 'f'
      SQL
    end

    # Which of the given accounts own anything at all. A row in any referring table is
    # ownership. There is no need to reach past the direct references -- `sets` hang off
    # `workouts` rather than off an account, so an account with sets has the workout that
    # holds them and is already caught by that.
    def owned_ids(db, ids)
      return [] if ids.empty?

      references(db).flat_map { |table, column| db[table].where(column => ids).select_map(column) }.uniq
    end

    # The addresses carrying more than one account.
    def duplicated_emails(db)
      db[:accounts].select_group(:email).having { count.function.* > 1 }.select_map(:email)
    end

    # The duplicated addresses, each with its rows and whether each row owns anything --
    # the picture `plan` decides from.
    def duplicates(db)
      rows = db[:accounts].where(email: duplicated_emails(db)).select_map(%i[email id])
      return {} if rows.empty?

      owned = owned_ids(db, rows.map(&:last))
      rows.group_by(&:first).transform_values do |pairs|
        pairs.map { |(_email, id)| { id:, owns: owned.include?(id) } }
      end
    end

    # The rows to delete for one address, given `[{id:, owns:}]`, or nil when the address
    # cannot be resolved without a person deciding.
    #
    # Where nothing is owned the survivor is the lowest id, which is the oldest row. That is
    # a choice rather than a preservation: the login lookup is Rodauth's default and carries
    # no ORDER BY, so which of the two a password reaches today is whatever Postgres happens
    # to hand back first, and is not guaranteed to be stable anyway.
    def deletable(rows)
      owners = rows.select { |row| row[:owns] }
      return if owners.length > 1

      survivor = owners.first || rows.min_by { |row| row[:id] }
      rows.reject { |row| row[:id] == survivor[:id] }.map { |row| row[:id] }
    end

    # The whole plan for `{email => [{id:, owns:}]}`: the ids that can go, and the addresses
    # that cannot be settled here. Both are returned rather than raising on the first
    # unresolved address, so a refusal names every address needing a decision and an operator
    # resolves them in one pass instead of discovering the next one on the next deploy.
    def plan(accounts_by_email)
      deletions = []
      unresolved = []
      accounts_by_email.each do |email, rows|
        ids = deletable(rows)
        ids ? deletions.concat(ids) : unresolved << email
      end
      [deletions, unresolved]
    end

    # Why the migration is stopping, or nil when it is not. Deliberately louder than a
    # migration that quietly picked a winner: a failed deploy is noticed, and the alternative
    # is discovering months later that a session went somewhere unreachable.
    def refusal(unresolved)
      return if unresolved.empty?

      "These addresses have more than one account owning training: #{unresolved.sort.join(', ')}. " \
        'Each has to be resolved by hand before email can be made unique, because both rows ' \
        'hold work somebody did and which one survives is a question about a person rather ' \
        'than about data. Merge or remove them, then run this again.'
    end
  end
end

