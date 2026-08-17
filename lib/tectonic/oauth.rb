# frozen_string_literal: true

# The hand-rolled OAuth 2.1 authorization layer for the MCP endpoint (there is no
# server-side OAuth in the mcp gem, and rodauth-oauth is deliberately not used). Access
# tokens are ordinary api_tokens rows tagged kind 'oauth', so the existing bearer auth,
# request context, and audit trail carry OAuth tokens unchanged. This file wires the
# pieces together; app.rb mounts the routes in the Roda tree next to the login session.
require_relative 'oauth/pkce'
require_relative 'oauth/redirect_uri'
require_relative 'oauth_client'
require_relative 'oauth_authorization_code'
require_relative 'oauth_refresh_token'
require_relative 'oauth/authorize_request'
require_relative 'oauth/metadata'
require_relative 'oauth/authorization'
require_relative 'oauth/registration'
require_relative 'oauth/token_grant'
require_relative 'oauth/endpoints'

