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
  def face_classes
    @face_classes ||= stylesheet.split('}')
                                .select { |block| block.include?('font-family') }
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
  it 'reads in the same face as the warmup above it' do
    warmup, working = tags_matching(/<span class="text-(?:lg|2xl)[^"]*">/)

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

  # A figure and the word for it are one reading, and the page is nothing but four of
  # them. The display face is drawn for a headline; asked for digits at 24px it was the
  # least legible thing on the page whose whole job those four numbers are.
  it 'sets every figure in the same face as its label' do
    labels = tags_matching(/<dt\b[^>]*>/)
    figures = tags_matching(/<dd\b[^>]*>/)

    labels.zip(figures).each do |label, figure|
      assert_equal face_of(label), face_of(figure)
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

  it 'names it on the exercise edit title, which is a div and not a heading' do
    account_id = login
    exercise_id = DB[:exercises].insert(name: "Deadlift #{SecureRandom.hex(4)}", account_id:)

    get "/exercises/#{exercise_id}/edit"

    assert_equal ['brand'], face_of(tags_matching(/<div class="brand[^"]*">/).first)
  end

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

