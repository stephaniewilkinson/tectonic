# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'program_weeks'
require_relative 'programs'
require_relative 'progression'
require_relative 'rounding'
require_relative 'equipment'
require_relative 'measured'
require_relative 'set_scheme'
require_relative 'sets'
require_relative 'warmup'
require_relative 'workouts'

class Tectonic < Roda
  # Turns a program into real workouts and sets for a given week. A planned
  # session is not a separate kind of record: it is ordinary Set rows written
  # ahead of time with is_completed false, which lifting flips to true.
  class ProgramGenerator
    # created_by is the OAuth client that asked for this week, when an assistant did. It
    # is stamped onto the rows the same way a set logged over MCP is stamped, so a
    # session an assistant scheduled says so in the UI rather than appearing to have come
    # from nowhere. Nil for the rake task, which is a person at a command line.
    def initialize(program, created_by: nil)
      @program = program
      # The rack this account lifts on. Every weight below is rounded to something it can
      # actually load, and warmups start at its bar rather than at an assumed 45.
      @equipment = Equipment.for_account(program.account_id)
      @created_by = created_by
    end

    # Inserts a workout per program day of the numbered week, with every set
    # pre-created, warmups included. Returns that week's workouts, whether generated
    # now or already present. Safe to run twice: see existing_workout.
    #
    # The week is named by its position in the block rather than by a date, because
    # the block's start date already fixes when each of its weeks falls; asking a
    # caller for the right Monday was asking them to recompute what the program knows.
    def generate(number)
      week = @program.week(number)
      raise ArgumentError, "Program #{@program.id} has no week #{number}; it has #{@program.weeks}." unless week

      DB.transaction do
        week.program_days.sort_by(&:weekday).map { |day| generate_day(week, day, week.date_for(day.weekday)) }
      end
    end

    # Writes this day's session again from the plan as it now stands, so an edit to a
    # prescription reaches the session that prescription already produced. Answers what it
    # did: :rewritten, :lifted for a session with work in it, or :none where the day has
    # not been generated at all.
    #
    # A session with any completed set is left alone, and that is the whole rule. Once a
    # lifter has answered a prescription the row is a record of what happened, not a plan
    # to be revised, and rewriting it would delete training. An untrained session is only
    # ever a copy of the plan, so replacing it wholesale is the same operation as having
    # generated it a moment later.
    def refresh(day)
      workout = existing_workout(day)
      return :none unless workout
      return :lifted if lifted?(workout)

      DB.transaction do
        Set.where(workout_id: workout.id).delete
        rewrite(day, workout)
      end
      :rewritten
    end

    private

    # The date is recomputed as well, because moving a day to another weekday moves the
    # session it wrote; leaving the old date behind is what used to strand a workout that
    # nothing could find again.
    # The lifts are re-read rather than taken off the day, because the caller has usually
    # just written one: adding a lift asks the day for its lifts to work out the next
    # position, which caches the association as it was a moment before the new row
    # existed, and the session would then be rewritten without it.
    def rewrite(day, workout)
      week = day.program_week
      workout.update(date: week.date_for(day.weekday))
      ProgramLift.where(program_day_id: day.id).order(:position).each do |lift|
        insert_sets(workout, week, lift)
      end
    end

    def lifted?(workout)
      Set.where(workout_id: workout.id, is_completed: true).limit(1).any?
    end

    def generate_day(week, day, date)
      existing = existing_workout(day)
      return existing if existing

      workout = Workout.create(account_id: @program.account_id, date:, program_day_id: day.id,
                               created_by_oauth_application_id: @created_by)
      day.program_lifts.sort_by(&:position).each { |lift| insert_sets(workout, week, lift) }
      workout
    end

    # Idempotency on (account_id, program day): the workout this day already wrote is left
    # exactly as it is, so regenerating a week never duplicates sets and never overwrites
    # what was lifted. Keying on the date as well as the day conflated two different
    # things -- a day moved to another weekday no longer matched the session it had
    # already written, so regenerating left a second workout behind and the first became
    # unreachable. A program day belongs to exactly one week and so has exactly one
    # session; the day is the whole key.
    def existing_workout(day)
      Workout.where(account_id: @program.account_id, program_day_id: day.id).first
    end

    def insert_sets(workout, week, lift)
      return write_flat(workout, lift, nil) unless lift.is_weighted
      return write_flat(workout, lift, top_weight(week, lift)) if lift.timed?

      top = top_weight(week, lift)
      Warmup.ramp(top, is_barbell: lift.is_barbell, bar_weight: @equipment.bar_weight,
                       increment: @equipment.increment).each do |set|
        insert_set(workout, lift, set, is_warmup: true)
      end
      working_sets(lift, top).each { |set| insert_set(workout, lift, set, is_warmup: false) }
    end

    # Every set at the same load, with no ramp before them. Two kinds of work want this.
    # Unweighted work has no load to ramp to and nothing to step between, and its weight
    # column stays empty -- empty rather than zero, because tonnage is summed off it and a
    # null adds nothing to a sum where a zero only fails to add anything by accident of
    # arithmetic. Timed work is measured in seconds, and a ladder of durations is not a
    # warmup: nobody ramps up to a plank.
    def write_flat(workout, lift, weight)
      Array.new(lift.sets) { { weight:, **quantity(lift) } }
           .each { |set| insert_set(workout, lift, set, is_warmup: false) }
    end

    # What this lift counts, as the two columns a set stores it in. The measure names
    # which one carries the number and the other stays empty, which is the invariant the
    # table itself holds.
    def quantity(lift)
      lift.timed? ? { reps: nil, duration_seconds: lift.duration_seconds } : { reps: lift.reps, duration_seconds: nil }
    end

    # The load this week asks for, which is the lift's rule applied and then a deload's
    # reduction on top of whatever it arrived at. Deloading last is what lets the rule stay
    # ignorant of deloads: a lighter week is a lighter version of the week that was due,
    # not a different prescription.
    def top_weight(week, lift)
      planned = prescribed_weight(week, lift)
      week.is_deload ? Progression.deloaded(planned, increment: @equipment.increment) : planned
    end

    # fixed keeps the number it was written with. percent takes one of the account's
    # estimated max, resolved at generation rather than stored, so a week written months ago
    # is generated against the strength that exists when it is trained -- and it needs no
    # step rule, because a max read fresh has already moved by however much the lifting
    # moved it. linear is the one that steps, off the last session of the movement.
    def prescribed_weight(week, lift)
      case lift.progression
      when 'percent' then percent_of_max_weight(lift)
      when 'linear' then progressed_weight(week, lift)
      else written_start(lift)
      end
    end

    # A fixed or linear lift needs pounds to hold at or to start from. A row carrying
    # neither those nor a percentage is one nobody can generate, and it is worth saying so
    # by name: the alternative is nil reaching the rounding and a NoMethodError naming a
    # division, three files away from the lift that is actually wrong.
    def written_start(lift)
      return lift.top_weight if lift.top_weight

      raise ArgumentError, "#{Exercise[lift.exercise_id].name} is written as a #{lift.progression} lift " \
                           'with no top_weight to start from.'
    end

    # With no completed set the chart can read there is no max to take a percentage of, and
    # inventing one would write a whole week of loads off a guess, so the week refuses to
    # generate and says which movement is missing.
    def percent_of_max_weight(lift)
      exercise = Exercise[lift.exercise_id]
      max = exercise.estimated_max(account_id: @program.account_id)
      unless max
        raise ArgumentError, "No estimated max for #{exercise.name} yet, so #{lift.percent_of_max}% of it " \
                             'cannot be worked out. Log a completed set of it first.'
      end

      @equipment.round(max * lift.percent_of_max / 100.0)
    end

    # The written top_weight is where a lift starts and nothing more: once the movement has
    # been trained inside this block, the load comes from that session instead. So the first
    # week of a block, and any movement this block has never trained, generate at exactly
    # the number they were authored with, which is also what makes a block generatable out
    # of order.
    def progressed_weight(week, lift)
      sessions = previous_sessions(week, lift)
      return written_start(lift) if sessions.empty?

      Progression.next_top_weight(sessions.first[:top_weight], sessions.map { |s| s[:outcome] },
                                  increment: load_increment)
    end

    # The size of one step, which is the smallest change the rack can actually make. Five
    # pounds is 2.5s on each side, the lightest pair in Plates::DEFAULT_INVENTORY, and the
    # number Rounding is built around. It is read here, in one place, rather than at the
    # call site, because equipment is about to become a property of an account (#64): when
    # it is, this is the method that asks the account what it can load, and the rule above
    # goes on reading "one increment" without changing.
    def load_increment
      Rounding::INCREMENT
    end

    # This block's sessions of this movement, most recent first, each as the load it
    # prescribed and what became of it. The rules ask two short questions of them: what
    # happened last time, and whether the attempt before that also fell short.
    #
    # Matched on the movement rather than on the program lift row, because every week writes
    # lift rows of its own and they are the same lift only in that they name the same
    # exercise. Confined to this block, because top_weight is the block's own starting point
    # and a lift that wants to carry strength across blocks is written as a percentage of a
    # max, which spans them by construction.
    def previous_sessions(week, lift)
      previous_workouts(week, lift).filter_map { |workout| session(workout, lift) }
    end

    # One session as the rules read it: the load it asked for, restated in the lift's own
    # units, and whether it was met, fallen short of, or never trained. Warmups are left
    # out -- they are a ramp to the top set and say nothing about whether the top set was
    # there -- and a session with nothing planned in it is not a prescription at all.
    def session(workout, lift)
      sets = Set.where(workout_id: workout.id, exercise_id: lift.exercise_id, is_warmup: false).all
      heaviest = sets.select(&:planned_weight).max_by(&:planned_weight)
      return nil unless heaviest

      { top_weight: written_top(heaviest, lift), outcome: Progression.outcome(sets.map(&:values)) }
    end

    # The previous session's top set, restated at the rep count this lift is written in. A
    # program that prefers threes generates a lift written as 4x5 to 155 as 4x3 to 165, so
    # the number on the set rows is not the number the lift was written with. Stepping
    # from it directly would put the load through the rep conversion a second time every
    # week and the prescription would run away from the lifter -- 155 became 180 in two
    # weeks of a block that was meant to add five pounds. Converted back through the same
    # chart that converted it out, so the step lands in the units it was written for.
    def written_top(set, lift)
      SetScheme.convert_weight(set.planned_weight, from_reps: set.planned_reps, to_reps: lift.reps)
    end

    # Every earlier session of this movement in the block, latest first. Not limited to the
    # two the strike count needs: weeks nobody trained are skipped when counting, so the
    # second attempt can sit any distance back, and a window wide enough to be safe is the
    # whole block anyway -- a handful of rows for a movement trained once a week.
    def previous_workouts(week, lift)
      lifted = Set.where(exercise_id: lift.exercise_id).select(:workout_id)
      Workout.where(account_id: @program.account_id, program_day_id: earlier_days(week), id: lifted)
             .order(Sequel.desc(:date), Sequel.desc(:id)).all
    end

    # The days of every earlier week of this block that was not a deload. Deload weeks are
    # passed over rather than progressed from: their loads are deliberately light, so a
    # block that stepped off one would carry the reduction into every week after it and
    # ratchet down a little each time it recovered.
    def earlier_days(week)
      weeks = @program.program_weeks_dataset.exclude(is_deload: true)
                      .where(Sequel[:number] < week.number).select(:id)
      ProgramDay.where(program_week_id: weeks).select(:id)
    end

    # Rep conversion is a main-work preference: accessories keep the reps they
    # were prescribed, so they are generated as if the program had no preference.
    def working_sets(lift, top)
      SetScheme.working_sets(
        sets: lift.sets,
        reps: lift.reps,
        top_weight: top,
        increment: @equipment.increment,
        preferred_reps: (@program.preferred_reps if lift.is_main),
        is_ascending: @program.is_ascending
      )
    end

    # Weight and reps start out equal to the planned values. Lifting the set as
    # written only flips is_completed; lifting it differently changes weight or
    # reps and leaves the planned columns behind as the record of the prescription.
    def insert_set(workout, lift, set, is_warmup:)
      Set.insert(
        workout_id: workout.id, exercise_id: lift.exercise_id,
        weight: set[:weight], reps: set[:reps], duration_seconds: set[:duration_seconds],
        planned_weight: set[:weight], planned_reps: set[:reps],
        # A set is done the way the lift that wrote it is done, so the two never disagree
        # about whether it was counted per side or held for time. Stored form rather than
        # the symbol: this is a dataset insert, which does not typecast, and Sequel reads a
        # symbol here as the name of a column.
        measure: Measured.stored(lift.measure), is_per_side: lift.is_per_side,
        is_warmup:, is_completed: false, is_barbell: lift.is_barbell,
        created_by_oauth_application_id: @created_by
      )
    end
  end
end

