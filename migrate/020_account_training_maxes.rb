# frozen_string_literal: true

# A training max you can set, per account and per movement. #264.
#
# `program_lifts.percent_of_max` was never decorative -- the audit that raised this said it
# had "no max to reference", and that was only half right. `Exercise#estimated_max` derives
# one from completed sets as of a date, ProgramGenerator resolves every percentage lift
# through it, and exercise_history returns it as estimated_1rm. What was missing is not a
# max; it is a max a lifter can *state*.
#
# Two cases the derived one cannot answer, and they are the two where percentages are most
# used:
#
# **Coming off a layoff.** The derived max is a lifetime best, and that is worth stating
# exactly rather than loosely, because it is stronger than it sounds: `Exercise#lifted_sets`
# bounds the window only at the top -- `date < (on + 1)` -- and `OneRepMax.best_of` takes the
# maximum over everything it is handed. So there is no lower bound at all. A single lifted in
# 2023 is still the number today's percentages are taken of, and it does not decay, expire or
# get outvoted by a year of lighter work.
#
# That is the right default -- a max is the most that has been demonstrated, not the most
# recent thing attempted, and inferring weakness from absence is what `Progression` already
# refuses to do at session scale. It is also exactly wrong after a layoff, which is when
# percentages get reached for. Somebody who knows their training max is 315 and wants to open
# a block at 65% had no way to say so, and generating against a three-year-old best is how a
# return to lifting gets prescribed at the weight that ended the last block.
#
# **A movement never logged.** There is nothing to derive from, so the week refuses to
# generate and names the movement. That refusal is correct -- inventing a max would write a
# whole block off a guess -- but "log a completed set of it first" was the only way out of
# it, which is a strange thing to tell somebody who already knows what they can lift.
#
# A table rather than a column on `exercises`, and that is the whole design. A library
# movement has a null account_id and sits on every account's page: a column there would be
# one account's number displayed to everyone and generated against by everyone, which is
# exactly the trap `Exercise.owned_by` exists to refuse and says so at length. Keyed on the
# pair, the same value is private by construction, and a shared Back Squat can carry a
# different max for every account that lifts it.
#
# Modelled on account_plates (007), which is the same shape of thing: a per-account fact
# the calculating code reads, kept beside the account rather than on the row it describes.
#
# numeric(7, 2) to match sets.weight, planned_weight, program_lifts.top_weight and
# accounts.bar_weight after 012. A max is compared against and multiplied by a percentage
# to produce a load, so it has to be exact in the way those are; a float would make 315 *
# 0.65 something that does not round the way the rack rounds.
#
# No default and no backfill. An account with no row here is an account that has not said,
# which is not the same as one that has said zero -- the absence is what makes the derived
# max the fallback, and a default would replace "I have not told you" with a number nobody
# chose. Nothing is written for existing accounts for the same reason: everyone keeps the
# derived max they have been generating against until they decide otherwise.
#
# ON DELETE CASCADE on the exercise, and it is the first in this schema. Every other foreign
# key here is a plain reference, because every other child row is training -- sets, program
# lifts, workouts -- and training should not vanish because something it pointed at did.
# This row is not training. It is a preference *about* a movement, so a movement that is
# gone leaves a preference about nothing, and the alternative to cascading is a delete that
# fails on a foreign key or a row that outlives its subject. Exercises are deleted:
# `rake exercises:merge` drops the folded-in row after moving its sets and lifts across.
# The account key is left plain, matching account_plates, since nothing deletes an account.
Sequel.migration do
  change do
    create_table(:account_training_maxes) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      foreign_key :exercise_id, :exercises, null: false, on_delete: :cascade
      # Named for what it is rather than `weight`: this is not a load anybody lifts, it is
      # the number percentages are taken of, and a lift written at 65% of it may never put
      # it on a bar at all.
      BigDecimal :pounds, size: [7, 2], null: false
      # When it was said. A stated max is a standing instruction and is resolved without
      # reference to a date -- see TrainingMax.for -- but "how recent does this have to be to
      # count" is a question a reader cannot even ask of a number with no date on it, and one
      # typed fourteen months ago is otherwise indistinguishable from one typed yesterday.
      #
      # Recorded rather than acted on, deliberately. Nothing expires a stated max, nothing
      # decays it, and nothing warns about it: the app reports when it was said and the
      # reader judges, which is the same division of labour #263 settled for session length.
      # Every other substantive table in 001 carries a timestamp; this is that, and it is
      # here rather than in a later migration because adding a column later is a migration.
      Time :stated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      # A max that is zero or negative is not a max, and one saved by accident would make
      # every percentage lift in a block generate at nothing. Refused here because this is
      # the one place that cannot be routed around -- the form, the MCP tool and any future
      # caller all land on it.
      # Written as a literal, the way 015's rule is. The block form compiles a Sequel virtual
      # row, so `pounds > 0` is what it has to say -- and rubocop then reads that as ordinary
      # Ruby and asks for `positive?`, which a virtual row has no such method for.
      constraint(:account_training_maxes_positive) { Sequel.lit('pounds > 0') }

      # One answer per account per movement. Without this a second save writes a second row
      # and the resolution below reads whichever Postgres returns first, which is a training
      # max that changes between two generations of the same week.
      #
      # It also indexes account_id, since it leads the pair, which is why there is no
      # separate index for that key.
      unique %i[account_id exercise_id]
      # exercise_id needs its own, and #233's rule is why: a foreign key with no index
      # leading on its column makes the parent's deletes scan this whole table. That is not
      # theoretical here -- this is the one cascading key in the schema, so deleting a
      # movement really does come looking for these rows, and `rake exercises:merge` deletes
      # movements. spec/foreign_key_index_spec.rb holds every key in the schema to this.
      index :exercise_id
    end
  end
end

