# frozen_string_literal: true

# Somewhere to say why a session went the way it did. #310.
#
# `program_lifts.note` and `exercises.note` both exist -- coaching intent for a prescription
# and for a movement -- and a *session* had nowhere to put anything. `workouts.name` is a
# label that tells two sessions on one date apart, not a place for a sentence.
#
# The gap matters most beside the things this app has only just started recording. An RPE of
# 9 on a set prescribed at 8 (#265) and a forty minute turnaround (#281) are both facts the
# app now keeps, and neither says *why*. "Slept badly" is the answer to both, available on
# the day and gone by the following week -- so the numbers accumulate and the one piece of
# context that explains them does not.
#
# **On the workout rather than on the program day**, which is the choice worth recording. A
# note on the day would be a note on the *plan*, and it would repeat on every week generated
# from that day -- right for "pause each rep", wrong for "slept badly", and this column is
# for the second. A note per set is finer than anyone will use one-handed with chalk on, and
# the session is the unit a person actually remembers in.
#
# Nullable, with blank stored as null. '' is truthy in Ruby, so a blank note kept as itself
# would draw its own empty paragraph under every session forever -- the same reasoning
# Exercise.clean_note and Workout.clean_name already carry, and now the same helper.
Sequel.migration do
  change do
    add_column :workouts, :note, String
  end
end

