# frozen_string_literal: true

# A rep can be done under commands, and now there is somewhere to say so. #311.
#
# At a meet the bench press is not one movement, it is three instructions: start, press,
# rack. The bar is held at the chest until somebody says otherwise, and a lift that was
# there the whole time gets three red lights for the timing of it. That is a trainable
# thing and this app had nowhere to record it.
#
# The only way to record it until now was in the movement's name -- a separate "Paused
# Bench Press" exercise -- and that has two costs. It splits the history, so
# `exercise_history` for Bench Press cannot see the commanded work and the estimated max
# is computed off half the evidence. And it cannot express a *set* done under commands
# inside an otherwise ordinary lift, which is how almost everybody actually trains it:
# the top single is commanded and the back-offs are not.
#
# **Commanded, not paused, and the word gets chosen once.** They are not the same thing. A
# pause is a tempo -- you hold the bar still for a beat because the programme said to --
# and it is something the lifter decides to do. A command is a rule imposed from outside:
# the hold lasts as long as the referee makes it last, which is the part that is hard and
# the part the misses were about. "Paused" is also already spoken for in this database:
# the library ships Paused Bench Press, Paused Deadlift and Tempo Squat as movements, and a
# flag meaning nearly-but-not-quite what three existing rows mean would make "how many
# commanded reps did this block contain" answerable two ways that disagree.
#
# **Two columns, for 019's reason and 029's.** A set row has no program_lift_id and never
# has; the generator copies the prescription onto the rows it writes. So a block can
# prescribe commands, and a session generated on Monday keeps them when the block is edited
# on Wednesday.
#
# **Not null with a default of false, unlike the planned_ columns beside it.** Those are
# nullable because absent means something there -- no target was prescribed, which is
# different from a target of zero. There is no third state here: a set was done under
# commands or it was not, and every set already in the table was not. This is 009's shape
# for is_per_side rather than 019's for target_rpe, and it is the right one because the
# fact is a boolean rather than an optional number.
#
# **The rule is `measure = 'reps'`, and it is the whole rule.** Commands bracket a rep --
# they say when it starts and when it is over -- so a movement held for time has no rep for
# them to bracket. A 60 second plank done under commands is not a thing that happens.
#
# What the rule deliberately does *not* say:
#
# **Nothing about load.** The obvious extra clause is that a commanded lift is a loaded
# one, and it is true of every meet there has ever been. It is left out because of where
# the failure would land: `weight` is editable, so a set recorded as commanded and later
# corrected to carry no load would violate the constraint on save -- an unrescued exception,
# which is a 500 page and a lost edit on the session screen. That is #213's shape exactly,
# and buying a guard against a prescription nobody would write with a 500 on an edit
# somebody might make is a bad trade. The same argument keeps `is_weighted` off the
# program_lifts constraint, where flipping that flag on an existing commanded lift would
# fail the same way inside update_program_lift.
#
# **Nothing about warmups.** 019 and 029 both exclude them and are right to: a ramp is
# computed rather than written, so a target RPE or a prescribed rest on one is an
# instruction nobody can follow. Commands are not like that. Practising the start command
# on the last heavy single before openers is real meet preparation and is a warmup by every
# definition this app has. The generator still declines to write commands onto a ramp,
# because a ramp is not what the block prescribed -- but that is the generator choosing,
# not the database refusing, and a lifter ticking the box on their own warmup single is
# recording something true.
#
# Both columns are new and false everywhere, so no existing row can fail either constraint.
# `down` loses what was recorded after this ran and cannot do otherwise.
Sequel.migration do
  up do
    alter_table(:program_lifts) do
      add_column :is_commanded, TrueClass, null: false, default: false
      add_constraint(:program_lifts_commanded_reps_are_counted) do
        Sequel.lit("is_commanded = false OR measure = 'reps'")
      end
    end
    alter_table(:sets) do
      add_column :is_commanded, TrueClass, null: false, default: false
      add_constraint(:sets_commanded_reps_are_counted) do
        Sequel.lit("is_commanded = false OR measure = 'reps'")
      end
    end
  end

  down do
    alter_table(:sets) do
      drop_constraint(:sets_commanded_reps_are_counted)
      drop_column :is_commanded
    end
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_commanded_reps_are_counted)
      drop_column :is_commanded
    end
  end
end

