# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# The shapes this app writes once and uses many times. #239.
#
# Fifteen distinct input class strings were written out across views/, and two of them were
# the same control at two radii -- rounded-md on four fields and rounded-lg on three that
# differed from those four in nothing else. Nobody chose that; it is what happens when the
# next person editing one field has no way to know there are thirty others.
#
# It is the drift button_style was introduced to stop. That helper's own note says so: "the
# rounded-lg both copies carried was one of the three radii that helper exists to settle."
# field_style and nav_link_style are the same answer for the two other things this app
# repeats, and _chevron.erb is that answer for a piece of markup rather than a class list.
#
# Asserted against the templates rather than against rendered pages, because what is being
# guarded is where a decision is written, not what a page looks like. A field that spells
# its own ring out renders identically today and is the thing that goes wrong later.
module NamedStyles
  def app = Tectonic.app

  def templates = Dir[File.expand_path('../views/**/*.erb', __dir__)]

  # Every class="..." in the templates, as a list of tokens, with the file it came from.
  def class_lists
    templates.flat_map do |path|
      File.read(path).scan(/class="([^"]*)"/).flatten.map { |classes| [path, classes] }
    end
  end
end

describe 'the input shape' do
  include Rack::Test::Methods
  include NamedStyles

  # A field is anything with border-0 and the grey ring. The white secondary button also
  # carries ring-gray-300 and is deliberately not in scope -- button_style's note leaves it
  # alone because it is already identical at all of its sites, which is the state this is
  # trying to reach for inputs.
  it 'is named rather than written out at each field' do
    hand_written = class_lists.select do |_path, classes|
      tokens = classes.split
      tokens.include?('border-0') && tokens.include?('ring-gray-300') && !classes.include?('field_style')
    end

    assert_empty hand_written.map { |path, classes| "#{File.basename(path)}: #{classes}" },
                 'these fields spell out the shape field_style exists to settle'
  end

  # The half that matters more than the count: one radius, not two. A field and the button
  # under it now agree, because field_style and button_style both say rounded-md.
  it 'settles on one radius, and the same one buttons use' do
    app_source = File.read(File.expand_path('../app.rb', __dir__))
    field = app_source[/def field_style\n(.*?)\n  end/m, 1]
    button = app_source[/def button_style\n(.*?)\n  end/m, 1]

    assert_includes field, 'rounded-md'
    assert_includes button, 'rounded-md', 'a field and a button should not disagree by two pixels'
  end
end

describe 'the nav link shape' do
  include Rack::Test::Methods
  include NamedStyles

  # Ten links, two states -- the one you are on and the nine you are not -- differing only
  # in colour, hover and a transparent border. All ten wrote the shape out in full.
  it 'is named rather than written out at each link' do
    hand_written = class_lists.select do |_path, classes|
      classes.include?('inline-flex') && classes.include?('border-b-2') && !classes.include?('nav_link_style')
    end

    assert_empty(hand_written.map { |path, classes| "#{File.basename(path)}: #{classes}" })
  end
end

describe 'the disclosure chevron' do
  include Rack::Test::Methods
  include NamedStyles

  # Path data written out three times is three places to fix when the shape changes. The
  # marker is not decoration -- a summary is display:list-item and these are flex rows, so
  # flex overrides list-item and no marker rendered at all until #208 drew one.
  # Keyed on group-open:rotate-90 rather than on the path data, because welcome.erb draws
  # the same arrow for something else -- a "Just shipped v1.0" badge inherited from the
  # template this page started as, which sits inside a `hidden` div and renders for nobody.
  # Same shape, different job, and it does not rotate; folding it in here would be matching
  # on coincidence.
  it 'is one partial rather than three copies of the path' do
    drawn = templates.count { |path| File.read(path).include?('group-open:rotate-90') }

    assert_equal 1, drawn, 'the disclosure chevron should live in views/_chevron.erb and nowhere else'
  end

  it 'is still rendered where a disclosure needs one' do
    users = templates.count { |path| File.read(path).include?("render('_chevron')") }

    assert_equal 2, users, 'the rating scale and the two revision disclosures use it'
  end
end

