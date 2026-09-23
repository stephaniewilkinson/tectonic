# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'finding_the_questions_waiting_spec' # and the queue, its two doorways, and the walk behind them

# A proposal whose session, or whose activity, has since been answered by something else. #555.
#
# ## One root, three failures
#
# `proposed_workout_id` is the app's open question: *this activity looks like that session,
# ask about it*. Nothing ever gave one up. `WithingsProposals.outstanding` asks whether the
# activity carrying the question has been claimed or refused, and never whether the session
# it names has been answered by somebody else in the meantime -- so a proposal can go on
# being a question about a session that has had its answer for months.
#
# The three ways that showed up are three describes below, and they are worth keeping apart
# because each of them is a different lie told to a different reader:
#
#   the badge   -- the workouts list and the settings link count a question nobody can answer
#   the button  -- "Yes" posts, `confirm` refuses it, and the route redirects as though it
#                  had worked, so the row comes back unchanged and the lifter taps it again
#   the walk    -- `proposed_workout_id` is unique, and a later run picking a second activity
#                  for a session whose slot is still held raises out of `pair` mid-walk,
#                  after the API budget is spent
#
# **Nothing here calls Withings**, as the forward flow's specs and the backfill's do not.
# Every fetch is stubbed; a suite that reached the network would be a suite that fails on a
# train, and one backfill spec that reached it would be a year of requests per run.
module AlreadyAnswered
  include FindingTheQuestions

  # The stranding #555 opens with, built in the order it actually happens.
  #
  # A backfill offers `backfilled` to the session. A second recording of the same afternoon
  # turns up afterwards -- a phone listening as well as the watch, or an activity the lifter
  # split in two in the Withings app -- and that is the one the lifter says yes to. The
  # session now has its answer and `backfilled` still names it, unclaimed and un-refused.
  def a_session_matched_to_the_other_recording
    a_session_with_a_proposal
    answered_from_its_own_record
  end

  def answered_from_its_own_record
    Tectonic::WithingsWorkouts.store(@account_id, activity(id: 'confirmed', starts: @at + 120, minutes: 45))
    Tectonic::WithingsWorkouts.confirm(account_id: @account_id, workout_id: @workout_id,
                                       external_id: 'confirmed')
  end

  def a_session_with_a_proposal
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
    backfill(@account_id, answering(backfilled))
  end

  # The same state as a database written before any of this was fixed carries it, put there
  # with one `UPDATE` because nothing in the app produces it any more: the answer that used
  # to strand a proposal now withdraws it in the same transaction.
  #
  # Written out rather than left to the fixture above on purpose. The queue has to be honest
  # about the rows that were stranded while it was possible -- they are sitting in the
  # reporting account's database now, and no future answer will ever visit them again -- and
  # a spec that only ever built the state through today's code would be asserting that the
  # cure works, twice, and nothing at all about the filter.
  def stranded_the_way_the_database_holds_it
    DB[:withings_workouts].where(external_id: 'backfilled').update(proposed_workout_id: @workout_id)
  end

  def backfilled = activity(id: 'backfilled', starts: @at + 60, minutes: 48)

  # Two more recordings of the same afternoon, stored and never offered to anything. One
  # covers less of the session than the proposal does and one covers more, which is what
  # decides whether `best` reaches for the row already holding the proposal or for a free
  # one -- and those are two different ways for a write to find the slot taken.
  def second_recording = activity(id: 'second', starts: @at + 120, minutes: 45)

  def fuller_recording = activity(id: 'fuller', starts: @at, minutes: 52)

  # A queue with one question on it, answered from somewhere else, and the row left behind the
  # way a database written before this fix carries it.
  def a_queue_holding_an_old_stranded_proposal
    a_session_matched_to_the_other_recording
    stranded_the_way_the_database_holds_it
  end

  # The review list as a lifter is actually holding it when they tap a question nobody can
  # answer: drawn while the question was open, with the token that belongs to that drawing,
  # and left on screen while the session was answered from its own record.
  def a_stale_queue_page
    a_session_with_a_proposal
    @token = token_for_form('/workouts/withings', "/workouts/#{@workout_id}/withings/match")
    answered_from_its_own_record
    stranded_the_way_the_database_holds_it
  end

  def tap_yes(back: 'proposals')
    post "/workouts/#{@workout_id}/withings/match",
         { '_csrf' => @token, 'activity' => 'backfilled', 'back' => back }
  end

  # Two walks at once, which is the only way a live proposal can be in place by the time this
  # one writes: `standing` looked, found nothing, and the other walk wrote before the update
  # ran. The stub is that other walk. There is no way to hold one process still inside a
  # single statement, and the state it produces -- a session whose slot is taken, reached by
  # code that believed it was free -- is exactly what the two halves of the guard are for.
  def offer_anyway
    session = Tectonic::WithingsBackfill.sessions(@account_id).first
    Tectonic::WithingsWorkouts.stub(:standing, nil) do
      Tectonic::WithingsBackfill.offer(@account_id, session, [])
    end
  end

  def proposal_on(external_id) = DB[:withings_workouts].where(external_id:).get(:proposed_workout_id)

  def matched_to(external_id) = DB[:withings_workouts].where(external_id:).get(:workout_id)
end

describe 'a session matched to the other recording of the same afternoon' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before { a_session_matched_to_the_other_recording }

  # The cure, at the moment the stranding used to happen. The lifter answered a question
  # about this session; the backfill's proposal was a question about this session; and there
  # is no reading of "yes" under which the second one is still open.
  it 'withdraws the question the backfill left about it' do
    assert_nil proposal_on('backfilled')
  end

  # And the yes itself is untouched, which is the thing the withdrawal must not cost. The row
  # the lifter confirmed keeps its session, and the row that was proposed keeps everything
  # except the promise it can no longer keep -- it is still stored, still un-refused, and free
  # to be offered to some other session it overlaps.
  it 'leaves the match it just made, and the activity it withdrew, both intact' do
    assert_equal @workout_id, matched_to('confirmed')
    assert_nil matched_to('backfilled')
    assert_nil DB[:withings_workouts].where(external_id: 'backfilled').get(:dismissed_at)
  end
end

describe 'the count and the list, with a proposal stranded before any of this was fixed' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before { a_queue_holding_an_old_stranded_proposal }

  # The fixture itself, pinned, because every claim in this describe and the next is about
  # this state and a setup that stopped producing it would make the lot pass for no reason.
  it 'has a proposal standing on a session that has its answer' do
    assert_equal @workout_id, proposal_on('backfilled')
    assert_equal @workout_id, matched_to('confirmed')
  end

  # The count #534 put on the workouts list, and the number it is entitled to print. A
  # question is a question about a session; a session that has been answered has none left,
  # whatever rows are still lying about with its id on them.
  it 'counts no question about a session that already has its answer' do
    assert_equal 0, Tectonic::WithingsProposals.waiting_count(@account_id)
  end

  # And the list behind the count says the same, because the two are one dataset and #534's
  # whole argument for that is a badge saying one over a screen listing none.
  it 'lists nothing on the review screen either' do
    get '/workouts/withings'

    assert_includes last_response.body, 'Nothing is waiting'
  end
end

describe 'the two doorways to a queue whose last question was answered elsewhere' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before { a_queue_holding_an_old_stranded_proposal }

  # The doorway is the visible half of the failure: a line on a page about training, about a
  # question nobody can answer, that no amount of answering will take away.
  it 'takes the doorway back off the workouts list' do
    get '/workouts'

    assert_empty doorways
  end

  # Settings keeps its link either way -- it is the permanent address -- so what has to
  # change there is the sentence beside it.
  it 'tells settings there is nothing waiting for an answer' do
    get '/settings'

    assert_includes last_response.body, 'nothing is waiting for an answer'
  end
end

describe 'a yes about a session that has already been answered' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before { a_stale_queue_page }

  # The failure the issue calls a button that lies. `confirm` returns 0 because the session
  # is already matched, and the row was left exactly as it was -- so the answer a lifter just
  # gave is still on the list when they get back to it, and the only thing a second tap can
  # do is the same nothing again.
  it 'leaves nothing behind for the lifter to tap a second time' do
    tap_yes

    assert_nil proposal_on('backfilled')
    assert_equal 0, Tectonic::WithingsProposals.waiting_count(@account_id)
  end

  # And it does not move a match that is already made, which is what `confirm` refuses for:
  # the unique index on `workout_id` would make a second claim an exception rather than a
  # no-op, and the session's answer is the lifter's and not a stale form's to overwrite.
  it 'does not hand the session to the activity that was tapped' do
    tap_yes

    assert_equal 'confirmed', DB[:withings_workouts].where(workout_id: @workout_id).get(:external_id)
    assert_nil matched_to('backfilled')
  end
end

describe 'where a yes that changed nothing sends the lifter' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before { a_stale_queue_page }

  # A write that changed no row is not an answer, and the queue is the one place that cannot
  # say so: a list with one fewer row on it looks identical whether the yes took or whether
  # the question simply went away. The session's own record can say it -- it is where the
  # match that was made is rendered -- so that is where a yes that did nothing goes.
  #
  # The ordinary yes is untouched and is pinned next door rather than here: the review list's
  # own spec asserts that an answer given from it comes back to it, and this is the exception
  # to that branch rather than a replacement for it.
  it 'sends them to the session rather than back to the queue as though it had worked' do
    tap_yes

    assert_equal "/workouts/#{@workout_id}", last_response.headers['Location']
  end
end

describe 'a walk that meets a proposal nobody can answer' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  # The other end of the same knot, and the one that takes the walk down. A record page for
  # another session was open when the backfill ran -- it offered `backfilled` before anything
  # had been written down about it -- and the lifter pressed No on that page afterwards. The
  # activity is refused, so `standing` no longer sees it; its session was never answered at
  # all, so it is still in the walk; and the slot under the unique index is still held.
  before do
    a_session_with_a_proposal
    @elsewhere = trained_session(@account_id, started_at: @at - (3 * 86_400))
    Tectonic::WithingsWorkouts.dismiss(account_id: @account_id, workout_id: @elsewhere,
                                       external_id: 'backfilled')
    @report = backfill(@account_id, answering(backfilled, second_recording), since: @at.year)
  end

  # Before this the `UPDATE` hit the unique index on `proposed_workout_id` and raised out of
  # `pair`, out of `attempt` and out of `run` -- a stack trace for the rake task, a 500 on the
  # settings page for the button (#561), and in both cases after every request for the year
  # had already been spent.
  it 'finishes the walk rather than dying on the index' do
    assert_equal 1, @report[:proposed]
  end

  # And the session gets the recording it can still answer, which is the difference between
  # surviving the collision and fixing it. A guard that merely declined to write would leave
  # this session unaskable for good, silently, for as long as the dead proposal sat there.
  it 'offers the session the recording that is still free' do
    assert_equal @workout_id, proposal_on('second')
  end

  # The dead proposal is given up rather than left invisible. It names a session it can never
  # be the answer to, and while it holds that session's slot nothing else may be offered it.
  it 'gives up the proposal the refused activity was holding' do
    assert_nil proposal_on('backfilled')
  end
end

describe 'a run that reaches for the activity already carrying the proposal' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before do
    a_session_with_a_proposal
    Tectonic::WithingsWorkouts.store(@account_id, second_recording)
  end

  # The tally, which `offer` reported without ever looking at what the update did. The row it
  # picks here is the one already carrying the proposal, so the write matches nothing and
  # changes nothing -- and it was counted as a proposal made. A report that overstates what it
  # wrote is worse than one that says nothing: it is the number a lifter reads first when they
  # are deciding whether an import worked.
  it 'counts what it wrote rather than what it set out to write' do
    assert_equal :already_waiting, offer_anyway
  end
end

describe 'a run whose session lost its slot to another walk' do
  include Rack::Test::Methods
  include RouteOwnership
  include AlreadyAnswered

  before do
    a_session_with_a_proposal
    Tectonic::WithingsWorkouts.store(@account_id, fuller_recording)
  end

  # The activity it picks is a free one and the session's slot is taken all the same.
  # `proposed_workout_id` is unique, and the update went to the database to find that out --
  # raising out of `pair` mid-walk rather than leaving one session unproposed. Guarded on the
  # session id as well as on the row, it is a write that declines instead.
  it 'declines the write rather than finding out at the index' do
    assert_equal :already_waiting, offer_anyway
  end

  # And the proposal already in place is left alone. A second one written over it would be the
  # swap `offer` refuses for its own reasons: a lifter reading one activity on the review list
  # and answering a different one.
  it 'leaves the proposal that got there first exactly as it is' do
    offer_anyway

    assert_equal @workout_id, proposal_on('backfilled')
    assert_nil proposal_on('fuller')
  end
end

