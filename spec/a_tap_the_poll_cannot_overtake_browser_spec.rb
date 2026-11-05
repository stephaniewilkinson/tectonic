# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'rest_timer_browser_spec' # its RestingBrowser helpers and session fixtures

# A tap whose answer the poll overtakes. #669.
#
# "Tapping RPE to close a set doesn't reset the timer." Nothing about RPE was wrong: rating a
# set completes it and the server sends the rest cue back with the panel, exactly as Done
# does. What went wrong was the order the answers came back in.
#
# The tap writes the set, the write rings the session stream (#592), and the stream fires the
# poll. That poll still carries the fingerprint the page loaded with -- the tap's own answer
# is what replaces it -- so it finds the session changed and sends every lift panel back. If
# that lands first it replaces the panel the tap was going to swap into, and htmx, finding
# the element that sent the tap gone from the page, discards the tap's whole response: the
# panel, the progress, and the rest cue with them. The screen looks right, because the poll
# drew the same rows, and the clock goes on counting the previous set's rest.
#
# The server is made slow to answer the tap here, which is the race held open long enough to
# be looked at rather than hoped for. The set is written before the delay, so the poll the
# stream sends in the gap finds the change exactly as it does on a phone.

# Prepended once, and off unless a test turns it on. The write has already happened by the
# time session_body runs, so the delay sits between the set being saved and the answer
# leaving -- the window a phone on a slow connection has open on every tap.
module SlowTaps
  class << self
    attr_accessor :on
  end

  private

  def session_body(...)
    sleep 2 if SlowTaps.on
    super
  end
end
Tectonic.prepend(SlowTaps)

# The two sets and the race between them, set up the same way for both taps.
module OvertakenTap
  include Capybara::DSL

  def answer_taps_slowly = SlowTaps.on = true

  def row(id) = "form[action$='/sets/#{id}/complete']"

  # The stream's doorbell, rung while the tap is still out. Fired from the tap's own request
  # rather than after a sleep, so it is always inside the window.
  def ring_the_stream_during_the_tap
    page.execute_script(<<~JS)
      document.body.addEventListener('htmx:beforeSend', function (event) {
        if (!/\\/complete$/.test(event.detail.requestConfig.path)) { return; }
        setTimeout(function () { htmx.trigger(document.body, 'session-changed'); }, 200);
      }, { once: true });
    JS
  end

  def rest_on_the_first_set
    find("#{row(@first)} button", text: 'Done').click
    assert has_css?('#rest-timer', visible: true, wait: 5)
    sleep 3
    assert_operator seconds_in(clock_text), :>=, 3
    answer_taps_slowly
    ring_the_stream_during_the_tap
  end
end

describe 'a tap the poll cannot overtake' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser
  include OvertakenTap

  before do
    account_id = sign_up_for_session
    workout_id, = generated_session(account_id)
    working = DB[:sets].where(workout_id:, is_warmup: false).first
    @first = working[:id]
    @second = DB[:sets].insert(working.except(:id))
    visit "/workouts/#{workout_id}/session"
  end

  after { SlowTaps.on = false }

  it 'starts the next rest when the set is closed with a rating' do
    rest_on_the_first_set
    find("#{row(@second)} button[name=rpe][value='7']").click

    assert has_css?("#rest-cue[data-set='#{@second}']", visible: :all, wait: 6)
    assert_operator seconds_in(clock_text), :<, 3
  end

  it 'starts the next rest when the set is closed with Done' do
    rest_on_the_first_set
    find("#{row(@second)} button", text: 'Done').click

    assert has_css?("#rest-cue[data-set='#{@second}']", visible: :all, wait: 6)
    assert_operator seconds_in(clock_text), :<, 3
  end
end

