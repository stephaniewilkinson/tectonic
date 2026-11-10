# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'rest_timer_browser_spec' # RestingBrowser#session_with_a_set

# The Done tap, counted once, and the undo not counted at all. #687.
#
# Fathom itself never sends from here -- the tag counts only the live hostname (#688) -- so the
# page's `window.fathom` is replaced with a recorder after it loads, and what the listener asked
# it to send is read back. That is the part this app owns: which tap becomes which event.
module FathomRecorder
  include Capybara::DSL

  def record_events
    page.execute_script(<<~JS)
      window.tracked = [];
      window.fathom = { trackEvent: function (name) { window.tracked.push(name); } };
    JS
  end

  def tracked = page.evaluate_script('window.tracked')

  def first_done = find('form[action$="/complete"] button', text: 'Done', match: :first)
end

describe 'what Fathom is told about a set' do
  include CapybaraBehaviour
  include BrowserSpec
  include RestingBrowser
  include FathomRecorder

  it 'counts a Done tap as one set completed, and an undo as nothing' do
    session_with_a_set
    record_events

    first_done.click
    assert has_css?('form[action$="/complete"] button', text: 'Undo', wait: 5)
    assert_equal ['set_completed'], tracked

    find('form[action$="/complete"] button', text: 'Undo', match: :first).click
    assert has_no_css?('form[action$="/complete"] button', text: 'Undo', wait: 5)
    assert_equal ['set_completed'], tracked
  end
end

