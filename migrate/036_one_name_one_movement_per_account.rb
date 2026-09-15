# frozen_string_literal: true

# An account cannot have two movements with the same name. #476.
#
# One unique index existed and it only covered the library:
#
#   CREATE UNIQUE INDEX exercises_library_name_key ON exercises (name) WHERE account_id IS NULL
#
# So the shared library cannot hold two `Deadlift` rows, and an account can hold as many as it
# likes. The reporting account holds exactly that -- a private `Deadlift` with 64 sets and a
# library `Deadlift` with none, indistinguishable in any list that shows a name.
#
# ## Folded, not raw
#
# A raw unique index would allow `Bench Press` and `Benchpress` side by side, which is the
# duplicate this app actually produced. The expression matches `ExerciseNames.fold` exactly:
# lowercased, non-alphanumerics removed. The two have to agree, and a spec asserts they do --
# an index folding differently from the resolver would refuse rows the app considers distinct
# and accept ones it considers the same, which is worse than having neither.
#
# The library index is folded here too. Nothing has collided there yet, and the reason is that
# `LIBRARY` is a hand-written list rather than a rule -- which is not a guarantee.
#
# ## Why an index when #474 already has the rule
#
# #474 put it in `Resolver::exercise` and in the browser form. That is two call sites today
# and it was one fewer before the browser form existed. `is_barbell` is this codebase's own
# cautionary tale: its comment records that three write paths forgot the flag when each had to
# remember it, which is why `barbell?` is on the model. An index is that argument enforced by
# the database rather than by everyone remembering.
#
# It also converts a silent wrong answer into a loud one. Without it, a path that skips the
# fold creates a second row and everything carries on.
#
# ## It refuses rather than folding anything
#
# A collision here is two rows with training on them, and choosing which survives is not a
# migration's decision to make -- `ExerciseMerge` refuses to choose direction for exactly this
# reason, and it is right: on the reporting account four pairs fold onto the library row and
# `Deadlift` folds the other way, because there the private row is the one carrying the
# training. A migration that picked automatically would get that one backwards and move 64
# sets, a training max and seven program lifts onto an empty row.
#
# So it aborts and names them. That fails a deploy, which is the honest outcome: the data has
# to be resolved deliberately first, with `rake 'exercises:merge[from,to]'`.
Sequel.migration do
  up do
    folded = Sequel.function(:lower, Sequel.function(:regexp_replace, :name, '[^a-zA-Z0-9]', '', 'g'))

    # Named before creating, because afterwards the index creation has already failed with
    # nothing but a constraint name to go on. Two accounts' worth of collisions in one error
    # message beats finding them one failed deploy at a time.
    collisions = from(:exercises).exclude(account_id: nil)
                                 .group(:account_id, folded)
                                 .having { count.function.* > 1 }
                                 .select_map([:account_id, folded.as(:folded)])
    unless collisions.empty?
      listed = collisions.map { |account_id, name| "account #{account_id}: #{name}" }.join(', ')
      raise Sequel::Error,
            "Two movements share a name on #{collisions.length} account/name pair(s) -- #{listed}. " \
            "Fold them first with rake 'exercises:merge[from,to]'; which row survives is a " \
            'decision about where the training is, so this will not choose for you.'
    end

    run <<~SQL
      CREATE UNIQUE INDEX exercises_account_folded_name_key
        ON exercises (account_id, lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g')))
        WHERE account_id IS NOT NULL
    SQL
  end

  down do
    run 'DROP INDEX IF EXISTS exercises_account_folded_name_key'
  end
end

