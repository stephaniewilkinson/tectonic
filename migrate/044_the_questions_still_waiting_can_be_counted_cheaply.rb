# frozen_string_literal: true

# An index over the open questions and nothing else, so that "how many proposals are waiting"
# is answerable on a page that has nothing to do with Withings. #534.
#
# ## Why a count has to be cheap before it can be shown anywhere
#
# The review list at /workouts/withings has nothing pointing at it, so the only way to reach
# it is to have just run `withings:backfill` with its output still on screen. The fix is a
# doorway somewhere a lifter already goes, and every version of that doorway -- a nav entry,
# a badge, a line above the workouts list -- has to know whether there is anything behind it
# before it can decide what to say. That is a count, asked on a page view that was not about
# Withings at all, which means its cost is a tax on pages that gain nothing from it.
#
# ## What 042 and 043 already give, and why it is not this
#
# 042 indexes `(account_id, external_id)` and `(account_id, started_at)`; 043 adds a unique
# index on `proposed_workout_id` alone. The second of 042's is the only one a count can use,
# and it can only use it as a prefix: Postgres seeks to the account and then reads *every
# activity that account has ever had* to test the three columns the predicate actually cares
# about. For a lifter who wears the watch for dog walks as well as squats, a decade is a few
# thousand rows, and this would read all of them to answer a question whose true answer is
# almost always nought.
#
# 043's index is no help at all: it leads with `proposed_workout_id`, so it cannot be used to
# find one account's rows, and a count that scanned it whole would read every account's.
#
# ## A partial index, because the predicate is what makes it small
#
# The three conditions below are the definition of "waiting" -- offered by a backfill, not
# confirmed, not refused -- and they are in the index rather than in the query's filter. That
# is what makes this different in kind from a composite index rather than merely narrower:
# the index holds *only* the rows that are still questions, which is a number that goes to
# zero as the lifter answers them. An account that has never connected a watch has no entries
# in it whatever, so the count is one read of an empty index rather than a scan proportional
# to how long they have owned the watch.
#
# The cost is the usual cost of a partial index and worth naming: Postgres will only use it
# for a query whose WHERE clause it can prove implies this one. So the predicate here and the
# predicate in `WithingsProposals.outstanding` are one thing written twice, and the day they
# stop matching the count silently goes back to scanning. That is why there is exactly one
# spelling of it in Ruby -- every reader of "waiting" goes through that one dataset -- and why
# `spec/finding_the_questions_waiting_spec.rb` names these three columns again when it reads
# this index out of the catalogue. It reads the catalogue rather than an EXPLAIN on purpose: a
# planner given a table of twelve rows will scan it whatever indexes exist, so a plan asserted
# there would be an assertion about the size of the fixture.
#
# It leads with `account_id` rather than being a bare predicate index, because the count is
# always for one lifter and a partial index with no key column still has to be read end to
# end. This one seeks.
#
# ## CONCURRENTLY, following 017
#
# A plain CREATE INDEX takes a lock that blocks writes for its duration, and this runs as
# Render's preDeployCommand, where a blocked write is a failed request rather than a slow
# one. It cannot run inside a transaction, which is what `no_transaction` is for, and it is
# why this is up/down rather than `change` -- the drop has to name `concurrently` too, and
# the reversal Sequel would infer does not.
WAITING_INDEX = :withings_workouts_waiting
# The predicate, which is the whole substance of this migration and the thing that has to
# stay in step with `WithingsProposals.outstanding`. Named here rather than written inline so
# that the up and the down cannot describe two different indexes -- a rollback that dropped
# something subtly other than what was made is the kind of failure nobody sees until the
# next deploy.
STILL_A_QUESTION = Sequel.&({ workout_id: nil, dismissed_at: nil }, Sequel.~(proposed_workout_id: nil))

Sequel.migration do
  no_transaction

  up do
    add_index :withings_workouts, :account_id,
              name: WAITING_INDEX, where: STILL_A_QUESTION, concurrently: true
  end

  down do
    drop_index :withings_workouts, :account_id, name: WAITING_INDEX, concurrently: true
  end
end

