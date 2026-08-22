# frozen_string_literal: true

Sequel.migration do
  # Work that carries no external load: a plank, a band pull-apart, a walk. There was no
  # way to write one. `check_load` refuses a lift with neither top_weight nor
  # percent_of_max, so the only expressible thing was `top_weight: 0` -- and zero is not
  # what a plank weighs, it is a null wearing a number's clothes.
  #
  # Worse than untidy, it corrupts the training. Zero is truthy in Ruby, so a lift written
  # at 0 passes `written_start` as a real starting load, `Progression.met?` reads a
  # completed set against a planned 0 as met, and `next_top_weight` adds an increment. A
  # plank generates at 0, then 5, then 10: three weeks in, the app is prescribing a
  # weighted plank nobody asked for. A barbell-flagged zero also draws a 45 lb warmup ramp
  # above its 0 lb working sets.
  #
  # The fourth value goes on `progression`, which already answers how a load is decided --
  # linear steps from a written number, percent reads one off the estimated max, fixed
  # holds. Unloaded says there is no load to decide, and putting it here rather than on a
  # new boolean means a lift cannot be marked unloaded and linear at once.
  up do
    # 006 wrote the known rules into a check constraint, so the new one has to be admitted
    # before any row can carry it. Widened rather than dropped: the constraint is what
    # stops a typo in a rule name reaching the generator, where an unknown rule falls
    # through to `written_start` and reads as fixed.
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_progression_known)
      add_constraint(:program_lifts_progression_known) { progression =~ %w[fixed linear percent unloaded] }
    end

    # Existing zero-weight rows adopt the reading they were always meant to have, which is
    # the same move 006 made when it gave every existing lift the rule it was already
    # being generated under. Both readings of a written zero are better off stopped: a
    # bodyweight lift stops climbing, and a placeholder somebody typed 0 into stops
    # pretending to be a load. Neither can be told from the other -- there is no signal --
    # but a lift that generates with no weight is visible on the session screen and
    # correctable in one edit, where a silent 5 lb a week is the bug being fixed here.
    from(:program_lifts)
      .where(top_weight: 0, percent_of_max: nil)
      .update(progression: 'unloaded', top_weight: nil)

    # A set with no external load stores no weight. Zero would be a lie of the same kind,
    # and it is the column tonnage is summed from: a null contributes nothing to a sum,
    # which is exactly right for a plank, where zero would also be right but only by
    # accident of arithmetic.
    alter_table(:sets) { set_column_allow_null :weight }

    # The invariant holds for anything that writes to this table, not only for the two
    # code paths that go through the shared writer.
    alter_table(:program_lifts) do
      add_constraint(:unloaded_lifts_carry_no_load) do
        Sequel.lit("progression <> 'unloaded' OR (top_weight IS NULL AND percent_of_max IS NULL)")
      end
    end
  end

  # Reversing puts the zeros back rather than dropping the rows, so a downgrade loses the
  # distinction and nothing else. The sets column cannot go back to NOT NULL while a null
  # is in it, so those are zeroed first.
  down do
    alter_table(:program_lifts) { drop_constraint(:unloaded_lifts_carry_no_load) }
    from(:program_lifts).where(progression: 'unloaded').update(progression: 'linear', top_weight: 0)
    from(:sets).where(weight: nil).update(weight: 0)
    alter_table(:sets) { set_column_not_null :weight }
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_progression_known)
      add_constraint(:program_lifts_progression_known) { progression =~ %w[fixed linear percent] }
    end
  end
end

