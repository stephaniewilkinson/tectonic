# frozen_string_literal: true

require 'bcrypt'
require 'date'
require_relative 'db'
require_relative 'clock'
require_relative 'equipment'
require_relative 'program_seed'
require_relative 'programs'
require_relative 'mcp/server'

class Tectonic < Roda
  # The account a directory reviewer signs in to. #683.
  #
  # Anthropic's connector review asks for "credentials for a fully populated account", and
  # a reviewer who connects and asks "what did I lift last week?" or "write me next week"
  # should get a real answer rather than an empty list. So this builds one: three weeks of
  # logged training before this one, including a bodyweight lift and a timed one, training
  # maxes, a goal, a plate rack, and a block whose current week has been generated.
  #
  # Filled through the same tools an assistant calls rather than by inserting rows, for two
  # reasons. The tools are what the reviewer will exercise, so populating through them is a
  # first rehearsal of exactly that. And they are the code that keeps up with the schema:
  # a hand-written insert list is the thing that silently goes stale three migrations later.
  #
  # Reset rather than created, and safe to run any number of times. Reviewers write to the
  # account -- that is the point of handing it over -- so the way back to a known state has to
  # be the same command as the way in. The account row itself is kept across a reset, along
  # with its connections and audit trail, so a reviewer's connector keeps working through it.
  module ReviewerAccount
    EMAIL = 'reviewer@tectonicplates.app'
    TIME_ZONE = 'America/Los_Angeles'
    MINIMUM_PASSWORD = 12

    # Three sessions a week. Each lift's top set climbs `step` pounds a week from `start`, so
    # exercise_history and block_progress have a trend to describe rather than a flat line.
    SESSIONS = {
      1 => ['Squat day', [
        { exercise: 'Back Squat', start: 225, step: 10, sets: 3, reps: 5 },
        { exercise: 'Bench Press', start: 165, step: 5, sets: 3, reps: 5 },
        { exercise: 'Plank', seconds: 60 }
      ]],
      3 => ['Pull day', [
        { exercise: 'Deadlift', start: 285, step: 10, sets: 1, reps: 5 },
        { exercise: 'Overhead Press', start: 105, step: 5, sets: 3, reps: 5 },
        { exercise: 'Pull-Up', sets: 3, reps: 8 }
      ]],
      5 => ['Volume day', [
        { exercise: 'Back Squat', start: 205, step: 10, sets: 3, reps: 8 },
        { exercise: 'Bench Press', start: 150, step: 5, sets: 3, reps: 8 },
        { exercise: 'Bent Over Row', start: 135, step: 5, sets: 3, reps: 8 }
      ]]
    }.freeze

    HISTORY_WEEKS = 3

    TRAINING_MAXES = { 'Back Squat' => 265, 'Bench Press' => 190, 'Deadlift' => 325, 'Overhead Press' => 125 }.freeze

    # Pairs of each plate, keyed by denomination: an ordinary garage rack.
    PLATES = { '45' => 4, '35' => 1, '25' => 1, '10' => 2, '5' => 1, '2.5' => 1 }.freeze

    # The account's training, children before parents. Everything here is rebuilt by
    # `populate`; anything not named -- the account row, its sign-in keys, its connections,
    # the audit log -- is the reviewer's and survives.
    TRAINING = %i[
      account_training_max_statements account_training_maxes account_goals
      account_exercise_rests account_plates account_dumbbell_plates
    ].freeze

    module_function

    # Creates or resets the account and returns its id. The password comes from the caller
    # and is never stored anywhere but as a hash.
    def reset!(password:, today: Clock.today(TIME_ZONE))
      raise ArgumentError, "a reviewer password needs at least #{MINIMUM_PASSWORD} characters" \
        if password.to_s.length < MINIMUM_PASSWORD

      DB.transaction do
        id = account(password)
        erase(id)
        populate(id, today)
        id
      end
    end

    # A verified account (status 2), so the reviewer is never asked to confirm an address
    # nobody reads, with the password set to whatever was given this time.
    def account(password)
      attributes = { password_hash: BCrypt::Password.create(password), status_id: 2, time_zone: TIME_ZONE }
      existing = DB[:accounts].where(email: EMAIL)
      return existing.get(:id).tap { existing.update(attributes) } unless existing.empty?

      DB[:accounts].insert(email: EMAIL, **attributes)
    end

    def erase(id) = doomed(id).each(&:delete)

    # Children before parents, as the foreign keys require. Each dataset is a lazy subquery
    # reaching up to the account, so deleting one level leaves the next still findable --
    # the programs go last because the weeks and days are found through them.
    def doomed(id)
      own = ->(table) { DB[table].where(account_id: id) }
      [DB[:sets].where(workout_id: own[:workouts].select(:id)),
       *%i[withings_workouts heart_rates health_metrics workouts].map(&own),
       *program_rows(own[:programs]), *TRAINING.map(&own), own[:exercises]]
    end

    def program_rows(programs)
      weeks = DB[:program_weeks].where(program_id: programs.select(:id))
      days = DB[:program_days].where(program_week_id: weeks.select(:id))
      [DB[:program_lifts].where(program_day_id: days.select(:id)), days, weeks, programs]
    end

    def populate(id, today)
      Equipment.replace(id, bar_weight: 45, plates: PLATES)
      context = MCP::RequestContext.new(account_id: id, email: EMAIL, scopes: %w[read write],
                                        application_id: nil, time_zone: TIME_ZONE)
      monday = today - ((today.wday - 1) % 7)
      HISTORY_WEEKS.times { |week| log_week(context, monday - (7 * (HISTORY_WEEKS - week)), week) }
      targets(context, today)
      block(context, id, monday)
    end

    def log_week(context, monday, week)
      SESSIONS.each do |weekday, (name, lifts)|
        date = (monday + weekday - 1).iso8601
        call(MCP::Tools::CreateWorkout, context, date:, name:)
        lifts.each { |lift| log_lift(context, date, lift, week) }
      end
    end

    # A loaded lift climbs, a bodyweight lift has no weight at all, and a timed one counts
    # seconds -- the three shapes a reviewer's questions can land on.
    def log_lift(context, date, lift, week)
      return call(MCP::Tools::CreateSet, context, **timed(date, lift)) if lift[:seconds]

      lift[:sets].times do |number|
        set = { exercise: lift[:exercise], date:, reps: lift[:reps], is_completed: true, rpe: 7 + number }
        set[:weight] = lift[:start] + (lift[:step] * week) if lift[:start]
        call(MCP::Tools::CreateSet, context, **set)
      end
    end

    def timed(date, lift)
      { exercise: lift[:exercise], date:, measure: 'time', duration_seconds: lift[:seconds], is_completed: true }
    end

    def targets(context, today)
      TRAINING_MAXES.each { |exercise, pounds| call(MCP::Tools::SetTrainingMax, context, exercise:, pounds:) }
      call(MCP::Tools::SetGoal, context, exercise: 'Back Squat', pounds: 285, by_date: (today + 84).iso8601)
    end

    # Block 0 starting this Monday, with this week's sessions generated, so get_program,
    # block_progress and generate_program_week all have a current week to work on.
    def block(context, id, monday)
      program = ProgramSeed.seed(id, start_date: monday)
      call(MCP::Tools::GenerateProgramWeek, context, program_id: program.id, week: 1)
    end

    # A tool that refuses or crashes here means the account is not what a reviewer will be
    # told it is, so it stops the reset -- and the transaction around it -- rather than
    # handing over half an account.
    def call(tool, context, **arguments)
      response = tool.call(server_context: context, **arguments)
      return response unless response.error?

      raise "#{tool.tool_name} refused while building the reviewer account: #{response.content.first[:text]}"
    end
  end
end

