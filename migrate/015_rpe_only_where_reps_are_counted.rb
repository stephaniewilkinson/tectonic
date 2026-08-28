# frozen_string_literal: true

# An RPE belongs only on a working set counted in reps. #211.
#
# RPE is reps in reserve: an 8 says two more were there. A 60 second plank has no reps for
# any to be in reserve of, and the scale the app shows is written entirely in rep counts --
# "4+", "3", "2", "1", "0" -- so on a timed set it explained a measure that could not be
# applied to it. A warmup is submaximal by definition, so its rating is a number nobody
# reads back.
#
# The session screen already declined to ask for a rating on a warmup, but only by which
# list the row was rendered in, and it asked for one on every timed working set. Nothing
# anywhere refused a rating written through MCP. So the rule existed in one view and was
# absent from every write path, which is the gap this closes: a constraint is the one place
# that cannot be forgotten by a caller.
#
# The tidy-up runs first and has to. A constraint is validated against every existing row,
# so any rating already sitting on a warmup or a timed set would refuse the migration
# itself. Those numbers describe a scale that was never applicable to the rows holding
# them, which is why they are cleared rather than migrated somewhere.
#
# **This deletes data**: ratings on warmups and on timed sets are set to null and the down
# migration cannot bring them back -- it drops the constraint, and nulls stay null. Ratings
# on working sets counted in reps, which is the great majority and the only ones that ever
# meant anything, are untouched.
Sequel.migration do
  up do
    from(:sets).where(Sequel.|({ is_warmup: true }, { measure: 'time' })).update(rpe: nil)
    alter_table(:sets) do
      add_constraint(:sets_rpe_only_on_working_reps) do
        Sequel.lit("rpe IS NULL OR (measure = 'reps' AND is_warmup = false)")
      end
    end
  end

  down do
    alter_table(:sets) { drop_constraint(:sets_rpe_only_on_working_reps) }
  end
end

