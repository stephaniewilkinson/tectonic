# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'session_row_spec' # reuses its one-lift session; idempotent require

# Which face a number is set in. styles.css hung Blonde Sans off the size utilities as
# well as off h1-h6, so the face was decided by how big a thing happened to be: a working
# set at text-2xl came out in the display face and the warmup at text-lg above it did
# not, and every figure on /volume came out in it while every label beside it did not.
# Nobody chose either of those.
#
# Nothing moves when this is wrong. The page renders, the numbers are right, every other
# spec passes, and the only symptom is two sets of letterforms in one column on somebody's
# screen -- so the face is asserted here against the markup and the stylesheet together,
# rather than looked at.
module DisplayFace
  def app = Tectonic.app

  # Comments stripped: they name the selectors they are about, and this reads selectors.
  def stylesheet
    get '/assets/css/styles.css'
    last_response.body.gsub(%r{/\*.*?\*/}m, '')
  end

  # Every class token the stylesheet hands a Blonde face to, read out of the stylesheet
  # rather than written down here. A list written down here would go on passing the day
  # `.text-2xl` came back into the font rule, which is the whole thing being guarded.
  #
  # Blonde rather than any font-family since #142: the stylesheet is a compiled Tailwind
  # build now and carries `.font-mono`, which grants a face and has nothing to do with this
  # brand. "Names a font-family" was only ever a proxy for "grants the brand face" and the
  # two stopped being the same thing the moment the utilities arrived.
  def face_classes
    @face_classes ||= stylesheet.split('}')
                                .grep(/font-family:\s*"?Blonde/)
                                .flat_map { |block| block.split('{').first.to_s.scan(/\.([\w-]+)/) }
                                .flatten.uniq
  end

  def classes_of(tag) = tag[/\sclass="([^"]*)"/, 1].to_s.split

  # The face-granting classes an element names, so [] means it is in the system face and
  # anything else says which face it asked for.
  def face_of(tag) = classes_of(tag) & face_classes

  def tags_matching(pattern) = last_response.body.scan(pattern)
end

describe 'the classes the stylesheet gives a Blonde face to' do
  include Rack::Test::Methods
  include DisplayFace

  it 'is the two that name a face and no size at all' do
    assert_equal %w[serif brand], face_classes
  end
end

# The screen a lifter reads with a bar in their hands, and the one place the two faces
# sat a centimetre apart.
describe 'a weight on the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow
  include DisplayFace

  before { session(weight: 225) }

  # 45 x 5 and 225 x 5 are the same kind of thing said twice, and the state of a set is
  # already carried by the row tint and by the Done button, so the typeface was left
  # saying nothing while looking like it said something.
  #
  # Matched on the pair of classes that make a span a load -- a size first, and gray-900,
  # which no other span on the row wears -- rather than on the sizes themselves. It named
  # text-lg and text-2xl, which was the difference #207 has since removed, so a pattern
  # written that way found one span instead of two and failed on a nil rather than on the
  # faces. The sizes are this spec's subject only in that it must not depend on them.
  it 'reads in the same face as the warmup above it' do
    warmup, working = tags_matching(/<span class="text-[^"]*text-gray-900">/)

    refute_nil working, 'both the warmup and the working set should carry a load'
    assert_equal face_of(warmup), face_of(working)
    assert_empty face_of(working)
  end
end

describe 'the stats on /volume' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow
  include DisplayFace

  before do
    session(weight: 225, working_done: true)
    get '/volume'
  end

  it 'has four figures to set' do
    assert_equal 4, tags_matching(/<dd\b[^>]*>/).length
  end

  # This asserted the opposite until #200: that a figure and its label read in one face,
  # because the display face was on these by accident of text-2xl and #128 took it off.
  #
  # It is on them deliberately now. They are the only numbers in the app that are a result
  # rather than an instruction -- read to feel something about a season, not to load a bar
  # -- which is the line app.css now draws. The labels stay in the system face: a label is
  # read at a glance and is not the thing on display.
  it 'sets every figure in the display face and every label in the system one' do
    labels = tags_matching(/<dt\b[^>]*>/)
    figures = tags_matching(/<dd\b[^>]*>/)

    assert_equal 4, figures.length
    figures.each { |figure| assert_equal ['serif'], face_of(figure) }
    labels.each { |label| assert_empty face_of(label) }
  end
end

# The rule #200 asked for, asserted where it can be: a display surface is read rather than
# used. These are the four the issue named, and the last of them is the line -- a screen you
# act on is not a display surface however large its title is.
describe 'the surfaces that take the display face' do
  include Rack::Test::Methods
  include RouteOwnership
  include DisplayFace

  def heading_face(path)
    get path
    face_of(last_response.body[/<h1\b[^>]*>/].to_s)
  end

  # /welcome rather than /, which redirects to it when signed out.
  it 'gives the marketing page its whole voice, not only its headline' do
    get '/welcome'
    copy = tags_matching(/<p class="[^"]*text-lg[^"]*">/)

    refute_empty copy
    copy.each { |line| assert_equal ['serif'], face_of(line) }
  end

  it 'titles /about, which had no heading at all' do
    assert_equal ['serif'], heading_face('/about')
  end

  it 'sets the date on a workout record, which titles a thing that happened' do
    account_id = login
    workout_id = own_workout(account_id)

    assert_equal ['serif'], heading_face("/workouts/#{workout_id}")
  end
end

# The line the rule draws, and the half of it that is easy to lose: a screen you act on is
# not a display surface however large its title is. /volume is the one worth naming --
# its four figures take the face and its own heading does not, because the figures are the
# result and the heading is a label on a screen you came to use.
describe 'the surfaces that do not' do
  include Rack::Test::Methods
  include RouteOwnership
  include DisplayFace

  def heading_face(path)
    get path
    face_of(last_response.body[/<h1\b[^>]*>/].to_s)
  end

  it 'leaves the titles of the screens you use in the heading face' do
    login

    ['/workouts', '/exercises', '/volume'].each do |path|
      assert_empty heading_face(path), "#{path} is a screen you use, not one you read"
    end
  end
end

# The other half of the change: what is not a heading and does want the face now says so,
# rather than having it because of a size that is free to change.
describe 'the surfaces that do want the display face' do
  include Rack::Test::Methods
  include RouteOwnership
  include DisplayFace

  it 'names it on the exercise link on a workout, which is an anchor and not a heading' do
    account_id = login
    workout_id = own_workout(account_id)
    exercise_id = DB[:exercises].insert(name: "Front Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 135, reps: 5, is_warmup: false, is_completed: false)

    get "/workouts/#{workout_id}"

    assert_equal ['brand'], face_of(tags_matching(%r{<a href="/exercises/\d+"[^>]*>}).first)
  end

  # The exercise edit title was the other one, a div carrying `brand`. It is an h1 now, so
  # it takes the face from the element and there is nothing here left to name: what it has
  # to be is pinned in page_title_spec with the rest of the titles.

  # The front page headline is Blonde Serif and 128px on a desktop. It took the serif from
  # a class that beat the size rules on source order alone; with those gone it beats the
  # element selector on specificity, which is a sturdier reason for the same result.
  it 'leaves the front page headline on the serif' do
    get '/welcome'

    headline = tags_matching(/<h1[^>]*>/).first

    assert_equal ['serif'], face_of(headline)
    assert_includes classes_of(headline), 'md:text-9xl'
  end
end

