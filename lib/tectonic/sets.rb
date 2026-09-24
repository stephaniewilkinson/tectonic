# frozen_string_literal: true

require_relative 'db'
require_relative 'measured'
require_relative 'oauth_application'

class Tectonic < Roda
  # Named WorkoutSet rather than Set because Ruby 4.0 promoted Set to a core class, and a
  # model called Set shadowed it in every file that reopens `class Tectonic` -- which is
  # all of lib/ and app.rb. `Set.new` there returned an empty row of this table rather than
  # a core Set, and did not raise while doing it, so the mistake surfaced somewhere else.
  #
  # The table is named explicitly because Sequel infers one from the class name, and this
  # class is no longer named after its table. The table stays `sets`: it is the right name
  # for what it holds, and it is the class name that had to move.
  class WorkoutSet < Sequel::Model(:sets)
    many_to_one :exercise
    many_to_one :workout
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    # The measure as a symbol; the column stores text. See Measured for why a dataset
    # filter must still use the string form.
    def measure
      Measured.cast(super)
    end

    def timed?
      measure == Measured::TIME
    end

    # Whether an RPE means anything for this set. #211.
    #
    # RPE is reps in reserve -- an 8 is "two more were there" -- so it needs reps for any
    # to be in reserve of. A 60 second plank has none, and the scale in _rpe_help.erb is
    # written entirely in rep counts ("4+", "3", "2", "1", "0"), so on a timed set it was
    # explaining a measure that could not be applied to it.
    #
    # A warmup is submaximal by definition, so its rating is a number nobody reads back.
    # The session screen already declined to ask for one; this is that rule said once,
    # where the write paths can see it, rather than implied by which list a row is in.
    #
    # Deliberately not is_barbell. That flag decides plate math and a warmup ramp, and a
    # dumbbell press has reps in reserve in exactly the sense a bench press does -- the
    # question is whether the set is counted in reps, not what it is loaded with.
    # Nor unweighted work, which is #278. RPE on a set carrying no external load is a
    # question about a movement rather than about a load: press-ups are as hard as your
    # last set of press-ups made them, and the answer moves nothing the app can act on --
    # there is no weight for Progression to step, and the rating would sit beside a blank
    # where every other rated set has a number. Five 48px buttons is also the tallest thing
    # on a row, and a session of banded and bodyweight accessories was mostly rating scale.
    #
    # This is the screen declining to ask. The database constraint from #211 still permits
    # a rating here, and deliberately: it enforces the two rules that are about meaning --
    # warmups and timed work -- and narrowing it to weight as well would be a migration
    # that clears ratings somebody did record.
    #
    # `positive?` rather than `!nil?`, which is #321. Zero is truthy in Ruby, so a set whose
    # weight was stored as 0 -- the only thing create_set would accept for bodyweight work
    # until 025 -- passed this test and drew the five buttons #278 exists to withhold. 025
    # nulls the zeros already in the table; this is what makes a zero from anywhere else
    # read as the absence of load it means, rather than leaving the rule true of the column
    # and false of the movement.
    def ratable?
      !is_warmup && !timed? && !weight.nil? && weight.positive?
    end

    # The work of one set, doubled where the count was per side. A Bulgarian split squat
    # written 3x8 per side is 48 reps of work, not 24, and counting it as 24 is what made
    # unilateral volume read as half of what was done.
    def counted_reps
      return nil unless reps

      is_per_side ? reps * 2 : reps
    end

    # The two columns that say a set was done, always written together. #281.
    #
    # completed_at is the instant it happened and is_completed is whether it did, and the
    # database refuses a row holding one without the other -- sets_completed_at_needs_a_
    # completion, because a set that was never done carrying the moment it was done is not
    # a state any reader could make sense of.
    #
    # Here rather than at the call sites, and for the same reason ratable? is on the model:
    # four write paths flip is_completed -- the session screen's Done, the set edit form,
    # complete_set and create_set -- and a rule remembered at four places is a rule forgotten
    # at one. The one that would forget it is undo, which is the path that clears the flag,
    # and the failure would be a check violation surfacing as a 500 on a Done button. That
    # is #213's shape, and this is the answer #211 gave to it: enforce it where it cannot be
    # routed around, and give every caller one way to say the thing.
    #
    # An undo clears the stamp rather than keeping it. A set un-completed was not done, so
    # the instant it was done is not a fact any more -- and keeping it would leave a
    # turnaround measured against a set that the lifter has said did not happen.
    #
    # `at` is a parameter with a default rather than a Time.now inside, so a caller with a
    # better answer -- a backdated import, a test pinning a clock -- can give one.
    def self.completion(done, at: Time.now)
      { is_completed: done, completed_at: done ? at : nil }
    end

    # The same two columns, for a row that already has an answer in them: what it would take
    # to reach `done` from where this set is, which is nothing at all when it is already
    # there. #542.
    #
    # This is what makes a completion safe to send twice, and it is the prerequisite the
    # write queue is built on rather than a tidiness. A tap held on a phone and replayed
    # when the signal returns arrives at a server that may already have recorded it -- the
    # request did reach the database and the *response* was what the network ate, which is
    # the likeliest way a tap comes to be queued at all. `completion` would mark it done a
    # second time, which is harmless for the flag and a lie in the stamp: the set was lifted
    # at 18:04 and the second arrival would say 18:40, moving a turnaround the lifter never
    # took. Every reader of completed_at -- the rest cue, Timing's turnarounds, the record's
    # clock times -- would then describe the phone finding signal rather than the training.
    #
    # It also fixes the wrinkle #516 named in the rating path, where the same re-stamp
    # happened without any queue involved: rating a set that was already done wrote the
    # moment of the rating over the moment of the lift.
    #
    # An empty hash rather than the columns set to what they already hold, because the
    # difference is visible: MCP's Changes.apply reports every field it writes, so an
    # assistant asked to log a set twice said "completed_at 18:04 to 18:40" the second time
    # and now says there was nothing to change. Which is true, and is the thing the lifter
    # needs to hear.
    #
    # Deliberately not a guard inside `completion` itself. That one is a class method used
    # at insert time -- create_set, and the fixtures in the specs -- where there is no row to
    # compare against, and it is the right shape for "these are the two columns a completion
    # is made of". This is the shape for "this set is being asked to become something".
    def completion_to(done, at: Time.now)
      return {} if is_completed == done

      self.class.completion(done, at:)
    end

    # A set moved onto another movement: the new movement's facts, and none of the old
    # movement's prescription. #406.
    #
    # Two generated Barbell Hip Thrust sets at 85 lb were swapped to bodyweight Single-Leg
    # Hip Thrust and the session read `Single-Leg Hip Thrust 10 reps per side (planned
    # 85x8)` -- a bodyweight movement supposedly prescribed at 85 lb. The planned columns
    # said what the *other* lift was asked for, and nothing cleared them.
    #
    # **A prescription belongs to the movement it was written for.** planned_weight,
    # planned_reps, planned_rpe and planned_rest_seconds are all answers to "what was this
    # lift asked for", so a row that is no longer that lift is carrying somebody else's
    # answer. Nil is the honest value: a set swapped at the rack was never prescribed.
    #
    # Cleared rather than refused, which is the other fix #406 offers. Refusing is right for
    # a *completed* set and UpdateSet.refuse_swap already does it -- a different movement is
    # a different set, and the work is gone either way. It is wrong for an unlifted one:
    # swapping a planned movement is the ordinary thing a lifter does standing at a busy
    # rack, and it is what update_workout_exercise exists for.
    #
    # Here rather than at the call sites, for the reason `completion` gives above: three
    # paths move a set onto another movement -- update_set, update_workout_exercise, and the
    # session screen's swap control -- and all three already remembered to carry is_barbell
    # across. A rule remembered at three places is a rule forgotten at one, and the one that
    # forgot this was all three.
    # The setup columns are cleared with the prescription, and for the same reason #406 gave
    # about the planned ones: they say what the *other* lift was asked for. Two generated
    # Barbell Hip Thrust sets swapped to a bodyweight Single-Leg Hip Thrust read as a
    # bodyweight movement supposedly prescribed at 85 lb; a bench angle left behind on a
    # movement that does not use a bench is the same bug wearing different numbers, and on the
    # one line of the row a lifter acts on before touching the bar. #412.
    def self.moved_to(exercise)
      { exercise_id: exercise.id, is_barbell: exercise.barbell?,
        planned_weight: nil, planned_reps: nil, planned_rpe: nil, planned_rest_seconds: nil,
        bench_angle_degrees: nil, rack_hole: nil, safety_hole: nil }
    end
  end
end

