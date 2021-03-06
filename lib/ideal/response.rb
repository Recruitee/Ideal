# encoding: utf-8

require 'cgi'
require 'openssl'
require 'base64'
#require 'rexml/document'

module Ideal
  # The base class for all iDEAL response classes.
  #
  # Note that if the iDEAL system is under load it will _not_ allow more
  # then two retries per request.
  class Response
    attr_accessor :response

    def initialize(response_body, options = {})
      #@response = REXML::Document.new(response_body).root
      @body = response_body
      doc = Nokogiri::XML(response_body)
      doc.remove_namespaces!
      @response = doc.root
      @success = !error_occured?
      @test = options[:test]
    end

    # Returns whether we're running in test mode
    def test?
      @test
    end

    # Returns whether the request was a success
    def success?
      @success
    end

    # Returns a technical error message.
    def error_message
      text('//Error/errorMessage') unless success?
    end

    # Returns a consumer friendly error message.
    def consumer_error_message
      text('//Error/consumerMessage') unless success?
    end

    # Returns details on the error if available.
    def error_details
      text('//Error/errorDetail') unless success?
    end

    # Returns an error type inflected from the first two characters of the
    # error code. See error_code for a full list of errors.
    #
    # Error code to type mappings:
    #
    # * +IX+ - <tt>:xml</tt>
    # * +SO+ - <tt>:system</tt>
    # * +SE+ - <tt>:security</tt>
    # * +BR+ - <tt>:value</tt>
    # * +AP+ - <tt>:application</tt>
    def error_type
      unless success?
        case error_code[0,2]
        when 'IX' then :xml
        when 'SO' then :system
        when 'SE' then :security
        when 'BR' then :value
        when 'AP' then :application
        end
      end
    end

    # Returns the code of the error that occured.
    #
    # === Codes
    #
    # ==== IX: Invalid XML and all related problems
    #
    # Such as incorrect encoding, invalid version, or otherwise unreadable:
    #
    # * <tt>IX1000</tt> - Received XML not well-formed.
    # * <tt>IX1100</tt> - Received XML not valid.
    # * <tt>IX1200</tt> - Encoding type not UTF-8.
    # * <tt>IX1300</tt> - XML version number invalid.
    # * <tt>IX1400</tt> - Unknown message.
    # * <tt>IX1500</tt> - Mandatory main value missing. (Merchant ID ?)
    # * <tt>IX1600</tt> - Mandatory value missing.
    #
    # ==== SO: System maintenance or failure
    #
    # The errors that are communicated in the event of system maintenance or
    # system failure. Also covers the situation where new requests are no
    # longer being accepted but requests already submitted will be dealt with
    # (until a certain time):
    #
    # * <tt>SO1000</tt> - Failure in system.
    # * <tt>SO1200</tt> - System busy. Try again later.
    # * <tt>SO1400</tt> - Unavailable due to maintenance.
    #
    # ==== SE: Security and authentication errors
    #
    # Incorrect authentication methods and expired certificates:
    #
    # * <tt>SE2000</tt> - Authentication error.
    # * <tt>SE2100</tt> - Authentication method not supported.
    # * <tt>SE2700</tt> - Invalid electronic signature.
    #
    # ==== BR: Field errors
    #
    # Extra information on incorrect fields:
    #
    # * <tt>BR1200</tt> - iDEAL version number invalid.
    # * <tt>BR1210</tt> - Value contains non-permitted character.
    # * <tt>BR1220</tt> - Value too long.
    # * <tt>BR1230</tt> - Value too short.
    # * <tt>BR1240</tt> - Value too high.
    # * <tt>BR1250</tt> - Value too low.
    # * <tt>BR1250</tt> - Unknown entry in list.
    # * <tt>BR1270</tt> - Invalid date/time.
    # * <tt>BR1280</tt> - Invalid URL.
    #
    # ==== AP: Application errors
    #
    # Errors relating to IDs, account numbers, time zones, transactions:
    #
    # * <tt>AP1000</tt> - Acquirer ID unknown.
    # * <tt>AP1100</tt> - Merchant ID unknown.
    # * <tt>AP1200</tt> - Issuer ID unknown.
    # * <tt>AP1300</tt> - Sub ID unknown.
    # * <tt>AP1500</tt> - Merchant ID not active.
    # * <tt>AP2600</tt> - Transaction does not exist.
    # * <tt>AP2620</tt> - Transaction already submitted.
    # * <tt>AP2700</tt> - Bank account number not 11-proof.
    # * <tt>AP2900</tt> - Selected currency not supported.
    # * <tt>AP2910</tt> - Maximum amount exceeded. (Detailed record states the maximum amount).
    # * <tt>AP2915</tt> - Amount too low. (Detailed record states the minimum amount).
    # * <tt>AP2920</tt> - Please adjust expiration period. See suggested expiration period.
    def error_code
      text('//errorCode') unless success?
    end

    private

    def error_occured?
      @response.name == 'ErrorRes' || @response.name == 'AcquirerErrorRes'
    end

    def text(path)
      @response.xpath(path)[0].text() unless @response.xpath(path)[0].nil?
    end
  end

  # An instance of TransactionResponse is returned from
  # Gateway#setup_purchase which returns the service_url to where the
  # user should be redirected to perform the transaction _and_ the
  # transaction ID.
  class TransactionResponse < Response
    # Returns the URL to the issuer’s page where the consumer should be
    # redirected to in order to perform the payment.
    def service_url
      CGI::unescapeHTML(text('//issuerAuthenticationURL'))
    end

    def verified?
      signed_document = SignedDocument.new(@body)
      @verified ||= signed_document.validate(Ideal::Gateway.ideal_certificate)
    end

    # Returns the transaction ID which is needed for requesting the status
    # of a transaction. See Gateway#capture.
    def transaction_id
      text('//transactionID')
    end

    # Returns the <tt>:order_id</tt> for this transaction.
    def order_id
      text('//purchaseID')
    end

    def signedinfo
      node = @response.xpath("//SignedInfo")[0]
      canonical = node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
    end

    def signature     
      Base64.decode64(text('//SignatureValue'))
    end
  end

  # An instance of StatusResponse is returned from Gateway#capture
  # which returns whether or not the transaction that was started with
  # Gateway#setup_purchase was successful.
  #
  # It takes care of checking if the message was authentic by verifying the
  # the message and its signature against the iDEAL certificate.
  #
  # If success? returns +false+ because the authenticity wasn't verified
  # there will be no error_code, error_message, and error_type. Use verified?
  # to check if the authenticity has been verified.
  class StatusResponse < Response
    def initialize(response_body, options = {})
      super
      @success = transaction_successful?
    end

    # Returns the status message, which is one of: <tt>:success</tt>,
    # <tt>:cancelled</tt>, <tt>:expired</tt>, <tt>:open</tt>, or
    # <tt>:failure</tt>.
    def status
      status = text('//status')
      status.downcase.to_sym unless (status.nil? || status.strip == '')
    end

    # Returns whether or not the authenticity of the message could be
    # verified.
    def verified?
      signed_document = SignedDocument.new(@body)
      @verified ||= signed_document.validate(Ideal::Gateway.ideal_certificate)  
    end

    # Returns the bankaccount number when the transaction was successful.
    def consumer_account_number
      text('//consumerAccountNumber')
    end

    # Returns the name on the bankaccount of the customer when the 
    # transaction was successful.
    def consumer_name
      text('//consumerName')
    end

    # Returns the city on the bankaccount of the customer when the
    # transaction was successful.
    def consumer_city
      text('//consumerCity')
    end

    private

    # Checks if no errors occured _and_ if the message was authentic.
    def transaction_successful?
      !error_occured? && status == :success && verified?
    end

    # The message that we need to verify the authenticity.
    def message
      text('//createDateTimeStamp') + text('//transactionID') + text('//status') + text('//consumerAccountNumber')
    end

    def signature
      Base64.decode64(text('//SignatureValue'))
    end
  end

  # An instance of DirectoryResponse is returned from
  # Gateway#issuers which returns the list of issuers available at the
  # acquirer.
  class DirectoryResponse < Response
    # Returns a list of issuers available at the acquirer.
    #
    #   gateway.issuers.list # => [{ :id => '1006', :name => 'ABN AMRO Bank' }]
    def list
      @response.xpath("//Issuer").map.with_index do |issuer, i|
        { :id => issuer.xpath("//issuerID")[i].text(), :name => issuer.xpath("//issuerName")[i].text() }
      end
    end
  end
end
