# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'
require_relative 'one_rep_max'
require_relative 'plates'
require_relative 'timing'
require_relative 'workouts'

class Tectonic < Roda
  # What went well, named specifically. #410, the second half.
  #
  # Finishing a session said nothing about how it went. The first half of #410 built the
  # moment -- something now closes a session -- and this is what there is to read once it has
  # been closed.
  #
  # ## Why "named specifically" is the whole requirement
  #
  # #410 is blunt about it: *"Generic praise reads as filler and gets ignored; a concrete
  # number does not."* And then the harder line: **"Do not manufacture a win that isn't in the
  # data. A summary that praises everything stops being read, and this app's whole position is
  # that it reports what it measured and leaves the judgement to the assistant."**
  #
  # So every line here is a **comparison that came out one way rather than the other**, stated
  # as the numbers it was made from. Nothing in this file contains an adjective about the
  # lifter. "Two extra reps at a lower effort than prescribed" is arithmetic; "great session"
  # is a verdict, and verdicts are not the app's to make -- which is #263's line and the
  # reason this returns four short facts rather than a paragraph.
  #
  # A session with nothing to say gets nothing said. That is the property that keeps the rest
  # readable: a summary that appears every time, saying something every time, is a summary
  # nobody reads by the third week.
  #
  # ## What is deliberately not here
  #
  # The diagnostics -- rests over prescription, the long gap, what was left unfinished -- are
  # #409's and are printed further down the record. #410 asks for that ordering explicitly:
  # *"a session that ran long and still moved a training max is a good session, and the
  # ordering should say so."*
  module SessionSummary
    # A session is "this week's Nth" only from the second onwards. The first session of a week
    # is not a streak, and saying "1st session this week" about it would be the manufactured
    # win the issue warns against.
    STREAK_FROM = 2

    module_function

    # What went well, as an ordered list of sentences. Empty where nothing did, which is a
    # real answer and the one that keeps this worth reading.
    #
    # Ordered as #410 orders them: what was beaten, what was moved, what was got through, and
    # how often. The lead is whatever the strongest true thing is, which on most days is the
    # first of those that happened at all.
    def of(workout, sets, timing)
      done = sets.select { |set| set[:is_completed] }
      return [] if done.empty?

      [*beat_the_plan(done), *maxes_moved(workout, done), *got_through(sets, done, timing),
       *streak(workout)].compact.take(4).then { |found| found.empty? ? held(sets, done) : found }
    end

    # "Bench 97x5 at RPE 7, planned 97x3 -- two extra reps at a lower effort than asked for."
    #
    # The best one rather than all of them. A session where five sets each went a rep over is
    # one fact about the session, not five, and printing it five times is the thing that makes
    # a summary stop being read.
    #
    # Only reps, and deliberately not weight. A set logged heavier than planned is usually the
    # lifter correcting what the bar actually had on it rather than beating anything (#215 is
    # about exactly that edit), so calling it a win would be reading a typo as an achievement.
    # An extra rep is unambiguous: nobody logs a sixth rep they did not do.
    def beat_the_plan(done)
      best = done.select { |set| extra_reps(set).to_i.positive? }.max_by { |set| extra_reps(set) }
      return [] unless best

      ["#{name_of(best)} #{shape(best)}#{effort(best)}, planned #{best[:planned_weight] &&
        "#{Plates.numeric(best[:planned_weight])}x"}#{best[:planned_reps]} " \
       "-- #{plural(extra_reps(best), 'extra rep')}#{lower_effort(best)}."]
    end

    def extra_reps(set)
      return nil unless set[:planned_reps] && set[:reps]

      set[:reps] - set[:planned_reps]
    end

    # "That puts your squat at 174, up from 168."
    #
    # The comparison is this session's best reading against the best reading from everything
    # before this session's date -- not against "the max today", which would already include
    # the sets being asked about and could never move.
    #
    # One query per movement in the session, which is three to six on a real day and only on a
    # record page. Nil where the movement has no prior reading at all: a first-ever session of
    # a lift sets every number it touches, and "up from nothing" is not a thing that happened.
    def maxes_moved(workout, done)
      done.group_by { |set| set[:exercise_id] }.filter_map { |id, sets| moved(workout, id, sets) }.take(1)
    end

    def moved(workout, exercise_id, sets)
      exercise = Exercise[exercise_id]
      now = OneRepMax.best_of(sets)
      return nil unless exercise && now

      before = exercise.estimated_max(account_id: workout.account_id, on: workout.date.to_date - 1)
      return nil unless before && now > before

      "That puts your #{exercise.name.downcase} at #{Plates.numeric(now.round)}, " \
        "up from #{Plates.numeric(before.round)}."
    end

    # "19 sets in 51 minutes." Said only where the whole session was completed, because that is
    # what makes it a fact about getting the work done rather than about stopping early -- a
    # short session with half its sets unticked is fast for the obvious reason.
    def got_through(sets, done, timing)
      return [] unless done.length == sets.length && timing && timing[:active]

      ["#{plural(done.length, 'set')} in #{Timing.phrase(timing[:active])}."]
    end

    # "Third session this week." A count, not a claim about consistency -- and only from the
    # second, because the first session of a week is not a streak and calling it one would be
    # the manufactured win #410 warns about.
    #
    # Weeks begin on Monday here, which is the training week the volume chart already buckets
    # by rather than the calendar grid's account-chosen start. A block is a unit of work and
    # starts where the block starts.
    def streak(workout)
      count = trained_this_week(workout)
      return [] if count < STREAK_FROM

      ["#{ordinal(count)} session this week."]
    end

    def trained_this_week(workout)
      date = workout.date.to_date
      monday = date - ((date.wday - 1) % 7)
      Workout.where(account_id: workout.account_id)
             .where(Sequel.cast(:date, :date) => monday..date)
             .where(id: WorkoutSet.where(is_completed: true).select(:workout_id))
             .count
    end

    # What to say when nothing was beaten, which #410 names: *"If nothing beat the plan, say
    # what held."* Still a comparison rather than praise -- every prescribed set done, and no
    # rated set harder than it was asked to be -- and still silent where it is not true.
    def held(sets, done)
      return [] unless done.length == sets.length && done.any? { |set| set[:planned_reps] }
      return [] unless done.all? { |set| at_or_under_target?(set) }

      ['Every prescribed set completed, none harder than asked for.']
    end

    # A set with no rating, or none prescribed, cannot have been harder than it was asked to
    # be -- there is no comparison to fail. Treating an unrated set as a failure would make
    # this line depend on how diligently somebody tapped RPE buttons rather than on how the
    # session went.
    def at_or_under_target?(set)
      return true unless set[:rpe] && set[:planned_rpe]

      set[:rpe] <= set[:planned_rpe]
    end

    def name_of(set) = Exercise[set[:exercise_id]]&.name || 'That set'

    def shape(set)
      return "#{set[:reps]} reps" unless set[:weight]

      "#{Plates.numeric(set[:weight])}x#{set[:reps]}"
    end

    def effort(set) = set[:rpe] ? " at RPE #{set[:rpe]}" : ''

    # Only where both numbers exist and the rating is genuinely under the target. "At a lower
    # effort than asked for" is the part of this that is worth reading, and saying it on a set
    # taken at exactly the target would be a small lie in the direction of praise.
    def lower_effort(set)
      return '' unless set[:rpe] && set[:planned_rpe] && set[:rpe] < set[:planned_rpe]

      ' at a lower effort than asked for'
    end

    def plural(count, noun) = "#{count} #{noun}#{'s' unless count == 1}"

    ORDINALS = %w[zeroth first second third fourth fifth sixth seventh eighth ninth tenth].freeze

    def ordinal(number)
      (ORDINALS[number] || "#{number}th").capitalize
    end
  end
end

