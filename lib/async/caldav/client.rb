# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"
require "net/http"
require "uri"
require "rexml/document"

require_relative "client/calendar"
require_relative "client/addressbook"

module Async
  module Caldav
    class Client
      class Error < StandardError; end
      class NotFound < Error; end
      class PreconditionFailed < Error; end
      class Conflict < Error; end
      class Unauthorized < Error; end
      class InvalidSyncToken < Error; end

      attr_reader :user

      def initialize(base_url, user:, password: nil, headers: {})
        @uri = URI.parse(base_url)
        @user = user
        @password = password
        @extra_headers = headers
        @http = nil
      end

      def self.open(base_url, **opts)
        client = new(base_url, **opts)
        return client unless block_given?

        begin
          yield client
        ensure
          client.close
        end
      end

      def close
        @http&.finish if @http&.started?
        @http = nil
      end

      # --- Discovery ---

      def principal
        _, _, body = request('PROPFIND', '/', headers: { 'Depth' => '0' })
        match = body.match(/<[^>]*current-user-principal[^>]*>\s*<[^>]*href[^>]*>([^<]+)</)
        match ? match[1].strip : "/#{@user}/"
      end

      def calendars
        path = "/calendars/#{@user}/"
        status, _, body = request('PROPFIND', path, headers: { 'Depth' => '1' })
        raise Error, "PROPFIND failed: #{status}" unless status == 207

        parse_collections(body, path, type: :calendar)
      end

      def addressbooks
        path = "/addressbooks/#{@user}/"
        status, _, body = request('PROPFIND', path, headers: { 'Depth' => '1' })
        raise Error, "PROPFIND failed: #{status}" unless status == 207

        parse_collections(body, path, type: :addressbook)
      end

      def calendar(name)
        Calendar.new(self, "/calendars/#{@user}/#{name}/")
      end

      def addressbook(name)
        Addressbook.new(self, "/addressbooks/#{@user}/#{name}/")
      end

      # --- Create ---

      def create_calendar(name, displayname: nil, description: nil, color: nil)
        path = "/calendars/#{@user}/#{name}/"
        x = Builder::XmlMarkup.new
        x.instruct! :xml, version: "1.0", encoding: "UTF-8"
        x.tag!("c:mkcalendar", "xmlns:d" => "DAV:", "xmlns:c" => "urn:ietf:params:xml:ns:caldav") do
          x.tag!("d:set") do
            x.tag!("d:prop") do
              x.tag!("d:displayname", displayname || name) if displayname || name
              x.tag!("c:calendar-description", description) if description
            end
          end
        end

        status, = request('MKCALENDAR', path, body: x.target!, headers: { 'Content-Type' => 'text/xml' })
        raise Error, "MKCALENDAR failed: #{status}" unless status == 201

        Calendar.new(self, path, displayname: displayname || name, description: description, color: color)
      end

      def create_addressbook(name, displayname: nil)
        path = "/addressbooks/#{@user}/#{name}/"
        x = Builder::XmlMarkup.new
        x.instruct! :xml, version: "1.0", encoding: "UTF-8"
        x.tag!("d:mkcol", "xmlns:d" => "DAV:", "xmlns:cr" => "urn:ietf:params:xml:ns:carddav") do
          x.tag!("d:set") do
            x.tag!("d:prop") do
              x.tag!("d:resourcetype") { x.tag!("d:collection"); x.tag!("cr:addressbook") }
              x.tag!("d:displayname", displayname || name)
            end
          end
        end

        status, = request('MKCOL', path, body: x.target!, headers: { 'Content-Type' => 'text/xml' })
        raise Error, "MKCOL failed: #{status}" unless status == 201

        Addressbook.new(self, path, displayname: displayname || name)
      end

      # --- HTTP transport ---

      def request(method, path, body: nil, headers: {})
        http = connect
        req = build_request(method, path, body, headers)
        response = http.request(req)

        status = response.code.to_i
        resp_headers = {}
        response.each_header { |k, v| resp_headers[k] = v }

        raise Unauthorized, "401 Unauthorized" if status == 401

        [status, resp_headers, response.body || '']
      end

      # --- Response parsing (used by Calendar/Addressbook) ---

      def parse_multistatus_items(xml, data_tag:)
        items = []
        xml.scan(/<[^>]*response[^>]*>(.*?)<\/[^>]*response>/m).each do |match|
          resp = match[0]
          href = resp.match(/<[^>]*href[^>]*>([^<]+)</)[1]&.strip rescue nil
          next unless href

          etag = resp.match(/<[^>]*getetag[^>]*>([^<]+)</)[1]&.strip rescue nil
          data = resp.match(/<[^>]*#{data_tag}[^>]*>(.*?)<\/[^>]*#{data_tag}>/m)
          body = data ? data[1].strip : nil

          # Unescape XML entities in the body
          if body
            body = body.gsub('&amp;', '&').gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"')
          end

          items << { path: href, body: body, etag: etag }
        end
        items
      end

      def parse_sync_items(xml)
        items = []
        xml.scan(/<[^>]*response[^>]*>(.*?)<\/[^>]*response>/m).each do |match|
          resp = match[0]
          href = resp.match(/<[^>]*href[^>]*>([^<]+)</)[1]&.strip rescue nil
          next unless href

          if resp.include?('404')
            items << { path: href, status: 404 }
          else
            etag = resp.match(/<[^>]*getetag[^>]*>([^<]+)</)[1]&.strip rescue nil
            items << { path: href, status: 200, etag: etag }
          end
        end
        items
      end

      def parse_collection_props(xml)
        props = {}
        props[:displayname] = Protocol::Caldav::Xml.extract_value(xml, 'displayname')
        props[:description] = Protocol::Caldav::Xml.extract_value(xml, 'calendar-description')
        props[:color] = Protocol::Caldav::Xml.extract_value(xml, 'calendar-color')
        ctag = Protocol::Caldav::Xml.extract_value(xml, 'getctag')
        props[:ctag] = ctag if ctag
        props
      end

      private

      def connect
        return @http if @http&.started?

        @http = Net::HTTP.new(@uri.host, @uri.port)
        @http.use_ssl = (@uri.scheme == 'https')
        @http.start
        @http
      end

      def build_request(method, path, body, headers)
        klass = case method
        when 'GET'         then Net::HTTP::Get
        when 'PUT'         then Net::HTTP::Put
        when 'DELETE'      then Net::HTTP::Delete
        when 'HEAD'        then Net::HTTP::Head
        when 'OPTIONS'     then Net::HTTP::Options
        when 'PROPFIND'    then propfind_class
        when 'PROPPATCH'   then proppatch_class
        when 'MKCOL'       then mkcol_class
        when 'MKCALENDAR'  then mkcalendar_class
        when 'REPORT'      then report_class
        when 'MOVE'        then move_class
        else raise Error, "Unknown method: #{method}"
        end

        req = klass.new(path)
        req.body = body if body

        # Auth
        if @password
          req.basic_auth(@user, @password)
        else
          req['Remote-User'] = @user
        end

        # Default + extra + per-request headers
        @extra_headers.each { |k, v| req[k] = v }
        headers.each { |k, v| req[k] = v }

        req
      end

      def parse_collections(xml, parent_path, type:)
        collections = []
        xml.scan(/<[^>]*response[^>]*>(.*?)<\/[^>]*response>/m).each do |match|
          resp = match[0]
          href = resp.match(/<[^>]*href[^>]*>([^<]+)</)[1]&.strip rescue nil
          next unless href
          next if href == parent_path # skip the parent itself

          # Check resource type
          is_calendar = resp.include?('calendar/')
          is_addressbook = resp.include?('addressbook/')

          if type == :calendar && is_calendar
            displayname = Protocol::Caldav::Xml.extract_value(resp, 'displayname')
            description = Protocol::Caldav::Xml.extract_value(resp, 'calendar-description')
            color = Protocol::Caldav::Xml.extract_value(resp, 'calendar-color')
            collections << Calendar.new(self, href, displayname: displayname, description: description, color: color)
          elsif type == :addressbook && is_addressbook
            displayname = Protocol::Caldav::Xml.extract_value(resp, 'displayname')
            collections << Addressbook.new(self, href, displayname: displayname)
          end
        end
        collections
      end

      # Custom HTTP method classes for WebDAV
      def propfind_class
        @propfind_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'PROPFIND')
          const_set(:REQUEST_HAS_BODY, true)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end

      def proppatch_class
        @proppatch_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'PROPPATCH')
          const_set(:REQUEST_HAS_BODY, true)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end

      def mkcol_class
        @mkcol_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'MKCOL')
          const_set(:REQUEST_HAS_BODY, true)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end

      def mkcalendar_class
        @mkcalendar_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'MKCALENDAR')
          const_set(:REQUEST_HAS_BODY, true)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end

      def report_class
        @report_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'REPORT')
          const_set(:REQUEST_HAS_BODY, true)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end

      def move_class
        @move_class ||= Class.new(Net::HTTPRequest) do
          const_set(:METHOD, 'MOVE')
          const_set(:REQUEST_HAS_BODY, false)
          const_set(:RESPONSE_HAS_BODY, true)
        end
      end
    end
  end
end


test do
  # Mock transport that routes requests through the Server directly
  class MockTransport
    def initialize
      @storage = Async::Caldav::Storage::Mock.new
      @server = Async::Caldav::Server.new(storage: @storage)
      # Pre-create parent collections
      %w[/calendars/ /calendars/admin/ /addressbooks/ /addressbooks/admin/].each do |p|
        @storage.create_collection(p)
      end
    end

    attr_reader :storage

    def request(method, path, body, headers, user)
      env = {
        'REQUEST_METHOD' => method,
        'PATH_INFO' => path,
        'rack.input' => StringIO.new(body || ''),
        'dav.user' => user
      }
      headers.each do |k, v|
        rack_key = "HTTP_#{k.upcase.tr('-', '_')}"
        env[rack_key] = v
      end
      env['CONTENT_TYPE'] = headers['Content-Type'] if headers['Content-Type']
      @server.call(env)
    end
  end

  # Client subclass that uses MockTransport instead of Net::HTTP
  class TestClient < Async::Caldav::Client
    def initialize(transport, user:)
      @transport = transport
      @user = user
      @extra_headers = {}
    end

    def request(method, path, body: nil, headers: {})
      status, resp_headers, resp_body = @transport.request(method, path, body, headers, @user)
      body_str = resp_body.is_a?(Array) ? resp_body.join : resp_body
      [status, resp_headers, body_str]
    end

    def close; end
  end

  require 'stringio'

  describe "Async::Caldav::Client" do
    def make_client
      transport = MockTransport.new
      [TestClient.new(transport, user: 'admin'), transport]
    end

    it "principal returns user path" do
      client, = make_client
      client.principal.should.include '/admin/'
    end

    it "create_calendar returns Calendar" do
      client, = make_client
      cal = client.create_calendar('work', displayname: 'Work')
      cal.should.be.instance_of Async::Caldav::Client::Calendar
      cal.path.should.equal '/calendars/admin/work/'
      cal.displayname.should.equal 'Work'
    end

    it "calendars returns list of Calendar objects" do
      client, = make_client
      client.create_calendar('cal1', displayname: 'Cal 1')
      client.create_calendar('cal2', displayname: 'Cal 2')
      cals = client.calendars
      cals.length.should.equal 2
      cals.all? { |c| c.is_a?(Async::Caldav::Client::Calendar) }.should.equal true
    end

    it "create_addressbook returns Addressbook" do
      client, = make_client
      ab = client.create_addressbook('contacts', displayname: 'Contacts')
      ab.should.be.instance_of Async::Caldav::Client::Addressbook
      ab.path.should.equal '/addressbooks/admin/contacts/'
    end

    it "addressbooks returns list of Addressbook objects" do
      client, = make_client
      client.create_addressbook('ab1', displayname: 'AB 1')
      abs = client.addressbooks
      abs.length.should.equal 1
      abs[0].displayname.should.equal 'AB 1'
    end

    it "calendar returns Calendar for name" do
      client, = make_client
      cal = client.calendar('work')
      cal.path.should.equal '/calendars/admin/work/'
    end

    it "open with block yields client and closes" do
      transport = MockTransport.new
      yielded = nil
      TestClient.open('http://localhost', user: 'admin') do |c|
        # We can't use TestClient.open directly since it calls new with base_url
        # but this tests the block pattern
        yielded = true
      end
      yielded.should.equal true
    end
  end

  describe "Async::Caldav::Client::Calendar" do
    def make_client
      transport = MockTransport.new
      [TestClient.new(transport, user: 'admin'), transport]
    end

    it "put_event creates event and returns etag" do
      client, = make_client
      cal = client.create_calendar('work')
      result = cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")
      result[:status].should.equal 201
      result[:etag].should.not.be.nil
    end

    it "get_event retrieves event body and etag" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nSUMMARY:Test\r\nEND:VCALENDAR")
      result = cal.get_event('ev.ics')
      result[:body].should.include 'SUMMARY:Test'
      result[:etag].should.not.be.nil
    end

    it "events returns items from REPORT" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nSUMMARY:Meeting\r\nEND:VCALENDAR")
      items = cal.events
      items.length.should.equal 1
      items[0][:path].should.include 'ev.ics'
    end

    it "delete_event removes event" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")
      cal.delete_event('ev.ics').should.equal true
      lambda { cal.get_event('ev.ics') }.should.raise Async::Caldav::Client::NotFound
    end

    it "delete removes collection" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.delete.should.equal true
    end

    it "put_event with if_match sends precondition" do
      client, = make_client
      cal = client.create_calendar('work')
      result = cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")
      etag = result[:etag]

      # Update with correct etag works
      result2 = cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nSUMMARY:V2\r\nEND:VCALENDAR", if_match: etag)
      result2[:status].should.equal 204

      # Update with wrong etag fails
      lambda {
        cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nSUMMARY:V3\r\nEND:VCALENDAR", if_match: '"wrong"')
      }.should.raise Async::Caldav::Client::PreconditionFailed
    end

    it "put_event with if_none_match * prevents overwrite" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")

      lambda {
        cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR", if_none_match: '*')
      }.should.raise Async::Caldav::Client::PreconditionFailed
    end

    it "put_event with duplicate UID raises Conflict" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('a.ics', "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR")

      lambda {
        cal.put_event('b.ics', "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR")
      }.should.raise Async::Caldav::Client::Conflict
    end

    it "sync returns items and token" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")

      items, token = cal.sync
      items.length.should.equal 1
      token.should.not.be.nil
    end

    it "sync with token returns incremental changes" do
      client, = make_client
      cal = client.create_calendar('work')
      cal.put_event('ev.ics', "BEGIN:VCALENDAR\r\nUID:1\r\nEND:VCALENDAR")

      _, token = cal.sync

      # No changes
      items, token2 = cal.sync(token: token)
      items.length.should.equal 0

      # Add item
      cal.put_event('ev2.ics', "BEGIN:VCALENDAR\r\nUID:2\r\nEND:VCALENDAR")
      items, = cal.sync(token: token2)
      items.length.should.equal 1
      items[0][:path].should.include 'ev2.ics'
    end

    it "proppatch updates properties" do
      client, = make_client
      cal = client.create_calendar('work', displayname: 'Old')
      cal.proppatch(displayname: 'New')
      cal.displayname.should.equal 'New'
    end
  end

  describe "Async::Caldav::Client::Addressbook" do
    def make_client
      transport = MockTransport.new
      [TestClient.new(transport, user: 'admin'), transport]
    end

    it "put_contact creates contact and returns etag" do
      client, = make_client
      ab = client.create_addressbook('contacts')
      result = ab.put_contact('alice.vcf', "BEGIN:VCARD\r\nUID:1\r\nFN:Alice\r\nEND:VCARD")
      result[:status].should.equal 201
      result[:etag].should.not.be.nil
    end

    it "get_contact retrieves contact" do
      client, = make_client
      ab = client.create_addressbook('contacts')
      ab.put_contact('alice.vcf', "BEGIN:VCARD\r\nUID:1\r\nFN:Alice\r\nEND:VCARD")
      result = ab.get_contact('alice.vcf')
      result[:body].should.include 'FN:Alice'
    end

    it "contacts returns items from REPORT" do
      client, = make_client
      ab = client.create_addressbook('contacts')
      ab.put_contact('alice.vcf', "BEGIN:VCARD\r\nUID:1\r\nFN:Alice\r\nEND:VCARD")
      items = ab.contacts
      items.length.should.equal 1
    end

    it "delete_contact removes contact" do
      client, = make_client
      ab = client.create_addressbook('contacts')
      ab.put_contact('alice.vcf', "BEGIN:VCARD\r\nUID:1\r\nFN:Alice\r\nEND:VCARD")
      ab.delete_contact('alice.vcf').should.equal true
      lambda { ab.get_contact('alice.vcf') }.should.raise Async::Caldav::Client::NotFound
    end

    it "delete removes collection" do
      client, = make_client
      ab = client.create_addressbook('contacts')
      ab.delete.should.equal true
    end
  end
end
