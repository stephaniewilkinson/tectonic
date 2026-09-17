# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The rest, on the list every movement is already on. #456.
#
# The bell, the countdown and the column it counts to have existed since #281 and #395, and the
# bell has never rung for anybody: on the reporting account not one movement and not one of 126
# program lifts carries a rest.
#
# That is not a bug in the timer. The app deliberately will not invent a rest -- a countdown
# that rings unasked is the app deciding how long somebody rests, which #263 settled it does
# not do -- so the bell rings only if a lifter names a length. What was missing is that nothing
# on any list showed the question was there to answer, which is the same argument #411 made for
# putting the training max on this page.
module RestColumn
  # Beside the movement rather than on it since 039, where a rest is keyed on the pair so a
  # library Back Squat can carry one.
  def an_exercise(account_id, rest: nil)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    Tectonic::Rest.replace(account_id, exercise.id, rest) if rest
    exercise
  end

  def index
    get '/exercises'
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end
end

describe 'the rest column' do
  include Rack::Test::Methods
  include RouteOwnership
  include RestColumn

  before { @account_id = login }

  it 'heads a column for it' do
    an_exercise(@account_id)

    assert_includes index, '>Rest</th>'
  end

  # Through Timing.phrase, which is how the session screen and the movement's own page both
  # say it. "180 seconds" and "3m" are the same fact and two spellings is one too many.
  it 'says a named rest the way the rest of the app says it' do
    an_exercise(@account_id, rest: 180)

    assert_includes index, Tectonic::Timing.phrase(180)
  end

  # A column of dashes is the whole point: an unanswered question has to look unanswered.
  #
  # Counted rather than matched on "&mdash;", which the training max beside it also prints for
  # a movement nobody has stated one for -- so a bare assert_includes would pass with no rest
  # column on the page at all. Two cells per row are blank where nothing is named and one where
  # a rest is, which is the difference this actually asserts.
  it 'shows a dash where nobody has named one' do
    an_exercise(@account_id)
    blank = index.scan('&mdash;').length

    an_exercise(@account_id, rest: 180)

    assert_equal blank + 1, index.scan('&mdash;').length
  end

  # And the phrase is absent entirely while nobody has named a rest, which is the other half of
  # the same check: a column that printed something for an unanswered movement would be the app
  # suggesting a length, which is exactly what it must not do.
  it 'names no length at all where nobody has named one' do
    an_exercise(@account_id)

    refute_includes index, Tectonic::Timing.phrase(180)
  end
end

