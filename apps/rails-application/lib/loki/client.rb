# lib/loki/client.rb
require "net/http"
require "json"
require "uri"
require "base64"

module Loki
  class Client
    def initialize(url:, username: nil, password: nil)
      @uri = URI.join(url, "/loki/api/v1/push")
      @username = username
      @password = password
    end

    def push(logs, labels = {})
      return if logs.empty?

      values = logs.map do |log|
        [(Time.now.to_f * 1_000_000_000).to_i.to_s, log]
      end

      payload = { streams: [{ stream: labels, values: values }] }
      send_request(payload)
    end

    private

    def send_request(payload)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"

      request = Net::HTTP::Post.new(@uri.request_uri, { "Content-Type" => "application/json" })
      request.body = JSON.dump(payload)

      if @username && @password
        auth = Base64.strict_encode64("#{@username}:#{@password}")
        request["Authorization"] = "Basic #{auth}"
      end

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        warn "Erro ao enviar logs para Loki: #{response.code} #{response.body}"
      end
    rescue => e
      warn "Exceção ao enviar logs para Loki: #{e.message}"
    end
  end
end
