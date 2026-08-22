# frozen_string_literal: true

require_relative 'db'
require_relative 'programs'
require_relative 'program_weeks'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'mcp/request_context'
require_relative 'mcp/tools/program_writer'
require_relative 'mcp/tools/support'
require_relative 'mcp/tools/delete_program_lift'

class Tectonic < Roda
  # The web side of editing a programme, written on top of the same writer the MCP tools
  # use rather than beside it.
  #
  # That writer already knows the rules: a lift is priced in pounds or as a percentage and
  # never both, a position renumbers its whole day so no two lifts claim one place, a
  # weekday is 0 to 6 and anything else is refused by name. Writing a second implementation
  # for the browser would mean two sets of rules drifting apart, and the one a person uses
  # would be the one that drifted -- an assistant's calls are covered by specs in a way a
  # form never quite is.
  #
  # What the browser needs that MCP does not is a way to fail: a tool raises a Refusal the
  # model reads, a form wants a message next to the field. `attempt` is the whole of that
  # translation.
  class ProgramEditor
    # The writer resolves exercises through an account-scoped context. A signed-in account
    # is one, so the web builds the same object the MCP endpoint builds from a token --
    # no scopes, because a person in their own browser is not acting under a grant, and no
    # application, because nothing they create here was created by an assistant.
    def initialize(account_id)
      @account_id = account_id
      @context = MCP::RequestContext.new(account_id:, email: nil, scopes: [], application_id: nil)
    end

    attr_reader :account_id

    # What the last edit did to the session its day had already generated: :rewritten,
    # :lifted where there was work in it, or :none where there was no session to touch.
    attr_reader :session

    # The blocks this account has written, newest first.
    def programs
      Program.where(account_id:).reverse(:id).all
    end

    # One block, or nil when it is not this account's. Every route goes through here, so a
    # guessed id resolves to nothing rather than to somebody else's training.
    def program(id)
      Program.where(id:, account_id:).first
    end

    # A lift, reached through the block that owns it, so the same is true one level down.
    def lift(program, id)
      return unless program

      ProgramLift.where(id:)
                 .where(program_day_id: ProgramDay.where(program_week_id: program.program_weeks_dataset.select(:id))
                                                  .select(:id))
                 .first
    end

    # Runs a write and answers [ok, message]. A Refusal is the writer saying no in words
    # meant to be read, so it is passed through to the page rather than turned into a 500.
    def attempt
      yield
      [true, nil]
    rescue MCP::Tool::Refusal => e
      [false, e.message]
    end

    # Starts a block with its first week, because a block with no weeks has nothing to
    # show and nowhere to add a day.
    def create_program(name:, start_date:)
      DB.transaction do
        program = Program.create(account_id:, name: name.to_s.strip, start_date:,
                                 preferred_reps: nil, is_ascending: true)
        ProgramWeek.create(program_id: program.id, number: 1)
        program
      end
    end

    def add_week(program, copy_from: nil)
      source = copy_from && program.week(copy_from.to_i)
      number = (program.program_weeks_dataset.max(:number) || 0) + 1
      return ProgramWeek.create(program_id: program.id, number:) unless source

      copy_week(program, source, number)
    end

    # A new week made of the same days and lifts as an existing one, which is how a block
    # is actually written: week two is week one again, a little heavier.
    def copy_week(program, source, number)
      DB.transaction do
        week = ProgramWeek.create(program_id: program.id, number:, is_deload: false)
        source.program_days.each { |day| copy_day(week, day) }
        week
      end
    end

    def copy_day(week, source)
      day = ProgramDay.create(program_week_id: week.id, weekday: source.weekday, focus: source.focus)
      source.program_lifts.each { |lift| ProgramLift.create(program_day_id: day.id, **copied(lift)) }
      day
    end

    # Everything about a lift except which day it belongs to.
    def copied(lift)
      { exercise_id: lift.exercise_id, position: lift.position, sets: lift.sets, reps: lift.reps,
        top_weight: lift.top_weight, percent_of_max: lift.percent_of_max,
        progression: lift.progression, is_barbell: lift.is_barbell, is_main: lift.is_main,
        note: lift.note }
    end

    def add_day(week, weekday:, focus: nil)
      MCP::Tools::ProgramWriter.day(@context, week, { weekday: weekday.to_i, focus: })
    end

    def add_lift(day, attributes)
      MCP::Tools::ProgramWriter.lift(@context, day, symbolize(attributes)).tap { refresh_session(day) }
    end

    # An edit to one lift: the load, the movement, the sets and reps. This is what a lifter
    # actually does between weeks, so it is the one path worth making short.
    def update_lift(lift, attributes)
      written = symbolize(attributes)
      whole = merged(lift, written)
      shape = MCP::Tools::ProgramWriter.shape_of(whole, lift.exercise)
      MCP::Tools::ProgramWriter.check_load(whole, shape)
      lift.update(**written.slice(:sets, :reps, :top_weight, :percent_of_max, :note),
                  progression: MCP::Tools::ProgramWriter.progression_for(whole, shape))
      refresh_session(lift.program_day)
    end

    # Deletion closes the gap the lift leaves, so positions stay 0..n-1 and the session
    # order after a removal reads the way it did before one. Reusing the MCP tool's own
    # step rather than repeating it, for the same reason the rest of this class does.
    def remove_lift(lift)
      day = lift.program_day
      DB.transaction { MCP::Tools::DeleteProgramLift.close_gap(lift, day) }
      refresh_session(day)
    end

    # An edit to the plan reaches the session the plan already wrote, so a lifter who
    # changes a load on Tuesday does not open Wednesday's session and find the old one.
    # A session with anything lifted in it is left alone, and the page says so rather than
    # failing: the edit itself was still wanted.
    def refresh_session(day)
      @session = MCP::Tools::SessionRefresh.apply(day)
    end

    # The row as it will be once the edit lands, which is what the pricing rule has to be
    # checked against -- an edit that sets a percentage without clearing the pounds is
    # refused rather than written into a state the generator cannot read.
    def merged(lift, attributes)
      { sets: lift.sets, reps: lift.reps, duration_seconds: lift.duration_seconds,
        top_weight: lift.top_weight, percent_of_max: lift.percent_of_max,
        is_weighted: lift.is_weighted, measure: lift.measure,
        is_per_side: lift.is_per_side }.merge(attributes)
    end

    # Form values arrive as strings keyed by strings; blank means "not given" rather than
    # zero, which is the difference between clearing a price and setting it to nothing.
    def symbolize(attributes)
      attributes.to_h.each_with_object({}) do |(key, value), clean|
        clean[key.to_sym] = value.to_s.strip.empty? ? nil : numeric(value)
      end
    end

    def numeric(value)
      Float(value.to_s, exception: false)&.then { |number| (number % 1).zero? ? number.to_i : number } || value
    end
  end
end

