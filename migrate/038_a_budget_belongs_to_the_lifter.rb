# frozen_string_literal: true

# How long a session should take, on the account rather than only on the block. #446.
#
# `programs.time_budget_minutes` has existed since 032 and **not one block has ever carried
# one**. `create_program` accepts it, `update_program` accepts it, `generate_program_week`
# warns when a day runs past it, and `SessionLength.against` does the comparison -- a whole
# feature, built, and never once run. The deadlift day that came out at 29 sets across four
# movements was never flagged, not because nothing checks but because there was no cap to
# check against.
#
# ## The column was on the wrong object
#
# The first reading was that the block editor removed in #411 took the only way to set it. That
# is not quite right, and #458 is why: it does not ask for no interface, it asks for no *CRUD*
# interface, and it names the exception exactly -- "one number per movement and one editable
# field, not a CRUD interface".
#
# So the question is not "where is the screen" but "whose fact is this". Everything else on
# `programs` is a programming decision that belongs to its block and changes between blocks:
# `preferred_reps`, `is_ascending`, `block`, `start_date`. A time budget is not one of those.
# "I have an hour to train" is a fact about a lifter's week. It will be the same next block and
# the one after, and asking again every time a block is written is how it comes to be asked
# never.
#
# `accounts` already holds exactly this kind of fact -- `bar_weight`, `week_starts_on`,
# `time_zone`, `dumbbell_handle_weight` -- each one field on the settings page, no CRUD, and
# each one answered once.
#
# ## The block can still override
#
# This is a default and not a replacement, so the column on `programs` stays and wins where it
# is set. A peaking block really can be longer than an ordinary week, and that is a fact about
# that block. What changes is that a block saying nothing now inherits an answer instead of
# disabling the check.
#
# ## Why not do this by asking assistants harder
#
# That was the fix for #456's half of the same pattern, and it is weaker than it looks: it
# depends on a model reading a description and choosing to act, every time, forever. A field on
# the settings page is answered once by the person whose hour it is.
#
# 10 to 300 matches `Bounds::BUDGET_MINUTES`, because the two describe the same quantity and a
# bound that differed between them is a bound somebody eventually crosses. Nullable, and null
# is the ordinary case: an account that has not said keeps exactly the behaviour it has now,
# which is no warning.
Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :time_budget_minutes, Integer
      add_constraint(:accounts_time_budget_minutes_in_range) do
        Sequel.lit('time_budget_minutes IS NULL OR (time_budget_minutes >= 10 AND time_budget_minutes <= 300)')
      end
    end
  end

  down do
    alter_table(:accounts) do
      drop_constraint(:accounts_time_budget_minutes_in_range)
      drop_column :time_budget_minutes
    end
  end
end

