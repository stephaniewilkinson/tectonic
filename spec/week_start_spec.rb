# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/calendar'

# Which day the calendar grid begins on. #189.
#
# It had always begun on Sunday, and not by decision: Calendar.bounds did a plain
# subtraction, `month - month.wday`, which is Sunday because Date#wday counts from there.
# Most of the world reads a week as beginning on Monday and the app had no way to say so.
#
# The arithmetic is the part worth testing rather than the form. A grid that starts on the
# wrong day still renders, still fills in, and still looks like a calendar -- it is simply
# somebody else's calendar, which is the kind of wrong nothing else here would catch.
module WeekStart
  def app = Tectonic.app

  SUNDAY = 0
  MONDAY = 1

  def choose(starts_on)
    post '/settings/week',
         { 'week_starts_on' => starts_on.to_s, '_csrf' => token_for_form('/settings', '/settings/week') }
    last_response
  end
end

describe 'the month grid' do
  include Rack::Test::Methods
  include RouteOwnership
  include WeekStart

  # Every month, both ways round, rather than one convenient month: the arithmetic wraps,
  # and February in a leap year and a month beginning on the start day itself are the two
  # shapes most likely to come out a day wrong.
  it 'is whole weeks that begin and end on the chosen day, for every month of a year' do
    [WeekStart::SUNDAY, WeekStart::MONDAY].each do |starts_on|
      (1..12).each do |month|
        from, to = Tectonic::Calendar.bounds(Date.new(2026, month, 1), starts_on)

        assert_equal starts_on, from.wday, "#{month}: grid starts on the wrong day"
        assert_equal (starts_on + 6) % 7, to.wday, "#{month}: grid ends on the wrong day"
        assert_equal 0, (from..to).count % 7, "#{month}: grid is not whole weeks"
        assert_operator from, :<=, Date.new(2026, month, 1)
        assert_operator to, :>=, Date.new(2026, month, -1)
      end
    end
  end

  # A leap February that begins on the start day is the case where "go back to the previous
  # start of week" and "go back nothing" are the same answer, and an off-by-one shows.
  it 'does not pad a month that already begins on the chosen day' do
    from, = Tectonic::Calendar.bounds(Date.new(2026, 2, 1), WeekStart::SUNDAY)

    assert_equal Date.new(2026, 2, 1), from, '1 Feb 2026 is a Sunday and needs no padding'
  end

  it 'names the columns in the order they are drawn' do
    assert_equal %w[Sun Mon Tue Wed Thu Fri Sat], Tectonic::Calendar.day_names(WeekStart::SUNDAY)
    assert_equal %w[Mon Tue Wed Thu Fri Sat Sun], Tectonic::Calendar.day_names(WeekStart::MONDAY)
  end
end

describe 'choosing a week start' do
  include Rack::Test::Methods
  include RouteOwnership
  include WeekStart

  before { @account_id = login }

  it 'begins on Sunday, which is what every account had before it was a choice' do
    assert_equal 0, DB[:accounts].where(id: @account_id).get(:week_starts_on)
  end

  it 'is remembered, and shows on the calendar' do
    choose(WeekStart::MONDAY)

    assert_equal 1, DB[:accounts].where(id: @account_id).get(:week_starts_on)

    get '/'

    assert_includes last_response.body, '>Mon<'
    assert_operator last_response.body.index('>Mon<'), :<, last_response.body.index('>Sun<'),
                    'Monday should be the first column'
  end

  it 'can be set back' do
    choose(WeekStart::MONDAY)
    choose(WeekStart::SUNDAY)

    assert_equal 0, DB[:accounts].where(id: @account_id).get(:week_starts_on)
  end

  # Refused by the route, and the constraint behind it is the backstop. Both, because a
  # check constraint refuses by raising and an unrescued Sequel exception reaches a person
  # as a 500 rather than as a refusal -- which is #213's bug, and this is #211's answer to
  # it. Writing this spec is how that was found: it errored with a CheckConstraintViolation
  # before the route learned to say no.
  it 'refuses a day a week cannot begin on' do
    choose(3)

    assert_equal 0, DB[:accounts].where(id: @account_id).get(:week_starts_on)
  end
end

describe 'where the plate inventory lives' do
  include Rack::Test::Methods
  include RouteOwnership

  before { login }

  # It had a page of its own, which put two per-account preferences on two pages.
  it 'is on the settings page' do
    get '/settings'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'name="bar_weight"'
    assert_includes last_response.body, 'Week'
  end

  it 'still answers at the address it used to have' do
    get '/equipment'

    assert_equal 302, last_response.status
    assert_equal '/settings', URI(last_response.headers['location']).path
  end
end

