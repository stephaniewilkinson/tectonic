# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require

# The date on the workout form is the platform's own control and arrives with the page. #524.
#
# It used to be a `type="text"` box with Flowbite's datepicker bound to it, fetched from
# cdnjs on every render of both the new and the edit page. Four things were wrong with that
# and they are separable, which is why they are asserted separately here.
#
# It was a third-party script, and the only one in the app besides the analytics tag. It
# carried no integrity hash, so the page executed whatever that URL served. It could not be
# fetched at all without a connection, and a lifter writing a session up in a basement got a
# bare text box demanding a hand-typed `09/23/2026` next to a calendar icon that no longer
# opened anything -- silently, in an app that since #516 tells somebody plainly when a tap did
# not reach the server. And because the field was text, iOS never offered the date wheel it
# already has.
#
# Asserted against the rendered HTML of both pages rather than against the partial, because
# one partial serving two routes is exactly the arrangement where a change is verified on the
# page somebody happened to open.
module NativeDateField
  def app = Tectonic.app

  def workout_pages(account_id)
    workout = own_workout(account_id)
    ['/workouts/new', "/workouts/#{workout}/edit"]
  end

  def body_of(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    last_response.body
  end

  def date_input(path) = body_of(path)[/<input\b[^>]*\bid="date"[^>]*>/].to_s

  # The form itself, not the page around it: the nav and the footer draw icons of their own,
  # and the assertion below is about the one that used to sit inside this field's wrapper.
  def form_on(path) = body_of(path)[%r{<form[^>]*action="/workouts"[^>]*>.*?</form>}m].to_s
end

describe 'the date field on the workout form' do
  include Rack::Test::Methods
  include RouteOwnership
  include NativeDateField

  before { @pages = workout_pages(login) }

  # The whole of the fix, in one attribute. Everything else here follows from it: a native
  # date control needs no script, so there is nothing to fetch and nothing to fail, and it is
  # what lets a phone offer the picker it ships with.
  it 'is a native date input on both the pages that share it' do
    @pages.each { |path| assert_includes date_input(path), 'type="date"' }
  end

  it 'loads no script from a CDN' do
    @pages.each { |path| refute_includes body_of(path), 'cdnjs.cloudflare.com' }
  end

  # Named separately from the CDN above, because vendoring that script into /js would have
  # answered the offline half and left the rest: a datepicker built for a mouse, no iOS wheel,
  # and a month-first string posted back to be guessed at.
  it 'asks for no datepicker at all' do
    @pages.each { |path| refute_includes body_of(path), 'datepicker' }
  end

  # The icon and its absolutely positioned wrapper decorated a text box into looking like a
  # date field. A native one draws its own, so a leftover glyph would be a second calendar
  # that opens nothing -- which is precisely what the broken version looked like.
  it 'leaves behind no calendar icon that opens nothing' do
    @pages.each do |path|
      form = form_on(path)

      refute_empty form, "no form posting to /workouts on #{path}"
      refute_includes form, '<svg'
    end
  end

  # Posted and rendered in one format, in both directions, which is #440's rule surviving the
  # change of format. A native date input renders an ISO value and posts one; anything else in
  # the box is a value it refuses to display, so the edit page would open empty and the next
  # save would lose the date.
  it 'renders the value in the one format that input will accept' do
    assert_equal '%Y-%m-%d', Tectonic::Workout::FORM_DATE
  end
end

