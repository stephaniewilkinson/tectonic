# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# #543. A session screen reopened with no signal -- a closed tab in a basement gym -- used to be
# the browser's offline page. It is now the last copy of that screen, with its styling and the
# queue that holds a tap until signal returns. assets/sw.js has the rules.
#
# No signal is set from Firefox's privileged context -- see `signal` -- which geckodriver only
# allows when started with --allow-system-access. That is what the driver below adds; it is
# otherwise the suite's headless Firefox. A page that fetches from an unreachable address, which
# is how the other signal specs fake it, cannot stand in here: a reload is a navigation, and only
# the browser's own connection failing makes a navigation fail.
Capybara.register_driver :offline_capable_firefox do |app|
  require 'selenium/webdriver'
  # Firefox's own HTTP cache off, because an offline Firefox serves a page from it and a spec
  # would then pass with no worker at all.
  options = Selenium::WebDriver::Firefox::Options.new(
    args: ['-headless'],
    prefs: { 'browser.cache.disk.enable' => false, 'browser.cache.memory.enable' => false,
             'browser.cache.offline.enable' => false }
  )
  service = Selenium::WebDriver::Service.firefox(args: ['--allow-system-access'])
  Capybara::Selenium::Driver.new(app, browser: :firefox, options:, service:)
end

module NoSignal
  def before_setup
    super
    Capybara.current_driver = :offline_capable_firefox
  end

  # Before teardown rather than after it, because teardown is where the suite hands the driver
  # back, and a browser left offline would fail whichever spec drew it next.
  def before_teardown
    signal(true)
    super
  end

  def after_teardown
    super
  ensure
    Capybara.use_default_driver
  end

  # One Firefox serves the whole run, and a worker and its cache outlive a spec. Without this a
  # first visit could be served by the last spec's worker, and 'kept the first time' would pass
  # whether or not the first time is handled.
  def a_browser_that_has_kept_nothing
    page.evaluate_async_script(<<~JS)
      var done = arguments[0];
      navigator.serviceWorker.getRegistrations()
        .then(function (all) { return Promise.all(all.map(function (r) { return r.unregister(); })); })
        .then(function () { return caches.keys(); })
        .then(function (names) { return Promise.all(names.map(function (n) { return caches.delete(n); })); })
        .then(function () { done(true); });
    JS
  end

  # No signal is every request failing at the network, which is done by sending them all through
  # a proxy that is not there. Firefox's own offline switch was the first try and does not work
  # for this: it leaves localhost reachable whatever its preferences say, so the test server
  # carried on answering and the spec passed with no worker at all.
  def signal(on)
    browser = page.driver.browser
    browser.context = 'chrome'
    browser.execute_script(<<~JS)
      Services.prefs.setBoolPref('network.proxy.allow_hijacking_localhost', #{!on});
      Services.prefs.setStringPref('network.proxy.http', '127.0.0.1');
      Services.prefs.setIntPref('network.proxy.http_port', 9);
      Services.prefs.setIntPref('network.proxy.type', #{on ? 0 : 1});
    JS
  ensure
    browser.context = 'content'
  end

  # A phone coming back into signal fires `online`; a proxy switched back on fires nothing, so
  # the event the phone would send is sent here.
  def reopened_with_no_signal
    kept
    signal(false)
    visit "/workouts/#{@workout_id}/session"
  end

  def signal_returns
    signal(true)
    page.execute_script("window.dispatchEvent(new Event('online'))")
  end

  # Whether the session's set has been done, allowing the held tap ten seconds to arrive.
  def landed?
    50.times do
      return true if DB[:sets].where(workout_id: @workout_id).get(:is_completed)

      sleep 0.2
    end
    false
  end

  def a_session(weight)
    workout_id = DB[:workouts].insert(account_id: @account_id, date: Date.today)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id: @account_id)
    DB[:sets].insert(workout_id:, exercise_id:, weight:, reps: 5, is_warmup: false, is_completed: false,
                     is_barbell: true)
    workout_id
  end

  def a_session_open
    @account_id = sign_in_as_somebody_new
    a_browser_that_has_kept_nothing
    @workout_id = a_session(155)
    visit "/workouts/#{@workout_id}/session"
    assert_text '155 lb'
  end

  # What the worker has kept, by path, once it has had a moment to keep it.
  def kept
    sleep 1.5
    urls = page.evaluate_async_script(<<~JS)
      var done = arguments[0];
      caches.keys()
        .then(function (names) { return Promise.all(names.map(function (n) { return caches.open(n).then(function (c) { return c.keys(); }); })); })
        .then(function (lists) { done([].concat.apply([], lists).map(function (r) { return new URL(r.url).pathname; })); });
    JS
    urls.sort
  end
end

describe 'what is kept of a session screen' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include NoSignal

  before { a_session_open }

  # The first visit counts: the worker is installed by this very page, so it asks to keep it
  # rather than waiting for a second visit that a lifter in a basement may never make.
  it 'is kept the first time it is opened, with its stylesheet and htmx' do
    assert_equal ['/assets/css/styles.css', '/js/htmx.min.js', "/workouts/#{@workout_id}/session"], kept
  end

  # One session is kept, not a history of them.
  it 'keeps only the last session opened' do
    kept
    other = a_session(185)
    visit "/workouts/#{other}/session"

    assert_equal ['/assets/css/styles.css', '/js/htmx.min.js', "/workouts/#{other}/session"], kept
  end

  # The next person to use the phone must not get this lifter's training out of it. The
  # stylesheet may be kept again by the sign-in page itself, which is nobody's training.
  it 'is forgotten on the way back to sign in' do
    kept
    visit '/login'

    assert_empty(kept.grep(%r{/session}))
  end
end

describe 'a session screen reopened with no signal' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include NoSignal

  before { a_session_open }

  it 'comes back from the copy, styled and able to hold a tap' do
    reopened_with_no_signal

    assert_text '155 lb'
    assert page.evaluate_script('!!window.htmx'), 'the copy came back without htmx, so a tap has nothing to queue it'
  end

  # What makes the copy worth keeping: a set done on it is held, and lands when signal is back.
  it 'holds a tap made on the copy and sends it when signal returns' do
    reopened_with_no_signal
    click_on 'Done'
    assert_text 'Waiting to send.'

    signal_returns

    assert landed?, 'the tap made offline never reached the database'
  end

  # A copy stands in for a missing network and nothing else: with signal the live page wins,
  # so a change made elsewhere is never hidden behind what was kept.
  it 'is the live page whenever there is signal' do
    kept
    DB[:sets].where(workout_id: @workout_id).update(weight: 165)
    visit "/workouts/#{@workout_id}/session"

    assert_text '165 lb'
  end
end

