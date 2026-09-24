# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec' # and its token minting, for the tool half; idempotent require
require_relative '../lib/tectonic/mcp'

# How many queries a page costs, and whether that number grows with what is on it. #234.
#
# Three pages issued one query per row. Measured on twelve workouts of twenty sets each:
# /workouts took 14, the workout record 13, and the set list 23. Each grew linearly, so a
# year of training on /workouts was a query per session.
#
# Nothing failed while that was true. Every page rendered, every assertion passed, and the
# suite has no other way to notice -- which is why this asserts the shape rather than a
# number. A page is rendered at two sizes and the counts must match: what matters is not
# that /workouts costs two queries but that it costs the same two when the account has
# trained for a year.
module QueryCount
  def app = Tectonic.app

  # A logger that keeps what it is told. Sequel wants the rest of the Logger interface and
  # never calls any of it here, which is what method_missing is for.
  class Tally
    STATEMENT = /SELECT|INSERT|UPDATE|DELETE/

    def initialize = @statements = []

    def info(message) = @statements << message

    def queries = @statements.count { |statement| statement.match?(STATEMENT) }

    def method_missing(_name, *_args) = nil

    def respond_to_missing?(*) = true
  end

  # Counts what reaches the database while the block runs. Sequel logs every statement it
  # executes, so this counts what was actually sent rather than what the code looks like it
  # should send -- which is the whole point, since an N+1 reads perfectly innocently at the
  # call site.
  def queries_while
    tally = Tally.new
    DB.loggers << tally
    yield
    DB.loggers.delete(tally)
    tally.queries
  end

  # What a seeded account is made of, so the fixture builders can be read without six
  # positional arguments between them.
  Fixture = Struct.new(:account_id, :movements, :days, :application_id)

  # The shapes a session comes in, in the proportions the reporting account actually holds,
  # and this is the whole of #593.
  #
  # The fixture used to insert every workout as `DB[:workouts].insert(account_id:, date:)` --
  # no `program_day_id` and no `name`. `Workout#label` is `name || program_day&.focus` and
  # `program_day` is a `many_to_one`, so Sequel answers a nil key with nil and issues no
  # query at all. Every ceiling in this file was therefore measured against the one kind of
  # session this app does not generate, and the per-row query the file exists to catch was
  # invisible to it from the day it was written. /workouts costs roughly 36 queries in
  # production against a ceiling of 10, and nothing here ever went red.
  #
  # So the sessions are generated ones now. Three in five carry a program day and no name of
  # their own, which is 32 of 54 on the account that reports these -- the proportion that
  # matters, because that is the branch that costs a query. One in five is a generated
  # session somebody renamed and one in five was logged by hand; production holds rather more
  # of the second and rather fewer of the first, and neither of those two shapes reaches the
  # association at all, so their exact share changes nothing a count can see. What would
  # change it is having none of the expensive shape, which is where this started.
  SHAPES = %i[generated generated generated renamed logged].freeze
  # Four days a week, the way a block is written, and the focus is what `label` reads.
  FOCUSES = ['Squat', 'Bench', 'Deadlift', 'Overhead press'].freeze

  # A session of `lifts` movements, four sets apiece, on its own workout. The movements are
  # shared across the sessions, which is what makes them worth returning: one of them is a lift
  # trained in every session, so its history page is `workouts * 4` sets long and grows with
  # the account the way a real one does.
  #
  # Everything this calls is prefixed `seeded_`, which is not decoration. Three other files
  # mix this module into a describe of their own to borrow `queries_while`, and a module
  # included second silently wins every name it shares with the one before it: `a_movement`
  # here took over `a_movement` in dating_a_session_by_when_it_happened_spec, and what a
  # reader saw was that spec's own helper raising ArgumentError on its own call. The prefix is
  # what stops the next helper added here from breaking a spec that never mentions it.
  def training(account_id, workouts:, lifts:)
    fixture = Fixture.new(account_id, nil, seeded_block(account_id), seeded_application)
    fixture.movements = Array.new(lifts) { |index| seeded_lift(fixture, index) }
    [Array.new(workouts) { |day| seeded_session(fixture, day) }, fixture.movements]
  end

  # The block the generated sessions hang off: three weeks of four days, started three weeks
  # ago so that it is a block that has finished.
  #
  # Finished on purpose. The front page calls `ProgramSchedule.ensure_ahead`, which writes the
  # sessions of whichever week covers today, so a live block would have this fixture
  # generating rows in the middle of a measurement and the two account sizes would not be
  # comparable. `Program#week_on` answers nil for a date past the last week, which costs two
  # queries and writes nothing -- the shape a real account in the gap between blocks is in.
  def seeded_block(account_id, weeks: 3, days_per_week: 4)
    program_id = DB[:programs].insert(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                      start_date: Date.today - (weeks * 7))
    (1..weeks).flat_map do |number|
      week_id = DB[:program_weeks].insert(program_id:, number:)
      Array.new(days_per_week) do |weekday|
        DB[:program_days].insert(program_week_id: week_id, weekday:, focus: FOCUSES[weekday])
      end
    end
  end

  # The client every row here is stamped with, which is what makes provenance cost anything.
  # `Presenter.provenance` reads `created_by_oauth_application&.name` on every set, every
  # workout and every movement of every payload, and against an unstamped fixture that is a
  # nil key and no query -- the same blind spot `label` had, in the surface #594 is about.
  def seeded_application
    DB[:oauth_applications].insert(name: 'Reading assistant', client_id: SecureRandom.uuid,
                                   client_secret: SecureRandom.hex, scopes: 'read write',
                                   redirect_uri: 'https://example.com/cb')
  end

  # One movement, and every third one was created by the assistant rather than typed in.
  # Production is 28 of 84, which is the shape `list_exercises` pays for once per row.
  def seeded_lift(fixture, index)
    DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id: fixture.account_id,
                          created_by_oauth_application_id: ((index % 3).zero? && fixture.application_id) || nil)
  end

  # One session of the shape its position gives it. Day 0 is a generated, unnamed one, so
  # every page and tool below that is handed `sessions.first` is handed the expensive case
  # rather than whichever one happened to be first.
  #
  # The sets all carry the creating application, because logging a set is what an assistant
  # connected to this thing spends its turns doing; the workout carries one only where it was
  # the assistant that opened it, which is the sessions nobody generated.
  def seeded_session(fixture, day)
    workout_id = seeded_workout(fixture, day, SHAPES[day % SHAPES.length])
    fixture.movements.each { |exercise_id| seeded_sets(fixture, workout_id, exercise_id) }
    workout_id
  end

  # The row itself: a program day unless nobody generated it, a name only where somebody
  # replaced the day's focus with one, and a creating client only where it was the assistant
  # that opened the session rather than the programme.
  def seeded_workout(fixture, day, shape)
    DB[:workouts].insert(
      account_id: fixture.account_id, date: Time.now - (day * 86_400),
      program_day_id: (fixture.days[day % fixture.days.length] unless shape == :logged),
      name: ('Squats and a walk home' if shape == :renamed),
      created_by_oauth_application_id: (fixture.application_id if shape == :logged)
    )
  end

  def seeded_sets(fixture, workout_id, exercise_id)
    4.times do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 135, reps: 5,
                       is_warmup: false, is_completed: true, is_barbell: true,
                       created_by_oauth_application_id: fixture.application_id)
    end
  end

  # What each page is allowed, so that "constant" cannot be satisfied by a page that is
  # constantly expensive. Generous on purpose: this is a guard against a per-row query coming
  # back, not a budget anybody should be tuning against.
  #
  # Single figures for the four session pages, and a higher one for the movement page, which
  # joined this file with #572 at twenty-one. That number is not what #572 did to it -- it is
  # what the page already was, and it is constant, which is the property this file exists to
  # protect. It draws a training max, an estimate off the whole set history, a goal, a rest,
  # and a progress chart that asks several questions of its own, and each of those is one query
  # whether the lifter has trained twice or two hundred times. Raising this to let a per-row
  # query in would be the misuse the paragraph above warns against; naming what a genuinely
  # heavy constant page costs is not, and the gap between 21 and 30 is deliberately too small
  # to absorb one -- the unfixed version of #572's eager load cost this page 100.
  #
  # The tools joined it with #594 and only one of them needs a number of its own. `/` costs
  # eight, `list_workouts` and `get_workout` eight each, `list_exercises` five: every one of
  # those sits under the default, which is the answer this file wanted and not one that was
  # arranged. Nothing here was raised to make a red spec pass, and the two that could not have
  # been -- 131 for `exercise_history` and 87 for `get_workout` on the large account before the
  # fix -- were not near any ceiling anybody would have written.
  #
  # `exercise_history` is the exception at twenty, and it is the movement page's argument in a
  # tool: it resolves a movement by name, reads a stated training max, estimates one off the
  # whole set history, asks the same question again over three separate windows for #307's
  # recent readings, and then fetches the sets with their movements and their sessions. Each of
  # those is one query whether the answer is eight sets or two hundred. Fourteen today, and the
  # gap to twenty is deliberately too small to absorb a per-row query: the default limit is 50
  # rows and MAX_LIMIT is 200, so anything walking an association per row lands at 64 or at
  # 214, not at 21. It was 611 at MAX_LIMIT before this, which is the largest single request
  # this app can be asked to serve.
  CEILINGS = Hash.new(10).merge('/exercises/:id' => 30, 'exercise_history' => 20).freeze

  def cost_of(path)
    queries_while { get path }
  end

  # A fresh account for each size, rather than one that grows: the small case must not be
  # measured against a query plan cache the large case warmed.
  def costs_for(workouts:, lifts:)
    account_id = login
    sessions, movements = training(account_id, workouts:, lifts:)
    pages_for(sessions.first, movements.first).merge(tools_for(account_id, sessions.first, movements.first))
  end

  # Exercise history joins the list with #572. It dates every row by the session the set came
  # from, and it walked `set.workout` per row to do it -- a query a set, a hundred of them for
  # a hundred squat sets, growing every session and never failing anything. The route eager
  # loads those sessions now, and asks for their completion stamps in the same load, because
  # the date on each row is the day the session was trained rather than the day it was
  # planned and `performed_on` will otherwise go and fetch that one session at a time.
  #
  # `/` is here since #593, and it was not before, which is why the calendar could hold the
  # same per-row query as the workouts list and never be asked about it. `Calendar.entries`
  # reads `label` on every session in the grid; a month of a four-day block is sixteen of
  # them. The front page is the most expensive page in this file for reasons that have
  # nothing to do with the grid -- see CEILINGS -- which is the other argument for measuring
  # it: a page nobody has counted is a page anything can be added to.
  #
  # `/exercises` is here for the same reason and was found the same way: its Source column
  # prints `provenance(exercise)`, which is the second many_to_one walk #593 turned up. It is
  # a page that grows with the library rather than with the training, which is slower but
  # does not stop.
  def pages_for(workout, movement)
    { '/' => cost_of('/'),
      '/workouts' => cost_of('/workouts'),
      '/exercises' => cost_of('/exercises'),
      'record' => cost_of("/workouts/#{workout}"),
      'sets' => cost_of("/workouts/#{workout}/sets"),
      'session' => cost_of("/workouts/#{workout}/session"),
      # Named as its path rather than as "exercise history", which is what it was called until
      # the MCP tools joined this file. There is a read tool called `exercise_history` and the
      # two are different surfaces answering the same question at different costs; two keys
      # differing by a space and an underscore, in a hash whose keys are also ceiling lookups,
      # is one typo away from a page being measured against a tool's allowance.
      '/exercises/:id' => cost_of("/exercises/#{movement}") }
  end

  # And the MCP surface, which is #594. `config.ru` named this risk in the paragraph about
  # the endpoint -- "an LLM drives that one, so nobody has watched its request pattern, and
  # its tools hold the same four connections every page does" -- and nobody had. A ceiling
  # that covers only the pages would not have stopped any of it, and will not stop the next
  # one.
  #
  # The four read tools that return rows. A tool answering with a number cannot hold a
  # per-row query, and the write tools are one row each by definition; these four are the
  # ones an assistant calls repeatedly in a conversation, and `exercise_history` at
  # `MAX_LIMIT` is the largest single request this app can be asked to serve.
  def tools_for(account_id, workout, movement)
    token = mint(scopes: ['read'], account_id:).raw
    name = DB[:exercises].where(id: movement).get(:name)
    { 'list_workouts' => tool_cost(token, 'list_workouts'),
      'get_workout' => tool_cost(token, 'get_workout', workout_id: workout),
      'exercise_history' => tool_cost(token, 'exercise_history', exercise: name),
      'list_exercises' => tool_cost(token, 'list_exercises') }
  end

  # One tool call, counted the way a page is. A refusal or a crash would come back as a
  # perfectly cheap response, so the result is read before the number is believed -- a
  # ceiling met by a tool that no longer works is worse than no ceiling.
  def tool_cost(token, name, **arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name:, arguments: } }.to_json
    response = nil
    count = queries_while { response = mcp.post('http://localhost/mcp', body, mcp_headers(token)) }
    answered!(name, response)
    count
  end

  def answered!(name, response)
    result = (JSON.parse(response.body)['result'] if response.status == 200)
    return if result && result['isError'] != true

    raise "#{name} did not answer: #{response.status} #{response.body}"
  end

  # A Rack::Test session of its own, because one session drives one app and `app` above is
  # the site. The MCP endpoint is mounted beside it in config.ru rather than routed through
  # it, so this is the same arrangement production has.
  def mcp
    @mcp ||= Rack::Test::Session.new(Tectonic::MCP.rack_app)
  end
end

describe 'what a page costs to render' do
  include Rack::Test::Methods
  include RouteOwnership
  include QueryCount

  # Two accounts, one with five times the training of the other. Separate accounts rather
  # than one that grows, so the small case cannot be measured against a warm query cache the
  # large case filled.
  #
  # The small one holds five sessions rather than two, which is one of each shape in SHAPES,
  # and that is a requirement rather than a round number. An eager load issues no second query
  # when every row's key is null, so an account whose sessions all happened to be generated
  # cost one query fewer than one that also held a hand-logged session -- a difference of one
  # that has nothing to do with per-row querying and everything to do with which sessions the
  # fixture happened to write. Two accounts can only be compared if they are made of the same
  # kinds of thing in different quantities, which is the point of the comparison.
  before do
    @small_costs = costs_for(workouts: 5, lifts: 3)
    @large_costs = costs_for(workouts: 25, lifts: 15)
  end

  # The assertion that matters, and the one a fixed number would not make: five times the
  # training must not cost five times the queries.
  #
  # Every surface is named at once rather than one assertion per surface stopping at the
  # first, which is what this was while it measured five pages and nothing else. It measures
  # ten surfaces now, and an N+1 is rarely alone -- #593 and #594 are the same mistake in six
  # places, and finding them one run at a time is six runs and six readings of the same
  # fixture. The failure a reader wants is the list.
  it 'does not grow with the amount of training on the page' do
    assert_empty @small_costs.keys.filter_map { |page| growth(page) }.join("\n")
  end

  def growth(page)
    return nil if @small_costs[page] == @large_costs[page]

    "#{page} costs #{@large_costs[page]} queries on a large account and " \
      "#{@small_costs[page]} on a small one, so it is querying per row"
  end

  # And a ceiling apiece, for the reason set out on CEILINGS. Listed together for the reason
  # above it.
  it 'stays inside what each page is allowed' do
    over = @large_costs.filter_map do |page, cost|
      "#{page} costs #{cost} queries, and is allowed #{QueryCount::CEILINGS[page]}" unless
        cost < QueryCount::CEILINGS[page]
    end
    assert_empty over.join("\n")
  end
end

