# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The programme screens, driven as a logged-in browser drives them. A stranger's block is
# present throughout: the routes take an id from the path, so every one of them has to
# resolve it through the account rather than take it on trust.
module Programming
  def app
    Tectonic.app
  end

  def sign_up
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'))
    get '/login'
    post '/login', { login: email, password: 'pw12345678', '_csrf' => token_from(last_response.body) }
    DB[:accounts].where(email:).get(:id)
  end

  def token_from(body)
    body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
  end

  # The token the form at `action` carries, taken from the page it is rendered on.
  def token_for(page, action)
    get page
    last_response.body[/action="#{Regexp.escape(action)}"[^>]*>.*?name="_csrf"[^>]*value="([^"]*)"/m, 1]
  end

  def block_for(account, name: 'Block 0')
    program = Tectonic::Program.create(account_id: account, name:, start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
    [program, week, day]
  end

  def lift_in(day, account, weight: 155)
    exercise = Tectonic::Exercise.create(account_id: account, name: "Squat #{SecureRandom.hex(4)}",
                                         is_barbell: true)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 5, top_weight: weight, progression: 'linear',
                                 is_barbell: true, is_main: true)
  end

  # An account, a block with one lift on it, and that block's page already fetched.
  def a_block_page
    account = sign_up
    program, _week, day = block_for(account)
    lift_in(day, account)
    get "/programs/#{program.id}"
    program
  end

  # Every control the editor draws, as [tag, the rest of its opening tag]. Scoped to
  # <main> because the nav's links are sized in views/nav.erb and answer to that file, not
  # this one; a hidden input is dropped because it has no box and nothing can tap it.
  def editor_controls(body)
    body[%r{<main>(.*)</main>}m, 1]
      .scan(/<(input|select|button|a)\s([^>]*)>/)
      .reject { |_tag, attributes| attributes.include?('type="hidden"') }
  end

  def classes_of(control)
    control.last[/class="([^"]*)"/, 1].to_s
  end
end

describe 'the programs list' do
  include Rack::Test::Methods
  include Programming

  it 'requires a login' do
    get '/programs'
    assert_equal 302, last_response.status
  end

  it 'lists only this account\'s blocks' do
    stranger = sign_up
    block_for(stranger, name: 'StrangersBlock')

    account = sign_up
    block_for(account, name: 'MyBlock')
    get '/programs'

    assert_includes last_response.body, 'MyBlock'
    refute_includes last_response.body, 'StrangersBlock'
  end

  it 'creates a block with its first week, so there is somewhere to add a day' do
    sign_up
    post '/programs', { name: 'New Block', start_date: Date.today.to_s,
                        '_csrf' => token_for('/programs', '/programs') }

    program = Tectonic::Program.where(name: 'New Block').first
    assert_equal 1, program.weeks
  end
end

describe 'editing a lift' do
  include Rack::Test::Methods
  include Programming

  before do
    @account = sign_up
    @program, _week, day = block_for(@account)
    @lift = lift_in(day, @account)
  end

  def save(params)
    action = "/programs/#{@program.id}/lifts/#{@lift.id}"
    post action, params.merge('_csrf' => token_for("/programs/#{@program.id}", action))
  end

  it 'changes the load' do
    save({ 'sets' => '3', 'reps' => '5', 'top_weight' => '165', 'percent_of_max' => '' })
    assert_equal 165, @lift.refresh.top_weight
  end
end

# The two prices are exclusive. The writer already knew that; what the browser adds is
# somewhere for its refusal to be read rather than becoming a 500 or a half-written row.
describe 'pricing a lift' do
  include Rack::Test::Methods
  include Programming

  before do
    @account = sign_up
    @program, _week, day = block_for(@account)
    @lift = lift_in(day, @account)
  end

  def save(params)
    action = "/programs/#{@program.id}/lifts/#{@lift.id}"
    post action, params.merge('_csrf' => token_for("/programs/#{@program.id}", action))
  end

  it 'refuses a lift priced two ways and says so' do
    save({ 'sets' => '3', 'reps' => '5', 'top_weight' => '165', 'percent_of_max' => '80' })

    assert_equal 155, @lift.refresh.top_weight
    get "/programs/#{@program.id}"
    assert_includes last_response.body, 'exactly one of'
  end

  it 'swaps pounds for a percentage when the other is cleared in the same save' do
    save({ 'sets' => '3', 'reps' => '5', 'top_weight' => '', 'percent_of_max' => '80' })

    assert_nil @lift.refresh.top_weight
    assert_equal 'percent', @lift.refresh.progression
  end
end

describe 'reaching a block that is not yours' do
  include Rack::Test::Methods
  include Programming

  it "redirects rather than showing a stranger's block" do
    stranger = sign_up
    program, = block_for(stranger)

    sign_up
    get "/programs/#{program.id}"

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], '/programs'
  end
end

describe 'reaching a lift that is not yours' do
  include Rack::Test::Methods
  include Programming

  # This one only proves the CSRF token is bound to its path: no form on my page carries a
  # token for a lift that is not mine, so the post dies before the lookup runs. Worth
  # asserting, but it is not the ownership check, which is reached directly below.
  it "refuses a post aimed at a lift in a stranger's block" do
    stranger = sign_up
    program, _week, day = block_for(stranger)
    lift = lift_in(day, stranger)

    account = sign_up
    mine, = block_for(account)
    action = "/programs/#{mine.id}/lifts/#{lift.id}"
    post action, { 'top_weight' => '999', '_csrf' => token_for("/programs/#{mine.id}", action) }

    refute_equal 999, lift.refresh.top_weight
    assert_equal program.id, lift.program_day.program_week.program_id
  end

  # The guard itself. A lift is reached through the block that owns it, so naming one from
  # another account resolves to nothing rather than to their training. Removing the day
  # and week filter from ProgramEditor#lift has to fail this.
  it 'does not resolve a lift that belongs to another account' do
    stranger = sign_up
    _program, _week, day = block_for(stranger)
    lift = lift_in(day, stranger)

    account = sign_up
    mine, = block_for(account)

    assert_nil Tectonic::ProgramEditor.new(account).lift(mine, lift.id)
  end
end

# The editor is the screen a lifter opens with one hand on a phone between weeks, and every
# control on it used to be 28px tall or less. These assert the class rather than the pixel
# because a spec that boots Firefox to measure a rectangle is slow and the class is what a
# careless edit actually drops; the pixels are in the pull request that set them.
describe 'the size of a control in the block editor' do
  include Rack::Test::Methods
  include Programming

  before do
    a_block_page
    @controls = editor_controls(last_response.body)
  end

  it 'gives every one of them a box 44px tall' do
    undersized = @controls.reject { |control| classes_of(control).include?('min-h-11') }
    named = undersized.map { |tag, attributes| "#{tag} #{attributes[/\A[^\n]*/]}" }

    refute_empty @controls, 'the scan matched nothing, so it can prove nothing'
    assert_empty named
  end

  # 16px is the size below which iOS Safari zooms the page to meet the field a finger has
  # just tapped, and leaves it zoomed. It applies to what takes focus, so the buttons on
  # the same row are deliberately not in this list.
  it 'sets the fields in 16px type' do
    fields = @controls.select { |control| %w[input select].include?(control.first) }
    small = fields.reject { |field| classes_of(field).include?('text-base') }
    named = small.map { |_tag, attributes| attributes[/aria-label="[^"]*"/] }

    refute_empty fields
    assert_empty named
  end
end

describe 'the two controls in the editor that are not a field' do
  include Rack::Test::Methods
  include Programming

  before { a_block_page }

  # An inline box takes its height from its line box, so min-h-11 on a bare link is
  # ignored: the way back off this page needs something to make it a box first.
  it 'gives the back link a box for a height to apply to' do
    back = editor_controls(last_response.body).find do |tag, attributes|
      tag == 'a' && attributes.include?('href="/programs"')
    end

    assert_includes classes_of(back), 'inline-flex'
  end

  # Removing a lift cannot be undone and it asked for a while, through an hx-confirm that
  # needed hx-boost to fire. Deleting a whole session asks nothing, so the app disagreed
  # with itself about "this cannot be undone"; it now agrees, at the end that does not ask.
  # This pins the plain post, because the way back is two attributes on one line.
  it 'posts the delete as an ordinary form, asking nothing' do
    form = last_response.body[%r{<form[^>]*/delete"[^>]*>}]

    refute_includes form, 'hx-confirm='
    refute_includes form, 'hx-boost='
  end
end

# This used to be a browser spec, because a confirm dialog is not something the markup can
# be read for and hx-boost swapping the page back in had to be watched. Neither is here
# now: the post is an ordinary browser navigation, and Rack::Test can follow one.
describe 'removing a lift' do
  include Rack::Test::Methods
  include Programming

  it 'takes the lift off the day and lands back on the block' do
    account = sign_up
    program, _week, day = block_for(account)
    lift = lift_in(day, account)
    action = "/programs/#{program.id}/lifts/#{lift.id}/delete"
    post action, { '_csrf' => token_for("/programs/#{program.id}", action) }

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], "/programs/#{program.id}"
    assert_equal 0, Tectonic::ProgramLift.where(program_day_id: day.id).count
  end
end

describe 'generating a week from the page' do
  include Rack::Test::Methods
  include Programming

  it 'writes real sessions, and writing twice does not double them' do
    account = sign_up
    program, _week, day = block_for(account)
    lift_in(day, account)
    action = "/programs/#{program.id}/generate"

    2.times do
      post action, { 'week' => '1', '_csrf' => token_for("/programs/#{program.id}", action) }
    end

    assert_equal 1, Tectonic::Workout.where(account_id: account).count
  end
end

