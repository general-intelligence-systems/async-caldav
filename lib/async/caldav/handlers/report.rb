# frozen_string_literal: true

module Async
  module Caldav
    module Handlers
      module Report
        module_function

        def call(path:, body:, storage:, resource_type: nil, **)
          # Detect sync-collection report
          if body&.include?('sync-collection')
            handle_sync_collection(path: path, body: body, storage: storage)
          else
            col_path = path.ensure_trailing_slash
            items = storage.list_items(col_path.to_s)
            if resource_type == :addressbook
              data_tag = 'cr:address-data'
            else
              data_tag = 'c:calendar-data'
            end
            expand_range = parse_expand(body)
            filter = parse_filter(body, resource_type)
            hrefs = extract_hrefs(body)
            if hrefs && !hrefs.empty?
              # Calendar-multiget / addressbook-multiget
              multi = storage.get_multi(hrefs)
              items = multi.select { |_, data| data }
            end
            xml = Protocol::Caldav::Multistatus.new.to_xml do |x|
              items.each do |item_path, data|
                unless data
                  next
                end

                # Apply filter
                if filter
                  if resource_type == :addressbook
                    card = Protocol::Caldav::Vcard::Parser.parse(data[:body])
                    unless card && Protocol::Caldav::Filter::Match.addressbook?(filter, card)
                      next
                    end
                  else
                    component = Protocol::Caldav::Ical::Parser.parse(data[:body])
                    unless component && Protocol::Caldav::Filter::Match.calendar?(filter, component)
                      next
                    end
                  end
                end

                item_body = data[:body]

                # Apply expand if requested (calendar items only)
                if expand_range && resource_type != :addressbook
                  component = Protocol::Caldav::Ical::Parser.parse(item_body)
                  if component
                    item_body = Protocol::Caldav::Ical::Expand.expand(
                      component,
                      range_start: expand_range[:start],
                      range_end:   expand_range[:end],
                    )
                  end
                end

                item_p = Protocol::Caldav::Path.new(item_path, storage_class: storage)
                item = Protocol::Caldav::Item.new(
                  path:         item_p,
                  body:         item_body,
                  content_type: data[:content_type],
                  etag:         data[:etag],
                )
                item.build_report(x, data_tag: data_tag)
              end
            end
            [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
          end
        end

        def parse_filter(body, resource_type)
          if resource_type == :addressbook
            Protocol::Caldav::Filter::Parser.parse_addressbook(body)
          else
            Protocol::Caldav::Filter::Parser.parse_calendar(body)
          end
        rescue Protocol::Caldav::ParseError
          nil
        end

        def handle_sync_collection(path:, body:, storage:)
          col_path = path.ensure_trailing_slash.to_s
          old_token = extract_sync_token(body)

          if old_token
            incremental_sync(col_path, old_token, storage)
          else
            initial_sync(col_path, storage)
          end
        end

        def extract_sync_token(body)
          token_match = body.match(/<[^>]*sync-token[^>]*>(?:<!\[CDATA\[)?([^<\]]*?)(?:\]\]>)?</)
          if token_match
            token = token_match[1].strip
            if token.empty?
              nil
            else
              token
            end
          end
        end

        def incremental_sync(col_path, old_token, storage)
          result = storage.sync_changes(col_path, old_token)
          if result
            new_token, changes = result
            xml = Protocol::Caldav::XmlBuilder.multistatus do |x|
              changes.each do |item_path, status|
                if status == :deleted
                  Protocol::Caldav::XmlBuilder.response(x, href: item_path) do
                    x.tag!("d:status", "HTTP/1.1 404 Not Found")
                  end
                else
                  etag = storage.etag(item_path)
                  Protocol::Caldav::XmlBuilder.response(x, href: item_path) do
                    Protocol::Caldav::XmlBuilder.propstat_ok(x) do
                      x.tag!("d:getetag", etag)
                    end
                  end
                end
              end
              x.tag!("d:sync-token", new_token)
            end
            [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
          else
            # The token names a snapshot the storage no longer holds; RFC 6578
            # says to answer with valid-sync-token so the client resyncs whole.
            error_xml = Builder::XmlMarkup.new
            error_xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
            error_xml.tag!("d:error", "xmlns:d" => "DAV:") do
              error_xml.tag!("d:valid-sync-token")
            end
            [403, { 'content-type' => 'application/xml' }, [error_xml.target!]]
          end
        end

        def initial_sync(col_path, storage)
          new_token = storage.snapshot_sync(col_path)
          items = storage.list_items(col_path)
          xml = Protocol::Caldav::XmlBuilder.multistatus do |x|
            items.each do |item_path, data|
              Protocol::Caldav::XmlBuilder.response(x, href: item_path) do
                Protocol::Caldav::XmlBuilder.propstat_ok(x) do
                  x.tag!("d:getetag", data[:etag])
                end
              end
            end
            x.tag!("d:sync-token", new_token)
          end

          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end

        def parse_expand(body)
          if body
            match = body.match(/<[^>]*expand[^>]*start\s*=\s*["']([^"']+)["'][^>]*end\s*=\s*["']([^"']+)["']/)
            if match
              start_time = Protocol::Caldav::Filter::Match.send(:parse_datetime_string, match[1])
              end_time = Protocol::Caldav::Filter::Match.send(:parse_datetime_string, match[2])
              if start_time && end_time
                { start: start_time, end: end_time }
              else
                nil
              end
            else
              nil
            end
          else
            nil
          end
        end

        def extract_hrefs(body)
          if body
            body.scan(/<[^>]*href[^>]*>([^<]+)</).map { |m| m[0].strip }
          else
            nil
          end
        end

        private_class_method :extract_hrefs, :handle_sync_collection, :parse_expand
        private_class_method :parse_filter, :extract_sync_token, :incremental_sync, :initial_sync
      end
    end
  end
end

__END__

require_relative "../../caldav"

def normalize(xml)
  xml.gsub(/>\s+</, '><').strip
end

describe "Async::Caldav::Handlers::Report" do
  def call(**opts)
    Async::Caldav::Handlers::Report.call(**opts)
  end

  def path(p, s)
    Protocol::Caldav::Path.new(p, storage_class: s)
  end

  it "returns 207 with all items when no filter" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:A\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
    s.put_item('/cal/b.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:B\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
    status, _, body = call(path: path('/cal/', s), storage: s, body: '', resource_type: :calendar)
    status.should.equal 207
    body[0].should.include 'a.ics'
    body[0].should.include 'b.ics'
  end

  it "filters items by comp-filter" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/ev.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
    s.put_item('/cal/td.ics', "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:Task\r\nEND:VTODO\r\nEND:VCALENDAR", 'text/calendar')

    filter_xml = <<~XML
      <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
        <c:comp-filter name="VCALENDAR">
          <c:comp-filter name="VEVENT"/>
        </c:comp-filter>
      </c:filter>
    XML

    _, _, body = call(path: path('/cal/', s), storage: s, body: filter_xml, resource_type: :calendar)
    body[0].should.include 'ev.ics'
    body[0].should.not.include 'td.ics'
  end

  it "uses c:calendar-data tag for calendars" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/ev.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')
    _, _, body = call(path: path('/cal/', s), storage: s, body: '', resource_type: :calendar)
    body[0].should.include 'c:calendar-data'
  end

  it "uses cr:address-data tag for addressbooks" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/addr/')
    s.put_item('/addr/c.vcf', "BEGIN:VCARD\r\nFN:John\r\nEND:VCARD", 'text/vcard')
    _, _, body = call(path: path('/addr/', s), storage: s, body: '', resource_type: :addressbook)
    body[0].should.include 'cr:address-data'
  end

  it "handles calendar-multiget with hrefs" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')
    s.put_item('/cal/b.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')

    multiget_body = '<d:href>/cal/a.ics</d:href>'
    _, _, body = call(path: path('/cal/', s), storage: s, body: multiget_body, resource_type: :calendar)
    body[0].should.include 'a.ics'
    body[0].should.not.include 'b.ics'
  end
end