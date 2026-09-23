# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'
require 'date'

# A session keeps the date it was trained on. #440.
#
# `views/workouts/_form.erb` is shared by the new page and the edit page, and its date input
# carried `value="<%= Date.today %>"` unconditionally. So the edit page opened with the wrong
# date in the box every time -- and because the field is `required` and posted with everything
# else, saving *any* edit moved the session to today.
#
# Two consequences, and the issue title names both. A session could not be corrected onto a
# past date, because the box would not hold one long enough to submit it. And renaming a
# session from three weeks ago dragged it, and its twelve completed sets with their ratings,
# onto the current day without saying anything.
#
# Reported as workout 28: created 2026-08-30, trained 2026-08-31, twelve completed sets filed a
# day early with no way to move them.
#
# The second half of it was the write path, and it outlived the fix above by a month. The form
# value became right; what it rendered was `%m/%d/%Y`, and that string went straight into the
# update, where Sequel typecast it with `Date.parse` -- which reads a slashed date day-first. A
# session trained on 2 September posted `09/02/2026` and was stored as 9 February, sets and all.
#
# It only bit when both halves were <= 12, so on the first twelve days of a month and not on
# the other nineteen. This file is why that reached production: every date here was built as
# `Date.today - 21`, so the specs asked the ambiguous question for about eleven days in thirty
# and the safe one the rest of the time, and which one they asked was not visible in the file.
# The dates below are written out instead -- one whose day is <= 12 and one whose day is not --
# so both cases are asked on every run of every day.
#
# The format they are posted in is ISO since #524, where the field became a `type="date"` input
# and stopped being able to write anything else. The hazard they were built around is therefore
# gone rather than fixed -- `2026-09-02` has one reading -- but they stay, because they are two
# rows in a table and what they now pin is that the hazard cannot come back. A form that went
# month-first again would fail them on the day it did, rather than on the next 2nd of a month.
module KeepingTheDate
  # The day of the month the old format could spell two ways, which was the whole of the
  # ambiguity: `09/02/2026` was 2 September to that form and 9 February to a day-first reader,
  # and both are real dates, so nothing raised and there was nothing for anybody to notice.
  # The name is kept over the date it describes rather than over how it is spelled today.
  #
  # Methods rather than constants, which is not a style choice: a constant on an included
  # module is not in scope inside a `describe` block, so it would be looked for at the top
  # level and raise NameError from every spec here.
  def ambiguous = Date.new(2026, 9, 2)

  # And a day past the 12th, which could not be read as a month, so a day-first parser had no
  # second reading available and landed on the right date by accident. Here to pin the half
  # that was always passing -- a fix that broke it would otherwise show up as nothing.
  def unambiguous = Date.new(2026, 9, 23)

  # Read off the app rather than spelled again here. These specs are about the round trip
  # surviving whatever the form writes, not about which format it writes -- one literal
  # below pins that, and everything else goes through the constant, so changing it would
  # change what these post rather than leave the suite testing a string nothing sends.
  def form_date = Tectonic::Workout::FORM_DATE

  def a_session_on(account_id, date, name: 'Squat day')
    Tectonic::Workout.insert(account_id:, date:, name:)
  end

  # The new-session half of the same form: no id, so the route inserts rather than updates.
  def create(date:, name: 'Squat day')
    post '/workouts', { 'id' => '', 'date' => date, 'name' => name,
                        '_csrf' => token_for('/workouts/new') }
  end

  # The row `create` just wrote. By account rather than across the table, so a stranger's
  # session left behind by another spec cannot be the one this reads back.
  def newest_workout = Tectonic::Workout.where(account_id: @account_id).reverse(:id).first.id

  def edit_page(workout_id)
    get "/workouts/#{workout_id}/edit"
    last_response.body
  end

  # Posts the edit form the way the browser does: every field it carries, together.
  def save(workout_id, date:, name: 'Renamed', note: '')
    post '/workouts', { 'id' => workout_id.to_s, 'date' => date, 'name' => name, 'note' => note,
                        '_csrf' => token_for("/workouts/#{workout_id}/edit") }
  end

  def date_of(workout_id) = Tectonic::Workout[workout_id].date.to_date

  # The date the rendered form is actually carrying, which is what a browser posts back when
  # somebody edits the name and nothing else. Taken off the page rather than passed in,
  # because a spec that supplies the right date itself cannot fail on the bug -- the whole
  # fault was the value the page put in the box.
  def date_in_form(workout_id)
    edit_page(workout_id)[/<input[^>]*id="date"[^>]*>/][/value="([^"]*)"/, 1]
  end
end

describe 'the date the edit page opens with' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before do
    @account_id = login
    @trained_on = ambiguous
    @workout = a_session_on(@account_id, @trained_on)
  end

  # The bug, at its source. Everything below follows from this one value being wrong.
  it 'is the day it was trained, not today' do
    assert_includes edit_page(@workout), "value=\"#{@trained_on.strftime(form_date)}\""
  end

  it 'is not today' do
    refute_includes edit_page(@workout), "value=\"#{Date.today.strftime(form_date)}\""
  end

  # The one literal in this file, and it is now the opposite claim to the one it used to make.
  # It read `value="09/02/2026"` and stood for the ambiguity every spec below it was written
  # about: month-first, deliberately, for a US reader, and also a perfectly good 9 February to
  # anything reading it day-first, which Ruby's `Date.parse` does.
  #
  # Since #524 the field is a `type="date"` input, which will render nothing but ISO and posts
  # nothing but ISO, so the value in the box has one reading. Pinned as a literal rather than
  # through the constant because this is the assertion that would have to be *changed* to put
  # the ambiguity back, which is the point of writing it out.
  #
  # What a lifter sees on screen is a separate question and is deliberately not asserted: a
  # native date input displays in the device's locale, so a US phone draws 09/02/2026 over this
  # value and a phone set elsewhere draws what its owner expects. The app no longer chooses.
  it 'is ISO, which has one reading in every locale' do
    assert_includes edit_page(@workout), 'value="2026-09-02"'
  end
end

# What the wrong value cost, which is the part a lifter would actually notice: the name is
# edited, the date rides back untouched, and the session moves anyway.
describe 'renaming a session without touching its date' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before { @account_id = login }

  # Posting the form back unchanged is what a browser does when somebody edits the name. The
  # date is read off the rendered input rather than spelled here, because a spec that supplies
  # its own string is testing that string and not the round trip.
  def assert_renaming_leaves_it_on(trained_on)
    workout = a_session_on(@account_id, trained_on)

    save(workout, date: date_in_form(workout))

    assert_equal trained_on, date_of(workout)
  end

  # The half that was live. 2 September rendered as `09/02/2026`, and a day-first parser read
  # that as 9 February without raising, because both readings are real dates. It renders as
  # `2026-09-02` now and has one reading, so this asks a question with no trap in it -- and it
  # stays, because it is the question that fails the day somebody puts the trap back.
  it 'leaves a session trained on the second of the month where it was' do
    assert_renaming_leaves_it_on(ambiguous)
  end

  # The half that always passed. 23 was not a month, so there was only one reading available and
  # even a guess landed on it. Named on its own so that a green run means both readings were
  # asked for, rather than whichever one the calendar handed this particular week.
  it 'leaves a session trained on the twenty-third of the month where it was' do
    assert_renaming_leaves_it_on(unambiguous)
  end

  it 'still renames it' do
    workout = a_session_on(@account_id, ambiguous)

    save(workout, date: ambiguous.strftime(form_date), name: 'Heavy squats')

    assert_equal 'Heavy squats', Tectonic::Workout[workout].name
  end
end

# The same string, on the other route out of the same form. The insert carried the identical
# bug and had nothing watching it: a session written for the 2nd was filed on 9 February the
# moment it was created, before anybody had lifted anything in it. Both routes read the date
# the same way, which is what keeps them agreeing when the format changes under them, as it
# just has.
describe 'writing a session for a day the calendar could read two ways' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before { @account_id = login }

  it 'files it on the day that was typed' do
    create(date: ambiguous.strftime(form_date))

    assert_equal ambiguous, date_of(newest_workout)
  end

  it 'files a day past the twelfth on the day that was typed too' do
    create(date: unambiguous.strftime(form_date))

    assert_equal unambiguous, date_of(newest_workout)
  end
end

# A date this form cannot have written, which is a hand-made post, an autofill, or a browser
# too old for `type="date"` that drew a text box and let somebody type into it in their own
# locale. The old behaviour was to hand it to Sequel and accept whatever came back; the whole
# point of #440's second half is that the app does not guess at this, and #524 changing what
# the form posts does not change what a post can contain.
#
# `31/12/2026` is the shape a European autofill puts in a box: a perfectly good date read
# day-first, no date at all read month-first, and not this form's format under any reading.
# It is the one the app must not quietly take a guess at.
describe 'saving a date the form could not have written' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before do
    @account_id = login
    @workout = a_session_on(@account_id, ambiguous)
  end

  it 'leaves the session on the day it was already on' do
    save(@workout, date: '31/12/2026')

    assert_equal ambiguous, date_of(@workout)
  end

  it 'does not keep the rest of the edit either' do
    save(@workout, date: '31/12/2026', name: 'Heavy squats')

    assert_equal 'Squat day', Tectonic::Workout[@workout].name
  end

  # Refused, not crashed. An unrescued typecast reaches a lifter as a 500, which reads as the
  # server having fallen over rather than as the app declining what was typed.
  it 'sends the lifter back to the form rather than to an error page' do
    save(@workout, date: 'the second of September')

    assert_equal 302, last_response.status
    assert_equal "/workouts/#{@workout}/edit", last_response.headers['location']
  end
end

# The insert half of the same refusal. Both routes out of this form read the date the same
# way, so both decline the same values -- a new session refused on one and written with a
# guessed date on the other would be the bug back in half the app.
describe 'writing a new session with a date the form could not have written' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before { @account_id = login }

  it 'writes nothing and sends the lifter back to the form' do
    create(date: 'the second of September')

    assert_equal 0, Tectonic::Workout.where(account_id: @account_id).count
    assert_equal '/workouts/new', last_response.headers['location']
  end
end

# And says so, because a form that comes back looking exactly as it was left is a form that
# has silently thrown away what was typed into it. A refusal nobody is told about is the same
# shape of failure as the wrong date: the lifter carries on believing the save happened.
describe 'being told the date was refused' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before do
    @account_id = login
    @workout = a_session_on(@account_id, ambiguous)
    save(@workout, date: 'the second of September')
  end

  it 'says why when the form comes back' do
    assert_includes edit_page(@workout), 'That date could not be read'
  end

  # Once, not on every reload afterwards. The notice is about a save that has just failed, and
  # one still on the page ten minutes later describes nothing the lifter can see.
  it 'says it once' do
    edit_page(@workout)

    refute_includes edit_page(@workout), 'That date could not be read'
  end
end

# And the correction the issue asked for: a session trained a day after it was written, moved
# onto the day it happened. This always worked at the route -- #319 made POST /workouts with an
# id update the date -- and could not be reached through the page.
describe 'correcting a session onto the day it actually happened' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  it 'moves it, and the sets go with it' do
    account_id = login
    written_for = Date.new(2026, 8, 30)
    workout = a_session_on(account_id, written_for)
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout, exercise_id:, weight: 155, reps: 5, rpe: 8,
                     is_warmup: false, is_completed: true, completed_at: Time.now)

    save(workout, date: '2026-08-31')

    assert_equal Date.new(2026, 8, 31), date_of(workout)
    # The sets are reached through the workout rather than dated themselves, so they follow it
    # without anything having to move them. That is why a date editor is the whole fix here.
    assert_equal 1, Tectonic::WorkoutSet.where(workout_id: workout).count
  end
end

# The new page has no session to read a date off, and must go on opening at today.
describe 'writing a new session' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  it 'still opens at today' do
    login

    get '/workouts/new'

    assert_includes last_response.body, "value=\"#{Date.today.strftime('%Y-%m-%d')}\""
  end
end

