# frozen_string_literal: true

#
# Rack configuration for Ruby Live Text-to-Speech Starter
#
# Loads the Sinatra app and wraps it with the WebSocket proxy middleware.
# The middleware intercepts WebSocket upgrades for /api/live-text-to-speech
# and proxies them to Deepgram's Live TTS API.
#

require_relative "app"

# Wrap Sinatra app with WebSocket proxy middleware
use WebSocketProxy
run App
