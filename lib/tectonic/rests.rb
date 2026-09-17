# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # How long one lifter rests on one movement, so the bell has a length to ring at. #456.
  #
  # 037 put this on `exercises` and 039 moved it here, for the reason 020 moved the training
  # max: a library movement has a null account_id and sits on every account's page, so a column
  # there is one lifter's answer on everybody's screen -- and `Exercise.owned_by` refuses the
  # edit outright, which made the answer unsayable for the nine barbell movements the reporting
  # account trains. Two of the three main lifts, which is where three minutes actually matters.
  #
  # Keyed on the pair, a shared Back Squat carries a different rest for every account that
  # lifts it, and the bell is consented to by the person it rings at.
  #
  # Read rather than copied onto sets, which 037 got right and is kept: `rest_suggestion`
  # consults this when a set carries no prescription of its own, so naming a rest reaches every
  # session already written without regenerating anything. Copying would fix only sessions
  # written afterwards, which is the wrong half. The precedence stays readable in one place --
  # the block's own rest, then the lifter's for that movement, then nothing.
  module Rest
    # The same bound as Bounds::REST and the check constraint behind this table, because the
    # three describe one quantity and a bound that differed between them is one somebody
    # eventually crosses.
    SECONDS = (5..1800)

    module_function

    # What this lifter rests on this movement, or nil where they have not said. Nil is the
    # ordinary answer and has to stay one: most movements want no bell.
    def for(account_id:, exercise_id:)
      DB[:account_exercise_rests].where(account_id:, exercise_id:).get(:seconds)
    end

    # Every rest this account holds, keyed by movement, for the reads that want them all at
    # once -- a session screen pricing a dozen set rows, and the movement list drawing a column
    # of them. One query rather than one per row, which is Goal.all_for's argument exactly.
    def all_for(account_id)
      DB[:account_exercise_rests].where(account_id:).to_h { |row| [row[:exercise_id], row[:seconds]] }
    end

    # Saves what a lifter named, or clears it where they named nothing.
    #
    # Out of range clears rather than clamping, which is `Exercise.clean_rest_seconds`'s rule
    # and its reasoning: clamping 9000 to 1800 would store a number nobody typed and then ring
    # at them for half an hour of it. Refusing to record a nonsense rest is the smaller lie
    # than inventing a sensible one.
    #
    # Blank clears, because that is the way back from having named a rest -- without it the
    # answer would be unsayable once said, which is the trap #369's handle weight names.
    def replace(account_id, exercise_id, raw)
      seconds = clean(raw)
      return clear(account_id, exercise_id) unless seconds

      DB[:account_exercise_rests]
        .insert_conflict(target: %i[account_id exercise_id],
                         update: { seconds:, set_at: Sequel::CURRENT_TIMESTAMP })
        .insert(account_id:, exercise_id:, seconds:)
    end

    def clear(account_id, exercise_id)
      DB[:account_exercise_rests].where(account_id:, exercise_id:).delete
    end

    # A length or nothing. Kept here rather than left on Exercise now that the column is gone,
    # so the form, the MCP tool and any future caller land on one rule.
    def clean(raw)
      seconds = raw.to_s.strip
      return nil if seconds.empty?

      SECONDS.cover?(seconds.to_i) ? seconds.to_i : nil
    end
  end
end

