# frozen_string_literal: true

require_relative 'db'
require_relative 'programs'
require_relative 'program_generator'
require_relative 'error_reporting'
require_relative 'workouts'

class Tectonic < Roda
  # Sessions exist without anybody asking for them. #411.
  #
  # A week of workouts only existed when somebody said "generate week 3" -- and an assistant
  # only acts when it is messaged. So the way you found out there was no session for today was
  # by opening the app on Monday morning and finding nothing there, which is the worst possible
  # moment and the worst possible way.
  #
  # #411 argues for dropping the programme screens on the grounds that a block is an authoring
  # artifact rather than something a lifter reads, and it names this as the dependency that
  # creates -- and says the app should do it **regardless of whether the rest is ever done**.
  # It is right, so this landed first and on its own.
  #
  # **Lazily, on the way in, rather than on a schedule.** A cron job is the obvious shape and
  # needs a scheduler this app does not have, which would be infrastructure to provision before
  # a line of it worked. Generating when somebody arrives gets the same result for anybody who
  # opens the app -- and a session nobody ever looks for is a session whose absence nobody ever
  # notices. It also cannot drift out of step with the clock the way a cron entry can.
  #
  # **Two weeks rather than one**, which is the other half of what #411 asks for: the week in
  # progress and the one after it, so next week's sessions are already there to be looked at,
  # edited, or rescheduled. Later weeks get edited as data arrives, which is expected and is
  # why this does not run to the end of the block.
  module ProgramSchedule
    # How far ahead to keep sessions written. One week beyond the current one.
    WEEKS_AHEAD = 1

    module_function

    # Writes any missing session for the current week and the next, for every block this
    # account has that is running today.
    #
    # A command, answering nothing. The generator is idempotent on (account, program day) and
    # returns the workout that day already wrote rather than a second one, so counting what it
    # handed back would report work it did not do -- and there is no cheap honest count to
    # return instead. What was written is in the workouts table, which is where a caller that
    # cares should look.
    #
    # Safe to call on every page load, which is what lets it be lazy at all: after the first
    # visit of a week it is a handful of indexed lookups that find everything already there.
    #
    # A handful was the claim and it had stopped being true: #595 measured 25 queries on a
    # visit that wrote nothing, on the front page and on every login. Each running block's
    # weeks and days are loaded once here now rather than asked after a row at a time; a block
    # that has not started is not read at all; and each week asks once which of its days
    # already have a session. What it reads is still the sessions themselves -- nothing here
    # remembers having generated anything, because the workouts table is the only record of
    # that and a second one would be something to disagree with.
    #
    # Nothing here may raise into a request. Somebody arriving has come to look at their
    # training, and a block the generator refuses -- an unloadable percentage, a movement that
    # was deleted -- must not turn the front page into a 500 on the way past. The failure is
    # reported and the page renders whatever does exist, which is the same trade config.ru
    # already makes for error reporting itself.
    def ensure_ahead(account_id, today = Date.today)
      Program.where(account_id:).where { start_date <= today }.eager(program_weeks: :program_days)
             .all.each { |program| fill(program, today) }
      nil
    rescue StandardError => e
      ErrorReporting.note('program_schedule', account_id:, today: today.to_s)
      report(e)
      nil
    end

    # The weeks a block should have on the floor today. Nothing where the block has not started
    # or has finished -- a block whose last week is behind us is history, and writing sessions
    # past its end would invent training nobody planned.
    def fill(program, today)
      current = program.week_on(today)
      return unless current

      generator = ProgramGenerator.new(program)
      (current.number..(current.number + WEEKS_AHEAD)).each do |number|
        generator.generate(number) if program.week(number)
      end
    end

    def report(exception)
      return unless ErrorReporting.on?

      Sentry.capture_exception(exception)
    rescue StandardError
      # Reporting a failure must never become a second one, on the request path least of all.
    end
  end
end

