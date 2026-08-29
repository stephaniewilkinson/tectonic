# frozen_string_literal: true

# A prescription can ask for an effort, not only a load. #265.
#
# `sets.rpe` records what a set *was*. Nothing on the prescription side said what it
# *should be*: program_lifts carried sets, reps, top_weight, percent_of_max, progression,
# measure, is_per_side, duration_seconds, is_weighted, is_main, note and position, and no
# way at all to write "top set at RPE 8". That is how autoregulated programming is
# expressed, and it is the more honest instruction exactly when a percentage is least
# reliable -- coming off a layoff, where a percentage of a max nobody has tested since is a
# guess wearing a decimal point.
#
# **Two columns, because a target that never reaches the gym floor is a note in a file.** A
# set row has no program_lift_id and never has; the generator copies the prescription onto
# the rows it writes, which is what planned_weight and planned_reps have been doing since
# 001. planned_rpe is the third of that set. Having all three on one row is what makes
# "what was asked for" and "what happened" comparable at all -- and that comparison, rather
# than the display, is the reason to do this: it is the missing half of the one dimension
# that is not weight or reps, and the one Progression could eventually autoregulate on.
#
# **Where a target may sit** is #211's rule for sets.rpe, said again on both columns. RPE is
# reps in reserve -- an 8 says two more were there -- so a held position has no reps for any
# to be in reserve of, and a warmup is submaximal by definition and would be answering a
# question nobody asked.
#
# program_lifts has no is_warmup to constrain against: a lift prescribes its working sets
# and the ramp above them is computed by Warmup rather than written, so its constraint is
# the measure half alone. The generator declines to copy a target onto a ramp row, and the
# sets constraint is what holds it to that.
#
# **is_weighted is on the program_lifts rule and not on the sets one**, which is the one
# asymmetry here and is deliberate. #278 decided the session screen does not ask for a
# rating on work carrying no external load: press-ups are as hard as your last set of
# press-ups made them, and the answer moves nothing the app can act on. A target on such a
# lift would therefore print an instruction with no buttons under it to answer -- a
# prescription the editor accepted and the app then silently swallowed. Refusing it here
# costs nothing, because the column is new and no row can be holding one yet.
#
# The sets constraint deliberately does *not* gain that clause. lib/tectonic/sets.rb sets
# out at length why sets_rpe_only_on_working_reps stays wider than the screen's own rule --
# it enforces the two rules that are about meaning, and narrowing it to weight as well would
# be a migration that clears ratings somebody did record. planned_rpe is written only by the
# generator, which reads the program_lifts rule above, so the narrower rule is already in
# force where it matters without a second column having to restate it.
#
# **The range is the part that differs from sets.rpe.** 004 added that column as a bare
# Integer and 015 constrained only where it may sit, so this database will accept a rating
# of 80 today; what stops one is Bounds::RPE on the MCP side and five buttons on the screen.
# A target has neither guard behind it -- it is typed into a box on the block editor by
# somebody with no scale in front of them -- and a nonsense one is not one bad row: the
# generator copies it onto every working set of every week the block generates.
#
# 1 to 10 rather than the 6 to 10 the session screen offers. Those five buttons are a
# decision about which part of the scale is worth a thumb on a phone with chalk on, not a
# claim that RPE 5 is not a number: speed work and deload weeks are written at 5 and 6, and
# a column refusing a 5 would make a real prescription unwritable while sets.rpe cheerfully
# stored the answer to it.
#
# Nothing is cleaned up first and nothing is deleted, unlike 015. Both columns are new and
# nullable, so no existing row can fail either constraint. `down` loses targets written
# after this ran and cannot do otherwise.
Sequel.migration do
  up do
    alter_table(:program_lifts) do
      add_column :target_rpe, Integer
      add_constraint(:program_lifts_target_rpe_on_working_reps) do
        Sequel.lit("target_rpe IS NULL OR (target_rpe BETWEEN 1 AND 10 AND measure = 'reps' AND is_weighted)")
      end
    end
    alter_table(:sets) do
      add_column :planned_rpe, Integer
      add_constraint(:sets_planned_rpe_only_on_working_reps) do
        Sequel.lit("planned_rpe IS NULL OR (planned_rpe BETWEEN 1 AND 10 AND measure = 'reps' AND is_warmup = false)")
      end
    end
  end

  down do
    alter_table(:sets) do
      drop_constraint(:sets_planned_rpe_only_on_working_reps)
      drop_column :planned_rpe
    end
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_target_rpe_on_working_reps)
      drop_column :target_rpe
    end
  end
end

