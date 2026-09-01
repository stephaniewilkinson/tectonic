# frozen_string_literal: true

# The zeros already stored, given the reading 008 gave the prescription side. #321.
#
# 008 settled this for `program_lifts` and said why in a sentence this migration is only
# extending to the other table:
#
# > A set with no external load stores no weight. Zero would be a lie of the same kind.
#
# It made `sets.weight` nullable in the same breath, and then backfilled nothing -- there
# was no way to *write* a zero set at the time, because the generator writes nil for
# unloaded work. `create_set` was the hole: `weight` was required by its schema and
# `Bounds::WEIGHT` is `(0..2000)`, so a zero was not merely permitted, it was the only thing
# a caller could send for a plank or a bodyweight hip thrust. Every zero in this table
# arrived that way, and each one is a movement that carries no load being described as
# carrying none of it.
#
# **Not only cosmetic, which is why it is a migration and not a view change.** Zero is
# truthy in Ruby, and three readers take truthiness for a load:
#
#   * `load_label` and `quantity_label` print "0 lb x 10" instead of "10 reps" -- the row a
#     lifter reads at arm's length, showing a load nobody is being asked to lift
#   * `WorkoutSet#ratable?` ends in `!weight.nil?`, so a zero hangs five RPE buttons on a
#     working set that #278 decided should not have any
#   * `Volume::HEAVIEST` is `max(sets.weight)`, so a bodyweight movement reads as having a
#     0 lb top set rather than no top set
#
# A null is what each of those already handles correctly, and it is what the column has
# been able to hold since 008.
#
# `planned_weight` goes with it. It is the same lie in the column beside, it feeds
# `planned_label` through the same truthiness guard, and `Progression.met?` compares the
# two raw -- so leaving one nulled and the other zeroed would make the pair disagree about
# whether a set carried a load.
#
# **What this costs, stated plainly:** a placeholder somebody typed 0 into on a real
# barbell lift is now recorded as bodyweight. 008 already reached the conclusion that
# decides this -- there is no signal that tells the two apart -- and of the two readings a
# lift showing no weight is visible on the session screen and correctable in one edit,
# where a zero pretending to be a load is not visible anywhere.
Sequel.migration do
  up do
    from(:sets).where(weight: 0).update(weight: nil)
    from(:sets).where(planned_weight: 0).update(planned_weight: nil)
  end

  # Irreversible in the only sense that matters: the nulls this leaves behind cannot be told
  # from the nulls the generator has been writing for unloaded work since 008, so putting
  # zeros back would zero those too and reintroduce the bug on rows that never had it.
  # Nothing is dropped and no column changes shape, so a downgrade needs nothing done.
  down do
    # Deliberately empty. See above.
  end
end

