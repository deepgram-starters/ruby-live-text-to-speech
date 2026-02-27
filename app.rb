# frozen_string_literal: true

#
# Ruby Live Text-to-Speech Starter - Backend Server
#
# Simple WebSocket proxy to Deepgram's Live TTS API.
# Forwards all messages (JSON and binary) bidirectionally between client and Deepgram.
#
# API Endpoints:
# - WS  /api/live-text-to-speech - WebSocket proxy to Deepgram TTS (auth required)
# - GET /api/session             - JWT session token endpoint
# - GET /api/metadata            - Returns metadata from deepgram.toml
# - GET /health                  - Health check endpoint
#

require "sinatra/base"
require "sinatra/cross_origin"
require "faye/websocket"
require "jwt"
require "json"
require "toml-rb"
require "securerandom"
require "uri"
require "dotenv"

# Load .env file (won't override existing environment variables)
Dotenv.load

# ============================================================================
# CONFIGURATION
# ============================================================================

DEFAULT_MODEL = "aura-asteria-en"
DEEPGRAM_TTS_URL = "wss://api.deepgram.com/v1/speak"

# ============================================================================
# API KEY VALIDATION
# ============================================================================

DEEPGRAM_API_KEY = ENV["DEEPGRAM_API_KEY"]
unless DEEPGRAM_API_KEY && !DEEPGRAM_API_KEY.empty?
  warn "\n#{"=" * 70}"
  warn "ERROR: Deepgram API key not found!"
  warn "=" * 70
  warn "\nPlease set your API key using one of these methods:"
  warn "\n1. Create a .env file (recommended):"
  warn "   DEEPGRAM_API_KEY=your_api_key_here"
  warn "\n2. Environment variable:"
  warn "   export DEEPGRAM_API_KEY=your_api_key_here"
  warn "\nGet your API key at: https://console.deepgram.com"
  warn "#{"=" * 70}\n"
  exit 1
end

# ============================================================================
# SESSION AUTH - JWT tokens for production security
# ============================================================================

SESSION_SECRET = ENV["SESSION_SECRET"] || SecureRandom.hex(32)
JWT_EXPIRY = 3600 # 1 hour

# Validates JWT from Sec-WebSocket-Protocol: access_token.<jwt> header.
# Returns the full protocol string if valid, nil otherwise.
def validate_ws_token(env)
  protocol_header = env["HTTP_SEC_WEBSOCKET_PROTOCOL"] || ""
  protocols = protocol_header.split(",").map(&:strip)
  token_proto = protocols.find { |p| p.start_with?("access_token.") }
  return nil unless token_proto

  token = token_proto.sub("access_token.", "")
  begin
    JWT.decode(token, SESSION_SECRET, true, algorithm: "HS256")
    token_proto
  rescue JWT::DecodeError
    nil
  end
end

# ============================================================================
# SETUP - Initialize Sinatra app
# ============================================================================

class App < Sinatra::Base
  register Sinatra::CrossOrigin

  configure do
    enable :cross_origin
    set :port, (ENV["PORT"] || 8081).to_i
    set :bind, ENV["HOST"] || "0.0.0.0"
    set :server, :puma
  end

  # Enable CORS preflight
  before do
    response.headers["Access-Control-Allow-Origin"] = "*"
  end

  options "*" do
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    200
  end

  # ============================================================================
  # SESSION ROUTES - Auth endpoints (unprotected)
  # ============================================================================

  # GET /api/session - Issues a JWT for session authentication.
  get "/api/session" do
    content_type :json
    now = Time.now.to_i
    token = JWT.encode({ iat: now, exp: now + JWT_EXPIRY }, SESSION_SECRET, "HS256")
    { token: token }.to_json
  end

  # ============================================================================
  # HTTP ROUTES
  # ============================================================================

  # GET /api/metadata - Returns metadata from deepgram.toml
  get "/api/metadata" do
    content_type :json
    begin
      config = TomlRB.load_file("deepgram.toml")

      unless config["meta"]
        status 500
        return {
          error: "INTERNAL_SERVER_ERROR",
          message: "Missing [meta] section in deepgram.toml"
        }.to_json
      end

      config["meta"].to_json
    rescue Errno::ENOENT
      status 500
      {
        error: "INTERNAL_SERVER_ERROR",
        message: "deepgram.toml file not found"
      }.to_json
    rescue StandardError => e
      $stderr.puts "Error reading metadata: #{e}"
      status 500
      {
        error: "INTERNAL_SERVER_ERROR",
        message: "Failed to read metadata from deepgram.toml: #{e.message}"
      }.to_json
    end
  end

  # GET /health - Simple health check endpoint.
  get "/health" do
    content_type :json
    { status: "ok" }.to_json
  end
end

# ============================================================================
# WEBSOCKET MIDDLEWARE
# ============================================================================

# Rack middleware that intercepts WebSocket upgrade requests for
# /api/live-text-to-speech and proxies them to Deepgram's Live TTS API.
# All other requests are passed through to the Sinatra app.
class WebSocketProxy
  def initialize(app)
    @app = app
  end

  def call(env)
    # Only handle WebSocket upgrades on our endpoint
    if Faye::WebSocket.websocket?(env) && env["PATH_INFO"] == "/api/live-text-to-speech"
      handle_tts_websocket(env)
    else
      @app.call(env)
    end
  end

  private

  def handle_tts_websocket(env)
    # Validate JWT from WebSocket subprotocol before accepting
    valid_proto = validate_ws_token(env)
    unless valid_proto
      # Reject unauthenticated connections
      return [401, { "Content-Type" => "text/plain" }, ["Unauthorized"]]
    end

    # Accept the WebSocket connection, echoing the access_token.* subprotocol
    client_ws = Faye::WebSocket.new(env, [valid_proto])

    puts "Client connected to /api/live-text-to-speech"

    # Parse query parameters from the WebSocket URL
    query = Rack::Utils.parse_query(env["QUERY_STRING"] || "")
    model       = query["model"]       || DEFAULT_MODEL
    encoding    = query["encoding"]    || "linear16"
    sample_rate = query["sample_rate"] || "24000"
    container   = query["container"]   || "none"

    puts "TTS Config - model: #{model}, encoding: #{encoding}, " \
         "sample_rate: #{sample_rate}, container: #{container}"

    # Build Deepgram WebSocket URL with query parameters
    deepgram_params = URI.encode_www_form(
      model: model,
      encoding: encoding,
      sample_rate: sample_rate,
      container: container
    )
    deepgram_url = "#{DEEPGRAM_TTS_URL}?#{deepgram_params}"

    # Connect to Deepgram TTS API
    deepgram_ws = Faye::WebSocket::Client.new(deepgram_url, nil,
      headers: { "Authorization" => "Token #{DEEPGRAM_API_KEY}" }
    )

    # Track message counts for logging
    client_message_count = 0
    deepgram_message_count = 0

    # ---- Deepgram -> Client forwarding ----

    deepgram_ws.on :open do |_event|
      puts "Connected to Deepgram TTS API"
    end

    deepgram_ws.on :message do |event|
      deepgram_message_count += 1
      data = event.data

      # Log non-binary messages and every 10th binary message
      if data.is_a?(String)
        puts "Deepgram JSON message ##{deepgram_message_count}"
      elsif deepgram_message_count % 10 == 0
        puts "Deepgram binary message ##{deepgram_message_count}"
      end

      # Forward to client — ensure binary audio is sent as binary frames
      if client_ws
        if data.is_a?(Array)
          client_ws.send(data)
        elsif data.is_a?(String) && data.encoding == Encoding::ASCII_8BIT
          client_ws.send(data.bytes)
        else
          client_ws.send(data)
        end
      end
    end

    deepgram_ws.on :error do |event|
      puts "Deepgram WebSocket error: #{event.message}"
    end

    deepgram_ws.on :close do |event|
      puts "Deepgram connection closed: #{event.code} #{event.reason}"
      if client_ws
        code = safe_close_code(event.code)
        client_ws.close(code, event.reason)
      end
      client_ws = nil
    end

    # ---- Client -> Deepgram forwarding ----

    client_ws.on :message do |event|
      client_message_count += 1
      data = event.data

      # Log JSON messages and every 100th binary message
      if data.is_a?(String)
        puts "Client JSON message ##{client_message_count}"
      elsif client_message_count % 100 == 0
        puts "Client binary message ##{client_message_count}"
      end

      # Forward to Deepgram
      if deepgram_ws
        deepgram_ws.send(data)
      end
    end

    client_ws.on :close do |event|
      puts "Client disconnected: #{event.code} #{event.reason}"
      if deepgram_ws
        deepgram_ws.close
      end
      deepgram_ws = nil
      puts "Client disconnected from /api/live-text-to-speech"
    end

    client_ws.on :error do |event|
      puts "Client WebSocket error: #{event.message}"
      if deepgram_ws
        deepgram_ws.close
      end
    end

    # Return async Rack response (required by faye-websocket)
    client_ws.rack_response
  end

  # Returns a safe WebSocket close code, avoiding reserved codes
  def safe_close_code(code)
    reserved = [1004, 1005, 1006, 1015]
    if code.is_a?(Integer) && code >= 1000 && code <= 4999 && !reserved.include?(code)
      code
    else
      1000
    end
  end
end
