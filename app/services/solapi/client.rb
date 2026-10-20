# frozen_string_literal: true

module Solapi
  # 솔라피 Messages v4 REST API 클라이언트.
  # 문서 근거(2026-10-20 기준 공식 문서):
  # - 인증: https://solapi.com/developers/api/authentication-api-key
  #   Authorization: HMAC-SHA256 apiKey=<key>, date=<ISO8601>, salt=<rand>, signature=<hex>
  #   signature = HMAC-SHA256(api_secret, date + salt) hexdigest
  # - 발송: https://solapi.com/developers/api/messages — POST /messages/v4/send-many/detail
  # - 대체발송: https://solapi.com/developers/api/messages-disablesms
  #   알림톡(ATA)은 기본 대체발송 활성 — kakaoOptions.disableSms를 true로 설정하지 않는 한
  #   발송 실패 시 SMS/LMS로 자동 대체(MSG-002). 단, 대체발송에는 messages.from(사전 등록 발신번호) 필수.
  # 시크릿은 Rails credentials(solapi.api_key / solapi.api_secret)에서만 주입받는다(10.3).
  class Client
    API_BASE = "https://api.solapi.com"
    SEND_PATH = "/messages/v4/send-many/detail"
    GROUP_PATH = "/messages/v4/groups"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    Error = Class.new(StandardError)
    ConfigError = Class.new(Error)

    Result = Data.define(:success?, :fallback?, :message_id, :group_id, :error_code, :error_message) do
      def self.failure(code, message)
        new(success?: false, fallback?: false, message_id: nil, group_id: nil,
            error_code: code, error_message: message)
      end

      def self.success(message_id:, group_id:, fallback:)
        new(success?: true, fallback?: fallback, message_id: message_id, group_id: group_id,
            error_code: nil, error_message: nil)
      end
    end

    def initialize(api_key:, api_secret:, from:)
      raise ConfigError, "solapi.api_key 미설정" if api_key.blank?
      raise ConfigError, "solapi.api_secret 미설정" if api_secret.blank?

      @api_key = api_key
      @api_secret = api_secret
      @from = from.to_s.gsub(/[^0-9]/, "")
    end

    def self.from_credentials
      config = Rails.application.config_for(:solapi)

      new(
        api_key: config[:api_key],
        api_secret: config[:api_secret],
        from: config[:from]
      )
    rescue StandardError
      raise ConfigError, "solapi credentials 미설정(api_key/api_secret/from)"
    end

    def configured?
      true
    end

    # messages: [{ to:, text:, subject:, kakao_options: { pf_id:, template_id:, variables: } }]
    # scheduled_date: Time (예약발송 — messages[].scheduledDate, 과거 지정 시 즉시 발송)
    def send_messages(messages, scheduled_date: nil)
      body = {
        messages: messages.map { |m| build_request_message(m, scheduled_date) },
        showMessageList: true # 응답에 개별 messageId/statusCode 포함 — 상태 기록용
      }

      response = post(SEND_PATH, body)
      parse_send_response(response)
    rescue *NETWORK_ERRORS => e
      Result.failure("NETWORK_ERROR", e.class.name)
    rescue JSON::ParserError
      Result.failure("INVALID_RESPONSE", "응답 파싱 실패")
    end

    # 예약발송 취소(MSG-007): 그룹 삭제 → status DELETED.
    # 문서: https://solapi.com/developers/api/msg-groups (그룹 메시지 API)
    def cancel_scheduled(group_id)
      return Result.failure("NO_GROUP", "그룹 아이디 없음") if group_id.blank?

      delete("#{GROUP_PATH}/#{group_id}")
      Result.success(message_id: nil, group_id: group_id, fallback: false)
    rescue *NETWORK_ERRORS => e
      Result.failure("NETWORK_ERROR", e.class.name)
    end

    private

    NETWORK_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET,
                      Errno::ECONNREFUSED, OpenSSL::SSL::SSLError ].freeze

    def build_request_message(m, scheduled_date)
      msg = { "to" => m[:to].to_s.gsub(/[^0-9]/, "") }
      # 대체발송(MSG-002)에는 사전 등록 발신번호 필수 — 알림톡 실패 시 SMS/LMS 자동 대체
      msg["from"] = @from if @from.present?
      msg["text"] = m[:text] if m[:text].present?
      msg["subject"] = m[:subject] if m[:subject].present? # LMS 대체발송 시 제목

      if (kakao = m[:kakao_options])
        options = { "disableSms" => false } # 대체발송 활성(기본값 명시)
        options["pfId"] = kakao[:pf_id] if kakao[:pf_id].present?
        options["templateId"] = kakao[:template_id] if kakao[:template_id].present?
        options["variables"] = kakao[:variables] if kakao[:variables].present?
        msg["kakaoOptions"] = options
      end

      msg["scheduledDate"] = scheduled_date.utc.iso8601 if scheduled_date.present?
      msg
    end

    def parse_send_response(response)
      group = response["groupInfo"] || {}
      message_list = response["messageList"] || {}
      failed_list = response["failedMessageList"] || []

      # 접수 실패가 있으면 해당 건은 발송되지 않음 → 첫 건 사유 반환
      if failed_list.any?
        failed = failed_list.first
        return Result.failure(failed["code"] || failed["statusCode"] || "REGISTER_FAILED",
                              failed["message"] || "접수 실패")
      end

      # 성공 건의 messageId/statusCode — 그룹 카운트로 대체발송 판별(10.2: 채널 구분 통합 조회)
      entry = message_list.values.first
      message_id = entry&.dig("messageId")
      fallback = group.dig("count", "sentReplacement").to_i.positive?

      if entry && entry["statusCode"] != "2000" && !fallback
        Result.failure(entry["statusCode"], entry["statusMessage"] || "발송 실패")
      else
        Result.success(message_id: message_id, group_id: group["groupId"] || group["_id"],
                       fallback: fallback)
      end
    end

    def post(path, body)
      request(Net::HTTP::Post, path, body.to_json)
    end

    def delete(path)
      request(Net::HTTP::Delete, path, nil)
    end

    def request(http_class, path, body)
      uri = URI.join(API_BASE, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = http_class.new(uri)
      req["Authorization"] = auth_header
      req["Content-Type"] = "application/json"
      req.body = body if body

      res = http.request(req)
      parsed = res.body.to_s.empty? ? {} : JSON.parse(res.body)
      return parsed if res.is_a?(Net::HTTPSuccess)

      code = parsed.is_a?(Hash) ? (parsed["errorCode"] || parsed["code"] || "HTTP_#{res.code}") : "HTTP_#{res.code}"
      message = parsed.is_a?(Hash) ? (parsed["message"] || res.message) : res.message
      raise Error, "#{code}: #{message}"
    end

    # 인증 헤더(문서: authentication-api-key) — date+salt를 api_secret으로 HMAC-SHA256
    def auth_header
      date = Time.now.utc.iso8601
      salt = SecureRandom.hex(12) # 12~64바이트 랜덤 문자열
      signature = OpenSSL::HMAC.hexdigest("SHA256", @api_secret, date + salt)
      "HMAC-SHA256 apiKey=#{@api_key}, date=#{date}, salt=#{salt}, signature=#{signature}"
    end
  end
end
