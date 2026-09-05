# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'

class Tectonic < Roda
  # Folding one movement into another, and everything that owes. #267 asked for this and
  # #367 is why it is a file rather than eight lines in the Rakefile.
  #
  # The original moved two tables -- `sets` and `program_lifts` -- and then deleted the row.
  # That was every table pointing at an exercise when it was written. Three migrations later
  # there are six, and the four it does not name are what turns a tidy-up into data loss:
  #
  #   * `account_training_maxes`, `account_goals` and `account_training_max_statements` are
  #     all ON DELETE CASCADE (020, 025). So the final delete does not fail -- it succeeds,
  #     and takes the stated training max, the goal, and the entire log of maxes ever stated
  #     for the movement with it. A merge advertising that no set is lost was silently
  #     destroying the number every percentage in a block is taken of.
  #   * `program_lifts.percent_of_exercise_id` (023) has no cascade, so a block priced off
  #     the folded movement fails the delete and rolls the whole transaction back instead.
  #     Loud rather than silent, and still a merge that can never complete.
  #
  # Both halves are the same mistake: a list of tables written once, by hand, with nothing
  # holding it to the schema. It is still written by hand here -- Sequel can be asked for the
  # foreign keys, but what a merge owes each table is not derivable from the constraint, as
  # the two groups below show -- so the answer is to name all six in one place, beside the
  # reason each is in the group it is in.
  #
  # Nothing here decides *which* movement absorbs which. That is the caller's, and rightly:
  # a bare "Squat" is Back Squat for one lifter and Low-Bar for the next, and the app has no
  # way to know. See `sole_exercise` in the Rakefile for why the match is exact.
  module ExerciseMerge
    module_function

    # Columns that merely name a movement, on rows with nothing unique about them, so every
    # row moves and no two can collide.
    #
    # `percent_of_exercise_id` is #295's reference -- the movement a lift is *priced off*,
    # which is not the movement it prescribes -- and it has to move for the reason the rest
    # do: a percentage taken of a row that no longer exists is a lift that cannot generate.
    #
    # The statement log is here rather than below because it is append-only and deliberately
    # repetitive: a lifter who restates 315 as 325 has said two things, and `TrainingMax.as_of`
    # reads the pair back to say what a block in March opened at. There is no unique index on
    # it for that reason, so the whole log moves and stays readable afterwards.
    REPOINTED = [
      %i[sets exercise_id],
      %i[program_lifts exercise_id],
      %i[program_lifts percent_of_exercise_id],
      %i[account_training_max_statements exercise_id]
    ].freeze

    # The two tables holding one row per account per movement, each with a UNIQUE on the
    # pair, so folding can put two rows where only one is allowed. Named with the column that
    # dates them, because that is what decides which of the two survives.
    FOLDED = { account_training_maxes: :stated_at, account_goals: :set_at }.freeze

    # Moves everything pointing at `from` onto `into`, then deletes `from`. One transaction:
    # a half-applied merge would leave training on one row and the max it is generated
    # against on another, which is worse than either outcome whole.
    def fold(from, into)
      DB.transaction do
        REPOINTED.each { |table, column| DB[table].where(column => from.id).update(column => into.id) }
        FOLDED.each { |table, dated| fold_standing(table, dated, from, into) }
        from.delete
      end
    end

    # One row per account per movement, moved without tripping the unique index on the pair.
    #
    # Where the account has said nothing about the movement being folded into, the row simply
    # moves. Where it has said something about both, the two are one question answered twice
    # and the later answer is the one in force -- the same rule `TrainingMax.as_of` reads the
    # statement log by, so the surviving row and the log it is derived from cannot end up
    # disagreeing about which number is current. The superseded row is deleted rather than
    # left to collide.
    #
    # Ties go to the row already on the surviving movement. Two statements sharing a timestamp
    # to the microsecond are a seeded fixture rather than a lifter changing their mind twice,
    # and preferring the destination keeps the merge from moving anything on no evidence.
    def fold_standing(table, dated, from, into)
      DB[table].where(exercise_id: from.id).each do |row|
        standing = DB[table].where(account_id: row[:account_id], exercise_id: into.id).first
        supersede(table, row, standing, dated, into)
      end
    end

    # The resolution itself: keep one row, drop the other, and leave the survivor on the
    # movement that absorbed the merge.
    def supersede(table, row, standing, dated, into)
      return DB[table].where(id: row[:id]).delete if standing && standing[dated] >= row[dated]

      DB[table].where(id: standing[:id]).delete if standing
      DB[table].where(id: row[:id]).update(exercise_id: into.id)
    end

    # What a merge would carry, per table, for the dry run to print. Zeroes are dropped so a
    # movement with nothing but sets on it reports one line rather than six, and the tables
    # #367 added are counted alongside the two #267 knew about -- a dry run that listed only
    # sets and lifts is exactly how the cascade stayed invisible.
    def tally(from)
      COUNTED.filter_map do |(table, column), noun|
        count = DB[table].where(column => from.id).count
        "#{count} #{noun}" unless count.zero?
      end
    end

    # Every column in REPOINTED and FOLDED, with the words a person reads it back in.
    COUNTED = {
      %i[sets exercise_id] => 'set(s)',
      %i[program_lifts exercise_id] => 'prescribed lift(s)',
      %i[program_lifts percent_of_exercise_id] => 'lift(s) priced off it',
      %i[account_training_maxes exercise_id] => 'stated training max(es)',
      %i[account_goals exercise_id] => 'goal(s)',
      %i[account_training_max_statements exercise_id] => 'training max statement(s)'
    }.freeze
  end
end

