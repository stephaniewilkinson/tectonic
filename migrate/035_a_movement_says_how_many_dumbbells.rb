# frozen_string_literal: true

# How many dumbbells a movement is done with. #439.
#
# 033 gave dumbbells their own inventory and 007's arithmetic: a handle stands where the bar
# does, `pairs` counts what goes on **one** dumbbell, and `Plates.totals` answers for either
# rack without knowing which it is looking at. That is exactly right for a single-arm row and
# exactly wrong for a dumbbell bench press, and nothing until now could tell them apart.
#
# **Loadability differs between them and the difference is not small.** A plate size has to
# appear symmetrically on each handle in use, so one dumbbell spends a pair of a size and two
# dumbbells spend two pairs. On the reporting account's shelf -- a 4 lb handle with pairs of
# 10, 5 and 2.5 -- that is the difference between
#
#     one dumbbell:   4, 9, 14, 19, 24, 29, 34, 39, 44, 49, 54, 59, 64, 69, 74, 79
#     two dumbbells:  4, 9, 14, 19, 24, 29, 34, 39
#
# Half the range disappears. A single-arm row at 44 is ordinary; a dumbbell bench at 44 cannot
# be built at all, and the app was prescribing both from the same list.
#
# ## Two, where nobody has said
#
# There is no honest default here -- the two answers are wrong about different movements, and
# the column exists precisely because the app cannot work it out. So the tie is broken on which
# failure is worse, which #439 is explicit about:
#
#   "Rounding down rather than to nearest matters here: rounding up produces a weight the
#    lifter cannot load, which is a worse failure than one that is slightly light."
#
# Two is the conservative answer in exactly that sense. Every weight loadable on a pair is
# loadable on a single, so defaulting to two can only ever prescribe something buildable, where
# defaulting to one prescribes weights that do not exist for half the movements it applies to.
# A single-arm movement left unanswered is therefore a little light rather than impossible, and
# saying so on the movement fixes it.
#
# It cannot be seeded from the library, which was the first thing tried: `load_library` inserts
# every one of its fifty-four rows with `is_barbell: true`, so no dumbbell movement in this app
# is a library movement. They are all rows a lifter or an assistant created, and only the
# lifter knows which hand they are in.
#
# ## Why a column on the movement
#
# It is a property of the movement rather than of the prescription, the same argument
# `is_barbell` settles in exercise_library.rb: a dumbbell bench press is done with two
# dumbbells every time anybody writes it, and putting the answer on the prescription would ask
# it again on every block and let three write paths forget it -- which is the failure that
# comment records having already happened once.
#
# Nullable rather than defaulted in the schema, so the column keeps saying whether anybody has
# actually answered. `Exercise#dumbbells` is where null becomes two; a `DEFAULT 2` here would
# make an unanswered movement indistinguishable from one deliberately set to two, and the
# difference is the whole of what a "review these" list would be built from.
#
# The check allows only 1 and 2. There is no movement done with three dumbbells, and a column
# that would accept one is a column that will eventually hold one.
Sequel.migration do
  up do
    alter_table(:exercises) do
      add_column :dumbbell_count, Integer
      add_constraint(:exercises_dumbbell_count_is_one_or_two) do
        Sequel.lit('dumbbell_count IS NULL OR dumbbell_count IN (1, 2)')
      end
    end
  end

  down do
    alter_table(:exercises) do
      drop_constraint(:exercises_dumbbell_count_is_one_or_two)
      drop_column :dumbbell_count
    end
  end
end

