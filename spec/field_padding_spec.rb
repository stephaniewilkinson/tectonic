# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #368, both halves. The text in a field sat flush against the left edge of its own box,
# because most call sites carried a py-* and no horizontal padding at all -- and the new
# workout form asked how a session went before anybody had done it.
module Fields
  # Every input, select and textarea on a page, as its class list.
  CONTROL = /<(?:input|select|textarea)\b[^>]*class="([^"]*)"/m

  def controls_on(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    last_response.body.scan(CONTROL).flatten.map(&:split)
  end

  # A control styled by the shared helper, which is what this rule is about. The date field
  # on the workout form is Flowbite's own shape and is deliberately not one of these.
  def shared_controls(path)
    controls_on(path).select { |classes| classes.include?('rounded-md') && classes.include?('shadow-sm') }
  end
end

describe 'the inset of every field the shared style paints' do
  include Rack::Test::Methods
  include RouteOwnership
  include Fields

  before do
    @account_id = login
    @workout = own_workout(@account_id)
    @exercise = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id: @account_id)
  end

  # px-3 lives on field_style now, so a field cannot be rendered without it. Asserted over
  # the markup rather than over the helper because the helper was never the problem -- the
  # padding was simply absent from most of the call sites that composed on top of it.
  it 'is never zero on the left' do
    ['/settings', '/workouts/new', '/exercises/new', "/workouts/#{@workout}/sets/new",
     '/volume'].each do |path|
      shared_controls(path).each do |classes|
        assert_includes classes, 'px-3', "a field on #{path} has no horizontal padding"
      end
    end
  end

  # A select with a chevron still needs room on one side only, and Tailwind emits pr-* after
  # px-*, so naming one side still wins. This is what would break if the helper were given
  # pl-3 and pr-3 separately instead.
  it 'still lets one side be widened for a chevron' do
    widened = shared_controls('/volume').select { |classes| classes.grep(/\Apr-/).any? }

    refute_empty widened, 'the volume selects should still reserve room for their chevron'
    widened.each { |classes| assert_includes classes, 'px-3' }
  end
end

# The second half: a form shared between New workout and Edit workout asked how the session
# went, and on the new one there was no answer to give.
describe 'the note on the workout form' do
  include Rack::Test::Methods
  include RouteOwnership
  include Fields

  before { @account_id = login }

  it 'is not asked for on a session that has not happened' do
    get '/workouts/new'

    refute_includes last_response.body, 'How it went'
  end

  it 'is asked for once the session exists' do
    workout = own_workout(@account_id)
    get "/workouts/#{workout}/edit"

    assert_includes last_response.body, 'How it went'
  end

  # The name is a different question -- what to call two sessions on one date -- and is
  # answerable before the session, so it stays on both.
  it 'still asks what to call it on a new session' do
    get '/workouts/new'

    assert_includes last_response.body, 'Name'
  end

  # A note already written has to come back into the box, or editing one would silently
  # clear it.
  it 'shows a note that is already there' do
    workout = own_workout(@account_id)
    DB[:workouts].where(id: workout).update(note: 'Bar felt slow')
    get "/workouts/#{workout}/edit"

    assert_includes last_response.body, 'Bar felt slow'
  end
end

