# frozen_string_literal: true

# A prescription can say how the room is set up. #412.
#
# Chest-Supported DB Row was programmed with the note "incline bench" and nothing more. The
# lifter set 30 degrees, correctly, and had no way to know that was what was intended.
#
# **Bench angle changes what a row trains** -- shallow loads the lats, past about 45 degrees it
# becomes a rear-delt movement -- so it is a programming variable rather than a preference.
# Rack heights matter more than they look, too: getting under a bar at the wrong J-hook height
# wastes a minute, and re-unracking mid-warmup wastes several, which is expensive against the
# time budget 032 just gave a block.
#
# ## On the prescription, not on the movement
#
# #412 offers both -- "a structured field on the exercise or the program lift" -- and the
# choice is settled by 010, which refused to put a per-account note on `exercises` for a reason
# that applies here exactly:
#
#   There is deliberately no per-account note on a library movement. A library row has a nil
#   account_id and appears on every account's page, so a note column on one is a value one
#   account writes and every other account reads.
#
# Incline Dumbbell Press is a library movement. A bench angle column on it would be one
# lifter's bench angle on everybody's screen.
#
# The prescription has no such problem: a program_lift hangs off a program_day, a program_week
# and a program, and a program has an account. It is also the more honest home. A bench angle
# is a property of *how this block wants the movement done* rather than of the movement --
# which is the whole reason the issue calls it a programming variable -- and the same lifter
# may well want 30 degrees in a hypertrophy block and 15 in the next one.
#
# So it travels the way every other instruction travels: written on the lift, copied onto the
# sets the generator writes, and read off the row on the session screen. That is 019's pattern,
# 029's and 031's, and the reason it keeps being the pattern is that a session generated on
# Monday then keeps the setup it was generated with when the block is edited on Wednesday.
#
# ## Why these three and not the rest of the list
#
# #412 also names band tensions owned, dumbbell handle weight, and bench angle increments.
#
# The dumbbell handle landed in #369, which built the second rack the issue asks for.
#
# Band tensions are deliberately not here, and it is not an oversight. A band is the one item
# on that list that is not a number: bands are named by colour, every manufacturer numbers
# them differently, and the useful half of the feature -- "warn when a prescribed band tension
# isn't owned" -- needs an account-level inventory before it can warn about anything. That is
# #369's shape again and a build of its own; guessing at it here would produce a free-text
# field wearing a structured field's clothes, which is the thing this issue is against.
#
# Bench angle *increments* are left out for a smaller reason: they exist to validate an angle
# against a particular bench, and the range below already refuses the angles no bench has.
# Somebody whose bench is numbered 1-5 rather than in degrees is not served by this and is not
# worse off than they were.
#
# ## The ranges
#
# **-30 to 90 degrees.** Decline benches go to about -30 and a fully upright one is 90; past
# either is not a bench angle. Zero is flat and is a real answer, which is why the column is
# nullable rather than defaulted -- "flat" and "nobody said" are different instructions, and a
# default of zero would print "bench 0 degrees" on every barbell curl in the app.
#
# **1 to 50 for a hole.** Racks are numbered from the bottom and the tallest have around forty
# positions; fifty is past every rack and one is the lowest hole there is. A zero would be a
# hole that does not exist.
#
# A bad value here is not one bad row: the generator copies it onto every working set of every
# week the block generates, which is 019's argument for bounding target_rpe in the schema and
# applies unchanged.
#
# All six columns are new and nullable, so no existing row can fail any constraint. `down`
# loses what was written after this ran and cannot do otherwise.
# The two tables take the identical three columns and the identical three constraints, so the
# statements are written once and run against each rather than copied. 019 and 029 spelled both
# tables out because the two differed -- a target RPE may not sit on a warmup and a prescription
# has no warmups to exclude -- and here they do not differ at all: a bench is at the same angle
# on a ramp rung as it is under the top set.
CHECKS = {
  bench_angle: 'bench_angle_degrees IS NULL OR bench_angle_degrees BETWEEN -30 AND 90',
  rack_hole: 'rack_hole IS NULL OR rack_hole BETWEEN 1 AND 50',
  safety_hole: 'safety_hole IS NULL OR safety_hole BETWEEN 1 AND 50'
}.freeze

Sequel.migration do
  up do
    %i[program_lifts sets].each do |table|
      alter_table(table) do
        %i[bench_angle_degrees rack_hole safety_hole].each { |column| add_column column, Integer }
        CHECKS.each { |name, rule| add_constraint(:"#{table}_#{name}_in_range") { Sequel.lit(rule) } }
      end
    end
  end

  down do
    %i[sets program_lifts].each do |table|
      alter_table(table) do
        CHECKS.each_key { |name| drop_constraint(:"#{table}_#{name}_in_range") }
        %i[bench_angle_degrees rack_hole safety_hole].each { |column| drop_column column }
      end
    end
  end
end

