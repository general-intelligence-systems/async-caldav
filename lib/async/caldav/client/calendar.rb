# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "builder"

module Async
  module Caldav
    class Client
      class Calendar
        attr_reader :path, :displayname, :description, :color, :ctag

        def initialize(client, path, props = {})
          @client = client
          @path = path
          @displayname = props[:displayname]
          @description = props[:description]
          @color = props[:color]
          @ctag = props[:ctag]
        end

        def events(filter: nil)
          x = Builder::XmlMarkup.new
          x.instruct! :xml, version: "1.0", encoding: "UTF-8"
          x.tag!("c:calendar-query", "xmlns:d" => "DAV:", "xmlns:c" => "urn:ietf:params:xml:ns:caldav") do
            x.tag!("d:prop") { x.tag!("d:getetag"); x.tag!("c:calendar-data") }
            x << filter if filter
          end
          body = x.target!

          status, _, resp_body = @client.request('REPORT', @path, body: body, headers: { 'Content-Type' => 'text/xml' })
          raise Error, "REPORT failed: #{status}" unless status == 207

          @client.parse_multistatus_items(resp_body, data_tag: 'calendar-data')
        end

        def put_event(filename, body, if_match: nil, if_none_match: nil)
          headers = { 'Content-Type' => 'text/calendar' }
          headers['If-Match'] = if_match if if_match
          headers['If-None-Match'] = if_none_match if if_none_match

          path = "#{@path}#{filename}"
          status, resp_headers, = @client.request('PUT', path, body: body, headers: headers)

          case status
          when 201, 204
            { path: path, etag: resp_headers['etag'], status: status }
          when 412
            raise PreconditionFailed, "Precondition failed for #{path}"
          when 409
            raise Conflict, "UID conflict for #{path}"
          else
            raise Error, "PUT failed: #{status}"
          end
        end

        def get_event(filename)
          path = "#{@path}#{filename}"
          status, headers, body = @client.request('GET', path)

          case status
          when 200
            { path: path, body: body, etag: headers['etag'], content_type: headers['content-type'] }
          when 404
            raise NotFound, "Not found: #{path}"
          else
            raise Error, "GET failed: #{status}"
          end
        end

        def delete_event(filename)
          path = "#{@path}#{filename}"
          status, = @client.request('DELETE', path)

          case status
          when 204 then true
          when 404 then raise NotFound, "Not found: #{path}"
          else raise Error, "DELETE failed: #{status}"
          end
        end

        def delete
          status, = @client.request('DELETE', @path)

          case status
          when 204 then true
          when 404 then raise NotFound, "Not found: #{@path}"
          else raise Error, "DELETE failed: #{status}"
          end
        end

        def propfind
          status, _, body = @client.request('PROPFIND', @path, headers: { 'Depth' => '0' })
          raise Error, "PROPFIND failed: #{status}" unless status == 207
          @client.parse_collection_props(body)
        end

        def proppatch(displayname: nil, description: nil, color: nil)
          x = Builder::XmlMarkup.new
          x.instruct! :xml, version: "1.0", encoding: "UTF-8"
          x.tag!("d:propertyupdate", "xmlns:d" => "DAV:", "xmlns:c" => "urn:ietf:params:xml:ns:caldav", "xmlns:x" => "http://apple.com/ns/ical/") do
            x.tag!("d:set") do
              x.tag!("d:prop") do
                x.tag!("d:displayname", displayname) if displayname
                x.tag!("c:calendar-description", description) if description
                x.tag!("x:calendar-color", color) if color
              end
            end
          end

          status, = @client.request('PROPPATCH', @path, body: x.target!, headers: { 'Content-Type' => 'text/xml' })
          raise Error, "PROPPATCH failed: #{status}" unless status == 207

          @displayname = displayname if displayname
          @description = description if description
          @color = color if color
          self
        end

        def sync(token: nil)
          x = Builder::XmlMarkup.new
          x.instruct! :xml, version: "1.0", encoding: "UTF-8"
          x.tag!("d:sync-collection", "xmlns:d" => "DAV:") do
            x.tag!("d:prop") { x.tag!("d:getetag") }
            if token
              x.tag!("d:sync-token", token)
            else
              x.tag!("d:sync-token")
            end
          end
          body = x.target!

          status, _, resp_body = @client.request('REPORT', @path, body: body, headers: { 'Content-Type' => 'text/xml' })

          if status == 403
            raise InvalidSyncToken, "Invalid sync token"
          end
          raise Error, "REPORT failed: #{status}" unless status == 207

          new_token = resp_body.match(/<[^>]*sync-token[^>]*>([^<]+)</)[1] rescue nil
          items = @client.parse_sync_items(resp_body)
          [items, new_token]
        end
      end
    end
  end
end
