# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'session_spec' # reuses its browser sign-up and one-set session helpers

# A second tap on Done, before the first has come back. #236.
#
# The route toggles when it is sent no parameters, which is deliberate and right: a mis-tap
# is undone by tapping again. What nothing distinguished was a second tap meant as an undo
# from a second tap meant as "that did not appear to do anything". On this screen the second
# reading was the likely one -- the whole body is swapped on every tap, and nothing on the
# page changed between the tap and the answer -- so the sequence was tap, nothing, tap, and
# a set you did reading as not done.
#
# Driven in a real browser because both halves of the fix are the browser's: htmx disables
# the button for the life of the request, and the CSS that says so keys off a class htmx
# adds. Neither exists in a Rack::Test run, where the post simply succeeds twice.
# Both clicks are issued from JavaScript in one go, so the second lands while the first is
# still in flight. Clicking twice through Capybara would not test this at all: it waits for
# the page to settle in between, which is the case that already worked.
TAP_DONE_TWICE = <<~JS
  (function () {
    var button = Array.prototype.find.call(
      document.querySelectorAll('button'),
      function (b) { return b.textContent.trim() === 'Done'; }
    );
    button.click();
    window.secondTapWasRefused = button.disabled;
    button.click();
  })()
JS

describe 'tapping Done twice before the first tap answers' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  before { a_session_with_one_set_at 135 }

  it 'is refused, and the set stays done' do
    page.execute_script(TAP_DONE_TWICE)

    assert page.has_button?('Undo'), 'the set should have been completed and stayed completed'
    refute page.has_button?('Done'), 'a second tap should not have toggled it back'
  end

  it 'disables the button for the life of the request' do
    page.execute_script(TAP_DONE_TWICE)

    assert page.evaluate_script('window.secondTapWasRefused === true'),
           'the button should already be disabled when the second tap arrives'
  end
end

# The other half. Disabling the button on its own would make a deliberate second tap feel
# broken rather than do nothing, so the screen has to say the first one landed.
describe 'what the screen does while a tap is in flight' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  before { a_session_with_one_set_at 135 }

  # htmx marks the element making the request with htmx-request for as long as it is in
  # flight. That was already true; what was missing was any rule drawing something for it.
  it 'draws a ring on the button rather than fading it' do
    ring = page.evaluate_script(<<~JS)
      (function () {
        var form = document.querySelector('form[hx-disabled-elt]');
        form.classList.add('htmx-request');
        var button = form.querySelector('button');
        var style = window.getComputedStyle(button);
        var result = { shadow: style.boxShadow, opacity: style.opacity, animation: style.animationName };
        form.classList.remove('htmx-request');
        return result;
      })()
    JS

    refute_equal 'none', ring['animation'], 'an in-flight button should be doing something visible'
    assert_equal '1', ring['opacity'], 'and should not fade, which is what a disabled control looks like'
  end
end

