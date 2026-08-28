# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# The palette, as custom properties, held against the Tailwind utilities it names.
#
# #238 asked for a colour vocabulary that exists somewhere other than in comments. It is in
# assets/css/app.css as plain CSS variables rather than as renamed utilities, because
# renaming buys nothing portable -- `bg-action-500` is as Tailwind-shaped as `bg-lime-500`
# -- while a custom property is CSS that outlives whatever compiles it.
#
# That leaves one way to be wrong, and it is the reason this file exists. Two definitions of
# the same colour now sit in two places: `--color-action` in app.css and `lime-500` in
# Tailwind's own scale, which every existing template still uses. If they drift, half the
# app is one green and half is another, and nothing else would say so -- both compile, both
# render, and the difference between #84cc16 and #65a30d is not something anybody catches by
# looking at a page.
#
# So each variable is asserted equal to the utility it mirrors, both read out of the
# compiled stylesheet. That is the same trick display_face_spec uses for typefaces: read the
# built artefact rather than a list written down beside the thing it describes.
module Palette
  def app = Tectonic.app

  # What every role means, as the Tailwind class whose colour it must equal. Written as the
  # pairing rather than as two lists so that adding a variable without pinning it is not a
  # thing this file lets you do quietly.
  MIRRORS = {
    'action' => 'lime-500',                 # the primary button fill
    'action-strong' => 'lime-600',          # its hover step, one down its own scale (#165)
    'action-text' => 'lime-700',            # the link colour: 4.99:1 on white, AA for body
    'session' => 'sky-800',                 # Done, and Run session on the record
    'session-strong' => 'sky-900',          # their hover step
    'done-surface' => 'lime-50',            # a completed set row
    'done-edge' => 'lime-300',              # and its border
    'warning-surface' => 'amber-50',        # the two callouts, and nothing else (#214)
    'warning-edge' => 'amber-200',
    'warning-text' => 'amber-800'
  }.freeze

  def stylesheet
    get '/assets/css/styles.css'
    last_response.body
  end

  # The three channels a variable is defined as, e.g. "132 204 22".
  def variable(name) = stylesheet[/--color-#{name}:\s*([0-9]+ [0-9]+ [0-9]+)/, 1]

  # The three channels Tailwind compiled for one of its own colours. Matched on the class
  # name and then on the next rgb() in that rule, so it finds the colour whichever utility
  # happens to carry it -- lime-600 is only ever compiled behind a `hover:` prefix, and
  # lime-300 only as a border.
  def utility(name) = stylesheet[/[.\\][^{}]*#{Regexp.escape(name)}[^{}]*\{[^}]*?rgb\(([0-9]+ [0-9]+ [0-9]+)/, 1]
end

describe 'the palette custom properties' do
  include Rack::Test::Methods
  include Palette

  it 'defines one for every role' do
    Palette::MIRRORS.each_key do |role|
      refute_nil variable(role), "--color-#{role} is not in the compiled stylesheet"
    end
  end

  # The one that matters. Two definitions of one colour, and this is what stops them parting.
  it 'gives each role exactly the colour of the utility it names' do
    Palette::MIRRORS.each do |role, tailwind|
      expected = utility(tailwind)

      refute_nil expected, "#{tailwind} is not compiled, so this pairing cannot be checked"
      assert_equal expected, variable(role),
                   "--color-#{role} and #{tailwind} have drifted apart"
    end
  end

  # Channels rather than hex, and not by preference: Tailwind substitutes an alpha into
  # `rgb(var(--x) / <alpha-value>)`, so a hex here would compile and then quietly produce
  # nothing for `bg-action/70`, the way `text-gray-900/70` is used in the nav today.
  it 'writes them as space-separated channels, which is what the alpha modifier needs' do
    Palette::MIRRORS.each_key do |role|
      assert_match(/\A\d{1,3} \d{1,3} \d{1,3}\z/, variable(role), "--color-#{role} is not three channels")
    end
  end
end

# The point of doing it this way rather than by renaming: nothing was taken away. Every
# template still uses Tailwind's own scale, and it all still resolves.
describe 'what the palette did not change' do
  include Rack::Test::Methods
  include Palette

  it 'leaves the utilities every template is written in' do
    sheet = stylesheet

    ['.bg-lime-500', '.bg-white', '.text-gray-900'].each do |utility|
      assert_includes sheet, utility, "#{utility} went missing; this was meant to add names, not move any"
    end
  end
end

