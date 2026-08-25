# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The nav's links, measured against the bar they sit on. They arrived in the gray-500 of a
# stock nav that sits on white, where it is 4.83:1 and passes; this bar is lime-500, where
# the same grey is 2.45:1, and hover:text-white took it to 1.98:1 -- so pointing at a link
# made it harder to read than leaving it alone. Nothing moves when a colour is wrong: the
# page renders, the row still fits, every other spec passes, and the only symptom is text
# somebody cannot read. So the ratios are computed from the classes the markup carries,
# rather than left to a screenshot nobody takes twice.
module NavContrast
  # WCAG 2.1 AA for text that is neither 24px nor 18.66px bold, which is this row at both
  # of its sizes: text-base on a phone, text-xl from 640px up.
  AA = 4.5
  BAR = [132, 204, 22].freeze # bg-lime-500, pinned in a spec below rather than assumed

  # Only the colours this nav has worn. gray-500 and white are still in the table on
  # purpose: if either comes back, the failure is the ratio it comes back at rather than a
  # missing key, which would leave the next person working out which class did it.
  PALETTE = {
    'gray-500' => [107, 114, 128],
    'gray-900' => [17, 24, 39],
    'white' => [255, 255, 255]
  }.freeze

  # A colour utility and not a size one: text-base and sm:text-xl are also `text-`.
  COLOUR = %r{\Atext-(?<name>[a-z]+-\d{2,3}|white|black)(?:/(?<alpha>\d+))?\z}

  def app = Tectonic.app

  def nav = last_response.body[%r{<nav\b.*?</nav>}m].to_s

  def nav_tag = nav[/\A<nav\b[^>]*>/].to_s

  def nav_links = nav.scan(/<a\b[^>]*>/)

  def classes_of(element) = element[/\sclass="([^"]*)"/, 1].to_s.split

  def href(link) = link[/href="([^"]*)"/, 1]

  def wordmark = nav_links.find { |link| href(link) == '/' }

  def links_beside_the_wordmark = nav_links - [wordmark]

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'), created_on: Time.now)
    get '/login'
    csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post '/login', { login: email, password: 'pw12345678', '_csrf' => csrf }
  end

  def colour(link, prefix)
    classes_of(link).filter_map { |name| COLOUR.match(name.delete_prefix(prefix)) if name.start_with?(prefix) }.first
  end

  def resting(link) = colour(link, '') || flunk("#{href(link)} names no text colour of its own")

  # A link with no hover colour keeps the one it is resting in, which is what the wordmark
  # does, so this answers for every link rather than only the ones that state a hover.
  def hovered(link) = colour(link, 'hover:') || resting(link)

  # Composited over the bar, because an alpha colour is only as legible as what is behind
  # it, and what is behind these is the nav.
  def rendered(match)
    rgb = PALETTE.fetch(match[:name]) { flunk "the nav wears text-#{match[:name]}, which this spec has no value for" }
    return rgb unless match[:alpha]

    alpha = match[:alpha].to_f / 100
    rgb.zip(BAR).map { |over, under| (alpha * over) + ((1 - alpha) * under) }
  end

  def luminance(rgb)
    red, green, blue = rgb.map { |channel| channel / 255.0 }
                          .map { |c| c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4) }
    (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
  end

  def contrast(match)
    darker, lighter = [luminance(rendered(match)), luminance(BAR)].minmax
    (lighter + 0.05) / (darker + 0.05)
  end

  def assert_legible(link)
    at_rest = contrast(resting(link))
    on_hover = contrast(hovered(link))

    assert_operator at_rest, :>=, AA, "#{href(link)} is #{at_rest.round(2)}:1 at rest"
    assert_operator on_hover, :>=, AA, "#{href(link)} is #{on_hover.round(2)}:1 hovered"
  end

  def assert_hover_is_not_a_step_down
    nav_links.each do |link|
      assert_operator contrast(hovered(link)), :>=, contrast(resting(link)),
                      "hovering #{href(link)} makes it less legible than leaving it alone"
    end
  end
end

describe 'the nav a signed-in account reads' do
  include Rack::Test::Methods
  include NavContrast

  before do
    sign_in
    get '/workouts'
  end

  # Every ratio in this file is measured against this one class. If the bar stops being
  # lime-500 the arithmetic still runs and the answers are all quietly wrong, so it is
  # pinned here and the failure lands next to the numbers that depend on it.
  it 'is the lime bar the rest of these numbers are measured against' do
    assert_includes classes_of(nav_tag), 'bg-lime-500'
  end

  it 'clears AA on all eight links, at rest and hovered' do
    assert_equal 8, nav_links.length
    nav_links.each { |link| assert_legible link }
  end

  # The whole of the bug in one assertion: gray-500 at 2.45:1 went to white at 1.98:1, so
  # the affordance that says "this is a link" was the thing that made it hardest to read.
  it 'never makes hovering a link less legible than leaving it alone' do
    assert_hover_is_not_a_step_down
  end

  # nav.erb says the wordmark is set apart by darker text and a border that is not
  # transparent. Flat gray-900 on the links would clear AA too, and would take the first
  # half of that away and leave the border doing the job alone; the alpha is what keeps it.
  it 'leaves the wordmark darker than the links beside it' do
    assert_operator contrast(resting(wordmark)), :>,
                    links_beside_the_wordmark.map { |link| contrast(resting(link)) }.max
  end
end

describe 'the nav a visitor reads' do
  include Rack::Test::Methods
  include NavContrast

  before { get '/welcome' }

  it 'clears AA on the wordmark and both account links, at rest and hovered' do
    assert_equal 3, nav_links.length
    nav_links.each { |link| assert_legible link }
  end

  it 'never makes hovering a link less legible than leaving it alone' do
    assert_hover_is_not_a_step_down
  end
end

