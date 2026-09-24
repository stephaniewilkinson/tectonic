# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'backfilling_what_the_watch_recorded_spec' # and the walk that leaves the proposals
require_relative 'query_count_spec' # and the logger that counts what a page actually sends

# Reaching the backfill's review list without having just run a rake task. #534.
#
# The screen has worked since #532 and nothing linked to it, so the only route in was to
# still have `withings:backfill`'s output on screen. A lifter who ran it, closed the
# terminal and came back on Sunday could reach their own hundred questions only by
# remembering a URL -- which is a feature that exists for the operator and not for the
# lifter, and those are the same person only until they are not.
#
# What is asserted here is the decision as much as the wiring, because the decision is the
# part a later change could undo without anything going red. Three claims:
#
#   the doorway is on /workouts and only while there is something behind it
#   the nav does not move, ever, whether or not anything is waiting
#   the permanent address is in settings, beside the connection that produces the questions
#
# And the relationship between the two doors, which is the other half of the ticket: the
# record page's prompt and this list are one queue seen from two angles, and each now says
# so about the other.
#
# **Nothing here calls Withings**, as the forward flow's and the backfill's specs do not.
# The fixture's fetch is stubbed and the page views are asserted to reach nobody at all --
# which is the property that makes a count on an unrelated page view safe in the first
# place. A doorway that fetched would be one page view standing on a hundred API calls.
module FindingTheQuestions
  include Backfilling

  # A history already walked, leaving `count` sessions each with a question on it. Spread a
  # day apart so no activity is a plausible candidate for its neighbour's session -- what is
  # being set up is a queue of unambiguous proposals, not the ambiguity the matcher's own
  # spec is about.
  def questions_waiting(count)
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @sessions = Array.new(count) { |day| trained_session(@account_id, started_at: @at - (day * 86_400)) }
    backfill(@account_id, answering(*activities_for(count)))
  end

  def activities_for(count)
    Array.new(count) { |day| activity(id: "w-#{day}", starts: @at - (day * 86_400) + 60, minutes: 48) }
  end

  # Every question answered, which is the state each claim about an empty queue needs. Yes
  # rather than no, because a confirmation leaves the row alive and matched while a dismissal
  # also stamps the session -- and what is being set up here is "there is nothing left to
  # ask", not "the lifter refused to be asked".
  def answer_them_all
    @sessions.each_with_index do |workout_id, day|
      Tectonic::WithingsAnswers.confirm(account_id: @account_id, workout_id:, external_id: "w-#{day}")
    end
  end

  # Every question but the one on the first session, which is what leaves a record page as the
  # last question standing -- the state where a prompt that counted itself would claim there
  # was one more somewhere else.
  def answer_all_but_the_first
    @sessions.drop(1).each_with_index do |workout_id, index|
      Tectonic::WithingsAnswers.confirm(account_id: @account_id, workout_id:, external_id: "w-#{index + 1}")
    end
  end

  # A page view with Withings made unreachable. Every call this app makes to them goes
  # through `post`, so raising there catches a fetch wherever it was started from -- which is
  # stronger than stubbing `workouts`, since a doorway that grew its own request would not
  # necessarily go through that one.
  def without_withings(&)
    Tectonic::Withings.stub(:post, ->(*, **) { raise 'a page view reached Withings' }, &)
  end

  def nav_links = last_response.body[%r{<nav\b.*?</nav>}m].to_s.scan(/<a\b[^>]*>/)

  # The statements themselves rather than how many of them there were. Counting queries
  # cannot tell a count apart from a load -- `waiting` costs three queries whether it returns
  # one proposal or eighty -- and the difference that matters here is how many rows come back
  # over the wire, which only the SQL says.
  def statements_while
    sent = []
    logger = Object.new
    logger.define_singleton_method(:info) { |message| sent << message }
    logger.define_singleton_method(:method_missing) { |*| nil }
    logger.define_singleton_method(:respond_to_missing?) { |*| true }
    DB.loggers << logger
    yield
    DB.loggers.delete(logger)
    sent.grep(/SELECT|INSERT|UPDATE|DELETE/)
  end

  def doorways = last_response.body.scan(%r{<a\b[^>]*href="/workouts/withings"})
end

describe 'the way in to the review list, on the page the questions are about' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { questions_waiting(3) }

  # The doorway, and the whole of what #534 is about. The workouts list is where the
  # questions' own subject matter is -- every one of them is about a session below it -- and
  # it is the page somebody opens when they sit down to deal with their training.
  it 'offers a way in from the workouts list while questions are waiting' do
    get '/workouts'

    refute_empty doorways
  end

  # The count in the sentence rather than a bare link, because the lifter has to be able to
  # decide whether this is worth a sitting before spending a page load finding out.
  it 'says how many are waiting before anybody clicks' do
    get '/workouts'

    assert_includes last_response.body, 'may have recorded 3 of the sessions below'
  end

  # The other half of "whether it shows when nothing is waiting", answered no. A queue is not
  # a destination: an empty one needs no door, and a line saying so would be the clutter a
  # permanent nav entry was rejected for, moved somewhere cheaper.
  it 'says nothing on the workouts list once they are all answered' do
    answer_them_all
    get '/workouts'

    assert_empty doorways
  end
end

describe 'the nav, which this deliberately does not touch' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { questions_waiting(3) }

  # The decision, pinned. A nav entry was the obvious answer and is the wrong one: permanent,
  # it is carried on every page by every lifter to point at a screen that is empty except for
  # the few days after a backfill, in a nav that already wraps to two rows between 640 and
  # 840px. Conditional, it is worse -- people learn where things are by position, and an entry
  # that comes and goes moves every entry after it, so `settings` is fourth on Tuesday and
  # fifth on Sunday.
  #
  # Asserted as "the nav is identical either way" rather than as a count of links, so it
  # cannot be satisfied by a nav that happens to have seven of them for some other reason.
  it 'is exactly what it was, waiting or not' do
    get '/workouts'
    with_questions = nav_links
    answer_them_all
    get '/workouts'

    assert_equal nav_links, with_questions
    assert_empty nav_links.grep(%r{/workouts/withings})
  end
end

describe 'the permanent address of the review list' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { questions_waiting(3) }

  # A different job from the prompt on /workouts, and it needs a different place. A screen
  # findable only while it has work on it cannot be gone back to, and a lifter who wants to
  # check whether they finished has nowhere to look. It lives with the connection that
  # produces the questions, where nothing moves when it appears.
  it 'is in the settings block that owns the connection' do
    get '/settings'

    refute_empty doorways
  end

  # And it says the screen is empty rather than going quiet, because unlike the prompt on
  # /workouts this link is always rendered -- so silence beside it would read as a broken
  # count rather than as nothing to do.
  it 'says nothing is waiting rather than disappearing' do
    answer_them_all
    get '/settings'

    refute_empty doorways
    assert_includes last_response.body, 'nothing is waiting for an answer'
  end
end

describe 'the sentence the review list opens with' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  # The noun was pluralised against the count and the verb was not, so one proposal read
  # "1 session from your history overlap something your watch recorded". One is not an edge
  # case here: it is where every queue ends, reached by answering all but the last question,
  # so the broken reading was waiting at the moment the page was nearly done with the lifter.
  it 'agrees its verb with a single session' do
    questions_waiting(1)

    get '/workouts/withings'

    assert_includes last_response.body, '1 session from your history'
    assert_includes last_response.body, 'overlaps something your watch recorded'
  end

  it 'still reads as plural for more than one' do
    questions_waiting(3)

    get '/workouts/withings'

    assert_includes last_response.body, '3 sessions from your history'
    assert_includes last_response.body, 'overlap something your watch recorded'
  end
end

describe 'what a doorway to the review list asks Withings' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { questions_waiting(3) }

  # The constraint that makes any of this safe to put on pages that have nothing to do with
  # Withings. The review screen reads rows the backfill already wrote, and so does every
  # doorway to it: a nav count that triggered an API call would be a page view standing on a
  # hundred Withings calls, and a throttle is the one failure these pages cannot render.
  it 'asks them nothing at all' do
    without_withings { get '/workouts' }

    assert_equal 200, last_response.status
    without_withings { get '/settings' }

    assert_equal 200, last_response.status
  end
end

describe 'a lifter with no questions waiting and no watch' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { @account_id = login }

  # The common case, and the one the nav entry would have taxed: somebody who owns no watch
  # should be told nothing about Withings on a page about their training.
  it 'is told nothing about matches on the workouts list' do
    get '/workouts'

    assert_empty doorways
    refute_includes last_response.body, 'your watch'
  end

  # Nor in settings, where an unconnected account is shown how to connect and nothing else.
  # The link belongs to the connection, so it arrives with one.
  it 'is offered the connection in settings rather than the review list' do
    get '/settings'

    assert_empty doorways
  end
end

describe 'the record page and the review list as one queue' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions

  before { questions_waiting(3) }

  # Until this, nothing on a record page admitted that ninety more were waiting elsewhere, so
  # the honest reading of the prompt was that one stray Tuesday had a question on it. A lifter
  # would answer that one and leave the rest to be found by accident.
  it 'tells a record how many other sessions are waiting on the same question' do
    get "/workouts/#{@sessions.first}"

    assert_includes last_response.body, '2 other sessions'
    refute_empty doorways
  end

  # It counts the others and not itself. A prompt that counted the session on screen would
  # tell somebody with one question left that there was one elsewhere, and send them to a list
  # holding only the row they were already looking at.
  it 'does not count the session being looked at' do
    answer_all_but_the_first
    get "/workouts/#{@sessions.first}"

    assert_includes last_response.body, 'Was that this session?'
    refute_includes last_response.body, 'waiting on the same question'
  end

  # And the list says the same thing back, which is what makes the pair legible as one queue
  # rather than as two chores that happen to look alike. The date on each row already goes to
  # the session; this is what stops finding the same question there being a surprise.
  it 'tells the list that a record is the other way to answer' do
    get '/workouts/withings'

    assert_includes last_response.body, 'answered on the session&rsquo;s own record'
  end
end

describe 'what knowing the count costs a page that is not about Withings' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingTheQuestions
  include QueryCount

  # The assertion the ticket actually turns on, and the one a query count cannot make.
  # `waiting(account_id).length` costs three queries whether there is one proposal or eighty,
  # so counting statements would call it constant -- while it loaded every proposal, every
  # session behind them and every set stamp of all of those, then reduced the lot to sentences
  # nobody was going to read. What separates a count from a load is the SQL, so that is what
  # is read.
  it 'asks the database for a number rather than for the proposals' do
    questions_waiting(3)
    sent = statements_while { Tectonic::WithingsProposals.waiting_count(@account_id) }

    assert_equal 1, sent.length, "one count should be one query, not:\n  #{sent.join("\n  ")}"
    assert_match(/count\(\*\)/i, sent.first)
    assert_match(/withings_workouts/, sent.first)
  end

  # And the page-level guard beside it, which is the weaker claim of the two and worth having
  # anyway: it is what would go red if a future doorway started asking something per proposal
  # -- the session behind each one, say, to put a date in the sentence.
  it 'does not grow with the number of questions waiting' do
    questions_waiting(1)
    one = queries_while { get '/workouts' }
    questions_waiting(12)
    twelve = queries_while { get '/workouts' }

    assert_equal one, twelve, "the workouts list costs #{twelve} queries with twelve proposals " \
                              "and #{one} with one, so it is reading per proposal"
  end
end

describe 'the index that makes the count worth asking for' do
  # Read out of the catalogue rather than asserted through a plan -- a planner on a table of
  # twelve rows will scan it whatever indexes exist, so an EXPLAIN here would assert the size
  # of the fixture rather than the shape of the schema.
  #
  # 042's `(account_id, started_at)` would serve this query as a prefix and read every activity
  # the account has ever had to test three columns it does not carry; 043's index leads with
  # `proposed_workout_id` and cannot find one account's rows at all. What is asserted is the
  # partial one: keyed on the account, holding only the rows that are still questions, and
  # therefore empty for everybody who has answered them. Postgres will only reach for it while
  # its predicate covers what `WithingsProposals.outstanding` asks, so the columns are named
  # here -- a condition dropped from either side turns the count back into a scan with every
  # other spec still green.
  it 'has an index holding only the questions still open' do
    definitions = DB[:pg_indexes].where(tablename: 'withings_workouts').select_map(:indexdef)
    partial = definitions.grep(/WHERE/).grep(/\(account_id\)/)

    refute_empty partial, "no partial index keyed on the account:\n  #{definitions.join("\n  ")}"
    %w[workout_id IS NULL dismissed_at proposed_workout_id IS NOT NULL].each do |fragment|
      assert(partial.any? { |definition| definition.include?(fragment) },
             "the waiting index does not mention #{fragment}: #{partial.join(', ')}")
    end
  end
end

