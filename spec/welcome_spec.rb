# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'rack/test'

# The front page, which since #255 is the whole of the funnel: GTM.md records that there
# is no acquisition channel in the repository at all, so this is the only page a stranger
# is ever going to arrive at.
#
# What is asserted here is the editorial decision rather than the words. Copy gets edited
# and should not have to come here first; what must not quietly revert is the ordering --
# the connector before the log, the assistants before the acronym -- because that ordering
# is the answer to #255 and the reason the page reads the way it does. And the picture,
# which was shipped at zero pixels wide on a phone for long enough that nobody noticed.
module Welcome
  # A JPEG's own idea of its size, read out of the file rather than asked of ImageMagick,
  # which CI has no reason to have installed. The size is in the frame header: a run of
  # segments, each two bytes of marker and two of length, until one of the SOF markers,
  # whose payload opens with a precision byte and then height and width as big-endian
  # shorts. C4, C8 and CC share the range and are not frame headers.
  START_OF_FRAME = ((0xC0..0xCF).to_a - [0xC4, 0xC8, 0xCC]).freeze

  def app
    Tectonic.app
  end

  def jpeg_size(path)
    data = File.binread(path)
    offset = 2
    offset += 2 + data[offset + 2, 2].unpack1('n') until START_OF_FRAME.include?(data.getbyte(offset + 1))
    [data[offset + 7, 2].unpack1('n'), data[offset + 5, 2].unpack1('n')]
  end

  def welcome
    get '/welcome'

    assert_equal 200, last_response.status
    last_response.body
  end

  # The page as a reader sees it, with the head cut off. #326's rule is about what somebody is
  # *told* this app is, and since #359 the title and description are a different surface with a
  # different job -- one aimed at a search index, which has no opinion about vendor neutrality
  # and does have opinions about which words are in it.
  def visible = @body.sub(%r{\A.*</head>}m, '')
end

describe 'what the front page leads with' do
  include Rack::Test::Methods
  include Welcome

  before { @body = welcome }

  # The page opened "Lift heavier" and described a workout logger, which is what every
  # competitor says and most of them say with more reviews behind it. #255 was answered
  # with option 1: lead with the thing none of them has.
  #
  # It leads with the assistant and not with a vendor, which is #326 correcting the half of
  # #255 that named Claude. The lead is the same; the word is generic, because a product
  # that speaks an open protocol should not read as built for one client.
  it 'names the assistant in the headline' do
    assert_match(/<h1[^>]*>[^<]*AI/, @body)
  end

  it 'gets to the connector before it gets to the log' do
    assert_operator visible.index('AI'), :<, visible.index('lifting log')
  end

  # "MCP" was on this page with nothing explaining it, which asks a reader to already know
  # an acronym from inside this industry. It is still here, because somebody who does know
  # it is searching for exactly that word -- but after the plain-language version, not
  # instead of it.
  it 'names the assistants before it names the protocol' do
    assert_operator visible.index('AI'), :<, visible.index('MCP')
  end

  # The whole of #326: no vendor is named anywhere a reader is being told what this is. The
  # per-client setup steps on /connections are the exception and are asserted there.
  #
  # Read off the visible page rather than the whole document since #359, which put both
  # assistants into the title and description. That is not the thing #326 refused. It refused
  # this app reading as built for one client, and a title naming Claude *and* ChatGPT is the
  # opposite claim -- while the two search terms #342 found unowned are "Claude workout
  # connector" and "ChatGPT barbell program", so a head that names neither gives up the only
  # terms this domain can win. What a reader is told, which is what the issue is about, is
  # unchanged and still asserted.
  it 'names no vendor at all' do
    refute_match(/\bClaude\b/, visible)
    refute_match(/\bChatGPT\b/, visible)
  end

  # And the head does, deliberately, which is the half #359 asked for. Asserted here beside
  # the rule it is an exception to, so the two are read together.
  it 'names both of them in the metadata, and never only one' do
    head = @body[%r{<head\b.*?</head>}m]

    assert_includes head, 'Claude'
    assert_includes head, 'ChatGPT'
  end
end

# The exception, and the reason for it: on the setup steps the name *is* the instruction,
# because "Settings, then Connectors" is a different sequence in each client.
describe 'the setup steps on the connections page' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'still names each client, because a generic word would leave a reader hunting' do
    login
    get '/connections'

    assert_includes last_response.body, 'Claude:'
    assert_includes last_response.body, 'ChatGPT:'
  end

  it 'says what it is in generic words above them' do
    login
    get '/connections'

    assert_includes last_response.body, 'Connect your AI assistant'
  end
end

describe 'where the front page sends a reader' do
  include Rack::Test::Methods
  include Welcome

  before { @body = welcome }

  # It was "Learn more" pointing at /about, which is a colophon: a name, a twitter handle
  # and the Noun Project icon credits. The reader most likely to sign up is the one who
  # clicks it, and they were sent to attribution for the squat icon.
  it 'points its third button at a section that exists on this page' do
    target = @body[/href="#([\w-]+)"/, 1]

    refute_nil target, 'nothing on the page links to a section of it'
    assert_includes @body, %(id="#{target}")
  end

  # The dead "What's new / Just shipped v1.0" block was `hidden` with no responsive
  # variant, so it rendered for nobody at any width, and its link went to `#`. Template
  # furniture from whatever this page started as, found while doing #239 and left there
  # because deleting content was out of that issue's scope.
  it 'has no link that goes nowhere, and no block that renders for nobody' do
    refute_match(/href="#"/, @body)
    refute_includes @body, 'Just shipped'
  end

  # The Noun Project licence turns on the credit being reachable, and /about is where it
  # lives. Repointing the button above must not leave that page linked from nothing.
  it 'still links the colophon' do
    assert_includes @body, 'href="/about"'
  end
end

describe 'the picture of the app on the front page' do
  include Rack::Test::Methods
  include Welcome

  before do
    @body = welcome
    @img = @body[/<img[^>]*screenshot[^>]*>/]

    refute_nil @img, 'the front page has no screenshot on it'
  end

  # Two mechanisms said the same thing and neither was removed: `invisible lg:visible` on
  # the container and `w-[0rem] lg:w-[16rem]` on the image. Below 1024px the marketing page
  # for a gym app showed no picture of the app -- on the device the app is used on, and the
  # device a link between two lifters is most likely first opened on.
  it 'is not hidden on a phone by either of the two mechanisms that used to hide it' do
    refute_includes @img, 'w-[0rem]'
    refute_includes @body, 'invisible'
  end

  # The attributes said 2432x1442 while the file was 591x1280 -- not cosmetic, because the
  # browser reserves a box of that shape before the image arrives, so the page laid out
  # landscape and jumped when a portrait image landed in it. Read from the file so that
  # `rake assets:screenshot` cannot retake it at a different shape and leave these behind.
  it 'declares the shape the file actually is' do
    width, height = jpeg_size(File.expand_path('../assets/img/screenshot.jpeg', __dir__))

    assert_includes @img, %(width="#{width}")
    assert_includes @img, %(height="#{height}")
  end

  # It read "App screenshot", which describes the file rather than the product.
  it 'says what is in it' do
    assert_match(/alt="[^"]{30,}"/, @img)
  end
end

