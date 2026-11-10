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

  # What a custom property is set to in the compiled stylesheet, as written.
  def variable(name) = stylesheet[/--color-#{Regexp.escape(name)}:\s*([^;}]+)/, 1]&.strip

  # Tailwind 3's value for each step a role mirrors. Pinned in assets/css/app.css's @theme
  # because Tailwind 4 redefined its palette, and every contrast ratio here was measured
  # against these. If one of them moves, a colour on the live site moved with it.
  V3 = { 'lime-50' => '#f7fee7', 'lime-300' => '#bef264', 'lime-500' => '#84cc16',
         'lime-600' => '#65a30d', 'lime-700' => '#4d7c0f', 'sky-800' => '#075985',
         'sky-900' => '#0c4a6e', 'amber-50' => '#fffbeb', 'amber-200' => '#fde68a',
         'amber-800' => '#92400e' }.freeze
end

describe 'the palette custom properties' do
  include Rack::Test::Methods
  include Palette

  it 'defines one for every role' do
    Palette::MIRRORS.each_key do |role|
      refute_nil variable(role), "--color-#{role} is not in the compiled stylesheet"
    end
  end

  # The one that matters. Each role names the scale step it mirrors, so the two cannot part;
  # this holds which step that is, so changing it is a deliberate edit to a spec.
  it 'gives each role exactly the colour of the utility it names' do
    Palette::MIRRORS.each do |role, tailwind|
      assert_equal "var(--color-#{tailwind})", variable(role), "--color-#{role} no longer mirrors #{tailwind}"
    end
  end

  # And each of those steps is still the colour it was before Tailwind 4.
  it 'keeps every mirrored step at its Tailwind 3 value' do
    Palette::V3.each do |step, hex|
      assert_equal hex, variable(step), "--color-#{step} is not the colour the palette was chosen against"
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

