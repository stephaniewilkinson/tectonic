# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/support_mail'

# Mail to support@, received by Resend and passed on to a person. #682.
module SignedWebhook
  SECRET = "whsec_#{Base64.strict_encode64('a test signing key, not a real one')}".freeze
  NOW = 1_800_000_000

  def signed(body, id: 'msg_1', at: NOW, secret: SECRET)
    { id:, timestamp: at.to_s, body:,
      signatures: "v1,#{Tectonic::SupportMail.signature(secret, "#{id}.#{at}.#{body}")}" }
  end

  def verified?(request) = Tectonic::SupportMail.verified?(request, secret: SECRET, now: NOW)
end

describe 'checking a webhook came from Resend' do
  include SignedWebhook

  it 'accepts what was signed with the secret, as sent' do
    assert verified?(signed('{"type":"email.received"}'))
  end

  it 'refuses a body changed after signing' do
    request = signed('{"type":"email.received"}')
    refute verified?(request.merge(body: '{"type":"email.received","x":1}'))
  end

  it 'refuses a request replayed outside the five-minute window' do
    refute verified?(signed('{}', at: SignedWebhook::NOW - 301))
  end

  it 'refuses a signature in any version but v1, and finds v1 among several' do
    request = signed('{}')
    refute verified?(request.merge(signatures: request[:signatures].sub('v1,', 'v2,')))
    assert verified?(request.merge(signatures: "v2,nonsense #{request[:signatures]}"))
  end

  it 'refuses everything while no secret is configured' do
    refute Tectonic::SupportMail.verified?(signed('{}'), secret: '', now: SignedWebhook::NOW)
  end
end

describe 'the support webhook' do
  include Rack::Test::Methods
  include SignedWebhook

  def app = Tectonic::SupportMail::Webhook.new

  def deliver(body, request = signed(body, at: Time.now.to_i))
    Tectonic::SupportMail.stub(:secret, SignedWebhook::SECRET) do
      post '/', body, { 'HTTP_SVIX_ID' => request[:id], 'HTTP_SVIX_TIMESTAMP' => request[:timestamp],
                        'HTTP_SVIX_SIGNATURE' => request[:signatures] }
    end
  end

  def received(id, to: 'support@tectonicplates.app')
    %({"type":"email.received","data":{"email_id":"#{id}","to":["#{to}"]}})
  end

  it 'forwards a received email, and says so' do
    forwarded = []
    Tectonic::SupportMail.stub(:forward, ->(id) { forwarded << id }) { deliver(received('em_1')) }

    assert_equal 200, last_response.status
    assert_equal ['em_1'], forwarded
  end

  it 'answers 500 when the forward fails, so Resend tries again' do
    Tectonic::SupportMail.stub(:forward, ->(_) { false }) { deliver(received('em_1')) }

    assert_equal 500, last_response.status
  end
end

describe 'the support webhook, refusing' do
  include Rack::Test::Methods
  include SignedWebhook

  def app = Tectonic::SupportMail::Webhook.new

  def deliver(body, request = signed(body, at: Time.now.to_i))
    Tectonic::SupportMail.stub(:secret, SignedWebhook::SECRET) do
      post '/', body, { 'HTTP_SVIX_ID' => request[:id], 'HTTP_SVIX_TIMESTAMP' => request[:timestamp],
                        'HTTP_SVIX_SIGNATURE' => request[:signatures] }
    end
  end

  def received(id, to: 'support@tectonicplates.app')
    %({"type":"email.received","data":{"email_id":"#{id}","to":["#{to}"]}})
  end

  it 'does nothing for an unsigned request' do
    forwarded = []
    Tectonic::SupportMail.stub(:forward, ->(id) { forwarded << id }) do
      deliver(received('em_1'), { id: 'x', timestamp: Time.now.to_i.to_s, signatures: 'v1,forged' })
    end

    assert_equal 401, last_response.status
    assert_empty forwarded
  end

  it 'acknowledges other events without forwarding anything' do
    deliver('{"type":"email.delivered","data":{}}')

    assert_equal 200, last_response.status
  end
end

describe 'the forwarded message' do
  def received
    { 'from' => 'lifter@example.org', 'subject' => 'Delete my data', 'text' => 'Please.',
      'html' => '<p>Please.</p>', 'attachments' => [{ 'filename' => 'id.png' }] }
  end

  it 'goes to the configured inbox, and replies go to whoever wrote' do
    message = Tectonic::SupportMail.stub(:forward_to, 'owner@example.com') { Tectonic::SupportMail.message(received) }

    assert_equal ['owner@example.com'], message[:to]
    assert_equal 'lifter@example.org', message[:reply_to]
    assert_equal 'tectonic plates support <support@tectonicplates.app>', message[:from]
    assert_equal '[support] Delete my data', message[:subject]
    assert_includes message[:text], 'Attachments, in Resend under Receiving: id.png.'
  end
end

# The account's other domains receive mail too, and a Resend webhook hears all of it.
describe 'the support webhook, and mail for somebody else' do
  include Rack::Test::Methods
  include SignedWebhook

  def app = Tectonic::SupportMail::Webhook.new

  it 'forwards only what was sent to the support address' do
    forwarded = []
    Tectonic::SupportMail.stub(:secret, SignedWebhook::SECRET) do
      Tectonic::SupportMail.stub(:forward, ->(id) { forwarded << id }) do
        { 'em_ours' => 'Support <SUPPORT@tectonicplates.app>', 'em_other' => 'hello@another-domain.example' }
          .each do |id, to|
            body = %({"type":"email.received","data":{"email_id":"#{id}","to":["#{to}"]}})
            request = signed(body, at: Time.now.to_i)
            post '/', body, { 'HTTP_SVIX_ID' => request[:id], 'HTTP_SVIX_TIMESTAMP' => request[:timestamp],
                              'HTTP_SVIX_SIGNATURE' => request[:signatures] }
            assert_equal 200, last_response.status
          end
      end
    end

    assert_equal ['em_ours'], forwarded
  end
end

