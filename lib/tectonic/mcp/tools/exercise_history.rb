# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative '../../one_rep_max'
require_relative '../../training_max'
require_relative '../../timing'
# Volume::WINDOWS, so the windows an assistant is given here are the same three the volume
# page draws. Two lists of weeks in one app, free to drift, would make "the last 12 weeks"
# mean one thing on a chart and another in a conversation about the same movement.
require_relative '../../volume'

class Tectonic < Roda
  module MCP
    module Tools
      # What has actually been lifted on one movement, over a window, with the estimated
      # max it supports. Answering "is the squat going up" by walking every workout and
      # filtering it client-side costs a call per session and a context window; this is
      # one call, and it is the shape every progression question starts from.
      class ExerciseHistory < Tool
        DEFAULT_LIMIT = 50
        MAX_LIMIT = 200

        tool_name 'exercise_history'

        title 'History of a movement'
        description "The account's own sets of one movement (by name), newest first, with " \
                    'the dates they were lifted and the estimated one-rep max they support. ' \
                    'Narrow with from/to (YYYY-MM-DD). Completed sets only by default, which ' \
                    'is what training history means; pass include_planned for written but ' \
                    'unlifted sets too. Also reports how long this lifter typically takes ' \
                    'between sets of this movement, measured from their own sessions, which ' \
                    'is what to price a prescribed day with. ' \
                    'estimated_1rm is the most that has ever been demonstrated, so it can be ' \
                    'years old; `recent` reports what the last 12, 26 and 52 weeks each imply ' \
                    'on their own, with the date and the number of sets behind each. Use the ' \
                    'gap between them to judge what a next block should open at -- the app ' \
                    'reports both and proposes neither.'
        scope :read
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
                        limit: { type: 'integer' }, include_planned: { type: 'boolean' } },
          required: ['exercise'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = find(context, arguments[:exercise])
          rows = history(context, exercise, arguments).all
          recent = recent_readings(context, exercise, arguments)
          ok(summary(exercise, rows, context, arguments, recent),
             structured: payload(context, exercise, rows, arguments).merge(recent:))
        end

        # The movement by name among the ones this account can see, without creating it:
        # a history question about a movement that has never been logged is answered
        # "nothing", and inventing the movement to say so would leave a row behind.
        #
        # Through Resolver.existing_exercise since #454. This is the tool the old lookup hurt
        # most: picking the library row over the account's own means reporting on a row with
        # no sets on it, so "how has my deadlift gone" comes back "nothing logged" to somebody
        # with 64 sets of it. `matching` prefers the lifter's own row by stated rule.
        def self.find(context, name)
          Resolver.existing_exercise(context, name)
        end

        def self.history(context, exercise, arguments)
          rows = context.sets.where(exercise_id: exercise.id).order(Sequel.desc(:id))
          rows = rows.where(is_completed: true) unless arguments[:include_planned]
          window(context, rows, arguments).limit(limit_for(arguments))
        end

        # Dates live on the workout, not the set, so a window is a filter on the sessions
        # the sets belong to -- still inside the account-scoped dataset, which is what
        # keeps another account's lifting unreachable from here.
        def self.window(context, rows, arguments)
          from, to = bounds(context, arguments)
          workouts = context.workouts
          workouts = workouts.where { date >= from } if from
          workouts = workouts.where { date < (to + 1) } if to
          rows.where(workout_id: workouts.select(:id))
        end

        # Parsed before the datasets are built, so each bound is read once and so "today"
        # means the lifter's today rather than the server's (#349).
        def self.bounds(context, arguments)
          [arguments[:from] && Resolver.parse_date(arguments[:from], on: context.today),
           arguments[:to] && Resolver.parse_date(arguments[:to], on: context.today)]
        end

        def self.limit_for(arguments)
          (arguments[:limit] || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        end

        # estimated_1rm keeps its name and its meaning: the max the chart reads out of the
        # sets, which is what it has always been. training_max beside it is what a
        # percentage actually resolves against, which since #264 is the stated one where
        # there is one -- so the two disagree exactly when somebody has overridden the
        # estimate, and an assistant reading this can tell that they have.
        #
        # Reporting only the resolved number would have been smaller and wrong. "Your max
        # is 315" and "you told us your max is 315" are different claims, and an assistant
        # advising on a block needs the second: a stated max is a standing instruction, and
        # a derived one is a reading that a layoff quietly invalidates.
        #
        # typical_turnaround_seconds is #263's, and it answers a different question about
        # the same movement: not how heavy, but how long. It is what lets an assistant price
        # a prescribed day -- five squat sets is roughly five of these -- in the lifter's own
        # numbers instead of in a constant somebody chose. Off the rows already fetched, so
        # it costs no query, and nil where nothing can be measured: a movement lifted once,
        # and every movement whose sets predate #281. A zero would read as instantaneous.
        def self.payload(context, exercise, rows, arguments)
          { exercise: exercise.name, exercise_id: exercise.id, shown: rows.length,
            limit: limit_for(arguments), estimated_1rm: estimated(context, exercise, arguments),
            typical_turnaround_seconds: turnaround(rows),
            sets: rows.map { |set| Presenter.view_set(set).merge(date: set.workout.date.strftime('%Y-%m-%d')) } }
            .merge(max_fields(context, exercise, arguments))
        end

        # What the last twelve, twenty-six and fifty-two weeks each imply, beside the lifetime
        # best above. #307.
        #
        # `estimated_1rm` means the most that has ever been demonstrated, which is the right
        # meaning for a max (#293) and is also the one that goes stale without saying so: a
        # single from three years ago outranks everything since. #293 answered half of that by
        # carrying the date. This is the other half -- the same arithmetic over a window, so a
        # reader can see that the lifetime best is 315 from 2023 while the last twelve weeks
        # support 290.
        #
        # **Reported, not resolved.** Nothing here decays or discounts the lifetime figure, and
        # this tool does not propose a number to open a block at. That is the judgement #307
        # asks for and it belongs to whoever is reading this, over honest numbers with their
        # dates and their sample sizes attached -- which is the same line #263 drew and the
        # reason this is four extra fields rather than a new tool that coaches.
        #
        # Windowed off the same `as_of` the estimate uses, so asking about a block that
        # finished in March is answered with the twelve weeks before March rather than the
        # twelve before today. Independent of `from`/`to`/`limit`, which narrow the *sets that
        # are listed*: a caller asking for one session's worth of rows still gets the full
        # windows, because the windows are context for those rows rather than a summary of
        # them.
        # Read once in `perform` and handed to both the payload and the sentence, so the two
        # cannot describe the same movement differently and the extra query is one rather than
        # two.
        def self.recent_readings(context, exercise, arguments)
          exercise.recent_readings(account_id: context.account_id, windows: Volume::WINDOWS,
                                   on: as_of(context, arguments))
                  .map { |reading| readable(reading) }
        end

        # One window on its way out of the door. Both conversions are the kind of bug that only
        # shows up in the payload half, which is the half nobody reads by eye.
        #
        # `pounds` through Presenter.weight is #256, walked into again: weight is numeric(7,2),
        # Sequel hands back a BigDecimal, and BigDecimal serialises to JSON as the *string*
        # "0.275e3". The prose was right from the first line it was written, because it went
        # through the presenter; the structured field a client actually parses was a string
        # nobody could do arithmetic on. That issue found this in two places and there was a
        # third waiting for the next field to be added.
        #
        # `on` is the day the set behind the reading was lifted. The column is a timestamp, so
        # it comes back as a Time and would serialise with an hour and a timezone on it -- an
        # answer more precise than the question, and a different shape from every other date in
        # this payload.
        def self.readable(reading)
          reading.merge(pounds: Presenter.weight(reading[:pounds]),
                        on: reading[:on]&.to_date&.strftime('%Y-%m-%d'))
        end

        # The resolved max as three keys: the number, which of the two kinds it is, and the
        # day it is as of. Split out because they are one fact in three parts and because a
        # payload naming every field of every fact in one literal is a method doing several
        # jobs -- which rubocop counted before a reader would have.
        def self.max_fields(context, exercise, arguments)
          resolved = resolved_max(context, exercise, arguments)
          { training_max: resolved&.pounds, training_max_source: resolved&.source,
            training_max_as_of: resolved&.on_date&.strftime('%Y-%m-%d') }
        end

        # Grouped by session inside Timing, so two sets a week apart are never subtracted
        # from one another. The rows carry workout_id already.
        def self.turnaround(rows)
          Timing.between_sets_of(rows.map(&:values))
        end

        # The max as of the end of the window rather than as of today, so asking about a
        # block that finished in March is answered with what was true in March. Without a
        # window it means now, which is what "what can I lift" asks.
        def self.estimated(context, exercise, arguments)
          exercise.estimated_max(account_id: context.account_id, on: as_of(context, arguments))
        end

        # What a percentage lift would generate against: the stated max if there is one and
        # the derived reading otherwise. Through TrainingMax rather than repeating the
        # fallback, so this and ProgramGenerator cannot come to different conclusions about
        # the same movement -- which would make this tool describe a block it is not
        # generating.
        def self.resolved_max(context, exercise, arguments)
          TrainingMax.for(account_id: context.account_id, exercise:, on: as_of(context, arguments))
        end

        def self.as_of(context, arguments)
          arguments[:to] ? Resolver.parse_date(arguments[:to], on: context.today) : context.today
        end

        # `compact` before `max`, which is a second bug found while fixing the first. The
        # column is nullable and unweighted work stores nothing in it, so a movement with
        # both weighted and bodyweight sets in its history -- a pull-up, say -- reached
        # `max` with a nil among BigDecimals and raised ArgumentError rather than answering.
        # A history question about a mixed movement failed outright.
        #
        # The prose says the resolved max rather than the estimate, because it is the number
        # the next block will be built on, and it says which kind it is -- many clients show
        # only this text, and "max 315" that turns out to be a guess off a set from before a
        # layoff is the misreading #264 is about.
        def self.summary(exercise, rows, context, arguments, recent)
          heaviest = Presenter.weight(rows.map(&:weight).compact.max)
          "#{exercise.name}: #{rows.length} set(s), heaviest #{heaviest || 'none'}, " \
            "#{max_phrase(resolved_max(context, exercise, arguments))}#{pace(rows)}." \
            "#{recent_phrase(recent)}"
        end

        # The windows in the sentence and not only in the payload, which is #262's lesson and
        # the reason this tool prints its sets at all: plenty of clients render only the text,
        # and a lifetime best that reads as current is exactly the misreading #307 is about.
        #
        # Silent where no window holds anything readable, rather than printing three nils. A
        # movement with nothing in the last year has said everything it can say with the
        # lifetime figure above, and three empty clauses would be noise on every bodyweight
        # movement in the account -- none of which can be read for a max at all.
        def self.recent_phrase(recent)
          readable = recent.select { |reading| reading[:pounds] }
          return '' if readable.empty?

          " Recently: #{readable.map { |reading| window_phrase(reading) }.join(', ')}."
        end

        # The sample size is in the sentence too, because 290 off one set and 290 off forty are
        # not the same claim and a reader with only the number cannot tell them apart.
        def self.window_phrase(reading)
          sets = reading[:sets]
          # Already through the presenter by the time it gets here, which is what `readable`
          # is for -- the sentence and the payload now carry the same number rather than two
          # renderings of it.
          "last #{reading[:weeks]} weeks imply #{reading[:pounds]} " \
            "(#{sets} #{sets == 1 ? 'set' : 'sets'})"
        end

        def self.max_phrase(resolved)
          return 'no training max yet and nothing lifted to estimate one from' unless resolved

          dated = resolved.on_date ? ", from #{resolved.on_date.strftime('%-d %b %Y')}" : ''
          "training max #{Presenter.weight(resolved.pounds)} (#{resolved.explanation}#{dated})"
        end

        # How long a set of this costs, in the sentence as well as the payload -- many
        # clients render only the text, which is #262's lesson. Silent where there is nothing
        # measured, rather than printing a zero that reads as instantaneous.
        def self.pace(rows)
          seconds = turnaround(rows)
          seconds && ", about #{Timing.phrase(seconds)} between sets of it"
        end
      end
    end
  end
end

