# frozen_string_literal: true

# A prescription can ask for a rest, and the timer counts that rather than an average. #281.
#
# The rest timer shipped suggesting the median of this lifter's own turnarounds on the
# movement, which is a measurement and was the honest thing to offer while there was nothing
# else. It is not what a programme asks for. A block writing five singles at 90% means five
# minutes between them, and defaulting that to whatever the lifter happened to average --
# including the sessions where they rushed it -- makes the timer describe the habit instead
# of the instruction.
#
# So the prescription leads, and the measurement is the fallback for a lift that has none.
#
# **Two columns, for 019's reason exactly.** A set row has no program_lift_id and never has;
# the generator copies the prescription onto the rows it writes, which is what planned_weight,
# planned_reps and planned_rpe already do. planned_rest_seconds is the fourth of that set, and
# having it on the row is what lets a session generated on Monday keep the rest it was
# generated with when the block is edited on Wednesday.
#
# **Where a prescribed rest may sit is a wider rule than 019's, and deliberately.** A target
# RPE belongs only on a loaded lift counted in reps -- RPE is reps in reserve, so a held
# position has none and unloaded work moves nothing the app can act on. None of that is true
# of rest. A plank has a rest between holds, press-ups have one, and a lift counted in seconds
# has one; rest is the one prescription that means the same thing whatever the movement is. So
# there is no measure clause and no is_weighted clause here, and their absence is the point
# rather than an omission.
#
# **Warmups are excluded, and that is 019's rule kept.** A lift prescribes its working sets;
# the ramp above them is computed by Warmup rather than written. Three minutes between heavy
# squat singles is not three minutes between the 95lb and 135lb rungs, so copying the
# prescription onto a ramp row would put a plainly wrong instruction on the screen. A warmup
# falls back to the measured turnaround, which is the right number for it and is what the
# lifter's own ramps actually took.
#
# **The range is 5 to 1800 seconds.** The upper bound is half an hour, which is past any real
# prescription -- five to eight minutes is the outer edge of a heavy single, and nothing asks
# for twenty -- and well past LONG_GAP_SECONDS, the twenty minutes beyond which Timing stops
# counting a gap as training at all. That asymmetry is intended: a prescription is a thing
# somebody wrote down, so it may exceed what the app is willing to infer from silence. The
# lower bound is five seconds, which admits the short rests of rest-pause and drop-set work
# while refusing a zero, since a rest of no time is not a rest and would arm a timer that
# fires the instant it starts.
#
# A bad value here is not one bad row: the generator copies it onto every working set of every
# week the block generates, which is 019's argument for bounding target_rpe in the schema and
# applies unchanged.
#
# Both columns are new and nullable, so no existing row can fail either constraint. `down`
# loses prescriptions written after this ran and cannot do otherwise.
Sequel.migration do
  up do
    alter_table(:program_lifts) do
      add_column :rest_seconds, Integer
      add_constraint(:program_lifts_rest_seconds_in_range) do
        Sequel.lit('rest_seconds IS NULL OR rest_seconds BETWEEN 5 AND 1800')
      end
    end
    alter_table(:sets) do
      add_column :planned_rest_seconds, Integer
      add_constraint(:sets_planned_rest_seconds_off_warmups) do
        Sequel.lit('planned_rest_seconds IS NULL OR ' \
                   '(planned_rest_seconds BETWEEN 5 AND 1800 AND is_warmup = false)')
      end
    end
  end

  down do
    alter_table(:sets) do
      drop_constraint(:sets_planned_rest_seconds_off_warmups)
      drop_column :planned_rest_seconds
    end
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_rest_seconds_in_range)
      drop_column :rest_seconds
    end
  end
end

