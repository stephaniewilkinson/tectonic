# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require

# Seeded here as five other spec files do, because these specs are about where the library
# sits relative to an account's own movements and a file run on its own would otherwise be
# comparing one group against nothing.
Tectonic::Exercise.load_library

# What order a lifter is handed the movements in. #551.
#
# The list came back in insertion order until now, which is an order the app has and a lifter
# does not: `Cable Fly` above `Ab Wheel` because of the week each was typed in, on a screen
# that says nothing about weeks. It survived as long as it did because the control was a menu
# somebody scrolled; #549 made the same list the thing a typeahead filters and ranks, so what
# it opens on is the first thing anybody reads.
#
# Asserted through the rendered form rather than off the dataset, because what is being
# claimed is what a lifter is shown: the route's order and the template's two optgroups are
# both in it, and a model spec would pass while the view drew the groups the other way up.
module MovementOrder
  # The account's own movements, deliberately not in alphabetical order as they go in --
  # otherwise insertion order and name order agree and the spec asks nothing. `incline curl`
  # is lower case on purpose: this database is built with the C collation, which sorts every
  # capital ahead of every lower-case letter, so a name typed the way a lifter types one is
  # what tells an ordering that folds case from one that does not.
  TYPED_IN = ['Zercher Curl', 'Machine Row', 'incline curl', 'Cable Fly'].freeze
  BY_NAME = ['Cable Fly', 'incline curl', 'Machine Row', 'Zercher Curl'].freeze

  def a_lifter_with_their_own_movements
    @account_id = login
    @workout = own_workout(@account_id)
    TYPED_IN.each { |name| DB[:exercises].insert(name:, account_id: @account_id) }
  end

  def set_form
    get "/workouts/#{@workout}/sets/new"
    last_response.body
  end

  # The names inside one optgroup, in the order the markup has them.
  def options_in(body, label)
    group = body[%r{<optgroup label="#{label}">(.*?)</optgroup>}m, 1] || raise("no #{label} group")
    group.scan(/<option[^>]*>([^<]*)</).flatten.map(&:strip)
  end

  def all_options(body) = body.scan(/<option[^>]*>([^<]*)</).flatten.map(&:strip)

  # The movements page, which is the other screen that lists every one of them.
  def index_names
    get '/exercises'
    last_response.body.scan(%r{<a href="/exercises/\d+"[^>]*>\s*([^<]+?)\s*</a>}).flatten
  end

  # The swap menu inside a session panel. Forced to UTF-8 because the session screen renders
  # plate math with a multiplication sign in it, and a body left as bytes cannot be matched
  # against a pattern that is not.
  def swap_menu
    get "/workouts/#{@workout}/session"
    body = last_response.body.dup.force_encoding(Encoding::UTF_8)
    body[%r{<select id="swap-\d+".*?</select>}m] || raise('no swap menu on the session screen')
  end
end

describe 'the order the movement picker offers movements in' do
  include Rack::Test::Methods
  include RouteOwnership
  include MovementOrder

  before { a_lifter_with_their_own_movements }

  # The complaint in one assertion: four movements typed in over four different months come
  # back in the order a person would look for them in, not the order they were written in.
  it "sorts the account's own movements by name rather than by when they were added" do
    assert_equal MovementOrder::BY_NAME, options_in(set_form, 'Your exercises')
  end

  # The library gets the same treatment rather than keeping the curated order `LIBRARY` is
  # written in. That order groups squats with squats and presses with presses, which is real,
  # but nothing on screen draws it -- the picker renders one flat group of fifty-four under
  # one heading -- so it is an order only the source file can see.
  it 'sorts the library by name too' do
    library = options_in(set_form, 'Library')

    refute_empty library
    assert_equal library.sort_by(&:downcase), library
  end

  # And the split between the two survives the sort, which is the half that is not
  # alphabetical at all: "the library Bent Over Row or the one I named myself" is a real
  # question, and answering it is worth more than one unbroken A-to-Z.
  it 'keeps the library above the account\'s own however their names sort' do
    DB[:exercises].insert(name: 'Ab Wheel', account_id: @account_id)
    body = set_form

    assert_equal 'Ab Wheel', options_in(body, 'Your exercises').first
    refute_equal 'Ab Wheel', all_options(body).first
  end
end

describe 'the order the movements page lists movements in' do
  include Rack::Test::Methods
  include RouteOwnership
  include MovementOrder

  before { a_lifter_with_their_own_movements }

  # One order for both screens, asserted by comparing them rather than by writing the answer
  # out twice. A lifter who learns where a movement sits in the picker has learned where it
  # sits on the list it is edited from, and two orderings drifting apart is how that stops
  # being true without anybody noticing.
  it 'lists them in the same order the picker offers them in' do
    assert_equal all_options(set_form), index_names
  end
end

describe 'the order the session offers a movement to swap to' do
  include Rack::Test::Methods
  include RouteOwnership
  include MovementOrder

  before do
    a_lifter_with_their_own_movements
    DB[:sets].insert(workout_id: @workout, is_warmup: false, is_completed: false, weight: 40, reps: 12,
                     exercise_id: DB[:exercises].where(account_id: @account_id, name: 'Cable Fly').get(:id))
  end

  # The fourth list of movements and the one a lifter is holding mid-session: "lifted a
  # different movement", inside a session panel. It is drawn by walking a hash keyed by id
  # rather than through _exercise_options, so its order comes from the route that fills the
  # hash -- which is exactly how it would have been left behind in insertion order while
  # every other list of the same rows was sorted.
  it 'offers them in the same order the picker does' do
    swap = swap_menu

    assert_equal all_options(set_form), all_options(swap)
  end
end

