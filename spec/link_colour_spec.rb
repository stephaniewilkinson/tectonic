# frozen_string_literal: true

require_relative 'spec_helper'

# One link colour, pinned. The app answered "which lime is a link" four ways at once and
# two of the answers were unreadable. The Edit at the end of every set row on a workout
# record was lime-400, 1.51:1 against white, hovering to lime-300 at 1.31:1 -- so the only
# way to correct a set from the record faded as you reached for it. The account links on
# /login and /create-account were lime-500 at 1.98:1.
#
# lime-700 is 4.99:1, the one step in Tailwind's lime scale that clears WCAG AA's 4.5:1
# for body text, and hover goes to lime-800 at 7.08:1 -- darker, where every old pair went
# lighter.
#
# Read off the templates rather than off rendered pages. Nine views would need nine sets
# of fixtures to reach, and a rule that only holds on the pages somebody remembered to
# seed is a rule that comes back the moment a tenth page is written. Nothing moves when a
# link is the wrong green: the page renders, every other spec passes, and the only symptom
# is a link nobody can see.
module LinkColour
  VIEWS = File.expand_path('../views', __dir__)

  # Every anchor in every template, as [file, class list]. ERB tags go first because
  # `%>` closes with the same character an HTML tag does, so an href holding one would
  # otherwise cut the match off before the class attribute -- which is how a link with
  # no colour and a link with the wrong colour would have looked alike here.
  def self.links
    Dir[File.join(VIEWS, '**', '*.erb')].flat_map do |path|
      File.read(path).gsub(/<%.*?%>/m, '').scan(/<a\b[^>]*>/m).map do |tag|
        [path.delete_prefix("#{VIEWS}/"), tag[/\sclass="([^"]*)"/m, 1].to_s.split]
      end
    end
  end

  # Links painted a lime of their own. A link left at the colour of the text around it
  # carries no text-lime token at all and is not one of these.
  def self.lime = links.select { |(_, classes)| classes.grep(/\Atext-lime-/).any? }
end

describe 'the colour a link is written in' do
  it 'has some links to check in the first place' do
    refute_empty LinkColour.lime
  end

  it 'paints every one of them lime-700' do
    LinkColour.lime.each do |file, classes|
      assert_equal ['text-lime-700'], classes.grep(/\Atext-lime-/), "in #{file}"
    end
  end

  # lime-600 to lime-500 and lime-400 to lime-300 both faded the link under the pointer,
  # which is the backwards direction #124 describes for the buttons.
  it 'darkens them on hover rather than fading them' do
    LinkColour.lime.each do |file, classes|
      assert_equal ['hover:text-lime-800'], classes.grep(/\Ahover:text-lime-/), "in #{file}"
    end
  end
end

describe 'the two ways into a workout on the workout list' do
  # Show and Edit carried no class whatsoever, so Tailwind's preflight left them the
  # cell's text-gray-500 and they read as two more facts about the row beside the set
  # count. Delete, in the next column, is red-600 and does look like a control, so the row
  # read as one destructive button and two pieces of data.
  it 'paints them the same as every other link' do
    classes = LinkColour.links.filter_map { |file, list| list if file == 'workouts/_table.erb' }

    assert_equal 2, classes.length
    classes.each { |list| assert_includes list, 'text-lime-700' }
  end
end

