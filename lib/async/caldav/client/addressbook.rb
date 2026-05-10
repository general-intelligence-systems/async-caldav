# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "builder"

module Async
  module Caldav
    class Client
      class Addressbook
        attr_reader :path, :displayname

        def initialize(client, path, props = {})
          @client = client
          @path = path
          @displayname = props[:displayname]
        end

        def contacts(filter: nil)
          x = Builder::XmlMarkup.new
          x.instruct! :xml, version: "1.0", encoding: "UTF-8"
          x.tag!("cr:addressbook-query", "xmlns:d" => "DAV:", "xmlns:cr" => "urn:ietf:params:xml:ns:carddav") do
            x.tag!("d:prop") { x.tag!("d:getetag"); x.tag!("cr:address-data") }
            x << filter if filter
          end
          body = x.target!

          status, _, resp_body = @client.request('REPORT', @path, body: body, headers: { 'Content-Type' => 'text/xml' })
          raise Error, "REPORT failed: #{status}" unless status == 207

          @client.parse_multistatus_items(resp_body, data_tag: 'address-data')
        end

        def put_contact(filename, body, if_match: nil, if_none_match: nil)
          headers = { 'Content-Type' => 'text/vcard' }
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

        def get_contact(filename)
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

        def delete_contact(filename)
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

        def proppatch(displayname: nil)
          x = Builder::XmlMarkup.new
          x.instruct! :xml, version: "1.0", encoding: "UTF-8"
          x.tag!("d:propertyupdate", "xmlns:d" => "DAV:") do
            x.tag!("d:set") do
              x.tag!("d:prop") do
                x.tag!("d:displayname", displayname) if displayname
              end
            end
          end

          status, = @client.request('PROPPATCH', @path, body: x.target!, headers: { 'Content-Type' => 'text/xml' })
          raise Error, "PROPPATCH failed: #{status}" unless status == 207

          @displayname = displayname if displayname
          self
        end
      end
    end
  end
end
